-- Connecting-storm load harness for the admission queue.
--
-- Reproduces the main-thread cost of a mass reconnect. The FXServer fires one
-- `playerConnecting` per arriving client, all on the game thread, and the
-- resource runs a 100 ms admission ticker on that same thread. When a worker
-- crashes, thousands of clients reconnect at once and the queue backs up. This
-- harness measures the two synchronous hot paths as the backlog grows:
--   * enqueue + wait-estimate  (what onPlayerConnecting runs per arrival)
--   * tick()                   (what runTicker runs every 100 ms)
-- and projects the per-frame stall a real svMain frame would take from the
-- AVERAGE costs (the max dirty tick is reported separately; time is frozen,
-- admissions are disabled and callbacks are empty, so native work, deferral
-- traffic and the presence sweep are NOT included).
--
-- The queue/identity libraries load from LIB_DIR (arg[1] or LAVENDER_LIB_DIR,
-- default 'server/lib'), so the SAME harness runs the current code and a
-- checkout of the pre-fix code for a direct comparison. server/main.lua is
-- never loaded, so no FXServer natives are needed.
--
-- Env tunables: STORM_PLAYERS (max backlog to grow to, default 4000),
-- STORM_DUP_FRACTION (share of arrivals reusing a queued identity, default
-- 0.40 -- the reconnect-retry case that exercises duplicate detection),
-- STORM_ARRIVAL_PER_SEC (arrivals/sec for the frame projection, default 600).

local libDir = (arg and arg[1]) or os.getenv('LAVENDER_LIB_DIR') or 'server/lib'
local function loadlib(name)
    local chunk, err = loadfile(libDir .. '/' .. name)
    if not chunk then error(('cannot load %s/%s: %s'):format(libDir, name, tostring(err))) end
    return chunk()
end

Lavender = {}
loadlib('util.lua'); loadlib('defaults.lua'); loadlib('config.lua')
loadlib('config_lua.lua'); loadlib('config_store.lua'); loadlib('identity.lua')
loadlib('admission.lua'); loadlib('deferral.lua'); loadlib('queue.lua')

local Util = Lavender.Util
local Identity = Lavender.Identity
local Queue = Lavender.Queue

local function envnum(name, d) local v = tonumber(os.getenv(name)); if v == nil then return d end; return v end
local PLAYERS = math.floor(envnum('STORM_PLAYERS', 4000))
local DUP_FRACTION = envnum('STORM_DUP_FRACTION', 0.40)
local ARRIVAL_PER_SEC = envnum('STORM_ARRIVAL_PER_SEC', 600)
local FRAME_SECONDS = 0.1

-- Deterministic PRNG so runs are comparable across versions.
local seed = 1234567
local function rnd() seed = (1103515245 * seed + 12345) % 2147483648; return seed / 2147483648 end

local function identityFor(base)
    return Identity.fromRaw({
        'license:l' .. base, 'license2:m' .. base, 'discord:d' .. base,
        'fivem:f' .. base, 'live:v' .. base, 'xbl:x' .. base,
    }, { 'tokA' .. base, 'tokB' .. base })
end

