-- World of ClaudeCraft — NPC Spawner
-- 从 proto/npcs.json 生成 NPC 实体 (TS NpcDef: pos/facing/color/questIds/vendorItems)

local M = {}
local terrain = require("world.terrain")

local spawned = false

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
            local eid = allocIdFn()
            local e = entityNewFn(eid, "npc", id, def.name or id, 1, {
                x = def.pos.x or 0, y = terrain.groundHeight(def.pos.x or 0, def.pos.z or 0), z = def.pos.z or 0,
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
end

--- 重置 (测试)
function M.reset()
    spawned = false
end

return M
