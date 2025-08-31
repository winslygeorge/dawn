-- css_helper.lua

-- It's good practice to define external dependencies clearly.
-- Assuming 'auth.sha256' exists and provides a sha256_hex function.
local sha256 = require("auth.sha256")

local css_helper = {}

-- Define a constant for units to make it easier to manage
local DEFAULT_UNIT = "px"

-- Properties that typically require a unit when a number is provided.
-- Using a set (table with boolean values) for O(1) lookup performance.
local css_properties_with_units = {
    width = true, height = true, top = true, left = true, right = true, bottom = true,
    margin = true, marginTop = true, marginBottom = true, marginLeft = true, marginRight = true,
    padding = true, paddingTop = true, paddingBottom = true, paddingLeft = true, paddingRight = true,
    fontSize = true, borderWidth = true, borderRadius = true,
    maxWidth = true, maxHeight = true, minWidth = true, minHeight = true,
    flexBasis = true, gap = true, rowGap = true, columnGap = true,
    outlineWidth = true,
}

local palettes = {
    light = { primary = "#007bff", text = "#333", background = "#fff" },
    dark = { primary = "#6610f2", text = "#eee", background = "#333" }
}
local current_palette = palettes.light -- Default


function css_helper.get_builtin_palette(name)
    return palettes[name] or palettes.light
end

-- Helper function to check if a property typically requires a unit.
local function has_unit_property(prop)
    return css_properties_with_units[prop] == true
end

-- Converts camelCase to kebab-case (e.g., "fontSize" to "font-size").
local function to_kebab_case(str)
    -- The pattern `%u` matches uppercase characters.
    -- The function replaces each uppercase character with a hyphen followed by its lowercase version.
    return str:gsub("%u", function(c) return "-" .. c:lower() end)
end

-- Formats a CSS property value based on its type and property name.
local function format_value(prop_camel_case, val)
    -- If it's a number and the property needs a unit, append the default unit.
    if type(val) == "number" and has_unit_property(prop_camel_case) then
        return tostring(val) .. DEFAULT_UNIT
    end
    -- If it's a table, concatenate its elements with spaces. Useful for 'font' shorthand.
    if type(val) == "table" then
        return table.concat(val, " ")
    end
    -- Handle boolean values, converting them to "true" or "false" strings.
    -- (Less common for standard CSS values, but useful for custom properties or boolean attributes).
    if type(val) == "boolean" then
        return val and "true" or "false"
    end
    -- Handle palette references (e.g., "@primary").
    -- It tries to resolve the key from `_palette`; otherwise, it returns the original value.
    if type(val) == "string" and val:sub(1, 1) == "@" then
        local key = val:sub(2)
        -- Ensure _palette is initialized before accessing it.
        return css_helper._palette and css_helper._palette[key] or val
    end
    -- For all other types (strings, etc.), convert to string.
    return tostring(val)
end

--- Converts a Lua table representing CSS styles into an inline CSS string.
-- @param tbl table A table where keys are CSS property names (camelCase) and values are property values.
-- @return string An inline CSS string (e.g., "width: 100px; color: red;").
function css_helper.style_to_inline(tbl)
    local props = {}
    -- Iterate through the table, format each property and value, and add to `props`.
    for k, v in pairs(tbl) do
        local prop_kebab = to_kebab_case(k) -- Convert property name to kebab-case.
        local val_formatted = format_value(k, v) -- Format the value, passing original camelCase key.
        table.insert(props, string.format("%s: %s", prop_kebab, val_formatted))
    end
    -- Join all formatted properties with a semicolon and space.
    return table.concat(props, "; ")
end

