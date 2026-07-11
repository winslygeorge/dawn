# Makefile for Qoleng Lua Web Framework

PACKAGE=qoleng
VERSION=1.1-1
ROCKSPEC=$(PACKAGE)-$(VERSION).rockspec
BUILD_DIR=build

.PHONY: all build clean pack upload

## Default action
all: build

## Step 1: Build the framework (compile .luac, .so, and rockspec)
build:
	@echo "🔧 Building Qoleng framework..."
	./build.sh

## Step 2: Clean up build artifacts
clean:
	@echo "🧹 Cleaning build directory..."
	rm -rf $(BUILD_DIR)
	rm -f *.rock 

## Step 3: Package into .rock file
pack:
	@echo "📦 Packing rockspec..."
	cd $(BUILD_DIR) && luarocks pack $(ROCKSPEC)

## Step 4: Upload to LuaRocks
upload:
	@echo "🚀 Uploading to LuaRocks..."
	cd $(BUILD_DIR) && luarocks upload $(ROCKSPEC) --api-key=aFKR81EKku2cNthTNPcjZ9EsA5ieQU7r0ijG3HqT

## Show help
help:
	@echo "🛠️  Qoleng Framework Build Commands"
	@echo ""
	@echo "  make build     - Compile .luac, .so and generate rockspec"
	@echo "  make clean     - Remove build artifacts"
	@echo "  make pack      - Generate .rock file from rockspec"
	@echo "  make upload    - Upload to LuaRocks (set LUAROCKS_API_KEY)"
	@echo "  make help      - Show this help menu"
