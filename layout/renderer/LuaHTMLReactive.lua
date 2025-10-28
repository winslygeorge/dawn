-- HTMLReactive.lua
-- ✅ Reactive HTML Builder with SSR, Patch, Forms, Layouts, Slots, Widgets, and Validation

---@diagnostic disable: lowercase-global

local HTML = {}

local cjson = require("dkjson")

table.unpack = table.unpack or unpack -- Lua 5.1 / LuaJIT fallback

local layout_registry = {}
local schema_registry = {}

---@class VDOMNode
---@field tag string? The HTML tag name (e.g., "div", "span", "h1"). Nil for fragments.
---@field attrs table? A table of key-value pairs representing HTML attributes.
---@field children VDOMNode[]? A list of child VDOM nodes.
---@field content string? The text content of the element. Mutually exclusive with `children`.

---@class HandlerObject
---@field _handler true Marks this table as a server-side handler.
---@field fn string The name of the server-side function to call.
---@field args any[] Arguments to be passed to the server-side function.

---@class ClientOperation
---@field _op string The type of client-side operation (e.g., "setText", "addClass").
---@field selector string? CSS selector for DOM operations.
---@field value any? Value for set operations.
---@field className string? Class name for class operations.
---@field name string? Function name for declareFunction.
---@field params string[]? Parameters for declareFunction.
---@field body any? Body for declareFunction (string or ClientOperation[]).
---@field ms number? Milliseconds for timer operations.
---@field callback ClientOperation|ClientOperation[]? Callback operation for timers.
---@field id string? Unique ID for timers/websockets.
---@field url string? URL for fetch/websocket operations.
---@field options table? Fetch options (method, headers, body).
---@field responseType string? Expected response type for fetch ("text", "json", "blob").
---@field onSuccess ClientOperation|ClientOperation[]? Callback on successful fetch.
---@field onError ClientOperation|ClientOperation[]? Callback on fetch error.
---@field key string? Key for storage operations.
---@field text string? Text for clipboard/notification.
---@field title string? Title for notification.
---@field module string? Module name for ES module ops.
---@field fn string? Function name within a module.
---@field args any[]? Arguments for module function.
---@field onResult ClientOperation|ClientOperation[]? Callback on module function result.
---@field condition any? Condition for control flow (boolean or complex condition table).
---@field _complexCondition boolean? True if the condition is a complex evaluation for client.
---@field ['then'] ClientOperation|ClientOperation[]? Operations if condition is true.
---@field ['else'] ClientOperation|ClientOperation[]? Operations if condition is false.
---@field body ClientOperation|ClientOperation[]? Body of a loop.
---@field _ops ClientOperation[]? A list of operations for batching.
---@field object table? Object for object patching.
---@field items table? Items for list patching.
---@field template string? Template ID for list/object patching.
---@field classes string? Classes for list patching.
---@field staggerDelay number? Stagger delay for list patching.

---@class PatchObject
---@field type string The type of patch ("attr", "remove-attr", "text", "replace", "remove", "update-var", "list", "object", "nested").
---@field path string? VDOM path to the target node.
---@field selector string? CSS selector generated from the path.
---@field key string? Attribute key for "attr" and "remove-attr" types.
---@field value any? New attribute value or variable value.
---@field content string? New text content for "text" type.
---@field new VDOMNode? New VDOM node for "replace" type.
---@field varName string? The name of the reactive variable being updated.
---@field items table? List of items for "list" patch.
---@field template string? Template ID for "list" or "object" patch.
---@field classes string? CSS classes for "list" patch.
---@field staggerDelay number? Delay for staggered list updates.
---@field object table? Object data for "object" patch.

---@class SchemaField
---@field name string The name of the form field.
---@field label string? Display label for the field.
---@field type string? Input type (e.g., "text", "email", "date", "textarea", "select").
---@field required boolean? True if the field is mandatory.
---@field pattern string? Regular expression pattern for validation.
---@field placeholder string? Placeholder text for input.
---@field bind string? (Deprecated for data-bind) State variable to bind to.
---@field options string[]? List of options for "select" type.

---@class Schema
---@field fields SchemaField[] A list of field definitions for the form.

---@class Component
---@field state table The current state of the component.
---@field lastNode VDOMNode? The last VDOM node rendered by this component.
---@field patches PatchObject[] Patches generated from state changes.
---@field props table Properties passed to the component.
---@field reactiveBindings table<string, boolean> A map of state keys that are reactively bound to DOM elements.
---@field setState fun(self: Component, partial: table): PatchObject[] Updates the component's state and generates UI patches.
---@field render fun(self: Component, props: table?): VDOMNode Renders the component's VDOM.
---@field patch fun(self: Component, method: string, args: any[]): any Calls a component-defined method.
---@field methods table<string, fun(self: Component, ...): any> A table to define component-specific methods.

--------------------------------------------------
-- 🔁 JSX-Like Element Generator
--------------------------------------------------
--- Creates a Virtual DOM (VDOM) node. This is the fundamental building block for all UI.
--- @param tag string The HTML tag name (e.g., "div", "span", "h1").
--- @param attrs table? A table of key-value pairs representing HTML attributes.
--- @param children string|number|VDOMNode|VDOMNode[]? The content of the element.
--- @return VDOMNode A VDOM node table.
function HTML.e(tag, attrs, children)
 local node = { tag = tag, attrs = attrs or {} }
 if type(children) == "string" or type(children) == "number" then
  node.content = tostring(children)
 elseif type(children) == "table" then
  -- Ensure children is always a flat list of nodes, not a nested fragment
  if children.tag == nil and children.children then -- It's an HTML.fragment
      node.children = children.children
  else
      node.children = children
  end
 end
 return node
end

--- Creates a VDOM fragment, a special node with no tag.
--- It's used to group multiple child nodes without adding an extra wrapper element.
--- @param children VDOMNode|VDOMNode[] A list of VDOM nodes to include in the fragment.
--- @return VDOMNode A fragment VDOM node table.
function HTML.fragment(children)
 -- Ensure children is always a table for fragments
 if type(children) ~= "table" then
     children = { children } -- Wrap single child in a table
 end
 return { tag = nil, children = children }
end

--------------------------------------------------
-- New: Reactive Text Binding Helper
--------------------------------------------------
--- Wraps content in a span with data-bind attribute for client-side updates.
--- @param varName string The name of the state variable this element is bound to.
--- @param content string|number The current value of the variable.
--- @param attrs table? Optional attributes for the span element.
--- @return VDOMNode
function HTML.bindText(varName, content, attrs)
 attrs = attrs or {}
 attrs["data-bind"] = varName -- Identifier for client-side querying
 -- Optional: Add a class for easier selection or styling
 attrs.class = (attrs.class and attrs.class .. " " or "") .. "reactive-var-" .. varName
 return HTML.e("span", attrs, content)
end


--------------------------------------------------
-- 🔄 Diff Engine
--------------------------------------------------
--- Converts a VDOM path to a CSS selector for client-side querying.
--- @param path string The VDOM path (e.g., "root.children[1].children[2]").
--- @return string The CSS selector (e.g., ":scope > *:nth-child(1) > *:nth-child(2)").
local function path_to_selector(path)
  -- Convert VDOM path to CSS selector for client
  -- Example: root.children[1].children[2] → :scope > *:nth-child(1) > *:nth-child(2)
  local selector = path:gsub("^root", ":scope")
  selector = selector:gsub("%.children%[", " > *:nth-child("):gsub("%]", ")")
  return selector
end

