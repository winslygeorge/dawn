-- Advanced logger with timestamps and structured output
local logger = logger or {
    info  = function(...) print(os.date("[%Y-%m-%d %H:%M:%S] INFO:"), ...) end,
    warn  = function(...) print(os.date("[%Y-%m-%d %H:%M:%S] WARN:"), ...) end,
    error = function(...) print(os.date("[%Y-%m-%d %H:%M:%S] ERROR:"), ...) end,
    debug = function(...) print(os.date("[%Y-%m-%d %H:%M:%S] DEBUG:"), ...) end,
}

-- Advanced PatchQueue
local PatchQueue = {
    listeners = {},     -- persistent listeners
    once = {},          -- one-time listeners
    buffered = {},      -- buffered patches (if no listeners yet)
    tags = {},          -- tags mapped to listener functions
    enable_buffering = true
}

-- Register a persistent listener
function PatchQueue:on_push(fn, tag)
    table.insert(self.listeners, fn)
    if tag then
        self.tags[tag] = fn
    end

    -- Replay buffered patches if any
    if self.enable_buffering and #self.buffered > 0 then
        logger.debug("Replaying buffered patches to new listener")
        for _, patch in ipairs(self.buffered) do
            local ok, err = pcall(fn, patch)
            if not ok then
                logger.error("Buffered patch dispatch error: ", err)
            end
        end
    end
end

-- Register a one-time listener
function PatchQueue:once_push(fn)
    table.insert(self.once, fn)
end

-- Remove listener by tag
function PatchQueue:remove(tag)
    local fn = self.tags[tag]
    if not fn then return end

    for i, listener in ipairs(self.listeners) do
        if listener == fn then
            table.remove(self.listeners, i)
            break
        end
    end
    self.tags[tag] = nil
end

-- Dispatch a patch
function PatchQueue:push(patch)
    local dispatched = false

    for _, fn in ipairs(self.listeners) do
        local ok, err = pcall(fn, patch)
        if not ok then
            logger.error("Error dispatching patch to listener: ", err)
        end
        dispatched = true
    end

    for i = #self.once, 1, -1 do
        local fn = self.once[i]
        local ok, err = pcall(fn, patch)
        if not ok then
            logger.error("Error dispatching patch to one-time listener: ", err)
        end
        table.remove(self.once, i)
        dispatched = true
    end

    if not dispatched and self.enable_buffering then
        logger.warn("No listeners available, buffering patch")
        table.insert(self.buffered, patch)
    end
end

-- Clear listeners and buffer
function PatchQueue:clear()
    self.listeners = {}
    self.once = {}
    self.buffered = {}
    self.tags = {}
end

-- Example of use:
-- PatchQueue:on_push(function(patch) print("Received patch:", patch.id) end)
-- PatchQueue:push({id=123, data="test"})

return PatchQueue
