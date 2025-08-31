local DevWatcher = {}
DevWatcher.__index = DevWatcher

local log_level = require("utils.logger").LogLevel

local env = require("config.get_env")

function DevWatcher:new(server, options)
    local self = setmetatable({}, DevWatcher)
    self.server = server
    self.logger = self.server.logger or {
        log = function(_, level, message)
            print("[" .. tostring(level) .. "] " .. (message or ""))
        end
    }
    self.file_cache = {}
    self.changed_files = {}

    self.options = {
        interval = options.interval or 1.0,
        debounce_ms = options.debounce_ms or 1000, -- restart & notify cooldown
        retry_ms = options.retry_ms or 2000,       -- retry delay if restart fails
        watch_dirs = options.watch_dirs or {
            views = "./views",
            components = "./components",
            templates = "./templates"
        }
    }

    self.last_restart = 0
    self.restart_scheduled = false
    self.logger:log(log_level.DEBUG, "DevWatcher initialized with options: interval="
        .. tostring(self.options.interval) .. "s, debounce="
        .. tostring(self.options.debounce_ms) .. "ms, retry="
        .. tostring(self.options.retry_ms) .. "ms", "DevWatcher")
    return self
end

function DevWatcher:scan_files()
    for name, dir_path in pairs(self.options.watch_dirs) do
        -- self.logger:log("DEBUG", "Checking directory: " .. name .. " (" .. dir_path .. ")")
        local handle = io.popen(
            'find "'..dir_path..'" -type f \\( -name "*.lua" -o -name "*.mustache" \\) 2>/dev/null'
        )
        if not handle then
            self.logger:log(log_level.WARN, "Unable to open directory: " .. dir_path)
        else
            for filepath in handle:lines() do
                -- self.logger:log("TRACE", "Found file: " .. filepath)
                self:check_file(filepath)
            end
            handle:close()
        end
    end
    -- self.logger:log("DEBUG", "Finished scanning directories.")
end

function DevWatcher:check_file(filepath)
    -- self.logger:log("TRACE", "Checking file: " .. filepath)
    local pipe = io.popen("stat -c %Y '"..filepath.."' 2>/dev/null")
    if not pipe then
        self.logger:log(log_level.WARN, "Could not stat file: " .. filepath, "DevWatcher")
        return
    end
    local stat = pipe:read("*a")
    pipe:close()
    if not stat or stat == "" then
        self.logger:log(log_level.WARN, "No stat output for file: " .. filepath, "DevWatcher")
        return
    end

    local mtime = tonumber(stat)
    if not mtime then
        self.logger:log(log_level.WARN, "Invalid mtime for file: " .. filepath .. " ("..tostring(stat)..")", "DevWatcher")
        return
    end

    if not self.file_cache[filepath] then
        self.file_cache[filepath] = mtime
    elseif self.file_cache[filepath] ~= mtime then
        self.file_cache[filepath] = mtime
        self:handle_file_change(filepath)
    else
        -- self.logger:log("TRACE", "File unchanged: " .. filepath)
    end
end

function DevWatcher:handle_file_change(filepath)
    table.insert(self.changed_files, filepath)

    local now = os.time() * 1000
    local since_last = now - self.last_restart

    if since_last >= self.options.debounce_ms then
        self.logger:log(log_level.DEBUG, "Immediate restart scheduled (debounce passed)", "DevWatcher")
        self:schedule_restart()
    elseif not self.restart_scheduled then
        local delay = self.options.debounce_ms - since_last
        self.logger:log(log_level.DEBUG, "Restart debounce active. Scheduling restart in " .. delay .. "ms", "DevWatcher")
        self.restart_scheduled = true
        self.server:setTimeout(function()
            self.logger:log(log_level.DEBUG, "Debounce delay expired. Restarting now.", "DevWatcher")
            self:schedule_restart()
            self.restart_scheduled = false
        end, delay)
    else
        self.logger:log(log_level.DEBUG, "Restart already scheduled. Skipping additional scheduling.", "DevWatcher")
    end
end

function DevWatcher:schedule_restart()
    self.last_restart = os.time() * 1000
    local files = self.changed_files
    self.changed_files = {}

    if #files == 0 then
        self.logger:log(log_level.DEBUG, "No files to restart on. Skipping restart.", "DevWatcher")
        return
    end

    if self.server.restart then
        self:try_restart(files, 0)
    else
        self.logger:log(log_level.WARN, "Server does not support restart(). Skipping.", "DevWatcher")
    end
end

function DevWatcher:try_restart(files, attempt)
    self.logger:log(log_level.DEBUG, "Attempting server restart (attempt " .. attempt .. ")...", "DevWatcher")
    self.server.shared_state.changed_files = files
    local ok, err = pcall(function()
        self.server:restart()
    end)

    if not ok then
        attempt = attempt + 1
        self.logger:log(log_level.ERROR, "Server restart failed (attempt "..attempt.."): "..tostring(err), "DevWatcher")
        self.server:setTimeout(function()
            self:try_restart(files, attempt)
        end, self.options.retry_ms)
        return
    end

    self.logger:log(log_level.DEBUG, "Server restart succeeded after "..attempt.." attempt(s)", "DevWatcher")

     if self.server.shared_state then
            for k, comp in pairs(self.server.shared_state) do
                if comp and comp.hotReload then
                    comp:hotReload()
                end
            end
        end

end

function DevWatcher:start()
    if env and env.DEBUG == false then
        self.logger:log(log_level.WARN, "DevWatcher not started , in prod mode", "DevWatcher")
        return
    end
    self.logger:log(log_level.INFO, "Starting dev watcher (interval: "..self.options.interval.."s)", "DevWatcher")
    self.timer = self.server:setInterval(function()
        -- print("Scanning for file changes...")
        self:scan_files()
    end, self.options.interval * 1000)
end

function DevWatcher:stop()
    self.logger:log(log_level.INFO, "Stopping dev watcher", "DevWatcher")
    if self.timer then
        self.server.clearTimer(self.timer)
        self.logger:log(log_level.DEBUG, "Timer cleared", "DevWatcher")
    end
end

return DevWatcher
