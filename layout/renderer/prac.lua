local renderer = require("lustache_renderer")
local json = require("dkjson")

-- Define the data context
local data = {
    title = "Home",
    heading = "Welcome to the Dawn Framework!",
    message = "This is a server-rendered page using Mustache templates.",
    year = os.date("%Y")
}

-- Preload partials and main template
renderer:preload({ "index", "partials/footer" }, function(preload_err)
    if preload_err then
        print("[PRELOAD ERROR]:", preload_err)
        return
    end

    -- Render after preload
    renderer:render_async("index", data, function(err, html)
        if err then
            print("[RENDER ERROR]:", err)
        else
            print("[RENDERED HTML]\n" .. json.encode(html))
        end
    end)
end)

