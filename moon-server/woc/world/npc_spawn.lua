-- World of ClaudeCraft — NPC Spawner
-- 从 proto/npcs.json 生成 NPC 实体 (TS NpcDef: pos/facing/color/questIds/vendorItems)

local M = {}
local terrain = require("world.terrain")
local rideHeight = require("world.ride_height")

local spawned = false

--- findSafePos: 确保 NPC 站在合法地面上 (TS sim.ts:4689-4714)
--- @param x number
--- @param z number
--- @return number, number safe x, z
local function findSafePos(x, z)
    local seed = terrain.getWorldSeed()
    local gh = terrain.groundHeight(x, z)
    local wl = rideHeight.waterLevelAt(x, z, seed)
    -- 位置必须在水面以上至少 0.6 码 (干地)
    if gh > wl + 0.6 then return x, z end
    -- 螺旋搜索 (黄金角): 最多 80 次尝试
    local GOLDEN = 2.39996
    for i = 1, 80 do
        local r = 0.9 * math.sqrt(i) * 2.2
        local a = i * GOLDEN
        local px = x + math.sin(a) * r
        local pz = z + math.cos(a) * r
        local ngh = terrain.groundHeight(px, pz)
        local nwl = rideHeight.waterLevelAt(px, pz, seed)
        if ngh > nwl + 0.6 then return px, pz end
    end
    -- 全部失败: 退回原点 (0,0) 作为最后手段
    local g0 = terrain.groundHeight(0, 0)
    if g0 > rideHeight.waterLevelAt(0, 0, seed) + 0.6 then
        return 0, 0
    end
    return x, z  -- 无安全位置, 保持原坐标
end

--- 生成全部 NPC 实体 (world 启动时调用一次)
--- @param entities table
--- @param gridModule table
--- @param entityNewFn function (id, kind, templateId, name, level, pos) → Entity
--- @param allocIdFn function () → number
function M.spawnAll(entities, gridModule, entityNewFn, allocIdFn)
    if spawned then return end
    local ok, proto = pcall(function() return require("proto.load") end)
    if not ok then return end

    local npcs = proto.npcsById
    if not npcs then return end

    local count = 0
    for id, def in pairs(npcs) do
        if def.pos then
            local safeX, safeZ = findSafePos(def.pos.x or 0, def.pos.z or 0)
            local eid = allocIdFn()
            local e = entityNewFn(eid, "npc", id, def.name or id, 1, {
                x = safeX, y = terrain.placementHeight(safeX, safeZ), z = safeZ,
            })
            e.facing = def.facing or 0
            e.color = def.color or 0xffffff
            e.title = def.title
            e.greeting = def.greeting
            e.questIds = def.questIds or {}
            e.vendorItems = def.vendorItems or {}
            e.market = def.market or false
            e.banker = def.banker or false
            e.heroicVendor = def.heroicVendor or false
            e.warfareVendor = def.warfareVendor or false
            e.cardMaster = def.cardMaster or false
            e.hostile = false
            entities[eid] = e
            if gridModule then gridModule.insert(e) end
            count = count + 1
        end
    end
    spawned = true
    print(string.format("[Npc] Spawned %d NPCs", count))
    -- 诊断: 打印第一个 NPC 位置确认 Y 正确
    local first = next(npcs)
    if first then
        local d = npcs[first]
        local y = terrain.placementHeight(d.pos.x or 0, d.pos.z or 0)
        print(string.format("[Npc] First NPC '%s' at (%.1f,%.1f) Y=%.2f", d.name or first, d.pos.x or 0, d.pos.z or 0, y))
    end
end

--- 重置 (测试)
function M.reset()
    spawned = false
end

return M
