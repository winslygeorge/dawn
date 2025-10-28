-- streaming_multipart.lua (robust boundary handling + streaming + debug)
-- Safe binary handling + step-by-step debug logs + tolerant boundary matching

local ffi = require("ffi")
local zlib = require("zlib")
local lfs = require("lfs")
local base64 = require("utils.base64")
-- local crypto = require("crypto") -- optional encryption/decryption lib

local StreamingMultipartParser = {}
StreamingMultipartParser.__index = StreamingMultipartParser

-- default options -----------------------------------------------------------
local default_opts = {
  max_memory_size = 1024 * 1024 * 2,          -- 2MB cap for in-memory parts (fields)
  decode_base64 = true,
  decode_gzip = true,
  auto_save_dir = "./tmp",                     -- default dir for normal files
  large_file_threshold = 1024 * 1024 * 100,   -- 100MB threshold
  large_file_dir = "./upload/large",          -- redirect huge files here
  stream_to_disk = true,
  cleanup = true,
  on_start_part = nil,
  on_end_part = nil,
  encryption_key = nil, -- optional future use
  progress_callback = nil,
  debug = false,                -- enable step-by-step logs
  debug_body_preview_bytes = 0, -- preview first N bytes of body per part (0 = off)
  max_preamble = 4 * 1024 * 1024,  -- 4MB tolerance for preamble
  max_buffer_size = 1024 * 1024 * 10, -- 10MB max buffer size
}

-- logger helpers ------------------------------------------------------------
local function is_tty_stderr()
  local ok, f = pcall(function() return io.type(io.stderr) end)
  return ok and f ~= nil
end

local function _fmt(fmt, ...)
  local ok, msg = pcall(string.format, fmt, ...)
  if ok then return msg else return (fmt or "") end
end

local function log(self, level, fmt, ...)
  if not (self and self.opts and self.opts.debug) then return end
  local prefix = _fmt("[multipart:%s] ", level or "debug")
  local msg = _fmt(fmt or "", ...)
  local line = prefix .. msg .. "\n"
  if is_tty_stderr() then io.stderr:write(line) else print(line) end
end

