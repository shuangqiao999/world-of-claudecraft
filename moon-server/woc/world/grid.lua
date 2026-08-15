-- World of ClaudeCraft — Spatial Grid
-- 空间网格用于兴趣管理 (Interest Management)
-- 将世界划分为等大 cell，加速实体查询

local config = require("config")

-- 空间索引: 默认委托给 C++ aoi 空间索引 (world.aoi_grid); 设 WOC_AOI_GRID=0 回退纯 Lua 网格。
-- 所有模块经 require("world.grid") 共享同一索引, 保证 insert/query 状态一致。
-- aoi 模块缺失/加载失败时兜底回退, 避免 AOI/快照/索敌路径崩溃。
if config.USE_AOI_GRID then
    local ok, aoiGrid = pcall(require, "world.aoi_grid")
    if ok and aoiGrid then
        return aoiGrid
    end
    print("[Grid] WARNING: aoi spatial index unavailable, falling back to pure-Lua grid")
end

local M = {}

local CELL_SIZE = 32  -- 每个 cell 32 yards (TS spatial.ts:14)
local cells = {}       -- cells[hash] = { entityId1, entityId2, ... }
local entityCells = {} -- entityId → cell hash
local resultPool = {}  -- queryRadius 结果表池 (复用, 减少每 tick 分配)

--- 计算 cell hash (数值键, 无字符串分配)
local function hashCell(x, z)
    return math.floor(x / CELL_SIZE) * 100000 + math.floor(z / CELL_SIZE)
end

--- 位置 → cell 键 (供外部空间裁剪复用)
function M.cellKey(x, z)
    return math.floor(x / CELL_SIZE) * 100000 + math.floor(z / CELL_SIZE)
end

--- 添加实体到网格
function M.insert(entity)
    local id = entity.id
    local h = hashCell(entity.pos.x, entity.pos.z)

    if not cells[h] then
        cells[h] = {}
    end

    -- 避免重复
    local found = false
    for _, eid in ipairs(cells[h]) do
        if eid == id then found = true; break end
    end
    if not found then
        table.insert(cells[h], id)
    end

    entityCells[id] = h
end

--- 从网格移除实体
function M.remove(entity)
    local id = entity.id
    local h = entityCells[id]
    if h and cells[h] then
        for i, eid in ipairs(cells[h]) do
            if eid == id then
                table.remove(cells[h], i)
                break
            end
        end
        if #cells[h] == 0 then cells[h] = nil end
    end
    entityCells[id] = nil
end

--- 更新实体位置 (cell 变化时移动)
function M.update(entity)
    local oldHash = entityCells[entity.id]
    local newHash = hashCell(entity.pos.x, entity.pos.z)

    if oldHash ~= newHash then
        M.remove(entity)
        M.insert(entity)
    end
end

-- 访问单个 cell: 把范围内的实体加入 result (返回新 count, 是否已到 maxCount)
-- 模块级函数 (无闭包), 供 queryRadius 螺旋遍历复用, 避免每查询分配闭包
local function visitCell(gx, gz, x, z, radiusSq, entities, result, count, maxCount)
    local cell = cells[gx * 100000 + gz]
    if cell then
        for _, eid in ipairs(cell) do
            local e = entities[eid]
            if e then
                local dx = e.pos.x - x
                local dz = e.pos.z - z
                if dx * dx + dz * dz <= radiusSq then
                    result[#result + 1] = e
                    count = count + 1
                    if maxCount and count >= maxCount then return count, true end
                end
            end
        end
    end
    return count, false
end

--- 查询范围内的实体 (同心方环遍历: 中心 cell 优先, 结果近似按距离升序)
--- @param x number 中心 X
--- @param z number 中心 Z
--- @param radius number 查询半径 (yards)
--- @param entities table 全局实体表 {id → Entity}
--- @param maxCount number|nil 最多返回的实体数 (螺旋最近优先, 达到即提前停止)
--- @return table 实体列表 (近似最近优先, 供 AOI 上限直接截断)
function M.queryRadius(x, z, radius, entities, maxCount)
    local result = table.remove(resultPool)
    if result then
        for i = #result, 1, -1 do result[i] = nil end
    else
        result = {}
    end
    local radiusSq = radius * radius
    local cellRadius = math.ceil(radius / CELL_SIZE) + 1
    local cx = math.floor(x / CELL_SIZE)
    local cz = math.floor(z / CELL_SIZE)
    local count = 0
    local done = false

    count, done = visitCell(cx, cz, x, z, radiusSq, entities, result, count, maxCount) -- ring 0 (中心 cell)
    for ring = 1, cellRadius do
        if done then break end
        local top = cz - ring
        local bottom = cz + ring
        local left = cx - ring
        local right = cx + ring
        for d = left, right do
            if done then break end
            count, done = visitCell(d, top, x, z, radiusSq, entities, result, count, maxCount)
            if done then break end
            count, done = visitCell(d, bottom, x, z, radiusSq, entities, result, count, maxCount)
        end
        if done then break end
        for d = cz - ring + 1, cz + ring - 1 do
            if done then break end
            count, done = visitCell(left, d, x, z, radiusSq, entities, result, count, maxCount)
            if done then break end
            count, done = visitCell(right, d, x, z, radiusSq, entities, result, count, maxCount)
        end
    end

    return result
end

--- 归还 queryRadius 结果表到池 (调用方用完 result 后调用)
function M.releaseRadiusResult(result)
    if result and #resultPool < 4096 then
        resultPool[#resultPool + 1] = result
    end
end

-- ===== 跨分片 ghost 空间索引 =====
-- ghost 不是主实体 (不在 entities 表), 单独用一套 cell 索引, 快照构建只查 AOI 内 ghost
local ghostCells = {}   -- hash → { ghost1, ghost2, ... }
local ghostCellOf = {}  -- ghost.id → hash
local ghostPool = {}    -- queryGhosts 结果池

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

--- 获取网格统计
function M.stats()
    local cellCount = 0
    local totalEntities = 0
    for _, cell in pairs(cells) do
        cellCount = cellCount + 1
        totalEntities = totalEntities + #cell
    end
    return { cells = cellCount, entities = totalEntities }
end

return M
