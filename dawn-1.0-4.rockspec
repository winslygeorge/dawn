package = "dawn"
version = "1.0-4"

source = {
   url = "https://github.com/winslygeorge/dawn/archive/master.zip",
   dir = "dawn-master"
}

description = {
   summary = "🌄 Dawn Framework Overview",
   detailed = [[
      Dawn is a modular, async-capable Lua web framework inspired by the architectural philosophy of Phoenix (Elixir) and Express (Node.js). It supports:

      - RESTful HTTP routing
      - Middleware pipelines
      - JWT-based authentication
      - WebSockets with presence, pub/sub, and modular event hooks
      - Real-time components
      - Server-side rendering with Lustache
   ]],
   license = "MIT"
}

dependencies = {
   "luv",
   "uwebsockets",
   "dkjson",
   "net-url",
   "lustache",
   "lua-zlib"
}

build = {
   type = "builtin",
   modules = {
      ["layout.renderer.layout_model"] = "build/dawn/layout/renderer/layout_model.lua",
      ["layout.renderer.lustache_renderer"] = "build/dawn/layout/renderer/lustache_renderer.lua",
      ["layout.renderer.Controller"] = "build/dawn/layout/renderer/Controller.lua",
      ["layout.renderer.FuncComponent"] = "build/dawn/layout/renderer/FuncComponent.lua",
      ["dawn"] = "build/dawn/dawn.lua",
      ["auth.refresh_handler"] = "build/dawn/server/auth/refresh_handler.lua",
      ["auth.purejwt"] = "build/dawn/server/auth/purejwt.lua",
      ["auth.jwt_protect"] = "build/dawn/server/auth/jwt_protect.lua",
      ["auth.token_cleaner"] = "build/dawn/server/auth/token_cleaner.lua",
      ["auth.sha256"] = "build/dawn/server/auth/sha256.lua",
      ["auth.logout_handler"] = "build/dawn/server/auth/logout_handler.lua",
      ["auth.rate_limiting_middleware"] = "build/dawn/server/auth/rate_limiting_middleware.lua",
      ["auth.token_store"] = "build/dawn/server/auth/token_store.lua",
      ["auth.session_middleware"] = "build/dawn/server/auth/session_middleware.lua",
      ["multipart_parser"] = "build/dawn/server/multipart_parser.lua",
      ["dawn_server"] = "build/dawn/server/dawn_server.lua",
      ["dawn_sockets"] = "build/dawn/server/dawn_sockets.lua",
      ["websockets.presence_interface"] = "build/dawn/server/websockets/presence_interface.lua",
      ["utils.query_extractor"] = "build/dawn/utils/query_extractor.lua",
      ["utils.uuid"] = "build/dawn/utils/uuid.lua",
      ["utils.queue"] = "build/dawn/utils/queue.lua",
      ["utils.css_helper"] = "build/dawn/utils/css_helper.lua",
      ["utils.log_level"] = "build/dawn/utils/log_level.lua",
      ["utils.base64"] = "build/dawn/utils/base64.lua",
      ["utils.linkedlist"] = "build/dawn/utils/linkedlist.lua",
      ["utils.fibheap"] = "build/dawn/utils/fibheap.lua",
      ["utils.promise"] = "build/dawn/utils/promise.lua",
      ["utils.set"] = "build/dawn/utils/set.lua",
      ["utils.logger"] = "build/dawn/utils/logger.lua",
      ["runtime.scheduler"] = "build/dawn/runtime/scheduler.lua",
      ["runtime.loop"] = "build/dawn/runtime/loop.lua",
   }
}
