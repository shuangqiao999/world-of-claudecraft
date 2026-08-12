-- World of ClaudeCraft — Pedestrian NPCs (路人)
-- 城镇/野外的平民 NPC, 具备 AI: 漫游 + 被攻击后反击
-- 类似 GTA 的路人: 平时无害闲逛, 被打会还手, 可被击杀掉落

local M = {}

local simrng = require("world.simrng")
local m3d = require("world.math3d")
local config = require("config")

-- 路人 AI 数据: pedId -> { wanderDir, wanderTimer, attackTimer }
local aiData = {}

-- 路人名字池
local NAMES = {
    "Elder", "Farmer", "Traveler", "Merchant", "Hunter", "Miner", "Herbalist",
    "Woodcutter", "Baker", "Fisher", "Shepherd", "Guard", "Peasant", "Villager",
    "Carpenter", "Blacksmith", "Weaver", "Cook", "Stablehand", "Innkeeper",
}

local function randomName()
    return NAMES[simrng.randint(1, #NAMES)]
end

--- 生成路人 NPC (城镇 + 野外)
function M.spawn(entities, grid, entityNewFn, allocIdFn)
    local count = 0
    local function makePedestrian(x, z)
        local eid = allocIdFn()
        local e = entityNewFn(eid, "npc", "pedestrian", randomName(), 5, { x = x, y = 0, z = z })
        e.pedestrian = true
        e.hostile = false
        e.maxHp = 50
        e.hp = 50
        e.attackPower = 10
        e.moveSpeed = 5
        e.weapon = { min = 3, max = 6, speed = 2.6 }
        e.level = 5
        e.pedWanderDir = simrng.randfloat(0, math.pi * 2)
        e.pedWanderTimer = simrng.randfloat(2, 6)
        e.pedHomeX = x
        e.pedHomeZ = z
        entities[eid] = e
        if grid then grid.insert(e) end
        aiData[eid] = {}
        count = count + 1
    end

    -- 城镇路人 (出生点周边 ±20yd, 密集)
    for i = 1, 24 do
        local ang = simrng.randfloat(0, math.pi * 2)
        local dist = simrng.randfloat(0, 20)
        makePedestrian(math.cos(ang) * dist, math.sin(ang) * dist)
    end

    -- 野外路人 (散布 ±50yd, 稀疏)
    for i = 1, 30 do
        local x = simrng.randfloat(-50, 50)
        local z = simrng.randfloat(-50, 50)
        makePedestrian(x, z)
    end

    print(string.format("[Pedestrian] Spawned %d pedestrian NPCs", count))
    return count
end

--- 路人被攻击时的反击钩子 (dealDamage 调用)
function M.onDamaged(e, attacker)
    if not e or e.dead then return end
    if e.kind ~= "npc" or not e.pedestrian then return end
    if not attacker or attacker.dead then return end
    -- 被攻击 → 反击
    e.hostile = true
    e.targetId = attacker.id
    e.pedFleeTimer = nil
end

--- 路人 AI 更新 (漫游 + 反击)
function M.update(entities, players, dt, simTime)
    for pedId, _ in pairs(aiData) do
        local e = entities[pedId]
        if not e or e.dead then
            aiData[pedId] = nil
        else
            M._updatePedestrian(e, entities, dt)
        end
    end
end

--- 单个路人更新
function M._updatePedestrian(e, entities, dt)
    if e.hostile and e.targetId then
        local target = entities[e.targetId]
        if not target or target.dead or target.ghost then
            e.hostile = false
            e.targetId = nil
            return
        end
        -- 追击并攻击目标
        local dx = target.pos.x - e.pos.x
        local dz = target.pos.z - e.pos.z
        local dist = m3d.dist(dx, dz)
        local range = 3
        if dist > range then
            -- 追击
            local nx, nz = m3d.norm(dx, dz)
            e.pos.x = e.pos.x + nx * (e.moveSpeed or 5) * dt
            e.pos.z = e.pos.z + nz * (e.moveSpeed or 5) * dt
            e.facing = math.atan(dx, -dz)
        else
            -- 近战攻击
            e.attackTimer = (e.attackTimer or 0) - dt
            if e.attackTimer <= 0 then
                e.attackTimer = 1.5
                local dmg = simrng.randint(2, 6)
                target.hp = math.max(0, target.hp - dmg)
                if target.kind == "player" then
                    target.lastAttackerId = e.id
                end
            end
        end
    else
        -- 漫游 (在出生点周边游荡)
        e.pedWanderTimer = (e.pedWanderTimer or 3) - dt
        if e.pedWanderTimer <= 0 then
            e.pedWanderTimer = simrng.randfloat(2, 6)
            e.pedWanderDir = simrng.randfloat(0, math.pi * 2)
        end
        local speed = (e.moveSpeed or 5) * 0.4
        e.pos.x = e.pos.x + math.cos(e.pedWanderDir) * speed * dt
        e.pos.z = e.pos.z + math.sin(e.pedWanderDir) * speed * dt
        e.facing = e.pedWanderDir
        -- 游荡范围限制 (回出生点)
        local hdx = e.pos.x - (e.pedHomeX or e.pos.x)
        local hdz = e.pos.z - (e.pedHomeZ or e.pos.z)
        if m3d.dist(hdx, hdz) > 15 then
            e.pedWanderDir = math.atan(-hdx, hdz)
        end
    end
end

return M
