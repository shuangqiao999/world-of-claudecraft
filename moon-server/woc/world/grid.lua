-- World of ClaudeCraft — Spatial Grid
-- 空间网格用于兴趣管理 (Interest Management)
-- 将世界划分为等大 cell，加速实体查询

local config = require("config")

local M = {}

local CELL_SIZE = 32  -- 每个 cell 32 yards (TS spatial.ts:14)
local cells = {}       -- cells[hash] = { entityId1, entityId2, ... }
local entityCells = {} -- entityId → cell hash

--- 计算 cell hash (数值键, 无字符串分配)
local function hashCell(x, z)
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

--- 查询范围内的实体 (同心方环遍历: 中心 cell 优先, 结果近似按距离升序)
--- @param x number 中心 X
--- @param z number 中心 Z
--- @param radius number 查询半径 (yards)
--- @param entities table 全局实体表 {id → Entity}
--- @param maxCount number|nil 最多返回的实体数 (螺旋最近优先, 达到即提前停止)
--- @return table 实体列表 (近似最近优先, 供 AOI 上限直接截断)
function M.queryRadius(x, z, radius, entities, maxCount)
    local result = {}
    local seen = {}
    local radiusSq = radius * radius
    local cellRadius = math.ceil(radius / CELL_SIZE) + 1
    local cx = math.floor(x / CELL_SIZE)
    local cz = math.floor(z / CELL_SIZE)
    local count = 0
    local done = false

    local function visitCell(gx, gz)
        if done then return end
        local cell = cells[gx * 100000 + gz]
        if cell then
            for _, eid in ipairs(cell) do
                if not seen[eid] then
                    seen[eid] = true
                    local e = entities[eid]
                    if e then
                        local dx = e.pos.x - x
                        local dz = e.pos.z - z
                        if dx * dx + dz * dz <= radiusSq then
                            table.insert(result, e)
                            count = count + 1
                            if maxCount and count >= maxCount then done = true; return end
                        end
                    end
                end
            end
        end
    end

    visitCell(cx, cz) -- ring 0 (中心 cell)
    for ring = 1, cellRadius do
        if done then break end
        local top = cz - ring
        local bottom = cz + ring
        local left = cx - ring
        local right = cx + ring
        for d = left, right do
            if done then break end
            visitCell(d, top)
            visitCell(d, bottom)
        end
        if done then break end
        for d = cz - ring + 1, cz + ring - 1 do
            if done then break end
            visitCell(left, d)
            visitCell(right, d)
        end
    end

    return result
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
