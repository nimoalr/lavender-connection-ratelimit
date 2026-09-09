Lavender = Lavender or {}

local Metrics = {}
Metrics.__index = Metrics

-- 'disconnected_*' distinguish a password prompt abandoned because the source
-- vanished from one whose deferral was closed; both must be counted, and the
-- vocabulary stays fixed so label cardinality is bounded.
local rejectionReasons = {
    'duplicate', 'duplicate_flood', 'queue_full', 'internal_error', 'password_failed', 'password_timeout',
    'disconnected_endpoint_missing', 'disconnected_deferral_closed',
}
local departureReasons = { 'admitted', 'disconnected', 'queue_timeout', 'resource_stop' }
local duplicateStates = { 'queued', 'joining' }

-- Shared bucket ladder (seconds) for the reconcile, presence-sweep, and
-- in-flight duration histograms. Fixed so label cardinality stays bounded.
local durationBucketOrder = { 0.0005, 0.001, 0.005, 0.01, 0.05, 0.1, 0.5, 1, 5, 30, 120 }
local function newDurationBuckets()
    local m = {}
    for i = 1, #durationBucketOrder do m[tostring(durationBucketOrder[i])] = 0 end
    return m
end

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
        -- Ticker liveness: a successful scrape of this endpoint says nothing about
        -- whether admissions are progressing. These are fed by the entrypoint.
        enabled = 1,
        tickerIterations = 0,
        tickerFailures = 0,
        tickerLastRunAt = 0,     -- wall-clock unix seconds of the last completed tick
        tickerLastRunClock = 0,  -- monotonic seconds (same clock as the queue) of the last completed tick
        tickDurationCount = 0,
        tickDurationSum = 0,
        tickDurationBuckets = { ['0.001'] = 0, ['0.005'] = 0, ['0.01'] = 0, ['0.05'] = 0, ['0.1'] = 0, ['0.5'] = 0, ['1'] = 0, ['5'] = 0 },
        eventCallbackErrors = 0,
        -- Reconcile pass (the O(n) wait-estimate refresh) cost per frame.
        reconcileCount = 0,
        reconcileSum = 0,
        reconcileBuckets = newDurationBuckets(),
        -- Presence sweep (per-second liveness scan) cost and reaping.
        presenceSweepCount = 0,
        presenceSweepSum = 0,
        presenceSweepBuckets = newDurationBuckets(),
        abandonedRemoved = 0,
        -- Time from admission (deferral done) to load completion or timeout.
        inFlightDurationCount = 0,
        inFlightDurationSum = 0,
        inFlightDurationBuckets = newDurationBuckets(),
        -- Duplicate identities observed at enqueue, by the state of the match.
        duplicatesDetected = zeroMap(duplicateStates),
    }, Metrics)
end

local function observeInto(bucketMapRef, order, count, sum, seconds)
    seconds = math.max(0, seconds or 0)
    count = count + 1
    sum = sum + seconds
    for i = 1, #order do
        if seconds <= order[i] then
            local key = tostring(order[i])
            bucketMapRef[key] = (bucketMapRef[key] or 0) + 1
        end
    end
    return count, sum
end

--- recordReconcile records one wait-estimate reconcile pass (the queue's main
--- O(n) cost per frame). Watching this against the queue depth shows the
--- resource's game-thread cost live.
function Metrics:recordReconcile(seconds)
    self.reconcileCount, self.reconcileSum =
        observeInto(self.reconcileBuckets, durationBucketOrder, self.reconcileCount, self.reconcileSum, seconds)
end

--- recordPresenceSweep records one per-second presence sweep and how many
--- abandoned connections it reaped.
function Metrics:recordPresenceSweep(seconds, removed)
    self.presenceSweepCount, self.presenceSweepSum =
        observeInto(self.presenceSweepBuckets, durationBucketOrder, self.presenceSweepCount, self.presenceSweepSum, seconds)
    self.abandonedRemoved = self.abandonedRemoved + (removed or 0)
end

function Metrics:recordInFlightDuration(seconds)
    self.inFlightDurationCount, self.inFlightDurationSum =
        observeInto(self.inFlightDurationBuckets, durationBucketOrder, self.inFlightDurationCount, self.inFlightDurationSum, seconds)
end

local tickBucketOrder = { 0.001, 0.005, 0.01, 0.05, 0.1, 0.5, 1, 5 }

function Metrics:setEnabled(enabled)
    self.enabled = enabled and 1 or 0
