Lavender = Lavender or {}

local Identity = Lavender.Identity
local Util = Lavender.Util

--[[
    Admission queue.

    All queue work runs synchronously on the server's main thread, so every
    operation must stay cheap at large backlogs (hundreds to thousands of
    waiting connections):

      * Identity lookups (queued duplicates, in-flight duplicates, recent-admission
        cooldowns) go through an exact inverted index (identifier -> members).
        Identity.matches(a, b, t) with the validated threshold t >= 0.01 requires
        at least one shared identifier, so the index enumerates a superset of every
        match and the same Jaccard predicate is then applied to candidates only.
        Unique identities cost O(1) instead of a full scan per entry.
      * One reconciliation pass computes each entry's wait estimate for later
        duplicates in O(log n) using a sorted prefix of eligibility times, instead
        of an O(n) rescan per duplicate.
      * Batch expiry and drain remove every affected entry first and reconcile
        ONCE, instead of reconciling after each single removal (which is cubic in
        the batch size).
      * Observer callbacks (onEvent) are isolated: an exception in a metrics
        callback cannot abort a state transition half-way or kill the caller's
        ticker. Failures are counted, never swallowed silently.

    When several in-flight entries match, the one with the lowest sourceKey
    (string order) is chosen so results are deterministic.
]]

local function copyArray(source)
    local copy = {}
    for i = 1, #source do
        copy[i] = source[i]
    end
    return copy
end

-- ---------------------------------------------------------------------------
-- Exact inverted identity index
-- ---------------------------------------------------------------------------

local IdentityIndex = {}
IdentityIndex.__index = IdentityIndex

function IdentityIndex.new()
    return setmetatable({ members = {} }, IdentityIndex)
end

function IdentityIndex:add(record, identitySet)
    for identifier in pairs(identitySet or {}) do
        local bucket = self.members[identifier]
        if not bucket then
            bucket = {}
            self.members[identifier] = bucket
        end
        bucket[record] = true
    end
end

function IdentityIndex:remove(record, identitySet)
    for identifier in pairs(identitySet or {}) do
        local bucket = self.members[identifier]
        if bucket then
            bucket[record] = nil
            if next(bucket) == nil then
                self.members[identifier] = nil
            end
        end
    end
end

--- candidates returns a set of records sharing at least one identifier with
--- identitySet. Every record that can satisfy Identity.matches with a positive
--- threshold is in this set; callers still apply the exact predicate.
function IdentityIndex:candidates(identitySet)
    local found = {}
    for identifier in pairs(identitySet or {}) do
        local bucket = self.members[identifier]
        if bucket then
            for record in pairs(bucket) do
                found[record] = true
            end
        end
    end
    return found
end

-- ---------------------------------------------------------------------------
-- Sorted prefix of eligibility times (per reconciliation pass)
-- ---------------------------------------------------------------------------

-- countAtMost returns how many values in the sorted array are <= x.
local function countAtMost(sorted, x)
    local lo, hi = 1, #sorted
    while lo <= hi do
        local mid = (lo + hi) // 2
        if sorted[mid] <= x then
            lo = mid + 1
        else
            hi = mid - 1
        end
    end
    return lo - 1
end

local function insertSorted(sorted, x)
    local lo, hi = 1, #sorted
    while lo <= hi do
        local mid = (lo + hi) // 2
        if sorted[mid] <= x then
            lo = mid + 1
        else
            hi = mid - 1
        end
    end
    table.insert(sorted, lo, x)
end

