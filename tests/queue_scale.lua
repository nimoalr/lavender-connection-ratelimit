-- Queue observer isolation and scaling tests for server/lib/queue.lua.
-- Returns a function(test, assertEqual, assertTrue) that registers tests.

return function(test, assertEqual, assertTrue)
    local Util = Lavender.Util
    local Identity = Lavender.Identity
    local Queue = Lavender.Queue

    local function identityFor(base)
        return Identity.fromRaw({
            'license:l' .. base, 'license2:m' .. base, 'discord:d' .. base,
            'fivem:f' .. base, 'live:v' .. base, 'xbl:x' .. base,
        }, { 'tokA' .. base, 'tokB' .. base })
    end

    test('observer callback failures are isolated from queue state transitions', function()
        local now = 0
        local config = Util.deepCopy(Lavender.Defaults)
        config.release.ratePerSecond = 2
        config.release.burst = 3
        config.release.maxInFlight = 4
        config.identity.userCooldownSeconds = 30
        config.ip.spacingSeconds = 0
        local calls = 0
        local q = Queue.new({
            now = function() return now end,
            config = config,
            onEvent = function(event)
                calls = calls + 1
                if event == 'admitted' then
                    error('injected metrics failure')
                end
            end,
        })
        q:fillBucket()
        for i = 1, 3 do
            assertTrue(q:enqueue({ sourceKey = tostring(i), ip = '198.51.100.' .. i, identitySet = identityFor('u' .. i), payload = {} }))
        end
        local results = q:tick()
        assertEqual(#results.admitted, 3, 'admissions must complete despite a throwing observer')
        assertEqual(q:status().inFlight, 3)
        assertEqual(q:status().queueSize, 0)
        assertEqual(q.eventCallbackErrors, 3)
        assertTrue(q.lastEventCallbackError:find('injected metrics failure', 1, true) ~= nil)
        assertTrue(calls >= 6, 'observer was still invoked for every event')
    end)

    test('queue cost stays bounded at a large backlog', function()
        -- Fill to ~1,000 waiting entries (about 40% of them retries of a recent
        -- identity) with admissions running, then assert that single operations
        -- and a batch expiry stay in the millisecond range. The bounds are
        -- deliberately loose (about 10x the measured cost) so slower CI hosts stay
        -- green; a quadratic or cubic regression fails them by orders of magnitude.
        local config = Util.deepCopy(Lavender.Defaults)
        config.identity.activeDuplicatePolicy = 'queue'
        config.identity.recentHistorySeconds = 300
        config.identity.userCooldownSeconds = 60
        config.queue.maxSize = 4096
        config.queue.maxWaitSeconds = 900
        config.release.maxInFlight = 180
        config.release.ratePerSecond = 20
        config.release.burst = 15
        config.release.inFlightTimeoutSeconds = 120
        config.ip.spacingSeconds = 1
        local now = 0
        local q = Queue.new({ config = config, now = function() return now end })
        math.randomseed(4242)
        local i = 0
        while q:status().queueSize < 959 do
            now = now + 0.2
            i = i + 1
            local base = 'p' .. i
            if i > 20 and i % 2 == 0 then base = 'p' .. (i - math.random(1, 20)) end
            q:enqueue({ sourceKey = tostring(i), ip = '198.51.100.' .. (i % 200 + 1), identitySet = identityFor(base), payload = {} })
            if i % 25 == 0 then
                for _, e in ipairs(q:tick().admitted) do
                    if e.id % 3 ~= 0 then q:completeInFlight(e.sourceKey) end
                end
            end
            assertTrue(i < 20000, 'fill did not converge')
        end
        local function cpu(fn)
            local s = os.clock()
            fn()
            return os.clock() - s
        end
        now = now + 1
        local enqueueCost = cpu(function() assertTrue(q:enqueue({ sourceKey = 'probe', ip = '198.51.100.7', identitySet = identityFor('p' .. (i - 3)), payload = {} })) end)
        local removeCost = cpu(function() assertTrue(q:remove('probe', 'disconnected')) end)
        local tickCost = cpu(function() q:tick() end)
        local entries = q:getEntries()
        table.sort(entries, function(a, b) return a.enqueuedAt < b.enqueuedAt end)
        config.queue.maxWaitSeconds = now - entries[96].enqueuedAt
        config.release.burst = 0
        local expired
        local expireCost = cpu(function() expired = #q:tick().queueTimeouts end)
        assertTrue(expired >= 96, 'expected a batch expiry of at least 96, got ' .. expired)
        assertTrue(enqueueCost < 0.05, ('enqueue at n=959 took %.3fs'):format(enqueueCost))
        assertTrue(removeCost < 0.05, ('remove at n=959 took %.3fs'):format(removeCost))
        assertTrue(tickCost < 0.05, ('tick at n=959 took %.3fs'):format(tickCost))
        assertTrue(expireCost < 0.20, ('batch expiry of %d at n=959 took %.3fs'):format(expired, expireCost))
    end)

    test('enqueue defers the queue-wide reconcile to the ticker (O(1) arrivals)', function()
        -- A mass reconnect is one enqueue per arrival on the game thread. If
        -- enqueue reconciled the whole queue each time, that path would be
        -- O(n^2) and stall svMain (the original failure). This asserts, without
        -- timing, that enqueue does NOT reconcile, that a frame reconciles at
        -- most once, and that an idle frame skips the reconcile entirely.
        local config = Util.deepCopy(Lavender.Defaults)
        config.identity.activeDuplicatePolicy = 'queue'
        config.identity.userCooldownSeconds = 60
        config.ip.spacingSeconds = 1
        config.queue.maxSize = 4096
        config.queue.maxWaitSeconds = 1e9
        config.release.ratePerSecond = 1
        config.release.burst = 0
        config.release.maxInFlight = 0 -- no admission, so the queue holds steady
        local now = 100
        local q = Queue.new({ config = config, now = function() return now end })

        local reconciles = 0
        local original = q._reconcileDelays
        q._reconcileDelays = function(self, ...) reconciles = reconciles + 1; return original(self, ...) end

        for i = 1, 200 do
            q:enqueue({ sourceKey = tostring(i), ip = '198.51.100.' .. (i % 200 + 1), identitySet = identityFor('p' .. i), payload = {} })
        end
        assertEqual(reconciles, 0, 'enqueue must not reconcile the whole queue; it defers to the ticker')
        assertTrue(q.dirty, 'enqueue marks the queue dirty for the next reconcile')

        q:tick()
        assertEqual(reconciles, 1, 'a dirty frame reconciles the whole queue exactly once')
        assertTrue(not q.dirty, 'the reconcile clears the dirty flag')

        q:tick()
        assertEqual(reconciles, 1, 'an idle frame (no arrivals, admissions, or expiries) skips the reconcile')
    end)

    test('a mass abandonment sweep reconciles once, not once per removed entry', function()
        -- The server emptying at once used to cost one full reconcile per
        -- departed player (O(n^2) on the game thread). sweepPresence batches the
        -- removals into one reconcile and still emits every 'removed' event.
        local config = Util.deepCopy(Lavender.Defaults)
        config.queue.maxSize = 4096
        config.queue.disconnectGraceSeconds = 5
        config.release.burst = 0
        config.release.maxInFlight = 0
        local now = 0
        local removedEvents = 0
        local q = Queue.new({ config = config, now = function() return now end,
            onEvent = function(event) if event == 'removed' then removedEvents = removedEvents + 1 end end })
        for i = 1, 500 do
            assertTrue(q:enqueue({ sourceKey = tostring(i), ip = '198.51.100.' .. (i % 200 + 1), identitySet = identityFor('p' .. i), payload = {} }))
        end
        q:tick() -- consume the enqueue dirtiness so the sweep's reconcile is measured alone

        local reconciles = 0
        local original = q._reconcileDelays
        q._reconcileDelays = function(self, ...) reconciles = reconciles + 1; return original(self, ...) end

        -- Everyone vanishes: first sweep only marks them missing (inside grace).
        local removed = q:sweepPresence(function() return false end)
        assertEqual(#removed, 0, 'within the grace nothing is removed')
        assertEqual(reconciles, 0, 'marking presence must not reconcile')
        -- Past the grace: all 500 go in ONE reconcile.
        now = 10
        removed = q:sweepPresence(function() return false end)
        assertEqual(#removed, 500, 'every abandoned entry is removed')
        assertEqual(reconciles, 1, 'a 500-entry abandonment reconciles exactly once')
        assertEqual(removedEvents, 500, 'each removal is still observable as an event')
        assertEqual(q:status().queueSize, 0)

        -- A present entry is untouched and its missingSince clears.
        local e = q:enqueue({ sourceKey = 'stay', ip = '198.51.100.9', identitySet = identityFor('stay'), payload = {} })
        e.missingSince = now
        q:sweepPresence(function() return true end)
        assertEqual(e.missingSince, nil, 'a present entry is cleared')
        assertEqual(q:status().queueSize, 1)
    end)

    test('a duplicate enqueue reports the cached wait estimate instead of rescanning the queue', function()
        local config = Util.deepCopy(Lavender.Defaults)
        config.identity.activeDuplicatePolicy = 'reject'
        config.queue.maxSize = 4096
        config.queue.maxWaitSeconds = 900
        config.release.ratePerSecond = 1
        config.release.burst = 0
        config.release.maxInFlight = 0
        local now = 0
        local q = Queue.new({ config = config, now = function() return now end })
        local first = q:enqueue({ sourceKey = 'a', ip = '198.51.100.1', identitySet = identityFor('dup'), payload = {} })
        assertTrue(first)
        q:reconcile() -- caches first.estimatedWait
        assertTrue(first.estimatedWait ~= nil, 'reconcile must cache the estimate')
        first.estimatedWait = 42 -- distinguishable from any live computation

        local scans = 0
        local liveEstimate = q.estimateWait
        q.estimateWait = function(self, entry) scans = scans + 1; return liveEstimate(self, entry) end

        local entry, reason, details = q:enqueue({ sourceKey = 'b', ip = '198.51.100.2', identitySet = identityFor('dup'), payload = {} })
        assertEqual(entry, nil)
        assertEqual(reason, 'duplicate')
        assertEqual(details.waitSeconds, 42, 'the rejection reports the cached estimate')
        assertEqual(scans, 0, 'no O(n) live estimate on the duplicate path')

        -- An entry enqueued in the same frame (not yet reconciled) falls back to
        -- the live estimate rather than reporting nothing.
        local fresh = q:enqueue({ sourceKey = 'c', ip = '198.51.100.3', identitySet = identityFor('fresh'), payload = {} })
        assertTrue(fresh)
        assertEqual(fresh.estimatedWait, nil, 'not yet reconciled')
        local _, r2, d2 = q:enqueue({ sourceKey = 'd', ip = '198.51.100.4', identitySet = identityFor('fresh'), payload = {} })
        assertEqual(r2, 'duplicate')
        assertTrue(d2.waitSeconds >= 0)
        assertEqual(scans, 1, 'the unreconciled case uses the live estimate once')
    end)

    test('a single identity cannot flood the queue past the configured cap', function()
        -- Without a cap, one identity opening many connections makes the
        -- reconcile pass O(n^2). The cap bounds the group, keeping the queue
        -- and the reconcile cheap. Excess attempts are rejected as
        -- 'duplicate_flood'.
        local config = Util.deepCopy(Lavender.Defaults)
        config.identity.activeDuplicatePolicy = 'queue'
        config.identity.maxActiveQueuedDuplicates = 5
        config.release.ratePerSecond = 1
        config.release.burst = 0
        config.release.maxInFlight = 0
        config.queue.maxSize = 10000
        local now = 0
        local q = Queue.new({ config = config, now = function() return now end })

        local identity = identityFor('FLOOD')
        local queued, flood = 0, 0
        for i = 1, 200 do
            local entry, reason = q:enqueue({ sourceKey = tostring(i), ip = '198.51.100.5', identitySet = identity, payload = {} })
            if entry then
                queued = queued + 1
            elseif reason == 'duplicate_flood' then
                flood = flood + 1
            end
        end

        assertEqual(queued, 5, 'at most the cap of same-identity connections may queue')
        assertEqual(flood, 195, 'every attempt past the cap is rejected as duplicate_flood')
        assertEqual(q:status().queueSize, 5)

        -- A different identity is unaffected by another identity's cap.
        local other = q:enqueue({ sourceKey = 'other', ip = '198.51.100.6', identitySet = identityFor('SEPARATE'), payload = {} })
        assertTrue(other, 'a distinct identity still queues normally')

        -- A cap of 0 disables the limit.
        config.identity.maxActiveQueuedDuplicates = 0
        local q2 = Queue.new({ config = config, now = function() return now end })
        for i = 1, 20 do
            q2:enqueue({ sourceKey = 'b' .. i, ip = '198.51.100.7', identitySet = identityFor('FLOOD2'), payload = {} })
        end
        assertEqual(q2:status().queueSize, 20, 'a cap of 0 disables the flood limit')
    end)
end