end

--- recordTick records one completed ticker iteration. seconds is CPU/wall time
--- of the iteration; monotonicNow is the queue clock at completion; wallNow is
--- os.time().
function Metrics:recordTick(seconds, monotonicNow, wallNow)
    self.tickerIterations = self.tickerIterations + 1
    self.tickerLastRunClock = monotonicNow or self.tickerLastRunClock
    self.tickerLastRunAt = wallNow or self.tickerLastRunAt
    seconds = math.max(0, seconds or 0)
    self.tickDurationCount = self.tickDurationCount + 1
    self.tickDurationSum = self.tickDurationSum + seconds
    for i = 1, #tickBucketOrder do
        if seconds <= tickBucketOrder[i] then
            local key = tostring(tickBucketOrder[i])
            self.tickDurationBuckets[key] = (self.tickDurationBuckets[key] or 0) + 1
        end
    end
end

function Metrics:recordTickFailure()
    self.tickerFailures = self.tickerFailures + 1
end

function Metrics:setEventCallbackErrors(count)
    self.eventCallbackErrors = count or 0
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
        if data.duplicateState and self.duplicatesDetected[data.duplicateState] ~= nil then
            self.duplicatesDetected[data.duplicateState] = self.duplicatesDetected[data.duplicateState] + 1
        end
    elseif event == 'admitted' then
        self.admissions = self.admissions + 1
        self.departures.admitted = self.departures.admitted + 1
        self:observeWait((data.admittedAt or data.enqueuedAt) - data.enqueuedAt)
    elseif event == 'removed' and self.departures[data.reason] ~= nil then
        self.departures[data.reason] = self.departures[data.reason] + 1
    elseif event == 'in_flight_completed' then
        if data.inFlightDurationSeconds ~= nil then
            self:recordInFlightDuration(data.inFlightDurationSeconds)
        end
    elseif event == 'in_flight_timeout' then
        self.inFlightTimeouts = self.inFlightTimeouts + 1
        if data.inFlightDurationSeconds ~= nil then
            self:recordInFlightDuration(data.inFlightDurationSeconds)
        end
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

    appendFamily(lines, prefix .. '_enabled', 'Whether the limiter is active (1) or started inert via the lavender_enabled convar (0).', 'gauge', {
        ('%s_enabled %d'):format(prefix, self.enabled),
    })
    appendFamily(lines, prefix .. '_ticker_iterations_total', 'Completed admission ticker iterations.', 'counter', {
        ('%s_ticker_iterations_total %d'):format(prefix, self.tickerIterations),
    })
    appendFamily(lines, prefix .. '_ticker_failures_total', 'Admission ticker iterations that raised an error (the loop continues).', 'counter', {
        ('%s_ticker_failures_total %d'):format(prefix, self.tickerFailures),
    })
    appendFamily(lines, prefix .. '_ticker_last_run_timestamp_seconds', 'Unix time of the last completed ticker iteration.', 'gauge', {
        ('%s_ticker_last_run_timestamp_seconds %d'):format(prefix, self.tickerLastRunAt),
    })
    local tickerAge = (queueStatus and queueStatus.monotonicNow and self.tickerLastRunClock > 0)
        and math.max(0, queueStatus.monotonicNow - self.tickerLastRunClock) or -1
    appendFamily(lines, prefix .. '_ticker_last_tick_age_seconds', 'Seconds since the last completed ticker iteration on the resource clock (-1 before the first tick). Rising while scrapes succeed means admissions are stalled.', 'gauge', {
        ('%s_ticker_last_tick_age_seconds %s'):format(prefix, number(tickerAge)),
    })
    local tickSamples = {}
    for i = 1, #tickBucketOrder do
        local key = tostring(tickBucketOrder[i])
        tickSamples[#tickSamples + 1] = ('%s_tick_duration_seconds_bucket{le="%s"} %d'):format(prefix, number(tickBucketOrder[i]), self.tickDurationBuckets[key] or 0)
    end
    tickSamples[#tickSamples + 1] = ('%s_tick_duration_seconds_bucket{le="+Inf"} %d'):format(prefix, self.tickDurationCount)
    tickSamples[#tickSamples + 1] = ('%s_tick_duration_seconds_sum %s'):format(prefix, number(self.tickDurationSum))
    tickSamples[#tickSamples + 1] = ('%s_tick_duration_seconds_count %d'):format(prefix, self.tickDurationCount)
    appendFamily(lines, prefix .. '_tick_duration_seconds', 'Wall time of one admission ticker iteration (queue tick plus result handling).', 'histogram', tickSamples)
    appendFamily(lines, prefix .. '_event_callback_errors_total', 'Queue observer callback errors isolated by the queue (state transitions completed anyway).', 'counter', {
        ('%s_event_callback_errors_total %d'):format(prefix, self.eventCallbackErrors),
    })

    -- Duration histogram helper for the reconcile/presence/in-flight families.
    local function appendDurationHistogram(name, help, buckets, count, sum)
        local samples = {}
        for i = 1, #durationBucketOrder do
            local key = tostring(durationBucketOrder[i])
            samples[#samples + 1] = ('%s_bucket{le="%s"} %d'):format(name, number(durationBucketOrder[i]), buckets[key] or 0)
        end
        samples[#samples + 1] = ('%s_bucket{le="+Inf"} %d'):format(name, count)
        samples[#samples + 1] = ('%s_sum %s'):format(name, number(sum))
        samples[#samples + 1] = ('%s_count %d'):format(name, count)
        appendFamily(lines, name, help, 'histogram', samples)
    end

    appendDurationHistogram(prefix .. '_reconcile_duration_seconds',
        'Wall time of one wait-estimate reconcile pass (the queue O(n) refresh, at most once per frame).',
        self.reconcileBuckets, self.reconcileCount, self.reconcileSum)
    appendDurationHistogram(prefix .. '_presence_sweep_duration_seconds',
        'Wall time of one per-second presence sweep over the waiting queue.',
        self.presenceSweepBuckets, self.presenceSweepCount, self.presenceSweepSum)
    appendDurationHistogram(prefix .. '_in_flight_duration_seconds',
        'Time from admission to load completion or in-flight timeout.',
        self.inFlightDurationBuckets, self.inFlightDurationCount, self.inFlightDurationSum)

    appendFamily(lines, prefix .. '_abandoned_removed_total', 'Queued connections reaped by the presence sweep after the disconnect grace.', 'counter', {
        ('%s_abandoned_removed_total %d'):format(prefix, self.abandonedRemoved),
    })

    local duplicateSamples = {}
    for i = 1, #duplicateStates do
        local state = duplicateStates[i]
        duplicateSamples[#duplicateSamples + 1] = ('%s_duplicates_detected_total{state="%s"} %d'):format(prefix, state, self.duplicatesDetected[state])
    end
    appendFamily(lines, prefix .. '_duplicates_detected_total', 'Connection attempts enqueued behind a matching queued or joining identity, by that match state.', 'counter', duplicateSamples)

    -- Gauges derived from the queue snapshot: admission headroom, effective
    -- config, backlog high-water, and identity-index cardinality (a rising
    -- largest-group is the signature of a single-identity connection flood).
    appendFamily(lines, prefix .. '_token_bucket_available', 'Current admission tokens available in the global rate bucket.', 'gauge', {
        ('%s_token_bucket_available %s'):format(prefix, number(queueStatus.tokens or 0)),
    })
    appendFamily(lines, prefix .. '_release_rate_per_second', 'Effective admission rate (releases per second).', 'gauge', {
        ('%s_release_rate_per_second %s'):format(prefix, number(queueStatus.ratePerSecond or 0)),
    })
    appendFamily(lines, prefix .. '_release_max_in_flight', 'Effective maximum concurrent admitted-but-loading connections.', 'gauge', {
        ('%s_release_max_in_flight %d'):format(prefix, queueStatus.maxInFlight or 0),
    })
    appendFamily(lines, prefix .. '_queue_backlog_high_water', 'Largest queue depth observed since start.', 'gauge', {
        ('%s_queue_backlog_high_water %d'):format(prefix, queueStatus.backlogHighWater or 0),
    })
    local index = queueStatus.index or {}
    appendFamily(lines, prefix .. '_identity_index_identifiers', 'Distinct identity keys currently indexed across queued connections.', 'gauge', {
        ('%s_identity_index_identifiers %d'):format(prefix, index.identifiers or 0),
    })
    appendFamily(lines, prefix .. '_identity_largest_duplicate_group', 'Most queued connections sharing a single identity key (flood indicator).', 'gauge', {
        ('%s_identity_largest_duplicate_group %d'):format(prefix, index.largestGroup or 0),
    })

    return table.concat(lines, '\n') .. '\n'
end

Lavender.Metrics = Metrics
return Metrics
