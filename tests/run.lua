Lavender = {}

dofile('server/lib/util.lua')
dofile('server/lib/defaults.lua')
dofile('server/lib/config.lua')
dofile('server/lib/config_lua.lua')
dofile('server/lib/config_store.lua')
dofile('server/lib/identity.lua')
dofile('server/lib/admission.lua')
dofile('server/lib/deferral.lua')
dofile('server/lib/queue.lua')
dofile('server/lib/card.lua')
dofile('server/lib/metrics.lua')
dofile('server/lib/http.lua')

local Json = dofile('tests/support/json.lua')
local Util = Lavender.Util
local Config = Lavender.Config
local ConfigLua = Lavender.ConfigLua
local ConfigStore = Lavender.ConfigStore
local Identity = Lavender.Identity
local Admission = Lavender.Admission
local Deferral = Lavender.Deferral
local Queue = Lavender.Queue
local Card = Lavender.Card
local Metrics = Lavender.Metrics
local Http = Lavender.Http

local tests = {}

local function test(name, callback)
    tests[#tests + 1] = { name = name, callback = callback }
end

local function assertEqual(actual, expected, message)
    if actual ~= expected then
        error(message or ('expected %s, got %s'):format(tostring(expected), tostring(actual)), 2)
    end
end

local function assertTrue(value, message)
    if not value then
        error(message or 'expected value to be truthy', 2)
    end
end

local function assertContains(value, expected, message)
    if not value:find(expected, 1, true) then
        error(message or ('expected %q to contain %q'):format(value, expected), 2)
    end
end

local function assertNotContains(value, unexpected, message)
    if value:find(unexpected, 1, true) then
        error(message or ('expected %q not to contain %q'):format(value, unexpected), 2)
    end
end

local function configWith(overrides)
    local config = Util.deepCopy(Lavender.Defaults)
    config.release.ratePerSecond = 100
    config.release.burst = 10
    config.release.maxInFlight = 10
    config.identity.userCooldownSeconds = 0
    config.ip.spacingSeconds = 0

    for path, value in pairs(overrides or {}) do
        assertTrue(Util.setExistingPath(config, path, value))
    end
    return config
end

local function identity(value)
    return Identity.fromRaw({ 'license:' .. value }, { 'token-' .. value })
end

local function candidate(value, ip)
    return {
        sourceKey = value,
        name = 'private-name-' .. value,
        identitySet = identity(value),
        ip = ip,
        payload = {},
    }
end

test('admission event carries the observed address and bounded TTL', function()
    local captured
    local emitted = Admission.emit(function(...)
        captured = { ... }
    end, '2001:db8::42')

    assertTrue(emitted)
    assertEqual(captured[1], 'lavender:admitted')
    assertEqual(captured[2], '2001:db8::42')
    assertEqual(captured[3], 120)
    assertEqual(#captured, 3)

    captured = nil
    assertEqual(Admission.emit(function(...) captured = { ... } end, nil), false)
    assertEqual(captured, nil)
end)

test('Jaccard identity matching honors the 80 percent threshold and excludes IPs', function()
    local left = Identity.fromRaw(
        { 'license:a', 'license2:b', 'discord:c', 'ip:192.0.2.1' },
        { 'one', 'two' }
    )
    local right = Identity.fromRaw(
        { 'license:a', 'license2:b', 'discord:c', 'ip:198.51.100.2' },
        { 'one' }
    )

    assertEqual(Identity.similarity(left, right), 0.8)
    assertTrue(Identity.matches(left, right, 0.8))
    assertEqual(Identity.extractIp({ 'ip:203.0.113.4' }, nil), '203.0.113.4')
end)

test('priority identifiers match non-IP identifiers and tokens exactly', function()
    local set = Identity.fromRaw(
        { 'license:AdminOne', 'discord:1234', 'ip:203.0.113.4' },
        { 'TokenOne' }
    )

    assertTrue(Identity.matchesPriority(set, { 'license:adminone' }))
    assertTrue(Identity.matchesPriority(set, { 'identifier:discord:1234' }))
    assertTrue(Identity.matchesPriority(set, { 'token:tokenone' }))
    assertEqual(Identity.matchesPriority(set, { 'license:someoneelse' }), false)
    assertEqual(Identity.normalizePriorityIdentifier('ip:203.0.113.4'), nil)
end)

test('active duplicate identities are rejected when configured', function()
    local now = 0
    local queue = Queue.new({
        now = function() return now end,
        config = configWith({ ['identity.activeDuplicatePolicy'] = 'reject' }),
    })

    assertTrue(queue:enqueue(candidate('a', '192.0.2.1')))
    local duplicate, reason, details = queue:enqueue({
        sourceKey = 'other-source',
        identitySet = identity('a'),
        ip = '198.51.100.1',
        payload = {},
    })

    assertEqual(duplicate, nil)
    assertEqual(reason, 'duplicate')
    assertEqual(details.state, 'queued')
    assertTrue(details.waitSeconds >= 0)
end)

test('active duplicate rejection reports queued and joining retry windows', function()
    local now = 0
    local queue = Queue.new({
        now = function() return now end,
        config = configWith({
            ['release.ratePerSecond'] = 1,
            ['release.burst'] = 1,
            ['release.maxInFlight'] = 1,
            ['release.inFlightTimeoutSeconds'] = 120,
            ['identity.activeDuplicatePolicy'] = 'reject',
        }),
    })

    queue:enqueue(candidate('a'))
    queue:enqueue(candidate('b'))

    local duplicate, reason, details = queue:enqueue({
        sourceKey = 'duplicate-while-queued',
        identitySet = identity('b'),
        payload = {},
    })
    assertEqual(duplicate, nil)
    assertEqual(reason, 'duplicate')
    assertEqual(details.state, 'queued')
    assertTrue(details.waitSeconds >= 0)

    local admitted = queue:tick().admitted[1]
    duplicate, reason, details = queue:enqueue({
        sourceKey = 'duplicate-while-joining',
        identitySet = admitted.identitySet,
        payload = {},
    })
    assertEqual(duplicate, nil)
    assertEqual(reason, 'duplicate')
    assertEqual(details.state, 'joining')
    assertEqual(details.waitSeconds, 120)
end)

test('active duplicate attempts queue behind queued and joining matches by default', function()
    local now = 0
    local queue = Queue.new({
        now = function() return now end,
        config = configWith({ ['identity.userCooldownSeconds'] = 60 }),
    })

    queue:enqueue(candidate('a'))
    local duplicate = queue:enqueue({
        sourceKey = 'duplicate-while-queued',
        identitySet = identity('a'),
        payload = {},
    })
    assertTrue(duplicate ~= nil)
    assertEqual(duplicate.duplicateState, 'queued')

    local reason, remaining = queue:getEntryReason(duplicate)
    assertEqual(reason, 'active_duplicate')
    assertEqual(Util.round(remaining), 60)

    local admitted = queue:tick().admitted
    assertEqual(#admitted, 1)
    assertEqual(admitted[1].sourceKey, 'a')
    queue:completeInFlight('a')

    now = 59
    assertEqual(#queue:tick().admitted, 0)
    now = 60
    assertEqual(queue:tick().admitted[1].sourceKey, 'duplicate-while-queued')

    queue:completeInFlight('duplicate-while-queued')
    now = 120
    queue:enqueue(candidate('b'))
    assertEqual(queue:tick().admitted[1].sourceKey, 'b')

    now = 130
    local joiningDuplicate = queue:enqueue({
        sourceKey = 'duplicate-while-joining',
        identitySet = identity('b'),
        payload = {},
    })
    assertTrue(joiningDuplicate ~= nil)
    assertEqual(joiningDuplicate.duplicateState, 'joining')
    reason, remaining = queue:getEntryReason(joiningDuplicate)
    assertEqual(reason, 'active_duplicate')
    assertEqual(Util.round(remaining), 50)
end)

test('active duplicate delays recalculate when matching queued attempts are removed', function()
    local now = 0
    local queue = Queue.new({
        now = function() return now end,
        config = configWith({ ['identity.userCooldownSeconds'] = 60 }),
    })

    queue:enqueue(candidate('a'))
    local second = queue:enqueue({
        sourceKey = 'second-source',
        identitySet = identity('a'),
        payload = {},
    })
    local third = queue:enqueue({
        sourceKey = 'third-source',
        identitySet = identity('a'),
        payload = {},
    })

    local reason, remaining = queue:getEntryReason(second)
    assertEqual(reason, 'active_duplicate')
    assertEqual(Util.round(remaining), 60)

    reason, remaining = queue:getEntryReason(third)
    assertEqual(reason, 'active_duplicate')
    assertEqual(Util.round(remaining), 120)

    assertEqual(queue:remove('a', 'disconnected').sourceKey, 'a')

    reason, remaining = queue:getEntryReason(second)
    assertEqual(reason, 'ready')
    assertEqual(Util.round(remaining), 0)

    reason, remaining = queue:getEntryReason(third)
    assertEqual(reason, 'active_duplicate')
    assertEqual(Util.round(remaining), 60)

    assertEqual(queue:remove('second-source', 'disconnected').sourceKey, 'second-source')
    reason, remaining = queue:getEntryReason(third)
    assertEqual(reason, 'ready')
    assertEqual(Util.round(remaining), 0)
end)

test('token bucket and in-flight cap both gate releases', function()
    local now = 0
    local config = configWith({
        ['release.ratePerSecond'] = 1,
        ['release.burst'] = 1,
        ['release.maxInFlight'] = 1,
    })
    local queue = Queue.new({ now = function() return now end, config = config })
    queue:enqueue(candidate('a'))
    queue:enqueue(candidate('b'))

    local first = queue:tick()
    assertEqual(#first.admitted, 1)
    assertEqual(first.admitted[1].sourceKey, 'a')

    now = 10
    assertEqual(#queue:tick().admitted, 0)
    queue:completeInFlight('a')
    assertEqual(queue:tick().admitted[1].sourceKey, 'b')
end)

test('in-flight entries clear on playerJoining oldID or disconnected presence', function()
    local now = 0
    local queue = Queue.new({
        now = function() return now end,
        config = configWith({
            ['release.ratePerSecond'] = 1,
            ['release.burst'] = 1,
            ['release.maxInFlight'] = 1,
            ['queue.disconnectGraceSeconds'] = 5,
        }),
    })

    queue:enqueue(candidate('a'))
    assertEqual(queue:tick().admitted[1].sourceKey, 'a')
    assertEqual(queue:completeInFlight('a').sourceKey, 'a')

    queue:enqueue(candidate('b'))
    now = 1
    assertEqual(queue:tick().admitted[1].sourceKey, 'b')
    assertEqual(queue:updateInFlightPresence('b', false), nil)
    now = 5
    assertEqual(queue:updateInFlightPresence('b', false), nil)
    now = 6
    assertEqual(queue:updateInFlightPresence('b', false).sourceKey, 'b')
end)

test('startup fill uses the configured burst while live changes preserve tokens', function()
    local now = 0
    local queue = Queue.new({
        now = function() return now end,
        config = configWith({
            ['release.ratePerSecond'] = 1,
            ['release.burst'] = 1,
        }),
    })

    queue:setConfig(configWith({
        ['release.ratePerSecond'] = 1,
        ['release.burst'] = 4,
    }))
    assertEqual(queue:status().tokens, 1)

    queue:fillBucket()
    assertEqual(queue:status().tokens, 4)

    queue:setConfig(configWith({
        ['release.ratePerSecond'] = 1,
        ['release.burst'] = 8,
    }))
    assertEqual(queue:status().tokens, 4)
end)

test('eligible FIFO skips an IP-delayed connection without losing its place', function()
    local now = 0
    local queue = Queue.new({
        now = function() return now end,
        config = configWith({ ['ip.spacingSeconds'] = 5 }),
    })

    queue:enqueue(candidate('a', '192.0.2.1'))
    local delayed = queue:enqueue(candidate('b', '192.0.2.1'))
    queue:enqueue(candidate('c', '198.51.100.1'))

    local first = queue:tick()
    assertEqual(#first.admitted, 2)
    assertEqual(first.admitted[1].sourceKey, 'a')
    assertEqual(first.admitted[2].sourceKey, 'c')
    assertEqual(queue:getPosition(delayed.id), 1)

    now = 5
    assertEqual(queue:tick().admitted[1].sourceKey, 'b')
end)

test('IP pacing delays recalculate when queued attempts are removed', function()
    local now = 0
    local queue = Queue.new({
        now = function() return now end,
        config = configWith({ ['ip.spacingSeconds'] = 60 }),
    })

    queue:enqueue(candidate('a', '192.0.2.1'))
    local second = queue:enqueue(candidate('b', '192.0.2.1'))
    local third = queue:enqueue(candidate('c', '192.0.2.1'))

    local reason, remaining = queue:getEntryReason(second)
    assertEqual(reason, 'ip_pacing')
    assertEqual(Util.round(remaining), 60)

    reason, remaining = queue:getEntryReason(third)
    assertEqual(reason, 'ip_pacing')
    assertEqual(Util.round(remaining), 120)

    assertEqual(queue:remove('a', 'disconnected').sourceKey, 'a')

    reason, remaining = queue:getEntryReason(second)
    assertEqual(reason, 'ready')
    assertEqual(Util.round(remaining), 0)

    reason, remaining = queue:getEntryReason(third)
    assertEqual(reason, 'ip_pacing')
    assertEqual(Util.round(remaining), 60)
end)

test('recent matching users wait out cooldown while other users pass', function()
    local now = 0
    local queue = Queue.new({
        now = function() return now end,
        config = configWith({ ['identity.userCooldownSeconds'] = 60 }),
    })

    queue:enqueue(candidate('a'))
    queue:tick()
    queue:completeInFlight('a')

    now = 10
    local retry = queue:enqueue(candidate('a'))
    queue:enqueue(candidate('b'))
    local admitted = queue:tick().admitted
    assertEqual(#admitted, 1)
    assertEqual(admitted[1].sourceKey, 'b')
    assertEqual(queue:getPosition(retry.id), 1)

    now = 60
    assertEqual(queue:tick().admitted[1].sourceKey, 'a')
end)

test('wait estimates include cooldown plus slow global token refill', function()
    local now = 0
    local queue = Queue.new({
        now = function() return now end,
        config = configWith({
            ['release.ratePerSecond'] = 0.01,
            ['release.burst'] = 1,
            ['identity.userCooldownSeconds'] = 60,
            ['ip.spacingSeconds'] = 60,
        }),
    })

    queue:enqueue(candidate('a', '192.0.2.1'))
    assertEqual(queue:tick().admitted[1].sourceKey, 'a')
    queue:completeInFlight('a')

    now = 34
    local retry = queue:enqueue(candidate('a', '192.0.2.1'))
    assertEqual(Util.round(queue:estimateWait(retry)), 66)

    local reason, remaining = queue:getEntryReason(retry)
    assertEqual(reason, 'user_cooldown')
    assertEqual(Util.round(remaining), 26)

    now = 60
    reason, remaining = queue:getEntryReason(retry)
    assertEqual(reason, 'global_rate')
    assertEqual(Util.round(remaining), 40)
    assertEqual(Util.round(queue:estimateWait(retry)), 40)

    now = 100
    assertEqual(queue:tick().admitted[1].sourceKey, 'a')
end)

test('disconnect grace and queue timeout remove waiting entries', function()
    local now = 0
    local queue = Queue.new({
        now = function() return now end,
        config = configWith({
            ['queue.disconnectGraceSeconds'] = 5,
            ['queue.maxWaitSeconds'] = 10,
        }),
    })

    queue:enqueue(candidate('disconnect'))
    assertEqual(queue:updatePresence('disconnect', false), nil)
    now = 4
    assertEqual(queue:updatePresence('disconnect', false), nil)
    now = 5
    assertEqual(queue:updatePresence('disconnect', false).sourceKey, 'disconnect')

    queue:enqueue(candidate('timeout'))
    now = 15
    assertEqual(queue:tick().queueTimeouts[1].sourceKey, 'timeout')
end)

test('deferral serializer waits a tick before every operation', function()
    local tick = 0
    local actions = {}
    local object = {
        update = function() actions[#actions + 1] = { method = 'update', tick = tick } end,
        presentCard = function() actions[#actions + 1] = { method = 'presentCard', tick = tick } end,
        done = function() actions[#actions + 1] = { method = 'done', tick = tick } end,
    }
    local state = Deferral.new(object, function() tick = tick + 1 end)

    assertTrue(Deferral.call(state, 'update', 'queued'))
    assertTrue(Deferral.call(state, 'presentCard', {}))
    assertTrue(Deferral.call(state, 'done'))
    assertEqual(actions[1].tick, 1)
    assertEqual(actions[2].tick, 2)
    assertEqual(actions[3].tick, 3)
    assertEqual(Deferral.call(state, 'update', 'late'), false)

    local file = assert(io.open('server/main.lua', 'r'))
    local source = file:read('*a')
    file:close()
    assertTrue(source:match('deferrals%.defer%(%)%s*Wait%(0%)') ~= nil, 'initial defer must be followed by Wait(0)')
    assertTrue(source:find('DoesPlayerExist', 1, true) == nil, 'queued deferral cleanup must not depend on joined-player presence')
    assertTrue(source:find('GetPlayerEndpoint', 1, true) ~= nil, 'queued deferral cleanup should treat endpoint presence as connected')
    assertTrue(source:find('queue:updateInFlightPresence', 1, true) == nil, 'in-flight entries must be cleared by playerJoining or timeout')
end)

test('FX deferral wrapper uses direct methods and supports callable members', function()
    local tick = 0
    local actions = {}
    local callableDone = setmetatable({}, {
        __call = function(_, message)
            actions[#actions + 1] = { method = 'done', message = message, tick = tick }
        end,
    })
    local fxObject = {
        update = function(message)
            actions[#actions + 1] = { method = 'update', message = message, tick = tick }
        end,
        presentCard = function(card)
            actions[#actions + 1] = { method = 'presentCard', message = card.type, tick = tick }
        end,
        done = callableDone,
    }

    local state = Deferral.fromFx(fxObject, function() tick = tick + 1 end)
    assertTrue(Deferral.call(state, 'update', 'queued'))
    assertTrue(Deferral.call(state, 'presentCard', { type = 'AdaptiveCard' }))
    assertTrue(Deferral.call(state, 'done', 'finished'))
    assertEqual(actions[1].method, 'update')
    assertEqual(actions[2].method, 'presentCard')
    assertEqual(actions[3].method, 'done')
    assertEqual(actions[3].message, 'finished')
end)

test('FX deferral wrapper does not pass nil for successful done', function()
    local doneArgCount
    local doneMessage
    local state = Deferral.fromFx({
        update = function() end,
        presentCard = function() end,
        done = function(...)
            doneArgCount = select('#', ...)
            doneMessage = select(1, ...)
        end,
    }, function() end)

    assertTrue(Deferral.call(state, 'done'))
    assertEqual(doneArgCount, 0)
    assertEqual(doneMessage, nil)
end)

test('configuration validation and persistence are transactional', function()
    local active
    local writes = 0
    local writeAllowed = true
    local raw = 'valid'

    local store = ConfigStore.new({
        defaults = Lavender.Defaults,
        read = function() return raw end,
        write = function()
            writes = writes + 1
            return writeAllowed
        end,
        decode = function(value)
            if value ~= 'valid' then error('bad configuration') end
            return Util.deepCopy(Lavender.Defaults)
        end,
        encode = function() return 'encoded' end,
        onApply = function(value) active = value end,
    })

    assertTrue(store:loadStartup())
    assertTrue(store:set('release.ratePerSecond', 2))
    assertEqual(active.release.ratePerSecond, 2)
    assertEqual(writes, 1)

    assertEqual(store:set('release.burst', 0), false)
    assertEqual(active.release.burst, 1)
    assertEqual(writes, 1)

    writeAllowed = false
    assertEqual(store:set('release.burst', 3), false)
    assertEqual(active.release.burst, 1)

    writeAllowed = function()
        error('disk failure')
    end
    store.write = writeAllowed
    assertEqual(store:set('release.burst', 3), false)
    assertEqual(active.release.burst, 1)

    raw = 'invalid'
    assertEqual(store:reload(), false)
    assertEqual(active.release.ratePerSecond, 2)

    store.read = function()
        error('read failure')
    end
    assertEqual(store:reload(), false)
    assertEqual(active.release.ratePerSecond, 2)
end)

test('Lua configuration codec preserves standard comments and round-trips values', function()
    local encoded = ConfigLua.encode(Lavender.Defaults)
    assertContains(encoded, '-- Global admission tokens added per second.')
    assertContains(encoded, '-- Custom comments and formatting are not preserved after a runtime edit.')

    local decoded = ConfigLua.decode(encoded, '@generated-config.lua')
    local valid, errors = Config.validate(decoded)
    assertTrue(valid, table.concat(errors, '; '))
    assertEqual(decoded.release.ratePerSecond, 0.1)
    assertEqual(decoded.identity.activeDuplicatePolicy, 'queue')
    assertEqual(#decoded.priority.identifiers, 0)
    assertEqual(decoded.display.title, 'Connection Queue')
    assertEqual(decoded.messages.disconnected, 'The connection window was closed. Please reconnect.')
    assertEqual(decoded.metrics.waitBucketsSeconds[9], 900)

    local environmentEscape = pcall(ConfigLua.decode, 'return { value = os.time() }', '@unsafe-config.lua')
    assertEqual(environmentEscape, false)
end)

test('runtime edits persist a complete commented Lua configuration', function()
    local raw = ConfigLua.encode(Lavender.Defaults)
    local store = ConfigStore.new({
        defaults = Lavender.Defaults,
        read = function() return raw end,
        write = function(_, value)
            raw = value
            return true
        end,
        decode = ConfigLua.decode,
        encode = ConfigLua.encode,
    })

    assertTrue(store:loadStartup())
    assertTrue(store:set('release.ratePerSecond', 2))
    assertContains(raw, '-- Global admission tokens added per second.')
    assertContains(raw, 'ratePerSecond = 2,')

    local persisted = ConfigLua.decode(raw, '@persisted-config.lua')
    assertEqual(persisted.release.ratePerSecond, 2)
    assertEqual(persisted.messages.internalError, Lavender.Defaults.messages.internalError)
end)

test('configuration validation rejects non-finite Lua numbers', function()
    local candidateConfig = Util.deepCopy(Lavender.Defaults)
    candidateConfig.release.ratePerSecond = 0 / 0
    assertEqual(Config.validate(candidateConfig), false)

    candidateConfig.release.ratePerSecond = math.huge
    assertEqual(Config.validate(candidateConfig), false)
end)

test('configuration validation rejects unsafe priority identifiers', function()
    local candidateConfig = Util.deepCopy(Lavender.Defaults)
    candidateConfig.priority.identifiers = { 'license:admin', 'discord:1234', 'token:abcd' }
    assertEqual(Config.validate(candidateConfig), true)

    candidateConfig.priority.identifiers = { 'ip:203.0.113.4' }
    assertEqual(Config.validate(candidateConfig), false)

    candidateConfig.priority.identifiers = { 'license:admin', 'LICENSE:ADMIN' }
    assertEqual(Config.validate(candidateConfig), false)

    candidateConfig.priority.identifiers = { 'not-an-identifier' }
    assertEqual(Config.validate(candidateConfig), false)
end)

test('configuration validation enforces password gate constraints', function()
    local candidateConfig = Util.deepCopy(Lavender.Defaults)
    assertEqual(Config.validate(candidateConfig), true)

    candidateConfig.password.enabled = true
    assertEqual(Config.validate(candidateConfig), false, 'enabled gate must require a secret')

    candidateConfig.password.secret = 'hunter2'
    assertEqual(Config.validate(candidateConfig), true)

    candidateConfig.password.secret = ('x'):rep(129)
    assertEqual(Config.validate(candidateConfig), false)

    candidateConfig.password.secret = 'hunter2'
    candidateConfig.password.maxAttempts = 0
    assertEqual(Config.validate(candidateConfig), false)

    candidateConfig.password.maxAttempts = 3
    candidateConfig.password.timeoutSeconds = 1
    assertEqual(Config.validate(candidateConfig), false)
end)

test('all shipped configuration profiles validate', function()
    local expected = {
        ['profiles/development.lua'] = { 0.1, 1, 1 },
        ['profiles/playtest.lua'] = { 0.1, 1, 100 },
        ['profiles/conservative.lua'] = { 1, 2, 6 },
        ['profiles/balanced.lua'] = { 2, 4, 12 },
        ['profiles/high-throughput.lua'] = { 5, 10, 30 },
    }

    do
        local file = assert(io.open('config.lua', 'r'))
        local decoded = ConfigLua.decode(file:read('*a'), '@config.lua')
        file:close()
        local valid, errors = Config.validate(decoded)
        assertTrue(valid, 'config.lua: ' .. table.concat(errors, '; '))
        assertEqual(
            ConfigLua.encode(decoded),
            ConfigLua.encode(Lavender.Defaults),
            'config.lua must ship with the neutral embedded defaults'
        )
    end

    for path, release in pairs(expected) do
        local file = assert(io.open(path, 'r'))
        local raw = file:read('*a')
        local decoded = ConfigLua.decode(raw, '@' .. path)
        file:close()

        assertContains(raw, '-- Controls how queued connections are released into FXServer.', path)
        assertContains(raw, '-- Priority identities that bypass Lavender queue, rate, cooldown, IP, and in-flight gates.', path)
        assertContains(raw, '-- User-facing connection, rejection, timeout, and restart messages.', path)

        local valid, errors = Config.validate(decoded)
        assertTrue(valid, path .. ': ' .. table.concat(errors, '; '))
        assertEqual(decoded.release.ratePerSecond, release[1])
        assertEqual(decoded.release.burst, release[2])
        assertEqual(decoded.release.maxInFlight, release[3])
    end
end)

test('adaptive card and fallback expose queue status without identity data', function()
    local now = 0
    local config = configWith({ ['release.burst'] = 1 })
    local queue = Queue.new({ now = function() return now end, config = config })
    local entry = queue:enqueue(candidate('secret-license', '203.0.113.9'))

    local card = Card.build(entry, queue, config, { playersOnlineText = '12 / 128' })
    assertEqual(card.type, 'AdaptiveCard')
    local fallback = Card.fallbackMessage(entry, queue, config, { playersOnlineText = '12 / 128' })
    assertContains(fallback, 'Position 1/1')
    assertContains(fallback, 'Players online 12 / 128')
    assertEqual(card.body[3].items[1].facts[4].title, 'Players online')
    assertEqual(card.body[3].items[1].facts[4].value, '12 / 128')
    assertNotContains(fallback, 'secret-license')
    assertNotContains(fallback, '203.0.113.9')
end)

test('password card collects input via submit action and never embeds the secret', function()
    local config = Util.deepCopy(Lavender.Defaults)
    config.password.enabled = true
    config.password.secret = 'card-secret'

    local card = Card.buildPasswordPrompt(config, { showError = false, attemptsRemaining = 3 })
    assertEqual(card.type, 'AdaptiveCard')
    assertEqual(card.actions[1].type, 'Action.Submit')

    local input
    local errorLine = false
    for i = 1, #card.body do
        if card.body[i].type == 'Input.Text' then
            input = card.body[i]
        end
        if card.body[i].text == config.messages.passwordIncorrect then
            errorLine = true
        end
    end
    assertTrue(input ~= nil, 'password card must contain a text input')
    assertEqual(input.id, 'password')
    assertEqual(errorLine, false, 'first prompt must not show the incorrect-password line')

    local retry = Card.buildPasswordPrompt(config, { showError = true, attemptsRemaining = 2 })
    local retryError = false
    for i = 1, #retry.body do
        if retry.body[i].text == config.messages.passwordIncorrect then
            retryError = true
        end
    end
    assertTrue(retryError, 'retry prompt must show the incorrect-password line')

    local encoded = Json.encode and Json.encode(card) or nil
    if encoded then
        assertNotContains(encoded, 'card-secret')
    end
end)

test('FX deferral wrapper forwards the presentCard submit callback', function()
    local captured
    local state = Deferral.fromFx({
        update = function() end,
        presentCard = function(card, callback)
            captured = { card = card, callback = callback }
        end,
        done = function() end,
    }, function() end)

    local submitted
    assertTrue(Deferral.call(state, 'presentCard', { type = 'AdaptiveCard' }, function(data)
        submitted = data.password
    end))
    assertTrue(type(captured.callback) == 'function')
    captured.callback({ password = 'hunter2' })
    assertEqual(submitted, 'hunter2')
end)

test('Prometheus output is valid-shaped, low-cardinality, and ends with newline', function()
    local config = configWith()
    local metrics = Metrics.new(config)
    metrics:recordAttempt()
    metrics:recordRejection('duplicate')
    metrics:recordQueueEvent('admitted', {
        enqueuedAt = 0,
        admittedAt = 2,
        name = 'private-name',
        ip = '203.0.113.9',
        identitySet = { ['identifier:license:secret'] = true },
    })

    local body = metrics:render({
        queueSize = 1,
        eligibleQueueSize = 1,
        inFlight = 1,
    })

    assertContains(body, '# TYPE lavender_connection_ratelimit_connection_attempts_total counter')
    assertContains(body, 'lavender_connection_ratelimit_rejections_total{reason="duplicate"} 1')
    assertContains(body, 'lavender_connection_ratelimit_queue_wait_seconds_bucket{le="+Inf"} 1')
    assertEqual(body:sub(-1), '\n')
    assertNotContains(body, 'private-name')
    assertNotContains(body, '203.0.113.9')
    assertNotContains(body, 'secret')
end)

test('metrics HTTP handler returns 200, 404, 405, and 500 correctly', function()
    local config = { enabled = true, path = '/metrics' }
    local renderFails = false
    local handler = Http.metricsHandler(
        function() return config end,
        function()
            if renderFails then error('boom') end
            return 'metric 1\n'
        end
    )

    local function request(method, path)
        local result = {}
        handler({ method = method, path = path }, {
            writeHead = function(status, headers)
                result.status = status
                result.headers = headers
            end,
            send = function(body)
                result.body = body
            end,
        })
        return result
    end

    assertEqual(request('GET', '/metrics').status, 200)
    assertEqual(request('GET', '/missing').status, 404)
    assertEqual(request('POST', '/metrics').status, 405)
    renderFails = true
    assertEqual(request('GET', '/metrics').status, 500)
end)

test('FXServer entrypoint loads and registers its public interfaces', function()
    local handlers = {}
    local threads = {}
    local httpHandler
    local registeredCommand
    local triggeredEvent
    local admissionOrder = {}

    GetCurrentResourceName = function() return 'lavender-test' end
    GetGameTimer = function() return 0 end
    LoadResourceFile = function(_, path)
        local file = assert(io.open(path, 'r'))
        local raw = file:read('*a')
        file:close()
        return raw
    end
    SaveResourceFile = function() return true end
    AddEventHandler = function(name, callback) handlers[name] = callback end
    CreateThread = function(callback) threads[#threads + 1] = callback end
    Wait = function() end
    SetHttpHandler = function(callback) httpHandler = callback end
    RegisterCommand = function(name, callback, restricted)
        registeredCommand = {
            name = name,
            callback = callback,
            restricted = restricted,
        }
    end
    TriggerEvent = function(...)
        triggeredEvent = { ... }
        admissionOrder[#admissionOrder + 1] = 'event'
    end
    json = {
        decode = Json.decode,
        encode = function() return '{}' end,
    }

    dofile('server/main.lua')

    assertTrue(type(handlers.playerConnecting) == 'function')
    assertTrue(type(handlers.playerJoining) == 'function')
    assertTrue(type(handlers.playerDropped) == 'function')
    assertTrue(type(handlers.onResourceStop) == 'function')
    assertEqual(#threads, 2)
    assertTrue(type(httpHandler) == 'function')
    assertEqual(registeredCommand.name, 'lavender_rl')
    assertEqual(registeredCommand.restricted, true)

    registeredCommand.callback(0, { 'priority', 'list' })
    registeredCommand.callback(0, { 'priority', 'add', 'license:test-admin' })

    GetPlayerIdentifiers = function()
        return { 'license:test-admin', 'ip:198.51.100.42' }
    end
    GetNumPlayerTokens = function() return 0 end
    GetPlayerEndpoint = function() return '198.51.100.42:30120' end
    source = 42
    handlers.playerConnecting('test player', nil, {
        defer = function()
            admissionOrder[#admissionOrder + 1] = 'defer'
        end,
        done = function()
            admissionOrder[#admissionOrder + 1] = 'done'
        end,
    })

    assertEqual(triggeredEvent[1], 'lavender:admitted')
    assertEqual(triggeredEvent[2], '198.51.100.42')
    assertEqual(triggeredEvent[3], 120)
    assertEqual(table.concat(admissionOrder, ','), 'defer,event,done')

    registeredCommand.callback(0, { 'priority', 'remove', 'license:test-admin' })
    registeredCommand.callback(0, { 'priority', 'add', 'ip:203.0.113.4' })
end)

local passed = 0
for i = 1, #tests do
    local current = tests[i]
    local ok, err = pcall(current.callback)
    if ok then
        passed = passed + 1
        print(('ok %d - %s'):format(i, current.name))
    else
        print(('not ok %d - %s'):format(i, current.name))
        print(err)
    end
end

print(('%d/%d tests passed'):format(passed, #tests))
if passed ~= #tests then
    error('test suite failed')
end
