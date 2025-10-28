-- try.lua
local M = {}

--- create a structured error
-- @param errType string: type/category of error
-- @param message string: human-readable message
-- @param data table|nil: optional extra data (metadata, codes, etc.)
-- @return table: error object
function M.error(errType, message, data)
    return {
        __TRY_ERROR__ = true,
        type = errType or "Error",
        message = message or "",
        data = data or {}
    }
end

--- throw
-- raises an error (string or structured)
function M.throw(err)
    error(err, 2) -- keep caller stacktrace
end

--- try/catch
-- @param tryFunc function: risky code
-- @param catchFunc function|nil: error handler
-- @return ...: values from tryFunc if successful
function M.try(tryFunc, catchFunc)
    local results = { xpcall(tryFunc, debug.traceback) }
    local ok = table.remove(results, 1)

    if not ok then
        local err = results[1]
        if catchFunc then
            catchFunc(err)
        else
            error(err)
        end
    end

    return table.unpack(results)
end

--- try/catch/finally
-- @param tryFunc function
-- @param catchFunc function|nil
-- @param finallyFunc function|nil
-- @return ok:boolean, ...: success flag + return value(s)
function M.tryCatchFinally(tryFunc, catchFunc, finallyFunc)
    local results = { xpcall(tryFunc, debug.traceback) }
    local ok = table.remove(results, 1)

    if not ok then
        local err = results[1]
        if catchFunc then catchFunc(err) end
    end
    if finallyFunc then finallyFunc() end

    return ok, table.unpack(results)
end

return M
