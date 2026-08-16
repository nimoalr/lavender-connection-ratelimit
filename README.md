# Lavender Connection Rate Limiter

This resource is a standalone, dependency-free, server-only admission-rate limiter
for FiveM and RedM. It temporarily defers incoming connection attempts so that
expensive connection-time work and player loading begin at a controlled rate.
Eligible attempts are held in memory and released through a global token bucket
and a post-deferral in-flight cap.

This resource is **not** a conventional server slot queue. It does not wait
for player slots, rank players by roles or purchased packages, implement
weighted priority tiers, reserve slots, or replace `sv_maxclients`.

It also provides:

- Duplicate active-connection handling using non-IP identifiers and
  server-specific player tokens.
- A priority allowlist for exact non-IP identifiers that bypasses this resource's
  admission gates.
- Per-user cooldowns after admission and independent per-IP pacing.
- Live, validated configuration edits persisted to a documented `config.lua`.
- Adaptive Card queue status with a text fallback.
- An optional Adaptive Card password gate applied to every connection.
- A Prometheus-compatible metrics endpoint.

This resource is being used to pace connection admissions during Cfx's
[public stress tests for FiveM for GTAV Enhanced](https://forum.cfx.re/t/public-stress-test-calendar-fivem-for-gtav-enhanced/5420662).

## Installation

1. Place this directory in the server's `resources` directory.
2. Customize the active `config.lua`, or replace it with one of the files in
   `profiles/`.
3. Start the resource early in `server.cfg` so it sees every connection:

   ```cfg
   ensure lavender-connection-ratelimit
   ```

4. Grant trusted administrators access to its restricted command:

   ```cfg
   add_ace group.admin command.lavender_rl allow
   ```

The shipped active configuration is the intentionally slow development
profile. It releases one connection every 10 seconds, permits a burst of one,
and allows one post-deferral connection in flight. Choose a production profile
before deploying to a busy server.

## Admission Flow

For every `playerConnecting` event, this resource:

1. Defers the connection.
2. When the password gate is enabled, presents an Adaptive Card password
   prompt and rejects the connection after the configured attempts or
   timeout. The gate applies to every connection, including priority
   identities.
3. Collects the temporary source, player name, IP, all identifiers, and
   server-specific player tokens.
4. Builds an in-memory non-IP identity set. These values are never exposed in
   logs, cards, or metrics.
5. Immediately bypasses this resource's admission gates if any configured priority
   identifier exactly matches the identity set.
6. Applies the configured active-duplicate policy when its Jaccard identity
   similarity to a queued or in-flight connection meets the configured
   threshold. The default policy queues the new attempt behind the active one;
   strict mode rejects it.
7. Queues accepted attempts with independently calculated user-cooldown and
   IP-pacing eligibility timestamps.
8. Uses eligible FIFO scheduling. A temporarily delayed connection does not
   block eligible connections behind it.
9. Releases eligible connections only when the token bucket has capacity and
   the in-flight count is below its limit. Immediately before release, emits
   the server-local `lavender:admitted` integration event.
10. Clears in-flight tracking on `playerJoining(oldID)` or after the
    configured timeout.

IP overlap alone never identifies a duplicate user. Queued entries are removed
after disconnect, Cfx deferral-window closure, or queue timeout. Stopping the
resource rejects all remaining queued connections with a reconnect message.

Queue state, identity history, IP pacing state, and metrics are all in memory
and reset when the resource restarts.

### Admission Event

Immediately before this resource releases an accepted deferral, it emits:

```lua
TriggerEvent('lavender:admitted', ip, ttlSeconds)
```

This is a server-local integration event. A consuming resource can listen for
it as follows:

```lua
AddEventHandler('lavender:admitted', function(ip, ttlSeconds)
    -- Example: send a temporary grant to a resource that controls an
    -- upstream UDP proxy or firewall. Validate both arguments and expire
    -- the grant after ttlSeconds.
end)
```

`ip` is the address observed by the server, without an `ip:` prefix, and may be
IPv4 or IPv6. `ttlSeconds` is currently `120` and is the suggested maximum
lifetime of a temporary grant. Consumers must maintain and expire their own
state.

The event is emitted for both normally queued admissions and priority-bypass
admissions. It means this resource has decided to admit the attempt and is about to
complete its own deferral; it does **not** mean `playerJoining` has fired or
that another deferring resource will accept the connection. The event is
best-effort and has no acknowledgement, retry, replay, revocation, or
persistence. Start consumers before this resource so their handlers exist before
the first admission. If no address is available, this resource logs that the event
was skipped without logging the address itself.

The event deliberately transmits a player network address to server-side
listeners. Treat it as operationally sensitive data. Behind some proxy
topologies, the FXServer-observed address may be the proxy rather than the
original client.

## Profiles

The files under `profiles/` are templates only. This resource always loads the
active `config.lua`.

| Profile | Release rate | Burst | Max in flight |
| --- | ---: | ---: | ---: |
| Development | 0.1/second | 1 | 1 |
| Playtest | 0.1/second | 1 | 100 |
| Conservative | 1/second | 2 | 6 |
| Balanced | 2/second | 4 | 12 |
| High throughput | 5/second | 10 | 30 |

The playtest profile keeps loading players from blocking later releases and
uses a shorter reconnect cooldown. The other shipped profiles use an 80%
identity-similarity threshold, queued duplicate attempts, a 60-second user
cooldown, one same-IP eligibility slot every 5 seconds, a 120-second in-flight
timeout, and a 2-second card refresh.

## Configuration

`config.lua` must return the complete configuration table. It contains standard
comments explaining every field. Unknown keys, missing values, invalid types,
non-finite numbers, and out-of-range values are rejected.

| Path | Purpose |
| --- | --- |
| `version` | Configuration schema version. Must be `1`. |
| `release.ratePerSecond` | Global token refill rate. |
| `release.burst` | Maximum stored release tokens. |
| `release.maxInFlight` | Maximum released connections still loading. |
| `release.inFlightTimeoutSeconds` | Timeout before an in-flight slot is freed. |
| `identity.similarityThreshold` | Jaccard threshold for matching identities. |
| `identity.activeDuplicatePolicy` | `queue` parks active duplicates behind the existing attempt; `reject` bounces them. |
| `identity.userCooldownSeconds` | Minimum time between admissions for a matching identity. |
| `identity.recentHistorySeconds` | Retention time for recently admitted identity sets. |
| `priority.identifiers` | Exact non-IP identifiers that bypass this resource's admission gates. |
| `ip.spacingSeconds` | Spacing between eligibility slots for one IP. |
| `queue.maxSize` | Maximum waiting connections. |
| `queue.maxWaitSeconds` | Maximum time a connection may remain queued. |
| `queue.disconnectGraceSeconds` | Grace period before a missing queued connection is removed. |
| `display.adaptiveCards` | Enables Adaptive Card presentation. |
| `display.refreshSeconds` | Queue status refresh interval. |
| `display.title` | Queue card and fallback title. |
| `display.serverName` | Server name displayed on the card. |
| `password.enabled` | Enables the Adaptive Card password gate for every connection. |
| `password.secret` | Shared password. Must not be empty while the gate is enabled. |
| `password.maxAttempts` | Password submissions allowed before rejection. |
| `password.timeoutSeconds` | Seconds allowed for each password submission. |
| `metrics.enabled` | Enables the metrics route. |
| `metrics.path` | Resource-local metrics path, normally `/metrics`. |
| `metrics.prefix` | Prometheus metric-name prefix. |
| `metrics.waitBucketsSeconds` | Strictly increasing queue-wait histogram buckets. |
| `messages.*` | User-facing queue, rejection, disconnect, timeout, and stop messages. |

An invalid startup file causes a prominent server-console error and activates
embedded development-safe defaults. An invalid runtime reload preserves the
currently active configuration.

Rate, capacity, display, and metrics changes apply live. Existing queued
connections retain the eligibility timestamps already calculated for them.
Changing histogram buckets resets the in-memory queue-wait histogram.

### Runtime Commands

All configuration options can be updated at runtime via console commands.
`lavender_rl` is a restricted server command using the ACE permission
`command.lavender_rl`.

```text
lavender_rl status
lavender_rl config get [dot.path]
lavender_rl config set <dot.path> <value>
lavender_rl config reload
lavender_rl priority list
lavender_rl priority add <identifier>
lavender_rl priority remove <identifier>
```

Examples:

```text
lavender_rl config get release
lavender_rl config set release.ratePerSecond 2
lavender_rl config set release.maxInFlight 12
lavender_rl config set display.adaptiveCards false
lavender_rl config set display.title "Connection Queue"
lavender_rl config set metrics.waitBucketsSeconds [1,5,10,30,60,120]
lavender_rl config set password.secret "hunter2"
lavender_rl config set password.enabled true
lavender_rl priority add license:0123456789abcdef
lavender_rl priority remove license:0123456789abcdef
lavender_rl config reload
```

`config set` accepts JSON-style literals such as numbers, booleans, quoted
strings, and arrays. Bare text is treated as a string. It validates and
persists the complete proposed configuration before it becomes active. A
failed write preserves the current in-memory configuration.

Successful command edits regenerate the complete `config.lua` in a stable
order. The resource's standard field comments are preserved, but custom comments
and manual formatting are replaced.

Priority identifiers should be raw non-IP identifiers such as `license:...`,
`license2:...`, `discord:...`, `fivem:...`, or `steam:...`. `token:<value>` is
also accepted for player tokens. `ip:...` entries are rejected
so a whole network cannot bypass the limiter. Runtime priority commands do not
print configured identifier values back to the console; they only report counts.

## Adaptive Cards

This resource centrally refreshes an Adaptive Card showing:

- Current queue position and total queue size.
- Elapsed and approximate remaining wait.
- Fully connected player count.
- Whether the connection is waiting for active duplicate pacing, user cooldown,
  IP pacing, global rate capacity, or an in-flight slot.

Deferrals are owned per resource, but the currently displayed deferral card is
a shared presentation channel. Another resource handling `playerConnecting`
may replace this resource's card, and this resource may replace the other
resource's card on its next refresh. Every deferring resource must eventually
call its own `deferrals.done()`.

## Password Gate

When `password.enabled` is true, every connection must submit the shared
`password.secret` through an Adaptive Card prompt before it may queue or
join. The prompt allows `password.maxAttempts` submissions and gives each player
`password.timeoutSeconds` before the connection is rejected. Priority
identities do not bypass the gate.

The password card is presented regardless of `display.adaptiveCards`; that
toggle only controls the queue status display. Clients whose deferral UI
cannot present cards cannot pass the gate.

The secret is stored in plain text in `config.lua`, so the file should only
be readable by trusted administrators. `lavender_rl config get` redacts
`password.secret` in console output, but a `config set password.secret ...`
command line itself may be captured by console history or logs. Prefer
editing `config.lua` directly followed by `lavender_rl config reload` when
that matters. Failed and timed-out password attempts are counted in the
`_rejections_total` metric with the reasons `password_failed` and
`password_timeout`; submitted values are never logged.

## Prometheus Metrics

This resource exposes a resource HTTP handler under the actual resource name. With
the default folder name and path, scrape:

```text
http://127.0.0.1:30120/lavender-connection-ratelimit/metrics
```

Example Prometheus scrape configuration:

```yaml
scrape_configs:
  - job_name: fxserver_connection_queue
    metrics_path: /lavender-connection-ratelimit/metrics
    static_configs:
      - targets: ["127.0.0.1:30120"]
```

The endpoint is public and has no application-level authentication.

The endpoint returns Prometheus text exposition format `0.0.4`, returns `404`
for unknown paths, and returns `405` for non-GET requests to the metrics path.
Metric names use `metrics.prefix`, which defaults to
`lavender_connection_ratelimit`.

| Metric suffix | Type |
| --- | --- |
| `_queue_connections` | Gauge |
| `_queue_eligible_connections` | Gauge |
| `_in_flight_connections` | Gauge |
| `_connection_attempts_total` | Counter |
| `_queue_entries_total` | Counter |
| `_admissions_total` | Counter |
| `_rejections_total{reason=...}` | Counter |
| `_queue_departures_total{reason=...}` | Counter |
| `_in_flight_timeouts_total` | Counter |
| `_queue_wait_seconds` | Histogram |

### Grafana Dashboard

`grafana/lavender-connection-ratelimit-dashboard.json` is an importable
dashboard covering every emitted metric: live queue/eligible/in-flight stats,
mean queue wait, queue depth and throughput over time, rejections and
departures by reason (including the password gate), queue-wait percentiles
from the histogram, and in-flight timeouts. Import it via Grafana's
*Dashboards → Import*, then select the Prometheus datasource that scrapes the
metrics route. An `instance` variable filters multi-server setups.

## Testing

The test suite is pure Lua and uses fake clocks and server adapters:

```powershell
lua tests/run.lua
```

It covers identity similarity, duplicate queueing and rejection, token refill,
in-flight limits, eligible FIFO ordering, IP staggering, user cooldowns,
disconnect and timeout cleanup, mandatory deferral ticks, transactional
configuration, profile validation, Adaptive Card privacy, password gate
validation and card structure, the admission-event payload, and Prometheus
route behavior.

For a smoke test with the development profile:

1. Connect one local client and confirm it releases immediately.
2. Connect a distinct second client and confirm it visibly queues.
3. Confirm the second client releases after the first client's
   `playerJoining(oldID)` event frees the in-flight slot and the token bucket
   permits admission.
4. Scrape the metrics route and confirm queue and admission counters change.
