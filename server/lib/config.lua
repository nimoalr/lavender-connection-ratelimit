Lavender = Lavender or {}

local Config = {}

local allowedKeys = {
    version = true,
    release = {
        ratePerSecond = true,
        burst = true,
        maxInFlight = true,
        inFlightTimeoutSeconds = true,
    },
    identity = {
        similarityThreshold = true,
        activeDuplicatePolicy = true,
        userCooldownSeconds = true,
        recentHistorySeconds = true,
        maxActiveQueuedDuplicates = true,
    },
    priority = {
        identifiers = true,
    },
    ip = {
        spacingSeconds = true,
    },
    queue = {
        maxSize = true,
        maxWaitSeconds = true,
        disconnectGraceSeconds = true,
    },
    display = {
        adaptiveCards = true,
        refreshSeconds = true,
        title = true,
        serverName = true,
    },
    password = {
        enabled = true,
        secret = true,
        maxAttempts = true,
        timeoutSeconds = true,
    },
    metrics = {
        enabled = true,
        path = true,
        prefix = true,
        waitBucketsSeconds = true,
    },
    messages = {
        queued = true,
        joining = true,
        duplicate = true,
        queueFull = true,
        queueTimeout = true,
        disconnected = true,
        resourceStop = true,
        internalError = true,
        passwordPrompt = true,
        passwordIncorrect = true,
        passwordTimeout = true,
    },
}

