-- dawn_server.lua

local uws = require("uwebsockets")
local Supervisor = require("runtime.loop")
local json = require('dkjson')
local StreamingMultipartParser = require('multipart_parser')
local uv = require("luv")
local URLParamExtractor = require("utils.query_extractor")
local log_level = require('utils.logger').LogLevel
local TokenCleaner = require("auth.token_cleaner")
local Logger = require("utils.logger").Logger
local ServerpatchQueue = require('utils.server_patch_queue')
local DawnWatcher = require('utils.DawnWatcher')
local app_uws = nil

local restart_self = nil

local extractor = URLParamExtractor:new()

local function timestamp()
    return os.date("[%Y-%m-%d %H:%M:%S]")
end

local function extractHttpMethod(request_str)
    -- Extract the first line of the request
    local first_line = request_str:match("([^\r\n]+)")
    if first_line then
        -- Match the method (first word before a space)
        local method = first_line:match("^(%S+)")
        if method then
            return method:lower() -- return it in lowercase
        end
    end
    return "" -- if something fails
end

local TrieNode = {}

function TrieNode:new(logger)
    local self = setmetatable({}, { __index = TrieNode })
    self.children = {}
    self.handlers = {}  -- Change from single handler to table of handlers by method
    self.isEndOfPath = false
    self.params = {}
    self.log = logger
    return self
end

function TrieNode:insert(method, route, handler)
    local node = self
    local parts = {}
    local normalizedRoute = route:lower()
    for part in normalizedRoute:gmatch("([^/]+)") do
        table.insert(parts, part)
    end

    for i, part in ipairs(parts) do
        local paramName = nil
        if part:sub(1, 1) == ":" then
            paramName = part:sub(2)
            part = ":"
        elseif part == "*" then
            part = "*"
        end

        if not node.children[part] then
            node.children[part] = TrieNode:new()
        end
        node = node.children[part]
        if paramName then
            node.params[i] = paramName
        end
    end

    -- ✅ FIX: Store multiple handlers by method
    if node.handlers[method] then
        print(log_level.WARN, string.format("Route conflict: %s %s is being overridden.", method, route), "DawnServer")
    end
    
    node.isEndOfPath = true
    node.handlers[method] = handler  -- Store handler by method
    
    self.log:log(log_level.DEBUG, string.format("Registered route: %s %s", method, route), "DawnServer")
end

function TrieNode:search(method, path)
    local node = self
    local params = {}
    local parts = {}
    local normalizedPath = path:lower()
    for part in normalizedPath:gmatch("([^/]+)") do
        table.insert(parts, part)
    end

    for i, part in ipairs(parts) do
        local child = node.children[part]
        if not child then
            child = node.children[":"]
            if not child then
                child = node.children["*"]
                if child then
                    params.splat = table.concat(parts, "/", i)
                    return child.handlers[method] and child.handlers[method], params
                else
                    return nil, {}
                end
            else
                local paramName = child.params[i]
                if paramName then
                    params[paramName] = part
                end
            end
        end
        node = child
        if not node then
            return nil, {}
        end
    end

    -- ✅ FIX: Look for handler by specific method
    if node and node.isEndOfPath and node.handlers[method] then
        return node.handlers[method], params
    else
        self.log:log(log_level.DEBUG, string.format("Handler not found for method %s at path %s", method, path), "DawnServer")
        return nil, {}
    end
end

local DawnServer = {}
DawnServer.__index = DawnServer

function DawnServer:new(config)
    local self = setmetatable({}, DawnServer)
    self.dawnProcessChild = nil
    self.config = config or {}
    self.uws = uws.create_app()
    app_uws = self.uws
    self.logger = Logger:new(self)
    self.logger:setComponentLevel("DawnServer", config.level)
    self.router = TrieNode:new(self.logger)
    self.middlewares = {}
    self.error_handlers = { middleware = nil, route = {} }
    self.supervisor = Supervisor:new(self, "WebServerSupervisor", "one_for_one", self.logger)
    self.port = config.port or 3000
    self.heartbeat_config = config.heartbeat_config or nil
    self.running = false
    self.multipart_parser_options = config.multipart_parser_options or nil
    self.token_store = config.token_store or {
        store = nil,  cleanup_interval =  1800
    }
    self.reactive_render_engine = config.reactive_render_engine or nil
    self.route_scopes = {}
    self.routes = {}
    self.request_parsers = {}
    self.shared_state = {
        sessions = {},
        players = {},
        metrics = {},
        changed_files = {}
    }

    self.patch_queue = ServerpatchQueue
    -- New member to store static file configurations
    self.static_configs = config.static_configs or {}

    local DawnSockets = require("dawn_sockets")
    self.dawn_sockets_handler = DawnSockets:new(self, self.supervisor, self.shared_state, self.config.state_management_options or {})
    if(self.heartbeat_config) then 
    self.dawn_sockets_handler:start_heartbeat(self.heartbeat_config.interval, self.heartbeat_config.timeout) -- Start heartbeat with 10 seconds interval
    end

    if(self.reactive_render_engine) then
        self.dawn_sockets_handler:setReactiveRenderEngine(self.reactive_render_engine)
    end

    if self.token_store.store then
        self.logger:log(log_level.INFO, "SETTING UP LOGGER", 'dawn_server', 345)

        local cleaner = TokenCleaner:new("TokenCleaner", self.token_store.cleanup_interval, self)
        self.supervisor:startChild(cleaner)
    end

    self.dev_watcher = DawnWatcher:new(self, config.dev_watcher_config or {
        interval = 1, -- seconds
        paths = {
            components = "./lib/*.lua",
            views = "./views/**/*.lua",
            static = "./public/**/*.{css,js}"
        }
    })
    self.ROUTES_REGISTERED = nil

    restart_self = self

    return self
