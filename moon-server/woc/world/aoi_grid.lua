-- World of ClaudeCraft — AOI Grid (C++ native spatial index)
-- 用 Moon 的 C++ aoi 模块替代纯 Lua 网格, 提供与旧 grid.lua 兼容接口
-- aoi.query(cx, cz, w, h, out) 为中心矩形 [cx-w/2, cx+w/2] x [cz-h/2, cz+h/2]
-- 返回位置在矩形内的对象 ID (整数坐标)

local aoi = require("aoi")
local config = require("config")

local M = {}

-- 世界区域: -5000..5000, 16 码节点
local aoiInst = aoi.new(-5000, -5000, 10000, 16)

-- 查询矩形比圆半径各加 1 码 (整数坐标舍入余量), 后续用浮点圆距过滤
local QUERY_MARGIN = 1

--- 每实体兴趣尺寸 (影响 aoi 事件系统, 不影响基本 query)
local function viewSizeFor(e)
    if e.kind == "player" or e.kind == "pet" then
        return config.INTEREST_RADIUS or 90
    end
    return config.NPC_INTEREST_RADIUS or 120
end

local function toInt(v)
    return math.floor(v + 0.5)
end

--- 插入实体
function M.insert(e)
    if not e or not e.pos then return end
    local view = viewSizeFor(e)
    aoiInst:insert(e.id, toInt(e.pos.x), toInt(e.pos.z), view, view, 0, 0)
end

--- 更新实体位置
function M.update(e)
    if not e or not e.pos then return end
    local view = viewSizeFor(e)
    aoiInst:update(e.id, toInt(e.pos.x), toInt(e.pos.z), view, view, 0)
end

--- 移除实体
function M.remove(e)
    if not e then return end
    aoiInst:erase(e.id)
end

--- 检查实体是否在 AOI
function M.has(e)
    return e and aoiInst:has(e.id) or false
end

-- 查询结果池 (复用, 减少每 tick 分配)
local resultPool = {}

--- 范围查询 (浮点圆距过滤 + 最近优先 + maxCount 提前截断)
--- @param x, z 中心点 (浮点)
--- @param radius 查询半径 (yards)
--- @param entities 全局实体表 (id → entity)
--- @param maxCount 最多返回数 (nil = 全部)
function M.queryRadius(x, z, radius, entities, maxCount)
    local ids = {}
    local w = radius * 2 + QUERY_MARGIN * 2
    local count = aoiInst:query(toInt(x), toInt(z), w, w, ids)

    local result = table.remove(resultPool)
    if result then
        for i = #result, 1, -1 do result[i] = nil end
    else
        result = {}
    end

    local radiusSq = radius * radius
    for i = 1, count do
        local e = entities[ids[i]]
        if e then
            local dx = e.pos.x - x
            local dz = e.pos.z - z
            if dx * dx + dz * dz <= radiusSq then
                result[#result + 1] = e
            end
        end
    end

    -- 最近优先 (确定性: 距离升序, id 兜底)
    table.sort(result, function(a, b)
        local da = (a.pos.x - x)^2 + (a.pos.z - z)^2
        local db = (b.pos.x - x)^2 + (b.pos.z - z)^2
        if da ~= db then return da < db end
        return a.id < b.id
    end)

    if maxCount and #result > maxCount then
        for i = #result, maxCount + 1, -1 do result[i] = nil end
    end
    return result
end

--- 归还 queryRadius 结果表到池
function M.releaseRadiusResult(result)
    if result and #resultPool < 4096 then
        resultPool[#resultPool + 1] = result
    end
end

-- ===== ghost 空间索引 (纯 Lua cell 哈希, 与旧 grid.lua 一致) =====
local CELL_SIZE = 32
local ghostCells = {}
local ghostCellOf = {}
local ghostPool = {}

local function hashCell(x, z)
    return math.floor(x / CELL_SIZE) * 100000 + math.floor(z / CELL_SIZE)
end

--- 位置 → cell 键 (供外部空间裁剪复用)
function M.cellKey(x, z)
    return hashCell(x, z)
end

function M.ghostInsert(g)
    local h = hashCell(g.x, g.z)
    local cell = ghostCells[h]
    if not cell then cell = {}; ghostCells[h] = cell end
    table.insert(cell, g)
    ghostCellOf[g.id] = h
end

function M.ghostRemove(g)
    local h = ghostCellOf[g.id]
    if h and ghostCells[h] then
        for i, gg in ipairs(ghostCells[h]) do
            if gg.id == g.id then table.remove(ghostCells[h], i); break end
        end
        if #ghostCells[h] == 0 then ghostCells[h] = nil end
    end
    ghostCellOf[g.id] = nil
end

--- 查询 AOI 内 ghost (包围盒 cell 扫描, 过滤精确距离)
function M.queryGhosts(x, z, radius)
    local result = table.remove(ghostPool)
    if result then for i = #result, 1, -1 do result[i] = nil end else result = {} end
    local radiusSq = radius * radius
    local cellRadius = math.ceil(radius / CELL_SIZE) + 1
    local cx = math.floor(x / CELL_SIZE)
    local cz = math.floor(z / CELL_SIZE)
    for gx = cx - cellRadius, cx + cellRadius do
        for gz = cz - cellRadius, cz + cellRadius do
            local cell = ghostCells[gx * 100000 + gz]
            if cell then
                for _, g in ipairs(cell) do
                    local dx = g.x - x
                    local dz = g.z - z
                    if dx * dx + dz * dz <= radiusSq then
                        result[#result + 1] = g
                    end
                end
            end
        end
    end
    return result
end

function M.releaseGhosts(result)
    if result and #ghostPool < 4096 then
        ghostPool[#ghostPool + 1] = result
    end
end

--- 网格统计 (兼容)
function M.stats()
    return { cells = 0, entities = 0 }
end

return M
