Lavender = Lavender or {}

local Util = {}

function Util.deepCopy(value, seen)
    if type(value) ~= 'table' then
        return value
    end

    seen = seen or {}
    if seen[value] then
        return seen[value]
    end

    local copy = {}
    seen[value] = copy

    for key, child in pairs(value) do
        copy[Util.deepCopy(key, seen)] = Util.deepCopy(child, seen)
    end

    return copy
end

function Util.splitPath(path)
    if type(path) ~= 'string' or path == '' then
        return nil, 'path must be a non-empty string'
    end

    local parts = {}
    for part in path:gmatch('[^.]+') do
        if not part:match('^[%a_][%w_]*$') then
            return nil, ('invalid path segment: %s'):format(part)
        end
        parts[#parts + 1] = part
    end

    if #parts == 0 then
        return nil, 'path must contain at least one segment'
    end

    return parts
end

function Util.getPath(root, path)
    if path == nil or path == '' then
        return root
    end

    local parts, err = Util.splitPath(path)
    if not parts then
        return nil, err
    end

    local current = root
    for i = 1, #parts do
        if type(current) ~= 'table' or current[parts[i]] == nil then
            return nil, ('unknown configuration path: %s'):format(path)
        end
        current = current[parts[i]]
    end

    return current
end

function Util.setExistingPath(root, path, value)
    local parts, err = Util.splitPath(path)
    if not parts then
        return false, err
    end

    local current = root
    for i = 1, #parts - 1 do
        if type(current) ~= 'table' or type(current[parts[i]]) ~= 'table' then
            return false, ('unknown configuration path: %s'):format(path)
        end
        current = current[parts[i]]
    end

    local final = parts[#parts]
    if type(current) ~= 'table' or current[final] == nil then
        return false, ('unknown configuration path: %s'):format(path)
    end

    current[final] = value
    return true
end

function Util.round(value)
    return math.floor(value + 0.5)
end

function Util.clamp(value, minimum, maximum)
    if value < minimum then
        return minimum
    end
    if value > maximum then
        return maximum
    end
    return value
end

function Util.countMap(map)
    local count = 0
    for _ in pairs(map) do
        count = count + 1
    end
    return count
end

function Util.formatDuration(seconds)
    seconds = math.max(0, Util.round(seconds))

    local hours = math.floor(seconds / 3600)
    local minutes = math.floor((seconds % 3600) / 60)
    local remaining = seconds % 60

    if hours > 0 then
        return ('%dh %02dm %02ds'):format(hours, minutes, remaining)
    end
    if minutes > 0 then
        return ('%dm %02ds'):format(minutes, remaining)
    end
    return ('%ds'):format(remaining)
end

Lavender.Util = Util
return Util
