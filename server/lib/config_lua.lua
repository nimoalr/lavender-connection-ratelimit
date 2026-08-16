Lavender = Lavender or {}

local ConfigLua = {}

local function literal(value)
    local valueType = type(value)
    if valueType == 'string' then
        return ('%q'):format(value)
    end
    if valueType == 'number' or valueType == 'boolean' then
        return tostring(value)
    end
    error(('cannot encode configuration value of type %s'):format(valueType))
end

local function arrayLiteral(values)
    local encoded = {}
    for i = 1, #values do
        encoded[i] = literal(values[i])
    end
    return '{ ' .. table.concat(encoded, ', ') .. ' }'
end

local function add(lines, value)
    lines[#lines + 1] = value
end

local function addField(lines, indent, comment, key, value)
    add(lines, indent .. '-- ' .. comment)
    add(lines, ('%s%s = %s,'):format(indent, key, literal(value)))
end

local function addArrayField(lines, indent, comment, key, value)
    add(lines, indent .. '-- ' .. comment)
    add(lines, ('%s%s = %s,'):format(indent, key, arrayLiteral(value)))
end

function ConfigLua.decode(raw, chunkName)
    if type(raw) ~= 'string' then
        error('configuration source must be a string')
    end

    local chunk, compileError = load(raw, chunkName or '@config.lua', 't', {})
    if not chunk then
        error(compileError, 0)
    end

    local ok, result = pcall(chunk)
    if not ok then
        error(result, 0)
    end
    if type(result) ~= 'table' then
        error('configuration file must return a table', 0)
    end

    return result
end

function ConfigLua.encode(config)
    local lines = {}

    add(lines, '-- Lavender Connection Rate Limiter configuration.')
    add(lines, '-- Runtime command edits regenerate this file and preserve these standard comments.')
    add(lines, '-- Custom comments and formatting are not preserved after a runtime edit.')
    add(lines, 'return {')
    addField(lines, '    ', 'Configuration schema version. Must remain 1.', 'version', config.version)
    add(lines, '')

    add(lines, '    -- Controls how queued connections are released into FXServer.')
    add(lines, '    release = {')
    addField(lines, '        ', 'Global admission tokens added per second. Use 0.1 for one every 10 seconds.', 'ratePerSecond', config.release.ratePerSecond)
    addField(lines, '        ', 'Maximum stored admission tokens, allowing short bursts up to this size.', 'burst', config.release.burst)
    addField(lines, '        ', 'Maximum released connections still loading before further admissions pause.', 'maxInFlight', config.release.maxInFlight)
    addField(lines, '        ', 'Seconds before an in-flight connection is cleared if playerJoining is not observed.', 'inFlightTimeoutSeconds', config.release.inFlightTimeoutSeconds)
    add(lines, '    },')
    add(lines, '')

    add(lines, '    -- Controls duplicate detection and pacing for matching non-IP identities.')
    add(lines, '    identity = {')
    addField(lines, '        ', 'Jaccard similarity from 0 to 1 required to consider two identity sets the same user.', 'similarityThreshold', config.identity.similarityThreshold)
    addField(lines, '        ', 'How active matching queued/joining attempts are handled: "queue" or "reject".', 'activeDuplicatePolicy', config.identity.activeDuplicatePolicy)
    addField(lines, '        ', 'Seconds a recently admitted matching user must wait before becoming eligible again.', 'userCooldownSeconds', config.identity.userCooldownSeconds)
    addField(lines, '        ', 'Seconds to retain recently admitted identity sets; must cover the user cooldown.', 'recentHistorySeconds', config.identity.recentHistorySeconds)
    add(lines, '    },')
    add(lines, '')

    add(lines, '    -- Priority identities that bypass Lavender queue, rate, cooldown, IP, and in-flight gates.')
    add(lines, '    priority = {')
    addArrayField(lines, '        ', 'Exact non-IP identifiers such as license:..., license2:..., discord:..., fivem:..., or token:....', 'identifiers', config.priority.identifiers)
    add(lines, '    },')
    add(lines, '')

    add(lines, '    -- Controls independent pacing for connections sharing an IP address.')
    add(lines, '    ip = {')
    addField(lines, '        ', 'Seconds between eligibility slots for one IP. IP alone never marks a duplicate.', 'spacingSeconds', config.ip.spacingSeconds)
    add(lines, '    },')
    add(lines, '')

    add(lines, '    -- Bounds queue size, waiting time, and disconnected-entry cleanup.')
    add(lines, '    queue = {')
    addField(lines, '        ', 'Maximum number of connections allowed to wait in the queue.', 'maxSize', config.queue.maxSize)
    addField(lines, '        ', 'Maximum seconds a connection may remain queued before rejection.', 'maxWaitSeconds', config.queue.maxWaitSeconds)
    addField(lines, '        ', 'Seconds a missing queued source is tolerated before removal.', 'disconnectGraceSeconds', config.queue.disconnectGraceSeconds)
    add(lines, '    },')
    add(lines, '')

    add(lines, '    -- Controls the queue status shown to connecting players.')
    add(lines, '    display = {')
    addField(lines, '        ', 'Show Adaptive Cards when true; use deferrals.update text when false.', 'adaptiveCards', config.display.adaptiveCards)
    addField(lines, '        ', 'Seconds between queue-card or fallback-text refreshes.', 'refreshSeconds', config.display.refreshSeconds)
    addField(lines, '        ', 'Heading displayed on the queue card and fallback status line.', 'title', config.display.title)
    addField(lines, '        ', 'Server name displayed beneath the queue heading.', 'serverName', config.display.serverName)
    add(lines, '    },')
    add(lines, '')

    add(lines, '    -- Optional Adaptive Card password gate applied to every connection.')
    add(lines, '    password = {')
    addField(lines, '        ', 'Require the shared password before any connection may queue or join.', 'enabled', config.password.enabled)
    addField(lines, '        ', 'Shared password. Must not be empty while enabled is true.', 'secret', config.password.secret)
    addField(lines, '        ', 'Password submissions allowed before the connection is rejected.', 'maxAttempts', config.password.maxAttempts)
    addField(lines, '        ', 'Seconds allowed for each password submission before rejection.', 'timeoutSeconds', config.password.timeoutSeconds)
    add(lines, '    },')
    add(lines, '')

    add(lines, '    -- Controls the public Prometheus-compatible resource HTTP route.')
    add(lines, '    metrics = {')
    addField(lines, '        ', 'Expose the metrics route when true.', 'enabled', config.metrics.enabled)
    addField(lines, '        ', 'Resource-local HTTP path. The public route also includes the resource name.', 'path', config.metrics.path)
    addField(lines, '        ', 'Prefix used for every emitted Prometheus metric name.', 'prefix', config.metrics.prefix)
    addArrayField(lines, '        ', 'Strictly increasing queue-wait histogram bucket boundaries in seconds.', 'waitBucketsSeconds', config.metrics.waitBucketsSeconds)
    add(lines, '    },')
    add(lines, '')

    add(lines, '    -- User-facing connection, rejection, timeout, and restart messages.')
    add(lines, '    messages = {')
    addField(lines, '        ', 'Initial text shown immediately after a connection enters the queue.', 'queued', config.messages.queued)
    addField(lines, '        ', 'Text shown immediately before Lavender releases the deferral.', 'joining', config.messages.joining)
    addField(lines, '        ', 'Rejection shown when a matching connection is already queued or in flight.', 'duplicate', config.messages.duplicate)
    addField(lines, '        ', 'Rejection shown when queue.maxSize has been reached.', 'queueFull', config.messages.queueFull)
    addField(lines, '        ', 'Rejection shown when queue.maxWaitSeconds has elapsed.', 'queueTimeout', config.messages.queueTimeout)
    addField(lines, '        ', 'Rejection shown when the deferral window appears to have been closed.', 'disconnected', config.messages.disconnected)
    addField(lines, '        ', 'Rejection shown to queued connections when this resource stops.', 'resourceStop', config.messages.resourceStop)
    addField(lines, '        ', 'Fallback rejection shown after an unexpected limiter error.', 'internalError', config.messages.internalError)
    addField(lines, '        ', 'Prompt shown on the password card when the password gate is enabled.', 'passwordPrompt', config.messages.passwordPrompt)
    addField(lines, '        ', 'Text shown after an incorrect password submission.', 'passwordIncorrect', config.messages.passwordIncorrect)
    addField(lines, '        ', 'Rejection shown when a password submission window elapses.', 'passwordTimeout', config.messages.passwordTimeout)
    add(lines, '    },')
    add(lines, '}')
    add(lines, '')

    return table.concat(lines, '\n')
end

Lavender.ConfigLua = ConfigLua
return ConfigLua
