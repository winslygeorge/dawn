-- FunctionalComponent.lua
-- ✅ Full WebSocket-aware + HTMLReactive component module + Redis state persistence + ClientState support
-- OPTIMIZED: memory/performance improvements for clientStates and general micro-optimizations

local viewEngine = require("layout.renderer.lustache_renderer")
local css_helper = require("utils.css_helper")
local HTMLBuilder = require("layout.renderer.MustacheHTMLBuilder")
local HTMLReactive = require("layout.renderer.LuaHTMLReactive")
local HTML = require("layout.renderer.LuaHTMLReactive")

local cjson = require('dkjson')
local uuid = require("utils.uuid")
local log_level = require("utils.logger").LogLevel
local os_time = os.time
local table_insert = table.insert
local table_remove = table.remove
local pairs = pairs
local ipairs = ipairs
local type = type
local assert = assert
local pcall = pcall
local tostring = tostring

local FunctionalComponent = {}

function FunctionalComponent:new(data)
    local instance = data or {}
    setmetatable(instance, { __index = self })
    return instance
end

function FunctionalComponent:extends()
    local new_component = {
        server = nil,
        children = {},
        props = {},
        state = {},
        -- client_states: token_or_ws_id -> { state = <table>, _last_seen = <timestamp> }
        client_states = {}, -- optimized structure with timestamps for pruning
        style = { inline = {}, css = {} },
        scope_id = "c" .. tostring(math.random(100000, 999999)),
        palette = "light",
        collected_css = nil,
        collected_js_scripts = {},
        reactive_root_node = nil,
        reactive_render_fn = nil,
        view_mode = nil,
        viewname = nil,
        viewEngine = viewEngine,
        htmlBuilder = HTMLBuilder,
        HTMLReactive = HTMLReactive,
        methods = {},
        component_key = nil,
        clients = {},
        _source_file = debug.getinfo(2, "S").source:gsub("^@", ""), -- Track source file
        _watcher = nil, -- Will hold watcher reference
        setOnClientReady = function  ()    
self:onClientReady(function (comp, parent_ws_id, parent_client_toke)
    local clientState = comp:getClientState(self._ws_id)
end)
end,
        _parentClientStateEnabled = false, -- NEW: Track parent clientState access
        client_ready_callbacks = {} -- NEW: Client ready callbacks array
    }

    setmetatable(new_component, { __index = self })

    -- small helper: logger fallback (no-op if server not set)
    local function log(level, msg, ...)
        if new_component.server and new_component.server.logger and new_component.server.logger.log then
            new_component.server.logger:log(level, string.format(msg, ...), "FunctionalComponent", new_component.component_key)
        end
    end

    function new_component:enableHotReload(server)
        if not self._watcher and server and server.dev_watcher then
            self._watcher = server.dev_watcher
            log(log_level.DEBUG, "[FunctionalComponent] ✅ Enabled hot reload for: %s", tostring(self.component_key))
        end
        return self
    end

    function new_component:set_WS_ID(ws_id)
        self._ws_id = ws_id
    end

    function new_component:set_client_token(token)
        self.client_token = token
    end

   function new_component:hotReload()
    if not self._source_file then
        log(log_level.WARN, "[FunctionalComponent] ⚠️ Cannot hot reload (no source file tracked).")
        return
    end

    log(log_level.INFO, "[FunctionalComponent] ♻️ Hot reloading component from: %s", self._source_file)

    -- Clear the loaded module to force re-require
    local mod_name = self._source_file:gsub("%.lua$", ""):gsub("^./", ""):gsub("/", ".")
    package.loaded[mod_name] = nil

    -- Clear cached require for all potential dependencies
    local function clear_related_modules(base_name)
        local base_pattern = base_name:gsub("%.", "%%.")
        for module_name, _ in pairs(package.loaded) do
            if module_name:match("^" .. base_pattern) or module_name:match(base_pattern .. "$") then
                log(log_level.DEBUG, "[FunctionalComponent] Clearing module from cache: %s", module_name)
                package.loaded[module_name] = nil
            end
        end
    end
    
    clear_related_modules(mod_name)

    -- Try to reload the module
    local ok, reloaded = pcall(require, mod_name)
    if not ok then
        log(log_level.ERROR, "[FunctionalComponent] ❌ Reload failed: %s", tostring(reloaded))
        return
    end

    if self.view_mode == "html_reactive" and type(self.reactive_render_fn) == "function" then
        -- Get the new render function from the reloaded module
        local new_render_fn = nil
        
        -- Try different ways to extract the render function
        if type(reloaded) == "table" then
            if reloaded.render then
                new_render_fn = reloaded.render
                log(log_level.DEBUG, "[FunctionalComponent] Found render function in reloaded module")
            elseif reloaded.view then
                new_render_fn = reloaded.view
                log(log_level.DEBUG, "[FunctionalComponent] Found view function in reloaded module")
            elseif reloaded.reactive_render_fn then
                new_render_fn = reloaded.reactive_render_fn
                log(log_level.DEBUG, "[FunctionalComponent] Found reactive_render_fn in reloaded module")
            elseif reloaded.default and type(reloaded.default) == "function" then
                new_render_fn = reloaded.default
                log(log_level.DEBUG, "[FunctionalComponent] Found default export function")
            end
        elseif type(reloaded) == "function" then
            new_render_fn = reloaded
            log(log_level.DEBUG, "[FunctionalComponent] Module returned function directly")
        end
        
        if not new_render_fn then
            log(log_level.WARN, "[FunctionalComponent] ⚠️ Could not find render function in reloaded module. Module type: %s", type(reloaded))
            return
        end
        
        -- Store the old state for comparison (optional)
        local old_state = self.state
        
        -- Update the render function
        self.reactive_render_fn = new_render_fn
        
        -- Preserve existing state
        local existing_state = {}
        for k, v in pairs(self.state or {}) do
            existing_state[k] = v
        end
        
        local existing_client_state = {}
        local client_state_key = self.client_token or self._ws_id
        if client_state_key and self.client_states[client_state_key] then
            for k, v in pairs(self.client_states[client_state_key]) do
                if k ~= "_last_seen" then
                    existing_client_state[k] = v
                end
            end
        end
        
        -- Recreate the reactive component with the new render function
        if self.HTMLReactive.createComponentWithClientState then
            log(log_level.DEBUG, "[FunctionalComponent] Recreating component with client state support")
            self.reactive_component = self.HTMLReactive.createComponentWithClientState({
                render = function(state, props, clientState)
                    local renderContext = {
                        state = state,
                        props = props,
                        children = self.children,
                        HTMLReactive = self.HTMLReactive,
                        clientState = clientState or existing_client_state
                    }
                    return self.reactive_render_fn(renderContext.state, renderContext.props, 
                        renderContext.children, renderContext.HTMLReactive,
                        self.collected_js_scripts, renderContext.clientState)
                end,
                initialState = existing_state,
                initialClientState = existing_client_state,
                onClientStateChange = function(newClientState, oldClientState)
                    log(log_level.DEBUG, "[FunctionalComponent] ClientState changed after reload")
                end
            })
        elseif self.HTMLReactive.createCRUDEnhancedComponent then
            log(log_level.DEBUG, "[FunctionalComponent] Recreating CRUD-enhanced component")
            self.reactive_component = self.HTMLReactive.createCRUDEnhancedComponent(
                function(state, props, clientState)
                    local renderContext = {
                        state = state,
                        props = props,
                        children = self.children,
                        HTMLReactive = self.HTMLReactive,
                        clientState = clientState or existing_client_state
                    }
                    return self.reactive_render_fn(renderContext.state, renderContext.props, 
                        renderContext.children, renderContext.HTMLReactive,
                        self.collected_js_scripts, renderContext.clientState)
                end,
                existing_state,
                existing_client_state
            )
        else
            log(log_level.DEBUG, "[FunctionalComponent] Recreating basic component")
            self.reactive_component = self.HTMLReactive.createComponent(function(state, props, children, HTMLReactive)
                local renderContext = {
                    state = state,
                    props = props,
                    children = children,
                    HTMLReactive = HTMLReactive,
                    clientState = existing_client_state
                }
                return self.reactive_render_fn(renderContext.state, renderContext.props, 
                    renderContext.children, renderContext.HTMLReactive, 
                    self.collected_js_scripts, renderContext.clientState)
            end, existing_state)
        end
        
        -- Re-render the component
        local render_ok, render_err = pcall(function()
            self.reactive_root_node = self:render()
        end)
        
        if not render_ok then
            log(log_level.ERROR, "[FunctionalComponent] ❌ Failed to re-render after reload: %s", tostring(render_err))
            return
        end
        
        -- Broadcast reload notification to connected clients
        if self.server and self.server.shared_state and self.server.shared_state.sockets then
            local broadcast_ok, broadcast_err = pcall(function()
                self.server.shared_state.sockets:broadcast_to_all({
                    type = "component_reload",
                    component_key = self.component_key,
                    timestamp = os.time(),
                    force_reload = true
                })
            end)
            if not broadcast_ok then
                log(log_level.WARN, "[FunctionalComponent] Failed to broadcast reload: %s", tostring(broadcast_err))
            end
        end
        
        log(log_level.INFO, "[FunctionalComponent] ✅ Component fully reloaded and re-rendered.")
        
        -- Trigger any registered onReload callbacks
        if self.on_reload_callbacks then
            for _, callback in ipairs(self.on_reload_callbacks) do
                local callback_ok, callback_err = pcall(callback, self, old_state, self.state)
                if not callback_ok then
                    log(log_level.WARN, "[FunctionalComponent] Reload callback error: %s", tostring(callback_err))
                end
            end
        end
        
    elseif self.view_mode == "lustache" then
        self.viewEngine:reloadTemplate(self.viewname)
        log(log_level.INFO, "[FunctionalComponent] ✅ Mustache template reloaded.")
        
        -- Re-render if possible
        if self.render then
            pcall(function()
                self:render()
            end)
        end
    else
        log(log_level.WARN, "[FunctionalComponent] ⚠️ Unknown view mode or no render function: %s", tostring(self.view_mode))
    end
