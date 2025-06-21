local env = require("config.get_env")
local rate_limit_store = {}

return function ()
    return function (req, res, next)
        -- Attempt to get IP from X-Forwarded-For header first (most common for proxies)

        if req.method == "GET" then
            local url = (req and req._raw and req._raw:getUrl()) or (req.url and req.url or "") or nil
            if url and  url:find("/sse/") then
                -- If the request is for Server-Sent Events (SSE), we can skip rate limiting
                print("Skipping rate limiting for SSE request.")
                next()
                return
            end
        end

        local ip = nil
        -- Check if the request method is OPTIONS (CORS preflight)
        -- If so, we can skip rate limiting for these requests.
        if req.method == "OPTIONS" then
            -- Bypass rate limiting for OPTIONS requests (CORS preflight)
            next()
            return
        end

        if req.method == "WS" then
            ip = req.headers and req.headers["x-forwarded-for"] or nil
        else
            -- For non-WS requests, we can use the raw request object to get headers
            ip = req  and req._raw:getHeader("x-forwarded-for") or nil
    
        end

        if ip and ip ~= "" then
            -- If X-Forwarded-For contains multiple IPs (e.g., "client_ip, proxy1_ip, proxy2_ip")
            -- The first one is typically the actual client.
            local first_ip = string.match(ip, "([^,]+)")
            if first_ip then
                ip = first_ip
            end
        else
            -- Fallback: If X-Forwarded-For is not present or empty, try res:getRemoteAddress()
            -- (Note: As discussed, this might still be empty in your current setup, but it's the direct peer IP).
            ip = res and  res:getRemoteAddress() or nil
        end

        -- If IP is still not found, you might want to log an error or use a placeholder
        if not ip or ip == "" then
            print("Warning: Could not determine client IP address for rate limiting.")
            -- Decide how to handle this: either allow the request (less secure)
            -- or block it (more secure, but might block legitimate requests if IP detection fails).
            -- For demonstration, we'll use a generic placeholder, but in production,
            -- you might want stricter handling or an alternative identifier.
            ip = "unknown_ip_" .. tostring(req) -- Use a unique identifier for this request if IP is truly unknown
        end

        local now = os.time()

        local window = env and env.RATE_LIMITING_WINDOW_IN_SECS or 10-- seconds
        local max_requests = env and env.RATE_LIMITING_MAX_REQUESTS or  5

        local record = rate_limit_store[ip] or { count = 0, last = now }
        if now - record.last > window then
            record = { count = 1, last = now }
        else
            record.count = record.count + 1
        end

        if record.count > max_requests then
            print("Too many requests from IP: " .. ip)
            res:writeStatus(429):send("Too Many Requests")
            return
        end

        rate_limit_store[ip] = record
        next()
    end
end