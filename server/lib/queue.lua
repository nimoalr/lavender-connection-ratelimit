Lavender = Lavender or {}

local Identity = Lavender.Identity
local Util = Lavender.Util

local Queue = {}
Queue.__index = Queue

local function copyArray(source)
    local copy = {}
    for i = 1, #source do
        copy[i] = source[i]
    end
    return copy
end

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

function Queue:_emit(event, data)
    self.onEvent(event, data)
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
        if self.recentAdmissions[i].expiresAt <= now then
            table.remove(self.recentAdmissions, i)
        end
    end

end

function Queue:_activeDuplicateInfo(candidate, now)
    local threshold = self.config.identity.similarityThreshold

    for i = #self.entries, 1, -1 do
        local existing = self.entries[i]
        if existing.sourceKey == candidate.sourceKey
            or Identity.matches(candidate.identitySet, existing.identitySet, threshold) then
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

    for _, existing in pairs(self.inFlight) do
        if existing.sourceKey == candidate.sourceKey
            or Identity.matches(candidate.identitySet, existing.identitySet, threshold) then
            return {
                state = 'joining',
                entry = existing,
                waitSeconds = math.max(0, existing.expiresAt - now),
            }
        end
    end

    return nil
end

function Queue:_nearestQueuedDuplicateBefore(index)
    local entry = self.entries[index]
    if not entry then
        return nil
    end

    local threshold = self.config.identity.similarityThreshold
    for i = index - 1, 1, -1 do
        local existing = self.entries[i]
        if Identity.matches(entry.identitySet, existing.identitySet, threshold) then
            return existing
        end
    end

    return nil
end

function Queue:_matchingInFlight(entry)
    local threshold = self.config.identity.similarityThreshold
    for _, existing in pairs(self.inFlight) do
        if Identity.matches(entry.identitySet, existing.identitySet, threshold) then
            return existing
        end
    end

    return nil
end

function Queue:_reconcileActiveDuplicateDelays(now)
    if self.config.identity.activeDuplicatePolicy ~= 'queue' then
        return
    end

    now = now or self.now()

    for i = 1, #self.entries do
        local entry = self.entries[i]
        local userEligibleAt = self:_recentCooldownUntil(entry.identitySet or {}, now)
        local userDelayReason
        local duplicateState

        local queuedDuplicate = self:_nearestQueuedDuplicateBefore(i)
        if queuedDuplicate then
            userEligibleAt = math.max(
                userEligibleAt,
                now + self:estimateWait(queuedDuplicate) + self.config.identity.userCooldownSeconds
            )
            userDelayReason = 'active_duplicate'
            duplicateState = 'queued'
        else
            local joiningDuplicate = self:_matchingInFlight(entry)
            if joiningDuplicate then
                userEligibleAt = math.max(
                    userEligibleAt,
                    (joiningDuplicate.admittedAt or now) + self.config.identity.userCooldownSeconds
                )
                userDelayReason = 'active_duplicate'
                duplicateState = 'joining'
            end
        end

        entry.userEligibleAt = userEligibleAt
        entry.userDelayReason = userDelayReason
        entry.duplicateState = duplicateState
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

    for i = 1, #self.recentAdmissions do
        local recent = self.recentAdmissions[i]
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
    self:_reconcileDelays(now)
    self:_emit('queued', entry)
    return entry
end

function Queue:_removeAt(index, reason)
    local entry = table.remove(self.entries, index)
    if not entry then
        return nil
    end

    self.entriesById[entry.id] = nil
    self:_reconcileDelays(self.now())
    self:_emit('removed', { entry = entry, reason = reason })
    return entry
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
    for i = #self.entries, 1, -1 do
        local entry = self.entries[i]
        if now - entry.enqueuedAt >= self.config.queue.maxWaitSeconds then
            results.queueTimeouts[#results.queueTimeouts + 1] = self:_removeAt(i, 'queue_timeout')
        end
    end
end

function Queue:_expireInFlight(now, results)
    for sourceKey, entry in pairs(self.inFlight) do
        if entry.expiresAt <= now then
            self.inFlight[sourceKey] = nil
            results.inFlightTimeouts[#results.inFlightTimeouts + 1] = entry
            self:_emit('in_flight_timeout', entry)
        end
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
        self.inFlight[sourceKey] = nil
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

        local entry = table.remove(self.entries, eligibleIndex)
        self.entriesById[entry.id] = nil
        self.tokens = self.tokens - 1

        entry.admittedAt = now
        entry.expiresAt = now + self.config.release.inFlightTimeoutSeconds
        entry.missingSince = nil
        self.inFlight[entry.sourceKey] = entry
        self.recentAdmissions[#self.recentAdmissions + 1] = {
            identitySet = entry.identitySet,
            ip = entry.ip,
            admittedAt = now,
            expiresAt = now + self.config.identity.recentHistorySeconds,
        }

        results.admitted[#results.admitted + 1] = entry
        self:_emit('admitted', entry)
    end

    if #results.admitted > 0 then
        self:_reconcileDelays(now)
    end

    return results
end

function Queue:completeInFlight(sourceKey)
    local entry = self.inFlight[sourceKey]
    if entry then
        self.inFlight[sourceKey] = nil
        self:_emit('in_flight_completed', entry)
    end
    return entry
end

function Queue:drain(reason)
    local drained = {}
    while #self.entries > 0 do
        drained[#drained + 1] = self:_removeAt(#self.entries, reason or 'resource_stop')
    end
    return drained
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
    }
end

Lavender.Queue = Queue
return Queue