-- Pre-build arrivals: a mix of fresh identities and reconnect retries of an
-- already-generated identity (the duplicate path).
local arrivals, bases = {}, {}
for i = 1, PLAYERS do
    local base
    if i > 1 and rnd() < DUP_FRACTION then
        base = bases[1 + math.floor(rnd() * #bases)] or ('u' .. i)
    else
        base = 'u' .. i; bases[#bases + 1] = base
    end
    arrivals[i] = {
        sourceKey = tostring(i), name = 'player-' .. i,
        ip = ('10.%d.%d.%d'):format(math.floor(i / 65536) % 256, math.floor(i / 256) % 256, i % 256),
        identitySet = identityFor(base), payload = {},
    }
end

-- Admission held to zero (burst/maxInFlight 0) so the backlog holds steady at
-- each checkpoint and we measure the per-operation cost cleanly. ratePerSecond
-- is kept non-zero only to avoid a divide-by-zero inside the wait estimator.
local config = Util.deepCopy(Lavender.Defaults)
config.release.ratePerSecond = 1
config.release.burst = 0
config.release.maxInFlight = 0
config.identity.userCooldownSeconds = 30
config.ip.spacingSeconds = 0
config.queue.maxSize = PLAYERS * 2
config.queue.maxWaitSeconds = 1e9

local now = 1000
local q = Queue.new({ now = function() return now end, config = config, onEvent = function() end })
q:fillBucket()

-- A coarse OS clock (Windows os.clock is ~1 ms) is made usable by timing a
-- batch of identical operations and dividing: with 20 iterations the average
-- resolves to ~0.05 ms, so trailing decimals are not significant. The max is
-- per iteration and therefore only meaningful above the clock granularity.
-- GC is collected before each batch; allocation-triggered GC inside a batch is
-- part of the measured cost, as it is in production.
local function timeStats(iters, fn)
    collectgarbage('collect')
    local total, worst = 0, 0
    for _ = 1, iters do
        local t0 = os.clock()
        fn()
        local dt = os.clock() - t0
        total = total + dt
        if dt > worst then worst = dt end
    end
    return total * 1000 / iters, worst * 1000 -- avg ms per op, max ms
end
local function timeAvg(iters, fn)
    local avg = timeStats(iters, fn)
    return avg
end

local TICK_ITERS = math.floor(envnum('STORM_TICK_ITERS', 20))
local checkpoints = { 250, 500, 1000, 2000, 3000, 4000 }
local rows = {}
local next_i = 1
for _, target in ipairs(checkpoints) do
    if target > PLAYERS then break end
    -- grow the backlog to `target`, timing ONLY the enqueue calls (what
    -- onPlayerConnecting runs synchronously per arrival; it does NOT look up
    -- position, so getPosition is measured separately below). The loop must not
    -- call status() (an O(n) scan) inside the timed region: count accepted
    -- enqueues instead.
    local addFrom = next_i
    local size = 0
    if q.size then size = q:size() else size = q:status().queueSize end
    collectgarbage('collect')
    local t0 = os.clock()
    while size < target and next_i <= PLAYERS do
        if q:enqueue(arrivals[next_i]) then size = size + 1 end
        next_i = next_i + 1
    end
    local added = next_i - addFrom
    local enq_ms = added > 0 and (os.clock() - t0) * 1000 / added or 0
    size = q:status().queueSize
    -- The DIRTY tick is the one that matters: with a dirty-gated reconcile only
    -- the first tick after a change pays the O(n) pass, so averaging it with
    -- clean ticks would understate the frame cost 20x. Force the flag before
    -- every timed tick and report the clean tick separately. The flag is an
    -- implementation field, set here because the harness must reproduce "a
    -- change happened this frame" without paying an enqueue inside the timed
    -- region; it reaches the same reconcile branch an enqueue does.
    --
    -- Code WITHOUT the flag (the pre-fix baseline) reconciles inside every
    -- enqueue and, in tick, only after an admission. With admission frozen its
    -- tick column therefore contains NO reconcile: compare the baseline on its
    -- enqueue_ms (where its reconcile is paid) and on the projected frame, not
    -- on the tick columns.
    local tick_ms, tick_max_ms = timeStats(TICK_ITERS, function()
        if q.dirty ~= nil then q.dirty = true end
        q:tick()
    end)
    local clean_ms = timeAvg(TICK_ITERS, function() q:tick() end)
    -- getPosition() cost (used by the card/display refresh, not by the connect
    -- handler) -- reported so the display path's scaling is visible too.
    local pos_ms = 0
    if q.getPosition then
        local ids = {}
        for j = 1, math.min(50, size) do ids[j] = q.entries[1 + math.floor(rnd() * size)].id end
        pos_ms = timeAvg(#ids > 0 and #ids or 1, (function()
            local k = 0
            return function() k = (k % #ids) + 1; q:getPosition(ids[k]) end
        end)())
    end
    rows[#rows + 1] = { size = size, enq_ms = enq_ms, tick_ms = tick_ms, tick_max_ms = tick_max_ms, clean_ms = clean_ms, pos_ms = pos_ms }
    if size < target then break end -- PLAYERS exhausted
end

-- Frame projection: in one 100 ms server frame, ARRIVAL_PER_SEC/10 clients
-- arrive (each an enqueue) and the ticker runs once, all synchronous. Uses the
-- AVERAGE costs measured at the largest backlog reached; it is a projection,
-- not a measured worst case (see tick_max_ms for the largest single tick).
local last = rows[#rows]
local perFrame = math.max(1, math.floor(ARRIVAL_PER_SEC * FRAME_SECONDS))
local frame_ms = last and (perFrame * last.enq_ms + last.tick_ms) or 0
local hasDirtyFlag = q.dirty ~= nil

io.write('\n== connecting-storm result ==\n')
io.write(('lib_dir          %s\n'):format(libDir))
io.write(('backlog grown to %d  (dup fraction %.2f)\n'):format(last and last.size or 0, DUP_FRACTION))
io.write('\ncost as the backlog grows (per-operation averages, admission frozen; ~0.05 ms resolution):\n')
io.write('  queue_size   enqueue_ms   dirty_tick_ms   tick_max_ms   clean_tick_ms   getPosition_ms\n')
for _, r in ipairs(rows) do
    io.write(('  %9d   %10.3f   %13.2f   %11.2f   %13.2f   %14.3f\n'):format(r.size, r.enq_ms, r.tick_ms, r.tick_max_ms, r.clean_ms, r.pos_ms))
end
io.write('  enqueue_ms is per arrival (accepted or rejected), the cost onPlayerConnecting pays synchronously.\n')
if not hasDirtyFlag then
    io.write('  NOTE: this queue has no dirty flag (pre-fix baseline): it reconciles inside enqueue and, in tick,\n')
    io.write('  only after an admission. Its tick columns contain no reconcile; compare enqueue_ms and the frame.\n')
end
io.write('\nprojected frame stall from the averages (one 100ms frame at peak backlog, one dirty tick):\n')
io.write(('  %d arrivals/frame x %.3f ms enqueue  +  %.2f ms dirty tick  =  %.1f ms   (largest single tick seen: %.2f ms)\n'):format(
    perFrame, last and last.enq_ms or 0, last and last.tick_ms or 0, frame_ms, last and last.tick_max_ms or 0))
io.write(('\nSUMMARY lib=%s backlog=%d enqueue_ms=%.4f dirty_tick_ms=%.4f tick_max_ms=%.4f clean_tick_ms=%.4f frame_ms=%.1f dirty_flag=%s\n'):format(
    libDir, last and last.size or 0, last and last.enq_ms or 0, last and last.tick_ms or 0, last and last.tick_max_ms or 0,
    last and last.clean_ms or 0, frame_ms, tostring(hasDirtyFlag)))