--- Compares two VDOM trees and generates a list of "patch" objects.
--- These patches describe the minimal changes needed to transform the `old` VDOM into the `new` VDOM.
--- @param old VDOMNode? The previous VDOM tree.
--- @param new VDOMNode? The new VDOM tree.
--- @param path string? Internal parameter used to track the path of the current node in the tree. Defaults to "root".
--- @return PatchObject[] A table of patch objects.
function HTML.diff(old, new, path)
  path = path or "root"
  local selector = path_to_selector(path)
  local patches = {}

  if not old and new then
    return { { type = "replace", path = path, selector = selector, new = new } }
  elseif not new then
    return { { type = "remove", path = path, selector = selector } }
  elseif old.tag ~= new.tag then
    return { { type = "replace", path = path, selector = selector, new = new } }
  end

  local old_attrs = old.attrs or {}
  local new_attrs = new.attrs or {}

  for k, v in pairs(new_attrs) do
    if old_attrs[k] ~= v then
      table.insert(patches, { type = "attr", path = path, selector = selector, key = k, value = v })
    end
  end

  for k in pairs(old_attrs) do
    if new_attrs[k] == nil then
      table.insert(patches, { type = "remove-attr", path = path, selector = selector, key = k })
    end
  end

  if old.content ~= new.content then
    table.insert(patches, { type = "text", path = path, selector = selector, content = new.content })
  end

  local oc, nc = old.children or {}, new.children or {}
  for i = 1, math.max(#oc, #nc) do
    local childPatches = HTML.diff(oc[i], nc[i], path .. ".children[" .. i .. "]")
    for _, p in ipairs(childPatches) do
      table.insert(patches, p)
    end
  end

  return patches
end


--------------------------------------------------
-- 🎯 Structured Event Handler Builder
--------------------------------------------------
--- Creates a structured object that represents a server-side event handler.
--- This is the mechanism for an action on the client (e.g., a button click) to trigger a function call on the server.
--- @param fnName string The name of the server-side function to call.
--- @vararg any Arguments to be passed to the server-side function.
--- @return HandlerObject A special Lua table with an `_handler` field set to `true`.
function HTML.handler(fnName, ...)
    return {
        _handler = true,
        fn = fnName,
        args = { ... }
    }
end

--------------------------------------------------
-- 💻 Client-side Operation DSL
--------------------------------------------------
---@class HTML.client
HTML.client = {

    --------------------------------------------------
    -- 📜 JavaScript Function Declaration
    --------------------------------------------------
    --- Declares a JavaScript function on the client.
    --- @param name string The name of the function.
    --- @param params string[] A list of parameter names.
    --- @param bodyOps string|ClientOperation|ClientOperation[] The body of the function. Can be raw JS string or client operations.
    --- @return ClientOperation
    jsFunction = function(name, params, bodyOps)
        return { _op = "declareFunction", name = name, params = params, body = bodyOps }
    end,

    --------------------------------------------------
    -- 📄 DOM Operations
    --------------------------------------------------
    --- Adds a CSS class to elements matching the selector.
    --- @param sel string CSS selector.
    --- @param cls string Class name to add.
    --- @return ClientOperation
    addClass    = function(sel, cls) return { _op = "addClass", selector = sel, className = cls } end,
    --- Gets the text content of the first element matching the selector.
    --- @param sel string CSS selector.
    --- @return ClientOperation
    getText     = function(sel) return { _op = "getText", selector = sel } end,
    --- Gets the value of the first input element matching the selector.
    --- @param sel string CSS selector.
    --- @return ClientOperation
    getValue    = function(sel) return { _op = "getValue", selector = sel } end,
    -- get the elements attribute value
    --- @param sel string CSS selector.
    --- @param attr string The attribute name to get.
    --- @return ClientOperation
    getAttr     = function(sel, attr) return { _op = "getAttr", selector = sel, attr = attr } end,
    --- Hides elements matching the selector by setting `display: none`.
    --- @param sel string CSS selector.
    --- @return ClientOperation
    hide        = function(sel) return { _op = "hide", selector = sel } end,
    --- Queries the DOM for elements matching the selector (internal use mostly).
    --- @param sel string CSS selector.
    --- @return ClientOperation
    query       = function(sel) return { _op = "query", selector = sel } end,
    --- Removes a CSS class from elements matching the selector.
    --- @param sel string CSS selector.
    --- @param cls string Class name to remove.
    --- @return ClientOperation
    removeClass = function(sel, cls) return { _op = "removeClass", selector = sel, className = cls } end,
    --- Sets attributes on elements matching the selector.
    --- @param sel string CSS selector.
    --- @param attrs table A table of attributes to set.
    --- @return ClientOperation
    setAttrs    = function(sel, attrs) return { _op = "setAttrs", selector = sel, attrs = attrs } end,
    --- Sets the text content of elements matching the selector.
    --- @param sel string CSS selector.
    --- @param val string The new text content.
    --- @return ClientOperation
    setText     = function(sel, val) return { _op = "setText", selector = sel, value = val } end,
    --- Sets the value of input elements matching the selector.
    --- @param sel string CSS selector.
    --- @param val string The new value.
    --- @return ClientOperation
    setValue    = function(sel, val) return { _op = "setValue", selector = sel, value = val } end,
    --- Shows elements matching the selector by removing `display: none`.
    --- @param sel string CSS selector.
    --- @return ClientOperation
    show        = function(sel) return { _op = "show", selector = sel } end,

    --------------------------------------------------
    -- ⏱ Timers & Animation Frames
    --------------------------------------------------
    --- Cancels a previously scheduled animation frame request.
    --- @param id number The request ID returned by `requestAnimationFrame`.
    --- @return ClientOperation
    cancelAnimationFrame = function(id) return { _op = "cancelAnimationFrame", id = id } end,
    --- Clears a previously set interval.
    --- @param id number The interval ID returned by `setInterval`.
    --- @return ClientOperation
    clearInterval        = function(id) return { _op = "clearInterval", id = id } end,
    --- Schedules a function to run before the next repaint.
    --- @param cb ClientOperation|ClientOperation[] The callback operation(s).
    --- @param id string? A unique ID to reference this animation frame.
    --- @return ClientOperation
    requestAnimationFrame= function(cb, id) return { _op = "requestAnimationFrame", callback = cb, id = id } end,
    --- Executes a callback repeatedly with a fixed time delay between each call.
    --- @param ms number The delay in milliseconds.
    --- @param cb ClientOperation|ClientOperation[] The callback operation(s).
    --- @param id string? A unique ID to reference this interval.
    --- @return ClientOperation
    setInterval          = function(ms, cb, id) return { _op = "setInterval", ms = ms, callback = cb, id = id } end,
    --- Executes a callback function after a specified delay (one time).
    --- @param ms number The delay in milliseconds.
    --- @param cb ClientOperation|ClientOperation[] The callback operation(s).
    --- @return ClientOperation
    setTimeout           = function(ms, cb) return { _op = "setTimeout", ms = ms, callback = cb } end,

    --------------------------------------------------
    -- 🌐 WebSocket Operations
    --------------------------------------------------
    --- Closes a WebSocket connection.
    --- @param id string The ID of the WebSocket connection.
    --- @return ClientOperation
    wsClose   = function(id) return { _op = "wsClose", id = id } end,
    --- Connects to a WebSocket server.
    --- @param id string A unique ID for this WebSocket connection.
    --- @param url string The WebSocket URL.
    --- @param handlers table? A table with optional event handlers (`onMessage`, `onOpen`, `onClose`, `onError`).
    --- @return ClientOperation
    wsConnect = function(id, url, handlers)
        handlers = handlers or {}
        return {
            _op = "wsConnect",
            id = id,
            url = url,
            onMessage = handlers.onMessage,
            onOpen    = handlers.onOpen,
            onClose   = handlers.onClose,
            onError   = handlers.onError
        }
    end,
    --- Sends a message over a WebSocket connection.
    --- @param id string The ID of the WebSocket connection.
    --- @param message string The message to send.
    --- @return ClientOperation
    wsSend    = function(id, message) return { _op = "wsSend", id = id, message = message } end,

    --------------------------------------------------
    -- 📡 Fetch API
    --------------------------------------------------
    --- Performs a client-side network request using the Fetch API.
    --- @param url string The URL to fetch.
    --- @param options table? Fetch options (e.g., method, headers, body).
    --- @param responseType string? Expected response type ("text", "json", "blob").
    --- @param onSuccess ClientOperation|ClientOperation[]? Callback operation(s) on success.
    --- @param onError ClientOperation|ClientOperation[]? Callback operation(s) on error.
    --- @return ClientOperation
    fetch = function(url, options, responseType, onSuccess, onError)
        return {
            _op = "fetch",
            url = url,
            options = options,
            responseType = responseType,
            onSuccess = onSuccess,
            onError = onError
        }
    end,

    --------------------------------------------------
    -- 💾 Storage Operations
    --------------------------------------------------
    --- Gets an item from `localStorage`.
    --- @param key string The key of the item.
    --- @return ClientOperation
    localGet     = function(key) return { _op = "localGet", key = key } end,
    --- Removes an item from `localStorage`.
    --- @param key string The key of the item.
    --- @return ClientOperation
    localRemove  = function(key) return { _op = "localRemove", key = key } end,
    --- Sets an item in `localStorage`.
    --- @param key string The key of the item.
    --- @param value string The value to set.
    --- @return ClientOperation
    localSet     = function(key, value) return { _op = "localSet", key = key, value = value } end,
    --- Gets an item from `sessionStorage`.
    --- @param key string The key of the item.
    --- @return ClientOperation
    sessionGet   = function(key) return {_op = "sessionGet", key = key } end,
    --- Removes an item from `sessionStorage`.
    --- @param key string The key of the item.
    --- @return ClientOperation
    sessionRemove= function(key) return { _op = "sessionRemove", key = key } end,
    --- Sets an item in `sessionStorage`.
    --- @param key string The key of the item.
    --- @param value string The value to set.
    --- @return ClientOperation
    sessionSet   = function(key, value) return { _op = "sessionSet", key = key, value = value } end,

    ------------------------------------------------
    -- ADD helper functions for secure local storage
    -------------------------------------------------

    --------------------------------------------------
    -- 📋 Clipboard
    --------------------------------------------------
    --- Copies text to the clipboard.
    --- @param text string The text to copy.
    --- @return ClientOperation
    copyText = function(text) return { _op = "copyText", text = text } end,
    --- Reads text from the clipboard.
    --- @return ClientOperation
    readText = function() return { _op = "readText" } end,

    --------------------------------------------------
    -- 🔔 Notifications
    --------------------------------------------------
    --- Displays a desktop notification.
    --- @param title string The title of the notification.
    --- @param body string The body text of the notification.
    --- @return ClientOperation
    notify = function(title, body) return { _op = "notify", title = title, body = body } end,

    --------------------------------------------------
    -- 📦 ES Module Operations
    --------------------------------------------------
    --- Calls a function within an imported ES module.
    --- @param module string The name of the module (as defined in `importModule`).
    --- @param fn string The name of the function to call within the module.
    --- @param args any[]? Arguments to pass to the function.
    --- @param onResult ClientOperation|ClientOperation[]? Callback to execute with the function's result.
    --- @return ClientOperation
    callModuleFn = function(module, fn, args, onResult)
        return { _op = "callModuleFn", module = module, fn = fn, args = args, onResult = onResult }
    end,
    --- Imports an ES module on the client.
    --- @param name string The name to assign to the imported module for later reference.
    --- @param url string The URL of the ES module.
    --- @return ClientOperation
    importModule = function(name, url) return { _op = "importModule", name = name, url = url } end,

--------------------------------------------------
-- 🔄 Control Flow (with complex condition support)
--------------------------------------------------

--- Executes a block of operations at least once, and then repeatedly as long as a condition is true.
--- @param body_op ClientOperation|ClientOperation[] Operations to execute in the loop body.
--- @param condition any|table Condition (boolean, client op, or condition tree).
--- @return ClientOperation
do_while_loop = function (body_op, condition)
    return {
        _op = "do_while_loop",
        body = body_op,
        condition = condition,
        _complexCondition = type(condition) == "table" and (condition.operator or condition.conditions) ~= nil
    }
end,

--- Executes a loop until a condition becomes true.
--- @param body_op ClientOperation|ClientOperation[] Operations to execute in the loop body.
--- @param condition any|table Condition (boolean, client op, or condition tree).
--- @return ClientOperation
 loop_until = function (body_op, condition)
    return {
        _op = "loop_until",
        body = body_op,
        condition = condition,
        _complexCondition = type(condition) == "table" and (condition.operator or condition.conditions) ~= nil
    }
end,

--- Executes a block of operations repeatedly as long as a condition is true.
--- @param condition any|table Condition (boolean, client op, or condition tree).
--- @param body_op ClientOperation|ClientOperation[] Operations to execute in the loop body.
--- @return ClientOperation
while_loop = function (condition, body_op)
    return {
        _op = "while_loop",
        condition = condition,
        body = body_op,
        _complexCondition = type(condition) == "table" and (condition.operator or condition.conditions) ~= nil
    }
end,

--------------------------------------------------
-- 🔄 Control Flow (with DSL + complex condition support)
--------------------------------------------------

--- Executes a for loop with initializer, condition, and increment operations.
--- Supports both simple and complex condition trees.
--- @param init_op ClientOperation|ClientOperation[] Initialization operations (executed once).
--- @param condition any|table Condition (boolean, client op, or condition tree).
--- @param increment_op ClientOperation|ClientOperation[] Increment operations (executed each iteration).
--- @param body_op ClientOperation|ClientOperation[] Loop body operations.
--- @return ClientOperation
for_loop = function(init_op, condition, increment_op, body_op)
    return {
        _op = "for_loop",
        init = init_op,
        condition = condition,
        increment = increment_op,
        body = body_op,
        _complexCondition = type(condition) == "table" and (condition.operator or condition.conditions) ~= nil
    }
end,

--- Iterates over elements in a collection (array, list, or NodeList).
--- Each iteration sets the current item (and optional index) in the loop body context.
--- @param collection any|ClientOperation Collection to iterate (array, list, NodeList, etc.)
--- @param itemVar string Variable name to expose current item
--- @param indexVar string|nil Optional variable name for index
--- @param body_op ClientOperation|ClientOperation[] Loop body operations
--- @return ClientOperation
foreach_loop = function(collection, itemVar, indexVar, body_op)
    return {
        _op = "foreach_loop",
        collection = collection,
        itemVar = itemVar,
        indexVar = indexVar,
        body = body_op
    }
end,


    --- Executes operations conditionally based on a condition.
--- Executes operations conditionally based on a condition.
--- @param condition any|table A condition (boolean, client op, or condition tree).
--- @param then_op ClientOperation|ClientOperation[] Operations to execute if true.
--- @param else_op ClientOperation|ClientOperation[]? Operations to execute if false.
 if_ = function (condition, then_op, else_op)
    if type(condition) == "table" and (condition.operator or condition.conditions) then
        -- Complex condition: can be nested tree
        return {
            _op = "if_",
            _complexCondition = true,
            condition = condition,
            ['then'] = then_op,
            ['else'] = else_op
        }
    else
        return {
            _op = "if_",
            condition = condition,
            ['then'] = then_op,
            ['else'] = else_op
        }
    end
end,



    --------------------------------------------------
    -- ✂ String Operations
    --------------------------------------------------
    --- Trims whitespace from a string-like operation result.
    --- @param op ClientOperation The operation whose result should be trimmed.
    --- @return ClientOperation
    trim = function(op)
        return { _op = "trim", op = op }
    end,

     --------------------------------------------------
    -- 🔄 Type Conversion
    --------------------------------------------------
    --- Converts a value to a specified type.
    --- @param op ClientOperation The operation whose result should be converted.
    --- @param targetType string The target type ("string", "number", "boolean", "json", "array").
    --- @return ClientOperation
    convert = function(op, targetType)
        return { _op = "convert", op = op, targetType = targetType }
    end,

    --------------------------------------------------
    -- 📝 Console Logging
    --------------------------------------------------
    --- Logs a message to the browser console.
    --- @param level string The console level ("log", "error", "warn", "info", "debug").
    --- @param message ClientOperation|string The message to log.
    --- @return ClientOperation
    console = function(level, message)
        return { _op = "console", level = level, message = message }
    end,


    --------------------------------------------------
    -- 📑 Batch Operations
    --------------------------------------------------
    --- Groups multiple client operations into a single command to be executed sequentially.
    --- @vararg ClientOperation Operations to batch.
    --- @return ClientOperation
    batch = function(...)
        return { _ops = { ... } }
    end,


        --------------------------------------------------
    -- 🧮 Math Operations
    --------------------------------------------------
    --- Performs mathematical operations on the client.
    --- @param fn string The math function to execute ("sum", "subtract", "multiply", "divide", "mod", "pow", "sqrt", "abs", "min", "max", "round", "floor", "ceil", "sin", "cos", "tan", "asin", "acos", "atan", "atan2", "log", "log10", "exp", "random", "pi", "e").
    --- @param ... any|ClientOperation Arguments for the math function.
    --- @return ClientOperation
    math = function(fn, ...)
        return { _op = "math", fn = fn, args = {...} }
    end,

    --- Returns the absolute value of a number.
    --- @param x number|ClientOperation The number.
    --- @return ClientOperation
    abs = function(x) return HTML.client.math("abs", x) end,

    --- Returns the smallest integer greater than or equal to a number.
    --- @param x number|ClientOperation The number.
    --- @return ClientOperation
    ceil = function(x) return HTML.client.math("ceil", x) end,

    --- Returns the cosine of a number (in radians).
    --- @param x number|ClientOperation The number in radians.
    --- @return ClientOperation
    cos = function(x) return HTML.client.math("cos", x) end,

    --- Divides numbers.
    --- @param ... number|ClientOperation Numbers to divide.
    --- @return ClientOperation
    divide = function(...) return HTML.client.math("divide", ...) end,

    --- Returns Euler's number (e).
    --- @return ClientOperation
    e = function() return HTML.client.math("e") end,

    --- Returns e raised to the power of a number.
    --- @param x number|ClientOperation The exponent.
    --- @return ClientOperation
    exp = function(x) return HTML.client.math("exp", x) end,

    --- Returns the largest integer less than or equal to a number.
    --- @param x number|ClientOperation The number.
    --- @return ClientOperation
    floor = function(x) return HTML.client.math("floor", x) end,

    --- Returns the natural logarithm (base e) of a number.
    --- @param x number|ClientOperation The number.
    --- @return ClientOperation
    log = function(x) return HTML.client.math("log", x) end,

    --- Returns the base 10 logarithm of a number.
    --- @param x number|ClientOperation The number.
    --- @return ClientOperation
    log10 = function(x) return HTML.client.math("log10", x) end,

    --- Returns the maximum value from a set of numbers.
    --- @param ... number|ClientOperation Numbers to compare.
    --- @return ClientOperation
    max = function(...) return HTML.client.math("max", ...) end,

    --- Returns the minimum value from a set of numbers.
    --- @param ... number|ClientOperation Numbers to compare.
    --- @return ClientOperation
    min = function(...) return HTML.client.math("min", ...) end,

    --- Returns the remainder of a division operation.
    --- @param a number|ClientOperation The dividend.
    --- @param b number|ClientOperation The divisor.
    --- @return ClientOperation
    mod = function(a, b) return HTML.client.math("mod", a, b) end,

    --- Multiplies numbers.
    --- @param ... number|ClientOperation Numbers to multiply.
    --- @return ClientOperation
    multiply = function(...) return HTML.client.math("multiply", ...) end,

    --- Returns the value of π (pi).
    --- @return ClientOperation
    pi = function() return HTML.client.math("pi") end,

    --- Returns the base to the exponent power.
    --- @param base number|ClientOperation The base number.
    --- @param exponent number|ClientOperation The exponent.
    --- @return ClientOperation
    pow = function(base, exponent) return HTML.client.math("pow", base, exponent) end,

    --- Returns a random number between 0 and 1, or within a specified range.
    --- @param min number|ClientOperation? The minimum value (inclusive).
    --- @param max number|ClientOperation? The maximum value (inclusive).
    --- @return ClientOperation
    random = function(min, max)
        if min and max then
            return HTML.client.math("random", min, max)
        else
            return HTML.client.math("random")
        end
    end,

    --- Returns the value of a number rounded to the nearest integer.
    --- @param x number|ClientOperation The number.
    --- @return ClientOperation
    round = function(x) return HTML.client.math("round", x) end,

    --- Returns the sine of a number (in radians).
    --- @param x number|ClientOperation The number in radians.
    --- @return ClientOperation
    sin = function(x) return HTML.client.math("sin", x) end,

    --- Returns the square root of a number.
    --- @param x number|ClientOperation The number.
    --- @return ClientOperation
    sqrt = function(x) return HTML.client.math("sqrt", x) end,

    --- Subtracts numbers.
    --- @param ... number|ClientOperation Numbers to subtract.
    --- @return ClientOperation
    subtract = function(...) return HTML.client.math("subtract", ...) end,

    --- Adds numbers.
    --- @param ... number|ClientOperation Numbers to add.
    --- @return ClientOperation
    sum = function(...) return HTML.client.math("sum", ...) end,

    --- Returns the tangent of a number (in radians).
    --- @param x number|ClientOperation The number in radians.
    --- @return ClientOperation
    tan = function(x) return HTML.client.math("tan", x) end,

    --- Returns the arcsine of a number (in radians).
    --- @param x number|ClientOperation The number.
    --- @return ClientOperation
    asin = function(x) return HTML.client.math("asin", x) end,

    --- Returns the arccosine of a number (in radians).
    --- @param x number|ClientOperation The number.
    --- @return ClientOperation
    acos = function(x) return HTML.client.math("acos", x) end,

    --- Returns the arctangent of a number (in radians).
    --- @param x number|ClientOperation The number.
    --- @return ClientOperation
    atan = function(x) return HTML.client.math("atan", x) end,

    --- Returns the arctangent of the quotient of its arguments.
    --- @param y number|ClientOperation The y coordinate.
    --- @param x number|ClientOperation The x coordinate.
    --- @return ClientOperation
    atan2 = function(y, x) return HTML.client.math("atan2", y, x) end

}

--------------------------------------------------
-- File Reader + Media + Streaming
--------------------------------------------------
------------------------------------------------

-- In your HTML.client module

-- Existing function with a new 'name' parameter
function HTML.client.readFileAsText(selector, name, onResult)
    return {
        _op = "readFileAsText",
        selector = selector,
        name = name, -- This is the key change
        onResult = onResult,
    }
end

-- Update the existing readFileAsDataURL function
function HTML.client.readFileAsDataURL(selector, name, onResult)
    return {
        _op = "readFileAsDataURL",
        selector = selector,
        name = name, -- This is the key change
        onResult = onResult,
    }
end

function HTML.client.readFileAsJSON(selector, onResult)
    return { _op = "readFileAsJSON", selector = selector, onResult = onResult }
end

function HTML.client.readFileAsAudio(selector, onResult, opts)
    return {
        _op = "readFileAsAudio",
        selector = selector,
        onResult = onResult,
        target = opts and opts.target or nil
    }
end

function HTML.client.readFileAsVideo(selector, onResult, opts)
    return {
        _op = "readFileAsVideo",
        selector = selector,
        onResult = onResult,
        target = opts and opts.target or nil
    }
end

function HTML.client.streamFile(selector, opts)
    return {
        _op = "streamFile",
        selector = selector,
        chunkSize = opts.chunkSize,
        onChunk = opts.onChunk,
        onComplete = opts.onComplete,
        targetProgress = opts.targetProgress,
        targetPreview = opts.targetPreview
    }
end

-- Add this to your HTML.client module in LuaHTMLReactive.lua
function HTML.client.storeVar(name, value)
    return {
        _op = "storeVar",
        name = name,
        value = value,
    }
end


-- 👇 Optional shorthand numeric/eq helpers (extra sugar)
function HTML.client.eq(a, b) return HTML.client.cmp(a, "==", b) end
function HTML.client.neq(a, b) return HTML.client.cmp(a, "!=", b) end
function HTML.client.gt(a, b) return HTML.client.cmp(a, ">", b) end
function HTML.client.gte(a, b) return HTML.client.cmp(a, ">=", b) end
function HTML.client.lt(a, b) return HTML.client.cmp(a, "<", b) end
function HTML.client.lte(a, b) return HTML.client.cmp(a, "<=", b) end

--------------------------------------------------
-- 🔑 Variable Storage
--------------------------------------------------

--- Sets a client variable (not DOM, just JS memory).
--- @param name string Variable name
--- @param value any|ClientOperation Value to store
function HTML.client.setVar(name, value)
    return { _op = "setVar", name = name, value = value }
end

--- Gets a previously set client variable.
--- @param name string Variable name
function HTML.client.getVar(name)
    return { _op = "getVar", name = name }
end


--------------------------------------------------
-- 🔄 Loop Control
--------------------------------------------------

--- Breaks out of the nearest loop.
function HTML.client.break_()
    return { _op = "break" }
end

--- Skips the rest of the current iteration and continues with the next.
function HTML.client.continue_()
    return { _op = "continue" }
end


--------------------------------------------------
-- 🔙 Function Return
--------------------------------------------------

--- Immediately exits from the current function / execution context with an optional value.
--- @param value any|ClientOperation|nil Return value
function HTML.client.return_(value)
    return { _op = "return", value = value }
end


--------------------------------------------------
-- 🔎 Condition Builder DSL
--------------------------------------------------
--- AND group: accepts a list of conditions
function HTML.client.and_(...)
    local conditions = { ... }
    return { operator = "&&", conditions = conditions }
end

--- OR group: accepts a list of conditions
function HTML.client.or_(...)
    local conditions = { ... }
    return { operator = "||", conditions = conditions }
end

--- NOT: unary negation
function HTML.client.not_(cond)
    return { operator = "!", value = cond }
end

--- Binary condition: left OP right
--- @param left any|ClientOperation
--- @param operator string One of "==","!=",">","<",">=","<=","===","!=="
--- @param right any|ClientOperation
function HTML.client.cmp(left, operator, right)
    return { left = left, operator = operator, right = right }
end

-- Client DSL DOM manipulation

-- Basic insertion / removal / replace
function HTML.client.append(sel, html) return { _op = "append", selector = sel, value = html } end
function HTML.client.prepend(sel, html) return { _op = "prepend", selector = sel, value = html } end
function HTML.client.remove(sel) return { _op = "remove", selector = sel } end
function HTML.client.replace(sel, html) return { _op = "replace", selector = sel, value = html } end
function HTML.client.replaceWith(sel, html) return { _op = "replaceWith", selector = sel, value = html } end
function HTML.client.clear(sel) return { _op = "clear", selector = sel } end

-- Insert relative
function HTML.client.insertBefore(sel, html) return { _op = "insertBefore", selector = sel, value = html } end
function HTML.client.insertAfter(sel, html) return { _op = "insertAfter", selector = sel, value = html } end

-- Wrap / unwrap
function HTML.client.wrap(sel, tag, attributes)
    return {
        _op = "wrap",
        selector = sel,
        tag = tag,
        attributes = attributes
    }
end


function HTML.client.wrapAll(sel, tag, attributes)
    return {
        _op = "wrapAll",
        selector = sel,
        tag = tag,
        attributes = attributes
    }
end


-- Replace children / clone / move / swap
function HTML.client.replaceChildren(sel, html) return { _op = "replaceChildren", selector = sel, value = html } end
function HTML.client.clone(sel, deep) return { _op = "clone", selector = sel, deep = deep or false } end
function HTML.client.move(sel, targetSel, position) return { _op = "move", selector = sel, target = targetSel, position = position or "beforeend" } end

-- Collection / ordering
function HTML.client.sort(sel, compare) return { _op = "sort", selector = sel, compare = compare or "text" } end
function HTML.client.reverse(sel) return { _op = "reverse", selector = sel } end
function HTML.client.shuffle(sel) return { _op = "shuffle", selector = sel } end

-- Array-style
function HTML.client.push(sel, html) return { _op = "push", selector = sel, value = html } end
function HTML.client.pop(sel) return { _op = "pop", selector = sel } end
function HTML.client.unshift(sel, html) return { _op = "unshift", selector = sel, value = html } end
function HTML.client.shift(sel) return { _op = "shift", selector = sel } end
function HTML.client.slice(sel, start, finish) return { _op = "slice", selector = sel, start = start or 0, finish = finish } end
function HTML.client.splice(sel, start, deleteCount, html) return { _op = "splice", selector = sel, start = start or 0, deleteCount = deleteCount or 0, value = html } end
function HTML.client.split(sel, size) return { _op = "split", selector = sel, size = size or 2 } end
function HTML.client.concat(selA, selB, targetSel) return { _op = "concat", a = selA, b = selB, target = targetSel } end
function HTML.client.swap(selA, selB) return { _op = "swap", a = selA, b = selB } end

-- Functional (map/filter/reduce) & helpers
function HTML.client.map(sel, transform) return { _op = "map", selector = sel, transform = transform } end
function HTML.client.filter(sel, condition) return { _op = "filter", selector = sel, condition = condition } end
function HTML.client.reduce(sel, accumulator) return { _op = "reduce", selector = sel, accumulator = accumulator } end

-- Grouping / grouping-like ops
function HTML.client.groupBy(sel, key) return { _op = "groupBy", selector = sel, key = key } end
function HTML.client.partition(sel, condition) return { _op = "partition", selector = sel, condition = condition } end
function HTML.client.flatten(sel) return { _op = "flatten", selector = sel } end
function HTML.client.nest(sel, wrapperTag, levels) return { _op = "nest", selector = sel, tag = wrapperTag or "div", levels = levels or 1 } end

-- Dedup / unique
function HTML.client.unique(sel, mode) return { _op = "unique", selector = sel, mode = mode or "text" } end
function HTML.client.deduplicate(sel, key) return { _op = "deduplicate", selector = sel, key = key } end

-- Pairing / merging / zipping / cartesian
function HTML.client.zip(selA, selB, targetSel) return { _op = "zip", a = selA, b = selB, target = targetSel } end
function HTML.client.zipWith(selA, selB, targetSel, template) return { _op = "zipWith", a = selA, b = selB, target = targetSel, template = template } end
function HTML.client.cartesian(selA, selB, targetSel, template) return { _op = "cartesian", a = selA, b = selB, target = targetSel, template = template } end
function HTML.client.cartesianN(selectors, targetSel, template) return { _op = "cartesianN", selectors = selectors, target = targetSel, template = template } end

-- Combinatorics: combinations / permutations / power sets / with replacement
function HTML.client.combinations(sel, k, targetSel, template) return { _op = "combinations", selector = sel, k = k, target = targetSel, template = template } end
function HTML.client.permutations(sel, k, targetSel, template) return { _op = "permutations", selector = sel, k = k, target = targetSel, template = template } end
function HTML.client.powerSet(sel, targetSel, key) return { _op = "powerSet", selector = sel, target = targetSel, key = key } end
function HTML.client.combinationsWithReplacement(sel, k, targetSel, template) return { _op = "combinationsWithReplacement", selector = sel, k = k, target = targetSel, template = template } end
function HTML.client.permutationsWithReplacement(sel, k, targetSel, template) return { _op = "permutationsWithReplacement", selector = sel, k = k, target = targetSel, template = template } end

-- Set algebra ops
function HTML.client.union(selA, selB, targetSel, key) return { _op = "union", a = selA, b = selB, target = targetSel, key = key } end
function HTML.client.intersect(selA, selB, targetSel, key) return { _op = "intersect", a = selA, b = selB, target = targetSel, key = key } end
function HTML.client.difference(selA, selB, targetSel, key) return { _op = "difference", a = selA, b = selB, target = targetSel, key = key } end
function HTML.client.relativeComplement(selA, selB, targetSel, key) return { _op = "relativeComplement", a = selA, b = selB, target = targetSel, key = key } end
function HTML.client.symmetricDifference(selA, selB, targetSel, key) return { _op = "symmetricDifference", a = selA, b = selB, target = targetSel, key = key } end

-- Boolean set relations
function HTML.client.isSubset(selA, selB, key) return { _op = "isSubset", a = selA, b = selB, key = key } end
function HTML.client.isSuperset(selA, selB, key) return { _op = "isSuperset", a = selA, b = selB, key = key } end
function HTML.client.isDisjoint(selA, selB, key) return { _op = "isDisjoint", a = selA, b = selB, key = key } end
function HTML.client.isEqual(selA, selB, key) return { _op = "isEqual", a = selA, b = selB, key = key } end

-- Quantifier
function HTML.client.cardinality(sel, key) return { _op = "cardinality", selector = sel, key = key } end



--------------------------------------------------
-- 🔄 Patch Helper
--------------------------------------------------
--- Sends a patch message to a component on the server-side.
--- Supports optional child component key for namespacing.
--- @param parentKey string The parent component key
--- @param componentKey string? Optional child component key
--- @param method string The actual method name defined in the component (e.g., "childUpdateUser")
--- @vararg any Arguments to pass to the component method
--- @return HandlerObject
function HTML.patch(parentKey, componentKey, method, ...)
  local actualMethod
  if componentKey and componentKey ~= "" then
    -- e.g. "profile_childUpdateUser"
    actualMethod = componentKey .. "_" .. method
  else
    -- e.g. just "childUpdateUser"
    actualMethod = method
  end

  return HTML.handler("sendPatch", parentKey, actualMethod, ...)
end

--- Declares a JavaScript function on the client.
--- This is a convenience alias for `HTML.client.jsFunction`.
--- @param name string The name of the function.
--- @param params string[] A list of parameter names.
--- @param bodyOps string|ClientOperation|ClientOperation[] The body of the function.
--- @return ClientOperation
function HTML.jsFunction(name, params, bodyOps)
    -- bodyOps can be string (raw JS body) or HTML.client ops (table)
    return {
        _op = "declareFunction",
        name = name,
        params = params,
        body = bodyOps
    }
end

--------------------------------------------------
-- 🎯 Convenience Event Shorthands
--------------------------------------------------
-- Automatically generated convenience functions for common events like `onClick`, `onKeydown`, etc.
-- Each function takes a `handler` (HandlerObject or ClientOperation) and returns an attributes table.
-- e.g., HTML.onClick(HTML.handler("myClickHandler")) is equivalent to HTML.on("click", HTML.handler("myClickHandler"))

---@alias HandlerSpec HandlerObject|ClientOperation|ClientOperation[]|string

--- Attaches an event handler to a VDOM node.
--- @param events string|string[]|table A single event name (e.g., "click"), a list of event names (e.g., {"mouseover", "mouseout"}), or a table mapping event names to handler specs.
--- @param handlerSpec HandlerSpec The handler function or client operation to be executed.
--- @return table A table of event attributes (e.g., `{ onclick = "..." }`).
function HTML.on(events, handlerSpec)
    local out = {}

    local function buildHandler(h)
        if type(h) == "table" and h._handler then
            local argsStr = {}
            for _, arg in ipairs(h.args) do
                if type(arg) == "string" then
                    table.insert(argsStr, string.format("'%s'", arg))
                elseif type(arg) == "table" then
                    -- Corrected: Encode to JSON and replace double quotes with single quotes.
                    local json_str = cjson.encode(arg)
                    local v1, v2 = json_str:gsub('"', "'")
                    table.insert(argsStr, v1)
                else
                    table.insert(argsStr, tostring(arg))
                end
            end
            return h.fn .. "(" .. table.concat(argsStr, ",") .. ")"
        elseif type(h) == "table" and (h._op or h._ops) then
            -- Corrected: Encode to JSON and replace double quotes with single quotes.
            local json_str = cjson.encode(h)
            return string.format("window.__clientOp__(%s)", json_str:gsub('"', "'"))
        else
            return tostring(h)
        end
    end

    if type(events) == "table" then
        if #events > 0 then
            for _, ev in ipairs(events) do
                out["on" .. ev] = buildHandler(handlerSpec)
            end
        else
            for ev, h in pairs(events) do
                out["on" .. ev] = buildHandler(h)
            end
        end
    else
        out["on" .. events] = buildHandler(handlerSpec)
    end

    return out
end

---@field onClick fun(handler: HandlerSpec): table
---@field onDblclick fun(handler: HandlerSpec): table
---@field onMousedown fun(handler: HandlerSpec): table
---@field onMouseup fun(handler: HandlerSpec): table
---@field onMousemove fun(handler: HandlerSpec): table
---@field onMouseenter fun(handler: HandlerSpec): table
---@field onMouseleave fun(handler: HandlerSpec): table
---@field onMouseover fun(handler: HandlerSpec): table
---@field onMouseout fun(handler: HandlerSpec): table
---@field onKeydown fun(handler: HandlerSpec): table
---@field onKeyup fun(handler: HandlerSpec): table
---@field onKeypress fun(handler: HandlerSpec): table
---@field onChange fun(handler: HandlerSpec): table
---@field onInput fun(handler: HandlerSpec): table
---@field onSubmit fun(handler: HandlerSpec): table
---@field onFocus fun(handler: HandlerSpec): table
---@field onBlur fun(handler: HandlerSpec): table
---@field onDrag fun(handler: HandlerSpec): table
---@field onDragstart fun(handler: HandlerSpec): table
---@field onDragover fun(handler: HandlerSpec): table
---@field onDragenter fun(handler: HandlerSpec): table
---@field onDragleave fun(handler: HandlerSpec): table
---@field onDrop fun(handler: HandlerSpec): table
---@field onTouchstart fun(handler: HandlerSpec): table
---@field onTouchmove fun(handler: HandlerSpec): table
---@field onTouchend fun(handler: HandlerSpec): table
---@field onTouchcancel fun(handler: HandlerSpec): table
---@field onContextmenu fun(handler: HandlerSpec): table
---@field onWheel fun(handler: HandlerSpec): table
---@field onScroll fun(handler: HandlerSpec): table
local commonEvents = {
    "Click", "Dblclick", "Mousedown", "Mouseup", "Mousemove",
    "Mouseenter", "Mouseleave", "Mouseover", "Mouseout",
    "Keydown", "Keyup", "Keypress",
    "Change", "Input", "Submit", "Focus", "Blur",
    "Drag", "Dragstart", "Dragover", "Dragenter", "Dragleave", "Drop",
    "Touchstart", "Touchmove", "Touchend", "Touchcancel",
    "Contextmenu", "Wheel", "Scroll"
}

for _, ev in ipairs(commonEvents) do
    local methodName = "on" .. ev
    HTML[methodName] = function(handler)
        return HTML.on(ev:lower(), handler)
    end
end


--------------------------------------------------
-- 📦 HTML Render
--------------------------------------------------
local selfClosingTags = {
    meta = true, link = true, br = true, hr = true,
    img = true, input = true, source = true, area = true,
    base = true, col = true, embed = true, param = true,
    track = true, wbr = true
}

--- Renders a VDOM tree into a static HTML string. Primarily used for Server-Side Rendering (SSR).
--- @param vdom VDOMNode The VDOM node or fragment to render.
--- @param opts table? A table of options.
--- @field opts.pretty boolean? If true, the output is formatted with indentation and newlines. Defaults to false.
--- @field opts.indent string? The string to use for indentation. Defaults to "  ".
--- @return string A string containing the HTML markup.
function HTML.render(vdom, opts)
    opts = opts or {}
    local pretty = opts.pretty or false
    local indentStr = opts.indent or "  "

    local function renderNode(node, depth)
        depth = depth or 0
        local pad = pretty and (indentStr):rep(depth) or ""

        if type(node) == "string" or type(node) == "number" then
            return pad .. node .. (pretty and "\n" or "")
        end

        if not node.tag then
            local content = ""
            if node.children then
                for _, child in ipairs(node.children) do
                    content = content .. renderNode(child, depth)
                end
            end
            return content
        end

        local tag = node.tag
        local attrs = node.attrs or {}
        local attrString = ""

        for k, v in pairs(attrs) do
            if v ~= false then
                if type(v) == "table" and v._handler then
                    local argsStr = {}
                    for _, arg in ipairs(v.args) do
                        if type(arg) == "string" then
                            table.insert(argsStr, string.format("%q", arg))
                        elseif type(arg) == "table" then
                            table.insert(argsStr, cjson.encode(arg))
                        else
                            table.insert(argsStr, tostring(arg))
                        end
                    end
                    attrString = attrString .. " " .. k .. "=\"" .. v.fn .. "(" .. table.concat(argsStr, ",") .. ")\""
                elseif type(v) == "table" and (v._op or v._ops) then
                    attrString = attrString .. " " .. k .. "=\'window.__clientOp__(" .. cjson.encode(v) .. ")\'"
                else
                    attrString = attrString .. " " .. k .. (v == true and "" or ("=\"" .. tostring(v) .. "\""))
                end
            end
        end

        if selfClosingTags[tag] and not node.children and not node.content then
            return pad .. "<" .. tag .. attrString .. ">" .. (pretty and "\n" or "")
        end

        local content = ""
        if node.content then
            content = node.content
        elseif node.children then
            for _, child in ipairs(node.children) do
                content = content .. renderNode(child, depth + 1)
            end
        end

        local open = pad .. "<" .. tag .. attrString .. ">"
        local close = "</" .. tag .. ">" .. (pretty and "\n" or "")

        if pretty and content:match("[^%s]") then
            return open .. "\n" .. content .. pad .. close
        else
            return open .. content .. close
        end
    end

    return renderNode(vdom)
end


-- In LuaHTMLReactive.lua, add these functions

--- Creates a component placeholder that will be replaced with the component's rendered content
--- @param component_key string The key of the component to embed
--- @param props table? Properties to pass to the component
--- @return VDOMNode
function HTML.Component(component_key, props)
    return {
        _component = true,
        component_key = component_key,
        props = props or {},
        -- This will be replaced during rendering with the actual component content
        tag = "div",
        attrs = {
            ["data-component"] = component_key,
            class = "embedded-component",
            ["data-parent-key"] = props and props.parentComponentKey or ""
        },
        children = { HTML.e("div", { class = "component-loading" }, "Loading...") }
    }
end

--------------------------------------------------
-- 🌐 Patch JS Output
--------------------------------------------------
--- Converts a single patch object into a JavaScript snippet that performs the described change on the client's DOM.
--- @param patch PatchObject A single patch object.
--- @return string A string of JavaScript code.
function HTML.generate_js_patch(patch)
 local path = patch.path or "root"
 local selector = patch.selector or path:gsub("%.children%[", " > *:nth-child("):gsub("%]", ")")
 if patch.type == "attr" then
  return string.format('document.querySelector("%s").setAttribute("%s", "%s");', selector, patch.key, patch.value)
 elseif patch.type == "remove-attr" then
  return string.format('document.querySelector("%s").removeAttribute("%s");', selector, patch.key)
 elseif patch.type == "text" then
  -- For text patches, we might want to skip if it's a reactive-var span,
  -- as update-var will handle it. This logic is better on client-side.
  return string.format('document.querySelector("%s").textContent = "%s";', selector, patch.content)
 elseif patch.type == "replace" then
  local html = HTML.render(patch.new):gsub('"', '\\"')
  return string.format('document.querySelector("%s").outerHTML = "%s";', selector, html)
 elseif patch.type == "remove" then
  return string.format('document.querySelector("%s").remove();', selector)
 elseif patch.type == "update-var" then
  -- New patch type for variable updates
  -- This will call a client-side function `__updateReactiveVar__`
  return string.format('window.__updateReactiveVar__("%s", %s);',
             patch.varName, cjson.encode(patch.value)) -- Encode value for safety
 end
end

--- Takes a list of patch objects and concatenates their JavaScript code into a single string.
--- @param patches PatchObject[] A list of patch objects.
--- @return string A string of concatenated JavaScript code.
function HTML.toJS(patches)
 local js = {}
 for _, p in ipairs(patches) do table.insert(js, HTML.generate_js_patch(p)) end
 return table.concat(js, "\n")
end

--------------------------------------------------
-- 🧠 Logic Rendering
--------------------------------------------------
--- Conditionally includes a VDOM node if the condition is true.
--- @param cond boolean The condition to check.
--- @param node VDOMNode|string|number The content to render if the condition is true.
--- @return VDOMNode? The VDOM node if `cond` is true, otherwise `nil`.
function HTML.if_(cond, node) return cond and node or nil end
--- Conditionally includes a VDOM node if the condition is false.
--- @param cond boolean The condition to check.
--- @param node VDOMNode|string|number The content to render if the condition is false.
--- @return VDOMNode? The VDOM node if `cond` is false, otherwise `nil`.
function HTML.if_not(cond, node) return not cond and node or nil end

--- Includes a VDOM node only if `val` is present in `list`.
--- @param val any The value to check for.
--- @param list table The list to search within.
--- @param node VDOMNode|string|number The content to render.
--- @return VDOMNode? The VDOM node if `val` is in `list`, otherwise `nil`.
function HTML.only(val, list, node)
 local set = {}; for _, v in ipairs(list) do set[v] = true end
 return set[val] and node or nil
end

--- Includes a VDOM node only if `val` is NOT present in `list`.
--- @param val any The value to check for.
--- @param list table The list to search within.
--- @param node VDOMNode|string|number The content to render.
--- @return VDOMNode? The VDOM node if `val` is not in `list`, otherwise `nil`.
function HTML.except(val, list, node)
 local set = {}; for _, v in ipairs(list) do set[v] = true end
 return not set[val] and node or nil
end

--- Iterates over a table `list` and applies a function `fn` to each element, returning a new list of the results.
--- @param list table? The list of items to iterate over.
--- @param fn fun(value: any, index: number): VDOMNode|string|number A function that takes an item and its index and returns a VDOM node or content.
--- @return VDOMNode[] A table containing the results of the function calls.
function HTML.map(list, fn)
 local out = {}
 for i, v in ipairs(list or {}) do
  local result = fn(v, i)
  if type(result) == "table" or type(result) == "string" or type(result) == "number" then table.insert(out, result) end
 end
 return out
end

--- Executes a function repeatedly starting from `start` until `stop` condition is met.
--- @param start number The starting index.
--- @param fn fun(index: number): VDOMNode|string|number A function to generate content for each iteration.
--- @param stop fun(index: number): boolean A function that returns true to stop the loop.
--- @return VDOMNode[] A table containing the generated content from each iteration.
function HTML.do_until(start, fn, stop)
 local out = {}; local i = start
 while not stop(i) do table.insert(out, fn(i)); i = i + 1 end
 return out
end

--- Adds Tailwind CSS classes to a VDOM node's attributes table.
--- It safely appends new classes to any existing `class` attribute.
--- @param attrs table? The existing attributes table.
--- @param classes string? A space-separated string of new CSS classes.
--- @return table A new attributes table with the updated `class` attribute.
function HTML.tailwindify(attrs, classes)
  attrs = attrs or {}
  attrs.class = ((attrs.class or "") .. " " .. (classes or "")):gsub("^%s+", ""):gsub("%s+$", "")
  return attrs
end




--- Merges two attribute tables, with attributes from `b` overriding those from `a`.
--- @param a table? First attributes table.
--- @param b table? Second attributes table.
--- @return table A new merged attributes table.
function HTML.merge(a, b)
  local out = {}
  for k, v in pairs(a or {}) do out[k] = v end
  for k, v in pairs(b or {}) do out[k] = v end
  return out
end


-- 📁 File Input Elements
--------------------------------------------------
--------------------------------------------------
--- Creates an image file input with preview capability.
--- @param name string The 'name' attribute for the input.
--- @param preview_id string? Custom ID for the preview element (default: name .. "_preview").
--- @param attrs table? Additional attributes for the input.
--- @return VDOMNode
function HTML.ImageInput(name, preview_id, attrs)
    local previewId = preview_id or name .. "_preview"
    
    return HTML.fragment({
        HTML.e("input", HTML.merge({
            type = "file",
            name = name,
            accept = "image/*",
            class = "px-3 py-2 border border-gray-300 rounded-md focus:outline-none focus:ring-2 focus:ring-blue-500 focus:border-transparent",
            ["data-bind"] = name,
            onchange = string.format(
                "window.__clientOp__(%s)",
                cjson.encode(
                    HTML.client.readFileAsDataURL(
                        "input[name=\"" .. name .. "\"]",
                        name, -- Pass the name as the second argument
                        HTML.client.batch(
                            HTML.client.setAttrs("#" .. previewId, { src = "__VALUE__" }),
                            HTML.client.removeClass("#" .. previewId, "hidden")
                        )
                    )
                ):gsub('"', "'")
            )
        }, attrs or {}))
    })
end

--------------------------------------------------
--- Creates a general file input with preview capability (images, PDFs, etc.).
--- @param name string The 'name' attribute for the input.
--- @param preview_id string? Custom ID for the preview element (default: name .. "_preview").
--- @param attrs table? Additional attributes for the input.
--- @return VDOMNode
function HTML.FileInput(name, preview_id, attrs)
    local previewId = preview_id or name .. "_preview"

    return HTML.fragment({
        HTML.e("input", HTML.merge({
            type = "file",
            name = name,
            class = "px-3 py-2 border border-gray-300 rounded-md focus:outline-none focus:ring-2 focus:ring-blue-500 focus:border-transparent",
            ["data-bind"] = name,
            onchange = string.format(
                "window.__clientOp__(%s)",
                cjson.encode(
                    HTML.client.readFileAsDataURL(
                        "input[name=\"" .. name .. "\"]",
                        name, -- Pass the name as the second argument
                        HTML.client.batch(
                            HTML.client.setAttrs("#" .. previewId, { src = "__VALUE__" }),
                            HTML.client.removeClass("#" .. previewId, "hidden")
                        )
                    )
                ):gsub('"', "'")
            )
        }, attrs or {}))
    })
end

--------------------------------------------------
--- Creates a drag-and-drop file input with preview capability.
--- @param name string The 'name' attribute for the input.
--- @param preview_id string? Custom ID for the preview element (default: name .. "_preview").
--- @param attrs table? Additional attributes for the input.
--- @return VDOMNode
function HTML.DragDropInput(name, preview_id, attrs)
    local previewId = preview_id or name .. "_preview"
    local inputId = name .. "_input"

    return HTML.fragment({
        -- Hidden file input
        HTML.e("input", HTML.merge({
            type = "file",
            id = inputId,
            name = name,
            class = "hidden",
            ["data-bind"] = name,
            onchange = string.format(
                "window.__clientOp__(%s)",
                cjson.encode(
                    HTML.client.readFileAsDataURL(
                        "#" .. inputId,
                        name, -- Pass the name as the second argument
                        HTML.client.batch(
                            HTML.client.setAttrs("#" .. previewId, { src = "__VALUE__" }),
                            HTML.client.removeClass("#" .. previewId, "hidden")
                        )
                    )
                ):gsub('"', "'")
            )
        }, attrs or {})),

        -- Drag & Drop Zone
        HTML.e("div", {
            class = "flex flex-col items-center justify-center w-full h-32 border-2 border-dashed border-gray-400 rounded-lg cursor-pointer hover:border-blue-500 transition",
            onclick = string.format("document.getElementById('%s').click()", inputId),
            ondragover = "event.preventDefault(); this.classList.add('border-blue-500')",
            ondragleave = "this.classList.remove('border-blue-500')",
            ondrop = string.format([[
                event.preventDefault();
                this.classList.remove('border-blue-500');
                const input = document.getElementById('%s');
                input.files = event.dataTransfer.files;
                input.dispatchEvent(new Event('change'));
            ]], inputId)
        }, {
            HTML.e("p", { class = "text-gray-600" }, "Drag & drop a file here, or click to select")
        })
    })
end

--------------------------------------------------
--- Creates an audio file input with preview capability.
--- @param name string The 'name' attribute for the input.
--- @param preview_id string? Custom ID for the preview element (default: name .. "_preview").
--- @param attrs table? Additional attributes for the input.
--- @return VDOMNode
function HTML.AudioInput(name, preview_id, attrs)
    local previewId = preview_id or name .. "_preview"
    
    return HTML.fragment({
        HTML.e("input", HTML.merge({
            type = "file",
            name = name,
            accept = "audio/*",
            class = "px-3 py-2 border border-gray-300 rounded-md focus:outline-none focus:ring-2 focus:ring-blue-500 focus:border-transparent",
            ["data-bind"] = name,
            onchange = string.format(
                "window.__clientOp__(%s)",
                cjson.encode(
                    HTML.client.readFileAsAudio(
                        "input[name=\"" .. name .. "\"]",
                        name, -- Pass the name as the second argument
                        { target = "#" .. previewId }
                    )
                ):gsub('"', "'")
            )
        }, attrs or {}))
    })
end

--------------------------------------------------
--- Creates a video file input with preview capability.
--- @param name string The 'name' attribute for the input.
--- @param preview_id string? Custom ID for the preview element (default: name .. "_preview").
--- @param attrs table? Additional attributes for the input.
--- @return VDOMNode
function HTML.VideoInput(name, preview_id, attrs)
    local previewId = preview_id or name .. "_preview"
    
    return HTML.fragment({
        HTML.e("input", HTML.merge({
            type = "file",
            name = name,
            accept = "video/*",
            class = "px-3 py-2 border border-gray-300 rounded-md focus:outline-none focus:ring-2 focus:ring-blue-500 focus:border-transparent",
            ["data-bind"] = name,
            onchange = string.format(
                "window.__clientOp__(%s)",
                cjson.encode(
                    HTML.client.readFileAsVideo(
                        "input[name=\"" .. name .. "\"]",
                        name, -- Pass the name as the second argument
                        { target = "#" .. previewId }
                    )
                ):gsub('"', "'")
            )
        }, attrs or {}))
    })
end

--------------------------------------------------
--- Creates a large file input with streaming capability and progress bar.
--- @param name string The 'name' attribute for the input.
--- @param accept string The accept attribute (e.g., "video/*", "audio/*").
--- @param ws_id string The WebSocket ID for streaming uploads.
--- @param preview_id string? Custom ID for the preview element.
--- @param progress_id string? Custom ID for the progress element.
--- @param chunk_size number? Chunk size in bytes (default: 256KB for video, 128KB for audio).
--- @param attrs table? Additional attributes for the input.
--- @return VDOMNode
function HTML.StreamingFileInput(name, accept, ws_id, preview_id, progress_id, chunk_size, attrs)
    local previewId = preview_id or name .. "_preview"
    local progressId = progress_id or name .. "_progress"
    local isVideo = accept:find("video") ~= nil
    local defaultChunkSize = isVideo and (256 * 1024) or (128 * 1024)
    
    return HTML.fragment({
        HTML.e("input", HTML.merge({
            type = "file",
            name = name,
            accept = accept,
            class = "px-3 py-2 border border-gray-300 rounded-md focus:outline-none focus:ring-2 focus:ring-blue-500 focus:border-transparent",
            ["data-bind"] = name,
            onchange = string.format(
                "window.__clientOp__(%s)",
                cjson.encode(
                    HTML.client.streamFile(
                        "input[name=\"" .. name .. "\"]",
                        {
                            chunkSize = chunk_size or defaultChunkSize,
                            onChunk = {
                                _op = "wsSend",
                                id = ws_id,
                                message = "__VALUE__"
                            },
                            onComplete = {
                                _op = "console",
                                level = "info",
                                message = "Upload of " .. name .. " complete!"
                            },
                            targetProgress = "#" .. progressId,
                            targetPreview = "#" .. previewId
                        }
                    )
                ):gsub('"', "'")
            )
        }, attrs or {}))
    })
end

--------------------------------------------------
--- Creates a form field wrapper for file inputs with label and error handling.
--- @param label string The label text.
--- @param input_node VDOMNode The file input node.
--- @param error string? Error message to display.
--- @return VDOMNode
function HTML.FileField(label, input_node, error)
    return HTML.Column({}, {
        HTML.e("label", { class = "text-sm font-medium text-gray-700 mb-1" }, label),
        input_node,
        error and HTML.e("div", { class = "text-red-500 text-sm mt-1" }, error) or nil
    })
end

-- 🧱 Flutter-style Predefined Widgets

-- --- Creates a card-style container div.
-- --- @param attrs table? Additional attributes for the div.
-- --- @param children VDOMNode|VDOMNode[]? Content of the card.
-- --- @return VDOMNode
-- function HTML.Card(attrs, children)
--  return HTML.e("div", HTML.merge({
--   class = "card",
--   style = "padding:1rem;border:1px solid #ccc;border-radius:4px;background:white;"
--  }, attrs), children)
-- end

--- Creates a card-style container div with Tailwind styling.
--- @param attrs table? Additional attributes for the div.
--- @param children VDOMNode|VDOMNode[]? Content of the card.
--- @return VDOMNode
function HTML.Card(attrs, children)
 return HTML.e("div", HTML.merge({
  class = "bg-white rounded-lg shadow-md p-6 border border-gray-200",
  style = attrs and attrs.style -- Preserve any custom style
 }, attrs), children)
end

--- Creates a CSS Grid container with Tailwind styling.
--- @param columns number? Number of columns (default: 2).
--- @param gap string? Gap between grid items (default: "1rem").
--- @param children VDOMNode|VDOMNode[]? Content of the grid.
--- @return VDOMNode
function HTML.Grid(columns, gap, children)
 return HTML.e("div", {
  class = "grid gap-4",
  style = string.format("grid-template-columns:repeat(%d,minmax(0,1fr));gap:%s;", columns or 2, gap or "1rem")
 }, children)
end

--- Creates a flexbox container for arranging children horizontally with Tailwind styling.
--- @param attrs table? Additional attributes for the div.
--- @param children VDOMNode|VDOMNode[]? Content of the row.
--- @return VDOMNode
function HTML.Row(attrs, children)
 return HTML.e("div", HTML.merge({
  class = "flex flex-row items-center gap-4",
  style = attrs and attrs.style -- Preserve any custom style
 }, attrs), children)
end

--- Creates a flexbox container for arranging children vertically with Tailwind styling.
--- @param attrs table? Additional attributes for the div.
--- @param children VDOMNode|VDOMNode[]? Content of the column.
--- @return VDOMNode
function HTML.Column(attrs, children)
 return HTML.e("div", HTML.merge({
  class = "flex flex-col gap-3",
  style = attrs and attrs.style -- Preserve any custom style
 }, attrs), children)
end

-- --- Creates an unstyled list (ul) view.
-- --- @param children VDOMNode|VDOMNode[]? List items.
-- --- @param attrs table? Additional attributes for the ul.
-- --- @return VDOMNode
-- function HTML.ListView(children, attrs)
--  return HTML.e("ul", HTML.merge({
--   style = "list-style:none;padding:0;margin:0;"
--  }, attrs), children)
-- end
-- Creates an unstyled list (ul) view with Tailwind styling.
--- @param children VDOMNode|VDOMNode[]? List items.
--- @param attrs table? Additional attributes for the ul.
--- @return VDOMNode
function HTML.ListView(children, attrs)
 return HTML.e("ul", HTML.merge({
  class = "list-none p-0 m-0 space-y-2",
  style = attrs and attrs.style -- Preserve any custom style
 }, attrs), children)
end

--- Creates a transient snackbar notification with Tailwind styling.
--- @param message string|VDOMNode The message content.
--- @param attrs table? Additional attributes for the snackbar.
--- @return VDOMNode
function HTML.Snackbar(message, attrs)
 return HTML.e("div", HTML.merge({
  class = "fixed bottom-4 left-4 bg-gray-800 text-white px-4 py-3 rounded-lg shadow-lg z-50",
  style = attrs and attrs.style -- Preserve any custom style
 }, attrs), message)
end

--- Creates a modal dialog box with Tailwind styling.
--- @param title string|VDOMNode The dialog title.
--- @param body string|VDOMNode The main content of the dialog.
--- @param actions VDOMNode[]? A list of VDOM nodes (e.g., buttons) for actions.
--- @param attrs table? Additional attributes for the dialog container.
--- @return VDOMNode
function HTML.Dialog(title, body, actions, attrs)
 return HTML.e("div", HTML.merge({
  class = "fixed top-1/2 left-1/2 transform -translate-x-1/2 -translate-y-1/2 bg-white p-6 rounded-lg shadow-xl z-50 max-w-md w-full",
  style = attrs and attrs.style -- Preserve any custom style
 }, attrs), {
  HTML.e("h2", { class = "text-xl font-semibold mb-4 text-gray-800" }, title),
  HTML.e("div", { class = "mb-6 text-gray-600" }, body),
  HTML.Row({ class = "justify-end gap-3" }, actions or {})
 })
end

--- Creates a simple spinning loader animation with Tailwind styling.
--- @param style string? Custom CSS style for the loader.
--- @return VDOMNode
function HTML.Loader(style)
 return HTML.e("div", {
  class = "animate-spin rounded-full border-4 border-gray-200 border-t-blue-500",
  style = style or "width:24px;height:24px;"
 })
end

--------------------------------------------------
-- Custom Web Components (explicit parameters)
--------------------------------------------------
--- Create a <fluid-container> custom web component.
---
--- This component is a wrapper around the custom `<fluid-container>` web element
--- implemented in `Fluid-Container.js`. It draws a curved SVG path background
--- and lets you place child content inside it.
---
--- Parameters:
---
--- @param height string|number
---   The vertical size (in pixels) of the container.  
---   ⚡ Affects how tall the rendered `<fluid-container>` box is and also
---   determines the vertical scaling of the internal curve/SVG path.
---
--- @param width string|number
---   The horizontal size (in pixels) of the container.  
---   ⚡ Determines how wide the container is and how much horizontal space
---   the curve has to draw across.
---
--- @param equation string|nil
---   A JavaScript expression used to calculate the Y-value of the curve
---   for a given X. Example: `"Math.sin(x) * 5"`.  
---   ⚡ Used only when `curve-type` is `"cartesian"`.  
---   ⚠️ If this is set, `svg-path` is ignored.
---
--- @param svgPath string|nil
---   A raw SVG path string (e.g. `"M0,100 Q150,50 300,100"`).  
---   ⚡ Used when you want full control of the shape instead of an equation.  
---   ⚠️ Overrides `equation` if both are set.
---
--- @param color string|nil
---   The fill color for the curved area (CSS color format, e.g. `"#3498db"` or `"red"`).  
---   ⚡ Affects the background appearance of the curve.  
---   Internally, the component also generates a darker shade of this color
---   for the curve’s shadow.
---
--- @param precision integer|nil
---   The number of points used to sample the equation when generating the curve path.  
---   ⚡ Higher precision = smoother curve, but more expensive rendering.  
---   Default is 20.
---
--- @param curveType string|nil
---   Defines how the equation should be interpreted. Supported values:  
---   • `"cartesian"` → standard f(x) equation  
---   • `"sin"` → sine-based curve  
---   • `"cos"` → cosine-based curve  
---   • `"circle"` → circular arc curve  
---   • `"polar"` → polar coordinate curve  
---   • `"parametric"` → parametric function curve  
---   ⚡ Changing this alters how the `equation` string is evaluated.
---
--- @param overflow string|nil
---   Controls how child content behaves outside the curve bounds.  
---   • `"hidden"` → content is clipped to the curve shape (using SVG clipPath)  
---   • `"visible"` → content can overflow freely outside the curve  
---   ⚡ Default is `"hidden"`.
---
--- @param children table[]|string|nil
---   The nested child nodes inside the container (strings or other `HTML.*` calls).  
---   ⚡ These are slotted into the `<fluid-container>` as its content.
---
--- @return table Reactive HTML node representing <fluid-container>
function HTML.FluidContainer(height, width, equation, svgPath, color, precision, curveType, overflow, children)
  local attr = {
    height       = height,
    width        = width,
    equation     = equation,
    ["svg-path"] = svgPath,
    color        = color,
    precision    = precision,
    ["curve-type"] = curveType,
    overflow     = overflow,
  }
  return HTML.e("curve-element", attr, children)
end


--- Creates a pagination component with numbered buttons and Tailwind styling.
--- @param current number The current active page number.
--- @param total number The total number of pages.
--- @param onPageClick string? The JavaScript function name to call on page button click.
--- @return VDOMNode
function HTML.Paginator(current, total, onPageClick)
 local buttons = {}
 for i = 1, total do
  table.insert(buttons, HTML.Button(tostring(i), {
   class = i == current and "bg-blue-500 text-white font-medium" or "bg-gray-100 text-gray-700 hover:bg-gray-200",
   onclick = onPageClick and onPageClick .. "(" .. i .. ")"
  }))
 end
 return HTML.Row({ class = "gap-1" }, buttons)
end

--- Creates a standard HTML form element with Tailwind styling.
--- @param attrs table? Additional attributes for the form.
--- @param children VDOMNode|VDOMNode[]? Content of the form (e.g., form fields, buttons).
--- @return VDOMNode
function HTML.Form(attrs, children)
 return HTML.e("form", HTML.merge({
  class = "space-y-4"
 }, attrs), children)
end

--- Creates a common form field structure with a label and an input with Tailwind styling.
--- @param label string The label text for the field.
--- @param inputNode VDOMNode The VDOM node for the input element (e.g., HTML.TextField).
--- @return VDOMNode
function HTML.FormField(label, inputNode)
 return HTML.Column({}, {
  HTML.e("label", { class = "text-sm font-medium text-gray-700 mb-1" }, label),
  inputNode
 })
end

--- Creates an HTML label element with Tailwind styling.
--- @param for_id string The ID of the input element this label is for.
--- @param text string The text content of the label.
--- @param attrs table? Additional attributes for the label.
--- @return VDOMNode
function HTML.Label(for_id, text, attrs)
 return HTML.e("label", HTML.merge({ 
  ["for"] = for_id,
  class = "text-sm font-medium text-gray-700"
 }, attrs or {}), text)
end



--- Creates a text input field with Tailwind styling.
--- @param name string The 'name' attribute for the input.
--- @param value string? The initial 'value' of the input.
--- @param placeholder string? The 'placeholder' text for the input.
--- @param attrs table? Additional attributes for the input.
--- @return VDOMNode
function HTML.TextField(name, value, placeholder, attrs)
 return HTML.e("input", HTML.merge({
  type = "text",
  name = name,
  value = value,
  placeholder = placeholder,
  class = "px-3 py-2 border border-gray-300 rounded-md focus:outline-none focus:ring-2 focus:ring-blue-500 focus:border-transparent",
  ["data-bind"] = name
 }, attrs or {}))
end

--- Creates a textarea input field with Tailwind styling.
--- @param name string The 'name' attribute for the textarea.
--- @param value string? The initial content of the textarea.
--- @param placeholder string? The 'placeholder' text for the textarea.
--- @param attrs table? Additional attributes for the textarea.
--- @return VDOMNode
function HTML.TextArea(name, value, placeholder, attrs)
 return HTML.e("textarea", HTML.merge({
  name = name,
  placeholder = placeholder,
  class = "px-3 py-2 border border-gray-300 rounded-md focus:outline-none focus:ring-2 focus:ring-blue-500 focus:border-transparent min-h-[100px]",
  ["data-bind"] = name
 }, attrs or {}), value)
end

--- Creates a phone number input field with a country code selector and Tailwind styling.
--- @param name string The base 'name' attribute for the phone number input.
--- @param default_country string? Default country code.
--- @param attrs table? Additional attributes for both select and input.
--- @return VDOMNode
function HTML.PhoneField(name, default_country, attrs)
 return HTML.Row({ class = "gap-2" }, {
  HTML.e("select", HTML.merge({ 
   name = name .. "_code",
   class = "px-3 py-2 border border-gray-300 rounded-md focus:outline-none focus:ring-2 focus:ring-blue-500 focus:border-transparent"
  }, attrs), {
   HTML.e("option", { value = "+254" }, "🇰🇪 +254"),
   HTML.e("option", { value = "+1" }, "🇺🇸 +1"),
   HTML.e("option", { value = "+44" }, "🇬🇧 +44"),
   HTML.e("option", { value = "+91" }, "🇮🇳 +91"),
  }),
  HTML.TextField(name, "", "Phone Number", HTML.merge({ type = "tel" }, attrs))
 })
end

--- Creates a date input field with Tailwind styling.
--- @param name string The 'name' attribute for the input.
--- @param value string? The initial 'value' of the input (format YYYY-MM-DD).
--- @param attrs table? Additional attributes for the input.
--- @return VDOMNode
function HTML.DatePicker(name, value, attrs)
 return HTML.e("input", HTML.merge({
  type = "date",
  name = name,
  value = value or os.date("%Y-%m-%d"),
  class = "px-3 py-2 border border-gray-300 rounded-md focus:outline-none focus:ring-2 focus:ring-blue-500 focus:border-transparent",
  ["data-bind"] = name
 }, attrs))
end

--- Creates a styled button element with Tailwind styling.
--- @param label string|VDOMNode The text or VDOM node for the button's label.
--- @param attrs table? Additional attributes for the button.
--- @return VDOMNode
function HTML.Button(label, attrs)
 return HTML.e("button", HTML.merge({
  type = "button",
  class = "px-4 py-2 bg-blue-500 text-white rounded-md hover:bg-blue-600 focus:outline-none focus:ring-2 focus:ring-blue-500 focus:ring-offset-2 transition-colors",
  style = attrs and attrs.style -- Preserve any custom style
 }, attrs), label)
end

--- Creates a primary action button with Tailwind styling.
--- @param label string|VDOMNode The button label.
--- @param attrs table? Additional attributes.
--- @return VDOMNode
function HTML.PrimaryButton(label, attrs)
 return HTML.Button(label, HTML.merge({
  class = "bg-blue-600 hover:bg-blue-700 text-white font-medium"
 }, attrs))
end

--- Creates a secondary action button with Tailwind styling.
--- @param label string|VDOMNode The button label.
--- @param attrs table? Additional attributes.
--- @return VDOMNode
function HTML.SecondaryButton(label, attrs)
 return HTML.Button(label, HTML.merge({
  class = "bg-gray-200 hover:bg-gray-300 text-gray-800 font-medium"
 }, attrs))
end

--- Creates a danger action button with Tailwind styling.
--- @param label string|VDOMNode The button label.
--- @param attrs table? Additional attributes.
--- @return VDOMNode
function HTML.DangerButton(label, attrs)
 return HTML.Button(label, HTML.merge({
  class = "bg-red-500 hover:bg-red-600 text-white font-medium"
 }, attrs))
end

--- Creates a select dropdown with Tailwind styling.
--- @param name string The 'name' attribute for the select.
--- @param options table Table of options {text = value} or {text} for value=text.
--- @param selected string? The currently selected value.
--- @param attrs table? Additional attributes.
--- @return VDOMNode
function HTML.Select(name, options, selected, attrs)
    local optionNodes = {}
    
    -- Handle array-style options: {"Option 1", "Option 2", "Option 3"}
    if #options > 0 then
        for _, item in ipairs(options) do
            local text = tostring(item)
            local value = tostring(item)
            table.insert(optionNodes, HTML.e("option", {
                value = value,
                selected = selected == value
            }, text))
        end
    -- Handle key-value style options: {["Option 1"] = "val1", ["Option 2"] = "val2"}
    else
        for text, value in pairs(options) do
            table.insert(optionNodes, HTML.e("option", {
                value = tostring(value),
                selected = selected == tostring(value)
            }, tostring(text)))
        end
    end
    
    return HTML.e("select", HTML.merge({
        name = name,
        class = "px-3 py-2 border border-gray-300 rounded-md focus:outline-none focus:ring-2 focus:ring-blue-500 focus:border-transparent",
        ["data-bind"] = name
    }, attrs), optionNodes)
end

--- Creates a checkbox input with Tailwind styling.
--- @param name string The 'name' attribute.
--- @param checked boolean? Whether the checkbox is checked.
--- @param label string|VDOMNode? Optional label text.
--- @param attrs table? Additional attributes.
--- @return VDOMNode
function HTML.Checkbox(name, checked, label, attrs)
 local checkbox = HTML.e("input", HTML.merge({
  type = "checkbox",
  name = name,
  checked = checked,
  class = "h-4 w-4 text-blue-500 border-gray-300 rounded focus:ring-blue-500",
  ["data-bind"] = name
 }, attrs))
 
 if label then
  return HTML.Row({ class = "items-center gap-2" }, {
   checkbox,
   HTML.e("label", { class = "text-sm text-gray-700" }, label)
  })
 end
 return checkbox
end

--- Creates a radio button input with Tailwind styling.
--- @param name string The 'name' attribute.
--- @param value string The value for this radio option.
--- @param checked boolean? Whether this radio is checked.
--- @param label string|VDOMNode? Optional label text.
--- @param attrs table? Additional attributes.
--- @return VDOMNode
function HTML.Radio(name, value, checked, label, attrs)
 local radio = HTML.e("input", HTML.merge({
  type = "radio",
  name = name,
  value = value,
  checked = checked,
  class = "h-4 w-4 text-blue-500 border-gray-300 focus:ring-blue-500",
  ["data-bind"] = name
 }, attrs))
 
 if label then
  return HTML.Row({ class = "items-center gap-2" }, {
   radio,
   HTML.e("label", { class = "text-sm text-gray-700" }, label)
  })
 end
 return radio
end
--------------------------------------------------
-- 📦 Schema Registry & Validation
--------------------------------------------------
--- Registers a validation schema for a form.
--- @param name string A unique name for the schema.
--- @param schema Schema A table defining the form's structure and validation rules.
function HTML.setSchema(name, schema) schema_registry[name] = schema end
--- Retrieves a previously registered schema.
--- @param name string The name of the schema to retrieve.
--- @return Schema? The schema table, or nil if not found.
function HTML.getSchema(name) return schema_registry[name] end

--- Validates a table of form values against a provided schema.
--- @param schema Schema The schema to validate against.
--- @param values table? A table of form field names and their submitted values.
--- @return table<string, string> A table of errors, where keys are field names and values are error messages. An empty table indicates no errors.
function HTML.validate(schema, values)
 local errors = {}
 for _, f in ipairs(schema.fields or {}) do
  local val = values and values[f.name] or nil
  if f.required and (val == nil or val == "") then
   errors[f.name] = "This field is required."
  elseif f.pattern and val and not tostring(val):match(f.pattern) then
   errors[f.name] = "Invalid format."
  end
 end
 return errors
end

--- Renders validation error messages for a form.
--- @param errors table<string, string>? A table of validation errors.
--- @return VDOMNode A fragment containing div elements for each error.
function HTML.FormErrors(errors)
 local out = {}
 for field, msg in pairs(errors or {}) do
  table.insert(out, HTML.e("div", {
   class = "form-error",
   style = "color:red;font-size:0.9em;"
  }, field .. ": " .. msg))
 end
 return HTML.fragment(out)
end

--- Automatically generates a form's VDOM structure based on a schema.
--- It handles pre-populating fields with `values` and displaying validation `errors`.
--- @param schema Schema The form schema.
--- @param values table? The current form values to pre-populate.
--- @param errors table<string, string>? A table of validation errors to display.
--- @return VDOMNode A VDOM node for a <form> element.
function HTML.AutoForm(schema, values, errors)
 local children = {}
 for _, f in ipairs(schema.fields or {}) do
  local input, preview, progress
  local ispreview = f.show_default_preview or true
  local isprogress = f.show_default_progress or true
  local attrs = { name = f.name, required = f.required, ["data-bind"] = f.name } -- Add data-bind
  if f.placeholder then attrs.placeholder = f.placeholder end
  if f.bind then
   attrs.oninput = string.format("state.%s = this.value", f.bind) -- This JS will be less relevant if using `data-bind` + `__initializeReactiveInputs__`
   attrs.name = f.bind
  end
  if errors and errors[f.name] then
   attrs.style = "border:1px solid red;"
  end
  if f.type == "textarea" then
   input = HTML.e("textarea", attrs, values and values[f.name])
  elseif f.type == "date" then
   input = HTML.e("input", HTML.merge(attrs, { type = "date", value = values and values[f.name] }))
  elseif f.type == "select" then
   input = HTML.e("select", attrs, HTML.map(f.options, function(opt)
    return HTML.e("option", { value = opt }, opt)
   end))
elseif f.type == "file" then
            input = HTML.e("input", HTML.merge(attrs, {
                type = "file",
                name = f.name,
                required = f.required and true or nil
            }))

        elseif f.type == "image" then
            input = HTML.e("input", HTML.merge(attrs, {
                type = "file",
                accept = "image/*",
                name = f.name,
                required = f.required and true or nil,
                onchange = string.format(
                    "window.__clientOp__(%s)",
                    cjson.encode(
                        HTML.client.readFileAsDataURL(
                            "input[name=\"" .. f.name .. "\"]",
                            HTML.client.batch(
                                HTML.client.setAttrs("#" .. f.name .. "_preview", { src = "__VALUE__" }),
                                HTML.client.removeClass("#" .. f.name .. "_preview", "hidden")
                            )
                        )
                    ):gsub('"', "'")
                )
  
            }))
            preview = ispreview and HTML.e("img", {
                id = f.name .. "_preview",
                class = "mt-2 max-h-48 rounded border hidden"
            }) or nil

        elseif f.type == "audio" then
            input = HTML.e("input", HTML.merge(attrs, {
                type = "file",
                accept = "audio/*",
                name = f.name,
                required = f.required and true or nil,
                onchange = string.format(
                    "window.__clientOp__(%s)",
                    cjson.encode(
                        HTML.client.readFileAsAudio(
                            "input[name=\"" .. f.name .. "\"]",
                            nil,
                            { target = "#" .. f.name .. "_preview" }
                        )
                    ):gsub('"', "'")
                )
            }))
            preview = ispreview and HTML.e("audio", {
                id = f.name .. "_preview",
                class = "mt-2 hidden",
                controls = true
            }) or nil

        elseif f.type == "video" then
            input = HTML.e("input", 
            HTML.merge(attrs, {

                type = "file",
                accept = "video/*",
                name = f.name,
                required = f.required and true or nil,
                onchange = string.format(
                    "window.__clientOp__(%s)",
                    cjson.encode(
                        HTML.client.readFileAsVideo(
                            "input[name=\"" .. f.name .. "\"]",
                            nil,
                            { target = "#" .. f.name .. "_preview" }
                        )
                    ):gsub('"', "'")
                )
            }))
            preview = ispreview and HTML.e("video", {
                id = f.name .. "_preview",
                class = "mt-2 hidden",
                controls = true,
                style = "max-height: 240px;"
            }) or nil

        elseif f.type == "largeVideo" then
            input = HTML.e("input", HTML.merge(attrs, {
                type = "file",
                accept = "video/*",
                name = f.name,
                required = f.required and true or nil,
                onchange = string.format(
                    "window.__clientOp__(%s)",
                    cjson.encode(
                        HTML.client.streamFile(
                            "input[name=\"" .. f.name .. "\"]",
                            {
                                chunkSize = f.chunkSize or 256 * 1024,
                                onChunk = {
                                    _op = "wsSend",
                                    id = f.ws or "uploadSocket",
                                    message = "__VALUE__"
                                },
                                onComplete = {
                                    _op = "console",
                                    level = "info",
                                    message = "Upload of " .. f.name .. " complete!"
                                },
                                targetProgress = "#" .. f.name .. "_progress",
                                targetPreview = "#" .. f.name .. "_preview"
                            }
                        )
                    ):gsub('"', "'")
                )
            }))
            preview = ispreview and HTML.e("video", {
                id = f.name .. "_preview",
                class = "mt-2 hidden",
                controls = true,
                style = "max-height: 240px;"
            }) or nil
            progress = isprogress and HTML.e("progress", {
                id = f.name .. "_progress",
                max = 100,
                value = 0,
                class = "mt-2 w-full"
            }) or nil

        elseif f.type == "largeAudio" then
            input = HTML.e("input", HTML.merge(attrs, {
                type = "file",
                accept = "audio/*",
                name = f.name,
                required = f.required and true or nil,
                onchange = string.format(
                    "window.__clientOp__(%s)",
                    cjson.encode(
                        HTML.client.streamFile(
                            "input[name=\"" .. f.name .. "\"]",
                            {
                                chunkSize = f.chunkSize or 128 * 1024,
                                onChunk = {
                                    _op = "wsSend",
                                    id = f.ws or "uploadSocket",
                                    message = "__VALUE__"
                                },
                                onComplete = {
                                    _op = "console",
                                    level = "info",
                                    message = "Upload of " .. f.name .. " complete!"
                                },
                                targetProgress = "#" .. f.name .. "_progress",
                                targetPreview = "#" .. f.name .. "_preview"
                            }
                        )
                    ):gsub('"', "'")
                )
            }))
            preview = ispreview and HTML.e("audio", {
                id = f.name .. "_preview",
                class = "mt-2 hidden",
                controls = true
            }) or nil
            progress = isprogress and HTML.e("progress", {
                id = f.name .. "_progress",
                max = 100,
                value = 0,
                class = "mt-2 w-full"
            }) or nil
  else
   input = HTML.e("input", HTML.merge(attrs, { type = f.type or "text", value = values and values[f.name] }))
  end
  table.insert(children, HTML.e("div", {}, {
   HTML.e("label", {}, f.label or f.name),
   input
  }))

  if preview then table.insert(children, preview) end
if progress then table.insert(children, progress) end

 end
 if errors then table.insert(children, HTML.FormErrors(errors)) end
 return HTML.e("form", {}, children)
end

--------------------------------------------------
-- 🌐 Layout + Slot Support
--------------------------------------------------
--- Registers a reusable layout function.
--- A layout is a function that takes a `context` and renders a full page structure, often with a "slot" for the main content.
--- @param name string A unique name for the layout.
--- @param fn fun(ctx: table): VDOMNode The layout function. `ctx` will typically contain a `content` field.
function HTML.defineLayout(name, fn) layout_registry[name] = fn end

--- Renders a previously defined layout with a specific context.
--- @param name string The name of the layout to use.
--- @param ctx table The context for the layout, typically including the `content` to be placed inside.
--- @field ctx.content VDOMNode|VDOMNode[] The main content to be rendered within the layout.
--- @field ctx.slots table<string, VDOMNode|VDOMNode[]>? Optional table of named slots for specific content.
--- @return VDOMNode The VDOM tree generated by the layout.
function HTML.useLayout(name, ctx)
 local layout = layout_registry[name]
 assert(layout, "Layout not found: " .. name)
 return layout(ctx)
end

--- Renders content from a named slot within a layout context.
--- @param name string The name of the slot.
--- @param ctx table The context passed to the layout, containing `ctx.slots`.
--- @return VDOMNode? The content for the specified slot, or nil if not found.
function HTML.Slot(name, ctx)
 return ctx.slots and ctx.slots[name] or nil
end

--- Returns `val` if it's not nil or empty, otherwise returns `fallback`.
--- @param val any The value to check.
--- @param fallback any The fallback value.
--- @return any
function HTML.withDefault(val, fallback)
 return val or fallback
end

 --- create an enum object that will contain the patch types
HTML.PatchType = {
  UPDATE_VAR = "update-var",
  LIST = "list",
  OBJECT = "object",
  NESTED = "nested",
  GENERATOR = "generator"
}


--- Creates a patch object for updating a list of items on the client.
--- Used for reactive list rendering.
--- @param selector string CSS selector for the list container.
--- @param items table The new list of data items.
--- @param template_id string The ID of the HTML template to use for rendering each item.
--- @param classes string? CSS classes to apply during staggered updates.
--- @param staggerDelay number? Delay in milliseconds for staggered item updates.
--- @return PatchObject
function HTML.patch_list(selector, items, template_id, classes, staggerDelay)
  return {
    type = "list",
    selector = selector,
    items = items,
    template = template_id,
    classes = classes,
    staggerDelay = staggerDelay
  }
end

--- Creates a patch object for updating an object's properties on the client.
--- Used for reactive object rendering.
--- @param selector string CSS selector for the object container.
--- @param object table The new object data.
--- @param template_id string The ID of the HTML template to use for rendering the object.
--- @return PatchObject
function HTML.patch_object(selector, object, template_id)
  return {
    type = "object",
    selector = selector,
    object = object,
    template = template_id
  }
end



--- Creates a patch object for updating a nested value on the client.
--- @param selector string CSS selector for the parent element.
--- @param path string Dot-separated path to the nested value (e.g., "user.address.street").
--- @param value any The new value for the nested property.
--- @return PatchObject
function HTML.patch_nested(selector, path, value)
  return {
    type = "nested",
    selector = selector,
    path = path,
    value = value
  }
end


-- Add these missing functions to your LuaHTMLReactive.lua file

--------------------------------------------------
-- 🔄 Client State Helper Functions
--------------------------------------------------

--- Creates a client state binding element for reactive updates
--- @param varName string The name of the client state variable
--- @param content string|number The current value
--- @param attrs table? Optional attributes
--- @return VDOMNode
function HTML.bindClientState(varName, content, attrs)
    attrs = attrs or {}
    attrs["data-bind-client"] = varName -- Identifier for client-side clientState querying
    attrs.class = (attrs.class and attrs.class .. " " or "") .. "reactive-clientstate-" .. varName
    return HTML.e("span", attrs, content)
end

--- Helper function to create shallow copy of a table (for state comparison)
--- @param t table The table to copy
--- @return table A shallow copy
function HTML.shallowCopy(t)
    if type(t) ~= "table" then return t end
    local copy = {}
    for k, v in pairs(t) do
        copy[k] = v
    end
    return copy
end

--- Helper function to compare two values for shallow equality
--- @param a any First value
--- @param b any Second value
--- @return boolean True if equal
function HTML.shallowEqual(a, b)
    if type(a) ~= type(b) then return false end
    if type(a) ~= "table" then return a == b end
    
    for k, v in pairs(a) do
        if b[k] ~= v then return false end
    end
    
    for k, v in pairs(b) do
        if a[k] ~= v then return false end
    end
    
    return true
end

--- Enhanced setState method for components that supports clientState
--- @param partial table A table containing state keys and new values
--- @return PatchObject[] A list of generated patch objects
function HTML.createEnhancedComponent(fn, initialState)
    local comp = HTML.createComponent(fn, initialState)
    
    -- Enhanced setState that handles clientState patches
    local originalSetState = comp.setState
    comp.setState = function(partial)
        local patches = originalSetState(partial)
        
        -- Add clientState specific patches if clientState keys are modified
        for k, v in pairs(partial) do
            if k:find("clientState") or (comp.reactiveBindings and comp.reactiveBindings[k] and k:find("client")) then
                -- Generate clientState specific patches
                table.insert(patches, {
                    type = "update-var",
                    varName = k,
                    value = v,
                    selector = string.format('[data-bind-client="%s"]', k),
                    isClientState = true
                })
            end
        end
        
        return patches
    end
    
    return comp
end

--- Creates a component that can handle both normal state and clientState
--- @param renderFn fun(state: table, props: table, clientState: table): VDOMNode The render function
--- @param initialState table? Initial state
--- @param initialClientState table? Initial client state
--- @return Component
function HTML.createDualStateComponent(renderFn, initialState, initialClientState)
    local fullState = initialState or {}
    fullState.clientState = initialClientState or {}
    
    local comp = HTML.createComponent(function(state, props)
        -- Separate normal state from clientState for the render function
        local normalState = {}
        local clientState = state.clientState or {}
        
        for k, v in pairs(state) do
            if k ~= "clientState" then
                normalState[k] = v
            end
        end
        
        return renderFn(normalState, props, clientState)
    end, fullState)
    
    -- Enhanced method to update clientState specifically
    comp.setClientState = function(clientStatePartial)
        local mergedClientState = comp.state.clientState or {}
        for k, v in pairs(clientStatePartial) do
            mergedClientState[k] = v
        end
        
        return comp.setState({ clientState = mergedClientState })
    end
    
    -- Method to get current clientState
    comp.getClientState = function()
        return comp.state.clientState or {}
    end
    
    return comp
end

--------------------------------------------------
-- 🔄 Enhanced Patch Generation for ClientState
--------------------------------------------------

--- Generates patches specifically for clientState changes
--- @param clientStateChanges table Key-value pairs of clientState changes
--- @param componentKey string The component key for namespacing
--- @return PatchObject[]
function HTML.generateClientStatePatches(clientStateChanges, componentKey)
    local patches = {}
    
    for key, value in pairs(clientStateChanges) do
        local fullVarName = componentKey and (componentKey .. ".clientState." .. key) or ("clientState." .. key)
        
        table.insert(patches, {
            type = "update-var",
            varName = fullVarName,
            value = value,
            selector = string.format('[data-bind-client="%s"]', key),
            component = componentKey,
            isClientState = true
        })
    end
    
    return patches
end

--- Enhanced diff function that handles clientState bindings
function HTML.enhancedDiff(old, new, path)
    path = path or "root"
    local patches = HTML.diff(old, new, path)
    
    -- Additional logic for clientState specific attributes
    local oldAttrs = old and old.attrs or {}
    local newAttrs = new and new.attrs or {}
    
    -- Check for clientState binding changes
    if oldAttrs["data-bind-client"] ~= newAttrs["data-bind-client"] then
        local selector = HTML.path_to_selector(path)
        table.insert(patches, {
            type = "attr",
            path = path,
            selector = selector,
            key = "data-bind-client",
            value = newAttrs["data-bind-client"],
            isClientState = true
        })
    end
    
    return patches
end

--------------------------------------------------
-- 🔄 ClientState Aware Rendering Helpers
--------------------------------------------------

--- Renders a component with clientState context
--- @param component Component The component to render
--- @param props table Component props
--- @param clientState table Current clientState
--- @return VDOMNode
function HTML.renderWithClientState(component, props, clientState)
    if component.renderWithClientState then
        return component:renderWithClientState(props, clientState)
    else
        -- Merge clientState into props for backward compatibility
        local enhancedProps = props or {}
        enhancedProps.clientState = clientState
        return component:render(enhancedProps)
    end
end

--- Creates a VDOM node that reacts to clientState changes
--- @param clientStateKey string The clientState variable key
--- @param renderFn fun(value: any): VDOMNode Function that renders based on clientState value
--- @param attrs table? Additional attributes
--- @return VDOMNode
function HTML.clientStateBound(clientStateKey, renderFn, attrs)
    attrs = attrs or {}
    attrs["data-bind-client"] = clientStateKey
    
    return HTML.e("span", attrs, function()
        -- This will be replaced with actual value during rendering
        return renderFn(nil)
    end)
end

--------------------------------------------------
-- 🔄 Missing Utility Functions
--------------------------------------------------

--- Safe JSON decode with error handling
--- @param str string JSON string to decode
--- @return table|nil Decoded table or nil on error
--- @return string|nil Error message
function HTML.safeJsonDecode(str)
    local ok, result = pcall(function()
        return cjson.decode(str)
    end)
    
    if ok then
        return result
    else
        return nil, result
    end
end

--- Deep merge two tables
--- @param t1 table First table
--- @param t2 table Second table
--- @return table Merged table
function HTML.deepMerge(t1, t2)
    local result = {}
    
    for k, v in pairs(t1 or {}) do
        result[k] = v
    end
    
    for k, v in pairs(t2 or {}) do
        if type(v) == "table" and type(result[k]) == "table" then
            result[k] = HTML.deepMerge(result[k], v)
        else
            result[k] = v
        end
    end
    
    return result
end

--- Generates a unique ID for patches or elements
--- @param prefix string Prefix for the ID
--- @return string Unique ID
function HTML.generateId(prefix)
    prefix = prefix or "id"
    return prefix .. "_" .. tostring(os.time()) .. "_" .. tostring(math.random(1000, 9999))
end

--------------------------------------------------
-- 🔄 Enhanced Component Creation with ClientState Support
--------------------------------------------------

--- Creates a component with built-in clientState support
--- @param options table Component options
--- @field options.render fun(state: table, props: table, clientState: table): VDOMNode Render function
--- @field options.initialState table? Initial state
--- @field options.initialClientState table? Initial client state
--- @field options.methods table? Component methods
--- @field options.onClientStateChange fun(newClientState: table, oldClientState: table)? Callback when clientState changes
--- @return Component
function HTML.createComponentWithClientState(options)
    local comp = HTML.createDualStateComponent(options.render, options.initialState, options.initialClientState)
    
    -- Store the callback
    comp.onClientStateChange = options.onClientStateChange
    
    -- Enhance setClientState to trigger callback
    local originalSetClientState = comp.setClientState
    comp.setClientState = function(clientStatePartial)
        local oldClientState = comp.getClientState()
        local patches = originalSetClientState(clientStatePartial)
        local newClientState = comp.getClientState()
        
        if comp.onClientStateChange then
            comp:onClientStateChange(newClientState, oldClientState)
        end
        
        return patches
    end
    
    -- Add custom methods
    if options.methods then
        for name, method in pairs(options.methods) do
            comp.methods[name] = method
        end
    end
    
    return comp
end

--------------------------------------------------
-- 🔄 ClientState Specific VDOM Helpers
--------------------------------------------------

--- Creates a element that displays clientState value
--- @param clientStateKey string The clientState variable key
--- @param formatFn fun(value: any): string|number? Formatting function
--- @param attrs table? Additional attributes
--- @return VDOMNode
function HTML.clientStateDisplay(clientStateKey, formatFn, attrs)
    formatFn = formatFn or function(value) return tostring(value or "") end
    
    return HTML.bindClientState(clientStateKey, formatFn(nil), attrs)
end

--- Creates an input bound to clientState
--- @param clientStateKey string The clientState variable key
--- @param inputType string Input type (text, number, etc.)
--- @param attrs table? Additional attributes
--- @return VDOMNode
function HTML.clientStateInput(clientStateKey, inputType, attrs)
    attrs = attrs or {}
    attrs.type = inputType or "text"
    attrs["data-bind-client"] = clientStateKey
    attrs.class = (attrs.class and attrs.class .. " " or "") .. "client-state-input"
    
    return HTML.e("input", attrs)
end

--- Creates a button that updates clientState
--- @param label string Button label
--- @param clientStateUpdate table ClientState changes to apply on click
--- @param attrs table? Button attributes
--- @return VDOMNode
function HTML.clientStateButton(label, clientStateUpdate, attrs)
    attrs = attrs or {}
    attrs.onclick = string.format(
        "window.__updateClientState__(%s)",
        cjson.encode(clientStateUpdate):gsub('"', "'")
    )
    
    return HTML.e("button", attrs, label)
end


--------------------------------------------------
-- 🧬 Component System (Reactive)
--------------------------------------------------
--- Creates a stateful component.
--- This function returns a component object with methods for rendering, managing state, and handling patches.
--- @param fn fun(state: table, props: table): VDOMNode The render function for the component.
--- @param initialState table? The initial state of the component.
--- @field initialState._reactiveBindings table<string, boolean>? A map of state keys that are reactively bound to DOM elements.
--- @return Component A component object.
function HTML.createComponent(fn, initialState)
 local comp = {}
 comp.state = initialState or {}
 comp.lastNode = nil
 comp.patches = {}
 comp.props = {}
 -- Explicitly define reactive bindings, or derive from state keys if preferred
 comp.reactiveBindings = comp.state._reactiveBindings or {}
 comp.state._reactiveBindings = nil -- Clean up if directly in state

--- Updates the component's state and automatically generates patches by comparing the old VDOM with the new VDOM.
--- This is the primary way to trigger UI updates.
--- @param partial table A table containing the state keys and new values to merge into the component's state.
--- @return PatchObject[] A list of generated patch objects.
function comp.setState(partial)
  local generatedPatches = {}

  for k, v in pairs(partial) do
    -- Only update if value actually changed
    if comp.state[k] ~= v then
      comp.state[k] = v

      -- Reactive variable? → Prefer update-var
      if comp.reactiveBindings[k] then
        table.insert(generatedPatches, {
          type = "update-var",
          varName = k,
          value = v,
          selector = string.format('[data-bind="%s"]', k)
        })

      -- Array? → Treat as list patch
      elseif type(v) == "table" and #v > 0 then
        table.insert(generatedPatches, HTML.patch_list(
          string.format('[data-bind="%s"]', k),
          v,
          k .. "_template"
        ))

      -- Object-like table? → Treat as object patch
      elseif type(v) == "table" then
        table.insert(generatedPatches, HTML.patch_object(
          string.format('[data-bind="%s"]', k),
          v,
          k .. "_template"
        ))

      else
        -- Primitive value not bound → fallback to nested patch
        table.insert(generatedPatches, HTML.patch_nested(
          ":scope", -- Will be replaced if you store selector map
          k,
          v
        ))
      end
    end
  end

  -- Always do a VDOM diff in case there are structural changes
  local newNode = fn(comp.state, comp.props)
  local domPatches = HTML.diff(comp.lastNode, newNode)
  comp.lastNode = newNode

  for _, p in ipairs(domPatches) do
    table.insert(generatedPatches, p)
  end

  comp.patches = generatedPatches
  return generatedPatches
end

--- Renders the component's VDOM based on its current state and provided props.
--- @param props table? Properties to pass to the component's render function.
--- @return VDOMNode The rendered VDOM node.
 function comp.render(props)
  comp.props = props or {}
  local node = fn(comp.state, comp.props)
  comp.lastNode = node
  return node
 end

 --- Accepts patch messages (e.g., from JS) and mutates state.
 --- This function is designed to be called by the client-side patching mechanism.
 --- @param method string The name of the method to call on the component's `methods` table.
 --- @param args any[] Arguments to pass to the component method.
 --- @return any The result of the called method.
 function comp.patch(method, args)
  if type(comp.methods) == "table" and type(comp.methods[method]) == "function" then
   return comp.methods[method](comp, table.unpack(args or {}))
  end
 end

 comp.methods = {} -- define comp.methods.add/remove etc externally
 return comp
end
--------------------------------------------------
-- 🧱 App + Page Wrapper with Hydration
--------------------------------------------------
--- A high-level helper for generating a complete HTML document structure, including the `<html>`, `<head>`, and `<body>` tags.
--- @param config table A configuration table.
--- @field config.title string? The page title. Defaults to "Untitled".
--- @field config.head_extra VDOMNode|VDOMNode[]? Additional content to be inserted into the `<head>`.
--- @field config.body_attrs table? Attributes for the `<body>` tag.
--- @field config.children VDOMNode|VDOMNode[]? The main content of the page, to be placed inside the `<body>`.
--- @return VDOMNode A complete VDOM tree for an HTML page.
function HTML.Page(config)
  local head_children = {
    HTML.e("meta", { charset = "utf-8" }),
    HTML.e("meta", { name = "viewport", content = "width=device-width, initial-scale=1.0" }),
    HTML.e("title", {}, config.title or "Untitled")
  }

  -- UNPACK THE head_extra DIRECTLY INTO head_children
  if config.head_extra and config.head_extra.children then
    for _, child_node in ipairs(config.head_extra.children) do
      table.insert(head_children, child_node)
    end
  elseif config.head_extra and type(config.head_extra) == "table" then -- Handle case if head_extra is a single node, not a fragment
    table.insert(head_children, config.head_extra)
  end

  return HTML.e("html", {}, {
    HTML.e("head", {}, head_children), -- Pass the flattened list
    HTML.e("body", config.body_attrs or {}, config.children or {})
  })
end


--- The top-level wrapper for a reactive application.
--- It orchestrates the creation of a complete HTML page, including all the necessary `<script>` and `<style>` tags for client-side functionality like state hydration, reactive bindings, and patching.
--- @param config table A configuration table.
--- @field config.state table? The initial state of the application. This is serialized and passed to the client for hydration.
--- @field config.filters table? (Optional) JSON config for client patch filters.
--- @field config.component_css string[]? A list of CSS strings from components to be inlined.
--- @field config.component_js_scripts string[]? A list of raw JavaScript strings from components to be inlined.
--- @field config.include_patch_client boolean? If false, omits the default patchClient.js script. Defaults to true.
--- @field config.title string? The page title. Defaults to "Dawn Untitled".
--- @field config.body_attrs table? Attributes for the <body> tag.
--- @field config.head_extra VDOMNode|VDOMNode[]? Additional custom content for the <head> section.
--- @field config.children VDOMNode|VDOMNode[]? The root VDOM node(s) of the application, to be placed in the body.
--- @return VDOMNode The full VDOM tree for a reactive HTML application, ready for rendering to a string.
function HTML.App(config)
    local cjson = require("cjson")
    local state = config.state or {}
    local filters = config.filters
    local collected_component_css = config.component_css or {}
    local collected_component_js_scripts = config.component_js_scripts or {}

    -- Define the new head elements to be inserted
    local new_head_elements = {
        HTML.e("link", { rel = "icon", href = "https://placehold.co/32x32/17183B/FFFBFF?text=DF", type = "image/x-icon" }),
        HTML.e("link", { href = "https://fonts.googleapis.com/css2?family=Poppins:wght@400;600;700&family=Inter:wght@400;600;700&family=Roboto:wght@400;500&family=Open+Sans:wght@400;600&family=Fira+Code:wght@400;500;600&display=swap", rel = "stylesheet" }),
        HTML.e("script", { src = "https://cdn.tailwindcss.com" }),
        HTML.e("script", { src = "https://cdnjs.cloudflare.com/ajax/libs/pako/2.1.0/pako.min.js" }),
        HTML.e("link", { rel = "stylesheet", href = "https://cdnjs.cloudflare.com/ajax/libs/font-awesome/6.0.0-beta3/css/all.min.css" }),
        HTML.e("link", {rel = "stylesheet", href = "/static/assets/css/style.css"}),
    }

    

    local head_elements = {}

    -- 1. Inject initial state
    table.insert(head_elements, HTML.e("script", {}, "window.__INITIAL_STATE__ = " .. cjson.encode(state) .. ";"))

    -- Add the new elements to the head_elements table at the beginning
    for _, el in ipairs(new_head_elements) do
        table.insert(head_elements, el)
    end

    -- 5. Add any JS scripts from components (not modules, raw inline or preloaded)
    for _, js in ipairs(collected_component_js_scripts) do
        table.insert(head_elements, HTML.e("script", {}, js))
    end

    -- 3. Include your app logic (runs after hydration is defined)
    table.insert(head_elements, HTML.e("script", { type = "module", src = "/static/assets/js/main.js" }))

    -- 4. Include the patching/hydration handler
    if config.include_patch_client ~= false then
        table.insert(head_elements, HTML.e("script", { type = "module", src = "/static/assets/js/patchClient.js" }))
        table.insert(head_elements, HTML.e("script", { type = "module", src = "/static/assets/js/Fluid-Container.umd.min.js" }))
    end

    -- 6. Filters (optional JSON config for client patch filters)
    if filters then
        table.insert(head_elements, HTML.e("script", {}, "window.__PATCH_FILTERS__ = " .. cjson.encode(filters) .. ";"))
    end

    -- 7. Component/inlined CSS
    if next(collected_component_css) then
        table.insert(head_elements, HTML.e("style", {}, table.concat(collected_component_css, "\n")))
    end



    -- 8. Extra custom head content
    if config.head_extra then
        if config.head_extra.children then
            for _, child_node in ipairs(config.head_extra.children) do
                table.insert(head_elements, child_node)
            end
        else
            table.insert(head_elements, config.head_extra)
        end
    end

        table.insert(head_elements, HTML.e("script", { type = "module" }, [[
    import {
        bindStateToDOM,
        initializeBindings
    } from '/static/assets/js/domBindings.js';

    import {
        getState,
        dispatch
    } from '/static/assets/js/clientStore.js';

    document.addEventListener("DOMContentLoaded", () => {
        initializeBindings(dispatch);
        bindStateToDOM(getState(), dispatch);
    });
    ]]))

    table.insert(head_elements, HTML.e("script", {
        type = "module",
        src = "/reactors/_index.js"
    }))

    -- === BODY ===
    local final_body_children = {}
    if config.children then
        -- If config.children is an HTML.fragment, take its inner children
        if type(config.children) == 'table' and config.children.tag == nil and config.children.children then
            final_body_children = config.children.children
        -- If config.children is a single VDOM node (e.g., HTML.e(...))
        elseif type(config.children) == 'table' and config.children.tag ~= nil then
            final_body_children = { config.children }
        -- If config.children is already a flat table of VDOM nodes (e.g., {node1, node2})
        elseif type(config.children) == 'table' and not config.children.tag and next(config.children) then
            final_body_children = config.children
        -- If it's a simple string or number (content directly)
        else
            final_body_children = { config.children } -- Wrap it in a table
        end
    end

    return HTML.Page({
        title = config.title or "Dawn Untitled",
        body_attrs = config.body_attrs,
        head_extra = HTML.fragment(head_elements),
        children = HTML.fragment(final_body_children)
    })
end



return HTML