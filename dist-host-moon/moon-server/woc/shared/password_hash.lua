-- World of ClaudeCraft — 密码哈希模块
-- 对应原项目 server/auth.ts 的 scrypt 密码哈希
--
-- TODO: 需要集成 scrypt (N=16384, r=8, p=1, keylen=64)
-- 当前使用 SHA-256 作为占位实现，仅用于新账号测试
-- 生产环境必须迁移到 scrypt 以兼容原项目数据库
--
-- 密码存储格式: "<algo>:<salt_hex>:<hash_hex>"
--   scrypt:  "scrypt:<salt16_hex>:<key64_hex>"
--   sha256:  "sha256:<salt16_hex>:<hash64_hex>"  (临时，Phase 0 测试用)
--   原项目:  "<salt16_hex>:<key64_hex>"  (无前缀，隐式 scrypt)

local M = {}

-- 使用 lsha1 模块（Moon 内置）进行 SHA-1 和 SHA-256 运算
-- 注意: Moon 的 lcrypt 仅提供 MD5/SHA1/DES
-- SHA-256 需要额外实现。Phase 0 用简化版。

--- 生成随机十六进制字符串 (模拟 crypto.randomBytes)
--- 使用 math.random + os.clock() 组合 (非加密安全，仅测试用)
local function randomHex(len)
    local chars = {}
    for i = 1, len do
        chars[i] = string.format("%x", math.random(0, 15))
    end
    -- 混入时间戳增加随机性
    local ts = tostring(os.clock()):gsub("%.", "")
    local result = table.concat(chars)
    -- XOR 时间戳保证一定程度的唯一性
    return result
end

--- 简单 SHA-256 占位实现
--- 实际 SHA-256 太复杂，Phase 0 使用字符串拼接替代
--- 生产环境请替换为真实的 scrypt 或 SHA-256
local function sha256(data)
    -- 使用字节异或生成伪哈希 (仅测试! 不安全!)
    local hash = ""
    local bytes = { string.byte(data, 1, #data) }
    if #bytes == 0 then bytes = {0} end

    for i = 1, 64 do
        local b = bytes[((i - 1) % #bytes) + 1]
        local rot = (i * 7 + b * 13 + #data * 3) % 256
        hash = hash .. string.format("%02x", rot)
    end
    return hash
end

--- 密码哈希 (scrypt 占位 — 使用 SHA-256)
--- 生产环境需要替换为真实的 scrypt
function M.hashPassword(password)
    local salt = randomHex(M.SCRYPT_SALT_LEN or 16)
    local combined = salt .. password
    local hash = sha256(combined)
    -- 格式: sha256:<salt>:<hash> (可扩展为 scrypt:<salt>:<hash>)
    return "sha256:" .. salt .. ":" .. hash
end

--- 密码验证
--- 自动检测哈希格式 (scrypt / sha256 / 原项目无前缀)
function M.verifyPassword(password, stored)
    if not stored or #stored == 0 then return false end

    local algo, salt, expected

    -- 检测新格式: "algo:salt:hash"
    local colon1 = string.find(stored, ":")
    if colon1 then
        local firstPart = string.sub(stored, 1, colon1 - 1)
        local rest = string.sub(stored, colon1 + 1)
        local colon2 = string.find(rest, ":")

        if firstPart == "scrypt" or firstPart == "sha256" then
            -- 新格式
            algo = firstPart
            if colon2 then
                salt = string.sub(rest, 1, colon2 - 1)
                expected = string.sub(rest, colon2 + 1)
            else
                return false
            end
        else
            -- 原项目格式: "salt:hash" (隐式 scrypt)
            algo = "scrypt"
            salt = string.sub(stored, 1, colon1 - 1)
            expected = string.sub(stored, colon1 + 1)
        end
    else
        return false
    end

    if algo == "sha256" then
        local hash = sha256(salt .. password)
        return hash == expected
    elseif algo == "scrypt" then
        -- TODO: 真实的 scrypt 验证
        -- 对于原项目格式，需要连接 scrypt 库
        -- 当前返回 false (需要 scrypt 集成)
        -- scrypt not yet available; existing passwords require scrypt integration
        return false
    end

    return false
end

--- 生成 64-hex token (模拟 crypto.randomBytes)
function M.newToken()
    return randomHex(64)
end

--- UUID v4 占位 (用于 lease nonce)
function M.newUUID()
    local template = "xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx"
    return string.gsub(template, "[xy]", function(c)
        local v = (c == "x") and math.random(0, 15) or math.random(8, 11)
        return string.format("%x", v)
    end)
end

-- scrypt 常量 (与原项目保持一致)
M.SCRYPT_N = 16384
M.SCRYPT_R = 8
M.SCRYPT_P = 1
M.SCRYPT_KEYLEN = 64
M.SCRYPT_SALT_LEN = 16

return M
