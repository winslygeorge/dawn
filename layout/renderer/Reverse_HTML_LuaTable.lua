-- HTML_Parser.lua
local Parser = {}

-- Helper to trim whitespace. Returns an empty string if the string is empty or only whitespace after trimming.
local function trim(s)
    if s == nil then return "" end -- Handle nil input by returning empty string
    local trimmed = s:match("^%s*(.-)%s*$")
    return trimmed or "" -- Ensure it always returns a string, even if match returns nil
end

-- Detect tag name and attributes from a string like "div id='myDiv' class='container'"
local function parse_tag_and_attrs(tag_str)
    local tag, attr_str = tag_str:match("^%s*(%S+)%s*(.-)%s*$")
    if not tag then return nil, nil end

    local attrs = {}
    -- Pattern to match attributes: key, optional '=', optional quote, value, matching quote
    -- Handles key="value", key='value', key=value (unquoted), and key (boolean)
    -- This pattern is robust for standard HTML attributes.
    -- For custom attributes within comments, a more specific parsing might be needed.
    for key, eq, val_start_quote, val_content, val_end_quote in attr_str:gmatch('([%w%-:]+)(%s*=?%s*)(["\']?)(.-)%3') do
        if trim(eq) == "=" then
            attrs[key] = val_content -- Value is already stripped of quotes by the pattern
        else
            attrs[key] = true -- Boolean attribute
        end
    end

    return tag, attrs
end

-- Self-closing HTML tags
local self_closing = {
    br=true, hr=true, img=true, input=true, meta=true, link=true,
    source=true, track=true, wbr=true, area=true, base=true, col=true, embed=true,
    param=true, command=true, keygen=true
}

-- Helper to process text chunks, identifying plain text and mustache tokens
-- and adding them as temporary nodes to the provided 'parent_node'.
local function process_and_add_text_nodes(text_chunk, parent_node)
    local last_pos = 1
    -- Pattern to capture both {{...}} and {{{...}}}
    -- It captures the full token, then we determine if it's raw or not.
    for match_start_pos, matched_token, match_end_pos in text_chunk:gmatch("()({%s*{?%s*.-%s*}?%s*})()") do
        -- Add preceding plain text
        if match_start_pos > last_pos then
            local plain_text = trim(text_chunk:sub(last_pos, match_start_pos - 1))
            if plain_text ~= "" then -- Only add if not empty
                table.insert(parent_node.children, { type = "text", value = plain_text })
            end
        end

        -- Process the mustache token
        local content_match = nil
        local raw = false

        -- Check for {{{...}}} (raw mustache) using matched_token
        if matched_token:match("^{%s*{%s*(.-)%s*}%s*}$") then
            content_match = matched_token:match("^{%s*{%s*(.-)%s*}%s*}$")
            raw = true
        -- Check for {{...}} (regular mustache)
        elseif matched_token:match("^{%s*(.-)%s*}$") then
            content_match = matched_token:match("^{%s*(.-)%s*}$")
        end

        local trimmed_content = trim(content_match)
        table.insert(parent_node.children, { type = "mustache", content = trimmed_content, raw = raw })

        last_pos = match_end_pos + 1 -- Update last_pos using match_end_pos
    end

    -- Add any remaining text after the last token
    if last_pos <= #text_chunk then
        local remaining_text = trim(text_chunk:sub(last_pos))
        if remaining_text ~= "" then -- Only add if not empty
            table.insert(parent_node.children, { type = "text", value = remaining_text })
        end
    end
end