-- Hashes a Lua table to generate a short, unique identifier.
-- This is used for generating consistent class names based on style content.
-- Handles nested tables for more robust hashing.
local function hash_table(tbl)
    local function serialize_value(val)
        if type(val) == "table" then
            if getmetatable(val) and getmetatable(val).__tostring then
                -- If it has a __tostring metamethod, use it (e.g., for Lua objects)
                return tostring(val)
            end
            -- For generic tables, recursively serialize
            local inner_parts = {}
            local inner_keys = {}
            for k_inner, _ in pairs(val) do table.insert(inner_keys, k_inner) end
            table.sort(inner_keys)
            for _, k_inner in ipairs(inner_keys) do
                table.insert(inner_parts, tostring(k_inner) .. "=" .. serialize_value(val[k_inner]))
            end
            return "{" .. table.concat(inner_parts, ";") .. "}"
        elseif type(val) == "boolean" then
            return val and "true" or "false"
        else
            return tostring(val)
        end
    end

    local keys = {}
    for k, _ in pairs(tbl) do table.insert(keys, k) end
    table.sort(keys) -- Sort keys for consistent hashing.

    local parts = {}
    for _, k in ipairs(keys) do
        table.insert(parts, tostring(k) .. "=" .. serialize_value(tbl[k]))
    end
    local concatenated = table.concat(parts, ";")
    -- Generate SHA256 hash and take the first 8 characters for a compact ID.
    local hash = sha256.sha256_hex(concatenated)
    return hash:sub(1, 8)
end

-- Initialize internal state for CSS helper.
-- `_styles` now stores *already rendered CSS strings* mapped by class name.
css_helper._styles = {}
css_helper._palette = {}
css_helper._text_theme = {}
css_helper._theme_mode = "light" -- Current theme mode (e.g., "light" or "dark").

--- Sets the global CSS palette.
-- @param tbl table A table representing the palette (e.g., `{primary = "#007bff"}`).
function css_helper.set_palette(tbl)
    assert(type(tbl) == "table", "Palette must be a table.")
    css_helper._palette = tbl or current_palette
end

--- Sets the global text themes.
-- @param tbl table A table representing text themes (e.g., `{h1 = {fontSize = 24}}`).
function css_helper.set_text_theme(tbl)
    assert(type(tbl) == "table", "Text theme must be a table.")
    css_helper._text_theme = tbl or {}
end

