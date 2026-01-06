
-- FunctionalComponent.lua
-- ✅ Full WebSocket-aware + HTMLReactive component module + Redis state persistence + ClientState support
-- OPTIMIZED: memory/performance improvements for clientStates and general micro-optimizations
-- UPDATED: Fixed integration with HTMLReactive.lua
-- UPDATED: Corrected setState with proper state/VDOM snapshots and diffing

local viewEngine = require("layout.renderer.lustache_renderer")
local css_helper = require("utils.css_helper")
local HTMLBuilder = require("layout.renderer.MustacheHTMLBuilder")
local HTMLReactive = require("layout.renderer.LuaHTMLReactive")
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
        __vdom = nil, -- NEW: VDOM snapshot for diffing
        setOnClientReady = function  ()    
self:onClientReady(function (comp, parent_ws_id, parent_client_token)
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

    -- NEW: emitPatches method for versioned patch envelopes
    function new_component:emitPatches(patches_envelope)
        assert(type(patches_envelope) == "table" and patches_envelope.version, "Patches must be a versioned envelope.")

        -- Add component namespace to patches if available
        if self.component_key and patches_envelope.ops and #patches_envelope.ops > 0 then
            for _, patch in ipairs(patches_envelope.ops) do
                patch.component = (self.server and self.server.get_patch_namespace) 
                    and self.server:get_patch_namespace(self.component_key, patch.varName or patch.path) 
                    or self.component_key
            end
        end

        -- Send patches to patch queue
        if patches_envelope.ops and #patches_envelope.ops > 0 and self.server and self.server.patch_queue then
            self.server.patch_queue:push(patches_envelope)
        end

        -- Also broadcast to connected clients
        if patches_envelope.ops and #patches_envelope.ops > 0 and self.clients then
            for ws_id in pairs(self.clients) do
                if self.server and self.server.shared_state and self.server.shared_state.sockets then
                    pcall(function()
                        self.server.shared_state.sockets:send_to_user(ws_id, {
                            id = uuid.v4(),
                            type = "patches",
                            data = patches_envelope.ops
                        })
                    end)
                end
            end
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

        local mod_name = self._source_file:gsub("%.lua$", ""):gsub("^./", ""):gsub("/", ".")
        package.loaded[mod_name] = nil

        local ok, reloaded = pcall(require, mod_name)
        if not ok then
            log(log_level.ERROR, "[FunctionalComponent] ❌ Reload failed: %s", tostring(reloaded))
            return
        end

        if self.view_mode == "html_reactive" and type(self.reactive_render_fn) == "function" then
            local new_vdom_fn = self.reactive_render_fn
            -- recreate reactive component with client state if API available
            if self.HTMLReactive.createComponentWithClientState then
                self.reactive_component = self.HTMLReactive.createComponentWithClientState({
                    render = new_vdom_fn,
                    initialState = self.state or {},
                    onClientStateChange = function(newClientState, oldClientState)
                        log(log_level.DEBUG, "[FunctionalComponent] ClientState changed after reload")
                    end
                })
            else
                self.reactive_component = self.HTMLReactive.createComponent(new_vdom_fn, self.state or {})
            end

            self.reactive_root_node = self:render()
            self.__vdom = self.reactive_root_node -- Update VDOM snapshot
            log(log_level.INFO, "[FunctionalComponent] ✅ DOM rebuilt after reload.")
        elseif self.view_mode == "lustache" then
            self.viewEngine:reloadTemplate(self.viewname)
            log(log_level.INFO, "[FunctionalComponent] ✅ Mustache template reloaded.")
        end
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
        if self.component_key then
            assert(self.component_key == key, "Component key already set to a different value.")
            return
        end
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

        local hadRedisState = false
        -- Load persisted client state if Redis available
        if self.server and self.server.dawn_sockets_handler and self.server.dawn_sockets_handler.state_management and self.server.dawn_sockets_handler.state_management.redis and self.component_key then
            local redis = self.server.dawn_sockets_handler.state_management.redis
            local key = string.format("client_state:%s:%s", self.component_key, self.client_token or ws_id)
            local ok, val = pcall(function() return redis:get(key) end)
            if ok and val then
                local decoded_ok, decoded = pcall(function() return cjson.decode(val) end)
                if decoded_ok and type(decoded) == "table" then
                    self.client_states[self.client_token or ws_id] = { state = decoded, _last_seen = os_time() }
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
        local ok, val = pcall(function() return redis:get(key) end)
        if not ok or not val then return nil end
        local dec_ok, dec = pcall(function() return cjson.decode(val) end)
        if dec_ok and type(dec) == "table" then return dec end
        return nil
    end

    function new_component:getRedisClientState(client_token_or_ws_id, comp_key)
        local state = {}

        if self.server and self.server.dawn_sockets_handler and self.server.dawn_sockets_handler.state_management and self.server.dawn_sockets_handler.state_management.redis and self.component_key then
            local redis = self.server.dawn_sockets_handler.state_management.redis
            local key = string.format("client_state:%s:%s", comp_key or self.component_key, client_token_or_ws_id)
            local decoded = redis_get_decoded(redis, key)
            if decoded then
                state = decoded
            else
                state = {}
                local primeOk, primeErr = pcall(function()
                    redis:set(key, cjson.encode(state))
                    redis:expire(key, 86400)
                end)
                if not primeOk then
                    log(log_level.WARN, "[FunctionalComponent] ⚠️ Redis SET (prime empty state) failed: %s", tostring(primeErr))
                end
            end
        end

        if type(state) ~= "table" then state = {} end
        return state
    end


    function new_component:setRedisComponentState(comp_key, new_state)
    if type(new_state) ~= "table" then
        log(log_level.WARN,
            "[FunctionalComponent] ⚠️ setRedisComponentState expected table, got %s",
            type(new_state)
        )
        return false
    end

    if self.server
        and self.server.dawn_sockets_handler
        and self.server.dawn_sockets_handler.state_management
        and self.server.dawn_sockets_handler.state_management.redis
        and (comp_key or self.component_key)
    then
        local redis = self.server.dawn_sockets_handler.state_management.redis
        local key = "component_state:" .. (comp_key or self.component_key)

        local ok, err = pcall(function()
            redis:set(key, cjson.encode(new_state))
            redis:expire(key, 86400)
        end)

        if not ok then
            log(log_level.WARN,
                "[FunctionalComponent] ⚠️ Redis SET (component state) failed: %s",
                tostring(err)
            )
            return false
        end

        return true
    end

    log(log_level.WARN,
        "[FunctionalComponent] ⚠️ Cannot SET component state — Redis or component key missing"
    )
    return false
end


function new_component:setComponentState(comp_key, newState)
    assert(type(newState) == "table", "setComponentState expects a table")
    assert(comp_key, "setComponentState requires a component key")

    local self_instance = self
    local current_state = self_instance.state or {}

    ---------------------------------------------------------
    -- IMMUTABLE BFS DIFF (Cycle Safe)
    ---------------------------------------------------------
    local function clone_table(tbl)
        local out = {}
        for k, v in pairs(tbl) do out[k] = v end
        return out
    end

    local function immutable_bfs_diff_cycle_safe(old, new)
        local changed = {}
        local visited = setmetatable({}, { __mode = "k" })
        local queue = { { old, new, {} } }

        local result = clone_table(old)
        visited[old] = { clone = result }

        while #queue > 0 do
            local item = table.remove(queue, 1)
            local old_tbl, new_tbl, path = item[1], item[2], item[3]
            local clone = visited[old_tbl].clone

            for key, new_value in pairs(new_tbl) do
                local old_value = old_tbl[key]
                local old_type = type(old_value)
                local new_type = type(new_value)

                if old_type == "table" and new_type == "table" then
                    if old_value == new_value then
                        clone[key] = old_value
                    else
                        if not visited[old_value] then
                            local new_clone = clone_table(old_value)
                            clone[key] = new_clone
                            visited[old_value] = { clone = new_clone }

                            table.insert(queue, {
                                old_value,
                                new_value,
                                { unpack(path), key }
                            })
                        else
                            clone[key] = visited[old_value].clone
                        end
                    end

                elseif old_value ~= new_value then
                    clone[key] = new_value

                    local parts = {}
                    if type(path) == "table" and #path > 0 then
                        for i = 1, #path do parts[#parts+1] = path[i] end
                    end
                    parts[#parts+1] = key

                    changed[table.concat(parts, ".")] = new_value

                else
                    clone[key] = old_value
                end
            end
        end

        return result, changed
    end

    ---------------------------------------------------------
    -- Apply immutable diff
    ---------------------------------------------------------
    local nextState, changed = immutable_bfs_diff_cycle_safe(
        current_state,
        newState
    )

    if not next(changed) then
        return {}
    end

    -- replace state
    self_instance.state = nextState

    ---------------------------------------------------------
    -- Generate patches
    ---------------------------------------------------------
    local patches = {}

    if self_instance.reactive_component
        and type(self_instance.reactive_component.setState) == "function"
    then
        patches = self_instance.reactive_component.setState(changed) or {}
    else
        for key, value in pairs(changed) do
            table.insert(patches, {
                type = "update-var",
                varName = key,
                value = value,
                selector = string.format('[data-bind="%s"]', key),
                isClientState = false
            })
        end
    end

    ---------------------------------------------------------
    -- Add namespace
    ---------------------------------------------------------
    if comp_key and #patches > 0 then
        for _, patch in ipairs(patches) do
            patch.component =
                (self_instance.server and self_instance.server.get_patch_namespace)
                and self_instance.server:get_patch_namespace(
                    comp_key,
                    patch.varName or patch.path
                )
                or comp_key
        end
    end

    ---------------------------------------------------------
    -- Send patches to all connected clients
    ---------------------------------------------------------
    if #patches > 0 then
        local payload = {
            id = uuid.v4(),
            type = "patches",
            data = patches
        }

        if self_instance.clients then
            for ws_id in pairs(self_instance.clients) do
                if self_instance.server
                   and self_instance.server.shared_state
                   and self_instance.server.shared_state.sockets
                then
                    pcall(function()
                        self_instance.server.shared_state.sockets:
                            send_to_user(ws_id, payload)
                    end)
                end
            end
        end
    end

    ---------------------------------------------------------
    -- Persist to Redis for THIS component key
    ---------------------------------------------------------
    if self_instance.server
        and self_instance.server.dawn_sockets_handler
        and self_instance.server.dawn_sockets_handler.state_management
        and self_instance.server.dawn_sockets_handler.state_management.redis
        and comp_key
    then
        local redis = self_instance.server.dawn_sockets_handler.state_management.redis
        local key = "component_state:" .. comp_key

        local ok, err = pcall(function()
            redis:set(key, cjson.encode(self_instance.state))
            redis:expire(key, 86400)
        end)

        if not ok then
            log(log_level.WARN,
                "[FunctionalComponent] ⚠️ Redis SET failed: %s",
                tostring(err)
            )
        end
    end

    return patches
end



    function new_component:getRedisComponentState(comp_key)
    local state = {}

    -- Ensure required objects exist
    if self.server
        and self.server.dawn_sockets_handler
        and self.server.dawn_sockets_handler.state_management
        and self.server.dawn_sockets_handler.state_management.redis
        and (comp_key or self.component_key)
    then
        local redis = self.server.dawn_sockets_handler.state_management.redis
        local key = "component_state:" .. (comp_key or self.component_key)

        -- Try decode via your helper (assumed)
        local decoded = redis_get_decoded(redis, key)

        if decoded then
            state = decoded

        else
            -- Prime with empty table since state missing
            state = {}

            local primeOk, primeErr = pcall(function()
                redis:set(key, cjson.encode(state))
                redis:expire(key, 86400)
            end)

            if not primeOk then
                log(log_level.WARN,
                    "[FunctionalComponent] ⚠️ Redis SET (prime empty component state) failed: %s",
                    tostring(primeErr)
                )
            end
        end
    end

    -- Guarantee table return
    if type(state) ~= "table" then state = {} end
    return state
end

    -- NEW: Get clientState (returns plain table). Manages parent merging if enabled.
    function new_component:getClientState(ws_id)
        -- If no token, try to borrow from parent
        if not self.client_token and self.parent then
            self.client_token = self.parent.client_token
        end

        

        local key = self.client_token or ws_id
        if not key then
            return {}
        end
        -- ensure internal structure
        local slot = self.client_states[key]
        if not slot then
            slot = { state = {}, _last_seen = os_time() }
            self.client_states[key] = slot
        else
            slot._last_seen = os_time()
        end

        local clientState = slot.state

        if self._parentClientStateEnabled and self.parent then
            local parentClientState = (type(self.parent.getClientState) == "function") and self.parent:getClientState(ws_id) or nil
            if type(parentClientState) == "table" then
                -- To avoid copying/allocating a merged table in common case, embed parent under parent's component key
                clientState[self.parent.component_key] = parentClientState
            end
        end

        return clientState
    end

    -- NEW: Prune client_states to limit memory consumption.
    -- maxEntries: maximum number of client entries to keep (evict oldest when exceeded)
    -- maxAgeSeconds: maximum age (seconds); entries older than this are removed
    function new_component:pruneClientStates(maxEntries, maxAgeSeconds)
        maxEntries = tonumber(maxEntries) or 500
        maxAgeSeconds = tonumber(maxAgeSeconds) or (24 * 3600)

        local now = os_time()
        local entries = {}
        local count = 0

        for token, slot in pairs(self.client_states) do
            if type(slot) == "table" then
                local last = slot._last_seen or 0
                if now - last > maxAgeSeconds then
                    self.client_states[token] = nil -- aged out
                else
                    count = count + 1
                    entries[count] = { token = token, last = last }
                end
            else
                -- garbage entry: remove
                self.client_states[token] = nil
            end
        end

        if #entries > maxEntries then
            table.sort(entries, function(a, b) return a.last < b.last end) -- oldest first
            local to_remove = #entries - maxEntries
            for i = 1, to_remove do
                self.client_states[entries[i].token] = nil
            end
        end
        return true
    end


    -- Robust, production-ready setClientState
function new_component:setClientState(ws_id, newState, comp_key)
    assert(type(newState) == "table", "setClientState expects a table")

    -- ---- configuration / helpers ----
    local MAX_PATCH_PAYLOAD = 1024 * 256 -- 256KB payload guard for sending

    local function safe_encode(obj)
        local ok, s = pcall(function() return cjson.encode(obj) end)
        if not ok then
            return "<non-serializable>"
        end
        return s
    end

    -- Replace circular references with a placeholder to avoid infinite recursion/huge payloads.
    local function remove_cycles(tbl)
        local seen = {}
        local function _walk(v)
            if type(v) ~= "table" then return v end
            if seen[v] then return "[[CIRCULAR]]" end
            seen[v] = true
            local out = {}
            for k, val in pairs(v) do
                out[k] = _walk(val)
            end
            return out
        end
        return _walk(tbl)
    end

    -- normalize comp_key and validate

    local normalized_key = comp_key or self.component_key
    -- if caller supplied a validComponentKeys table on the component, check it
    if self.validComponentKeys and type(self.validComponentKeys) == "table" then
        if not self.validComponentKeys[normalized_key] then
            return
        end
    end
    comp_key = normalized_key

    -- ensure client_token inheritance
    if not self.client_token and self.parent then
        self.client_token = self.parent.client_token
    end

    local key = self.client_token or ws_id
    if not key then
        return {}
    end

    -- ensure slot exists
    local slot = self.client_states[key]
    if not slot then
        slot = { state = {}, _last_seen = os_time() }
        self.client_states[key] = slot
    end

    local clientState = slot.state
    if not clientState or type(clientState) ~= "table" then
        clientState = {}
        slot.state = clientState
    end

    -- take a shallow snapshot of the previous state
    local oldState = {}
    if self.HTMLReactive and self.HTMLReactive.shallowCopy then
        oldState = (self.HTMLReactive.shallowCopy(clientState) or {})
    else
        for k, v in pairs(clientState) do oldState[k] = v end
    end

    -- Prevent accidental nested routeManager recursion: if newState contains routeManager (or known recursive fields),
    -- sanitize it by replacing recursive cycles. We already call remove_cycles for logging, but also sanitize the actual newState.
    local sanitizedNewState = {}
    for k, v in pairs(newState) do
        -- convert any tables that are obviously self-referential to a safe copy that replaces cycles
        if type(v) == "table" then
            -- shallow copy but replace cycles
            sanitizedNewState[k] = remove_cycles(v)
        else
            sanitizedNewState[k] = v
        end
    end

    -- MERGE: apply sanitizedNewState into clientState (in-place).
    -- NOTE: v == nil acts as delete.
    for k, v in pairs(sanitizedNewState) do
        if v == nil then
            if clientState[k] ~= nil then
                clientState[k] = nil
            end
        else
            local before = clientState[k]
            clientState[k] = v
        end
    end

    -- update last seen
    slot._last_seen = os_time()

    -- ✅ FIXED: Use the new setState approach for client state updates
    -- This ensures proper VDOM snapshotting and diffing
    if self.view_mode == "html_reactive" and self.reactive_component then
        -- Create a wrapper updater function that updates client state
        local clientStateUpdater = function(currentState)
            -- Note: currentState here is component state, not client state
            -- We need to return the same state but trigger a re-render
            -- The actual client state is already updated above
            return currentState
        end
        
        -- Call setState to trigger proper VDOM diffing
        self:setState(clientStateUpdater)
    end

    -- Persist to Redis (only the state object)
    if self.server and self.server.dawn_sockets_handler and
       self.server.dawn_sockets_handler.state_management and
       self.server.dawn_sockets_handler.state_management.redis and
       self.component_key then

        local redis = self.server.dawn_sockets_handler.state_management.redis
        local keyname = string.format("client_state:%s:%s", comp_key or self.component_key, key)

        local ok, err = pcall(function()
            redis:set(keyname, cjson.encode(clientState))
            redis:expire(keyname, 86400)
        end)
    end

    -- Prune stale states (best-effort)
    pcall(function() self:pruneClientStates(300, 24 * 3600) end)

    -- Return canonical, up-to-date state
    return clientState
end


    function new_component:updateParentClientState(ws_id, newState)
        assert(type(newState) == "table", "updateParentClientState expects a table")
        if not self.parent then
            log(log_level.WARN, "[FunctionalComponent] ⚠️ No parent component to update clientState")
            return nil
        end
        return self.parent:setClientState(ws_id, newState)
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

    function new_component:sendClientPatches(ws_id, state_changes)
        assert(type(state_changes) == "table", "sendClientPatches expects a table of state changes")
        assert(self.component_key, "Component key must be set before sending patches")

        local clientState = self:getClientState(ws_id)

        -- merge state changes into client state
        for k, v in pairs(state_changes) do
            clientState[k] = v
        end

        -- persist in internal slot
        local key = self.client_token or ws_id
        self.client_states[key] = self.client_states[key] or { state = clientState, _last_seen = os_time() }
        self.client_states[key].state = clientState
        self.client_states[key]._last_seen = os_time()

        -- Generate patches using reactive_component.setState if available
        local patches = {}
        if self.reactive_component and type(self.reactive_component.setState) == "function" then
            patches = self.reactive_component.setState(state_changes) or {}
        end

        for _, patch in ipairs(patches) do
            patch.component = (self.server and self.server.get_patch_namespace) and self.server:get_patch_namespace(self.component_key, patch.varName or patch.path) or nil
            patch.isClientOnly = true
        end

        if #patches > 0 then
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

        -- Persist to Redis if available
        if self.server and self.server.dawn_sockets_handler and self.server.dawn_sockets_handler.state_management and self.server.dawn_sockets_handler.state_management.redis then
            local redis = self.server.dawn_sockets_handler.state_management.redis
            local keyname = string.format("client_state:%s:%s", self.component_key, ws_id)
            local ok, err = pcall(function()
                redis:set(keyname, cjson.encode(clientState))
                redis:expire(keyname, 86400)
            end)
            if not ok then
                log(log_level.WARN, "[FunctionalComponent] ⚠️ Redis SET (client_state) failed: %s", tostring(err))
            end
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

    -- Helper for deep equality comparison
    local deepEqual = HTMLReactive.deepEqual or function(a, b)
        if type(a) ~= type(b) then return false end
        if type(a) ~= "table" then return a == b end
        
        local visited = {}
        local function compare(t1, t2)
            if visited[t1] and visited[t1] == t2 then return true end
            visited[t1] = t2
            
            local count1, count2 = 0, 0
            for k, v in pairs(t1) do
                count1 = count1 + 1
                if not compare(v, t2[k]) then return false end
            end
            
            for _ in pairs(t2) do
                count2 = count2 + 1
            end
            
            return count1 == count2
        end
        
        return compare(a, b)
    end

    -- ✅ FIXED: Corrected setState method with proper VDOM snapshotting and diffing
    function new_component:setState(updater)
        -- Ensure component is initialized in reactive mode
        if self.view_mode ~= "html_reactive" or not self.HTMLReactive or not self.reactive_render_fn then
            error("setState called on non-reactive component or before initial render.", 2)
        end
        
        -- 1. Snapshot previous state and VDOM
        local prevState = self.state
        -- Use __vdom as the authoritative VDOM snapshot
        local prevVDOM = self.__vdom or self.reactive_root_node 

        -- 2. Calculate next state and update
        local nextState
        if type(updater) == "function" then
            nextState = updater(prevState)
        else
            nextState = updater -- Allow direct table assignment
        end
        
        self.state = nextState
        
        -- 3. Render new VDOM
        local nextVDOM = self:render() -- Renders using the new self.state

        -- 4. Store new VDOM
        self.__vdom = nextVDOM
        self.reactive_root_node = nextVDOM -- Keep the original field in sync

        -- 5. Generate patches with state delta context
        local patches_envelope = self.HTMLReactive.diff(prevVDOM, nextVDOM, {
            prevState = prevState,
            nextState = nextState,
            componentId = self.component_key -- Use the component's unique key
        })

        -- 6. Send the patch envelope
        self:emitPatches(patches_envelope)

        -- 7. Persist state to Redis
        if self.server and self.server.dawn_sockets_handler and
           self.server.dawn_sockets_handler.state_management and
           self.server.dawn_sockets_handler.state_management.redis and
           self.component_key then
            local redis = self.server.dawn_sockets_handler.state_management.redis
            local key = "component_state:" .. self.component_key
            local ok, err = pcall(function()
                redis:set(key, cjson.encode(self.state))
                redis:expire(key, 86400)
            end)
        end

        return patches_envelope
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

            if self.HTMLReactive.createComponentEx then
                self.reactive_component = self.HTMLReactive.createComponentEx({
                    render = function(state, props, clientState)
                        local renderContext = {
                            state = state,
                            props = props,
                            children = self.children,
                            HTMLReactive = self.HTMLReactive,
                            clientState = clientState or self:getClientState(self._ws_id)
                        }
                        return initial_vdom_builder(renderContext.state, renderContext.props, renderContext.children, renderContext.HTMLReactive, self.collected_js_scripts, renderContext.clientState)
                    end,
                    initialState = self.state,
                    initialClientState = self:getClientState(self._ws_id),
                    methods = self.methods
                })
                
                -- Set component key on reactive component if needed
                if self.component_key then
                    self.reactive_component.component_key = self.component_key
                end
            else
                self.reactive_component = self.HTMLReactive.createComponent(function(state, props)
                    local renderContext = {
                        state = state,
                        props = props,
                        children = self.children,
                        HTMLReactive = self.HTMLReactive,
                        clientState = self:getClientState(self._ws_id)
                    }
                    return initial_vdom_builder(renderContext.state, renderContext.props, renderContext.children, renderContext.HTMLReactive, self.collected_js_scripts, renderContext.clientState)
                end, self.state)
            end

            self.reactive_root_node = self:render()
            self.__vdom = self.reactive_root_node -- Initialize VDOM snapshot

            -- utils (kept API but optimized implementation)
            self.utils = {
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
                
                -- Handle HTML.Component placeholders
                if node._component and node.component_key and self.children[node.component_key] then
                    local child = self.children[node.component_key]
                    
                    -- Merge props
                    child.props = child.props or {}
                    for k, v in pairs(node.props or {}) do
                        child.props[k] = v
                    end
                    
                    child.props.parentComponentKey = self.component_key
                    
                    -- Build child component
                    local child_html, child_css, child_js = child:build()
                    
                    -- Convert HTML string back to VDOM node for embedding
                    if type(child_html) == "string" then
                        return self.HTMLReactive.e("div", {
                            ["data-embedded-component"] = node.component_key,
                            ["data-original-props"] = cjson.encode(node.props or {})
                        }, child_html)
                    else
                        return child_html
                    end
                end
                
                -- Recursively process children
                if node.children then
                    local newChildren = {}
                    for i = 1, #node.children do
                        newChildren[i] = replace_components(node.children[i])
                    end
                    node.children = newChildren
                end
                return node
            end

            local processed_vdom = replace_components(vdom)
            local html = self.HTMLReactive.render(processed_vdom)
            
            return html, { self.collected_css }, self.collected_js_scripts
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
            table_insert(scripts, '<script src="/static/assets/js/patchClient.js" type="module"></script>')
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
                    component.client_states[self.client_token or self._ws_id] = { state = loaded, _last_seen = os_time() }
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
        
        -- Snapshot previous VDOM
        local prevVDOM = self.__vdom or self.reactive_root_node
        
        -- Re-render to update internal state
        local new_root = self:render()
        self.reactive_root_node = new_root
        self.__vdom = new_root -- Update VDOM snapshot
        
        -- Generate patches with state delta context
        local patches_envelope = self.HTMLReactive.diff(prevVDOM, new_root, {
            prevState = self.state,
            nextState = self.state,
            componentId = self.component_key
        })

        -- Send patches
        self:emitPatches(patches_envelope)
        
        return patches_envelope
    end

    return new_component
end

return FunctionalComponent
