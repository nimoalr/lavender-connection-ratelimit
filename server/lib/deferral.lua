Lavender = Lavender or {}

local Deferral = {}

function Deferral.new(object, wait)
    return {
        object = object,
        wait = wait,
        busy = false,
        closed = false,
    }
end

function Deferral.fromFx(object, wait)
    return Deferral.new({
        update = function(message)
            return object.update(message)
        end,
        presentCard = function(card, callback)
            if callback == nil then
                return object.presentCard(card)
            end
            return object.presentCard(card, callback)
        end,
        done = function(...)
            local count = select('#', ...)
            if count == 0 then
                return object.done()
            end

            local message = select(1, ...)
            if message == nil then
                return object.done()
            end

            return object.done(message)
        end,
    }, wait)
end

function Deferral.call(state, method, ...)
    if not state or state.closed then
        return false, 'deferral is closed'
    end

    while state.busy and not state.closed do
        state.wait(0)
    end
    if state.closed then
        return false, 'deferral is closed'
    end

    state.busy = true

    -- FXServer requires at least one tick between all deferral operations.
    state.wait(0)

    -- Closed while we waited (another owner finished it, e.g. resource stop):
    -- the operation must not run on a finished deferral.
    if state.closed then
        state.busy = false
        return false, 'deferral is closed'
    end

    local fn = state.object[method]
    local ok, err
    if fn == nil then
        ok, err = false, ('unknown deferral method: %s'):format(tostring(method))
    else
        ok, err = pcall(fn, ...)
    end

    if method == 'done' then
        state.closed = true
    end
    state.busy = false
    return ok, err
end

function Deferral.reject(state, message)
    Deferral.call(state, 'update', message)
    return Deferral.call(state, 'done', message)
end

Lavender.Deferral = Deferral
return Deferral
