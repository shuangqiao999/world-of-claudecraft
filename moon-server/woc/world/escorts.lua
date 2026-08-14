-- World of ClaudeCraft — Escort System
-- 对应原项目 src/sim/escort.ts
-- 护送 NPC 行走 + 伏击波次

local simrng = require("world.simrng")
local m3d = require("world.math3d")
local M = {}

-- 活跃护送: { npcId, route = {x,z}[], progress, waitTimer, ambushes, currentWave }
local escorts = {}

--- 开始护送
function M.startEscort(npcId, route, opts)
    opts = opts or {}
    escorts[npcId] = {
        npcId = npcId,
        route = route or {},
        progress = 0,
        waitTimer = 0,
        ambushes = opts.ambushes or 2,
        currentWave = nil,
        ambushSpawns = opts.ambushSpawns or 3,
        finished = false,
    }
end

--- 每 tick 更新护送
function M.update(entities, players, createMobFn, gridModule, dt)
    local events = {}
    local toRemove = {}

    for npcId, escort in pairs(escorts) do
        local npc = entities[npcId]
        if not npc or npc.dead then
            toRemove[npcId] = true
            goto continue_escort
        end

        -- 沿路线行走
        local waypoint = escort.route[escort.progress + 1]
        if waypoint then
            local dx = waypoint.x - npc.pos.x
            local dz = waypoint.z - npc.pos.z
            local dist = m3d.dist(dx, dz)
            if dist < 1 then
                escort.progress = escort.progress + 1
            else
                local speed = 4
                npc.pos.x = npc.pos.x + (dx / dist) * speed * dt
                npc.pos.z = npc.pos.z + (dz / dist) * speed * dt
            end
        end

        -- 伏击波次
        if escort.progress >= math.floor(#escort.route * (escort.ambushes - escort.currentWave or 1) / escort.ambushes)
           and escort.ambushes > 0 then
            -- 简化: 在途中的标记点触发伏击
        end

        -- 完成
        if escort.progress >= #escort.route then
            table.insert(events, { type = "escort_complete", npcId = npcId })
            toRemove[npcId] = true
        end

        ::continue_escort::
    end

    for id, _ in pairs(toRemove) do escorts[id] = nil end
    return events
end

--- 触发伏击 (路径点)
function M.triggerAmbush(npcId, entities, players, createMobFn, gridModule)
    local escort = escorts[npcId]
    if not escort or escort.currentWave then return {} end
    local npc = entities[npcId]
    if not npc then return {} end

    escort.currentWave = true
    local events = {}
    for i = 1, escort.ambushSpawns do
        local ang = simrng.randfloat(0, math.pi * 2)
        local dist = simrng.randfloat(8, 12)
        local pos = {
            x = npc.pos.x + math.cos(ang) * dist,
            z = npc.pos.z + math.sin(ang) * dist,
        }
        local mob = createMobFn("forest_wolf", "Ambush Wolf", 1, pos)
        if mob then
            entities[mob.id] = mob
            gridModule.insert(mob)
            -- 攻击最近的玩家或NPC
            local nearest = nil
            for pid, meta in pairs(players) do
                local pe = entities[pid]
                if pe and not pe.dead then nearest = pe end
            end
            if nearest then
                mob.aggroTargetId = nearest.id
                mob.aiState = "chasing"
            end
            table.insert(events, { type = "escort_ambush", npcId = npcId, mobId = mob.id })
        end
    end
    escort.currentWave = false
    escort.ambushes = escort.ambushes - 1
    return events
end

return M
