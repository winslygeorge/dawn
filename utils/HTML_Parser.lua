-- utils/html_parser.lua
-- A helper module to convert well-formed HTML strings into Lua table structures
-- compatible with HTMLBuilder.
--
-- IMPORTANT: This is a regex-based parser and has limitations.
-- It works best with clean, properly nested HTML.
-- It does NOT handle malformed HTML, complex script parsing, or browser-level DOM nuances.

local M = {}

-- Regular expressions for parsing HTML components
local TAG_REGEX = "^<([a-zA-Z0-9_%-]+)([^>]*)>(.*)</%1>$" -- For full tags with content (3 capture groups)
local SELF_CLOSING_TAG_REGEX = "^<([a-zA-Z0-9_%-]+)([^>]*)/>$" -- For self-closing tags (2 capture groups)
local ATTR_REGEX = '([a-zA-Z0-9_%-]+)(?:="([^"]*)")?' -- For attributes: name="value" or just name
local OPENING_TAG_REGEX = "^<([a-zA-Z0-9_%-]+)([^>]*)>" -- For any opening tag

-- Helper function to trim whitespace
local function trim(s)
    if not s then return nil end -- Handle potential nil input
    return s:match("^%s*(.-)%s*$")
end

-- Helper to parse attributes string into a table
local function parse_attributes(attr_string)
    local attrs = {}
    for name, value in (attr_string or ""):gmatch(ATTR_REGEX) do -- Ensure attr_string is not nil
        if value then
            attrs[name] = value
        else
            attrs[name] = true -- Boolean attribute (e.g., 'selected', 'disabled')
        end
    end
    return attrs
end

-- Define self-closing tags for the parser's internal use
local SELF_CLOSING_TAGS = {
  br = true, hr = true, img = true, input = true, area = true, base = true,
  col = true, embed = true, keygen = true, link = true, meta = true,
  param = true, source = true, track = true, wbr = true,
}