end

function DawnServer:on_error(error_type, handler)
    assert(error_type == "middleware" or error_type == "route", "Invalid error handler type. Must be 'middleware' or 'route'.")
    assert(type(handler) == "function", "Error handler must be a function.")
    self.error_handlers[error_type] = handler
end

function DawnServer:on_route_error(route, handler)
    assert(type(route) == "string", "Route for error handler must be a string.")
    assert(type(handler) == "function", "Route error handler must be a function.")
    self.error_handlers.route[route:lower()] = handler
end

-- List of required methods for a reactive component
local REQUIRED_COMPONENT_METHODS = {
    "patch",            -- Handles WebSocket events
    "setState",         -- Updates state and returns patches
    "renderAppPage"     -- Used to generate the full HTML + state
}


--- 📦 Register a reactive component for WebSocket state patching.
-- Stores it in shared_state under a given key.
-- @param component table - Component instance (with .patch, .setState, .renderAppPage)
-- @param key string? - Storage key (default: "app_component_instance")
function DawnServer:register_reactive_component(component, key)
    key = key or "app_component_instance"

    if not self or not self.shared_state then
        error("[Dawn] Cannot register component: server not attached or missing shared_state.")
    end

    if type(component) ~= "table" then
        error("[Dawn] Component must be a table, got: " .. type(component))
    end

    -- Validate required methods
    for _, method in ipairs(REQUIRED_COMPONENT_METHODS) do
        if type(component[method]) ~= "function" then
            -- print(string.format("[Dawn] ⚠️ Warning: Component under key '%s' is missing method '%s'", key, method))
        end
    end

    if(self.shared_state[key]) then
            print(string.format("[Dawn] X ALready Registered reactive component under key '%s'", key))

    else

            print(string.format("[Dawn] ⏳ Registering reactive component under key '%s'...", key))
            self.shared_state[key] = component
                -- print(string.format("[Dawn] ✅ Registered reactive component under key '%s'", key))

    end
end

--- 🔍 Get a reactive component from shared_state.
-- @param key string? - Component key (default: "app_component_instance")
-- @return table | nil - The component instance or nil
function DawnServer:get_component(key)
    key = key or "app_component_instance"
    if not self or not self.shared_state then return nil end

    -- print every comp key in shared_state
    for k, v in pairs(self.shared_state) do
        print("Component Key:", k)
    end
    
    return self.shared_state[key]
end

--- 🧠 Get just the current state of a reactive component.
-- @param key string? - Component key
-- @return table - Component state (or empty table if missing)
function DawnServer:get_component_state(key)
    local comp = self:get_component(key)
    return comp and comp.state or {}
end

--- 📛 Generate a namespaced patch key: "component_key.field"
-- Useful for client filtering or debugging
-- @param component_key string
-- @param field string
-- @return string
function DawnServer:get_patch_namespace(component_key, field)
    if component_key and field then
        return component_key .. "." .. field
    end
    return field or ""
end

function DawnServer:use(middleware, route)
    assert(type(middleware) == "function", "Middleware must be a function")
    table.insert(self.middlewares, {
        func = middleware,
        route = route,
        global = route == nil
    })
end

function DawnServer:addRoute(method, path, handler, opts)
    if not self.routes[method] then
        self.routes[method] = {}
    end

    table.insert(self.routes[method], {
        path = path,
        handler = handler,
        opts = opts or {}
    })

    self.router:insert(method, path, handler)
end

function DawnServer:scope(prefix, func)
    table.insert(self.route_scopes, prefix)
    func(self)
    table.remove(self.route_scopes)
end

for _, method in ipairs({"get", "post", "put", "delete", "patch", "head", "options"}) do
    DawnServer[method] = function(self, route, handler)
        local scoped_route = table.concat(self.route_scopes, "") .. route
        self:addRoute(method, scoped_route, handler)
    end
end

function DawnServer:ws(route, handler)
    local scoped_route = table.concat(self.route_scopes, "") .. route
    self:addRoute("WS", scoped_route, handler)
end

-- New function to add static file serving configuration
function DawnServer:serveStatic(route_prefix, directory_path)
    assert(type(route_prefix) == "string", "Route prefix for static serving must be a string.")
    assert(type(directory_path) == "string", "Directory path for static serving must be a string.")
    table.insert(self.static_configs, {
        route_prefix = route_prefix,
        directory_path = directory_path
    })
end

-- Corrected wrapper to use a dot for a regular function call
function DawnServer:setInterval(callback, interval, ...)
    return self.uws.setInterval(callback, interval, ...)
