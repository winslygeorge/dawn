-- component_patcher.lua
-- ✅ Reusable patch helpers for data-id-based component targeting

local Patcher = {}

-- A generic function to generate a patch targeting an element by data-id
-- Renamed `type` to `patchType` to avoid shadowing the built-in Lua `type` function
local function createPatch(patchType, data_id, extra_data)
    assert(type(data_id) == "string", "data_id must be a string")
    local patch = {
        type = patchType,
        selector = string.format('[data-id="%s"]', data_id)
    }
    for k, v in pairs(extra_data or {}) do
        patch[k] = v
    end
    return patch
end

-- Set an attribute using data-id
function Patcher.setAttr(data_id, key, value)
    return createPatch("attr", data_id, { key = key, value = value })
end

-- Remove an attribute using data-id
function Patcher.removeAttr(data_id, key)
    return createPatch("remove-attr", data_id, { key = key })
end

-- Set the text content using data-id
function Patcher.setText(data_id, content)
    return createPatch("text", data_id, { content = tostring(content) })
end

-- Replace an element using new HTML
function Patcher.replace(data_id, newHTML)
    return createPatch("replace", data_id, { newHTML = newHTML })
end

-- Remove a node using data-id
function Patcher.remove(data_id)
    return createPatch("remove", data_id)
end

-- Update a reactive variable (data-bind)
function Patcher.setVar(varName, value)
    assert(type(varName) == "string", "varName must be a string")
    return {
        type = "update-var",
        varName = varName,
        value = value
    }
end

-- Set multiple attributes on a single data-id node
function Patcher.multiAttr(data_id, attrs)
    assert(type(attrs) == "table", "attrs must be a table")
    local out = {}
    for k, v in pairs(attrs) do
        table.insert(out, Patcher.setAttr(data_id, k, v))
    end
    return out
end

-- New functions for list/array and nested data support
-- Creates a patch to update a list with items and an optional template
-- Items should be tables with a unique 'key' for efficient reconciliation
-- Template can be an HTML string or a string referencing a data-template-id
function Patcher.setList(data_id, items, template)
    return createPatch("list", data_id, {
        items = items,
        template = template
    })
end

-- Creates a patch to update a single object using an HTML template
function Patcher.setObject(data_id, object, template)
    return createPatch("object", data_id, {
        object = object,
        template = template
    })
end

-- Creates a patch for nested access (text, attr, or variable) within a data-id element
function Patcher.setNested(data_id, path, value)
    assert(type(path) == "string", "path must be a string")

    return createPatch("nested", data_id, {
        path = path,
        value = value
    })
end

return Patcher