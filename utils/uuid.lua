-- utils/uuid.lua

local M = {}

-- Seed once at startup
math.randomseed(os.time() + tonumber(tostring({}):sub(8), 16))

function M.v4()
    local template = "xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx"
    return string.gsub(template, "[xy]", function(c)
        local v = (c == "x") and math.random(0, 15) or math.random(8, 11)
        return string.format("%x", v)
    end)
end

return M