-- Helper to finalize a node's children:
-- - If all children are text/mustache, combine into 'content' string and remove 'children'.
-- - Otherwise, convert temporary text/mustache nodes to their final structure.
-- - Recursively calls itself for child tag nodes.
local function finalize_node_content(node)
    if not node.children or #node.children == 0 then
        node.children = nil -- No children, remove the empty table for cleaner output
        return
    end

    local all_text_or_mustache = true
    local combined_content_parts = {} -- To build the content string if applicable

    for i, child in ipairs(node.children) do
        if child.type == "text" then
            table.insert(combined_content_parts, child.value)
        elseif child.type == "mustache" then
            -- Reconstruct original mustache syntax for the 'content' string
            table.insert(combined_content_parts, (child.raw and "{{{" or "{{") .. child.content .. (child.raw and "}}}" or "}}"))
        else -- It's a real tag node, so this node must use 'children' array
            all_text_or_mustache = false
            -- Recursively finalize its children
            finalize_node_content(child)
        end
    end

    if all_text_or_mustache then
        node.content = table.concat(combined_content_parts)
        node.children = nil -- If all were text/mustache, use 'content' and remove 'children'
    else
        -- If mixed content (text/mustache and tags), convert the temporary text/mustache nodes
        -- within the children array to their final format.
        for i, child in ipairs(node.children) do
            if child.type == "text" then
                node.children[i] = { content = child.value }
            elseif child.type == "mustache" then
                node.children[i] = { tag = "mustache", content = child.content }
                if child.raw then node.children[i].raw = true end
            end
        end
    end
end

