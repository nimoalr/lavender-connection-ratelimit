local Json = {}
Json.null = {}

local function decodeError(position, message)
    error(('JSON decode error at byte %d: %s'):format(position, message), 0)
end

function Json.decode(text)
    local position = 1
    local length = #text
    local parseValue

    local function skipWhitespace()
        while position <= length and text:sub(position, position):match('%s') do
            position = position + 1
        end
    end

    local function parseString()
        if text:sub(position, position) ~= '"' then
            decodeError(position, 'expected string')
        end

        position = position + 1
        local parts = {}
        while position <= length do
            local character = text:sub(position, position)
            if character == '"' then
                position = position + 1
                return table.concat(parts)
            end

            if character == '\\' then
                position = position + 1
                local escape = text:sub(position, position)
                local replacements = {
                    ['"'] = '"',
                    ['\\'] = '\\',
                    ['/'] = '/',
                    b = '\b',
                    f = '\f',
                    n = '\n',
                    r = '\r',
                    t = '\t',
                }

                if escape == 'u' then
                    local hex = text:sub(position + 1, position + 4)
                    local codepoint = tonumber(hex, 16)
                    if not codepoint or #hex ~= 4 then
                        decodeError(position, 'invalid unicode escape')
                    end
                    parts[#parts + 1] = utf8.char(codepoint)
                    position = position + 5
                elseif replacements[escape] then
                    parts[#parts + 1] = replacements[escape]
                    position = position + 1
                else
                    decodeError(position, 'invalid escape')
                end
            else
                if character:byte() < 32 then
                    decodeError(position, 'unescaped control character')
                end
                parts[#parts + 1] = character
                position = position + 1
            end
        end

        decodeError(position, 'unterminated string')
    end

    local function parseNumber()
        local tail = text:sub(position)
        local valueText = tail:match('^-?%d+%.%d+[eE][+-]?%d+')
            or tail:match('^-?%d+[eE][+-]?%d+')
            or tail:match('^-?%d+%.%d+')
            or tail:match('^-?%d+')

        if not valueText then
            decodeError(position, 'invalid number')
        end

        local value = tonumber(valueText)
        if not value then
            decodeError(position, 'invalid number')
        end

        position = position + #valueText
        return value
    end

    local function parseArray()
        position = position + 1
        skipWhitespace()

        local array = {}
        if text:sub(position, position) == ']' then
            position = position + 1
            return array
        end

        while true do
            array[#array + 1] = parseValue()
            skipWhitespace()

            local character = text:sub(position, position)
            if character == ']' then
                position = position + 1
                return array
            end
            if character ~= ',' then
                decodeError(position, 'expected , or ]')
            end
            position = position + 1
            skipWhitespace()
        end
    end

    local function parseObject()
        position = position + 1
        skipWhitespace()

        local object = {}
        if text:sub(position, position) == '}' then
            position = position + 1
            return object
        end

        while true do
            local key = parseString()
            skipWhitespace()
            if text:sub(position, position) ~= ':' then
                decodeError(position, 'expected :')
            end
            position = position + 1
            skipWhitespace()
            object[key] = parseValue()
            skipWhitespace()

            local character = text:sub(position, position)
            if character == '}' then
                position = position + 1
                return object
            end
            if character ~= ',' then
                decodeError(position, 'expected , or }')
            end
            position = position + 1
            skipWhitespace()
        end
    end

    parseValue = function()
        skipWhitespace()
        local character = text:sub(position, position)

        if character == '"' then
            return parseString()
        elseif character == '{' then
            return parseObject()
        elseif character == '[' then
            return parseArray()
        elseif character == '-' or character:match('%d') then
            return parseNumber()
        elseif text:sub(position, position + 3) == 'true' then
            position = position + 4
            return true
        elseif text:sub(position, position + 4) == 'false' then
            position = position + 5
            return false
        elseif text:sub(position, position + 3) == 'null' then
            position = position + 4
            return Json.null
        end

        decodeError(position, 'unexpected value')
    end

    local value = parseValue()
    skipWhitespace()
    if position <= length then
        decodeError(position, 'trailing data')
    end
    return value
end

return Json
