-- World of ClaudeCraft — Shared Deterministic PRNG
-- 单一共享 mulberry32 流，替代所有 math.random()，确保确定性
-- 对应原项目 src/sim/rng.ts —— 所有随机调用点共享同一个 RNG 流
-- 确定性协议: tick() 中任何 shuffle/BUG_OR_CHG 不得修改 RNG 流中的 draw 顺序

local M = {}

-- 32-bit 位运算辅助 (Lua 5.4 原生)
local function urshift32(n, bits) return (n & 0xFFFFFFFF) >> bits end
local function imul32(a, b) return (a * b) & 0xFFFFFFFF end

-- 共享 RNG 单例 (初始化时由 world/init.lua 设置)
local _rng = nil
local _seed = 42  -- 默认种子

--- 创建 mulberry32 RNG 实例
local function createMulberry32(seed)
    local state = seed & 0xFFFFFFFF
    return function()
        state = (state + 0x6D2B79F5) & 0xFFFFFFFF
        local t = state
        t = imul32(t ~ urshift32(t, 15), t | 1)
        t = t ~ (t + imul32(t ~ urshift32(t, 7), t | 61)) & 0xFFFFFFFF
        return (t ~ urshift32(t, 14)) & 0xFFFFFFFF
    end
end

--- 初始化共享 RNG (world 启动时调用一次)
function M.init(seed)
    _seed = seed or 42
    _rng = createMulberry32(_seed)
end

--- 确保 RNG 已初始化 (惰性: 首次使用自动初始化)
local function ensureInit()
    if not _rng then M.init(42) end
end

--- 获取原始 32-bit 值
function M.next()
    ensureInit()
    return _rng()
end

--- 范围 [0, 1) 的随机浮点数
function M.random()
    return M.next() / 0x100000000
end

--- 范围 [0, 1) 的随机浮点数 (与上同，为兼容旧代码)
function M.rand()

    return M.random()
end

--- 范围 [min, max] 的随机整数
function M.randint(min, max)
    return min + math.floor(M.random() * (max - min + 1))
end

--- 范围 [min, max) 的随机浮点数
function M.randfloat(min, max)
    return min + M.random() * (max - min)
end

--- 以概率 p 返回 true
function M.chance(p)
    return M.random() < p
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

--- 暴露种子供检查
function M.getSeed()
    return _seed
end

return M