end

-- Corrected wrapper to use a dot for a regular function call
function DawnServer:setTimeout(callback, delay, ...)
    return self.uws.setTimeout(callback, delay, ...)
end

-- The clearTimer function is fine, as it's a single argument.
function DawnServer:clearTimer(timer_id)
    return self.uws.clearTimer(timer_id)
end

-- New function to send SSE data
function DawnServer:sse_send(sse_id, data)
    return self.uws.sse_send(sse_id, data)
end

-- New function to close SSE connection
function DawnServer:sse_close(sse_id)
    return self.uws.sse_close(sse_id)
end

--- 🌍 Perform an outbound HTTP request (async)
-- @param url string
-- @param method string (default "GET")
-- @param body string (default "")
-- @param headers table { ["Header"] = "Value" }
-- @param callback function(res) called with {status, body, headers, error}
function DawnServer:http_request(url, method, body, headers, callback)
    assert(type(url) == "string", "url must be a string")
    assert(type(callback) == "function", "callback must be a function")
    return self.uws.http_request(url, method or "GET", body or "", headers or {}, callback)
end

--- 🔗 Convenience GET wrapper
function DawnServer:http_get(url, callback, headers)
    return self:http_request(url, "GET", "", headers or {}, callback)
end

--- 🔗 Convenience POST wrapper
function DawnServer:http_post(url, body, callback, headers)
    return self:http_request(url, "POST", body or "", headers or {}, callback)
end

-- Convenience PUT wrapper
function DawnServer:http_put(url, body, callback, headers)
    return self:http_request(url, "PUT", body or "", headers or {}, callback)
end
-- Convenience DELETE wrapper
function DawnServer:http_delete(url, callback, headers)
    return self:http_request(url, "DELETE", "", headers or {}, callback)
end
-- Convenience PATCH wrapper
function DawnServer:http_patch(url, body, callback, headers)
    return self:http_request(url, "PATCH", body or "", headers or {}, callback)
end
-- Convenience HEAD wrapper
function DawnServer:http_head(url, callback, headers)
    return self:http_request(url, "HEAD", "", headers or {}, callback)
end
-- Convenience OPTIONS wrapper
function DawnServer:http_options(url, callback, headers)
    return self:http_request(url, "OPTIONS", "", headers or {}, callback)
end


local function parseQuery(url)
    return extractor:extract_from_url_like_string(url)
end


-- 🔄 Enhanced Redirect Helper
function DawnServer:redirect(res, location, options)
    local opts = {}
    
    -- Handle different parameter formats
    if type(options) == "number" then
        opts.status = options
    elseif type(options) == "table" then
        opts = options
    end
    
    -- Default values
    opts.status = opts.status or 302
    opts.flash = opts.flash or nil
    opts.preserveMethod = opts.preserveMethod or false
    
    -- Convert status code to status line
    local statusLine
    if type(opts.status) == "number" then
        local statusMap = {
            [301] = "301 Moved Permanently",
            [302] = "302 Found", 
            [303] = "303 See Other",
            [307] = "307 Temporary Redirect",
            [308] = "308 Permanent Redirect",
            [300] = "300 Multiple Choices",
            [304] = "304 Not Modified"
        }
        statusLine = statusMap[opts.status] or tostring(opts.status) .. " Redirect"
    else
        statusLine = opts.status
    end
    
    -- Set redirect headers
    res:writeStatus(statusLine)
    res:writeHeader("Location", location)
    
    -- Add flash message if provided (could use cookies or session)
    if opts.flash then
        res:writeHeader("X-Flash-Message", opts.flash)
    end
    
    -- For 307/308, indicate method should be preserved
    if opts.preserveMethod then
        res:writeHeader("X-Redirect-Preserve-Method", "true")
    end
    
    res:send('')
    
    self.logger:log(
        log_level.DEBUG,
        string.format("Redirect: %s -> %s (Status: %s, Flash: %s)", 
            res._raw and res._raw.url or "unknown", 
            location, 
            statusLine,
            opts.flash or "none"
        ),
        "DawnServer"
    )
end


--------------------------------------------------------
-- 📂 File Operation Helpers (wrapping C++ bindings)
--------------------------------------------------------

--- 🔹 Sync read file
-- @param path string
-- @return string|nil, string|nil (content, error)
function DawnServer:read_file(path)
    return self.uws.sync_read_file(path)
end

--- 🔹 Sync write file
-- @param path string
-- @param data string
-- @return boolean, string|nil (success, error)
function DawnServer:write_file(path, data)
    return self.uws.sync_write_file(path, data)
end

--- 🔹 Async read file
-- @param path string
-- @param cb function(content, err)
function DawnServer:async_read_file(path, cb)
    assert(type(cb) == "function", "callback must be a function")
    self.uws.async_read_file(path, function(content, err)
        cb(content, err)
    end)
end

--- 🔹 Async write file
-- @param path string
-- @param data string
-- @param cb function(success, err)
function DawnServer:async_write_file(path, data, cb)
    assert(type(cb) == "function", "callback must be a function")
    self.uws.async_write_file(path, data, function(success, err)
        cb(success, err)
    end)
