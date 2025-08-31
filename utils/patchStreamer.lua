-- patch_streamer.lua
-- Enhanced PatchStreamer: supports multi-filter, NOT filters, wildcard paths, keepalive, and logging

local PatchQueue = require("utils.patch_queue")
local cjson = require("dkjson")
local log_level = require("utils.logger").LogLevel

local PatchStreamer = {}
PatchStreamer.__index = PatchStreamer

function PatchStreamer:new(dawn)
  local obj = setmetatable({}, self)
  obj.dawn = dawn
  obj.subscribers = {} -- sse_id → { filters = ..., last_seen = ... }
  obj.flush_interval = 100 -- ms
  obj.max_inactive_ms = 30000
  obj.keepalive_interval = 15000 -- ms
  obj.timer_id = nil
  obj.keepalive_timer_id = nil
  obj.shutdown_signal = false
  obj:init()
  return obj
end

function PatchStreamer:init()
  self.timer_id = self.dawn:setInterval(function(ctx)
    if self.shutdown_signal then return end
    self:pruneDeadClients()
    if PatchQueue:isEmpty() then return end
    local patch = PatchQueue:pop()
    if patch then
      local encoded = cjson.encode({ patch })
      self:broadcast(encoded, patch)
    end
  end, self.flush_interval)

  self.keepalive_timer_id = self.dawn:setInterval( function()
    if self.shutdown_signal then return end
    for sse_id in pairs(self.subscribers) do
      local ok, err = pcall(function()
        self.dawn:sse_send(sse_id, ":ping\n\n")
      end)
      if not ok then
        self.dawn.logger:log(log_level.ERROR, "[PatchStreamer] Keepalive failed for:"..sse_id.."\nError:"..err, "PatchStreamer", sse_id)
        self:removeSubscriber(sse_id)
      end
    end
  end, self.keepalive_interval)
end

function PatchStreamer:addSubscriber(sse_id, filters)
  self.subscribers[sse_id] = {
    filters = filters or {},
    last_seen = os.time() * 1000
  }
  self.dawn.logger:log(log_level.INFO, "[PatchStreamer] Added subscriber:"..sse_id, "PatchStreamer", sse_id)
end

function PatchStreamer:removeSubscriber(sse_id)
  self.subscribers[sse_id] = nil
  self.dawn.logger:log(log_level.INFO, "[PatchStreamer] Removed subscriber:"..sse_id, "PatchStreamer", sse_id)
end

function PatchStreamer:shouldSend(patch, filters)
  if not filters then return true end

  -- Positive component match
  if filters.component and patch.component then
    local matched = false
    for _, allowed in ipairs(filters.component) do
      if patch.component == allowed then
        matched = true
        break
      end
    end
    if not matched then return false end
  end

  -- NOT component exclusion
  if filters.not_component and patch.component then
    for _, blocked in ipairs(filters.not_component) do
      if patch.component == blocked then
        return false
      end
    end
  end

  -- Positive path match
  if filters.path and patch.path then
    if not patch.path:match(filters.path) then
      return false
    end
  end

  -- NOT path exclusion
  if filters.not_path and patch.path then
    if patch.path:match(filters.not_path) then
      return false
    end
  end

  return true
end

function PatchStreamer:pruneDeadClients()
  local now = os.time() * 1000
  for sse_id, meta in pairs(self.subscribers) do
    if now - meta.last_seen > self.max_inactive_ms then
      self:removeSubscriber(sse_id)
    end
  end
end

function PatchStreamer:broadcast(payload, raw_patch)
  for sse_id, meta in pairs(self.subscribers) do
    meta.last_seen = os.time() * 1000
    if self:shouldSend(raw_patch, meta.filters) then
      local ok, err = pcall(function()
        self.dawn:sse_send(sse_id, "data: " .. payload .. "\n\n")
      end)
      if not ok then
        self.dawn.logger:log(log_level.ERROR, "[PatchStreamer] Failed to send to:"..sse_id.."\nError:"..err, "PatchStreamer", sse_id)
        self:removeSubscriber(sse_id)
      end
    end
  end
end

function PatchStreamer:shutdown()
  self.shutdown_signal = true
  self.subscribers = {}
  if self.timer_id then self.timer_id = nil end
  if self.keepalive_timer_id then self.keepalive_timer_id = nil end
  self.dawn.logger:log(log_level.INFO, "[PatchStreamer] Shutdown complete.")
end

return PatchStreamer
