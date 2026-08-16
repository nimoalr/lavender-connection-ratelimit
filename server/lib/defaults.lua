Lavender = Lavender or {}

local Defaults = {
    version = 1,
    release = {
        ratePerSecond = 0.1,
        burst = 1,
        maxInFlight = 1,
        inFlightTimeoutSeconds = 120,
    },
    identity = {
        similarityThreshold = 0.8,
        activeDuplicatePolicy = 'queue',
        userCooldownSeconds = 60,
        recentHistorySeconds = 600,
    },
    priority = {
        identifiers = {},
    },
    ip = {
        spacingSeconds = 5,
    },
    queue = {
        maxSize = 128,
        maxWaitSeconds = 900,
        disconnectGraceSeconds = 5,
    },
    display = {
        adaptiveCards = true,
        refreshSeconds = 2,
        title = 'Connection Queue',
        serverName = 'the server',
    },
    password = {
        enabled = false,
        secret = '',
        maxAttempts = 3,
        timeoutSeconds = 120,
    },
    metrics = {
        enabled = true,
        path = '/metrics',
        prefix = 'lavender_connection_ratelimit',
        waitBucketsSeconds = { 1, 5, 10, 30, 60, 120, 300, 600, 900 },
    },
    messages = {
        queued = 'Your connection is queued.',
        joining = 'Your connection is being admitted. Please wait...',
        duplicate = 'A matching connection is already queued or joining.',
        queueFull = 'The connection queue is full. Please try again shortly.',
        queueTimeout = 'You waited in the connection queue for too long. Please try again.',
        disconnected = 'The connection window was closed. Please reconnect.',
        resourceStop = 'The connection limiter restarted. Please reconnect.',
        internalError = 'The connection limiter encountered an error. Please try again.',
        passwordPrompt = 'This server is password protected. Enter the password to continue.',
        passwordIncorrect = 'Incorrect password.',
        passwordTimeout = 'Password entry timed out. Please reconnect and try again.',
    },
}

Lavender.Defaults = Defaults
return Defaults
