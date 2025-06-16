return {
  -- Runtime core
  loop = require("runtime.loop"),
  scheduler = require("runtime.scheduler"),

  -- Server core
  dawn_server = require("dawn_server"),
  dawn_sockets = require("dawn_sockets"),
  multipart_parser = require("multipart_parser"),

  -- WebSockets
  presence_interface = require("websockets.presence_interface"),

  -- Auth
  jwt_protect = require("auth.jwt_protect"),
  purejwt = require("auth.purejwt"),
  token_store = require("auth.token_store"),
  session_middleware = require("auth.session_middleware"),
  rate_limiting_middleware = require("auth.rate_limiting_middleware"),
  refresh_handler = require("auth.refresh_handler"),
  logout_handler = require("auth.logout_handler"),
  sha256 = require("auth.sha256"),

  -- Layout and rendering
  Controller = require("layout.renderer.Controller"),
  FuncComponent = require("layout.renderer.FuncComponent"),
  layout_model = require("layout.renderer.layout_model"),
  lustache_renderer = require("layout.renderer.lustache_renderer"),

  -- Utils
  base64 = require("utils.base64"),
  css_helper = require("utils.css_helper"),
  fibheap = require("utils.fibheap"),
  linkedlist = require("utils.linkedlist"),
  log_level = require("utils.log_level"),
  logger = require("utils.logger"),
  promise = require("utils.promise"),
  query_extractor = require("utils.query_extractor"),
  queue = require("utils.queue"),
  set = require("utils.set"),
  uuid = require("utils.uuid")
}
