-- MustacheHTMLBuilder.lua
-- Converts Lua tables to HTML5-compliant Mustache templates using the Enums helper

local Enums = require("layout.renderer.HTML_Enums")
local Builder = {}

-- Pre-compute frequently used strings and patterns for performance
local AMP_REPLACE = "&amp;"
local LT_REPLACE = "&lt;"
local GT_REPLACE = "&gt;"
local QUOT_REPLACE = "&quot;"
local APOS_REPLACE = "&#39;"

-- Escape HTML
local function escape_html(str)
    -- Convert to string once at the beginning to avoid repeated checks within gsub
    local s = tostring(str)
    return s:gsub("&", AMP_REPLACE)
            :gsub("<", LT_REPLACE)
            :gsub(">", GT_REPLACE)
            :gsub('"', QUOT_REPLACE)
            :gsub("'", APOS_REPLACE)
end

-- Self-closing tags set for quicker lookup
local SELF_CLOSING_TAGS = {
    br = true,
    hr = true,
    img = true,
    input = true,
    area = true,
    base = true,
    col = true,
    embed = true,
    keygen = true,
    link = true,
    meta = true,
    param = true,
    source = true,
    track = true,
    wbr = true,
}

-- Render attributes as string
local function render_attrs(tag, attrs)
    local result = {}
    -- Iterate directly over attrs if it's a table, otherwise use an empty table for `pairs`
    for k, v in pairs(attrs or {}) do
        -- Using `rawget` can sometimes be slightly faster than `Enums.has_attr`
        -- if Enums.has_attr is a simple table lookup.
        -- Assuming Enums.has_attr is efficient, keeping it for clarity.
        if Enums.has_attr(tag, k) then
            if v == true then
                -- String concatenation might be slightly faster than string.format for simple cases
                table.insert(result, k)
            else
                table.insert(result, k .. '="' .. escape_html(v) .. '"')
            end
        end
    end
    return table.concat(result, " ")
end

-- Render a single HTML element
local function render_element(node)
    -- Use table.unpack for direct assignment (Lua 5.2+) or local variables
    local tag = node.tag
    local attrs = node.attrs
    local children = node.children
    local content = node.content

    assert(type(node) == "table", "Each element must be a table.")

    -- Ignore '!--' tags by returning an empty string
    if tag == "!--" then
        return ""
    end

    -- Handle custom tags that are not valid HTML but should be rendered literally
    -- This applies to tags like 'project_name', 'model_name', etc., which are placeholders.
    if not Enums.is_valid_tag(tag) then
        local inner_content = ""
        if content then
            inner_content = content
        elseif children then
            for _, child in ipairs(children) do
                inner_content = inner_content .. Builder.render(child)
            end
        end

        -- If it's a custom tag, render it as <custom_tag>content</custom_tag>
        -- or <custom_tag> if it's empty, matching the original source HTML.
        if inner_content ~= "" then
            return "<" .. tostring(tag) .. ">" .. inner_content .. "</" .. tostring(tag) .. ">"
        else
            return "<" .. tostring(tag) .. ">"
        end
    end

    -- From this point onwards, 'tag' is guaranteed to be a valid HTML tag
    -- because the 'if not Enums.is_valid_tag(tag)' block handles invalid ones.
    -- The assert below is no longer strictly necessary but can remain for redundant checks.
    -- assert(Enums.is_valid_tag(tag), "Invalid tag: '" .. tostring(tag) .."'.")

    local attr_str = render_attrs(tag, attrs)
    local open_tag
    if attr_str ~= "" then
        open_tag = "<" .. tag .. " " .. attr_str .. ">"
    else
        open_tag = "<" .. tag .. ">"
    end

    -- Check against the pre-computed set for self-closing tags
    if SELF_CLOSING_TAGS[tag] then
        -- For self-closing tags, ensure consistency: always render with '/>'
        return "<" .. tag .. (attr_str ~= "" and " " .. attr_str or "") .. "/>"
    else
        local inner_content = {}
        -- If content exists, add it first
        if content then
            table.insert(inner_content, content)
        end
        -- Process children recursively
        if children then
            for _, child in ipairs(children) do
                table.insert(inner_content, Builder.render(child))
            end
        end
        -- Concatenate inner content only once
        local body = table.concat(inner_content, "")
        return open_tag .. body .. "</" .. tag .. ">"
    end
end

---
--  Core Rendering Functions

-- Main render entry
function Builder.render(node)
    -- Direct string rendering for text nodes
    if type(node) == "string" then
        return node
    elseif type(node) == "table" then
        -- Handle "text nodes" created by the parser (tables with content but no tag)
        if node.content and not node.tag then
            return node.content
        -- Handle "mustache" nodes
        elseif node.tag == "mustache" then
            -- If mustache content is empty, render as empty string to avoid {{}} or {{{}}}
            if node.content == "" then
                return ""
            elseif node.raw then
                return "{{{" .. node.content .. "}}}" -- Triple mustache for raw content
            else
                return "{{" .. node.content .. "}}" -- Double mustache for escaped content
            end
        end
        return render_element(node)
    else
        -- Handle unexpected types gracefully, perhaps by returning an empty string or erroring
        return "" -- Or error("Unsupported node type: " .. type(node))
    end