end

-- Add method to register reload callbacks
function new_component:onReload(callback)
    if type(callback) ~= "function" then
        error("onReload expects a function", 2)
    end
    self.on_reload_callbacks = self.on_reload_callbacks or {}
    table_insert(self.on_reload_callbacks, callback)
    return self
end

    -- ==== PROPS HELPERS ====
    function new_component:updateProps(new_props)
        if type(new_props) ~= "table" then error("updateProps expects a table", 2) end
        for k, v in pairs(new_props) do self.props[k] = v end
        return self
    end

    function new_component:setProps(new_props)
        if type(new_props) ~= "table" then error("setProps expects a table", 2) end
        self.props = new_props
        return self
    end

    function new_component:removeProp(key)
        if key == nil then error("removeProp expects a key", 2) end
        self.props[key] = nil
        return self
    end

    function new_component:clearProps()
        self.props = {}
        return self
    end

    function new_component:getProp(key, default)
        local val = self.props[key]
        return val == nil and default or val
    end

    function new_component:getProps()
        local copy = {}
        for k, v in pairs(self.props) do copy[k] = v end
        return copy
    end

    -- ==== CHILDREN HELPERS ====
    function new_component:setChildren(new_children)
        if type(new_children) ~= "table" then error("setChildren expects a table", 2) end
        self.children = new_children
        return self
    end

    function new_component:addChild(child)
        table_insert(self.children, child)
        return self
    end

    function new_component:addChildren(children_list)
        if type(children_list) ~= "table" then error("addChildren expects a table", 2) end
        for _, child in ipairs(children_list) do table_insert(self.children, child) end
        return self
    end

    function new_component:removeChild(index)
        if type(index) ~= "number" then error("removeChild expects a numeric index", 2) end
        table_remove(self.children, index)
        return self
    end

    function new_component:removeChildren(predicate)
        if type(predicate) ~= "function" then error("removeChildren expects a function", 2) end
        local i = 1
        while i <= #self.children do
            if predicate(self.children[i], i) then
                table_remove(self.children, i)
            else
                i = i + 1
            end
        end
        return self
    end

    function new_component:clearChildren()
        self.children = {}
        return self
    end

    function new_component:getChild(index)
        return self.children[index]
    end

    function new_component:getChildren()
        local copy = {}
        for i, child in ipairs(self.children) do copy[i] = child end
        return copy
    end

    function new_component:setServer(server)
        assert(type(server) == "table", "server must be an object of dawn server table")
        self.server = server
        return self
    end

    function new_component:setComponentKey(key)
        assert(type(key) == "string" and #key > 0, "component_key must be a non-empty string")
        -- if self.component_key then
        --     assert(self.component_key == key, "Component key already set to a different value.")
        --     return
        -- end
        self.component_key = key
        if self.server and type(self.server.register_reactive_component) == "function" then
            self.server:register_reactive_component(self, self.component_key)
        end
    end

    function new_component:enableParentClientStateAccess()
        self._parentClientStateEnabled = true
        return self
    end

    function new_component:onClientReady(callback)
        assert(type(callback) == "function", "onClientReady expects a function")
        table_insert(self.client_ready_callbacks, callback)
        local parent = self:getParentComponent()
        local parent_ws_id = parent and parent._ws_id or nil
        local parent_client_token = parent and parent.client_token or nil
        if parent_ws_id then
            -- call into callback safely
            local ok, err = pcall(callback, self, parent_ws_id, parent_client_token)
            if not ok then
                log(log_level.WARN, "[FunctionalComponent] client ready callback error: %s", tostring(err))
            end
        end
    end

    -- BFS traversal (optimized, uses local refs)
    local function bfs_traverse_components(root, ws_id, client_token)
        local queue = {}
        local visited = {}
        local qn = 0

        for key, child in pairs(root.children or {}) do
            if child and not visited[child] then
                visited[child] = true
                qn = qn + 1
                queue[qn] = { key = key, node = child, parent = "root", depth = 1 }
            end
        end

        local i = 1
        while i <= qn do
            local entry = queue[i]
            local child = entry.node

            if type(child.set_WS_ID) == "function" then
                local success, err = pcall(function()

                    child:set_WS_ID(ws_id)
                    child:set_client_token(client_token)
                    -- Load persisted client state from Redis if available
                    if root.server and root.server.dawn_sockets_handler and root.server.dawn_sockets_handler.state_management and root.server.dawn_sockets_handler.state_management.redis and child.component_key then
                        local redis = root.server.dawn_sockets_handler.state_management.redis
                        local key = string.format("client_state:%s:%s", child.component_key, child.client_token or ws_id)
                        local ok, val = pcall(function() return redis:get(key) end)
                        if ok and val then
                            local decoded, dec_err = pcall(function() return cjson.decode(val) end)
                            if decoded and type(dec_err) == "table" then
                                child.client_states[child.client_token or ws_id] = { state = dec_err, _last_seen = os_time() }
                            end
                        end
                    end

                    child:triggerClientReadyCallbacks(ws_id, client_token)
                end)

                if not success then
                    log(log_level.WARN, "[FunctionalComponent] Error setting WS_ID for %s: %s", tostring(child.component_key or tostring(child)), tostring(err))
                end
            end

            if child.children then
                for key, grandchild in pairs(child.children) do
                    if grandchild and not visited[grandchild] then
                        visited[grandchild] = true
                        qn = qn + 1
                        queue[qn] = { key = key, node = grandchild, parent = child.component_key or tostring(child), depth = entry.depth + 1 }
                    end
                end
            end

            i = i + 1
        end
    end

    function new_component:onJoin(ws_id, client_token)
        log(log_level.DEBUG, "[FunctionalComponent] onJoin called: ws=%s token=%s", tostring(ws_id), tostring(client_token))

        if not self.client_token then
            self.client_token = client_token
        end

        self.clients[ws_id] = true
        self:set_WS_ID(ws_id)


        --print comp keys 
        for k, v in pairs(self.clients) do
        end

        local hadRedisState = false
        -- Load persisted client state if Redis available
        if self.server and self.server.dawn_sockets_handler and self.server.dawn_sockets_handler.state_management and self.server.dawn_sockets_handler.state_management.redis and self.component_key then
            local redis = self.server.dawn_sockets_handler.state_management.redis
            local key = string.format("client_state:%s:%s", self.component_key, self.client_token or ws_id)
            local ok, val = pcall(function() return redis:get(key) end)
            if ok and val then
                local decoded_ok, decoded = pcall(function() return cjson.decode(val) end)
                if decoded_ok and type(decoded) == "table" then
                    decoded._last_seen = os_time()
                    self.client_states[self.client_token or ws_id] = decoded
                    hadRedisState = true

                    -- If reactive, generate patches for clientState and queue them
                    if self.view_mode == "html_reactive" and self.reactive_component then
                        local patches = {}
                        for k, v in pairs(decoded) do
                            table_insert(patches, {
                                type = "update-var",
                                path = {"clientState", k},
                                value = v,
                                varName = "clientState." .. k
                            })
                        end

                        if #patches > 0 then
                            for _, patch in ipairs(patches) do
                                patch.component = (self.server and self.server.get_patch_namespace) and self.server:get_patch_namespace(self.component_key, patch.varName or patch.path) or nil
                            end

                            local payload = {
                                id = uuid.v4(),
                                type = "patches",
                                data = patches
                            }

                            if self.parent and self.parent.server and self.parent.server.shared_state and self.parent.server.shared_state.sockets then
                                    self.parent.server.shared_state.sockets:send_to_user(ws_id, payload)
                                elseif self.server and self.server.shared_state and self.server.shared_state.sockets then
                                    self.server.shared_state.sockets:send_to_user(ws_id, payload)
                                else
                                    log(log_level.WARN, "[FunctionalComponent] No socket layer available to send patches")
                                end
                        end
                    end
                end
            end
        end

        if hadRedisState and self.view_mode == "html_reactive" and self.reactive_component then
            self:rerender()
        end

        bfs_traverse_components(self, ws_id, client_token)
        self:triggerClientReadyCallbacks(ws_id, client_token)

        -- prune to avoid unbounded growth on join
        if type(self.pruneClientStates) == "function" then
            -- sensible defaults: keep up to 200 entries or 24h age
            pcall(function() self:pruneClientStates(200, 24 * 3600) end)
        end
    end

    function new_component:triggerClientReadyCallbacks(ws_id, client_token)
        local comp = self
        for _, callback in ipairs(self.client_ready_callbacks) do
            local success, err = pcall(callback, comp, ws_id, client_token)
            if not success then
                log(log_level.WARN, "[FunctionalComponent] Client ready callback error: %s", tostring(err))
            end
        end
    end

    function new_component:beforeClose(ws_id)
        self.clients[ws_id] = nil
        -- Optionally mark last seen time
        -- No removal from client_states here - retain for reconnect unless pruned
    end

-- Standardized redis-backed single-get helper (returns decoded table or nil)
local function redis_get_decoded(redis, key)
    log(log_level.DEBUG, "[FunctionalComponent] 🔍 redis_get_decoded called for key: %s", tostring(key))
    
    local ok, val = pcall(function() 
        log(log_level.DEBUG, "[FunctionalComponent] 🔍 Attempting redis:get('%s')", key)
        return redis:get(key) 
    end)
    
    log(log_level.DEBUG, "[FunctionalComponent] 🔍 redis:get pcall result - ok: %s, val type: %s, val: %s", 
        tostring(ok), type(val), tostring(val))
    
    if not ok then
        log(log_level.ERROR, "[FunctionalComponent] ❌ redis:get failed with error: %s", tostring(val))
        return nil 
    end
    
    if not val then
        log(log_level.DEBUG, "[FunctionalComponent] 🔍 Key not found or nil value in Redis for key: %s", key)
        return nil 
    end
    
    log(log_level.DEBUG, "[FunctionalComponent] 🔍 Raw Redis value length: %d", #val)
    
    local dec_ok, dec = pcall(function() 
        log(log_level.DEBUG, "[FunctionalComponent] 🔍 Attempting to JSON decode value")
        return cjson.decode(val) 
    end)
    
    log(log_level.DEBUG, "[FunctionalComponent] 🔍 JSON decode result - ok: %s, dec type: %s", 
        tostring(dec_ok), type(dec))
    
    if not dec_ok then
        log(log_level.ERROR, "[FunctionalComponent] ❌ JSON decode failed for key %s: %s", key, tostring(dec))
        return nil
    end
    
    if type(dec) == "table" then 
        -- Count table keys properly
        local keyCount = 0
        for _ in pairs(dec) do keyCount = keyCount + 1 end
        log(log_level.DEBUG, "[FunctionalComponent] ✅ Successfully decoded table with %d keys for key: %s", 
            keyCount, key)
        return dec 
    else
        log(log_level.WARN, "[FunctionalComponent] ⚠️ Decoded value is not a table (type: %s) for key: %s", 
            type(dec), key)
        return nil
    end
end

function new_component:getRedisClientState(client_token_or_ws_id, comp_key)
    log(log_level.DEBUG, "[FunctionalComponent] 🔍 getRedisClientState called with:")
    log(log_level.DEBUG, "[FunctionalComponent]   • client_token_or_ws_id: %s", tostring(client_token_or_ws_id))
    log(log_level.DEBUG, "[FunctionalComponent]   • comp_key: %s", tostring(comp_key))
    log(log_level.DEBUG, "[FunctionalComponent]   • self.component_key: %s", tostring(self.component_key))
    
    local state = {}

    -- Check if all required components exist
    local has_server = self.server ~= nil
    local has_dawn_sockets_handler = has_server and self.server.dawn_sockets_handler ~= nil
    local has_state_management = has_dawn_sockets_handler and self.server.dawn_sockets_handler.state_management ~= nil
    local has_redis = has_state_management and self.server.dawn_sockets_handler.state_management.redis ~= nil
    
    log(log_level.DEBUG, "[FunctionalComponent] 🔍 Precondition checks:")
    log(log_level.DEBUG, "[FunctionalComponent]   • self.server exists: %s", tostring(has_server))
    log(log_level.DEBUG, "[FunctionalComponent]   • dawn_sockets_handler exists: %s", tostring(has_dawn_sockets_handler))
    log(log_level.DEBUG, "[FunctionalComponent]   • state_management exists: %s", tostring(has_state_management))
    log(log_level.DEBUG, "[FunctionalComponent]   • redis exists: %s", tostring(has_redis))
    log(log_level.DEBUG, "[FunctionalComponent]   • self.component_key exists: %s", tostring(self.component_key ~= nil))

    if has_server and has_dawn_sockets_handler and has_state_management and has_redis and self.component_key then
        local redis = self.server.dawn_sockets_handler.state_management.redis
        
        -- Determine which component key to use
        local actual_comp_key = comp_key or self.component_key
        log(log_level.DEBUG, "[FunctionalComponent] 🔍 Using component key: %s", actual_comp_key)
        
        local key = string.format("client_state:%s:%s", actual_comp_key, client_token_or_ws_id)
        log(log_level.DEBUG, "[FunctionalComponent] 🔍 Generated Redis key: %s", key)
        
        local decoded = redis_get_decoded(redis, key)
        
        if decoded then
            log(log_level.DEBUG, "[FunctionalComponent] ✅ Found existing state in Redis for key: %s", key)
            state = decoded
        else
            log(log_level.DEBUG, "[FunctionalComponent] 🔍 No existing state found, creating empty state for key: %s", key)
            state = {}
            
            -- Prime Redis with empty state
            local primeOk, primeErr = pcall(function()
                log(log_level.DEBUG, "[FunctionalComponent] 🔍 Priming Redis with empty state for key: %s", key)
                local encoded = cjson.encode(state)
                log(log_level.DEBUG, "[FunctionalComponent] 🔍 Empty state JSON: %s", encoded)
                
                redis:set(key, encoded)
                redis:expire(key, 86400)
                log(log_level.DEBUG, "[FunctionalComponent] ✅ Successfully primed Redis with empty state")
            end)
            
            if not primeOk then
                log(log_level.WARN, "[FunctionalComponent] ⚠️ Redis SET (prime empty state) failed: %s", tostring(primeErr))
                log(log_level.DEBUG, "[FunctionalComponent] 🔍 Redis connection might be down or misconfigured")
            end
        end
    else
        log(log_level.WARN, "[FunctionalComponent] ⚠️ Missing required dependencies for getRedisClientState:")
        if not has_server then log(log_level.WARN, "[FunctionalComponent]   • self.server is nil") end
        if not has_dawn_sockets_handler then log(log_level.WARN, "[FunctionalComponent]   • dawn_sockets_handler is nil") end
        if not has_state_management then log(log_level.WARN, "[FunctionalComponent]   • state_management is nil") end
        if not has_redis then log(log_level.WARN, "[FunctionalComponent]   • redis is nil") end
        if not self.component_key then log(log_level.WARN, "[FunctionalComponent]   • self.component_key is nil") end
    end

    if type(state) ~= "table" then 
        log(log_level.WARN, "[FunctionalComponent] ⚠️ State is not a table (type: %s), converting to empty table", type(state))
        state = {} 
    end
    
    -- Count state keys properly
    local stateKeyCount = 0
    for _ in pairs(state) do stateKeyCount = stateKeyCount + 1 end
    log(log_level.DEBUG, "[FunctionalComponent] 🔍 Returning state with %d keys", stateKeyCount)
    return state
end

--- create getRedisComponentState to get component-wide state
--- returns decoded table or nil
--- comp_key: optional component key (defaults to self.component_key)
--- if no component_key set, returns empty table
--- usage: local state = self:getRedisComponentState("my_component_key")
--- returns: table
function new_component:getRedisComponentState(comp_key)
    log(log_level.DEBUG, "[FunctionalComponent] 🔍 getRedisComponentState called with:")
    log(log_level.DEBUG, "[FunctionalComponent]   • comp_key: %s", tostring(comp_key))
    log(log_level.DEBUG, "[FunctionalComponent]   • self.component_key: %s", tostring(self.component_key))
    
    local state = {}

    -- Check if all required components exist
    local has_server = self.server ~= nil
    local has_dawn_sockets_handler = has_server and self.server.dawn_sockets_handler ~= nil
    local has_state_management = has_dawn_sockets_handler and self.server.dawn_sockets_handler.state_management ~= nil
    local has_redis = has_state_management and self.server.dawn_sockets_handler.state_management.redis ~= nil
    
    log(log_level.DEBUG, "[FunctionalComponent] 🔍 Precondition checks for component state:")
    log(log_level.DEBUG, "[FunctionalComponent]   • self.server exists: %s", tostring(has_server))
    log(log_level.DEBUG, "[FunctionalComponent]   • dawn_sockets_handler exists: %s", tostring(has_dawn_sockets_handler))
    log(log_level.DEBUG, "[FunctionalComponent]   • state_management exists: %s", tostring(has_state_management))
    log(log_level.DEBUG, "[FunctionalComponent]   • redis exists: %s", tostring(has_redis))

    if has_server and has_dawn_sockets_handler and has_state_management and has_redis then
        local redis = self.server.dawn_sockets_handler.state_management.redis
        
        -- Determine which component key to use
        local actual_comp_key = comp_key or self.component_key
        log(log_level.DEBUG, "[FunctionalComponent] 🔍 Using component key: %s", tostring(actual_comp_key))
        
        if not actual_comp_key then
            log(log_level.WARN, "[FunctionalComponent] ⚠️ getRedisComponentState called without component_key")
            log(log_level.DEBUG, "[FunctionalComponent] 🔍 comp_key param: %s, self.component_key: %s", 
                tostring(comp_key), tostring(self.component_key))
            return {}
        end
        
        local keyname = string.format("component_state:%s", actual_comp_key)
        log(log_level.DEBUG, "[FunctionalComponent] 🔍 Generated Redis key: %s", keyname)
        
        local decoded = redis_get_decoded(redis, keyname)
        
        if decoded then
            log(log_level.DEBUG, "[FunctionalComponent] ✅ Found existing component state in Redis for key: %s", keyname)
            state = decoded
        else
            log(log_level.DEBUG, "[FunctionalComponent] 🔍 No existing component state found, creating empty state for key: %s", keyname)
            state = {}
            
            -- Prime Redis with empty state
            local primeOk, primeErr = pcall(function()
                log(log_level.DEBUG, "[FunctionalComponent] 🔍 Priming Redis with empty component state for key: %s", keyname)
                local encoded = cjson.encode(state)
                log(log_level.DEBUG, "[FunctionalComponent] 🔍 Empty component state JSON: %s", encoded)
                
                redis:set(keyname, encoded)
                redis:expire(keyname, 86400)
                log(log_level.DEBUG, "[FunctionalComponent] ✅ Successfully primed Redis with empty component state")
            end)
            
            if not primeOk then
                log(log_level.WARN, "[FunctionalComponent] ⚠️ Redis SET (prime empty component state) failed: %s", tostring(primeErr))
                log(log_level.DEBUG, "[FunctionalComponent] 🔍 Possible Redis connection issue or permissions problem")
            end
        end
    else
        log(log_level.WARN, "[FunctionalComponent] ⚠️ Missing required dependencies for getRedisComponentState:")
        if not has_server then log(log_level.WARN, "[FunctionalComponent]   • self.server is nil") end
        if not has_dawn_sockets_handler then log(log_level.WARN, "[FunctionalComponent]   • dawn_sockets_handler is nil") end
        if not has_state_management then log(log_level.WARN, "[FunctionalComponent]   • state_management is nil") end
        if not has_redis then log(log_level.WARN, "[FunctionalComponent]   • redis is nil") end
    end

    if type(state) ~= "table" then 
        log(log_level.WARN, "[FunctionalComponent] ⚠️ Component state is not a table (type: %s), converting to empty table", type(state))
        state = {} 
    end
    
    -- Count component state keys properly
    local stateKeyCount = 0
    for _ in pairs(state) do stateKeyCount = stateKeyCount + 1 end
    log(log_level.DEBUG, "[FunctionalComponent] 🔍 Returning component state with %d keys", stateKeyCount)
    return state
end

-- Optional helper function for counting keys
function new_component:countTableKeys(tbl)
    if type(tbl) ~= "table" then return 0 end
    local count = 0
    for _ in pairs(tbl) do count = count + 1 end
    return count
end

-- Optional: Add this validation function to debug Redis connection
function new_component:validateRedisConnection()
    log(log_level.DEBUG, "[FunctionalComponent] 🔍 Validating Redis connection...")
    
    if self.server and self.server.dawn_sockets_handler and self.server.dawn_sockets_handler.state_management then
        local redis = self.server.dawn_sockets_handler.state_management.redis
        if redis then
            local ok, result = pcall(function() 
                return redis:ping() 
            end)
            log(log_level.DEBUG, "[FunctionalComponent] 🔍 Redis ping result: ok=%s, result=%s", 
                tostring(ok), tostring(result))
            return ok and result == "PONG"
        else
            log(log_level.WARN, "[FunctionalComponent] ⚠️ Redis object is nil")
        end
    else
        log(log_level.WARN, "[FunctionalComponent] ⚠️ Missing Redis dependencies")
    end
    return false
end




-- Helper function to get table keys as array
 function tableKeys(tbl)
    local keys = {}
    for k, _ in pairs(tbl or {}) do
        table.insert(keys, tostring(k))
    end
    return keys
end


    function new_component:sendHTMLClientOperations(ws_id, ops)
        assert(type(ops) == "table", "browserOps expects a table of operations")
        local payload = {
            id = uuid.v4(),
            type = "browser_ops",
            ops = ops
        }
        if self.parent and self.parent.server and self.parent.server.shared_state and self.parent.server.shared_state.sockets then
            self.parent.server.shared_state.sockets:send_to_user(ws_id, payload)
        elseif self.server and self.server.shared_state and self.server.shared_state.sockets then
            self.server.shared_state.sockets:send_to_user(ws_id, payload)
        else
            log(log_level.WARN, "[FunctionalComponent] No socket layer available to send HTML client operations")
        end
    end

    function new_component:fetchInitialState(callback, ...)
        assert(type(callback) == "function", "Callback must be a function")
        if self.server and type(self.server.async) == "function" then
            self.server:async(callback, ...)
        else
            -- fallback synchronous call if async not present
            pcall(callback, ...)
        end
    end

    function new_component:setView(viewName)
        assert(type(viewName) == "string" and #viewName > 0, "ViewName must be a non-empty string.")
        assert(not self.view_mode, "View mode already set.")
        self.viewname = viewName
        self.view_mode = "lustache"
    end

    function new_component:setReactiveView()
        assert(not self.view_mode, "View mode already set.")
        self.view_mode = "html_reactive"
    end

    function new_component:setTheme(theme_name)
        self.palette = theme_name or "light"
        css_helper.set_palette(css_helper.get_builtin_palette(self.palette))
    end

    function new_component:render()
        assert(self.view_mode == "html_reactive", "Calling render() is only valid in html_reactive mode.")
        assert(type(self.reactive_render_fn) == "function", "reactive_render_fn is not set.")
        return self.reactive_render_fn(self.state, self.props, self.children, self.HTMLReactive, self:getClientState(self._ws_id))
    end

    function FunctionalComponent:loadStateFromRedis()
        if not (self.server and self.server.dawn_sockets_handler and self.server.dawn_sockets_handler.state_management and self.server.dawn_sockets_handler.state_management.redis) then
            return
        end

        local redis = self.server.dawn_sockets_handler.state_management.redis
        local key = "component_state:" .. (self.component_key or "")
        local ok, val = pcall(function() return redis:get(key) end)

        if ok and val then
            local decoded_ok, decoded = pcall(function() return cjson.decode(val) end)
            if decoded_ok and type(decoded) == "table" then
                for k, v in pairs(decoded) do
                    self.state[k] = v
                end
            else
                log(log_level.WARN, "[FunctionalComponent] Redis decode error for %s", tostring(self.component_key))
            end
        else
            log(log_level.INFO, "[FunctionalComponent] No existing state in Redis for key: %s", tostring(key))
        end
    end

-- create self:setComponentState("route_"..k, compState) to set component-wide state
function new_component:setComponentState(comp_key, newState)
    assert(type(newState) == "table", "setComponentState expects a table")

    if not comp_key then
        log(log_level.WARN, "[FunctionalComponent] ⚠️ setComponentState called without component_key")
        return {}
    end

    self:setState(newState)
    return newState
end



function new_component:pruneClientStates(max_count, max_age)
    
    local current_time = os_time()
    local to_remove = {}
    local count = 0
    
    for key, slot in pairs(self.client_states) do
        count = count + 1
        
        -- Get the _last_seen from the slot (it should be at top level now)
        local last_seen = slot._last_seen
        
        if last_seen and (current_time - last_seen) > max_age then
            table.insert(to_remove, key)
        end
    end
    
    -- If still over count limit, remove oldest
    if count > max_count then
        local sorted = {}
        for key, slot in pairs(self.client_states) do
            table.insert(sorted, {key = key, last_seen = slot._last_seen or 0})
        end
        
        table.sort(sorted, function(a, b) return a.last_seen < b.last_seen end)
        
        for i = 1, count - max_count do
            if sorted[i] and not tableContains(to_remove, sorted[i].key) then
                table.insert(to_remove, sorted[i].key)
            end
        end
    end
    
    -- Remove marked keys
    for _, key in ipairs(to_remove) do
        self.client_states[key] = nil
    end
    
end



-- Helper function to get value from path in a table
local function getByPath(tbl, path)
    if not path or path == "" then return tbl end
    local parts = {}
    for part in path:gmatch("[^%.]+") do
        table.insert(parts, part)
    end
    
    local current = tbl
    for _, part in ipairs(parts) do
        if type(current) ~= "table" then return nil end
        current = current[part]
        if current == nil then return nil end
    end
    return current
end

-- Helper function to set value at path in a table
local function setByPath(tbl, path, value)
    if not path or path == "" then 
        -- Clear and replace the entire table
        for k in pairs(tbl) do
            tbl[k] = nil
        end
        for k, v in pairs(value) do
            tbl[k] = v
        end
        return
    end
    
    local parts = {}
    for part in path:gmatch("[^%.]+") do
        table.insert(parts, part)
    end
    
    local current = tbl
    for i = 1, #parts - 1 do
        local part = parts[i]
        if current[part] == nil then
            current[part] = {}
        elseif type(current[part]) ~= "table" then
            current[part] = {}
        end
        current = current[part]
    end
    
    local lastPart = parts[#parts]
    current[lastPart] = value
end

-- Helper function to deep copy table (avoid reference issues)
local function deepCopy(orig)
    local copy
    if type(orig) == "table" then
        copy = {}
        for orig_key, orig_value in pairs(orig) do
            copy[deepCopy(orig_key)] = deepCopy(orig_value)
        end
        setmetatable(copy, deepCopy(getmetatable(orig)))
    else
        copy = orig
    end
    return copy
end

function new_component:setClientState(ws_id, updater, comp_key)
    -- ------------------------------------------------------------------------
    -- 1. Fast path: no operation if updater is empty or nil
    -- ------------------------------------------------------------------------
    if updater == nil then
        return {}
    end
    if type(updater) == "table" and next(updater) == nil then
        return {}
    end

    -- ------------------------------------------------------------------------
    -- 2. Localise frequently used functions / tables for speed
    -- ------------------------------------------------------------------------
    local client_states = self.client_states
    local reactive = self.reactive_component
    local server = self.server
    local log = self.server and self.server.logger and self.server.logger.log
    local os_time = os.time
    local deepCopy = deepCopy   -- assumes deepCopy is a local upvalue (already defined)
    local cjson_encode = cjson.encode
    local type = type
    local pairs = pairs
    local ipairs = ipairs
    local table_insert = table.insert

    -- ------------------------------------------------------------------------
    -- 3. Determine storage key (client_token or ws_id)
    -- ------------------------------------------------------------------------
    local key = self.client_token or ws_id

    if not key then
        if log then log(log_level.WARN, "[setClientState] No client key available") end
        return {}
    end

    -- ------------------------------------------------------------------------
    -- 4. Get current client state (always stored flat, no nesting)
    -- ------------------------------------------------------------------------
    local slot = client_states[key]
    local currentState
    if slot then
        -- slot is the raw state table (no extra nesting)
        currentState = slot
    else
        currentState = {}
        client_states[key] = currentState
    end

    -- ------------------------------------------------------------------------
    -- 5. Prepare variables
    -- ------------------------------------------------------------------------
    local patches = {}
    local newState

    -- ------------------------------------------------------------------------
    -- 6. Process updater based on its type
    -- ------------------------------------------------------------------------
    if type(updater) == "table" and updater._operation then
        -- 6a. CRUD operation – delegate to reactive component
        if reactive and reactive.crud then
            patches = reactive.crud(
                updater._operation,
                updater._target,
                updater._data,
                updater._options or {},
                currentState and currentState and currentState or {}
            ) or {}
        end
        -- The reactive component modifies currentState directly,
        -- so we can just reuse currentState as the new state.
        newState = currentState

    elseif type(updater) == "function" then
        -- 6b. Function updater – call with a shallow copy of current state
        --     (shallow copy is enough because we only need to detect changes)
        local oldCopy = {}
        for k, v in pairs(currentState) do
            oldCopy[k] = v
        end
        local updated = updater(oldCopy)
        if type(updated) ~= "table" then
            if log then log(log_level.WARN, "[setClientState] updater function returned non-table") end
            return {}
        end
        newState = updated

        -- Apply changes to the reactive component (if available)
        if reactive and reactive.setClientState then
            patches = reactive.setClientState(newState) or {}
        end

        -- Update the stored state
        for k in pairs(currentState) do
            currentState[k] = nil
        end
        for k, v in pairs(newState) do
            currentState[k] = v
        end

    else
        -- 6c. Partial table – merge into current state
        newState = currentState   -- we modify in place
        for k, v in pairs(updater) do
            currentState[k] = v
        end

        if reactive and reactive.setClientState then
            patches = reactive.setClientState(updater) or {}
        end
    end

    -- Update last seen timestamp
    currentState._last_seen = os_time()

    -- ------------------------------------------------------------------------
    -- 7. Add component namespace to patches (if any)
    -- ------------------------------------------------------------------------
    local patch_key = comp_key or self.component_key
    if patch_key and #patches > 0 and server and server.get_patch_namespace then
        for _, patch in ipairs(patches) do
            patch.component = server:get_patch_namespace(
                patch_key,
                patch.varName or patch.path or patch.cleanPath or ""
            )
            -- Ensure client‑state flags are present
            patch.isClientOnly = true
            patch.isClientState = true
        end
    end

    -- ------------------------------------------------------------------------
    -- 8. Send patches via the appropriate socket
    -- ------------------------------------------------------------------------
    if #patches > 0 then
        local sockets
        if self.parent and self.parent.server and self.parent.server.shared_state and self.parent.server.shared_state.sockets then
            sockets = self.parent.server.shared_state.sockets
        elseif server and server.shared_state and server.shared_state.sockets then
            sockets = server.shared_state.sockets
        end
        if sockets then
            sockets:send_to_user(ws_id, patches)
        elseif log then
            log(log_level.WARN, "[setClientState] No socket available to send patches")
        end
    end

    -- ------------------------------------------------------------------------
    -- 9. Persist to Redis (only if Redis and component key are available)
    -- ------------------------------------------------------------------------
    if server and server.dawn_sockets_handler and
       server.dawn_sockets_handler.state_management and
       server.dawn_sockets_handler.state_management.redis and
       patch_key then

        local redis = server.dawn_sockets_handler.state_management.redis
        local redis_key = string.format("client_state:%s:%s", patch_key, key)


        -- Use pcall to avoid crashing on Redis errors
        local ok, err = pcall(function()
            redis:set(redis_key, cjson_encode(newState or currentState))
            redis:expire(redis_key, 86400)   -- 24 hours
        end)
        if not ok and log then
            log(log_level.WARN, "[setClientState] Redis persistence failed: %s", tostring(err))
        end
    end

    -- ------------------------------------------------------------------------
    -- 10. Prune old client states (lightweight call)
    -- ------------------------------------------------------------------------
    if type(self.pruneClientStates) == "function" then
        self:pruneClientStates(300, 24 * 3600)   -- keep at most 300, max age 24h
    end

end

-- Helper function to add CRUD support to setClientState calls
function new_component:clientCRUD(operation, target, data, options)
    
    -- Ensure target has cs. prefix for client state
    local clientTarget = target
    if type(target) == "string" and not target:match("^cs%.") then
        clientTarget = "cs." .. target
    end
    
    options = options or {}
    options.isClientState = true
    options.isClientOnly = true
    
    return {
        _operation = operation,
        _target = clientTarget,
        _data = data,
        _options = options
    }
end



-- Fixed getClientState that doesn't nest state
function new_component:getClientState(ws_id)
    local key = self.client_token or ws_id
    
    if not key then
        return {}
    end
    
    -- Get from local storage
    local slot = self.client_states[key]
    if not slot then
        return {}
    end
    
    -- Extract clean state WITHOUT nesting
    local cleanState = {}
    
    if slot.state and slot.state.state then
        -- Double nested: slot.state.state
        for k, v in pairs(slot.state.state) do
            if k ~= "state" then  -- Skip any nested state properties
                cleanState[k] = v
            end
        end
    elseif slot.state then
        -- Single nested: slot.state
        for k, v in pairs(slot.state) do
            if k ~= "state" then  -- Skip any nested state properties
                cleanState[k] = v
            end
        end
    else
        -- No nesting
        for k, v in pairs(slot) do
            if k ~= "state" and k ~= "_last_seen" then  -- Skip internal fields
                cleanState[k] = v
            end
        end
    end
    
    return cleanState
end

-- Helper to clean up existing nested state
function new_component:cleanupNestedState()
    for key, slot in pairs(self.client_states) do
        local originalSlot = slot
        
        -- Keep flattening until no more nested state
        local hasChanges = true
        while hasChanges do
            hasChanges = false
            
            -- Check for double nesting: slot.state.state
            if slot.state and slot.state.state then
                slot.state = slot.state.state
                hasChanges = true
            end
            
            -- Check for single nesting: slot.state
            if slot.state then
                -- Move all properties from slot.state to slot
                for k, v in pairs(slot.state) do
                    if k ~= "state" then  -- Don't copy nested state
                        slot[k] = v
                    end
                end
                slot.state = nil  -- Remove the nesting
                hasChanges = true
            end
            
            -- Remove any leftover state properties
            if slot.state then
                slot.state = nil
                hasChanges = true
            end
        end
        
        -- Keep _last_seen if it exists
        if not slot._last_seen and originalSlot._last_seen then
            slot._last_seen = originalSlot._last_seen
        end
    end
end


--- Generate CRUD patches by comparing old and new state
function new_component:generateCRUDPatchesFromDiff(oldState, newState)
    local patches = {}
    
    if not oldState or not newState then return patches end
    
    -- Helper to compare values
    local function valuesEqual(a, b)
        if type(a) ~= type(b) then return false end
        if type(a) ~= "table" then return a == b end
        
        -- Simple table comparison for arrays
        if #a > 0 and #b > 0 then
            if #a ~= #b then return false end
            for i = 1, #a do
                if not valuesEqual(a[i], b[i]) then
                    return false
                end
            end
            return true
        end
        
        -- For objects, compare key by key
        local keys = {}
        for k in pairs(a) do keys[k] = true end
        for k in pairs(b) do keys[k] = true end
        
        for k in pairs(keys) do
            if not valuesEqual(a[k], b[k]) then
                return false
            end
        end
        return true
    end
    
    -- Compare top-level properties
    for key, newValue in pairs(newState) do
        local oldValue = oldState[key]
        
        if not valuesEqual(oldValue, newValue) then
            if type(newValue) == "table" and #newValue > 0 then
                -- Array/list changes
                if not oldValue or #oldValue == 0 then
                    -- Entire new list
                    table.insert(patches, {
                        operation = HTML.CRUD_OPERATIONS.SET,
                        path = key,
                        data = newValue,
                        options = {isClientState = true}
                    })
                else
                    -- Find differences between arrays
                    local added = {}
                    local removed = {}
                    local updated = {}
                    
                    -- Simple diff for now - could be optimized
                    table.insert(patches, {
                        operation = HTML.CRUD_OPERATIONS.SET,
                        path =  key,
                        data = newValue,
                        options = {isClientState = true}
                    })
                end
            elseif type(newValue) == "table" then
                -- Object changes
                table.insert(patches, {
                    operation = HTML.CRUD_OPERATIONS.SET,
                    path = key,
                    data = newValue,
                    options = {isClientState = true}
                })
            else
                -- Primitive value
                table.insert(patches, {
                    operation = HTML.CRUD_OPERATIONS.SET,
                    path = key,
                    data = newValue,
                    options = {isClientState = true}
                })
            end
        end
    end
    
    -- Check for removed keys
    for key, oldValue in pairs(oldState) do
        if newState[key] == nil then
            table.insert(patches, {
                operation = HTML.CRUD_OPERATIONS.DELETE,
                path =  key,
                data = nil,
                options = {isClientState = true}
            })
        end
    end
    
    return patches
end

--- Calculate new client state from CRUD operation
function new_component:calculateNewClientState(currentState, crudOperation)
    local operation = crudOperation._operation
    local target = crudOperation._target:gsub("^cs%.", "")  -- Remove cs. prefix
    local data = crudOperation._data
    local options = crudOperation._options or {}
    
    local newState = {}
    for k, v in pairs(currentState or {}) do
        newState[k] = v
    end
    
    if operation == HTML.CRUD_OPERATIONS.APPEND then
        if not newState[target] then
            newState[target] = {}
        end
        if type(data) == "table" then
            for _, item in ipairs(data) do
                table.insert(newState[target], item)
            end
        else
            table.insert(newState[target], data)
        end
        
        -- Update counter if specified
        if options.updateCounter then
            local counterResult = options.updateCounter(newState)
            for k, v in pairs(counterResult or {}) do
                newState[k] = v
            end
        end
        
    elseif operation == HTML.CRUD_OPERATIONS.SET then
        newState[target] = data
        
    elseif operation == HTML.CRUD_OPERATIONS.UPDATE then
        if type(newState[target]) == "table" and type(data) == "table" then
            for k, v in pairs(data) do
                newState[target][k] = v
            end
        else
            newState[target] = data
        end
        
    elseif operation == HTML.CRUD_OPERATIONS.DELETE then
        if options.key then
            if type(newState[target]) == "table" then
                newState[target][options.key] = nil
            end
        elseif options.index and type(newState[target]) == "table" then
            table.remove(newState[target], options.index)
        elseif options.predicate and type(newState[target]) == "table" then
            local newList = {}
            for _, item in ipairs(newState[target]) do
                if not options.predicate(item) then
                    table.insert(newList, item)
                end
            end
            newState[target] = newList
        else
            newState[target] = nil
        end
    end
    
    return newState
end

-- Helper to count keys in a table
 function tableKeysCount(tbl)
    local count = 0
    for _ in pairs(tbl or {}) do
        count = count + 1
    end
    return count
end

-- Helper function to get table keys as array
function tableKeys(tbl)
    local keys = {}
    for k, _ in pairs(tbl or {}) do
        table.insert(keys, tostring(k))
    end
    return keys
end

function new_component:updateParentClientState(ws_id, newState)
    assert(type(newState) == "table", "updateParentClientState expects a table")
    if not self.parent then
        log(log_level.WARN, "[FunctionalComponent] ⚠️ No parent component to update clientState")
        return nil
    end
    
    -- Check if parent has CRUD support
    if self.parent.reactive_component and 
       (self.parent.reactive_component.crud or self.parent.reactive_component.set) then

        -- Use CRUD operation if available
        return self.parent:setClientState(ws_id, {
            _operation = HTML.CRUD_OPERATIONS.UPDATE,
            _target = self.parent:getClientState(ws_id),
            _data = newState,
            _options = {isClientState = true}
        }, "update parent from child component")
    else
        -- Fall back to traditional update
        return self.parent:setClientState(ws_id, newState, "secondary update from child component")
    end
end

-- Enhanced setState with CRUD support
-- Enhanced setState with CRUD support
function new_component:setState(newState, opts)
    
    -- Allow both table and function syntax
    if type(newState) ~= "table" and type(newState) ~= "function" then
        error("setState expects a table or function", 2)
    end
    
    -- Check for client-only flag
    if type(newState) == "table" and newState.isClientOnly then
        error("Attempted to persist client-only state into component_state", 2)
    end
    
    local patches = {}
    
    -- Check if we have CRUD-enhanced component
    local useCRUD = self.reactive_component and 
                   (self.reactive_component.crud or 
                    self.reactive_component.set or 
                    self.reactive_component.append)
    
    if useCRUD and type(newState) == "table" and newState._operation then
        -- CRUD operation style update for normal state
        
        local operation = newState._operation
        local target = newState._target
        local data = newState._data
        local options = newState._options or {}
        
        patches = self.reactive_component.crud(operation, target, data, options) or {}
        
    else
        -- Traditional update
        
        -- Check if it's an updater function
        if type(newState) == "function" then
            
            -- Call the updater function with current state
            local currentStateCopy = {}
            for k, v in pairs(self.state or {}) do
                currentStateCopy[k] = v
            end
            
            local updatedState = newState(currentStateCopy)
            -- Validate the result
            if type(updatedState) ~= "table" then
                error("Updater function must return a table", 2)
            end
            
            patches = self.reactive_component.setState(updatedState) or {}
        else
            -- It's a partial state object
            patches = self.reactive_component.setState(newState) or {}
        end
    end
    
    -- Update component namespace for patches
    if self.component_key and #patches > 0 then
        for i, patch in ipairs(patches) do
            
            if self.server and self.server.get_patch_namespace then
                patch.component = self.server:get_patch_namespace(
                    self.component_key, 
                    patch.varName or patch.path
                )
            else
            end
        end
    else
    end
    
    -- Persist to Redis if needed
    if self.server and self.server.dawn_sockets_handler and 
       self.server.dawn_sockets_handler.state_management and 
       self.server.dawn_sockets_handler.state_management.redis and 
       self.component_key then
        
        
        local redis = self.server.dawn_sockets_handler.state_management.redis
        local key = "component_state:" .. self.component_key
        
        local ok, err = pcall(function()
            -- Get current state from reactive component (after update)
            local currentState = self.state or {}
            if self.reactive_component and self.reactive_component.getNormalState then
                currentState = self.reactive_component:getNormalState()
            end
            
            
            local jsonData = cjson.encode(currentState)
            
            redis:set(key, jsonData)
            
            redis:expire(key, 86400)
        end)
        
        if not ok then
            log(log_level.WARN, "[FunctionalComponent] ⚠️ Redis SET failed: %s", tostring(err))
        else
        end
    else

    end
    
    -- Send patches
    if #patches > 0 then
        
        -- Push patches individually or as array based on server configuration
        for i, patch in ipairs(patches) do
            
            local patchQueue = nil
            if self.parent and self.parent.server and self.parent.server.patch_queue then
                patchQueue = self.parent.server.patch_queue
            elseif self.server and self.server.patch_queue then
                patchQueue = self.server.patch_queue
            end
            
            if patchQueue then
                patchQueue:push(patch)
            else
               
            end
        end
    else
    end
    
    return patches
end
-- Helper function to check if table contains element
local function tableContains(table, element)
    for _, value in pairs(table) do
        if value == element then
            return true
        end
    end
    return false
end

function new_component:init(callback)
    assert(type(callback) == "function", "Init callback must be a function.")

    if next(self.style.inline) then
        self.props.style = css_helper.style_to_inline(self.style.inline)
    end

    local class_result = css_helper.style_to_class(self.style.css, self.scope_id)
    if class_result.class and class_result.class ~= "" then
        self.props.class = (self.props.class and (self.props.class .. " ") or "") .. class_result.class
    end
    self.collected_css = class_result.css_content

    -- Redis component state load (preserve existing API)
    if self.server and self.server.dawn_sockets_handler and self.server.dawn_sockets_handler.state_management and self.server.dawn_sockets_handler.state_management.redis and self.component_key then
        local redis = self.server.dawn_sockets_handler.state_management.redis
        local key = "component_state:" .. self.component_key
        local ok, val = pcall(function() return redis:get(key) end)
        if ok and val then
            local decoded_ok, decoded = pcall(function() return cjson.decode(val) end)
            if decoded_ok and type(decoded) == "table" then
                self.state = decoded
            end
        end
    end

    if self.view_mode == "lustache" then
        callback(self.children, self.props, self.style, self:getClientState(self._ws_id))
    elseif self.view_mode == "html_reactive" then
        local initial_vdom_builder = callback(
            self.server,
            self.children,
            self.props,
            self.style,
            self.HTMLReactive,
            self.collected_js_scripts,
            self:getClientState(self._ws_id)
        )

        assert(type(initial_vdom_builder) == "function",
            "HTMLReactive init callback must return a VDOM builder function.")

        self.reactive_render_fn = initial_vdom_builder

        -- Check if we have CRUD-enhanced component creation
        if self.HTMLReactive.createCRUDEnhancedComponent then
            self.reactive_component = self.HTMLReactive.createCRUDEnhancedComponent(
                function(state, props, clientState)
                    local renderContext = {
                        state = state,
                        props = props,
                        children = self.children,
                        HTMLReactive = self.HTMLReactive,
                        clientState = clientState or self:getClientState(self._ws_id)
                    }
                    return initial_vdom_builder(renderContext.state, renderContext.props, 
                        renderContext.children, renderContext.HTMLReactive,
                        self.collected_js_scripts, renderContext.clientState)
                end,
                self.state,
                self:getClientState(self._ws_id)
            )
        elseif self.HTMLReactive.createComponentWithClientState then
            self.reactive_component = self.HTMLReactive.createComponentWithClientState({
                render = function(state, props, clientState)
                    local renderContext = {
                        state = state,
                        props = props,
                        children = self.children,
                        HTMLReactive = self.HTMLReactive,
                        clientState = clientState or self:getClientState(self._ws_id)
                    }
                    return initial_vdom_builder(renderContext.state, renderContext.props, 
                        renderContext.children, renderContext.HTMLReactive,
                        self.collected_js_scripts, renderContext.clientState)
                end,
                initialState = self.state,
                initialClientState = self:getClientState(self._ws_id),
                onClientStateChange = function(newClientState, oldClientState)
                    log(log_level.DEBUG, "[FunctionalComponent] ClientState changed")
                end
            })
        else
            self.reactive_component = self.HTMLReactive.createComponent(function(state, props, children, HTMLReactive)
                local renderContext = {
                    state = state,
                    props = props,
                    children = children,
                    HTMLReactive = HTMLReactive,
                    clientState = self:getClientState(self._ws_id)
                }
                return initial_vdom_builder(renderContext.state, renderContext.props, 
                    renderContext.children, renderContext.HTMLReactive, 
                    self.collected_js_scripts, renderContext.clientState)
            end, self.state)
        end

        self.reactive_root_node = self:render()

        -- Enhanced utils with CRUD-like operations
        self.utils = {
            -- Array operations
            arrayPush = function(arr, item)
                if not item then return arr or {} end
                if not arr then return {item} end
                local newArr = {}
                for i = 1, #arr do newArr[i] = arr[i] end
                newArr[#newArr+1] = item
                return newArr
            end,

            arrayUpdate = function(arr, predicate, updater)
                if not arr then return {} end
                local newArr, changed = {}, false
                for i = 1, #arr do
                    local item = arr[i]
                    if item and predicate(item) then
                        newArr[#newArr+1] = updater(item)
                        changed = true
                    else
                        newArr[#newArr+1] = item
                    end
                end
                return changed and newArr or arr
            end,

            arrayRemove = function(arr, predicate)
                if not arr then return {} end
                local newArr, removed = {}, false
                for i = 1, #arr do
                    local item = arr[i]
                    if item and not predicate(item) then
                        newArr[#newArr+1] = item
                    else
                        removed = true
                    end
                end
                return removed and newArr or arr
            end,

            arrayDedupe = function(arr, keyFn)
                if not arr then return {} end
                local seen, newArr = {}, {}
                keyFn = keyFn or function(item) return item.id end
                for i = 1, #arr do
                    local item = arr[i]
                    if item then
                        local key = keyFn(item)
                        if key and not seen[key] then
                            seen[key] = true
                            newArr[#newArr+1] = item
                        end
                    end
                end
                return newArr
            end,

            arrayMap = function(arr, mapper)
                if not arr then return {} end
                local newArr = {}
                for i = 1, #arr do
                    local item = arr[i]
                    newArr[i] = item and mapper(item, i) or nil
                end
                return newArr
            end,
            
            -- Object operations
            objectSet = function(obj, key, value)
                if not obj then return {} end
                local newObj = {}
                for k, v in pairs(obj) do
                    newObj[k] = v
                end
                newObj[key] = value
                return newObj
            end,
            
            objectMerge = function(obj1, obj2)
                local newObj = {}
                for k, v in pairs(obj1 or {}) do
                    newObj[k] = v
                end
                for k, v in pairs(obj2 or {}) do
                    newObj[k] = v
                end
                return newObj
            end,
            
            objectDelete = function(obj, key)
                if not obj then return {} end
                local newObj = {}
                for k, v in pairs(obj) do
                    if k ~= key then
                        newObj[k] = v
                    end
                end
                return newObj
            end,
            
            objectClear = function(obj)
                return {}
            end,
            
            -- CRUD-style operations for reactive components
            crud = function(operation, target, data, options)
                if not self.reactive_component or not self.reactive_component.crud then
                    error("CRUD operations not available for this component")
                end
                
                -- Check if target is a table reference in our state
                local resolvedTarget = target
                if type(target) == "table" then
                    -- Try to find the path to this table
                    local path = HTML.tableToPath(target, 
                        self.reactive_component.getNormalState and 
                        self.reactive_component:getNormalState() or self.state)
                    if path then
                        resolvedTarget = path
                    end
                end
                
                return self.reactive_component.crud(operation, resolvedTarget, data, options or {})
            end,
            
            set = function(target, value, options)
                return self.utils.crud(HTML.CRUD_OPERATIONS.SET, target, value, options)
            end,
            
            append = function(target, items, options)
                return self.utils.crud(HTML.CRUD_OPERATIONS.APPEND, target, items, options)
            end,
            
            prepend = function(target, items, options)
                return self.utils.crud(HTML.CRUD_OPERATIONS.PREPEND, target, items, options)
            end,
            
            delete = function(target, options)
                return self.utils.crud(HTML.CRUD_OPERATIONS.DELETE, target, nil, options)
            end,
            
            update = function(target, data, options)
                return self.utils.crud(HTML.CRUD_OPERATIONS.UPDATE, target, data, options)
            end,
            
            merge = function(target, data, options)
                return self.utils.crud(HTML.CRUD_OPERATIONS.MERGE, target, data, options)
            end,
            
            clear = function(target, options)
                return self.utils.crud(HTML.CRUD_OPERATIONS.CLEAR, target, nil, options)
            end
        }
        
        if not self.patch and type(self.methods) == "table" then
            self.patch = function(self_instance, ws_id, method, args)
                local fn = self_instance.methods[method]
                if type(fn) == "function" then
                    return fn(self_instance, ws_id, args)
                else
                    log(log_level.WARN, "[FunctionalComponent] ⚠️ Method '%s' not found.", tostring(method))
                    return {}
                end
            end
        end
    else
        callback(self.children, self.props, self.style, self.htmlBuilder, self:getClientState(self._ws_id))
        assert(#self.children > 0, "HTMLBuilder mode requires 'children' to be populated.")
    end
end

    function new_component:broadcast_patches(patches_table)
        if not patches_table or type(patches_table) ~= "table" then return end

        for _, patch_data in ipairs(patches_table) do
            patch_data.id = patch_data.id or uuid.v4()
            local component_key_for_patch = self.component_key or "default_component_instance"
            patch_data.component = (self.server and self.server.get_patch_namespace) and self.server:get_patch_namespace(component_key_for_patch, patch_data.varName or patch_data.path) or nil
        end

        if self.server and self.server.patch_queue then
            self.server.patch_queue:push(patches_table)
        end

        if self.state and self.server and self.server.dawn_sockets_handler and self.server.dawn_sockets_handler.state_management and type(self.server.dawn_sockets_handler.state_management.persist_state) == "function" and self.component_key then
            pcall(function()
                self.server.dawn_sockets_handler.state_management:persist_state("component_state:" .. self.component_key, self.state, 3600)
            end)
        end
    end

    function new_component:build()
        if self.view_mode == "lustache" then
            self.props.children = self.children
            local html = self.viewEngine:render(self.viewname, self.props or {})
            return css_helper.render_with_styles(html, false, self.scope_id)
        elseif self.view_mode == "html_reactive" then
            local vdom = self.reactive_root_node

            local function replace_components(node)
                if type(node) ~= "table" then return node end
                if node._component and self.children[node.component_key] then
                    local child = self.children[node.component_key]

                    child.props = child.props or {}
                    for k, v in pairs(node.props or {}) do
                        child.props[k] = v
                    end

                    if not child.parentState and self.state then
                        child.parentState = self.state
                    end

                    if not child.parentMethods and self.methods then
                        child.parentMethods = self.methods
                    end

                    child.props.parentComponentKey = self.component_key
                    child:enableParentClientStateAccess()
                    return child:build()
                end

                if node.children then
                    local newChildren = {}
                    for i = 1, #node.children do
                        newChildren[i] = replace_components(node.children[i])
                    end
                    node.children = newChildren
                end
                return node
            end

            return replace_components(vdom), { self.collected_css }, self.collected_js_scripts
        else
            local html_parts = {}
            for _, node in ipairs(self.children) do
                table_insert(html_parts, self.htmlBuilder.render(node))
            end
            return css_helper.render_with_styles(table.concat(html_parts, ""), false, self.scope_id)
        end
    end

    function new_component:renderFragmentWithAssets(opts)
        opts = opts or {}
        assert(self.view_mode == "html_reactive", "renderFragmentWithAssets only available in html_reactive mode")
        assert(self.reactive_root_node, "No reactive_root_node set. Did you call init()?")

        local fragment_html = self.HTMLReactive.render(self.reactive_root_node)
        local styles = self.collected_css and ("<style>" .. self.collected_css .. "</style>") or ""

        local scripts = {}
        table_insert(scripts, "<script src='https://cdnjs.cloudflare.com/ajax/libs/pako/2.1.0/pako.min.js'></script>")
        if opts.state then
            table_insert(scripts, string.format("<script>window.__INITIAL_STATE__ = %s;</script>", cjson.encode(opts.state)))
            table_insert(scripts, "<script>window.__reactiveComponentInstance__ = {state: {__shared: window.__INITIAL_STATE__ || {},__client: {}}};</script>")
        end
        if opts.filters then
            table_insert(scripts, string.format("<script>window.__PATCH_FILTERS__ = %s;</script>", cjson.encode(opts.filters)))
        end

        if opts.include_patch_client ~= false then
            -- table_insert(scripts, '<script src="/static/assets/js/patchClientHelper.js" type="module"></script>')
            -- table_insert(scripts, '<script src="/static/assets/js/patchClientHelper2.js" type="module"></script>')
            -- table_insert(scripts, '<script src="/static/assets/js/patchClient.js" type="module"></script>')
            
            table_insert(scripts, '<script src="/static/assets/js/Fluid-Container.umd.min.js" type="module"></script>')
        end
        for _, js in ipairs(self.collected_js_scripts or {}) do
            table_insert(scripts, "<script>" .. js .. "</script>")
        end

        return styles .. fragment_html .. table.concat(scripts, "\n")
    end

    function new_component:renderAppPage(config)
        local node, css_list, js_list = self:build()
        return self.HTMLReactive.App({
            title = config.title or "Untitled",
            state = config.state or {},
            filters = config.filters,
            include_patch_client = config.include_patch_client ~= false,
            component_css = css_list,
            component_js_scripts = js_list,
            children = { node },
            head_extra = config.head_extra,
            body_attrs = config.body_attrs
        })
    end

    function new_component:reload()
        if self.view_mode == "lustache" then
            package.loaded[self.viewname] = nil
            self.viewEngine:reloadTemplate(self.viewname)
        else
            log(log_level.WARN, "[FunctionalComponent] reload() not supported for this view mode.")
        end
    end

    function new_component:addChildComponent(key, component)
        assert(type(key) == "string", "Child component key must be a string")
        assert(component and component.view_mode, "Child must be an initialized FuncComponent")

        component:enableParentClientStateAccess()

        if not component._ws_id and self._ws_id then
            component:set_WS_ID(self._ws_id)
            component:set_client_token(self.client_token)

            if self.server and self.server.dawn_sockets_handler and self.server.dawn_sockets_handler.state_management and self.server.dawn_sockets_handler.state_management.redis and component.component_key then
                local redis = self.server.dawn_sockets_handler.state_management.redis
                local keyname = string.format("client_state:%s:%s", component.component_key, self.client_token or self._ws_id)
                local loaded = redis_get_decoded(redis, keyname)
                if loaded then
                    component.client_states[self.client_token or self._ws_id] = loaded
                end
            end

            bfs_traverse_components(component, self._ws_id, self.client_token)
            component:triggerClientReadyCallbacks(self._ws_id, self.client_token)
        end

        self.children[key] = component
        component.parent = self
        component.client_token = self.client_token

        if self.server and not component.server then
            component:setServer(self.server)
        end

        component.parentState = self.state
        component.parentMethods = self.methods
        component.props.parentComponentKey = self.component_key

        self:registerChildMethods(key, component)

        return self
    end

    function new_component:registerChildMethods(childKey, childComponent)
        childComponent:setComponentKey(childKey)

        if not childComponent.methods then return end
        self.methods = self.methods or {}

        for methodName, methodFn in pairs(childComponent.methods) do
            local namespacedMethodName = childKey .. "_" .. methodName
            if not self.methods[namespacedMethodName] then
                self.methods[namespacedMethodName] = function(parent, ws_id, ...)
                    if childComponent.methods and childComponent.methods[methodName] then
                        return childComponent.methods[methodName](childComponent, ws_id, ...)
                    end
                end
                log(log_level.INFO, "[FunctionalComponent] ✅ Registered child method: %s", namespacedMethodName)
            end
        end
    end

    function new_component:callChildMethod(childKey, methodName, ws_id, ...)
        local child = self.children[childKey]
        if not child then
            log(log_level.WARN, "[FunctionalComponent] ⚠️ Child not found: %s", tostring(childKey))
            return nil
        end

        if child.methods and child.methods[methodName] then
            return child.methods[methodName](child, ws_id, ...)
        else
            log(log_level.WARN, "[FunctionalComponent] ⚠️ Method not found in child: %s", tostring(methodName))
            return nil
        end
    end

    function new_component:getChildComponent(childKey)
        return self.children[childKey]
    end

    function new_component:getChildrenComponents()
        return self.children
    end

    function new_component:getParentState()
        if self.parent and self.parent.state then return self.parent.state end
        if self.parentState then return self.parentState end
        return {}
    end

    function new_component:updateParentState(newState)
        if self.parent and self.parent.setState then return self.parent:setState(newState) end
        return {}
    end

    function new_component:callParentMethod(methodName, ...)
        if self.parent and self.parent.methods and self.parent.methods[methodName] then
            return self.parent.methods[methodName](self.parent, ...)
        elseif self.parentMethods and self.parentMethods[methodName] then
            return self.parentMethods[methodName](self, ...)
        end
        return nil
    end

    function new_component:getParentComponent()
        return self.parent
    end

    function new_component:hasParent()
        return self.parent ~= nil
    end

    function new_component:getComponentKey()
        return self.props.componentKey or self.component_key
    end

    function new_component:getChildKey()
        return self.props.childComponentKey or (self.child and self.child.component_key)
    end

    function new_component:getParentKey()
        return self.props.parentComponentKey or (self.parent and self.parent.component_key)
    end

    function new_component:sendToParent(messageType, data)
        if self.parent and self.parent.methods and self.parent.methods.onChildMessage then
            return self.parent.methods.onChildMessage(self.parent, self.component_key, messageType, data)
        end
        return nil
    end

    function new_component:rerender()
        assert(self.view_mode == "html_reactive", "rerender() only supported in html_reactive mode")
        assert(self.reactive_render_fn, "No reactive_render_fn set, did you call init()?")

        local new_root = self:render()
        -- local patches = self.HTMLReactive.diff(self.reactive_root_node, new_root)
        -- self.reactive_root_node = new_root

        -- if self.component_key and #patches > 0 then
        --     for _, patch in ipairs(patches) do
        --         patch.component = (self.server and self.server.get_patch_namespace) and self.server:get_patch_namespace(self.component_key, patch.varName or patch.path) or nil
        --     end
        -- end

        -- if #patches > 0 and self.server and self.server.patch_queue then
        --     self.server.patch_queue:push(patches)
        -- end

        return new_root
    end

    return new_component
end

return FunctionalComponent