end

-- function to execute async tasks
function DawnServer:async(func, ...)
    assert(type(func) == "function", "First argument must be a function")
    self.uws.execute_async(func, ...)
end

--- 🔹 File exists?
-- @param path string
-- @return boolean
function DawnServer:file_exists(path)
    local f = io.open(path, "rb")
    if f then
        f:close()
        return true
    end
    return false
end

--- 🔹 JSON helpers (if dkjson or cjson is available)
function DawnServer:read_json(path, decode)
    local content, err = self:read_file(path)
    if not content then return nil, err end
    local ok, result = pcall(decode or json.decode, content)
    if not ok then
        return nil, "Invalid JSON: " .. tostring(result)
    end
    return result, nil
end

function DawnServer:write_json(path, tbl, encode)
    local ok, result = pcall(encode or json.encode, tbl)
    if not ok then
        return false, "Failed to encode JSON: " .. tostring(result)
    end
    return self:write_file(path, result)
end

--- 🔹 Stream read (async, chunked)
-- Reads file in chunks and calls cb(chunk) for each piece.
-- When error occurs: cb(nil, err)
-- @param path string
-- @param chunk_size integer? (default 65536)
-- @param cb function(chunk, err)
function DawnServer:stream_read_file(path, chunk_size, cb)
    assert(type(cb) == "function", "callback must be a function")
    if type(chunk_size) == "function" then
        cb = chunk_size
        chunk_size = nil
    end
    self.uws.stream_read_file(path, chunk_size or (10 * 1024), function(chunk, err)
        cb(chunk, err)
    end)
end


--- 🔹 Stream write (append mode)
-- Useful for chunked uploads or logs
-- @param path string
-- @param data string
-- @return boolean, string|nil
function DawnServer:stream_write_file(path, data)
    return self.uws.stream_write_file(path, data)
end



function DawnServer:printRoutes()
    self.logger:log(log_level.INFO, "Registered Routes:", "DawnServer")
    local function printNodeRoutes(node, prefix)
        if node.handlers and next(node.handlers) then
            for method, handler in pairs(node.handlers) do
                self.logger:log(log_level.INFO, "  " .. method:upper() .. " " .. prefix, "DawnServer")
            end
        end
        for path, child in pairs(node.children) do
            local slashCount = select(2, prefix:gsub("/", "", 1))
            local param = child.params[slashCount + 1] or ""
            local segment = (path == ":" and "/:" .. param) or (path == "*" and "/*") or ("/" .. path)
            printNodeRoutes(child, prefix .. segment)
        end
    end
    printNodeRoutes(self.router, "")
end

local function log_invisible_chars(str, label)
    local has_invisible = false
    local output = ""
    for i = 1, #str do
        local byte = str:byte(i)
        if byte < 32 or byte > 126 then
            has_invisible = true
            output = output .. string.format("[%d]", byte)
        end
    end
    if has_invisible then
        print("DEBUG", label .. " contains invisible characters (byte codes): " .. output, "DawnServer")
    else
        print("label doesn't have invisible characters")
    end
end

local function handleCORS(req, res)
    if req.method == "OPTIONS" then
        res:writeHeader("Access-Control-Allow-Origin", "*")
        res:writeHeader("Access-Control-Allow-Methods", "GET, POST, PUT, DELETE, PATCH, OPTIONS")
        res:writeHeader("Access-Control-Allow-Headers", "Content-Type, Authorization")
        res:writeHeader("Access-Control-Max-Age", "86400")
        res:writeStatus(200):send()
        return false
    end
    return true
end

