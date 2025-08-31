-- query_filter_parser.lua
-- Converts Dawn req.query table into normalized patch filters with multi, wildcard, and NOT support

local function parseQueryFilters(query)
  query = query or {}
  local filters = {}

  -- Multi-component support: ?component=chat,log,user
  if query.component and query.component ~= "" then
    local comps = {}
    for c in tostring(query.component):gmatch("[^,]+") do
      table.insert(comps, c)
    end
    filters.component = comps
  end

  -- Negative component filter: ?not_component=internal,debug
  if query.not_component and query.not_component ~= "" then
    local not_comps = {}
    for c in tostring(query.not_component):gmatch("[^,]+") do
      table.insert(not_comps, c)
    end
    filters.not_component = not_comps
  end

  -- Allow wildcard-style path pattern: ?path=root.children.*
  if query.path and query.path ~= "" then
    local raw = tostring(query.path)
    local lua_pattern = raw:gsub("%%", "%%%%")
                         :gsub("%*", ".-")
                         :gsub("%[", "%%[")
                         :gsub("%]", "%%]")
    filters.path = lua_pattern
  end

  -- Negative path pattern: ?not_path=root.debug.*
  if query.not_path and query.not_path ~= "" then
    local raw = tostring(query.not_path)
    local lua_pattern = raw:gsub("%%", "%%%%")
                         :gsub("%*", ".-")
                         :gsub("%[", "%%[")
                         :gsub("%]", "%%]")
    filters.not_path = lua_pattern
  end

  return filters
end

return parseQueryFilters
