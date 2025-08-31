-- advanced_logger.lua
local ffi = require("ffi")
local cjson = require("dkjson")

ffi.cdef[[ int getpid(); ]]

local LOG_FILE = "app.log"
local MAX_LOG_SIZE = 10 * 1024 * 1024 -- 10MB
local MAX_QUEUE_SIZE = 10000
local AUTO_FLUSH_INTERVAL = 5000
local MAX_HISTORY_LINES = 200
local MAX_ROTATED_FILES = 5

local LogLevel = {
    DEBUG = 1, INFO = 2, WARN = 3, ERROR = 4, FATAL = 5
}
local levelNames = { [1]="DEBUG", [2]="INFO", [3]="WARN", [4]="ERROR", [5]="FATAL" }
function LogLevel.toString(level) return levelNames[level] or "UNKNOWN" end

local COLORS = {
    DEBUG = "\27[38;5;244m", INFO = "\27[38;5;34m", WARN = "\27[38;5;214m",
    ERROR = "\27[38;5;196m", FATAL = "\27[48;5;88;38;5;231m", RESET = "\27[0m"
}
local ICONS = {
    DEBUG = "\xF0\x9F\x90\x9E", INFO = "\xE2\x84\xB9\xEF\xB8\x8F", WARN = "\xE2\x9A\xA0\xEF\xB8\x8F",
    ERROR = "\xE2\x9D\x8C", FATAL = "\xF0\x9F\x92\x80"
}

local Logger = {}
Logger.__index = Logger

function Logger:new(dawn)
    local obj = setmetatable({}, self)
    obj.pid = ffi.C.getpid()
    obj.thread_id = math.random(1, 999999999)
    obj.log_fd = nil
    obj.log_queue = {}
    obj.log_worker_active = false
    obj.shutdown_signal = false
    obj.log_mode = "dev"
    obj.min_level = LogLevel.INFO
    obj.component_levels = {}
    obj.subscribers = {}
    obj.history = {}
    obj.last_request_id = nil
    obj.dawn = dawn
    obj.flush_timer_id = nil

    obj:openLogFile()
    obj:startAutoFlush()
    return obj
end

function Logger:setLogMode(mode)
    self.log_mode = mode or "dev"
end

function Logger:setComponentLevel(component, level)
    self.component_levels[component] = level
end

function Logger:getComponentLevel(component)
    return self.component_levels[component] or self.min_level
end

function Logger:openLogFile()
    local file, err = io.open(LOG_FILE, "a+")
    if not file then
        print("[Logger] Failed to open log file:", err)
        return
    end
    self.log_fd = file
    print("[Logger] Log file opened.")
end

function Logger:checkRotation()
    if not self.log_fd then return end
    local current_size = self.log_fd:seek("end")
    self.log_fd:seek("set")
    if current_size and current_size >= MAX_LOG_SIZE then
        local timestamp = os.date("%Y%m%d_%H%M%S")
        local new_name = string.format("app_%s.log", timestamp)
        self.log_fd:close()
        os.rename(LOG_FILE, new_name)
        print("[Logger] Rotated log file to:", new_name)
        self:cleanupOldLogs()
        self:openLogFile()
    end
end

function Logger:cleanupOldLogs()
    local logs = {}
    for file in io.popen("ls app_*.log 2>/dev/null"):lines() do
        table.insert(logs, file)
    end
    table.sort(logs)
    while #logs > MAX_ROTATED_FILES do
        local old = table.remove(logs, 1)
        os.remove(old)
        print("[Logger] Removed old log file:", old)
    end
end

