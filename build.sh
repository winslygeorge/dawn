#!/bin/bash

set -e

# === CONFIGURATION ===
PACKAGE="dawn"
VERSION="1.0-1"
ROCKSPEC_NAME="$PACKAGE-$VERSION.rockspec"
SO_MODULE_NAME="dawn.server.core"  # require("dawn.server.core")
C_SRC="server/check_version.cpp"
SO_FILENAME="core.so"

SRC_DIR=$(pwd)
BUILD_DIR="$SRC_DIR/build"
MODULE_ROOT="$BUILD_DIR/dawn"
ROCKSPEC_PATH="$BUILD_DIR/$ROCKSPEC_NAME"

# === 0. Install Build Dependencies ===
echo "[0/6] Installing system dependencies..."
sudo apt update
sudo apt install -y git cmake python3 g++ libssl-dev libpq-dev zlib1g-dev lua5.1 luajit libluajit-5.1-dev

# === 1. Clean previous builds ===
echo "[1/6] Cleaning build directory..."
rm -rf "$BUILD_DIR"
mkdir -p "$MODULE_ROOT"

# === 2. Compile .lua to .luac ===
echo "[2/6] Compiling .lua files to .luac..."
find "$SRC_DIR" -name "*.lua" | while read lua_file; do
  rel_path="${lua_file#$SRC_DIR/}"
  out_file="$MODULE_ROOT/${rel_path%.lua}.lua"
  mkdir -p "$(dirname "$out_file")"
  luajit -b "$lua_file" "$out_file"
done


# === 4. Generate .rockspec ===
echo "[4/6] Generating rockspec..."
cat > "$ROCKSPEC_PATH" <<EOF
package = "$PACKAGE"
version = "$VERSION"

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
EOF

# Add .luac modules
find "$MODULE_ROOT" -name "*.lua" | while read luac_file; do
  mod_path="${luac_file#$MODULE_ROOT/}"
  mod_name="${mod_path%.lua}"
  mod_name="${mod_name//\//.}"
  echo "      [\"$mod_name\"] = \"dawn/${mod_path}\"," >> "$ROCKSPEC_PATH"
done

# Add compiled .so if present
if [ -n "$SO_FILENAME" ]; then
  echo "      [\"$SO_MODULE_NAME\"] = \"dawn/server/$SO_FILENAME\"," >> "$ROCKSPEC_PATH"
fi

# Close the rockspec
cat >> "$ROCKSPEC_PATH" <<EOF
   }
}
EOF

# === 5. Done ===
echo "[5/6] ✅ Build complete"
echo "Output directory: $BUILD_DIR"
echo "Generated rockspec: $ROCKSPEC_PATH"

# === 6. Packaging Reminder ===
echo "[6/6] To package and upload:"
echo "  cd build"
echo "  luarocks pack $ROCKSPEC_NAME"
echo "  luarocks upload $ROCKSPEC_NAME --api-key=YOUR_API_KEY"
