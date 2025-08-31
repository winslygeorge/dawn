local TokenCleaner = {}
TokenCleaner.__index = TokenCleaner
local log_level = require("utils.logger").LogLevel

function TokenCleaner:new(name, interval, dawn_server)
    local self = setmetatable({}, TokenCleaner)
    self.name = name or "TokenCleaner"
    self.interval = (interval or 3600) * 1000 -- convert to milliseconds
    self.dawn_server = dawn_server
    self.timer_id = nil
    return self
end

function TokenCleaner:start()
    if self.timer_id then
        self.dawn_server:clearTimer(self.timer_id)
    end

    self.timer_id = self.dawn_server:setInterval(function()
        -- log debug starting token cleanup_all
        self.dawn_server.logger:log(log_level.DEBUG, "[TokenCleaner] Starting token cleanup.", "TokenCleaner", self.name)
        local count = require("auth.token_store").cleanup_all()
        if count > 0 then
            self.dawn_server.logger:log(log_level.INFO, "[TokenCleaner] Removed " .. count .. " expired token(s).", "TokenCleaner", self.name)
        end
    end, self.interval)

    return true
end

function TokenCleaner:restart()
    return self:start()
end

function TokenCleaner:stop()
    if self.timer_id then
        -- self.dawn_server:clearTimer(self.timer_id)
        self.timer_id = nil
    end
    return true
end

return TokenCleaner
