package = "dawn"
version = "1.0-1"

source = {
   url = "git+https://github.com/winslygeorge/dawn.git",
   branch = "master"
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
      ["layout.renderer.layout_model"] = "dawn/layout/renderer/layout_model.lua",
      ["layout.renderer.lustache_renderer"] = "dawn/layout/renderer/lustache_renderer.lua",
      ["layout.renderer.Controller"] = "dawn/layout/renderer/Controller.lua",
      ["layout.renderer.FuncComponent"] = "dawn/layout/renderer/FuncComponent.lua",
      ["dawn"] = "dawn/dawn.lua",
      ["auth.refresh_handler"] = "dawn/server/auth/refresh_handler.lua",
      ["auth.purejwt"] = "dawn/server/auth/purejwt.lua",
      ["auth.jwt_protect"] = "dawn/server/auth/jwt_protect.lua",
      ["auth.token_cleaner"] = "dawn/server/auth/token_cleaner.lua",
      ["auth.sha256"] = "dawn/server/auth/sha256.lua",
      ["auth.logout_handler"] = "dawn/server/auth/logout_handler.lua",
      ["auth.rate_limiting_middleware"] = "dawn/server/auth/rate_limiting_middleware.lua",
      ["auth.token_store"] = "dawn/server/auth/token_store.lua",
      ["auth.session_middleware"] = "dawn/server/auth/session_middleware.lua",
      ["multipart_parser"] = "dawn/server/multipart_parser.lua",
      ["dawn_server"] = "dawn/server/dawn_server.lua",
      ["dawn_sockets"] = "dawn/server/dawn_sockets.lua",
      ["websockets.presence_interface"] = "dawn/server/websockets/presence_interface.lua",
      ["utils.query_extractor"] = "dawn/utils/query_extractor.lua",
      ["utils.uuid"] = "dawn/utils/uuid.lua",
      ["utils.queue"] = "dawn/utils/queue.lua",
      ["utils.css_helper"] = "dawn/utils/css_helper.lua",
      ["utils.log_level"] = "dawn/utils/log_level.lua",
      ["utils.base64"] = "dawn/utils/base64.lua",
      ["utils.linkedlist"] = "dawn/utils/linkedlist.lua",
      ["utils.fibheap"] = "dawn/utils/fibheap.lua",
      ["utils.promise"] = "dawn/utils/promise.lua",
      ["utils.set"] = "dawn/utils/set.lua",
      ["utils.logger"] = "dawn/utils/logger.lua",
      ["runtime.scheduler"] = "dawn/runtime/scheduler.lua",
      ["runtime.loop"] = "dawn/runtime/loop.lua",
   }
}