local function executeMiddleware(self, req, res, route, middlewares, index)
    index = index or 1
    if index > #middlewares then return true end
    local mw = middlewares[index]
    local matchesScope = mw.global or (mw.route and route:sub(1, #mw.route) == mw.route)
    if matchesScope then
        local nextCalled = false
        local function next()
            nextCalled = true
            return executeMiddleware(self, req, res, route, middlewares, index + 1)
        end

        local ok, err = pcall(function()
            mw.func(req, res, next)
        end)

        if not ok then
            self.logger:log(log_level.ERROR, "Error in middleware: " .. tostring(err), "DawnServer")
            if type(self.error_handlers.middleware) == "function" then
                self.error_handlers.middleware(req, res, err)
            else
                res:writeHeader("Content-Type", "text/plain")
                    :writeStatus(500)
                    :send("Internal Server Error")
            end
            return false
        end

        if not nextCalled then return false end
        return true
    else
        return executeMiddleware(self, req, res, route, middlewares, index + 1)
    end
end




function DawnServer:run()
    print("DawnServer is starting...")
    if self.running then return end
    self.running = true
    -- self.uws.create_app()
    local self_ref = self

    local function decodeURIComponent(str)
        str = str:gsub('+', ' ')
        str = str:gsub('%%(%x%x)', function(h)
            return string.char(tonumber(h, 16))
        end)
        return str
    end

    local function handleRequest(_req, res, chunk, is_last)
    -- URL and path from table field (not method call)
    local path = (_req.url or ""):match("^[^?]*")
    if path ~= "/" and path:sub(-1) == "/" then
        path = path:sub(1, -2)
    end

    -- Method string is already provided
    local method = extractHttpMethod(_req.method)

    -- Search route
    local handler_info, params = self_ref.router:search(method, path)
    local req = {
        _raw = _req,
        params = params,
        method = method
    }

    self_ref.logger:log(
        log_level.DEBUG,
        string.format(
            "Method: %s, Path: %s, Handler Found: %s, Params: %s",
            method,
            path,
            tostring(handler_info ~= nil),
            json.encode(params)
        ),
        "DawnServer"
    )

    if not handleCORS(req, res) then return end

    if handler_info then
        local handler = handler_info
        -- Use snapshot .url to parse query
        local query_params = parseQuery("?"..(_req.query or ""))

        if executeMiddleware(self_ref, req, res, path, self_ref.middlewares, 1) then
            method = string.upper(method)
            if method == "WS" then
                res:writeStatus(404):send("Not Found") -- WS handled separately
            elseif method == "GET" or method == "DELETE" or method == "HEAD" or method == "OPTIONS" then
                -- Normal no-body handlers
                local ok, err = pcall(function()
                    handler(req, res, query_params)
                end)
                if not ok then
                    self_ref.logger:log(log_level.ERROR,
                        string.format("Error in route handler for %s %s: %s", method, path, tostring(err)),
                        "DawnServer")
                    local route_error_handler = self_ref.error_handlers.route[path:lower()]
                    if type(route_error_handler) == "function" then
                        route_error_handler(req, res, err)
                    else
                        res:writeHeader("Content-Type", "text/plain")
                            :writeStatus(500)
                            :send("Internal Server Error")
                    end
                end

            elseif method == "POST" or method == "PUT" or method == "PATCH" then
           -- Access snapshot header via function
local content_type = ((_req.getHeader and _req:getHeader("content-type")) or ""):lower()

local multipart_marker = "multipart/form-data"

if content_type:sub(1, #multipart_marker) == multipart_marker then
    -- Multipart streaming parser path
    req.form_data_parser = StreamingMultipartParser:new(
        content_type,
        function(part)
            req.form_data = req.form_data or {}
            
            if part.is_file then
                local tmp_path = string.format("/tmp/upload_%s_%s", os.time(), part.filename or "nofile")
                local file, err = io.open(tmp_path, "wb")
                if not file then
                    self_ref.logger:log(
                        log_level.ERROR,
                        string.format("Failed to open file for writing: %s", tostring(err)),
                        "DawnServer"
                    )
                    return
                end

                part.on_data = function(data)
                    file:write(data)
                end
                part.on_end = function()
                    file:close()
                    req.form_data[part.name] = {
                        filename = part.filename,
                        path = tmp_path,
                        headers = part.headers,
                        size = part.size
                    }
                end
            else
                local chunks = {}
                part.on_data = function(data)
                    table.insert(chunks, data)
                end
                part.on_end = function()
                    req.form_data[part.name] = table.concat(chunks)
                end
            end
        end,
        self_ref.multipart_parser_options
    )

    local is_tempfile = false

    -- print("chunk : ", chunk)

    -- Process the chunk (this should be inside a loop that receives chunks)
    if type(chunk) == "string" and chunk:sub(1, 6) == "@file:" then
        local tmp_path = chunk:sub(7) -- strip @file:
        local f, err = io.open(tmp_path, "rb")
        if not f then
            self_ref.logger:log(log_level.ERROR,
                string.format("Failed to open temp upload file: %s", tostring(err)),
                "DawnServer")
        else
            is_tempfile = true
            -- print("isfile = ", tostring(is_tempfile))
            while true do
                local data = f:read(8192)
                if not data then break end
                req.form_data_parser:feed(data)
            end
            f:close()
        end
    else
        -- Normal in-memory body - feed the chunk to parser
        -- print("received a normal in memory body")
        req.form_data_parser:feed(chunk or "")
    end

    -- Only call handler when this is the last chunk
    if is_last then
        -- Finalize the parsing (feed boundary end if needed)
        req.form_data_parser:feed("") -- Sometimes needed to flush final data

        -- print("is last  -> ", req.form_data_parser.form_data_parsed)
                
        -- Call the handler with the parsed form data
        local ok, err = pcall(handler, req, res, req.form_data_parser.form_data_parsed)

        if is_tempfile then
            local tmp_path = chunk:sub(7) -- strip @file:
            pcall(os.remove, tmp_path) -- ✅ guaranteed cleanup with pcall for safety
        end

        if not ok then
            self_ref.logger:log(log_level.ERROR,
                string.format("Error in multipart handler for %s %s: %s", method, path, tostring(err)),
                "DawnServer")
            local route_error_handler = self_ref.error_handlers.route[path:lower()]
            if type(route_error_handler) == "function" then
                route_error_handler(req, res, err)
            else
                res:writeHeader("Content-Type", "text/plain")
                   :writeStatus(500)
                   :send("Internal Server Error")
            end
        end
    end

else
                    -- Non-multipart
                    if chunk then
                        req.body = (req.body or "") .. chunk
                    end
                    if is_last then
                        local parsed_body, parse_error

                        if content_type:find("application/json") then
                            parsed_body = json.decode(req.body)
                            if not parsed_body then
                                parse_error = "Failed to parse JSON body"
                                self_ref.logger:log(
                                    log_level.ERROR,
                                    string.format("Error parsing JSON body for %s %s: %s", method, path, parse_error),
                                    "DawnServer"
                                )
                            end
                        elseif content_type:lower():find("application/x-www-form-urlencoded", 1, true) then

                            parsed_body = {}
                            for key, value in (req.body or ""):gmatch("([^&=]+)=([^&=]*)") do
                                local decoded_key = decodeURIComponent(key)
                                local decoded_value = decodeURIComponent(value)
                                parsed_body[decoded_key] = decoded_value
                            end

                        else
                
                            parsed_body = req.body
                        end
                        local ok, err = pcall(handler, req, res, parsed_body, parse_error)
                        if not ok then
                            self_ref.logger:log(
                                log_level.ERROR,
                                string.format("Error in route handler for %s %s: %s", method, path, tostring(err)),
                                "DawnServer"
                            )
                            local rouzte_error_handler = self_ref.error_handlers.route[path:lower()]
                            if type(route_error_handler) == "function" then
                                route_error_handler(req, res, err)
                            else
                                res:writeHeader("Content-Type", "text/plain")
                                    :writeStatus(500)
                                    :send("Internal Server Error")
                            end
                        end
                    end
                end
            end
        end
    else
        -- Fallback 404
        res:writeStatus(404):send("Not Found")
    end
end

        local function get_ws_id(ws)
    if ws then
        local get_id_func = getmetatable(ws).get_id
        return get_id_func(ws)
    else
        print("Error: WebSocket object is nil or does not have get_id method.")
        return nil
    end
end
local function registerRouteHandlers(node, prefix)
    -- ✅ FIX: Check if there are any handlers (multiple methods possible)
    if node.handlers and next(node.handlers) then
        -- ✅ FIX: Iterate through ALL methods for this path
        for method, handler_func in pairs(node.handlers) do
            local routePath = prefix
            local method_lower = method:lower()
            
            print(log_level.DEBUG, 
                string.format("📝 Registering route: %s %s", method:upper(), routePath), 
                "RouteRegistration"
            )
            
            if method_lower == "ws" then
                self.uws.ws(routePath, function(ws, event, message, code, reason)
                    if event == "open" then
                        local fake_req = {
                            method = "WS",
                            url = routePath,
                            headers = {["x-forwarded-for"] = get_ws_id(ws)},
                            ws = ws
                        }
                        local fake_res = {}
                        fake_res.writeHeader = function() return fake_res end
                        fake_res.writeStatus = function() return fake_res end
                        fake_res.send = function(...)
                            print( "[WS Middleware] Blocking upgrade:", ..., " : dawn_server")
                            ws:close()
                        end
                        local ok = executeMiddleware(self_ref, fake_req, fake_res, routePath, self_ref.middlewares, 1)
                        if ok then
                            self_ref.dawn_sockets_handler:handle_open( ws, message)
                        else
                            print("[WS] Connection rejected by middleware:", routePath)
                        end
                    elseif event == "message" then
                        self_ref.dawn_sockets_handler:handle_message( ws, message, code)
                    elseif event == "close" then
                        self_ref.dawn_sockets_handler:handle_close( ws, code, reason)
                    end
                end)
            elseif method_lower == "get" or method_lower == "delete" or method_lower == "head" or method_lower == "options" then

               -- check if routePath contains '/sse/' to handle SSE
                if routePath:find("/sse/") then
                    self.uws.sse(routePath, function(req, sse_id)
                        local fake_req = {
                            method = "GET",
                            url = routePath,
                            headers = req.headers,
                            sse_id = sse_id
                        }
                        local fake_res = {}
                        fake_res.writeHeader = function() return fake_res end
                        fake_res.writeStatus = function() return fake_res end
                        fake_res.send = function(data)
                            self.uws.sse_send(sse_id, data)
                        end
                        local ok = executeMiddleware(self_ref, fake_req, fake_res, routePath, self_ref.middlewares, 1)
                        if ok then
                            local handler_info, params = self_ref.router:search(method_lower, routePath)
                            pcall(function()
                                if handler_info then
                                    local query_params = parseQuery("?"..(req.query or ""))
                                    handler_func(fake_req, fake_res, query_params)  -- ✅ Use the actual handler
                                else
                                    -- If no specific SSE handler is found, send a default message
                                    self.uws.sse_send(sse_id, "Default SSE message", "default")
                                    self:sse_close(sse_id)
                                    print("[SSE] No handler found for SSE route:", routePath)
                                end
                            end)
                        else
                            print("[SSE] Connection rejected by middleware:", routePath)
                        end
                    end)
                else
                    self.uws[method_lower](routePath, handleRequest)
                end
            elseif method_lower == "post" or method_lower == "put" or method_lower == "patch" then
                self.uws[method_lower](routePath, handleRequest)
            end
        end
    end
    
    for path, child in pairs(node.children) do
        local slashCount = select(2, prefix:gsub("/", "", 1))
        local param = child.params[slashCount + 1] or ""
        local nextPrefix = prefix .. (
            path == ":" and "/:" .. param or
            (path == "*" and "/*" or "/" .. path)
        )
        registerRouteHandlers(child, nextPrefix)
    end
end
    registerRouteHandlers(self.router, "")

    -- Register static file serving using the new self.uws.serve_static function
    for _, config in ipairs(self_ref.static_configs) do
        self_ref.logger:log(log_level.INFO, string.format("Serving static files from '%s' at route '%s'", config.directory_path, config.route_prefix), "DawnServer")
        self.uws.serve_static(config.route_prefix, config.directory_path)

    end

    self:printRoutes()
    self.uws.listen(self.port, function(token)
        if token then
            self.logger:log(log_level.INFO, "Server started on port " .. self.port, "DawnServer")
        end
    end)

end

local function get_ws_id(ws)
    if ws then
        local get_id_func = getmetatable(ws).get_id
        return get_id_func(ws)
    else
        return nil
    end
end

local function decodeURIComponent(str)
    str = str:gsub('+', ' ')
    str = str:gsub('%%(%x%x)', function(h)
        return string.char(tonumber(h, 16))
    end)
    return str
end

function DawnServer:restart_run()
    -- Re-register route handlers
    local self_ref = self

    -- This should be the same handleRequest as in run()
    local function handleRequest(_req, res, chunk, is_last)
        local path = (_req.url or ""):match("^[^?]*")
        if path ~= "/" and path:sub(-1) == "/" then
            path = path:sub(1, -2)
        end
        local method = extractHttpMethod(_req.method)

        local handler_info, params = self_ref.router:search(method, path)
        local req = {
            _raw = _req,
            params = params,
            method = method
        }

        self_ref.logger:log(log_level.DEBUG,
            string.format("Method: %s, Path: %s, Handler Found: %s",
                method, path, tostring(handler_info ~= nil)),
            "DawnServer"
        )

        if not handleCORS(req, res) then return end

        if handler_info then
            local handler = handler_info
            local query_params = parseQuery("?"..(_req.query or ""))
            if executeMiddleware(self_ref, req, res, path, self_ref.middlewares, 1) then
                method = string.upper(method)
                if method == "GET" or method == "DELETE" or method == "HEAD" or method == "OPTIONS" then
                    local ok, err = pcall(function()
                        handler(req, res, query_params)
                    end)
                    if not ok then
                        self_ref.logger:log(log_level.ERROR,
                            string.format("Error in route handler for %s %s: %s",
                                method, path, tostring(err)),
                            "DawnServer"
                        )
                        local route_error_handler = self_ref.error_handlers.route[path:lower()]
                        if type(route_error_handler) == "function" then
                            route_error_handler(req, res, err)
                        else
                            res:writeHeader("Content-Type", "text/plain")
                                :writeStatus(500)
                                :send("Internal Server Error")
                        end
                    end
                elseif method == "POST" or method == "PUT" or method == "PATCH" then
                    -- Add body handling for POST/PUT/PATCH
                    local content_type = ((_req.getHeader and _req:getHeader("content-type")) or ""):lower()
                    
                    if chunk then
                        req.body = (req.body or "") .. chunk
                    end
                    if is_last then
                        local parsed_body, parse_error
                        
                        if content_type:find("application/json") then
                            parsed_body = json.decode(req.body)
                            if not parsed_body then
                                parse_error = "Failed to parse JSON body"
                            end
                        elseif content_type:lower():find("application/x-www-form-urlencoded", 1, true) then
                            parsed_body = {}
                            for key, value in (req.body or ""):gmatch("([^&=]+)=([^&=]*)") do
                                local decoded_key = decodeURIComponent(key)
                                local decoded_value = decodeURIComponent(value)
                                parsed_body[decoded_key] = decoded_value
                            end
                        else
                            parsed_body = req.body
                        end
                        
                        local ok, err = pcall(handler, req, res, parsed_body, parse_error)
                        if not ok then
                            self_ref.logger:log(log_level.ERROR,
                                string.format("Error in route handler for %s %s: %s",
                                    method, path, tostring(err)),
                                "DawnServer"
                            )
                            local route_error_handler = self_ref.error_handlers.route[path:lower()]
                            if type(route_error_handler) == "function" then
                                route_error_handler(req, res, err)
                            else
                                res:writeHeader("Content-Type", "text/plain")
                                    :writeStatus(500)
                                    :send("Internal Server Error")
                            end
                        end
                    end
                end
            end
        else
            res:writeStatus(404):send("Not Found")
        end
    end

    -- Register WS, SSE, and HTTP routes
    local function registerRouteHandlers(node, prefix)
        if node.handlers and next(node.handlers) then
            for method, handler_func in pairs(node.handlers) do
                local method_lower = method:lower()
                local routePath = prefix
                
                if method_lower == "ws" then
                    self.uws.ws(routePath, function(ws, event, message, code, reason)
                        if event == "open" then
                            local fake_req = {
                                method = "WS",
                                url = routePath,
                                headers = {["x-forwarded-for"] = get_ws_id(ws)},
                                ws = ws
                            }
                            local fake_res = {}
                            fake_res.writeHeader = function() return fake_res end
                            fake_res.writeStatus = function() return fake_res end
                            fake_res.send = function(...)
                                print("[WS Middleware] Blocking upgrade:", ...)
                                ws:close()
                            end
                            local ok = executeMiddleware(self_ref, fake_req, fake_res, routePath, self_ref.middlewares, 1)
                            if ok then
                                self_ref.dawn_sockets_handler:handle_open(ws, message)
                            end
                        elseif event == "message" then
                            self_ref.dawn_sockets_handler:handle_message(ws, message, code)
                        elseif event == "close" then
                            self_ref.dawn_sockets_handler:handle_close(ws, code, reason)
                        end
                    end)
                elseif method_lower == "get" and routePath:find("/sse/") then
                    self.uws.sse(routePath, function(req, sse_id)
                        local fake_req = {
                            method = "GET",
                            url = routePath,
                            headers = req.headers,
                            sse_id = sse_id
                        }
                        local fake_res = {}
                        fake_res.writeHeader = function() return fake_res end
                        fake_res.writeStatus = function() return fake_res end
                        fake_res.send = function(data)
                            self.uws.sse_send(sse_id, data)
                        end
                        local ok = executeMiddleware(self_ref, fake_req, fake_res, routePath, self_ref.middlewares, 1)
                        if ok then
                            local handler_info, params = self_ref.router:search(method_lower, routePath)
                            pcall(function()
                                if handler_info then
                                    local query_params = parseQuery("?"..(req.query or ""))
                                    handler_func(fake_req, fake_res, query_params)
                                else
                                    self.uws.sse_send(sse_id, "Default SSE message", "default")
                                    self.uws.sse_close(sse_id)
                                end
                            end)
                        end
                    end)
                elseif method_lower == "get" or method_lower == "delete" or method_lower == "head" or method_lower == "options" then
                    self.uws[method_lower](routePath, handleRequest)
                elseif method_lower == "post" or method_lower == "put" or method_lower == "patch" then
                    self.uws[method_lower](routePath, handleRequest)
                end
            end
        end

        for path, child in pairs(node.children) do
            local slashCount = select(2, prefix:gsub("/", "", 1))
            local param = child.params[slashCount + 1] or ""
            local nextPrefix = prefix .. (
                path == ":" and "/:" .. param or
                (path == "*" and "/*" or "/" .. path)
            )
            registerRouteHandlers(child, nextPrefix)
        end
    end

    registerRouteHandlers(self.router, "")

    -- ✅ FIX: Re-register static file serving
    for _, config in ipairs(self_ref.static_configs) do
        self_ref.logger:log(log_level.INFO,
            string.format("Serving static files from '%s' at route '%s'",
                config.directory_path, config.route_prefix),
            "DawnServer"
        )
        self.uws.serve_static(config.route_prefix, config.directory_path)
    end

    self:printRoutes()
end


function DawnServer:restart()
   return  self.supervisor:restartChild(self.dawnProcessChild)
end

function DawnServer:stop()
    if self.running then
        self.running = false
        self.uws.cleanup_app()
        self.logger:log(log_level.INFO, "Dawn Server stopped", "DawnServer")
    end
end

-- Define the restart hook once
function on_restart_register(app)

  if not restart_self then
      print("[Lua] Error: restart_self is nil, cannot re-register routes.")
      return
  end

  restart_self.uws = app

--   restart_self.ROUTES_REGISTERED:load(restart_self):registerAllRoutes()

  restart_self:restart_run()
end


function DawnServer:start()
    self.dawnProcessChild = {
        name = "DawnServer_Supervisor",
        start = function()
            --  if self.dev_watcher then
            --         self.dev_watcher:start()
            -- end
            self.logger:log(log_level.INFO, "Dawn Server connection started ".. self.port, "DawnServer")
            self:run()
            local ok, err = pcall(self.uws.run)
            if not ok then
                self.logger:log(log_level.ERROR, "Fatal server error: " .. tostring(err), "DawnServer")
                return false
            end

            return true
        end,
        stop = function()
            self.logger:log(log_level.INFO, "Dawn Server connection stopped", "DawnServer")
            -- if self.dev_watcher then
            --     self.dev_watcher:stop()
            -- end
            self:stop()
            self.logger:Shutdown()
            return true
        end,
        restart = function()
            if not self.running then
                self.logger:log(log_level.WARN, "Server is not running, cannot restart.", "DawnServer")
                return
            end

            self.uws.restart_cleanup()

            -- 🔑 Use new unified restart (returns new userdata!)
            self.uws = self.uws.restart_reregister(self.port, function(success, err)
                if success then
                    print("✅ Restart complete on port " .. self.port)
                       -- Notify clients only after successful restart
                    self.shared_state.sockets:broadcast_to_all({
                        type = "reload",
                        changed = self.shared_state.changed_files or nil
                    })

                    if self.dev_watcher then
                    self.dev_watcher:start()
            end
                else
                    print("❌ Restart failed:", err)
                end
            end)

            return true
        end,
        restart_policy = "transient",
        restart_count = 5,
        backoff = 5000
    }
    self.supervisor:startChild(self.dawnProcessChild)
end


return DawnServer