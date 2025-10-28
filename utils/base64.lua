-- base64.lua
local ffi = require("ffi")
local bit = require("bit")

local base64 = {}

local b64chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'
local b64enc = {}
local b64dec = {}

for i = 1, #b64chars do
    local c = b64chars:sub(i, i)
    b64enc[i - 1] = c
    b64dec[c] = i - 1
end

-- Base64 Encode
function base64.encode(input)
    local output = {}
    local bytes = {input:byte(1, #input)}
    local i = 1

    while i <= #bytes do
        local b1 = bytes[i] or 0
        local b2 = bytes[i + 1] or 0
        local b3 = bytes[i + 2] or 0

        local triple = bit.lshift(b1, 16) + bit.lshift(b2, 8) + b3

        table.insert(output, b64enc[bit.band(bit.rshift(triple, 18), 0x3F)])
        table.insert(output, b64enc[bit.band(bit.rshift(triple, 12), 0x3F)])
        table.insert(output, i + 1 <= #bytes and b64enc[bit.band(bit.rshift(triple, 6), 0x3F)] or "=")
        table.insert(output, i + 2 <= #bytes and b64enc[bit.band(triple, 0x3F)] or "=")

        i = i + 3
    end

    return table.concat(output)
end

-- Base64 Decode
function base64.decode(input)
    input = input:gsub("[^" .. b64chars .. "=]", "")
    local output = {}
    local n, t = 0, 0

    for c in input:gmatch(".") do
        if c ~= '=' then
            t = t * 64 + b64dec[c]
            n = n + 1
            if n == 4 then
                table.insert(output, string.char(
                    bit.band(bit.rshift(t, 16), 0xFF),
                    bit.band(bit.rshift(t, 8), 0xFF),
                    bit.band(t, 0xFF)
                ))
                n, t = 0, 0
            end
        end
    end

    if n == 3 then
        t = t * 64
        table.insert(output, string.char(
            bit.band(bit.rshift(t, 16), 0xFF),
            bit.band(bit.rshift(t, 8), 0xFF)
        ))
    elseif n == 2 then
        t = t * 64 * 64
        table.insert(output, string.char(
            bit.band(bit.rshift(t, 16), 0xFF)
        ))
    end

    return table.concat(output)
end

return base64