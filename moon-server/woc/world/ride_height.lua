-- World of ClaudeCraft — Ride Height
-- 对应原项目 src/sim/ride_height.ts
-- 移动体在某点"骑乘"的高度: 淹没时钳到水面, 否则地形 — 供坡度门控

local terrain = require("world.terrain")
local M = {}

M.SHORE_STEP_UP = 0.9

--- 骑乘高度 (TS rideHeight)
function M.rideHeight(x, z, h, seed)
    local level = M.waterLevelAt(x, z, seed)
    if h < level then return level end
    return h
end

function M.rideHeightAt(x, z, seed)
    return M.rideHeight(x, z, terrain.groundHeight(x, z), seed)
end

--- 两段水面取高 (TS stepWaterLevel)
function M.stepWaterLevel(x0, z0, x1, z1, seed)
    local l0 = M.waterLevelAt(x0, z0, seed)
    local l1 = M.waterLevelAt(x1, z1, seed)
    if l0 == -math.huge and l1 == -math.huge then return -math.huge end
    return math.max(l0, l1)
end

--- 脚下是否在水中 (TS isSubmergedAt)
function M.isSubmergedAt(x, z, seed)
    return terrain.groundHeight(x, z) < M.waterLevelAt(x, z, seed)
end

--- 骑乘表面陡峭度 (TS rideSteepnessAt: 记忆化)
function M.rideSteepnessAt(x, z, seed)
    local h = M.rideHeightAt(x, z, seed)
    local hN = M.rideHeight(x, z - 0.35, terrain.groundHeight(x, z - 0.35), seed)
    local hE = M.rideHeight(x + 0.35, z, terrain.groundHeight(x + 0.35, z), seed)
    local maxRise = math.max(hN, hE) - h
    return math.max(0, maxRise) / 0.35
end

--- 岸上跨出 (TS shoreStepOut): 太陡的岸边有低可站立唇则允许
function M.shoreStepOut(x0, z0, x1, z1, seed, maxSlope)
    -- 简化: 检查目标点是否低于水面 (可站立浅水唇)
    local g1 = terrain.groundHeight(x1, z1)
    local level = M.waterLevelAt(x1, z1, seed)
    if level == -math.huge then return false end
    return g1 >= level - M.SHORE_STEP_UP and g1 <= level + 0.2
end

--- 水面高度 (TS waterLevelAt: 湖/海则水面, 否则 -Infinity)
function M.waterLevelAt(x, z, seed)
    -- 简化: 全部水域统一高度 (无自定义地图)
    if terrain.isInWaterBody and terrain.isInWaterBody(x, z) then
        return terrain.getWaterLevel()
    end
    return -math.huge
end

return M
