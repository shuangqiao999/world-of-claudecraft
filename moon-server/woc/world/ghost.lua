-- World of ClaudeCraft — 跨分片 ghost 实体同步 (Phase 2)
-- 空间分片下, 每分片只仿真自己 region 的实体; 边界实体复制为 ghost 同步给相邻分片,
-- 使边界玩家能看见/感知相邻分片的单位 (快照层只读, 不参与本分片仿真)。

local config = require("config")
local snapshot = require("world.snapshot")

local M = {}

--- 序列化一个实体为 ghost (完整 wire 记录 + LITE wire 记录 + 空间坐标 + 归属分片)
--- @param e Entity
--- @param ownerShard number 实体归属分片 (跨片战斗转发用)
--- @return {id, x, z, ownerShard, kind, pedestrian, json, full, lite}
---   json/full 为完整 wire JSON (首见下发), lite 为变化时下发的 LITE JSON (P2a)
--- _wireVer 缓存: 实体版本未变直接复用上次序列化结果 (静态 NPC/节点零重编码,
--- 移动 mob 也只在变化时重建), 满足 region 内部 ghost 的开销控制要求。
function M.serialize(e, ownerShard)
    local cache = e._ghostCache
    if not cache or cache.ver ~= e._wireVer then
        cache = {
            ver = e._wireVer,
            full = snapshot.buildGhostWire(e),
            lite = snapshot.buildGhostLite(e),
        }
        e._ghostCache = cache
    end
    return {
        id = e.id,
        x = e.pos.x,
        z = e.pos.z,
        ownerShard = ownerShard,
        kind = e.kind,
        pedestrian = e.pedestrian or false,
        json = cache.full,
        full = cache.full,
        lite = cache.lite,
    }
end

--- 判断实体是否在 region 边界 INTEREST_QUERY_RADIUS(135yd) 内 (需同步给邻居)
--- @param x number
--- @param z number
function M.isBoundary(x, z)
    local rx, rz = config.regionOf(x, z)
    local minX, minZ = rx * config.REGION_SIZE, rz * config.REGION_SIZE
    local maxX, maxZ = (rx + 1) * config.REGION_SIZE, (rz + 1) * config.REGION_SIZE
    local R = config.INTEREST_QUERY_RADIUS
    return (x - minX < R) or (maxX - x < R) or (z - minZ < R) or (maxZ - z < R)
end

return M
