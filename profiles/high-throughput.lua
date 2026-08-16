-- High-throughput production profile. Copy this file over config.lua to activate it.
-- Runtime command edits regenerate the active config.lua with complete standard comments.
-- Custom comments and formatting are not preserved after a runtime edit.
return {
    -- Configuration schema version. Must remain 1.
    version = 1,

    -- Controls how queued connections are released into FXServer.
    release = {
        -- Global admission tokens added per second. Use 0.1 for one every 10 seconds.
        ratePerSecond = 5,
        -- Maximum stored admission tokens, allowing short bursts up to this size.
        burst = 10,
        -- Maximum released connections still loading before further admissions pause.
        maxInFlight = 30,
        -- Seconds before an in-flight connection is cleared if playerJoining is not observed.
        inFlightTimeoutSeconds = 120,
    },

    -- Controls duplicate detection and pacing for matching non-IP identities.
    identity = {
        -- Jaccard similarity from 0 to 1 required to consider two identity sets the same user.
        similarityThreshold = 0.8,
        -- How active matching queued/joining attempts are handled: "queue" or "reject".
        activeDuplicatePolicy = "queue",
        -- Seconds a recently admitted matching user must wait before becoming eligible again.
        userCooldownSeconds = 60,
        -- Seconds to retain recently admitted identity sets; must cover the user cooldown.
        recentHistorySeconds = 600,
    },

    -- Priority identities that bypass Lavender queue, rate, cooldown, IP, and in-flight gates.
    priority = {
        -- Exact non-IP identifiers such as license:..., license2:..., discord:..., fivem:..., or token:....
        identifiers = { },
    },

    -- Controls independent pacing for connections sharing an IP address.
    ip = {
        -- Seconds between eligibility slots for one IP. IP alone never marks a duplicate.
        spacingSeconds = 5,
    },

    -- Bounds queue size, waiting time, and disconnected-entry cleanup.
    queue = {
        -- Maximum number of connections allowed to wait in the queue.
        maxSize = 128,
        -- Maximum seconds a connection may remain queued before rejection.
        maxWaitSeconds = 900,
        -- Seconds a missing queued source is tolerated before removal.
        disconnectGraceSeconds = 5,
    },

    -- Controls the queue status shown to connecting players.
    display = {
        -- Show Adaptive Cards when true; use deferrals.update text when false.
        adaptiveCards = true,
        -- Seconds between queue-card or fallback-text refreshes.
        refreshSeconds = 2,
        -- Heading displayed on the queue card and fallback status line.
        title = "Connection Queue",
        -- Server name displayed beneath the queue heading.
        serverName = "the server",
    },

    -- Optional Adaptive Card password gate applied to every connection.
    password = {
        -- Require the shared password before any connection may queue or join.
        enabled = false,
        -- Shared password. Must not be empty while enabled is true.
        secret = "",
        -- Password submissions allowed before the connection is rejected.
        maxAttempts = 3,
        -- Seconds allowed for each password submission before rejection.
        timeoutSeconds = 120,
    },

    -- Controls the public Prometheus-compatible resource HTTP route.
    metrics = {
        -- Expose the metrics route when true.
        enabled = true,
        -- Resource-local HTTP path. The public route also includes the resource name.
        path = "/metrics",
        -- Prefix used for every emitted Prometheus metric name.
        prefix = "lavender_connection_ratelimit",
        -- Strictly increasing queue-wait histogram bucket boundaries in seconds.
        waitBucketsSeconds = { 1, 5, 10, 30, 60, 120, 300, 600, 900 },
    },

    -- User-facing connection, rejection, timeout, and restart messages.
    messages = {
        -- Initial text shown immediately after a connection enters the queue.
        queued = "Your connection is queued.",
        -- Text shown immediately before Lavender releases the deferral.
        joining = "Your connection is being admitted. Please wait...",
        -- Rejection shown when a matching connection is already queued or in flight.
        duplicate = "A matching connection is already queued or joining.",
        -- Rejection shown when queue.maxSize has been reached.
        queueFull = "The connection queue is full. Please try again shortly.",
        -- Rejection shown when queue.maxWaitSeconds has elapsed.
        queueTimeout = "You waited in the connection queue for too long. Please try again.",
        -- Rejection shown when the deferral window appears to have been closed.
        disconnected = "The connection window was closed. Please reconnect.",
        -- Rejection shown to queued connections when this resource stops.
        resourceStop = "The connection limiter restarted. Please reconnect.",
        -- Fallback rejection shown after an unexpected limiter error.
        internalError = "The connection limiter encountered an error. Please try again.",
        -- Prompt shown on the password card when the password gate is enabled.
        passwordPrompt = "This server is password protected. Enter the password to continue.",
        -- Text shown after an incorrect password submission.
        passwordIncorrect = "Incorrect password.",
        -- Rejection shown when a password submission window elapses.
        passwordTimeout = "Password entry timed out. Please reconnect and try again.",
    },
}
