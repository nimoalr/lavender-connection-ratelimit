Lavender = Lavender or {}

local Util = Lavender.Util

local Card = {}

local reasonText = {
    user_cooldown = function(remaining)
        return ('A matching user recently connected. Cooldown remaining: %s.'):format(Util.formatDuration(remaining))
    end,
    active_duplicate = function(remaining)
        return ('A matching connection is already queued or joining. This attempt will stay queued. Delay remaining: %s.'):format(Util.formatDuration(remaining))
    end,
    ip_pacing = function(remaining)
        return ('Connections from your network are being spaced out. Delay remaining: %s.'):format(Util.formatDuration(remaining))
    end,
    in_flight = function()
        return 'The server is waiting for an admitted connection to finish loading.'
    end,
    global_rate = function(remaining)
        return ('The global connection gate is pacing admissions. Next opportunity in about %s.'):format(Util.formatDuration(remaining))
    end,
    ready = function()
        return 'Your connection is eligible and waiting for the next admission slot.'
    end,
}

function Card.statusText(reason, remaining)
    local formatter = reasonText[reason] or reasonText.ready
    return formatter(remaining or 0)
end

function Card.fallbackMessage(entry, queue, config, runtime)
    -- position and estimatedWait are cached on the entry by the reconcile pass,
    -- so a card render stays O(1) rather than scanning the whole queue.
    local position = entry.position or 0
    local reason, remaining = queue:getEntryReason(entry)
    runtime = runtime or {}

    return ('%s | Position %d/%d | Waited %s | Estimated %s | Players online %s | %s'):format(
        config.display.title,
        position,
        queue:size(),
        Util.formatDuration(queue.now() - entry.enqueuedAt),
        Util.formatDuration(entry.estimatedWait or 0),
        runtime.playersOnlineText or 'unknown',
        Card.statusText(reason, remaining)
    )
end

function Card.build(entry, queue, config, runtime)
    -- Cached, O(1) reads (see fallbackMessage).
    local queueSize = queue:size()
    local position = entry.position or 0
    local reason, remaining = queue:getEntryReason(entry)
    local waited = queue.now() - entry.enqueuedAt
    local estimated = entry.estimatedWait or 0
    runtime = runtime or {}

    return {
        ['$schema'] = 'http://adaptivecards.io/schemas/adaptive-card.json',
        type = 'AdaptiveCard',
        version = '1.0',
        body = {
            {
                type = 'TextBlock',
                text = config.display.title,
                size = 'Large',
                weight = 'Bolder',
                horizontalAlignment = 'Center',
                wrap = true,
            },
            {
                type = 'TextBlock',
                text = ('Connecting to %s'):format(config.display.serverName),
                isSubtle = true,
                horizontalAlignment = 'Center',
                spacing = 'None',
                wrap = true,
            },
            {
                type = 'Container',
                style = 'Emphasis',
                spacing = 'Large',
                items = {
                    {
                        type = 'FactSet',
                        facts = {
                            { title = 'Position', value = ('%d / %d'):format(position, queueSize) },
                            { title = 'Time queued', value = Util.formatDuration(waited) },
                            { title = 'Estimated wait', value = ('about %s'):format(Util.formatDuration(estimated)) },
                            { title = 'Players online', value = runtime.playersOnlineText or 'unknown' },
                        },
                    },
                },
            },
            {
                type = 'TextBlock',
                text = Card.statusText(reason, remaining),
                color = reason == 'ready' and 'Good' or 'Accent',
                weight = 'Bolder',
                horizontalAlignment = 'Center',
                spacing = 'Large',
                wrap = true,
            },
            {
                type = 'TextBlock',
                text = 'Please keep your game open. Your position updates automatically.',
                isSubtle = true,
                horizontalAlignment = 'Center',
                spacing = 'Medium',
                wrap = true,
            },
        },
    }
end

function Card.buildPasswordPrompt(config, options)
    options = options or {}

    local body = {
        {
            type = 'TextBlock',
            text = config.display.title,
            size = 'Large',
            weight = 'Bolder',
            horizontalAlignment = 'Center',
            wrap = true,
        },
        {
            type = 'TextBlock',
            text = ('Connecting to %s'):format(config.display.serverName),
            isSubtle = true,
            horizontalAlignment = 'Center',
            spacing = 'None',
            wrap = true,
        },
        {
            type = 'TextBlock',
            text = config.messages.passwordPrompt,
            horizontalAlignment = 'Center',
            spacing = 'Large',
            wrap = true,
        },
    }

    if options.showError then
        body[#body + 1] = {
            type = 'TextBlock',
            text = config.messages.passwordIncorrect,
            color = 'Attention',
            weight = 'Bolder',
            horizontalAlignment = 'Center',
            wrap = true,
        }
    end

    body[#body + 1] = {
        type = 'Input.Text',
        id = 'password',
        placeholder = 'Password',
        style = 'Password',
        maxLength = 128,
        isMultiline = false,
    }

    if options.attemptsRemaining then
        body[#body + 1] = {
            type = 'TextBlock',
            text = ('Attempts remaining: %d'):format(options.attemptsRemaining),
            isSubtle = true,
            horizontalAlignment = 'Center',
            spacing = 'Medium',
            wrap = true,
        }
    end

    return {
        ['$schema'] = 'http://adaptivecards.io/schemas/adaptive-card.json',
        type = 'AdaptiveCard',
        version = '1.0',
        body = body,
        actions = {
            {
                type = 'Action.Submit',
                title = 'Submit',
            },
        },
    }
end

Lavender.Card = Card
return Card
