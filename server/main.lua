local Util = Lavender.Util
local ConfigStore = Lavender.ConfigStore
local ConfigLua = Lavender.ConfigLua
local Identity = Lavender.Identity
local Admission = Lavender.Admission
local Deferral = Lavender.Deferral
local Queue = Lavender.Queue
local Card = Lavender.Card
local Metrics = Lavender.Metrics
local Http = Lavender.Http

local resourceName = GetCurrentResourceName()
local prefix = ('[%s]'):format(resourceName)

local function log(message)
    print(('%s %s'):format(prefix, message))
end

local function logErrors(heading, errors)
    log(('^1%s^7'):format(heading))
    for i = 1, #(errors or {}) do
        log(('^1- %s^7'):format(errors[i]))
    end
end

-- Keep a monotonic clock across GetGameTimer resets/wraps.
local previousGameTimer = GetGameTimer()
local monotonicSeconds = 0

local function nowSeconds()
    local current = GetGameTimer()
    local delta = current - previousGameTimer
    if delta < 0 then
        delta = 0
    end
    previousGameTimer = current
    monotonicSeconds = monotonicSeconds + (delta / 1000)
    return monotonicSeconds
end

local activeConfig = Util.deepCopy(Lavender.Defaults)
local metrics = Metrics.new(activeConfig)
local queue
local firstConfigApply = true

queue = Queue.new({
    now = nowSeconds,
    config = activeConfig,
    onEvent = function(event, data)
        metrics:recordQueueEvent(event, data)
    end,
})

local configStore = ConfigStore.new({
    path = 'config.lua',
    defaults = Lavender.Defaults,
    read = function(path)
        return LoadResourceFile(resourceName, path)
    end,
    write = function(path, data)
        return SaveResourceFile(resourceName, path, data, -1)
    end,
    decode = function(raw)
        return ConfigLua.decode(raw, '@config.lua')
    end,
    encode = function(value)
        return ConfigLua.encode(value)
    end,
    onApply = function(config)
        activeConfig = config
        metrics:setConfig(config)
        queue:setConfig(config)
        if firstConfigApply then
            queue:fillBucket()
            firstConfigApply = false
        end
    end,
})

local loaded, startupErrors = configStore:loadStartup()
if not loaded then
    logErrors('config.lua is invalid; using embedded development-safe defaults.', startupErrors)
else
    log('Loaded config.lua.')
end

local function safePlayerIdentifiers(sourceKey)
    local ok, identifiers = pcall(GetPlayerIdentifiers, sourceKey)
    if ok and type(identifiers) == 'table' then
        return identifiers
    end
    return {}
end

