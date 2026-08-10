-- World of ClaudeCraft — Pseudo-Random Number Generator
-- mulberry32 确定性 PRNG (使用 Lua 5.4 原生位运算符)
-- 对应原项目 src/sim/rng.ts
-- 必须与原 TypeScript 版本逐位一致

local M = {}

--- 32-bit 无符号右移 (Lua 5.4 原生)
--- Lua 5.4 的 >> 对于非负数等价于无符号右移
local function urshift32(n, bits)
    return (n & 0xFFFFFFFF) >> bits
end

--- 32-bit 乘法 (模拟 Math.imul)
local function imul32(a, b)
    return (a * b) & 0xFFFFFFFF
end

--- 创建新的 mulberry32 PRNG 实例
--- 必须产生与原项目 TypeScript 版本相同的序列
--- @param seed number 32-bit 无符号整数种子
function M.create(seed)
    local state = seed & 0xFFFFFFFF

    return function()
        -- state += 0x6D2B79F5 (mulberry32 魔数)
        state = (state + 0x6D2B79F5) & 0xFFFFFFFF
        local t = state

        -- t = Math.imul(t ^ (t >>> 15), t | 1)
        t = imul32(t ~ urshift32(t, 15), t | 1)

        -- t ^= t + Math.imul(t ^ (t >>> 7), t | 61)
        t = t ~ (t + imul32(t ~ urshift32(t, 7), t | 61)) & 0xFFFFFFFF

        -- return ((t ^ (t >>> 14)) >>> 0)
        return (t ~ urshift32(t, 14)) & 0xFFFFFFFF
    end
end

--- 生成范围 [0, 1) 的随机浮点数
function M.random(rng)
    return rng() / 0x100000000  -- 除以 2^32
end

--- 生成范围 [min, max] 的随机整数
function M.randint(rng, min, max)
    return min + math.floor(M.random(rng) * (max - min + 1))
end

--- 生成范围 [min, max) 的随机浮点数
function M.randfloat(rng, min, max)
    return min + M.random(rng) * (max - min)
end

--- 以概率 p 返回 true
function M.chance(rng, p)
    return M.random(rng) < p
end

--- 字符串哈希 → 32-bit 无符号整数
function M.hashString(str)
    local hash = 0
    for i = 1, #str do
        local ch = string.byte(str, i)
        hash = ((hash << 5) ~ hash) & 0xFFFFFFFF
        hash = (hash ~ ch) & 0xFFFFFFFF
    end
    return hash
end

return M
