Lavender = Lavender or {}

local Util = Lavender.Util
local Config = Lavender.Config

local ConfigStore = {}
ConfigStore.__index = ConfigStore

function ConfigStore.new(options)
    assert(type(options) == 'table', 'ConfigStore options are required')
    assert(type(options.read) == 'function', 'ConfigStore read adapter is required')
    assert(type(options.write) == 'function', 'ConfigStore write adapter is required')
    assert(type(options.decode) == 'function', 'ConfigStore decode adapter is required')
    assert(type(options.encode) == 'function', 'ConfigStore encode adapter is required')

    return setmetatable({
        path = options.path or 'config.lua',
        defaults = Util.deepCopy(options.defaults or Lavender.Defaults),
        read = options.read,
        write = options.write,
        decode = options.decode,
        encode = options.encode,
        onApply = options.onApply or function() end,
        active = nil,
    }, ConfigStore)
end

function ConfigStore:_decodeAndValidate(raw)
    if type(raw) ~= 'string' then
        return nil, { 'configuration file could not be read' }
    end

    local ok, candidate = pcall(self.decode, raw)
    if not ok then
        return nil, { ('configuration file could not be decoded: %s'):format(tostring(candidate)) }
    end
    if type(candidate) ~= 'table' then
        return nil, { 'configuration file must decode to a table' }
    end

    local valid, errors = Config.validate(candidate)
    if not valid then
        return nil, errors
    end

    return candidate
end

function ConfigStore:_readAndValidate()
    local ok, raw = pcall(self.read, self.path)
    if not ok then
        return nil, { 'configuration file could not be read' }
    end
    return self:_decodeAndValidate(raw)
end

function ConfigStore:_apply(candidate)
    self.active = Util.deepCopy(candidate)
    self.onApply(self.active)
    return self.active
end

function ConfigStore:loadStartup()
    local candidate, errors = self:_readAndValidate()
    if not candidate then
        self:_apply(self.defaults)
        return false, errors
    end

    self:_apply(candidate)
    return true
end

function ConfigStore:reload()
    local candidate, errors = self:_readAndValidate()
    if not candidate then
        return false, errors
    end

    self:_apply(candidate)
    return true
end

function ConfigStore:get(path)
    return Util.getPath(self.active, path)
end

function ConfigStore:set(path, value)
    local candidate = Util.deepCopy(self.active)
    local changed, pathError = Util.setExistingPath(candidate, path, value)
    if not changed then
        return false, { pathError }
    end

    local valid, errors = Config.validate(candidate)
    if not valid then
        return false, errors
    end

    local encodedOk, encoded = pcall(self.encode, candidate)
    if not encodedOk or type(encoded) ~= 'string' then
        return false, { 'failed to encode the proposed configuration' }
    end

    local wroteOk, wrote = pcall(self.write, self.path, encoded)
    if not wroteOk or not wrote then
        return false, { 'failed to persist the proposed configuration' }
    end

    self:_apply(candidate)
    return true
end

Lavender.ConfigStore = ConfigStore
return ConfigStore
