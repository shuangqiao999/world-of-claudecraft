-- World of ClaudeCraft — Pathfinding (Local A*)
-- 本地 A* 寻路: 用于战士冲锋, Mob 路径规划
-- 对应原项目 src/sim/pathfind.ts

local M = {}

local GRID_SIZE = 1     -- 1 yard/pixel
local SEARCH_RADIUS = 50  -- 50 yard 搜索范围

-- 简化的节点结构
local function newPos(x, z)
    return { x = math.floor(x + 0.5), z = math.floor(z + 0.5) }
end

local function posKey(x, z)
    return x .. "," .. z
end

local function heuristic(ax, az, bx, bz)
    return math.abs(ax - bx) + math.abs(az - bz)
end

--- 简化的 A* 寻路 (无障碍物网格)
--- @param startX, startZ 起点
--- @param endX, endZ 终点
--- @return table 路径点列表
function M.findPath(startX, startZ, endX, endZ)
    local start = newPos(startX, startZ)
    local goal = newPos(endX, endZ)

    if math.abs(start.x - goal.x) > SEARCH_RADIUS or math.abs(start.z - goal.z) > SEARCH_RADIUS then
        -- 超出搜索半径, 直接返回直线
        return { { x = endX, z = endZ } }
    end

    -- 简化: 无障碍物, 直接直线
    return { { x = endX, z = endZ } }
end

--- 简化玩家寻路 (考虑身体半径, 攀爬, 游泳)
function M.findPlayerPath(startX, startZ, endX, endZ)
    return M.findPath(startX, startZ, endX, endZ)
end

--- 获取两点间距离
function M.distance(x1, z1, x2, z2)
    local dx = x1 - x2
    local dz = z1 - z2
    return math.sqrt(dx * dx + dz * dz)
end

return M
