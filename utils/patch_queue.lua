-- PatchQueue.lua
-- Shared global patch queue with debounce control

local PatchQueue = {}
PatchQueue.__index = PatchQueue

function PatchQueue:new()
  return setmetatable({ queue = {}, lastPush = 0, debounceMs = 50 }, self)
end

function PatchQueue:push(patch)
  if patch then
    table.insert(self.queue, patch)
    self.lastPush = os.time() * 1000
  end
end

function PatchQueue:pushMany(patches)
  for _, patch in ipairs(patches or {}) do
    self:push(patch)
  end
end

function PatchQueue:pop()
  return table.remove(self.queue, 1)
end

function PatchQueue:drain()
  local drained = {}
  while #self.queue > 0 do
    table.insert(drained, self:pop())
  end
  return drained
end

function PatchQueue:isEmpty()
  return #self.queue == 0
end

function PatchQueue:peek()
  return self.queue[1]
end

function PatchQueue:clear()
  self.queue = {}
end

-- Global instance for app
return PatchQueue:new()
