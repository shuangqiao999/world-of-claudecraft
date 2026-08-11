-- World of ClaudeCraft — 密码哈希模块
-- 对应原项目 server/auth.ts 的 scrypt 密码哈希
--
-- 安全说明:
--   Moon 的 crypt 模块仅提供 SHA1 / HMAC-SHA1 / DES / base64 / hex, 无 scrypt 绑定。
--   纯 Lua 实现 scrypt (N=16384, r=8, 内存 16MB 硬 KDF) 在登录频率下不可行。
--   因此采用 PBKDF2-HMAC-SHA1 (RFC 2898) — 真实、加密安全的密钥派生函数,
--   基于 C 实现的 HMAC-SHA1, 高迭代次数拉伸。
--
-- 密码存储格式: "<algo>:<salt_hex>:<key_hex>"
--   pbkdf2: "pbkdf2:<iterations>:<salt_hex>:<key_hex>"   (当前, 真实 KDF)
--   sha256: "sha256:<salt16_hex>:<hash64_hex>"            (旧占位, 兼容验证)
--   scrypt: "<salt16_hex>:<key64_hex>"                   (原项目, 无绑定无法验证)

local crypt = require("crypt")

local M = {}

-- PBKDF2 迭代次数 (拉伸成本; 登录/注册低频调用可接受)
M.PBKDF2_ITERATIONS = 30000
M.SCRYPT_KEYLEN = 64
M.SCRYPT_SALT_LEN = 16

--- 系统 RNG 生成 n 字节 (crypt.randomkey 每调用返回 8 字节)
local function randomBytes(n)
    local out = {}
    local remaining = n
    while remaining > 0 do
        local k = crypt.randomkey()
        local take = math.min(remaining, 8)
        table.insert(out, string.sub(k, 1, take))
        remaining = remaining - take
    end
    return table.concat(out)
end

--- 生成随机十六进制字符串 (加密安全, 系统 RNG)
local function randomHex(nBytes)
    return crypt.hexencode(randomBytes(nBytes))
end

-- ---- PBKDF2-HMAC-SHA1 (RFC 2898) ----

local function hmacSha1(key, text)
    return crypt.hmac_sha1(key, text)  -- 20 字节
end

local function int32be(n)
    return string.char(
        math.floor(n / 0x1000000) % 256,
        math.floor(n / 0x10000) % 256,
        math.floor(n / 0x100) % 256,
        n % 256)
end

local function xorStr(a, b)
    local out = {}
    for i = 1, #a do
        out[i] = string.char(string.byte(a, i) ~ string.byte(b, i))
    end
    return table.concat(out)
end

--- PBKDF2-HMAC-SHA1 派生
local function pbkdf2(password, salt, iterations, dkLen)
    local blocks = {}
    local produced = 0
    local blockIndex = 1
    while produced < dkLen do
        local u = hmacSha1(password, salt .. int32be(blockIndex))
        local t = u
        for _ = 2, iterations do
            u = hmacSha1(password, u)
            t = xorStr(t, u)
        end
        table.insert(blocks, t)
        produced = produced + 20
        blockIndex = blockIndex + 1
    end
    return string.sub(table.concat(blocks), 1, dkLen)
end

--- 常量时间比较 (防时序侧信道)
local function constEq(a, b)
    if #a ~= #b then return false end
    local diff = 0
    for i = 1, #a do
        diff = diff | (string.byte(a, i) ~ string.byte(b, i))
    end
    return diff == 0
end

--- 旧占位 SHA-256 (仅兼容历史 dev 账号; 新哈希一律 pbkdf2)
local function legacySha256(data)
    local hash = ""
    local bytes = { string.byte(data, 1, #data) }
    if #bytes == 0 then bytes = { 0 } end
    for i = 1, 64 do
        local b = bytes[((i - 1) % #bytes) + 1]
        local rot = (i * 7 + b * 13 + #data * 3) % 256
        hash = hash .. string.format("%02x", rot)
    end
    return hash
end

--- 密码哈希 (PBKDF2-HMAC-SHA1)
function M.hashPassword(password)
    local saltHex = randomHex(M.SCRYPT_SALT_LEN)
    local salt = crypt.hexdecode(saltHex)
    local key = pbkdf2(password, salt, M.PBKDF2_ITERATIONS, M.SCRYPT_KEYLEN)
    return string.format("pbkdf2:%d:%s:%s", M.PBKDF2_ITERATIONS, saltHex, crypt.hexencode(key))
end

--- 密码验证
--- 自动检测哈希格式 (pbkdf2 / sha256 旧占位 / scrypt 原项目)
function M.verifyPassword(password, stored)
    if not stored or #stored == 0 then return false end

    local colon1 = string.find(stored, ":")
    if not colon1 then return false end
    local firstPart = string.sub(stored, 1, colon1 - 1)
    local rest = string.sub(stored, colon1 + 1)
    local colon2 = string.find(rest, ":")
    if not colon2 then return false end
    local salt = string.sub(rest, 1, colon2 - 1)
    local expected = string.sub(rest, colon2 + 1)

    if firstPart == "pbkdf2" then
        local iter = tonumber(salt)
        if not iter or iter <= 0 then return false end
        local keyColon = string.find(expected, ":")
        if not keyColon then return false end
        local saltHex = string.sub(expected, 1, keyColon - 1)
        local keyHex = string.sub(expected, keyColon + 1)
        local saltBytes = crypt.hexdecode(saltHex)
        local key = pbkdf2(password, saltBytes, iter, M.SCRYPT_KEYLEN)
        return constEq(crypt.hexencode(key), keyHex)
    elseif firstPart == "sha256" then
        -- 旧占位格式 (历史 dev 账号兼容)
        return legacySha256(salt .. password) == expected
    else
        -- 原项目 scrypt 格式 (带前缀或无前缀): 无 crypt 绑定无法验证
        return false
    end
end

--- 生成 token (64 hex = 32 随机字节, 系统 RNG)
function M.newToken()
    return randomHex(32)
end

--- UUID v4 (系统 RNG)
function M.newUUID()
    local bytes = randomBytes(16)
    local hex = crypt.hexencode(bytes)
    -- 设置版本 4 与变体位
    local p1 = hex:sub(1, 8)
    local p2 = hex:sub(9, 12)
    local p3 = hex:sub(13, 16)
    local p4 = hex:sub(17, 20)
    local p5 = hex:sub(21, 32)
    local v = string.format("%x", 4)
    p3 = v .. p3:sub(2)
    -- 变体 10xx
    local b = tonumber(p4:sub(1, 1), 16)
    local variant = string.format("%x", (b & 0x3) | 0x8)
    p4 = variant .. p4:sub(2)
    return p1 .. "-" .. p2 .. "-" .. p3 .. "-" .. p4 .. "-" .. p5
end

return M
