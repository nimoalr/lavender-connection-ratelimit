Lavender = Lavender or {}

local Admission = {
    eventName = 'lavender:admitted',
    ttlSeconds = 120,
}

-- Notify server-local consumers that Lavender is about to release its deferral.
-- The address is intentionally passed to the event but never returned for logging.
function Admission.emit(trigger, ip)
    if type(trigger) ~= 'function' or type(ip) ~= 'string' or ip == '' then
        return false
    end

    trigger(Admission.eventName, ip, Admission.ttlSeconds)
    return true
end

Lavender.Admission = Admission
return Admission
