-- World of ClaudeCraft — AOI Grid (C++ native spatial index)
-- 用 Moon 的 C++ aoi 模块替代纯 Lua 网格, 提供与旧 grid.lua 兼容接口
-- aoi.query(cx, cz, w, h, out) 为中心矩形 [cx-w/2, cx+w/2] x [cz-h/2, cz+h/2]
-- 返回位置在矩形内的对象 ID (整数坐标)

local aoi = require("aoi")
local config = require("config")

local M = {}

-- 世界区域: -5000..5000, 16 码节点
local aoiInst = aoi.new(-5000, -5000, 10000, 16)

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

--- 范围查询 (返回实体列表, 兼容旧 grid.queryRadius)
--- @param x, z 中心点
--- @param radius 查询半径
--- @param entities 全局实体表 (用于 id → entity 解析)
function M.queryRadius(x, z, radius, entities)
    local ids = {}
    local count = aoiInst:query(toInt(x), toInt(z), radius * 2, radius * 2, ids)
    local out = {}
    for i = 1, count do
        local e = entities[ids[i]]
        if e then table.insert(out, e) end
    end
    return out
end

--- 原始 ID 查询 (返回 id 数组 + 数量, 供调用方自行解析)
function M.queryIds(x, z, radius)
    local ids = {}
    local count = aoiInst:query(toInt(x), toInt(z), radius * 2, radius * 2, ids)
    return ids, count
end

--- 网格统计 (兼容)
function M.stats()
    return { cells = 0, entities = 0 }
end

return M
