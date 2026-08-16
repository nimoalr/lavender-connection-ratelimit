Lavender = Lavender or {}

local Http = {}

local function respond(response, status, headers, body)
    response.writeHead(status, headers or {})
    response.send(body or '')
end

function Http.metricsHandler(getConfig, render)
    return function(request, response)
        local config = getConfig()

        if not config.enabled or request.path ~= config.path then
            respond(response, 404, { ['Content-Type'] = 'text/plain; charset=utf-8' }, 'Not found.\n')
            return
        end

        if request.method ~= 'GET' then
            respond(response, 405, {
                ['Content-Type'] = 'text/plain; charset=utf-8',
                ['Allow'] = 'GET',
            }, 'Method not allowed.\n')
            return
        end

        local ok, body = pcall(render)
        if not ok then
            respond(response, 500, { ['Content-Type'] = 'text/plain; charset=utf-8' }, 'Metrics rendering failed.\n')
            return
        end

        respond(response, 200, {
            ['Content-Type'] = 'text/plain; version=0.0.4; charset=utf-8',
            ['Cache-Control'] = 'no-store',
        }, body)
    end
end

Lavender.Http = Http
return Http
