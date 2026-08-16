Lavender = Lavender or {}

local Identity = {}

local function trim(value)
    return value:match('^%s*(.-)%s*$')
end

local function add(set, value)
    if type(value) == 'string' and value ~= '' then
        set[value:lower()] = true
    end
end

function Identity.fromRaw(identifiers, tokens)
    local set = {}

    for i = 1, #(identifiers or {}) do
        local identifier = identifiers[i]
        if type(identifier) == 'string' and not identifier:lower():match('^ip:') then
            add(set, 'identifier:' .. identifier)
        end
    end

    for i = 1, #(tokens or {}) do
        add(set, 'token:' .. tostring(tokens[i]))
    end

    return set
end

function Identity.extractIp(identifiers, endpoint)
    for i = 1, #(identifiers or {}) do
        local identifier = identifiers[i]
        if type(identifier) == 'string' then
            local ip = identifier:match('^[Ii][Pp]:(.+)$')
            if ip and ip ~= '' then
                return ip:lower()
            end
        end
    end

    if type(endpoint) ~= 'string' or endpoint == '' then
        return nil
    end

    local bracketed = endpoint:match('^%[([^]]+)%]:%d+$')
    if bracketed then
        return bracketed:lower()
    end

    local ipv4 = endpoint:match('^([%d.]+):%d+$')
    return (ipv4 or endpoint):lower()
end

function Identity.similarity(left, right)
    left = left or {}
    right = right or {}

    local intersection = 0
    local union = 0

    for value in pairs(left) do
        union = union + 1
        if right[value] then
            intersection = intersection + 1
        end
    end

    for value in pairs(right) do
        if not left[value] then
            union = union + 1
        end
    end

    if union == 0 then
        return 0
    end

    return intersection / union
end

function Identity.matches(left, right, threshold)
    return Identity.similarity(left, right) >= threshold
end

function Identity.normalizePriorityIdentifier(value)
    if type(value) ~= 'string' then
        return nil, 'identifier must be a string'
    end

    local normalized = trim(value):lower()
    if normalized == '' then
        return nil, 'identifier must not be empty'
    end

    if normalized:match('^identifier:') then
        normalized = normalized:sub(12)
    end

    if normalized:match('^ip:') then
        return nil, 'ip identifiers are not allowed for priority bypass'
    end

    if not normalized:match('^[%w_]+:.+') then
        return nil, 'identifier must look like license:..., discord:..., fivem:..., license2:..., or token:...'
    end

    return normalized
end

function Identity.priorityKey(value)
    local normalized = Identity.normalizePriorityIdentifier(value)
    if not normalized then
        return nil
    end

    if normalized:match('^token:') then
        return normalized
    end

    return 'identifier:' .. normalized
end

function Identity.matchesPriority(identitySet, priorityIdentifiers)
    identitySet = identitySet or {}

    for i = 1, #(priorityIdentifiers or {}) do
        local key = Identity.priorityKey(priorityIdentifiers[i])
        if key and identitySet[key] then
            return true
        end
    end

    return false
end

Lavender.Identity = Identity
return Identity