---
-- Recursively parses an HTML string into an HTMLBuilder-compatible Lua table.
-- @param html_string string The HTML string to parse.
-- @return table|string A Lua table representing the HTML structure, or a string if it's plain text.
local function parse_html_recursive(html_string)
    html_string = trim(html_string)
    if html_string == "" then return nil end

    -- Check for comments and remove them
    html_string = html_string:gsub("", "")

    -- Try to match a self-closing tag first
    local tag_name_self_closing, attrs_str_self_closing = html_string:match(SELF_CLOSING_TAG_REGEX)
    if tag_name_self_closing then
        return {
            tag = tag_name_self_closing,
            attrs = parse_attributes(attrs_str_self_closing)
        }
    end

    -- Try to match a full opening and closing tag
    -- CORRECTED LINE: Matching the 3 capture groups from TAG_REGEX
    local tag_name, attrs_str, content_between_tags = html_string:match(TAG_REGEX)
    if tag_name then -- Check if a full tag was matched
        local node = {
            tag = tag_name,
            attrs = parse_attributes(attrs_str),
            children = {},
            content = nil -- Will be set if it's plain text content
        }

        local cursor = 1
        local content_parts = {}

        -- Loop to find child elements or text content
        -- Line 69 (now referencing 'content_between_tags')
        while cursor <= #content_between_tags do
            local current_substring = content_between_tags:sub(cursor)
            local tag_start_idx = current_substring:find("<")

            if tag_start_idx then
                -- Add any plain text content before the next tag
                local text_content = trim(current_substring:sub(1, tag_start_idx - 1))
                if text_content ~= "" then
                    table.insert(content_parts, text_content)
                end

                -- Find the extent of the next element
                local matched_tag_type, matched_tag_name = current_substring:match(OPENING_TAG_REGEX)
                if matched_tag_type then
                    local end_idx = 0
                    if SELF_CLOSING_TAGS[matched_tag_type] then
                        -- It's a self-closing tag, just find its end
                        end_idx = current_substring:find("/>", tag_start_idx) + 1
                    else
                        -- It's an opening tag, find its matching closing tag
                        local balance = 0
                        local current_pos = tag_start_idx
                        while current_pos <= #current_substring do
                            local char = current_substring:sub(current_pos, current_pos)
                            if char == '<' then
                                local potential_open_tag_name = current_substring:sub(current_pos):match("^<([a-zA-Z0-9_%-]+)")
                                if potential_open_tag_name and potential_open_tag_name == matched_tag_type then
                                    balance = balance + 1
                                elseif potential_open_tag_name and current_substring:sub(current_pos, current_pos + 1) == "</" then
                                    local potential_close_tag_name = current_substring:sub(current_pos + 2):match("^([a-zA-Z0-9_%-]+)")
                                    if potential_close_tag_name and potential_close_tag_name == matched_tag_type then
                                        balance = balance - 1
                                    end
                                end
                            end

                            if balance == 0 then
                                end_idx = current_pos
                                break
                            end
                            current_pos = current_pos + 1
                        end
                    end

                    if end_idx > 0 then
                        local child_html = current_substring:sub(tag_start_idx, end_idx)
                        local parsed_child = parse_html_recursive(child_html)
                        if parsed_child then
                            table.insert(node.children, parsed_child)
                        end
                        cursor = cursor + end_idx - 1
                    else
                        -- Couldn't find a matching end for a tag, treat remaining as text
                        local remaining_text = trim(current_substring:sub(tag_start_idx))
                        if remaining_text ~= "" then
                           table.insert(content_parts, remaining_text)
                        end
                        cursor = #content_between_tags + 1 -- Exit loop
                    end
                else
                    -- No valid tag found at tag_start_idx, treat as text
                    local remaining_text = trim(current_substring:sub(tag_start_idx))
                    if remaining_text ~= "" then
                        table.insert(content_parts, remaining_text)
                    end
                    cursor = #content_between_tags + 1 -- Exit loop
                end
            else
                -- No more tags, treat remaining as text content
                local remaining_text = trim(current_substring)
                if remaining_text ~= "" then
                    table.insert(content_parts, remaining_text)
                end
                cursor = #content_between_tags + 1 -- Exit loop
            end
        end

        -- If we have children, any extracted plain text content also becomes a child string
        if #node.children > 0 then
            for _, part in ipairs(content_parts) do
                table.insert(node.children, part)
            end
        else
            -- If no child tables, then all content is plain text
            node.content = table.concat(content_parts, "")
            node.children = nil -- Clear children if it's purely content
        end
        return node
    else
        -- If neither self-closing nor full tag matched, it's just a text string
        return html_string
    end
end


---
-- Converts a complex HTML string into an HTMLBuilder-compatible Lua table structure.
-- This function is a wrapper for the recursive parser.
-- @param html_string string The HTML string to convert.
-- @return table A Lua table representing the parsed HTML.
function M.from_html_string(html_string)
    if not html_string or type(html_string) ~= "string" then
        return nil, "Input is not a string."
    end
    -- Normalize whitespace around tags for easier parsing
    html_string = html_string:gsub(">\n%s*<", "><")
    html_string = html_string:gsub("%s*/>", "/>")
    html_string = html_string:gsub("%s*>", ">")
    html_string = html_string:gsub("<%s*", "<")

    -- Wrap the entire HTML in a dummy div to ensure it's a single root element for parsing
    -- This helps handle cases where the input HTML has multiple root elements.
    local wrapped_html = "<div>" .. html_string .. "</div>"
    local parsed_root = parse_html_recursive(wrapped_html)

    -- Corrected Line 195: Check if parsed_root.children exists before getting its length
    if parsed_root and parsed_root.tag == "div" and parsed_root.children and #parsed_root.children == 1 then
        return parsed_root.children[1]
    end
    return parsed_root
end

return M