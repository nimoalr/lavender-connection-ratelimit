Lavender = Lavender or {}

local Metrics = {}
Metrics.__index = Metrics

local rejectionReasons = { 'duplicate', 'queue_full', 'internal_error', 'password_failed', 'password_timeout' }
local departureReasons = { 'admitted', 'disconnected', 'queue_timeout', 'resource_stop' }

local function zeroMap(keys)
    local map = {}
    for i = 1, #keys do
        map[keys[i]] = 0
    end
    return map
end

local function bucketMap(config)
    local map = {}
    for i = 1, #config.metrics.waitBucketsSeconds do
        map[tostring(config.metrics.waitBucketsSeconds[i])] = 0
    end
    return map
end

local function sameBuckets(left, right)
    local leftBuckets = left.metrics.waitBucketsSeconds
    local rightBuckets = right.metrics.waitBucketsSeconds
    if #leftBuckets ~= #rightBuckets then
        return false
    end
    for i = 1, #leftBuckets do
        if leftBuckets[i] ~= rightBuckets[i] then
            return false
        end
    end
    return true
end

local function number(value)
    if value == math.huge then
        return '+Inf'
    end
    return ('%.6f'):format(value):gsub('0+$', ''):gsub('%.$', '')
end

local function appendFamily(lines, name, help, metricType, samples)
    lines[#lines + 1] = ('# HELP %s %s'):format(name, help)
    lines[#lines + 1] = ('# TYPE %s %s'):format(name, metricType)
    for i = 1, #samples do
        lines[#lines + 1] = samples[i]
    end
end

function Metrics.new(config)
    return setmetatable({
        config = config,
        attempts = 0,
        entries = 0,
        admissions = 0,
        rejections = zeroMap(rejectionReasons),
        departures = zeroMap(departureReasons),
        inFlightTimeouts = 0,
        waitCount = 0,
        waitSum = 0,
        waitBuckets = bucketMap(config),
    }, Metrics)
end

function Metrics:setConfig(config)
    if not sameBuckets(self.config, config) then
        self.waitCount = 0
        self.waitSum = 0
        self.waitBuckets = bucketMap(config)
    end
    self.config = config
end

function Metrics:recordAttempt()
    self.attempts = self.attempts + 1
end

function Metrics:recordRejection(reason)
    if self.rejections[reason] ~= nil then
        self.rejections[reason] = self.rejections[reason] + 1
    end
end

function Metrics:observeWait(seconds)
    seconds = math.max(0, seconds)
    self.waitCount = self.waitCount + 1
    self.waitSum = self.waitSum + seconds

    local buckets = self.config.metrics.waitBucketsSeconds
    for i = 1, #buckets do
        if seconds <= buckets[i] then
            local key = tostring(buckets[i])
            self.waitBuckets[key] = (self.waitBuckets[key] or 0) + 1
        end
    end
end

function Metrics:recordQueueEvent(event, data)
    if event == 'queued' then
        self.entries = self.entries + 1
    elseif event == 'admitted' then
        self.admissions = self.admissions + 1
        self.departures.admitted = self.departures.admitted + 1
        self:observeWait((data.admittedAt or data.enqueuedAt) - data.enqueuedAt)
    elseif event == 'removed' and self.departures[data.reason] ~= nil then
        self.departures[data.reason] = self.departures[data.reason] + 1
    elseif event == 'in_flight_timeout' then
        self.inFlightTimeouts = self.inFlightTimeouts + 1
    end
end

function Metrics:render(queueStatus)
    local prefix = self.config.metrics.prefix
    local lines = {}

    appendFamily(lines, prefix .. '_queue_connections', 'Current number of connections waiting in the admission queue.', 'gauge', {
        ('%s_queue_connections %d'):format(prefix, queueStatus.queueSize),
    })
    appendFamily(lines, prefix .. '_queue_eligible_connections', 'Current number of queued connections whose user and IP delays have elapsed.', 'gauge', {
        ('%s_queue_eligible_connections %d'):format(prefix, queueStatus.eligibleQueueSize),
    })
    appendFamily(lines, prefix .. '_in_flight_connections', 'Current number of admitted connections still loading into FXServer.', 'gauge', {
        ('%s_in_flight_connections %d'):format(prefix, queueStatus.inFlight),
    })
    appendFamily(lines, prefix .. '_connection_attempts_total', 'Total connection attempts observed by the limiter.', 'counter', {
        ('%s_connection_attempts_total %d'):format(prefix, self.attempts),
    })
    appendFamily(lines, prefix .. '_queue_entries_total', 'Total connection attempts accepted into the queue.', 'counter', {
        ('%s_queue_entries_total %d'):format(prefix, self.entries),
    })
    appendFamily(lines, prefix .. '_admissions_total', 'Total queued connections released from this resource deferral.', 'counter', {
        ('%s_admissions_total %d'):format(prefix, self.admissions),
    })

    local rejectionSamples = {}
    for i = 1, #rejectionReasons do
        local reason = rejectionReasons[i]
        rejectionSamples[#rejectionSamples + 1] = ('%s_rejections_total{reason="%s"} %d'):format(prefix, reason, self.rejections[reason])
    end
    appendFamily(lines, prefix .. '_rejections_total', 'Total connection attempts rejected by reason.', 'counter', rejectionSamples)

    local departureSamples = {}
    for i = 1, #departureReasons do
        local reason = departureReasons[i]
        departureSamples[#departureSamples + 1] = ('%s_queue_departures_total{reason="%s"} %d'):format(prefix, reason, self.departures[reason])
    end
    appendFamily(lines, prefix .. '_queue_departures_total', 'Total connections leaving the queue by reason.', 'counter', departureSamples)

    appendFamily(lines, prefix .. '_in_flight_timeouts_total', 'Total admitted connections cleared after the in-flight timeout.', 'counter', {
        ('%s_in_flight_timeouts_total %d'):format(prefix, self.inFlightTimeouts),
    })

    local histogramSamples = {}
    local buckets = self.config.metrics.waitBucketsSeconds
    for i = 1, #buckets do
        local cumulative = self.waitBuckets[tostring(buckets[i])] or 0
        histogramSamples[#histogramSamples + 1] = ('%s_queue_wait_seconds_bucket{le="%s"} %d'):format(prefix, number(buckets[i]), cumulative)
    end
    histogramSamples[#histogramSamples + 1] = ('%s_queue_wait_seconds_bucket{le="+Inf"} %d'):format(prefix, self.waitCount)
    histogramSamples[#histogramSamples + 1] = ('%s_queue_wait_seconds_sum %s'):format(prefix, number(self.waitSum))
    histogramSamples[#histogramSamples + 1] = ('%s_queue_wait_seconds_count %d'):format(prefix, self.waitCount)
    appendFamily(lines, prefix .. '_queue_wait_seconds', 'Time spent in the admission queue before release.', 'histogram', histogramSamples)

    return table.concat(lines, '\n') .. '\n'
end

Lavender.Metrics = Metrics
return Metrics
