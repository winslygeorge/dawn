local Enums = {}

-- HTML5 tag names
Enums.Tags = {
  "html", "head", "title", "base", "link", "meta", "style", "script", "noscript",
  "body", "section", "nav", "article", "aside", "h1", "h2", "h3", "h4", "h5", "h6",
  "header", "footer", "address", "main", "p", "hr", "pre", "blockquote", "ol", "ul", "li",
  "dl", "dt", "dd", "figure", "figcaption", "div", "a", "em", "strong", "small", "s", "cite",
  "q", "dfn", "abbr", "ruby", "rt", "rp", "data", "time", "code", "var", "samp", "kbd",
  "sub", "sup", "i", "b", "u", "mark", "bdi", "bdo", "span", "br", "wbr", "ins", "del",
  "img", "iframe", "embed", "object", "param", "video", "audio", "source", "track", "canvas",
  "map", "area", "svg", "math", "table", "caption", "colgroup", "col", "tbody", "thead",
  "tfoot", "tr", "td", "th", "form", "label", "input", "button", "select", "datalist",
  "optgroup", "option", "textarea", "output", "progress", "meter", "fieldset", "legend",
  "details", "summary", "dialog", "script", "noscript", "template", "slot", "portal"
}

-- Global attributes (shared across tags)
Enums.GlobalAttributes = {
  "id", "class", "style", "title", "lang", "dir", "hidden",
  "tabindex", "accesskey", "draggable", "contenteditable", "spellcheck", "role", "data-*"
}

-- WAI-ARIA attributes
Enums.AriaAttributes = {
  "aria-label", "aria-labelledby", "aria-hidden", "aria-describedby", "aria-expanded",
  "aria-controls", "aria-current", "aria-disabled", "aria-live", "aria-pressed",
  "aria-role", "aria-valuenow", "aria-valuemin", "aria-valuemax", "aria-haspopup",
  "aria-selected", "aria-readonly", "aria-required", "aria-atomic", "aria-busy"
}

-- HTML tag-specific attributes
Enums.AttributesByTag = {
  a = { "href", "target", "rel", "download", "type" },
  img = { "src", "alt", "width", "height", "loading", "decoding" },
  input = { "type", "name", "value", "placeholder", "disabled", "checked", "required" },
  button = { "type", "disabled", "name", "value" },
  form = { "action", "method", "enctype", "novalidate", "target" },
  link = { "rel", "href", "type", "media" },
  script = { "src", "type", "async", "defer", "crossorigin" },
  meta = { "name", "content", "charset", "http-equiv" },
  div = { "id", "class", "style", "data-*", "role" },
  span = { "id", "class", "style", "data-*", "role" }
}

-- Expected values
Enums.ExpectedValues = {
  ["type"] = {
    ["input"] = { "text", "password", "email", "number", "date", "checkbox", "radio", "file", "hidden", "submit", "reset", "button" },
    ["button"] = { "submit", "reset", "button" },
    ["script"] = { "module", "text/javascript" }
  },
  ["target"] = { "_blank", "_self", "_parent", "_top" },
  ["rel"] = { "stylesheet", "nofollow", "noopener", "noreferrer", "preload" },
  ["method"] = { "get", "post" }
}

-- Event attributes (global)
Enums.EventAttributes = {
  "onabort", "onafterprint", "onbeforeprint", "onbeforeunload", "onblur",
  "oncanplay", "oncanplaythrough", "onchange", "onclick", "oncontextmenu", "oncopy",
  "oncut", "ondblclick", "ondrag", "ondragend", "ondragenter", "ondragleave",
  "ondragover", "ondragstart", "ondrop", "ondurationchange", "onended", "onerror",
  "onfocus", "onhashchange", "oninput", "oninvalid", "onkeydown", "onkeypress",
  "onkeyup", "onload", "onloadeddata", "onloadedmetadata", "onloadstart",
  "onmessage", "onmousedown", "onmouseenter", "onmouseleave", "onmousemove",
  "onmouseover", "onmouseout", "onmouseup", "onoffline", "ononline", "onopen",
  "onpagehide", "onpageshow", "onpaste", "onpause", "onplay", "onplaying",
  "onpopstate", "onprogress", "onratechange", "onreset", "onresize", "onscroll",
  "onsearch", "onseeked", "onseeking", "onselect", "onshow", "onstalled",
  "onstorage", "onsubmit", "onsuspend", "ontimeupdate", "ontoggle", "onunload",
  "onvolumechange", "onwaiting", "onwheel", "onhover", "onpress"
}

-- Internal sets for quick lookups
local function list_to_set(list)
  local set = {}
  for _, v in ipairs(list) do set[v] = true end
  return set
end

Enums._TagSet = list_to_set(Enums.Tags)
Enums._EventSet = list_to_set(Enums.EventAttributes)

-- Validation helpers
function Enums.is_valid_tag(tag)
  return Enums._TagSet[tag] or false
end

function Enums.get_attributes(tag)
  local specific = Enums.AttributesByTag[tag] or {}
  local all = {}
  for _, a in ipairs(specific) do table.insert(all, a) end
  for _, a in ipairs(Enums.GlobalAttributes) do table.insert(all, a) end
  for _, a in ipairs(Enums.AriaAttributes) do table.insert(all, a) end
  return all
end

function Enums.has_attr(tag, attr)
  local attrs = Enums.get_attributes(tag)
  for _, a in ipairs(attrs) do
    if a == attr or (a:match("data%-") and attr:match("^data%-")) then
      return true
    end
  end
  return Enums.is_event_attr(attr)
end

function Enums.get_expected_values(attr, tag)
  local values = Enums.ExpectedValues[attr]
  if not values then return {} end
  if type(values) == "table" and type(values[1]) == "string" then
    return values
  elseif type(tag) == "string" and values[tag] then
    return values[tag]
  end
  return {}
end

function Enums.list_tags()
  return Enums.Tags
end

function Enums.list_attributes()
  local all = {}
  for _, attrs in pairs(Enums.AttributesByTag) do
    for _, a in ipairs(attrs) do
      all[a] = true
    end
  end
  local out = {}
  for k in pairs(all) do table.insert(out, k) end
  return out
end

-- Event utilities
function Enums.is_event_attr(attr)
  return Enums._EventSet[attr] or false
end

function Enums.get_event_attributes()
  return Enums.EventAttributes
end

function Enums.list_all_events()
  return Enums.EventAttributes
end

-- Group attributes for reporting
function Enums.grouped_attributes()
  local scoped = {}
  for tag, attrs in pairs(Enums.AttributesByTag) do
    scoped[tag] = {}
    for _, attr in ipairs(attrs) do table.insert(scoped[tag], attr) end
  end
  return {
    global = Enums.GlobalAttributes,
    aria = Enums.AriaAttributes,
    events = Enums.EventAttributes,
    scoped = scoped
  }
end

return Enums
