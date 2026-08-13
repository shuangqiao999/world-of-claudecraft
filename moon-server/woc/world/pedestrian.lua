-- World of ClaudeCraft — Pedestrian NPCs (路人)
-- 城镇/野外的平民 NPC, 接入 mob AI 行为树 (漫游/追击/战斗/逃跑/返回)
-- 类似 GTA 的路人: 平时无害闲逛, 被打会反击, 低血量逃跑, 可击杀掉落

local M = {}

local simrng = require("world.simrng")
local mobAI = require("world.mob.ai")
local terrain = require("world.terrain")
local grid = require("world.grid")

-- 路人名字池
local NAMES = {
    "Elder", "Farmer", "Traveler", "Merchant", "Hunter", "Miner", "Herbalist",
    "Woodcutter", "Baker", "Fisher", "Shepherd", "Guard", "Peasant", "Villager",
    "Carpenter", "Blacksmith", "Weaver", "Cook", "Stablehand", "Innkeeper",
}

local function randomName()
    return NAMES[simrng.randint(1, #NAMES)]
end

--- 生成路人 NPC (城镇 + 野外), 接入 mob AI 行为树
function M.spawn(entities, grid, entityNewFn, allocIdFn)
    local count = 0
    local function makePedestrian(x, z)
        local eid = allocIdFn()
        local y = terrain.placementHeight(x, z)
        local e = entityNewFn(eid, "npc", "pedestrian", randomName(), 5, { x = x, y = y, z = z })
        e.pedestrian = true
        e.hostile = false
        e.moveSpeed = 5
        e.level = 5
        -- 接入 mob AI 行为树 (fallback profile: 50HP/5AP, 此处覆盖为 10AP)
        mobAI.initMob(e, "pedestrian", { x = x, y = y, z = z })
        -- 覆盖属性 (5级 50HP 攻击力10)
        e.maxHp = 50
        e.hp = 50
        e.attackPower = 10
        e.weapon = { min = 3, max = 6, speed = 2.6 }
        e.moveSpeed = 5
        -- humanoid 家族 → 低血量逃跑白名单
        e.family = "humanoid"
        entities[eid] = e
        if grid then grid.insert(e) end
        count = count + 1
    end

    -- 城镇路人 (出生点周边 ±20yd, 密集)
    -- 注: 移动端弱 GPU 下 24 个满细节骨骼动画角色会让城镇 FPS 掉到个位数,
    -- 降为 6 个 (与野外共 ~14 个) 在保留"路人"风味的同时保住移动端帧率
    for i = 1, 6 do
        local ang = simrng.randfloat(0, math.pi * 2)
        local dist = simrng.randfloat(0, 20)
        makePedestrian(math.cos(ang) * dist, math.sin(ang) * dist)
    end

    -- 野外路人 (散布 ±50yd, 稀疏)
    for i = 1, 8 do
        local x = simrng.randfloat(-50, 50)
        local z = simrng.randfloat(-50, 50)
        makePedestrian(x, z)
    end

    print(string.format("[Pedestrian] Spawned %d pedestrian NPCs (mob AI)", count))
    return count
end

--- 路人 AI 更新 (委托给 mob AI 行为树, 空间裁剪: 只更新玩家 200yd 内的路人)
function M.update(entities, players, dt, simTime)
    -- 玩家 cell 集合 (避免 O(npc×players) 距离检查)
    local playerCells = {}
    for pid, _ in pairs(players) do
        local pe = entities[pid]
        if pe and not pe.dead then
            playerCells[grid.cellKey(pe.pos.x, pe.pos.z)] = true
        end
    end
    if next(playerCells) == nil then return end

    for _, e in pairs(entities) do
        if e.kind == "npc" and e.pedestrian and not e.dead then
            local cx = math.floor(e.pos.x / 32)
            local cz = math.floor(e.pos.z / 32)
            local nearPlayer = false
            for dcx = -7, 7 do
                for dcz = -7, 7 do
                    if playerCells[(cx + dcx) * 100000 + (cz + dcz)] then nearPlayer = true; break end
                end
                if nearPlayer then break end
            end
            if nearPlayer then
                mobAI.updateMob(e, entities, players, dt)
            end
        end
    end
end

return M