function Logger:log(level, msg, source, request_id)
    local min_level = self:getComponentLevel(source or "")
    if type(level) == "string" then
        level = LogLevel[level:upper()] or LogLevel.INFO
    end
    if not level or type(level) ~= "number" or level < LogLevel.DEBUG or level > LogLevel.FATAL then
        print("[Logger] Invalid log level:", level)
        return
    end
    if level < min_level then return end

    local level_name = LogLevel.toString(level)
    source = source or "unknown"
    local entry = {
        timestamp = os.date("!%Y-%m-%dT%H:%M:%SZ"),
        level = level_name,
        message = msg,
        source = source,
        pid = self.pid,
        thread_id = self.thread_id,
        request_id = request_id or "N/A",
        memory_usage = collectgarbage("count")
    }

    local json_log = cjson.encode(entry)
    if not json_log then
        print("[Logger] Failed to encode log entry.")
        return
    end
    table.insert(self.log_queue, json_log .. "\n")

    -- Beautified dev mode logs
if self.log_mode == "dev" then
    local color = COLORS[level_name] or ""
    local icon  = ICONS[level_name] or ""
    local reset = COLORS.RESET
    local bold  = "\27[1m"
    local dim   = "\27[2m"

    local pid_str    = tostring(entry.pid or "?")
    local tid_str    = tostring(entry.thread_id or "?")
    local source_str = tostring(source or "unknown")
    local level_str  = tostring(level_name or "UNKNOWN")
    local ts_str     = tostring(entry.timestamp or "")
    local msg_str    = tostring(msg or "")

    local formatted = string.format(
        "%s╭──────────────────────────────────────────────────────────╮%s\n" ..
        "%s│ %s%-7s%s │ %s%-19s%s │ PID:%-5s TID:%-9s │ %-15s │%s\n" ..
        "%s╰→ %s%s%s%s\n",
        dim, reset,
        color, bold, level_str, reset,
        reset, ts_str, color,
        pid_str, tid_str, source_str, reset,
        reset, color, icon, " " .. msg_str, reset
    )

    print(formatted)
end



    if #self.log_queue >= MAX_QUEUE_SIZE or #self.log_queue >= 10 then
        self:flushBuffer()
    end
end

function Logger:flushBuffer()
    if #self.log_queue == 0 or not self.log_fd then return end
    local batch_logs = table.concat(self.log_queue)
    self.log_queue = {}
    local ok, err = pcall(function()
        self.log_fd:write(batch_logs)
        self.log_fd:flush()
        self:checkRotation()
        for line in batch_logs:gmatch("[^\r\n]+") do
            self:broadcastToSubscribers(line)
            table.insert(self.history, line)
            if #self.history > MAX_HISTORY_LINES then
                table.remove(self.history, 1)
            end
        end
    end)
    if not ok then
        print("[Logger] Log write failed:", err)
    end
end

function Logger:startAutoFlush()
    if self.flush_timer_id then
        self.dawn:clearTimer(self.flush_timer_id)
    end
    self.flush_timer_id = self.dawn:setInterval(function(ctx)
        self:flushBuffer()
    end, AUTO_FLUSH_INTERVAL)
end

function Logger:addSubscriber(id, opts)
    self.subscribers[id] = opts or {}
    for _, line in ipairs(self.history) do
        if self:shouldSend(line, self.subscribers[id]) then
            self.dawn:sse_send(id, line)
        end
    end
end

function Logger:removeSubscriber(id)
    self.subscribers[id] = nil
end

function Logger:shouldSend(line, opts)
    if not opts then return true end
    local ok, decoded = pcall(cjson.decode, line)
    if not ok or not decoded then return true end
    if opts.level and LogLevel[decoded.level] < LogLevel[opts.level] then
        return false
    end
    if opts.component and decoded.source ~= opts.component then
        return false
    end
    return true
end

function Logger:broadcastToSubscribers(line)
    for id, opts in pairs(self.subscribers) do
        if self:shouldSend(line, opts) then
            self.dawn:sse_send(id, line)
        end
    end
end

function Logger:shutdown()
    self.shutdown_signal = true
    self:flushBuffer()
    if self.flush_timer_id then
        self.flush_timer_id = nil
    end
    if self.log_fd then
        self.log_fd:close()
        self.log_fd = nil
        print("[Logger] Shutdown complete. Logs flushed.")
    end
end

return {
    Logger = Logger,
    LogLevel = LogLevel
}