-- Core recursive parsing function for an HTML segment
-- Returns a list of parsed nodes
local function parse_html_segment(html_segment)
    local segment_nodes = {}
    -- Dummy parent node to collect top-level nodes of this segment
    local segment_root_dummy = { children = segment_nodes }
    local segment_stack = { segment_root_dummy }
    local segment_current_node = segment_root_dummy

    local segment_i = 1
    while segment_i <= #html_segment do
        local next_open_segment = html_segment:find("<", segment_i)

        if not next_open_segment then
            -- No more tags, process remaining text
            local text = html_segment:sub(segment_i)
            process_and_add_text_nodes(text, segment_current_node)
            break
        end

        -- Text before tag
        if next_open_segment > segment_i then
            local text = html_segment:sub(segment_i, next_open_segment - 1)
            process_and_add_text_nodes(text, segment_current_node)
        end

        local tag_start_check = html_segment:sub(next_open_segment + 1, next_open_segment + 3)

        -- Special handling for HTML comments (<!-- ... -->)
        if tag_start_check == "!--" then
            local comment_end_idx = html_segment:find("-->", next_open_segment + 4)
            if comment_end_idx then
                local comment_content_raw = html_segment:sub(next_open_segment + 4, comment_end_idx - 1)

                local comment_node = { tag = "!--", attrs = {}, children = {} }
                table.insert(segment_current_node.children, comment_node)

                -- Custom attribute parsing from the beginning of the comment content
                -- This is a heuristic based on the example output's structure for comments.
                local current_content_pos = 1
                local temp_comment_attrs = {}

                while true do
                    local key_match_start, key_match_end = comment_content_raw:find('^%s*([%w%-:]+)', current_content_pos)
                    if not key_match_start then break end -- No more keys found

                    local current_key = comment_content_raw:sub(key_match_start, key_match_end)
                    local after_key_pos = key_match_end + 1

                    local eq_match_start, eq_match_end = comment_content_raw:find('^%s*=', after_key_pos)

                    if eq_match_start then -- Has an equals sign, so it's key=value
                        local val_match_start, val_match_end, val_content_actual = comment_content_raw:find('^%s*["\']?(.-)["\']?', eq_match_end + 1)
                        if val_match_start then
                            temp_comment_attrs[current_key] = val_content_actual
                            current_content_pos = val_match_end + 1
                        else
                            break -- Malformed value, stop parsing attributes
                        end
                    else -- Boolean attribute
                        temp_comment_attrs[current_key] = true
                        current_content_pos = key_match_end + 1
                    end
                end
                comment_node.attrs = temp_comment_attrs

                -- The remaining content after attributes is itself HTML that needs parsing
                local remaining_html_for_comment = comment_content_raw:sub(current_content_pos)
                local parsed_comment_children = parse_html_segment(remaining_html_for_comment)
                for _, child in ipairs(parsed_comment_children) do
                    table.insert(comment_node.children, child)
                end

                segment_i = comment_end_idx + 3 -- Advance past '-->'
            else
                -- Malformed comment (no closing '-->'), treat as plain text
                local text = html_segment:sub(next_open_segment)
                process_and_add_text_nodes(text, segment_current_node)
                segment_i = #html_segment + 1 -- End loop
            end
        else -- Standard HTML tag
            local next_close_segment = html_segment:find(">", next_open_segment)
            if not next_close_segment then
                -- Malformed HTML, tag opened but not closed. Process remaining as text.
                local text = html_segment:sub(next_open_segment)
                process_and_add_text_nodes(text, segment_current_node)
                segment_i = #html_segment + 1 -- End loop
                break
            end

            local tag_full_segment = html_segment:sub(next_open_segment + 1, next_close_segment - 1)
            local is_closing_segment = tag_full_segment:match("^/")
            local is_self_closing_syntax = tag_full_segment:match("/%s*$") -- e.g., <br/> or <img src="x"/>

            if is_closing_segment then
                local tag_name = tag_full_segment:match("^/%s*(%S+)")
                -- Pop from stack if matching tag found and not the dummy root
                if tag_name and #segment_stack > 1 and segment_stack[#segment_stack].tag == tag_name then
                    local completed_node = table.remove(segment_stack)
                    segment_current_node = segment_stack[#segment_stack] -- Move up to parent node
                    finalize_node_content(completed_node) -- Finalize children for this node
                -- else: Mismatch or trying to close dummy root, ignore or handle error
                end
                segment_i = next_close_segment + 1
            else -- Opening tag
              local tag, attrs = parse_tag_and_attrs(tag_full_segment:gsub("/%s*$", ""))
if tag then
    local remaining_html = html_segment:sub(next_close_segment + 1)
    local closing_tag_pattern = "</%s*" .. tag .. "%s*>"
    local has_closing = remaining_html:find(closing_tag_pattern)

    local is_html_self_closing = is_self_closing_syntax or self_closing[tag]

    if not has_closing and not is_html_self_closing and tag ~= "!--" then
        -- No closing tag: treat this as raw passthrough
        local raw_node = { content = "<" .. tag_full_segment .. ">" }
        table.insert(segment_current_node.children, raw_node)
        segment_i = next_close_segment + 1
    else
        local node = { tag = tag, attrs = attrs, children = {} }
        table.insert(segment_current_node.children, node)

        if not is_html_self_closing then
            table.insert(segment_stack, node)
            segment_current_node = node
        else
            finalize_node_content(node)
        end
        segment_i = next_close_segment + 1
    end
end

                segment_i = next_close_segment + 1
            end
        end
    end

    -- After the main loop, finalize any remaining open nodes in the segment stack
    -- This handles cases where tags might not have been properly closed at the end of the segment.
    while #segment_stack > 1 do -- Keep the dummy root, remove others
        local node_to_finalize = table.remove(segment_stack)
        finalize_node_content(node_to_finalize)
    end
    return segment_nodes
end

-- Main Parser.parse function (wrapper)
function Parser.parse(html)
    -- Parse the entire HTML string as a segment
    local root_children = parse_html_segment(html)

    -- Wrap the result in the top-level 'html' tag as per the example output format
    -- local root_node = { tag = "div", children = root_children }

    -- Finalize the top-level html node's children (e.g., combining text/mustache if it was only that)
    finalize_node_content(root_children)

    return root_children
end

function Parser.export(parsed_html_table)
    local serpent = require('serpent')

    local output_filename = "./lib/exported_html_data.lua"
    if parsed_html_table then
        local file_content = "return {children = " .. serpent.block(parsed_html_table, {
            indent = "  ",
            sortkeys = false,
            comment = false,
            name = nil
        }).. "}"

        local file, err = io.open(output_filename, "w")
        if file then
            file:write(file_content)
            file:close()
            print("\nExported Lua table to: " .. output_filename)
            print("You can now load this table in another Lua script like: local data = require(\"exported_html_data\")")
        else
            print("\nError exporting file: " .. err)
        end
    else
        print("\nSkipping file export: No Lua table to export.")
    end
end


return Parser