local function addError(errors, path, message)
    errors[#errors + 1] = ('%s: %s'):format(path, message)
end

local function expectTable(errors, root, key, path)
    local value = root and root[key]
    if type(value) ~= 'table' then
        addError(errors, path, 'must be an object')
        return nil
    end
    return value
end

local function expectBoolean(errors, root, key, path)
    if type(root and root[key]) ~= 'boolean' then
        addError(errors, path, 'must be a boolean')
    end
end

local function expectString(errors, root, key, path, maximumLength)
    local value = root and root[key]
    if type(value) ~= 'string' then
        addError(errors, path, 'must be a string')
        return
    end
    if value == '' then
        addError(errors, path, 'must not be empty')
    elseif maximumLength and #value > maximumLength then
        addError(errors, path, ('must be at most %d characters'):format(maximumLength))
    end
end

local function expectEnumString(errors, root, key, path, allowedValues)
    local value = root and root[key]
    expectString(errors, root, key, path, 120)
    if type(value) ~= 'string' then
        return
    end

    for i = 1, #allowedValues do
        if value == allowedValues[i] then
            return
        end
    end

    addError(errors, path, ('must be one of: %s'):format(table.concat(allowedValues, ', ')))
end

local function normalizePriorityIdentifier(value)
    if type(value) ~= 'string' then
        return nil, 'must be a string'
    end

    local normalized = value:match('^%s*(.-)%s*$'):lower()
    if normalized == '' then
        return nil, 'must not be empty'
    end
    if normalized:match('^identifier:') then
        normalized = normalized:sub(12)
    end
    if normalized:match('^ip:') then
        return nil, 'must not be an IP identifier'
    end
    if #normalized > 256 then
        return nil, 'must be at most 256 characters'
    end
    if not normalized:match('^[%w_]+:.+') then
        return nil, 'must look like license:..., license2:..., discord:..., fivem:..., steam:..., or token:...'
    end

    return normalized
end

local function expectPriorityIdentifiers(errors, root, key, path)
    local value = root and root[key]
    if type(value) ~= 'table' then
        addError(errors, path, 'must be an array')
        return
    end

    local seen = {}
    for index = 1, #value do
        local normalized, err = normalizePriorityIdentifier(value[index])
        local childPath = ('%s.%d'):format(path, index)
        if not normalized then
            addError(errors, childPath, err)
        elseif seen[normalized] then
            addError(errors, childPath, 'must not duplicate another priority identifier')
        else
            seen[normalized] = true
        end
    end

    for keyName in pairs(value) do
        if type(keyName) ~= 'number' or keyName < 1 or keyName % 1 ~= 0 or keyName > #value then
            addError(errors, path, 'must be a dense array')
            break
        end
    end
end

local function expectNumber(errors, root, key, path, minimum, maximum, integer)
    local value = root and root[key]
    if type(value) ~= 'number' then
        addError(errors, path, 'must be a number')
        return
    end
    if value ~= value or value == math.huge or value == -math.huge then
        addError(errors, path, 'must be a finite number')
        return
    end
    if integer and value % 1 ~= 0 then
        addError(errors, path, 'must be an integer')
    end
    if minimum and value < minimum then
        addError(errors, path, ('must be at least %s'):format(minimum))
    end
    if maximum and value > maximum then
        addError(errors, path, ('must be at most %s'):format(maximum))
    end
end

local function checkUnknownKeys(errors, value, schema, path)
    if type(value) ~= 'table' then
        return
    end

    for key, child in pairs(value) do
        local childSchema = schema[key]
        local childPath = path == '' and tostring(key) or (path .. '.' .. tostring(key))

        if childSchema == nil then
            addError(errors, childPath, 'is not a supported configuration key')
        elseif type(childSchema) == 'table' then
            checkUnknownKeys(errors, child, childSchema, childPath)
        end
    end
end

function Config.validate(candidate)
    local errors = {}

    if type(candidate) ~= 'table' then
        return false, { 'configuration root must be an object' }
    end

    checkUnknownKeys(errors, candidate, allowedKeys, '')

    expectNumber(errors, candidate, 'version', 'version', 1, 1, true)

    local release = expectTable(errors, candidate, 'release', 'release')
    expectNumber(errors, release, 'ratePerSecond', 'release.ratePerSecond', 0.001, 100, false)
    expectNumber(errors, release, 'burst', 'release.burst', 1, 1000, true)
    expectNumber(errors, release, 'maxInFlight', 'release.maxInFlight', 1, 1000, true)
    expectNumber(errors, release, 'inFlightTimeoutSeconds', 'release.inFlightTimeoutSeconds', 1, 3600, false)

    local identity = expectTable(errors, candidate, 'identity', 'identity')
    expectNumber(errors, identity, 'similarityThreshold', 'identity.similarityThreshold', 0.01, 1, false)
    expectEnumString(errors, identity, 'activeDuplicatePolicy', 'identity.activeDuplicatePolicy', { 'queue', 'reject' })
    expectNumber(errors, identity, 'userCooldownSeconds', 'identity.userCooldownSeconds', 0, 86400, false)
    expectNumber(errors, identity, 'recentHistorySeconds', 'identity.recentHistorySeconds', 1, 604800, false)
    -- Optional: absent means the default cap applies. 0 disables the cap.
    if identity and identity.maxActiveQueuedDuplicates ~= nil then
        expectNumber(errors, identity, 'maxActiveQueuedDuplicates', 'identity.maxActiveQueuedDuplicates', 0, 100000, true)
    end
    if identity and type(identity.userCooldownSeconds) == 'number'
        and type(identity.recentHistorySeconds) == 'number'
        and identity.recentHistorySeconds < identity.userCooldownSeconds then
        addError(errors, 'identity.recentHistorySeconds', 'must be greater than or equal to userCooldownSeconds')
    end

    local priority = expectTable(errors, candidate, 'priority', 'priority')
    expectPriorityIdentifiers(errors, priority, 'identifiers', 'priority.identifiers')

    local ip = expectTable(errors, candidate, 'ip', 'ip')
    expectNumber(errors, ip, 'spacingSeconds', 'ip.spacingSeconds', 0, 3600, false)

    local queue = expectTable(errors, candidate, 'queue', 'queue')
    expectNumber(errors, queue, 'maxSize', 'queue.maxSize', 1, 10000, true)
    expectNumber(errors, queue, 'maxWaitSeconds', 'queue.maxWaitSeconds', 1, 86400, false)
    expectNumber(errors, queue, 'disconnectGraceSeconds', 'queue.disconnectGraceSeconds', 0, 300, false)

    local display = expectTable(errors, candidate, 'display', 'display')
    expectBoolean(errors, display, 'adaptiveCards', 'display.adaptiveCards')
    expectNumber(errors, display, 'refreshSeconds', 'display.refreshSeconds', 0.5, 60, false)
    expectString(errors, display, 'title', 'display.title', 80)
    expectString(errors, display, 'serverName', 'display.serverName', 120)

    local password = expectTable(errors, candidate, 'password', 'password')
    expectBoolean(errors, password, 'enabled', 'password.enabled')
    if password then
        local secret = password.secret
        if type(secret) ~= 'string' then
            addError(errors, 'password.secret', 'must be a string')
        elseif #secret > 128 then
            addError(errors, 'password.secret', 'must be at most 128 characters')
        elseif password.enabled == true and secret == '' then
            addError(errors, 'password.secret', 'must not be empty while password.enabled is true')
        end
    end
    expectNumber(errors, password, 'maxAttempts', 'password.maxAttempts', 1, 10, true)
    expectNumber(errors, password, 'timeoutSeconds', 'password.timeoutSeconds', 5, 600, false)

    local metrics = expectTable(errors, candidate, 'metrics', 'metrics')
    expectBoolean(errors, metrics, 'enabled', 'metrics.enabled')
    expectString(errors, metrics, 'path', 'metrics.path', 120)
    expectString(errors, metrics, 'prefix', 'metrics.prefix', 120)
    if metrics and type(metrics.path) == 'string' and not metrics.path:match('^/[A-Za-z0-9_./-]+$') then
        addError(errors, 'metrics.path', 'must begin with / and contain only URL path characters')
    end
    if metrics and type(metrics.prefix) == 'string' and not metrics.prefix:match('^[A-Za-z_:][A-Za-z0-9_:]*$') then
        addError(errors, 'metrics.prefix', 'must be a valid Prometheus metric prefix')
    end
    if metrics and type(metrics.waitBucketsSeconds) == 'table' then
        local previous = -math.huge
        if #metrics.waitBucketsSeconds == 0 then
            addError(errors, 'metrics.waitBucketsSeconds', 'must contain at least one bucket')
        end
        for i = 1, #metrics.waitBucketsSeconds do
            local bucket = metrics.waitBucketsSeconds[i]
            if type(bucket) ~= 'number' or bucket <= 0 or bucket > 86400 then
                addError(errors, ('metrics.waitBucketsSeconds.%d'):format(i), 'must be a number between 0 and 86400')
            elseif bucket <= previous then
                addError(errors, 'metrics.waitBucketsSeconds', 'must be strictly increasing')
            end
            previous = type(bucket) == 'number' and bucket or previous
        end
    else
        addError(errors, 'metrics.waitBucketsSeconds', 'must be an array')
    end

    local messages = expectTable(errors, candidate, 'messages', 'messages')
    for key in pairs(allowedKeys.messages) do
        expectString(errors, messages, key, 'messages.' .. key, 500)
    end

    return #errors == 0, errors
end

Lavender.Config = Config
return Config