end

-- Convert to Mustache section
function Builder.mustache_section(name, nodes)
    assert(type(name) == "string" and #name > 0, "Section name must be a non-empty string.")
    local content_parts = {}
    for _, node in ipairs(nodes or {}) do
        table.insert(content_parts, Builder.render(node))
    end
    local section_content = table.concat(content_parts, "\n")
    return string.format("{{#%s}}\n%s\n{{/%s}}", name, section_content, name)
end

-- Wrap with layout
function Builder.layout(name, body)
    assert(type(name) == "string" and #name > 0, "Layout name must be a non-empty string.")
    -- Ensure body is a string, default to empty string if nil
    local layout_body = type(body) == "string" and body or ""
    return string.format("{{#%s}}%s{{/%s}}", name, layout_body, name)
end

---
-- ## Utility and Validation

-- Export helper
function Builder.export(node, name)
    local export_name = name or "section"
    local html = Builder.render(node)
    local mustache = Builder.mustache_section(export_name, {node})
    -- Check if dkjson is available before requiring to prevent errors if not present
    local json_module_ok, dkjson = pcall(require, "dkjson")
    local json_output = ""
    if json_module_ok and dkjson and dkjson.encode then
        json_output = dkjson.encode(node, { indent = true })
    else
        warn("dkjson module not found. JSON output will be empty.") -- Lua 5.3+ or custom warn function
    end

    return {
        html = html,
        mustache = mustache,
        json = json_output
    }
end

-- Validate tag/attributes/events with warnings
function Builder.validate(node, path)
    path = path or "root"
    local errors = {}

    if type(node) == "string" then return {} end -- Strings are valid leaf nodes

    -- Check for nil node or non-table node for clearer errors at the top level
    if not node or type(node) ~= "table" then
        table.insert(errors, string.format("[%s] Node is not a table. Received type: %s", path, type(node)))
        return errors
    end

    -- Skip validation for '!--' tags
    if node.tag == "!--" then
        -- Recursively validate children of comments if they contain other HTML structures
        if node.children then
            for i, child in ipairs(node.children) do
                local subpath = string.format("%s.children[%d]", path, i)
                -- Ensure child is a table or string before validating
                if type(child) ~= "table" and type(child) ~= "string" then
                    table.insert(errors, string.format("[%s] Child node is not a table or string. Received type: %s", subpath, type(child)))
                else
                    local child_errors = Builder.validate(child, subpath)
                    -- Extend the errors table with child errors
                    for _, e in ipairs(child_errors) do
                        table.insert(errors, e)
                    end
                end
            end
        end
        return errors -- Return early as we don't validate '!--' as a standard tag
    end

    -- Skip validation for 'mustache' tags
    if node.tag == "mustache" then
        return errors -- Mustache nodes are handled separately and don't need HTML tag validation
    end

    -- Skip validation for custom tags like 'project_name', 'model_name', etc.
    -- These are handled by render_element's new logic and don't need HTML validation here.
    if node.tag and not Enums.is_valid_tag(node.tag) then
        -- Recursively validate children of these custom tags if they contain other HTML structures
        if node.children then
            for i, child in ipairs(node.children) do
                local subpath = string.format("%s.children[%d]", path, i)
                if type(child) ~= "table" and type(child) ~= "string" then
                    table.insert(errors, string.format("[%s] Child node is not a table or string. Received type: %s", subpath, type(child)))
                else
                    local child_errors = Builder.validate(child, subpath)
                    for _, e in ipairs(child_errors) do
                        table.insert(errors, e)
                    end
                end
            end
        end
        return errors -- Return early as we don't validate these as standard tags
    end


    -- Validate tag presence and validity
    local tag = node.tag
    if not tag then
        table.insert(errors, string.format("[%s] Missing 'tag' property.", path))
    elseif not Enums.is_valid_tag(tag) then
        table.insert(errors, string.format("[%s] Invalid tag: '%s'", path, tostring(tag)))
    end

    -- Validate attributes
    if node.attrs then
        for k, _ in pairs(node.attrs) do
            -- Only check attributes if the tag itself is considered valid to avoid cascading errors
            if tag and Enums.is_valid_tag(tag) and not Enums.has_attr(tag, k) then
                table.insert(errors, string.format("[%s] Invalid attribute '%s' for tag <%s>", path, k, tag))
            end
        end
    end

    -- Recursively validate children
    if node.children then
        if type(node.children) ~= "table" then
            table.insert(errors, string.format("[%s] 'children' property must be a table. Received type: %s", path, type(node.children)))
        else
            for i, child in ipairs(node.children) do
                local subpath = string.format("%s.children[%d]", path, i)
                -- Ensure child is a table or string before validating
                if type(child) ~= "table" and type(child) ~= "string" then
                    table.insert(errors, string.format("[%s] Child node is not a table or string. Received type: %s", subpath, type(child)))
                else
                    local child_errors = Builder.validate(child, subpath)
                    -- Extend the errors table with child errors
                    for _, e in ipairs(child_errors) do
                        table.insert(errors, e)
                    end
                end
            end
        end
    end

    return errors
end

return Builder
