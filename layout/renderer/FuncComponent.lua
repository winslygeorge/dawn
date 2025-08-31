-- FunctionalComponent.lua
-- ✅ Full WebSocket-aware + HTMLReactive component module + Redis state persistence

local viewEngine = require("layout.renderer.lustache_renderer")
local css_helper = require("utils.css_helper")
local HTMLBuilder = require("layout.renderer.MustacheHTMLBuilder")
local HTMLReactive = require("layout.renderer.LuaHTMLReactive")
local cjson = require('dkjson')
local uuid = require("utils.uuid")
local log_level = require("utils.logger").LogLevel

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
        client_states = {}, -- maps ws_id => { state = {} }
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
    }

    setmetatable(new_component, { __index = self })


       -- Add this method to register with watcher
    function new_component:enableHotReload(server)
        if not self._watcher and server and server.dev_watcher then
            self._watcher = server.dev_watcher
            -- self._watcher:register_component(self)
            self.server.logger:log(log_level.DEBUG, 
                "[FunctionalComponent] ✅ Enabled hot reload for: "..tostring(self.component_key),
                "FunctionalComponent", self.component_key)
        end
        return self
    end

        -- 🔥 Add hot reload support
    function new_component:hotReload()
        if not self._source_file then
            self.server.logger:log(log_level.WARN,
                "[FunctionalComponent] ⚠️ Cannot hot reload (no source file tracked).",
                "FunctionalComponent", self.component_key)
            return
        end

        self.server.logger:log(log_level.INFO,
            "[FunctionalComponent] ♻️ Hot reloading component from: " .. self._source_file,
            "FunctionalComponent", self.component_key)

        -- Clear Lua cache for source
        local mod_name = self._source_file:gsub("%.lua$", ""):gsub("^./", ""):gsub("/", ".")
        package.loaded[mod_name] = nil

        local ok, reloaded = pcall(require, mod_name)
        if not ok then
            self.server.logger:log(log_level.ERROR,
                "[FunctionalComponent] ❌ Reload failed: " .. tostring(reloaded),
                "FunctionalComponent", self.component_key)
            return
        end

        -- Reset render fn and DOM tree
        if self.view_mode == "html_reactive" and type(self.reactive_render_fn) == "function" then
            local new_vdom_fn = self.reactive_render_fn
            self.reactive_component = self.HTMLReactive.createComponent(new_vdom_fn, self.state or {})
            self.reactive_root_node = self:render()

            self.server.logger:log(log_level.INFO,
                "[FunctionalComponent] ✅ DOM rebuilt after reload.",
                "FunctionalComponent", self.component_key)
        elseif self.view_mode == "lustache" then
            self.viewEngine:reloadTemplate(self.viewname)
            self.server.logger:log(log_level.INFO,
                "[FunctionalComponent] ✅ Mustache template reloaded.",
                "FunctionalComponent", self.component_key)
        end
    end


    -- Add this to automatically enable when server is set
    function new_component:setServer(server)
        assert(type(server) == "table", "server must be an object of dawn server table")
        self.server = server
        -- if server.dev_watcher then
        --     self:enableHotReload(server)
        -- end
        return self
    end


    function new_component:setComponentKey(key)
        assert(type(key) == "string" and #key > 0, "component_key must be a non-empty string")
        if self.component_key then
            assert(self.component_key == key, "Component key already set to a different value.")
            return
        end
        self.component_key = key
        self.server:register_reactive_component(self, self.component_key)
    end

    function new_component:onJoin(ws_id)
        self.clients[ws_id] = true

        -- Try to load persisted client state
        if self.server and self.server.dawn_sockets_handler.state_management.redis and self.component_key then
            local redis = self.server.dawn_sockets_handler.state_management.redis
            local key = string.format("client_state:%s:%s", self.component_key, ws_id)
            local ok, val = pcall(function() return redis:get(key) end)
            if ok and val then
                local decoded, _, err = cjson.decode(val)
                if not err and type(decoded) == "table" then
                    self.client_states[ws_id] = decoded
                end
            end
        end
    end

    function new_component:beforeClose(ws_id)
        self.clients[ws_id] = nil
    end

    function new_component:getClientState(ws_id)
        self.client_states[ws_id] = self.client_states[ws_id] or {}
        return self.client_states[ws_id]
    end

    function new_component:setClientState(ws_id, newState)
        assert(type(newState) == "table", "setClientState expects a table")
        local clientState = self:getClientState(ws_id)
        for k, v in pairs(newState) do
            clientState[k] = v
        end
        if self.server and self.server.dawn_sockets_handler.state_management.redis and self.component_key then
            local redis = self.server.dawn_sockets_handler.state_management.redis
            local key = string.format("client_state:%s:%s", self.component_key, ws_id)
            local ok, err = pcall(function()
                redis:set(key, cjson.encode(clientState))
                redis:expire(key, 86400) -- expires after 24 hours
            end)
            if not ok then
                self.server.logger:log(log_level.WARN, "[FunctionalComponent] ⚠️ Redis SET (client_state) failed: " .. tostring(err), "FunctionalComponent", self.component_key)
            end
        end
        return clientState
    end


    function new_component:sendClientPatches(ws_id, state_changes)
    assert(type(state_changes) == "table", "sendClientPatches expects a table of state changes")
    assert(self.component_key, "Component key must be set before sending patches")

    -- Ensure client state tracking exists
    local clientState = self:getClientState(ws_id)

    -- Merge state changes into client state
    for k, v in pairs(state_changes) do
        clientState[k] = v
    end
    self.client_states[ws_id] = clientState

    -- Generate patches using the same logic as setState()
    local patches = self.reactive_component.setState(state_changes)

    -- Attach component namespace for filtering
    for _, patch in ipairs(patches) do
        patch.component = self.server:get_patch_namespace(
            self.component_key,
            patch.varName or patch.path
        )
        -- Mark as client-only to avoid accidental broadcast
        patch.isClientOnly = true
    end

    -- Send patches to a single client
 -- Send patches to a single client
if #patches > 0 then
    if self.parent then
        -- Let parent dispatch to client through its socket layer
        self.parent.server.shared_state.sockets:send_to_user(ws_id, {
            id = uuid.v4(),
            type = "patches",
            data = patches
        })
    else
        self.server.shared_state.sockets:send_to_user(ws_id, {
            id = uuid.v4(),
            type = "patches",
            data = patches
        })
    end
end


    -- Persist client-specific state if Redis is enabled
    if self.server and self.server.dawn_sockets_handler.state_management.redis then
        local redis = self.server.dawn_sockets_handler.state_management.redis
        local key = string.format("client_state:%s:%s", self.component_key, ws_id)
        local ok, err = pcall(function()
            redis:set(key, cjson.encode(clientState))
            redis:expire(key, 86400)
        end)
        if not ok then
            self.server.logger:log(log_level.WARN, "[FunctionalComponent] ⚠️ Redis SET (client_state) failed: " .. tostring(err), "FunctionalComponent", self.component_key)
        end
    end
end

----------------------------------------------------------------

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
        return self.reactive_render_fn(self.state, self.props, self.children, self.HTMLReactive)
    end

 -- Load state from Redis and merge into self.state
function FunctionalComponent:loadStateFromRedis()
    if not (self.server 
        and self.server.dawn_sockets_handler 
        and self.server.dawn_sockets_handler.state_management 
        and self.server.dawn_sockets_handler.state_management.redis) then
        return
    end

    local redis = self.server.dawn_sockets_handler.state_management.redis
    local key = "component_state:" .. (self.component_key or "")
    local ok, val = pcall(function() return redis:get(key) end)

    if ok and val then
        local decoded, _, err = cjson.decode(val)
        if not err and type(decoded) == "table" then
            for k, v in pairs(decoded) do
                self.state[k] = v
            end
        else
            self.server.logger:log(log_level.WARN, "[FunctionalComponent] Redis decode error: " .. tostring(err), "FunctionalComponent", self.component_key)
        end
    else
        self.server.logger:log(log_level.INFO, "[FunctionalComponent] No existing state in Redis for key: " .. key, "FunctionalComponent", self.component_key)
    end
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

        -- 🔄 Redis state load (if available)
        if self.server and self.server.dawn_sockets_handler.state_management and self.server.dawn_sockets_handler.state_management.redis and self.component_key then
            local redis = self.server.dawn_sockets_handler.state_management.redis
            local key = "component_state:" .. self.component_key
            local ok, val = pcall(function() return redis:get(key) end)
            if ok and val then
                local decoded, _, err = cjson.decode(val)
                if not err and type(decoded) == "table" then
                    self.state = decoded
                end
            end
        end

        if self.view_mode == "lustache" then
            callback(self.children, self.props, self.style)

        elseif self.view_mode == "html_reactive" then
    local initial_vdom_builder = callback(
        self.server,
        self.children,
        self.props,
        self.style,
        self.HTMLReactive,
        self.collected_js_scripts
    )

    assert(
        type(initial_vdom_builder) == "function",
        "HTMLReactive init callback must return a VDOM builder function."
    )

    -- Store the render function
    self.reactive_render_fn = initial_vdom_builder

    -- ✅ Create the LuaHTMLReactive component instance here
    self.reactive_component = self.HTMLReactive.createComponent(initial_vdom_builder, self.state)

    -- Render initial root node
    self.reactive_root_node = self:render()

    -- Add this to your component initialization
self.utils = {
    -- Generic array push (works with any item type)
    arrayPush = function(arr, item)
        if not item then return arr or {} end
        if not arr then return {item} end
        local newArr = {table.unpack(arr)} -- Fast copy
        table.insert(newArr, item)
        return newArr
    end,
    
    -- Generic array update (key-agnostic)
    arrayUpdate = function(arr, predicate, updater)
        if not arr then return {} end
        local newArr, changed = {}, false
        for _, item in ipairs(arr) do
            if item and predicate(item) then
                newArr[#newArr+1] = updater(item)
                changed = true
            else
                newArr[#newArr+1] = item
            end
        end
        return changed and newArr or arr
    end,
    
    -- Generic array filter (remove items)
    arrayRemove = function(arr, predicate)
        if not arr then return {} end
        local newArr, removed = {}, false
        for _, item in ipairs(arr) do
            if item and not predicate(item) then
                newArr[#newArr+1] = item
            else
                removed = true
            end
        end
        return removed and newArr or arr
    end,
    
    -- Generic array dedupe
    arrayDedupe = function(arr, keyFn)
        if not arr then return {} end
        local seen, newArr = {}, {}
        keyFn = keyFn or function(item) return item.id end -- Default key
        
        for _, item in ipairs(arr) do
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
    
    -- Generic array mapper
    arrayMap = function(arr, mapper)
        if not arr then return {} end
        local newArr = table.create(#arr)
        for i, item in ipairs(arr) do
            newArr[i] = item and mapper(item, i) or nil
        end
        return newArr
    end
}


if not self.setState then
        self.setState = function(self_instance, newState, opts)
            assert(type(newState) == "table", "setState expects a table")

              -- Merge new values into self.state
                for k, v in pairs(newState) do
                    self.state[k] = v
                end

            -- Update state and get optimal patches from LuaHTMLReactive
            local patches = self_instance.reactive_component.setState(newState)

            -- Tag patches with component namespace for server-side filtering
            if self_instance.component_key then
                for _, patch in ipairs(patches) do
                    patch.component = self_instance.server:get_patch_namespace(
                        self_instance.component_key,
                        patch.varName or patch.path
                    )
                end
            end


-- ✅ NEW: bubble patches to parent’s patch queue if child
if #patches > 0 then

  

    if self_instance.parent then
        -- Forward child patches to parent’s patch queue
        self_instance.parent.server.patch_queue:push(patches)
    else
        -- Otherwise normal behavior
        self_instance.server.patch_queue:push(patches)
    end
end

            -- Persist full state in Redis if enabled
            if self_instance.server
                and self_instance.server.dawn_sockets_handler
                and self_instance.server.dawn_sockets_handler.state_management.redis
                and self_instance.component_key
            then
                local redis = self_instance.server.dawn_sockets_handler.state_management.redis
                local key = "component_state:" .. self_instance.component_key
                local ok, err = pcall(function()
                    -- print("Persisting state to Redis for component: " .. self_instance.component_key, cjson.encode(self_instance.state))
                    redis:set(key, cjson.encode(self.state))
                    redis:expire(key, 86400) -- 24 hours
                end)
                if not ok then
                    self_instance.server.logger:log(log_level.WARN, "[FunctionalComponent] ⚠️ Redis SET failed: " .. tostring(err), "FunctionalComponent", self_instance.component_key)
                end
            end

            return patches
        end
    end

    -- Unified patch dispatcher for client actions
    if not self.patch and type(self.methods) == "table" then
        self.patch = function(self_instance, ws_id, method, args)
            local fn = self_instance.methods[method]
            if type(fn) == "function" then
                return fn(self_instance, ws_id, args)
            else
                self_instance.server.logger:log(log_level.WARN, "[FunctionalComponent] ⚠️ Method '" .. tostring(method) .. "' not found.", "FunctionalComponent", self_instance.component_key)
                return {}
            end
        end
    end
        else
            callback(self.children, self.props, self.style, self.htmlBuilder)
            assert(#self.children > 0, "HTMLBuilder mode requires 'children' to be populated.")
        end
    end

    -- Assuming 'new_component' is an instance of your component (e.g., CounterComponent)
-- and it has access to 'self.server.state_management.PatchQueue'

function new_component:broadcast_patches(patches_table) -- Renamed argument for clarity
    if not patches_table then
        -- You might want to log a warning here
        return
    end

    -- Loop through each individual patch in the table
    for _, patch_data in ipairs(patches_table) do
        -- Ensure the patch has an ID if it's missing (though process_client_action already does this)
        patch_data.id = patch_data.id or uuid.v4()

        -- Crucial: Ensure the 'component' field is set for filtering
        -- This depends on how your component gets its `comp_key` and if it has a `varName` or `path`
        -- You'll need to pass `comp_key` from the component's context.
        -- Let's assume the component instance knows its `comp_key`.
        -- If not, you might need to pass it as an argument or retrieve it.
        local component_key_for_patch = self.component_key -- Example: component knows its key
        if not component_key_for_patch then
            -- Fallback or error if component doesn't know its own key
            component_key_for_patch = "default_component_instance" -- Placeholder
            self.server.logger:log(3, "Component broadcasting patches without knowing its registered key. Using default.", "FunctionalComponent", 200)
        end

        -- Ensure self.server.state_management provides get_patch_namespace
        patch_data.component = self.server:get_patch_namespace(
            component_key_for_patch,
            patch_data.varName or patch_data.path
        )

        -- PUSH EACH INDIVIDUAL PATCH
    end

    self.server.patch_queue:push(patches_table)
    -- After broadcasting, you'd typically want to persist the component's state
    -- This logic might already be handled by the code that calls broadcast_patches,
    -- but if not, ensure it happens here or immediately after.
    if self.state and self.server.dawn_sockets_handler.state_management.persist_state then
        self.server.dawn_sockets_handler.state_management:persist_state(
            "component_state:" .. self.component_key,
            self.state,
            3600
        )
    end
end

    function new_component:build()
        if self.view_mode == "lustache" then
            self.props.children = self.children
            local html = self.viewEngine:render(self.viewname, self.props or {})
            return css_helper.render_with_styles(html, false, self.scope_id)

        elseif self.view_mode == "html_reactive" then
    local vdom = self.reactive_root_node

    -- Replace child placeholders with real renders
    -- Replace child placeholders with real renders
local function replace_components(node)
    if type(node) ~= "table" then return node end
    if node._component and self.children[node.component_key] then
        local child = self.children[node.component_key]
        
        -- 🔥 Merge props from parent VDOM placeholder into child.props
        child.props = child.props or {}
        for k, v in pairs(node.props or {}) do
            child.props[k] = v
        end
        
        -- Pass parent state reference if not already set
        if not child.parentState and self.state then
            child.parentState = self.state
        end
        
        -- Pass parent methods reference if not already set
        if not child.parentMethods and self.methods then
            child.parentMethods = self.methods
        end
        
        -- Pass parent component key for identification
        child.props.parentComponentKey = self.component_key
        
        return child:build()
    end

    if node.children then
        local newChildren = {}
        for i, c in ipairs(node.children) do
            newChildren[i] = replace_components(c)
        end
        node.children = newChildren
    end
    return node
end

    return replace_components(vdom),
           { self.collected_css },
           self.collected_js_scripts

        else
            local html_parts = {}
            for _, node in ipairs(self.children) do
                table.insert(html_parts, self.htmlBuilder.render(node))
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
        if opts.state then
            table.insert(scripts, string.format("<script>window.__INITIAL_STATE__ = %s;</script>", cjson.encode(opts.state)))
            table.insert(scripts,"<script>window.__reactiveComponentInstance__ = {state: {__shared: window.__INITIAL_STATE__ || {},__client: {}}};</script>")
        end
        if opts.filters then
            table.insert(scripts, string.format("<script>window.__PATCH_FILTERS__ = %s;</script>", cjson.encode(opts.filters)))
        end
    
        if opts.include_patch_client ~= false then
            table.insert(scripts, '<script src="/static/assets/js/patchClient.js" type="module"></script>')
        end
        for _, js in ipairs(self.collected_js_scripts or {}) do
            table.insert(scripts, "<script>" .. js .. "</script>")
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
            warn("Reload() not supported for this view mode.")
        end
    end

function new_component:addChildComponent(key, component)
    assert(type(key) == "string", "Child component key must be a string")
    assert(component and component.view_mode, "Child must be an initialized FuncComponent")

    self.children[key] = component
    component.parent = self
    
    -- Pass parent's server instance to child
    if self.server and not component.server then
        component:setServer(self.server)
    end
    
    -- Pass parent's state reference to child
    component.parentState = self.state
    component.parentMethods = self.methods
    
    -- Pass component key for proper identification
    component.props.parentComponentKey = self.component_key
    
    -- 🔥 AUTO-REGISTER CHILD METHODS ON PARENT
    self:registerChildMethods(key, component)
    
    return self
end

-- New method to automatically register child methods on parent
function new_component:registerChildMethods(childKey, childComponent)

    childComponent:setComponentKey(childKey)

    if not childComponent.methods then return end
    
    -- Initialize parent methods table if not exists
    self.methods = self.methods or {}
    
    for methodName, methodFn in pairs(childComponent.methods) do
        -- Create namespaced method name: childKey_methodName
        local namespacedMethodName = childKey .. "_" .. methodName
        
        -- Only register if not already exists
        if not self.methods[namespacedMethodName] then
            self.methods[namespacedMethodName] = function(parent, ws_id, ...)
                -- Forward the call to the child component
                if childComponent.methods and childComponent.methods[methodName] then
                    return childComponent.methods[methodName](childComponent, ws_id, ...)
                end
            end
            
            self.server.logger:log(log_level.INFO, 
                "[FunctionalComponent] ✅ Registered child method: " .. namespacedMethodName,
                "FunctionalComponent", self.component_key)
        end
    end
end

-- New method to call child methods directly from parent
function new_component:callChildMethod(childKey, methodName, ...)
    local child = self.children[childKey]
    if not child then
        self.server.logger:log(log_level.WARN,
            "[FunctionalComponent] ⚠️ Child not found: " .. childKey,
            "FunctionalComponent", self.component_key)
        return nil
    end
    
    if child.methods and child.methods[methodName] then
        return child.methods[methodName](child, ...)
    else
        self.server.logger:log(log_level.WARN,
            "[FunctionalComponent] ⚠️ Method not found in child: " .. methodName,
            "FunctionalComponent", self.component_key)
        return nil
    end
end

-- New method to get a child component by key
function new_component:getChildComponent(childKey)
    return self.children[childKey]
end

function new_component:getParentState()
    if self.parent and self.parent.state then
        return self.parent.state
    elseif self.parentState then
        return self.parentState
    end
    return {}
end

function new_component:updateParentState(newState)
    if self.parent and self.parent.setState then
        return self.parent:setState(newState)
    end
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

-- get current component key
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

    -- rebuild virtual DOM from current state
    local new_root = self:render()

    -- diff with old root and get patches
    local patches = self.HTMLReactive.diff(self.reactive_root_node, new_root)

    -- update root node reference
    self.reactive_root_node = new_root

    -- attach component namespace to patches
    if self.component_key then
        for _, patch in ipairs(patches) do
            patch.component = self.server:get_patch_namespace(
                self.component_key,
                patch.varName or patch.path
            )
        end
    end

    -- queue patches so connected clients rerender
    if #patches > 0 then
        self.server.patch_queue:push(patches)
    end

    return patches
end

    return new_component
end

return FunctionalComponent