local function safePlayerTokens(sourceKey)
    local tokens = {}
    local countOk, count = pcall(GetNumPlayerTokens, sourceKey)
    if not countOk or type(count) ~= 'number' then
        return tokens
    end

    for index = 0, count - 1 do
        local tokenOk, token = pcall(GetPlayerToken, sourceKey, index)
        if tokenOk and type(token) == 'string' and token ~= '' then
            tokens[#tokens + 1] = token
        end
    end
    return tokens
end

local function safePlayerEndpoint(sourceKey)
    local ok, endpoint = pcall(GetPlayerEndpoint, sourceKey)
    if ok and type(endpoint) == 'string' and endpoint ~= '' then
        return endpoint
    end
    return nil
end

-- Notify server-local integrations without writing the player address to the console.
local function emitAdmission(ip, path)
    if not Admission.emit(TriggerEvent, ip) then
        log(('Admission event not emitted: path=%s reason=missing_endpoint'):format(path))
        return false
    end
    log(('Admission event emitted: path=%s ttl=%d'):format(path, Admission.ttlSeconds))
    return true
end

local function safePlayerName(sourceKey)
    local ok, name = pcall(GetPlayerName, sourceKey)
    if ok and type(name) == 'string' and name ~= '' then
        return name
    end
    return nil
end

local function sourceStillConnected(sourceKey)
    -- During playerConnecting the temporary source is not a fully joined
    -- player. Treat source-scoped connection data as the presence signal.
    if safePlayerEndpoint(sourceKey) ~= nil or safePlayerName(sourceKey) ~= nil then
        return true
    end

    return #safePlayerIdentifiers(sourceKey) > 0
end

local function runtimeCardStats()
    local playersOk, players = pcall(GetNumPlayerIndices)
    if not playersOk or type(players) ~= 'number' then
        return {
            playersOnlineText = 'unknown',
        }
    end

    local maxOk, maxPlayers = pcall(GetConvarInt, 'sv_maxclients', 0)
    if maxOk and type(maxPlayers) == 'number' and maxPlayers > 0 then
        return {
            playersOnlineText = ('%d / %d'):format(players, maxPlayers),
        }
    end

    return {
        playersOnlineText = tostring(players),
    }
end

local function priorityIdentifiers()
    return (activeConfig.priority and activeConfig.priority.identifiers) or {}
end

local rejectionMessages = {
    duplicate = function(details)
        local wait = Util.formatDuration((details and details.waitSeconds) or activeConfig.identity.userCooldownSeconds)
        return ('%s Please wait about %s before retrying.'):format(
            activeConfig.messages.duplicate,
            wait
        )
    end,
    queue_full = function(details)
        local wait = Util.formatDuration((details and details.waitSeconds) or activeConfig.display.refreshSeconds)
        return ('%s Please try again in about %s.'):format(activeConfig.messages.queueFull, wait)
    end,
}

local function rejectDeferral(state, message, reason)
    local ok, err = Deferral.reject(state, message)
    if not ok then
        log(('Failed to reject a deferral: reason=%s error=%s'):format(
            tostring(reason or 'unknown'),
            tostring(err)
        ))
    end
    return ok, err
end

local function entryStatusForLog(entry)
    local status = queue:status()
    local position = queue:getPosition(entry.id) or 0
    local reason, remaining = queue:getEntryReason(entry)

    return ('entry=%d position=%d/%d reason=%s delay=%s estimated=%s'):format(
        entry.id,
        position,
        status.queueSize,
        tostring(reason),
        Util.formatDuration(remaining or 0),
        Util.formatDuration(queue:estimateWait(entry))
    )
end

local function presentEntryStatus(entry, state)
    if not queue:isQueued(entry.id) or state.closed then
        return
    end

    local runtime = runtimeCardStats()
    local fallback = Card.fallbackMessage(entry, queue, activeConfig, runtime)
    if activeConfig.display.adaptiveCards then
        local built, card = pcall(Card.build, entry, queue, activeConfig, runtime)
        local presented = false
        if built then
            presented = Deferral.call(state, 'presentCard', card)
        end
        if not presented and queue:isQueued(entry.id) then
            Deferral.call(state, 'update', fallback)
        end
    else
        Deferral.call(state, 'update', fallback)
    end
end

-- Returns true when the gate is disabled or the correct password was
-- submitted; otherwise false plus a rejection reason and player message.
local function promptForPassword(state, sourceKey)
    local passwordConfig = activeConfig.password
    if not passwordConfig.enabled then
        return true
    end

    for attempt = 1, passwordConfig.maxAttempts do
        local submitted
        local card = Card.buildPasswordPrompt(activeConfig, {
            showError = attempt > 1,
            attemptsRemaining = passwordConfig.maxAttempts - attempt + 1,
        })
        local onSubmit = function(data)
            local value = type(data) == 'table' and data.password or nil
            submitted = type(value) == 'string' and value or ''
        end
        local presented = Deferral.call(state, 'presentCard', card, onSubmit)
        if not presented then
            return false, 'internal_error', activeConfig.messages.internalError
        end

        local deadline = nowSeconds() + passwordConfig.timeoutSeconds
        -- Other deferring resources (txAdmin's banlist check, for example) share
        -- the deferral display and can replace this card with their own text.
        -- Re-present on a backoff: quickly at first while other resources are
        -- likely still writing, then rarely so typing is not interrupted.
        local representInterval = 3
        local nextRepresentAt = nowSeconds() + representInterval
        while submitted == nil do
            if state.closed or not sourceStillConnected(sourceKey) then
                return false, 'disconnected', activeConfig.messages.disconnected
            end
            if nowSeconds() >= deadline then
                return false, 'password_timeout', activeConfig.messages.passwordTimeout
            end
            if nowSeconds() >= nextRepresentAt then
                Deferral.call(state, 'presentCard', card, onSubmit)
                representInterval = math.min(representInterval * 2, 30)
                nextRepresentAt = nowSeconds() + representInterval
            end
            Wait(250)
        end

        if submitted == passwordConfig.secret then
            return true
        end
    end

    return false, 'password_failed', activeConfig.messages.passwordIncorrect
end

local function waitForEntryDecision(entry, state)
    local nextDisplayAt = nowSeconds()

    while not state.closed do
        if entry.payload.rejectMessage then
            rejectDeferral(state, entry.payload.rejectMessage, entry.payload.rejectReason)
            return
        end

        if entry.payload.admitted then
            local updated, updateErr = Deferral.call(state, 'update', activeConfig.messages.joining)
            if not updated then
                log(('Failed to update admitted deferral before release: %s'):format(tostring(updateErr)))
            end
            emitAdmission(entry.ip, 'queue')
            local ok, err = Deferral.call(state, 'done')
            if not ok then
                queue:completeInFlight(entry.sourceKey)
                metrics:recordRejection('internal_error')
                log(('Failed to release a queued deferral: %s'):format(tostring(err)))
            else
                log(('Released queued connection: entry=%d waited=%s'):format(
                    entry.id,
                    Util.formatDuration((entry.admittedAt or nowSeconds()) - entry.enqueuedAt)
                ))
            end
            return
        end

        if not queue:isQueued(entry.id) then
            state.closed = true
            return
        end

        local now = nowSeconds()
        if now >= nextDisplayAt then
            presentEntryStatus(entry, state)
            nextDisplayAt = now + activeConfig.display.refreshSeconds
        end

        Wait(250)
    end
end

AddEventHandler('playerConnecting', function(playerName, _, deferrals)
    local sourceKey = tostring(source)
    local deferralState

    local ok, err = xpcall(function()
        deferralState = Deferral.fromFx(deferrals, Wait)

        deferrals.defer()
        Wait(0)

        metrics:recordAttempt()

        local passwordOk, passwordReason, passwordMessage = promptForPassword(deferralState, sourceKey)
        if not passwordOk then
            metrics:recordRejection(passwordReason)
            log(('Rejected connection at the password gate: reason=%s'):format(tostring(passwordReason)))
            rejectDeferral(deferralState, passwordMessage, passwordReason)
            return
        end

        local identifiers = safePlayerIdentifiers(sourceKey)
        local tokens = safePlayerTokens(sourceKey)
        local identitySet = Identity.fromRaw(identifiers, tokens)
        local ip = Identity.extractIp(identifiers, safePlayerEndpoint(sourceKey))

        if Identity.matchesPriority(identitySet, priorityIdentifiers()) then
            emitAdmission(ip, 'priority')
            local released, releaseErr = Deferral.call(deferralState, 'done')
            if released then
                log('Priority connection admitted.')
            else
                metrics:recordRejection('internal_error')
                log(('Failed to admit a priority deferral: %s'):format(tostring(releaseErr)))
            end
            return
        end

        local entry, reason, details = queue:enqueue({
            sourceKey = sourceKey,
            name = playerName,
            identitySet = identitySet,
            ip = ip,
            payload = {
                deferral = deferralState,
            },
        })

        if not entry then
            metrics:recordRejection(reason)
            local messageFactory = rejectionMessages[reason]
            local message = messageFactory and messageFactory(details) or activeConfig.messages.internalError
            if reason == 'duplicate' and details then
                log(('Rejected duplicate connection: state=%s retry_after=%s'):format(
                    tostring(details.state),
                    Util.formatDuration(details.waitSeconds or 0)
                ))
            else
                log(('Rejected connection: reason=%s'):format(tostring(reason or 'internal_error')))
            end
            rejectDeferral(deferralState, message, reason)
            return
        end

        if entry.duplicateState then
            log(('Queued duplicate connection: %s duplicate_state=%s'):format(
                entryStatusForLog(entry),
                entry.duplicateState
            ))
        else
            log(('Queued connection: %s'):format(entryStatusForLog(entry)))
        end

        local updated, updateErr = Deferral.call(deferralState, 'update', activeConfig.messages.queued)
        if not updated then
            log(('Failed to send initial queue update: %s'):format(tostring(updateErr)))
        end
        waitForEntryDecision(entry, deferralState)
    end, debug.traceback)

    if not ok then
        queue:remove(sourceKey, 'internal_error')
        queue:completeInFlight(sourceKey)
        metrics:recordRejection('internal_error')
        log(('Connection handler failed: %s'):format(tostring(err)))
        if deferralState and not deferralState.closed then
            rejectDeferral(deferralState, activeConfig.messages.internalError, 'internal_error')
        end
    end
end)

AddEventHandler('playerJoining', function(first, second)
    local oldId = second or first
    if oldId == nil then
        log('playerJoining fired without oldID; in-flight entry could not be cleared.')
        return
    end

    local completed = queue:completeInFlight(tostring(oldId))
    if completed then
        log(('Completed in-flight connection: entry=%d'):format(completed.id))
    end
end)

AddEventHandler('playerDropped', function()
    local sourceKey = tostring(source)
    local removed = queue:remove(sourceKey, 'disconnected')
    if removed and removed.payload and removed.payload.deferral then
        removed.payload.deferral.closed = true
        log(('Removed disconnected queued connection: entry=%d'):format(removed.id))
    end

    local completed = queue:completeInFlight(sourceKey)
    if completed then
        log(('Cleared dropped in-flight connection: entry=%d'):format(completed.id))
    end
end)

CreateThread(function()
    while true do
        Wait(100)

        local results = queue:tick()
        for i = 1, #results.queueTimeouts do
            local entry = results.queueTimeouts[i]
            entry.payload.rejectMessage = activeConfig.messages.queueTimeout
            entry.payload.rejectReason = 'queue_timeout'
        end

        for i = 1, #results.admitted do
            local entry = results.admitted[i]
            entry.payload.admitted = true
        end
    end
end)

CreateThread(function()
    while true do
        Wait(1000)

        local entries = queue:getEntries()
        for i = 1, #entries do
            local entry = entries[i]
            local removed = queue:updatePresence(entry.sourceKey, sourceStillConnected(entry.sourceKey))
            if removed and removed.payload and removed.payload.deferral then
                log(('Removed abandoned queued connection: entry=%d queue=%d'):format(
                    removed.id,
                    queue:status().queueSize
                ))
                if not removed.payload.deferral.closed then
                    rejectDeferral(removed.payload.deferral, activeConfig.messages.disconnected, 'disconnected')
                end
            end
        end
    end
end)

SetHttpHandler(Http.metricsHandler(
    function()
        return activeConfig.metrics
    end,
    function()
        return metrics:render(queue:status())
    end
))

local function redactForConsole(value, path)
    if path == 'priority.identifiers' then
        return { ('<%d priority identifiers redacted>'):format(#(value or {})) }
    end

    if path == 'password.secret' then
        return '<password secret redacted>'
    end

    if path == 'priority' and type(value) == 'table' then
        local copy = Util.deepCopy(value)
        copy.identifiers = { ('<%d priority identifiers redacted>'):format(#(value.identifiers or {})) }
        return copy
    end

    if path == 'password' and type(value) == 'table' then
        local copy = Util.deepCopy(value)
        copy.secret = '<password secret redacted>'
        return copy
    end

    if (path == nil or path == '') and type(value) == 'table' then
        local copy = Util.deepCopy(value)
        if type(copy.priority) == 'table' then
            copy.priority.identifiers = { ('<%d priority identifiers redacted>'):format(#(copy.priority.identifiers or {})) }
        end
        if type(copy.password) == 'table' then
            copy.password.secret = '<password secret redacted>'
        end
        return copy
    end

    return value
end

local function encodeForConsole(value, path)
    value = redactForConsole(value, path)
    local ok, encoded = pcall(json.encode, value)
    if ok then
        return encoded
    end
    return tostring(value)
end

local function printCommandErrors(errors)
    for i = 1, #(errors or {}) do
        log(('Configuration error: %s'):format(errors[i]))
    end
end

local function copyPriorityIdentifiers()
    local identifiers = priorityIdentifiers()
    local copy = {}
    for i = 1, #identifiers do
        copy[i] = identifiers[i]
    end
    return copy
end

local function priorityIndexOf(list, normalized)
    for i = 1, #list do
        if Identity.normalizePriorityIdentifier(list[i]) == normalized then
            return i
        end
    end
    return nil
end

local function printPriorityUsage()
    log('Usage: lavender_rl priority list | priority add <identifier> | priority remove <identifier>')
end

RegisterCommand('lavender_rl', function(_, args)
    local action = args[1]

    if action == 'status' then
        local status = queue:status()
        log(('queue=%d eligible=%d in_flight=%d/%d tokens=%.2f rate=%.3f/s'):format(
            status.queueSize,
            status.eligibleQueueSize,
            status.inFlight,
            status.maxInFlight,
            status.tokens,
            status.ratePerSecond
        ))
        return
    end

    if action == 'config' and args[2] == 'get' then
        local value, err = configStore:get(args[3])
        if err then
            log(err)
        else
            log(encodeForConsole(value, args[3]))
        end
        return
    end

    if action == 'config' and args[2] == 'set' then
        local path = args[3]
        local rawValue = table.concat(args, ' ', 4)
        if not path or rawValue == '' then
            log('Usage: lavender_rl config set <dot.path> <value>')
            return
        end

        local decoded, value = pcall(json.decode, rawValue)
        if not decoded or value == nil then
            value = rawValue
        end

        local changed, errors = configStore:set(path, value)
        if not changed then
            printCommandErrors(errors)
        else
            log(('Updated and persisted %s.'):format(path))
        end
        return
    end

    if action == 'config' and args[2] == 'reload' then
        local reloaded, errors = configStore:reload()
        if not reloaded then
            log('Reload rejected; the active configuration was preserved.')
            printCommandErrors(errors)
        else
            log('Reloaded config.lua.')
        end
        return
    end

    if action == 'priority' then
        local subcommand = args[2]

        if subcommand == 'list' then
            log(('Priority identifiers configured: %d'):format(#priorityIdentifiers()))
            return
        end

        if subcommand == 'add' or subcommand == 'remove' then
            local rawIdentifier = table.concat(args, ' ', 3)
            if rawIdentifier == '' then
                printPriorityUsage()
                return
            end

            local normalized, normalizeErr = Identity.normalizePriorityIdentifier(rawIdentifier)
            if not normalized then
                log(('Priority identifier rejected: %s'):format(normalizeErr))
                return
            end

            local list = copyPriorityIdentifiers()
            local existingIndex = priorityIndexOf(list, normalized)

            if subcommand == 'add' then
                if existingIndex then
                    log(('Priority identifier already configured. total=%d'):format(#list))
                    return
                end

                list[#list + 1] = normalized
            else
                if not existingIndex then
                    log(('Priority identifier was not configured. total=%d'):format(#list))
                    return
                end

                table.remove(list, existingIndex)
            end

            local changed, errors = configStore:set('priority.identifiers', list)
            if not changed then
                printCommandErrors(errors)
                return
            end

            log(('Priority identifier %s. total=%d'):format(
                subcommand == 'add' and 'added' or 'removed',
                #list
            ))
            return
        end

        printPriorityUsage()
        return
    end

    log('Usage: lavender_rl status | config get [dot.path] | config set <dot.path> <value> | config reload | priority list|add|remove')
end, true)

AddEventHandler('onResourceStop', function(stoppedResource)
    if stoppedResource ~= resourceName then
        return
    end

    local message = activeConfig.messages.resourceStop
    local drained = queue:drain('resource_stop')
    for i = 1, #drained do
        local state = drained[i].payload.deferral
        if state and not state.closed then
            pcall(state.object.done, message)
            state.closed = true
        end
    end
end)

log(('Ready. Metrics: /%s%s | Admin ACE: command.lavender_rl'):format(resourceName, activeConfig.metrics.path))