local function hexdump_prefix(s, n)
  if not s or n <= 0 then return ""
  end
  local out = {}
  local len = math.min(#s, n)
  for i=1,len do
    out[#out+1] = string.format("%02X", string.byte(s, i))
    if i < len then out[#out+1] = " " end
  end
  return table.concat(out)
end

-- utilities ----------------------------------------------------------------
local function sanitize_filename(name)
  if not name then return "unnamed_part_" .. tostring(math.random(1e6)) end
  -- Remove path components and sanitize
  local base = name:match("([^/\\]*)$")
  return base:gsub("[^%w%.%-_]", "_"):gsub("^%.+", ""):gsub("%.+$", "")
end

local function create_temp_writer(filename, opts, force_large)
  local dir = opts.auto_save_dir
  if force_large then
    dir = opts.large_file_dir or dir
  end

  -- ensure directory exists
  local attr = lfs.attributes(dir)
  if not attr then
    assert(lfs.mkdir(dir), "Failed to create directory: " .. dir)
  elseif attr.mode ~= "directory" then
    error(dir .. " exists but is not a directory")
  end

  local path = dir .. "/" .. sanitize_filename(filename or ("part_" .. tostring(math.random(1e6))))
  local file = assert(io.open(path, "wb"))
  return {
    path = path,
    write = function(self, chunk) file:write(chunk) end,
    close = function() file:close() end
  }
end

local function try_gunzip(data)
  local ok, result = pcall(function()
    local stream = zlib.inflate()
    return stream(data)
  end)
  return ok and result or nil
end

-- constructor ---------------------------------------------------------------
function StreamingMultipartParser:new(content_type, on_part_callback, opts)
  assert(type(content_type) == "string", "Content-Type required")
  assert(type(on_part_callback) == "function", "Callback required")

  opts = setmetatable(opts or {}, { __index = default_opts })

  -- Handle quoted boundaries and various content-type formats
  local raw_boundary = content_type:match('boundary%s*=%s*"([^"]+)"') or
                       content_type:match("boundary%s*=%s*'([^']+)'") or
                       content_type:match('boundary%s*=%s*([^%s;]+)')
  assert(raw_boundary, "Boundary not found in content type: " .. tostring(content_type))

  -- Standard boundaries
  local boundary = "--" .. raw_boundary
  local boundary_final = boundary .. "--"
  local boundary_crlf = "\r\n" .. boundary

  -- WebKit-style boundaries (Chrome/Safari variants)
  local webkit_boundary = "----" .. raw_boundary:gsub("^%-*", ""):gsub("webkitformboundary", "WebKitFormBoundary")
  local webkit_boundary_final = webkit_boundary .. "--"
  local webkit_boundary_crlf = "\r\n" .. webkit_boundary

  local self = setmetatable({
    boundary = boundary,
    boundary_final = boundary_final,
    boundary_crlf = boundary_crlf,
    webkit_boundary = webkit_boundary,
    webkit_boundary_final = webkit_boundary_final,
    webkit_boundary_crlf = webkit_boundary_crlf,
    raw_boundary = raw_boundary,
    on_part = on_part_callback,
    opts = opts,
    buffer = "",
    state = "preamble",
    current = nil,
    done = false,
    total_read = 0,
    parts_count = 0,
    progress = 0,
    form_data_parsed = {},
  }, StreamingMultipartParser)

  log(self, "info", "Initialized parser. raw_boundary='%s'", raw_boundary)
  log(self, "info", "Standard boundary='%s'", boundary)
  log(self, "info", "WebKit boundary='%s'", webkit_boundary)
  return self
end

function StreamingMultipartParser:storeFormDataParsed(part)
  if not part then return end
  table.insert(self.form_data_parsed, part)
end

-- internal helpers ----------------------------------------------------------
local function parse_headers(self, header_block)
  local headers = {}
  for line in header_block:gmatch("[^\r\n]+") do
    local k, v = line:match("^([^:%s]+)%s*:%s*(.*)$")
    if k and v then
      headers[k:lower()] = v:gsub("^%s*(.-)%s*$", "%1")
    else
      log(self, "warn", "Malformed header line: " .. line)
    end
  end
  return headers
end

local function parse_content_disposition(cd)
  local name = cd:match('name="([^"]+)"')
  local filename = cd:match('filename="([^"]+)"')
  return name, filename
end

-- boundary detection helper -------------------------------------------------
local function find_boundary_anycase(buf, boundary, webkit_boundary)
  if #buf == 0 then return nil end

  local patterns = {
    { pat = "\r\n" .. boundary .. "--",  kind = "final"  },
    { pat = "\n"    .. boundary .. "--",  kind = "final"  },
    { pat = "\r\n" .. webkit_boundary .. "--", kind = "final" },
    { pat = "\n"    .. webkit_boundary .. "--", kind = "final" },
    { pat = "\r\n" .. boundary .. "\r\n", kind = "normal" },
    { pat = "\n"    .. boundary .. "\n",   kind = "normal" },
    { pat = "\r\n" .. webkit_boundary .. "\r\n", kind = "normal" },
    { pat = "\n"    .. webkit_boundary .. "\n",   kind = "normal" },
    { pat = boundary .. "\r\n",           kind = "normal" },
    { pat = boundary .. "\n",             kind = "normal" },
    { pat = webkit_boundary .. "\r\n",    kind = "normal" },
    { pat = webkit_boundary .. "\n",      kind = "normal" },
    { pat = boundary .. "--",             kind = "final"  },
    { pat = webkit_boundary .. "--",      kind = "final"  },
  }

  local lb = buf:lower()
  local earliest_s, earliest_e, earliest_kind, earliest_pat = nil, nil, nil, nil

  for _, entry in ipairs(patterns) do
    local pat = entry.pat
    local s, e = lb:find(pat:lower(), 1, true)
    if s and (not earliest_s or s < earliest_s) then
      earliest_s, earliest_e, earliest_kind, earliest_pat = s, e, entry.kind, pat
    end
  end

  if not earliest_s then return nil end
  return earliest_s, earliest_e, earliest_kind, earliest_pat
end

-- buffer management ---------------------------------------------------------
function StreamingMultipartParser:process_buffer()
  local processed = false

  while true do
    if self.state == "preamble" then
      local s, e, kind, pat = find_boundary_anycase(self.buffer, self.boundary, self.webkit_boundary)
      if s and e then
        self.buffer = self.buffer:sub(e + 1)
        self.state = "headers"
        processed = true
      else
        if #self.buffer > self.opts.max_preamble then
          error("multipart: boundary not found in preamble")
        end
        return processed
      end

    elseif self.state == "headers" then
      local s,e = self.buffer:find("\r\n\r\n", 1, true)
      if not s then
        return processed
      end

      local header_block = self.buffer:sub(1, s-1)
      self.buffer = self.buffer:sub(e+1)

      local headers = parse_headers(self, header_block)
      local cd = headers["content-disposition"] or ""
      local name, filename = parse_content_disposition(cd)
      local mimetype = headers["content-type"]
      local cte = headers["content-transfer-encoding"]
      local content_encoding = headers["content-encoding"]

      self.current = {
        headers = headers,
        name = name,
        filename = filename,
        mimetype = mimetype,
        content_transfer_encoding = cte,
        content_encoding = content_encoding,
        is_file = filename and true or false,
        size = 0,
        size_raw = 0,
        body = self.opts.stream_to_disk and nil or {},
        temp_writer = nil,
        base64 = self.opts.decode_base64 and cte and cte:lower() == "base64" or false,
        gzip = self.opts.decode_gzip and (
          (mimetype and mimetype:lower() == "application/gzip") or
          (content_encoding and content_encoding:lower():find("gzip",1,true))
        ) or false,
        path = nil,
      }

      if self.opts.stream_to_disk and self.current.is_file then
        local force_large = false
        if self.opts.large_file_threshold and headers["content-length"] then
          local cl = tonumber(headers["content-length"])
          if cl and cl >= self.opts.large_file_threshold then
            force_large = true
            log(self, "info", "Detected large file (%d bytes), redirecting to %s", cl, self.opts.large_file_dir)
          end
        end
        self.current.temp_writer = create_temp_writer(filename, self.opts, force_large)
      end

      if self.opts.on_start_part then
        pcall(self.opts.on_start_part, self.current)
      end

      self.state = "body"
      processed = true

    elseif self.state == "body" then
      local s, e, kind, pat = find_boundary_anycase(self.buffer, self.boundary, self.webkit_boundary)
      if not s then
        return processed
      end

      local raw_body = self.buffer:sub(1, s-1)
      self.buffer = self.buffer:sub(e+1)

      local part = self.current
      part.size_raw = #raw_body

      local payload = raw_body
      if part.base64 then
        local ok, decoded = pcall(function() return base64.decode(payload) end)
        if ok and decoded then payload = decoded end
      end
      if part.gzip then
        local decoded = try_gunzip(payload)
        if decoded then payload = decoded end
      end
      part.size = #payload

      if part.temp_writer then
        part.temp_writer:write(payload)
        part.temp_writer:close()
        part.path = part.temp_writer.path
        part.body = nil
      else
        if not part.body then part.body = {} end
        if not part.is_file and #payload > self.opts.max_memory_size then
          error("Field '" .. tostring(part.name) .. "' exceeds max_memory_size")
        end
        table.insert(part.body, payload)
        part.body = table.concat(part.body)
      end

      self.parts_count = self.parts_count + 1
      if self.opts.on_end_part then pcall(self.opts.on_end_part, part) self:storeFormDataParsed(part) end
      pcall(self.on_part, part)

      self.current = nil

      if kind == "final" then
        self.done = true
        return true
      else
        if self.buffer:sub(1,2) == "\r\n" then
          self.buffer = self.buffer:sub(3)
        elseif self.buffer:sub(1,1) == "\n" then
          self.buffer = self.buffer:sub(2)
        end
        self.state = "headers"
        processed = true
      end
    else
      error("Invalid parser state: " .. tostring(self.state))
    end
  end
end

-- feed ---------------------------------------------------------------------
function StreamingMultipartParser:feed(data)
  if self.done then return end
  if data == nil or #data == 0 then return end

  if #self.buffer > self.opts.max_buffer_size then
    self:process_buffer()
  end

  self.buffer = self.buffer .. data
  self.total_read = self.total_read + #data

  if self.opts.progress_callback then
    self.progress = self.total_read
    pcall(self.opts.progress_callback, self.progress)
  end

  self:process_buffer()
end

-- finalization -------------------------------------------------------------
function StreamingMultipartParser:finalize()
  if not self.done and #self.buffer > 0 then
    self:process_buffer()
    if self.state == "body" and self.current then
      local part = self.current
      part.size_raw = #self.buffer
      local payload = self.buffer
      if part.base64 then
        local ok, decoded = pcall(function() return base64.decode(payload) end)
        if ok and decoded then payload = decoded end
      end
      if part.gzip then
        local decoded = try_gunzip(payload)
        if decoded then payload = decoded end
      end
      part.size = #payload
      if part.temp_writer then
        part.temp_writer:write(payload)
        part.temp_writer:close()
        part.path = part.temp_writer.path
        part.body = nil
      else
        if not part.body then part.body = {} end
        table.insert(part.body, payload)
        part.body = table.concat(part.body)
      end
      self.parts_count = self.parts_count + 1
      if self.opts.on_end_part then pcall(self.opts.on_end_part, part) self:storeFormDataParsed(part) end
      pcall(self.on_part, part)
      self.buffer = ""
      self.current = nil
    end
  end
end

-- utility methods ----------------------------------------------------------
function StreamingMultipartParser:get_stats()
  return {
    parts_processed = self.parts_count,
    bytes_read = self.total_read,
    buffer_size = #self.buffer,
    state = self.state,
    done = self.done
  }
end

function StreamingMultipartParser:reset()
  self.buffer = ""
  self.state = "preamble"
  self.current = nil
  self.done = false
  self.parts_count = 0
  self.total_read = 0
end

-- accumulate utility -------------------------------------------------------
function StreamingMultipartParser.accumulate(content_type, body_stream, opts)
  local form = {}
  local parser = StreamingMultipartParser:new(content_type, function(part)
    if opts and opts.nested and part.name then
      StreamingMultipartParser.set_nested(form, part.name, part.is_file and part or part.body)
    elseif part.name then
      form[part.name] = part.is_file and part or part.body
    end
  end, opts)

  for chunk in body_stream do parser:feed(chunk) end
  parser:finalize()
  return form
end

function StreamingMultipartParser.set_nested(tbl, key_path, value)
  local keys = {}
  for k in key_path:gmatch("[^%[%]]+") do table.insert(keys, k) end
  local t = tbl
  for i=1,#keys-1 do t[keys[i]] = t[keys[i]] or {} t = t[keys[i]] end
  t[keys[#keys]] = value
end

return StreamingMultipartParser