--- Sets the current theme mode.
-- @param mode string The theme mode (e.g., "light", "dark").
function css_helper.set_theme_mode(mode)
    assert(type(mode) == "string" and #mode > 0, "Theme mode must be a non-empty string.")
    css_helper._theme_mode = mode
end

--- Retrieves and resolves a predefined text theme.
-- @param name string The name of the text theme.
-- @return table A table of resolved CSS properties for the text theme.
function css_helper.use_text_theme(name)
    assert(type(name) == "string" and #name > 0, "Text theme name must be a non-empty string.")
    local theme = css_helper._text_theme[name]
    assert(theme, "Text theme '" .. name .. "' not found.")
    local resolved = {}
    -- Format each value in the theme.
    for k, v in pairs(theme) do
        resolved[k] = format_value(k, v)
    end
    return resolved
end

--- Creates a media query string.
-- @param str string The media query condition (e.g., "(min-width: 640px)").
-- @return string The full media query string (e.g., "@media (min-width: 640px)").
function css_helper.media_query(str)
    assert(type(str) == "string" and #str > 0, "Media query string must be non-empty.")
    return "@media " .. str
end

-- Predefined media query breakpoints (functions to allow dynamic generation if needed).
css_helper.media = {
    sm = function() return css_helper.media_query("(min-width: 640px)") end,
    md = function() return css_helper.media_query("(min-width: 768px)") end,
    lg = function() return css_helper.media_query("(min-width: 1024px)") end,
    xl = function() return css_helper.media_query("(min-width: 1280px)") end,
    ["2xl"] = function() return css_helper.media_query("(min-width: 1536px)") end,
    query = css_helper.media_query -- Allow custom media queries.
}

local MAX_RECURSION_DEPTH = 30 -- Safeguard for deeply nested styles.

--- Recursively resolves nested CSS styles.
-- This function handles nested selectors, at-rules, and property-value pairs.
-- @param styles table The current styles table block to process.
-- @param parent_selector string The accumulated parent selector (e.g., ".my-class > div").
-- @param acc table The accumulator table for resolved flattened styles.
-- @param depth number Current recursion depth to prevent infinite loops.
-- @return table The accumulated and resolved styles (flattened `acc` table).
local function resolve_nested_styles(styles, parent_selector, acc, depth)
    acc = acc or {}
    depth = depth or 0
    parent_selector = parent_selector or ""

    if depth > MAX_RECURSION_DEPTH then
        error("Max recursion depth reached in resolve_nested_styles. This may indicate a circular reference or overly complex nesting.")
    end

    for key, value in pairs(styles) do
        if type(value) ~= "table" then
            -- This is a CSS property-value pair. Add it to the current parent selector.
            acc[parent_selector] = acc[parent_selector] or {}
            acc[parent_selector][key] = value -- `key` is the CSS property name, `value` is its value
        else -- `value` is a table, so `key` must be a nested selector or an at-rule
            if key:sub(1, 1) == "@" then
                -- This is an at-rule (e.g., @media, @keyframes)
                local at_rule_block = acc[key] or {}
                -- Recursively resolve styles inside the at-rule.
                -- Crucially, the `parent_selector` is passed down, meaning inner rules
                -- will still be scoped relative to the original parent.
                local inner_resolved_styles = resolve_nested_styles(value, parent_selector, {}, depth + 1)
                for sel, props_tbl in pairs(inner_resolved_styles) do
                    at_rule_block[sel] = at_rule_block[sel] or {}
                    -- Merge properties from recursive call
                    for p, v in pairs(props_tbl) do
                        at_rule_block[sel][p] = v
                    end
                end
                acc[key] = at_rule_block
            else
                -- This is a nested selector (e.g., "&:hover", ".child", "h1", "div")
                local full_selector
                if parent_selector == "" then
                    full_selector = key
                else
                    if key:sub(1, 1) == "&" then
                        -- Handle SASS-like parent reference (&)
                        full_selector = parent_selector .. key:sub(2) -- Remove the ampersand
                    else
                        -- Default to descendant selector if no ampersand
                        full_selector = parent_selector .. " " .. key
                    end
                end

                if #full_selector > 2000 then
                    error("Selector too long: " .. full_selector:sub(1, 100) .. "...")
                end

                -- Recursively resolve styles for the concatenated selector.
                -- The results are merged into the main accumulator.
                resolve_nested_styles(value, full_selector, acc, depth + 1)
            end
        end
    end
    return acc
end

--- Renders a Lua table of styles (potentially nested) into a flat CSS string.
-- This is the core function for converting the Lua style structure into actual CSS.
-- @param style_table table The table of styles to render. Can contain nested selectors and at-rules.
-- @param minified boolean If true, the output CSS will be minified (default: false).
-- @return string The generated CSS string.
function css_helper.render_styles(style_table, minified)
    minified = minified or false -- Default to not minified
    local flat_styles = {} -- Will hold { selector = { prop = val, ... }, ... }

    -- Step 1: Flatten the input style_table using the recursive resolver
    for selector_or_prop, rules_or_value in pairs(style_table) do
        if type(rules_or_value) == "table" then
            -- This is a top-level selector or at-rule
            local resolved_block = resolve_nested_styles({[selector_or_prop] = rules_or_value})
            for sel, props_tbl in pairs(resolved_block) do
                flat_styles[sel] = flat_styles[sel] or {}
                for prop, val in pairs(props_tbl) do
                    flat_styles[sel][prop] = val -- Merge properties
                end
            end
        else
            -- This is a direct property-value pair for the "root" or unnamed selector.
            -- This applies to styles not explicitly under a selector (e.g., `:root { --var: val; }`).
            flat_styles[""] = flat_styles[""] or {}
            flat_styles[""][selector_or_prop] = rules_or_value
        end
    end

    local css_chunks = {} -- Stores individual CSS rule blocks.
    local indent = minified and "" or "  " -- Indentation for pretty printing.
    local newline = minified and "" or "\n" -- Newline for pretty printing.
    local space = minified and "" or " " -- Space for pretty printing.

    -- Step 2: Render the flattened styles into CSS string chunks
    -- Sort selectors for consistent output, important for caching and diffing.
    local selectors = {}
    for sel, _ in pairs(flat_styles) do table.insert(selectors, sel) end
    table.sort(selectors)

    for _, selector in ipairs(selectors) do
        local rules = flat_styles[selector]
        if selector:sub(1, 1) == "@" then
            -- Handle at-rules (e.g., `@media`, `@keyframes`).
            -- Recursively call render_styles for the inner rules of the at-rule.
            local inner_css = css_helper.render_styles(rules, minified)
            table.insert(css_chunks, selector .. space .. "{" .. newline .. inner_css .. newline .. "}")
        else
            -- Process regular CSS rules (selectors like ".class", "#id", "div", or "" for root).
            local props_list = {}
            local props_keys = {}
            for k, _ in pairs(rules) do table.insert(props_keys, k) end
            table.sort(props_keys) -- Sort properties for consistent output.

            for _, k in ipairs(props_keys) do
                local prop_kebab = to_kebab_case(k)
                local val_formatted = format_value(k, rules[k]) -- Pass original camelCase key `k`
                table.insert(props_list, indent .. prop_kebab .. ":" .. space .. val_formatted .. ";")
            end

            -- Assemble the CSS block for the current selector.
            if #props_list > 0 then -- Only add if there are properties.
                if selector == "" then
                    -- For the root/unnamed selector, just output the properties directly
                    table.insert(css_chunks, table.concat(props_list, newline))
                else
                    table.insert(css_chunks, selector .. space .. "{" .. newline .. table.concat(props_list, newline) .. newline .. "}")
                end
            end
        end
    end

    -- Step 3: Join all CSS chunks. Add an extra newline between blocks for readability when not minified.
    return table.concat(css_chunks, newline .. (minified and "" or "\n"))
end


--- Generates a class name based on the style content and renders the associated styles into a CSS string.
-- This function is used to create unique scoped CSS classes, and directly provides the CSS content
-- for injection into the page's <head> (e.g., by HTMLReactive.App).
-- @param tbl table A table of CSS properties for the class. This table can contain nested selectors.
-- @param scope_id string An optional scope ID to prefix the generated class name (e.g., "c123").
-- @return table A table containing:
--   - `class` string: The generated CSS class name (e.g., "scoped-c123-abc12345").
--   - `css_content` string: The CSS rules for this class, including nested rules, formatted as a string.
function css_helper.style_to_class(tbl, scope_id)
    assert(type(tbl) == "table", "Style table must be a table.")
    assert(not scope_id or type(scope_id) == "string", "Scope ID must be a string or nil.")

    local hash = hash_table(tbl)
    local class_name = (scope_id and scope_id .. "-") .. "c" .. hash

    -- Construct the style table for rendering, ensuring the generated class is the root selector.
    -- All properties and nested rules from `tbl` become children of this generated class.
    local class_styles_for_rendering = {
        ["." .. class_name] = tbl
    }

    -- Render *only* the CSS for this specific class.
    local rendered_css = css_helper.render_styles(class_styles_for_rendering)

    -- Store the *rendered CSS string* internally for potential future use (e.g., by `render_with_styles`).
    css_helper._styles[class_name] = rendered_css

    return {
        class = class_name,
        css_content = rendered_css -- Return the CSS content string directly for global collection.
    }
end

--- Renders HTML with dynamically generated styles injected into a `<style>` tag.
-- This function is primarily used for non-HTMLReactive rendering pipelines (e.g., Lustache, HTMLBuilder)
-- where the component produces a raw HTML string and its styles need to be embedded.
-- It collects all *already rendered* CSS strings stored internally by `style_to_class`.
-- @param html string The HTML content produced by the component.
-- @param minified boolean If true, the generated CSS will be minified (default: false).
-- @param scope_id string An optional scope ID to filter which stored styles are rendered.
--   If provided, only styles whose generated class name starts with `scope_id` will be included.
-- @return string The HTML string with the embedded `<style>` block.
function css_helper.render_with_styles(html, minified, scope_id)
    minified = minified or false
    local all_rendered_css = {}
    -- Iterate through all stored *rendered* styles.
    for class_name, rendered_css_str in pairs(css_helper._styles) do
        -- If a `scope_id` is provided, only include styles that belong to that scope.
        if not scope_id or class_name:sub(1, #scope_id) == scope_id then
            table.insert(all_rendered_css, rendered_css_str)
        end
    end

    -- Combine all relevant rendered CSS strings
    -- Use a single newline for minified to keep it compact, double for non-minified for readability.
    local combined_css = table.concat(all_rendered_css, minified and "\n" or "\n\n")

    if combined_css ~= "" then
        -- Embed the combined CSS into a <style> tag.
        return html .. "\n<style>" .. (minified and "" or "\n") .. combined_css .. (minified and "" or "\n") .. "</style>"
    end
    return html -- No styles to inject, return original HTML
end

--- A utility function to test the `format_value` function.
-- @param style_tbl table A table of styles to test.
-- @return boolean, string True if all values can be formatted, false and an error message otherwise.
function css_helper.test(style_tbl)
    local ok, err = pcall(function()
        for k, v in pairs(style_tbl) do
            format_value(k, v) -- Test formatting for each property-value pair.
        end
    end)
    return ok, err
end

return css_helper