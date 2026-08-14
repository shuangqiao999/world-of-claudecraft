-- World of ClaudeCraft — Dungeon Interior Colliders
-- 对应原项目 src/sim/dungeon_layout.ts layoutColliders
-- 玩家进入副本时, 按 interior 类型注册实例内部碰撞体 (墙壁/立柱/棺材/台阶)

local colliders = require("world.colliders")
local M = {}

-- 实例内碰撞体 (进入副本时注册, 离开时清除)
local interiorColliders = {}

--- 注册副本内部碰撞体 (TS layoutColliders: 墙壁 OBB / 立柱圆 / 可站立棺材 / 台阶)
--- @param interior string "crypt"|"sanctum"|"nythraxis"|"temple"|"lastkeep"|"arena"
--- @param originX, originZ number 实例原点偏移
function M.registerInterior(interior, originX, originZ)
    M.clearInterior()
    local ok, proto = pcall(function() return require("proto.load") end)
    if not ok then return end
    local layout = proto.getDungeonLayout(interior)
    if not layout then return end

    local ox, oz = originX or 0, originZ or 0

    -- 侧墙 OBB (TS sideWallZ/sideWallHd, 全高)
    if layout.sideWallZ ~= nil then
        for _, sx in ipairs({ -23, 23 }) do  -- DUNGEON_WALL_X = 23
            table.insert(interiorColliders, colliders.addCollider({
                type = "obb", x = ox + sx, z = oz + (layout.sideWallZ or 47),
                hw = 1, hd = layout.sideWallHd or 66, rot = 0,
            }))
        end
    end

    -- 立柱 (TS PILLAR_COLLIDER_R = 1.0, 圆)
    for _, p in ipairs(layout.pillars or {}) do
        table.insert(interiorColliders, colliders.addCollider({
            type = "circle", x = ox + p.x, z = oz + p.z, r = 1.0,
        }))
    end

    -- 棺材/货物 (TS 可站立 OBB, tombDressing: coffins → 脊顶, cargo → 堆叠)
    for _, t in ipairs(layout.tombs or {}) do
        local top = 1.72  -- TOMB_COFFIN_PLAIN_TOP
        table.insert(interiorColliders, colliders.addCollider({
            type = "obb", x = ox + t.x, z = oz + t.z,
            hw = 1.1, hd = 2.1, rot = 0,
            standable = true, moveTopY = top,
        }))
    end

    -- 墙段 (waist stubs, 全高 OBB)
    for _, s in ipairs(layout.stubs or {}) do
        table.insert(interiorColliders, colliders.addCollider({
            type = "obb", x = ox + s.x, z = oz + s.z,
            hw = s.hw or 0.6, hd = s.hd or 5, rot = 0,
        }))
    end

    -- 台阶 (dais, 可站立圆)
    if layout.dais then
        table.insert(interiorColliders, colliders.addCollider({
            type = "circle", x = ox + layout.dais.x, z = oz + layout.dais.z,
            r = layout.dais.r or 9.5,
            standable = true, moveTopY = (layout.daisRaised and 0.6) or 0.3,
        }))
    end
end

--- 清除实例内碰撞体 (离开副本时)
function M.clearInterior()
    for _, c in ipairs(interiorColliders) do
        colliders.removeCollider(c)
    end
    interiorColliders = {}
end

return M
