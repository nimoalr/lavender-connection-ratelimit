fx_version 'cerulean'
games { 'gta5', 'rdr3' }

name 'lavender-connection-ratelimit'
author 'Nimoa'
description 'Server-only connection admission rate limiter for FXServer deferrals'
version '0.1.0'

server_only 'yes'

server_scripts {
    'server/lib/util.lua',
    'server/lib/defaults.lua',
    'server/lib/config.lua',
    'server/lib/config_lua.lua',
    'server/lib/config_store.lua',
    'server/lib/identity.lua',
    'server/lib/admission.lua',
    'server/lib/deferral.lua',
    'server/lib/queue.lua',
    'server/lib/card.lua',
    'server/lib/metrics.lua',
    'server/lib/http.lua',
    'server/main.lua',
}

files {
    'config.lua',
    'profiles/*.lua',
}
