-- Connecting-storm load harness for the admission queue.
--
-- Reproduces the main-thread cost of a mass reconnect. The FXServer fires one
-- `playerConnecting` per arriving client, all on the game thread, and the
-- resource runs a 100 ms admission ticker on that same thread. When a worker
-- crashes, thousands of clients reconnect at once and the queue backs up. This
-- harness measures the two synchronous hot paths as the backlog grows:
--   * enqueue + wait-estimate  (what onPlayerConnecting runs per arrival)
--   * tick()                   (what runTicker runs every 100 ms)
-- and projects the worst single-frame stall a real svMain frame would take.
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
-- batch of identical operations and dividing.
local function timeAvg(iters, fn)
    collectgarbage('collect')
    local t0 = os.clock()
    for _ = 1, iters do fn() end
    return (os.clock() - t0) * 1000 / iters -- ms per op
end

local TICK_ITERS = math.floor(envnum('STORM_TICK_ITERS', 20))
local checkpoints = { 250, 500, 1000, 2000, 3000, 4000 }
local rows = {}
local next_i = 1
for _, target in ipairs(checkpoints) do
    if target > PLAYERS then break end
    -- grow the backlog to `target`, timing only the enqueue calls (what
    -- onPlayerConnecting runs synchronously per arrival; it does NOT look up
    -- position, so getPosition is measured separately below).
    local addFrom = next_i
    local t0 = os.clock()
    while q:status().queueSize < target and next_i <= PLAYERS do
        q:enqueue(arrivals[next_i])
        next_i = next_i + 1
    end
    local added = next_i - addFrom
    local enq_ms = added > 0 and (os.clock() - t0) * 1000 / added or 0
    local size = q:status().queueSize
    -- one tick() at this backlog, averaged over many iterations
    local tick_ms = timeAvg(TICK_ITERS, function() q:tick() end)
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
    rows[#rows + 1] = { size = size, enq_ms = enq_ms, tick_ms = tick_ms, pos_ms = pos_ms }
    if size < target then break end -- PLAYERS exhausted
end

-- Frame projection: in one 100 ms server frame, ARRIVAL_PER_SEC/10 clients
-- arrive (each an enqueue) and the ticker runs once, all synchronous. Use the
-- costs measured at the largest backlog reached.
local last = rows[#rows]
local perFrame = math.max(1, math.floor(ARRIVAL_PER_SEC * FRAME_SECONDS))
local worst_frame_ms = last and (perFrame * last.enq_ms + last.tick_ms) or 0

io.write('\n== connecting-storm result ==\n')
io.write(('lib_dir          %s\n'):format(libDir))
io.write(('backlog grown to %d  (dup fraction %.2f)\n'):format(last and last.size or 0, DUP_FRACTION))
io.write('\ncost as the backlog grows (per-operation, admission frozen):\n')
io.write('  queue_size   enqueue_ms   tick_ms   getPosition_ms\n')
for _, r in ipairs(rows) do
    io.write(('  %9d   %10.4f   %8.4f   %12.4f\n'):format(r.size, r.enq_ms, r.tick_ms, r.pos_ms))
end
io.write('\nprojected worst single-frame stall (one 100ms frame at peak backlog):\n')
io.write(('  %d arrivals/frame x %.4f ms enqueue  +  %.4f ms tick  =  %.1f ms\n'):format(
    perFrame, last and last.enq_ms or 0, last and last.tick_ms or 0, worst_frame_ms))
io.write(('\nSUMMARY lib=%s backlog=%d enqueue_ms=%.4f tick_ms=%.4f worst_frame_ms=%.1f\n'):format(
    libDir, last and last.size or 0, last and last.enq_ms or 0, last and last.tick_ms or 0, worst_frame_ms))
