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
end