local function sortedKeys(set)
    local keys = {}
    for key in pairs(set) do
        keys[#keys + 1] = key
    end
    table.sort(keys)
    return keys
end

-- ---------------------------------------------------------------------------
-- Queue
-- ---------------------------------------------------------------------------

local Queue = {}
Queue.__index = Queue

function Queue.new(options)
    options = options or {}
    local now = options.now or os.time
    local config = assert(options.config, 'Queue config is required')
    local current = now()

    return setmetatable({
        now = now,
        config = config,
        onEvent = options.onEvent or function() end,
        entries = {},
        entriesById = {},
        inFlight = {},
        recentAdmissions = {},
        nextId = 0,
        tokens = config.release.burst,
        lastRefill = current,
        -- indexes (exact; see header)
        queuedIndex = IdentityIndex.new(),
        inFlightIndex = IdentityIndex.new(),
        recentIndex = IdentityIndex.new(),
        -- observer isolation
        eventCallbackErrors = 0,
        lastEventCallbackError = nil,
    }, Queue)
end

function Queue:setConfig(config)
    self:_refill()
    self.config = config
    self.tokens = math.min(self.tokens, config.release.burst)
end

function Queue:fillBucket()
    self.tokens = self.config.release.burst
    self.lastRefill = self.now()
end

--- _emit notifies the observer. The observer is OUTSIDE the queue's invariants:
--- a throwing callback must not leave an entry half admitted, so failures are
--- counted and reported, and state transitions always complete.
function Queue:_emit(event, data)
    local ok, err = pcall(self.onEvent, event, data)
    if not ok then
        self.eventCallbackErrors = self.eventCallbackErrors + 1
        self.lastEventCallbackError = tostring(err)
    end
end

function Queue:_refill()
    local now = self.now()
    local elapsed = now - self.lastRefill
    if elapsed < 0 then
        elapsed = 0
    end

    self.tokens = math.min(
        self.config.release.burst,
        self.tokens + elapsed * self.config.release.ratePerSecond
    )
    self.lastRefill = now
end

function Queue:_tokensAt(now)
    local elapsed = now - self.lastRefill
    if elapsed < 0 then
        elapsed = 0
    end

    return math.min(
        self.config.release.burst,
        self.tokens + elapsed * self.config.release.ratePerSecond
    )
end

function Queue:_cleanupRecent(now)
    for i = #self.recentAdmissions, 1, -1 do
        local recent = self.recentAdmissions[i]
        if recent.expiresAt <= now then
            table.remove(self.recentAdmissions, i)
            self.recentIndex:remove(recent, recent.identitySet)
        end
    end
end

--- _matchingInFlightFor returns the in-flight entry matching identitySet (or, when
--- sourceKey is given, sharing that sourceKey) with the lowest sourceKey, or nil.
function Queue:_matchingInFlightFor(identitySet, sourceKey)
    local threshold = self.config.identity.similarityThreshold
    local candidates = self.inFlightIndex:candidates(identitySet)
    local matching = {}
    for record in pairs(candidates) do
        if Identity.matches(identitySet, record.identitySet, threshold) then
            matching[record.sourceKey] = record
        end
    end
    if sourceKey ~= nil and self.inFlight[sourceKey] then
        matching[sourceKey] = self.inFlight[sourceKey]
    end
    local keys = sortedKeys(matching)
    if #keys == 0 then
        return nil
    end
    return matching[keys[1]]
end

function Queue:_activeDuplicateInfo(candidate, now)
    local threshold = self.config.identity.similarityThreshold
    local identitySet = candidate.identitySet or {}
    local candidates = self.queuedIndex:candidates(identitySet)

    -- Latest queued entry (highest position) that matches by identity or shares
    -- the sourceKey: same result as the original reverse scan, but only the
    -- candidate subset pays the Jaccard comparison.
    for i = #self.entries, 1, -1 do
        local existing = self.entries[i]
        if existing.sourceKey == candidate.sourceKey
            or (candidates[existing] and Identity.matches(identitySet, existing.identitySet, threshold)) then
            return {
                state = 'queued',
                entry = existing,
                waitSeconds = math.min(
                    self:estimateWait(existing),
                    math.max(0, self.config.queue.maxWaitSeconds - (now - existing.enqueuedAt))
                ),
                position = i,
            }
        end
    end

    local joining = self:_matchingInFlightFor(identitySet, candidate.sourceKey)
    if joining then
        return {
            state = 'joining',
            entry = joining,
            waitSeconds = math.max(0, joining.expiresAt - now),
        }
    end

    return nil
end

function Queue:_nearestQueuedDuplicateBefore(index)
    local entry = self.entries[index]
    if not entry then
        return nil
    end

    local threshold = self.config.identity.similarityThreshold
    local candidates = self.queuedIndex:candidates(entry.identitySet)
    for i = index - 1, 1, -1 do
        local existing = self.entries[i]
        if candidates[existing] and Identity.matches(entry.identitySet, existing.identitySet, threshold) then
            return existing
        end
    end

    return nil
end

function Queue:_matchingInFlight(entry)
    return self:_matchingInFlightFor(entry.identitySet, nil)
end

--- _reconcileActiveDuplicateDelays recomputes user-level eligibility for every
--- queued entry in queue order. For an entry with an earlier queued duplicate the
--- original called estimateWait(duplicate), which rescans everything ahead of the
--- duplicate; because entries ahead of the duplicate are already final within
--- this pass, that estimate is precomputed here when the duplicate itself is
--- processed (sorted prefix of eligibility times + binary search).
function Queue:_reconcileActiveDuplicateDelays(now)
    if self.config.identity.activeDuplicatePolicy ~= 'queue' then
        return
    end

    now = now or self.now()

    local threshold = self.config.identity.similarityThreshold
    local cooldownSeconds = self.config.identity.userCooldownSeconds
    local rate = self.config.release.ratePerSecond

    local position = {}      -- entry -> index, for entries already processed
    local prefixEligible = {} -- sorted max(userEligibleAt, ipEligibleAt) of processed entries
    local estimate = {}      -- entry -> estimateWait(entry) as the original would compute it

    for i = 1, #self.entries do
        local entry = self.entries[i]
        local userEligibleAt = self:_recentCooldownUntil(entry.identitySet or {}, now)
        local userDelayReason
        local duplicateState

        -- nearest earlier duplicate: the candidate with the highest processed index
        local queuedDuplicate
        local bestIndex = 0
        for record in pairs(self.queuedIndex:candidates(entry.identitySet)) do
            local idx = position[record]
            if idx and idx > bestIndex and Identity.matches(entry.identitySet, record.identitySet, threshold) then
                bestIndex = idx
                queuedDuplicate = record
            end
        end

        if queuedDuplicate then
            userEligibleAt = math.max(
                userEligibleAt,
                now + estimate[queuedDuplicate] + cooldownSeconds
            )
            userDelayReason = 'active_duplicate'
            duplicateState = 'queued'
        else
            local joiningDuplicate = self:_matchingInFlight(entry)
            if joiningDuplicate then
                userEligibleAt = math.max(
                    userEligibleAt,
                    (joiningDuplicate.admittedAt or now) + cooldownSeconds
                )
                userDelayReason = 'active_duplicate'
                duplicateState = 'joining'
            end
        end

        entry.userEligibleAt = userEligibleAt
        entry.userDelayReason = userDelayReason
        entry.duplicateState = duplicateState

        -- estimateWait(entry) restricted to entries ahead of it, all final now.
        local eligibleAt = math.max(now, entry.userEligibleAt, entry.ipEligibleAt)
        local ahead = countAtMost(prefixEligible, eligibleAt)
        local tokenDelay = math.max(0, (ahead + 1) - self:_tokensAt(eligibleAt)) / rate
        estimate[entry] = (eligibleAt - now) + tokenDelay

        insertSorted(prefixEligible, math.max(entry.userEligibleAt, entry.ipEligibleAt))
        position[entry] = i
    end
end

function Queue:_reconcileIpDelays(now)
    now = now or self.now()

    local lastByIp = {}
    for i = 1, #self.recentAdmissions do
        local recent = self.recentAdmissions[i]
        if recent.ip then
            lastByIp[recent.ip] = math.max(lastByIp[recent.ip] or -math.huge, recent.admittedAt)
        end
    end

    for i = 1, #self.entries do
        local entry = self.entries[i]
        if entry.ip then
            local previous = lastByIp[entry.ip]
            if previous then
                entry.ipEligibleAt = math.max(now, previous + self.config.ip.spacingSeconds)
            else
                entry.ipEligibleAt = now
            end
            lastByIp[entry.ip] = entry.ipEligibleAt
        else
            entry.ipEligibleAt = now
        end
    end
end

function Queue:_reconcileDelays(now)
    now = now or self.now()
    self:_reconcileIpDelays(now)
    self:_reconcileActiveDuplicateDelays(now)
end

function Queue:_recentCooldownUntil(identitySet, now)
    local cooldownUntil = now
    local threshold = self.config.identity.similarityThreshold

    for recent in pairs(self.recentIndex:candidates(identitySet)) do
        if Identity.matches(identitySet, recent.identitySet, threshold) then
            cooldownUntil = math.max(cooldownUntil, recent.admittedAt + self.config.identity.userCooldownSeconds)
        end
    end

    return cooldownUntil
end

function Queue:enqueue(candidate)
    local now = self.now()
    self:_cleanupRecent(now)

    local duplicate = self:_activeDuplicateInfo(candidate, now)
    local queueDuplicate = duplicate and self.config.identity.activeDuplicatePolicy == 'queue'
    if duplicate and not queueDuplicate then
        return nil, 'duplicate', duplicate
    end
    if #self.entries >= self.config.queue.maxSize then
        return nil, 'queue_full'
    end

    local userEligibleAt = self:_recentCooldownUntil(candidate.identitySet or {}, now)
    local userDelayReason
    if queueDuplicate then
        local duplicateCooldownBase = now
        if duplicate.state == 'queued' then
            duplicateCooldownBase = now + (duplicate.waitSeconds or 0)
        elseif duplicate.entry and duplicate.entry.admittedAt then
            duplicateCooldownBase = duplicate.entry.admittedAt
        end

        userEligibleAt = math.max(
            userEligibleAt,
            duplicateCooldownBase + self.config.identity.userCooldownSeconds
        )
        userDelayReason = 'active_duplicate'
    end

    self.nextId = self.nextId + 1
    local entry = {
        id = self.nextId,
        sourceKey = candidate.sourceKey,
        name = candidate.name,
        ip = candidate.ip,
        identitySet = candidate.identitySet or {},
        payload = candidate.payload,
        enqueuedAt = now,
        userEligibleAt = userEligibleAt,
        userDelayReason = userDelayReason,
        duplicateState = duplicate and duplicate.state or nil,
        ipEligibleAt = now,
        missingSince = nil,
    }

    self.entries[#self.entries + 1] = entry
    self.entriesById[entry.id] = entry
    self.queuedIndex:add(entry, entry.identitySet)
    self:_reconcileDelays(now)
    self:_emit('queued', entry)
    return entry
end

--- _detach removes the entry at index from the queue structures WITHOUT
--- reconciling or emitting; callers batch those steps.
function Queue:_detach(index)
    local entry = table.remove(self.entries, index)
    if not entry then
        return nil
    end
    self.entriesById[entry.id] = nil
    self.queuedIndex:remove(entry, entry.identitySet)
    return entry
end

function Queue:_removeAt(index, reason)
    local entry = self:_detach(index)
    if not entry then
        return nil
    end

    self:_reconcileDelays(self.now())
    self:_emit('removed', { entry = entry, reason = reason })
    return entry
end

--- _removeMany detaches the entries at the given DESCENDING indices, reconciles
--- once, then emits one 'removed' event per entry in that order (the order the
--- original produced by removing one at a time from the back).
function Queue:_removeMany(indicesDescending, reason)
    local removed = {}
    for i = 1, #indicesDescending do
        local entry = self:_detach(indicesDescending[i])
        if entry then
            removed[#removed + 1] = entry
        end
    end
    if #removed > 0 then
        self:_reconcileDelays(self.now())
        for i = 1, #removed do
            self:_emit('removed', { entry = removed[i], reason = reason })
        end
    end
    return removed
end

function Queue:remove(sourceKey, reason)
    for i = 1, #self.entries do
        if self.entries[i].sourceKey == sourceKey then
            return self:_removeAt(i, reason or 'removed')
        end
    end
    return nil
end

function Queue:isQueued(id)
    return self.entriesById[id] ~= nil
end

function Queue:updatePresence(sourceKey, present)
    local now = self.now()

    for i = 1, #self.entries do
        local entry = self.entries[i]
        if entry.sourceKey == sourceKey then
            if present then
                entry.missingSince = nil
                return nil
            end

            entry.missingSince = entry.missingSince or now
            if now - entry.missingSince >= self.config.queue.disconnectGraceSeconds then
                return self:_removeAt(i, 'disconnected')
            end
            return nil
        end
    end

    return nil
end

function Queue:_timeEligible(entry, now)
    return entry.userEligibleAt <= now and entry.ipEligibleAt <= now
end

function Queue:_expireQueue(now, results)
    local expired = {}
    for i = #self.entries, 1, -1 do
        if now - self.entries[i].enqueuedAt >= self.config.queue.maxWaitSeconds then
            expired[#expired + 1] = i
        end
    end
    if #expired == 0 then
        return
    end
    local removed = self:_removeMany(expired, 'queue_timeout')
    for i = 1, #removed do
        results.queueTimeouts[#results.queueTimeouts + 1] = removed[i]
    end
end

function Queue:_setInFlight(entry)
    self.inFlight[entry.sourceKey] = entry
    self.inFlightIndex:add(entry, entry.identitySet)
end

function Queue:_clearInFlight(sourceKey)
    local entry = self.inFlight[sourceKey]
    if entry then
        self.inFlight[sourceKey] = nil
        self.inFlightIndex:remove(entry, entry.identitySet)
    end
    return entry
end

function Queue:_expireInFlight(now, results)
    local expired = {}
    for sourceKey, entry in pairs(self.inFlight) do
        if entry.expiresAt <= now then
            expired[#expired + 1] = sourceKey
        end
    end
    table.sort(expired)
    for i = 1, #expired do
        local entry = self:_clearInFlight(expired[i])
        results.inFlightTimeouts[#results.inFlightTimeouts + 1] = entry
        self:_emit('in_flight_timeout', entry)
    end
end

function Queue:getInFlightEntries()
    local entries = {}
    for _, entry in pairs(self.inFlight) do
        entries[#entries + 1] = entry
    end
    return entries
end

function Queue:updateInFlightPresence(sourceKey, present)
    local entry = self.inFlight[sourceKey]
    if not entry then
        return nil
    end

    if present then
        entry.missingSince = nil
        return nil
    end

    local now = self.now()
    entry.missingSince = entry.missingSince or now
    if now - entry.missingSince >= self.config.queue.disconnectGraceSeconds then
        self:_clearInFlight(sourceKey)
        self:_emit('in_flight_disconnected', entry)
        return entry
    end

    return nil
end

function Queue:tick()
    local now = self.now()
    local results = {
        admitted = {},
        queueTimeouts = {},
        inFlightTimeouts = {},
    }

    self:_refill()
    self:_cleanupRecent(now)
    self:_expireQueue(now, results)
    self:_expireInFlight(now, results)

    while self.tokens >= 1 and Util.countMap(self.inFlight) < self.config.release.maxInFlight do
        local eligibleIndex
        for i = 1, #self.entries do
            if self:_timeEligible(self.entries[i], now) then
                eligibleIndex = i
                break
            end
        end

        if not eligibleIndex then
            break
        end

        local entry = self:_detach(eligibleIndex)
        self.tokens = self.tokens - 1

        entry.admittedAt = now
        entry.expiresAt = now + self.config.release.inFlightTimeoutSeconds
        entry.missingSince = nil
        self:_setInFlight(entry)
        local recent = {
            identitySet = entry.identitySet,
            ip = entry.ip,
            admittedAt = now,
            expiresAt = now + self.config.identity.recentHistorySeconds,
        }
        self.recentAdmissions[#self.recentAdmissions + 1] = recent
        self.recentIndex:add(recent, recent.identitySet)

        results.admitted[#results.admitted + 1] = entry
        self:_emit('admitted', entry)
    end

    if #results.admitted > 0 then
        self:_reconcileDelays(now)
    end

    return results
end

function Queue:completeInFlight(sourceKey)
    local entry = self:_clearInFlight(sourceKey)
    if entry then
        self:_emit('in_flight_completed', entry)
    end
    return entry
end

function Queue:drain(reason)
    local indices = {}
    for i = #self.entries, 1, -1 do
        indices[#indices + 1] = i
    end
    return self:_removeMany(indices, reason or 'resource_stop')
end

function Queue:getEntries()
    return copyArray(self.entries)
end

function Queue:getPosition(id)
    for i = 1, #self.entries do
        if self.entries[i].id == id then
            return i
        end
    end
    return nil
end

function Queue:getEntryReason(entry)
    local now = self.now()
    local userRemaining = math.max(0, entry.userEligibleAt - now)
    local ipRemaining = math.max(0, entry.ipEligibleAt - now)

    if userRemaining > 0 and userRemaining >= ipRemaining then
        return entry.userDelayReason or 'user_cooldown', userRemaining
    end
    if ipRemaining > 0 then
        return 'ip_pacing', ipRemaining
    end
    if Util.countMap(self.inFlight) >= self.config.release.maxInFlight then
        return 'in_flight', 0
    end

    self:_refill()
    if self.tokens < 1 then
        return 'global_rate', (1 - self.tokens) / self.config.release.ratePerSecond
    end

    return 'ready', 0
end

function Queue:estimateWait(entry)
    local now = self.now()
    local eligibleAt = math.max(now, entry.userEligibleAt, entry.ipEligibleAt)
    local delay = eligibleAt - now
    local ahead = 0

    for i = 1, #self.entries do
        local queued = self.entries[i]
        if queued.id == entry.id then
            break
        end
        if self:_timeEligible(queued, eligibleAt) then
            ahead = ahead + 1
        end
    end

    local neededTokens = ahead + 1
    local tokensAtEligible = self:_tokensAt(eligibleAt)
    local tokenDelay = math.max(0, neededTokens - tokensAtEligible) / self.config.release.ratePerSecond

    return delay + tokenDelay
end

function Queue:status()
    local now = self.now()
    local eligible = 0
    for i = 1, #self.entries do
        if self:_timeEligible(self.entries[i], now) then
            eligible = eligible + 1
        end
    end

    self:_refill()
    return {
        queueSize = #self.entries,
        eligibleQueueSize = eligible,
        inFlight = Util.countMap(self.inFlight),
        tokens = self.tokens,
        ratePerSecond = self.config.release.ratePerSecond,
        maxInFlight = self.config.release.maxInFlight,
        eventCallbackErrors = self.eventCallbackErrors,
    }
end

Lavender.Queue = Queue
return Queue
