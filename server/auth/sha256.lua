-- utils/sha256.lua
-- Pure Lua SHA256 implementation compatible with LuaJIT (uses 'bit')

local bit = require("bit")
local band, bor, bxor, bnot = bit.band, bit.bor, bit.bxor, bit.bnot
local rshift, lshift = bit.rshift, bit.lshift

local function rotr(x, n)
    return bor(rshift(x, n), lshift(x, 32 - n))
end

local H = {
    0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
    0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19
}

local K = {
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5,
    0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
    0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc,
    0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7,
    0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
    0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3,
    0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5,
    0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
    0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2
}

local function to_bytes(value)
    local bytes = {}
    for i = 7, 0, -1 do
        bytes[#bytes + 1] = string.char(rshift(value, i * 8) % 256)
    end
    return table.concat(bytes)
end

local function preproc(msg)
    local len = #msg
    local extra = 64 - ((len + 9) % 64)
    msg = msg .. "\128" .. string.rep("\0", extra)
    msg = msg .. to_bytes(len * 8)
    return msg
end

local function to_uint32(str, i)
    local b1, b2, b3, b4 = str:byte(i, i + 3)
    return bor(lshift(b1, 24), lshift(b2, 16), lshift(b3, 8), b4)
end

local function sha256(msg)
    msg = preproc(msg)
    local h = { unpack(H) }  -- Change table.unpack to unpack

    for i = 1, #msg, 64 do
        local w = {}
        for j = 0, 15 do
            w[j] = to_uint32(msg, i + j * 4)
        end
        for j = 16, 63 do
            local s0 = bxor(rotr(w[j - 15], 7), rotr(w[j - 15], 18), rshift(w[j - 15], 3))
            local s1 = bxor(rotr(w[j - 2], 17), rotr(w[j - 2], 19), rshift(w[j - 2], 10))
            w[j] = band(w[j - 16] + s0 + w[j - 7] + s1, 0xffffffff)
        end

        local a, b, c, d, e, f, g, h0 = unpack(h)  -- Change table.unpack to unpack

        for j = 0, 63 do
            local S1 = bxor(rotr(e, 6), rotr(e, 11), rotr(e, 25))
            local ch = bxor(band(e, f), band(bnot(e), g))
            local temp1 = band(h0 + S1 + ch + K[j + 1] + w[j], 0xffffffff)
            local S0 = bxor(rotr(a, 2), rotr(a, 13), rotr(a, 22))
            local maj = bxor(band(a, b), band(a, c), band(b, c))
            local temp2 = band(S0 + maj, 0xffffffff)

            h0 = g
            g = f
            f = e
            e = band(d + temp1, 0xffffffff)
            d = c
            c = b
            b = a
            a = band(temp1 + temp2, 0xffffffff)
        end

        h[1] = band(h[1] + a, 0xffffffff)
        h[2] = band(h[2] + b, 0xffffffff)
        h[3] = band(h[3] + c, 0xffffffff)
        h[4] = band(h[4] + d, 0xffffffff)
        h[5] = band(h[5] + e, 0xffffffff)
        h[6] = band(h[6] + f, 0xffffffff)
        h[7] = band(h[7] + g, 0xffffffff)
    end

    return string.format("%08x%08x%08x%08x%08x%08x%08x%08x",
        h[1], h[2], h[3], h[4], h[5], h[6], h[7], h[8])
end


return {
    sha256_hex = sha256
}
