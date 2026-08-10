-- World of ClaudeCraft — Dragonkin Brood
-- 对应原项目 src/sim/mob/dragonkin_brood.ts
-- 龙蛋靠近偷袭/孵化幼龙/扑击/巢穴护盾

local simrng = require("world.simrng")
local M = {}

local HATCH_TARGET_RANGE = 24
local HATCH_THREAT = 60
local WARD_AURA_ID = "brood_ward"
local WARD_ABSORB = 9999
local LEAP_MIN_SECONDS = 0.4

-- 孵化后的幼龙实体 (tracked by the world init via dragonkin egg mobs)
local broodingEggs = {}  -- { eggEntityId = { hatchMobId, hatchSeconds } }

--- 注册一个龙蛋 (由 spawn 或战斗生成)
function M.registerEgg(eggEntityId, hatchMobId, hatchSeconds)
    broodingEggs[eggEntityId] = {
        hatchMobId = hatchMobId or "dragonkin_whelp",
        hatchSeconds = hatchSeconds or 8,
    }
end

--- 清除龙蛋注册
function M.unregisterEgg(eggEntityId)
    broodingEggs[eggEntityId] = nil
end

--- 孵化幼龙 (TS hatch 逻辑)
function M._hatchEgg(eggEntity, entities, players, createMobFn, gridModule, def)
    local pos = { x = eggEntity.pos.x, y = eggEntity.pos.y, z = eggEntity.pos.z }
    -- 选择目标: 最近的玩家
    local victim, victimDistSq = nil, math.huge
    for pid, meta in pairs(players) do
        local pe = entities[pid]
        if pe and not pe.dead then
            local dx = pe.pos.x - pos.x
            local dz = pe.pos.z - pos.z
            local dsq = dx * dx + dz * dz
            if dsq <= HATCH_TARGET_RANGE * HATCH_TARGET_RANGE and dsq < victimDistSq then
                victim = pe
                victimDistSq = dsq
            end
        end
    end

    -- 创建幼龙
    local level = simrng.randint(1, 3)
    local whelp = createMobFn(def.hatchMobId or "dragonkin_whelp", "Dragonkin Whelp", level, pos)
    if not whelp then return {} end
    entities[whelp.id] = whelp
    gridModule.insert(whelp)

    local events = {{ type = "brood_hatch", eggId = eggEntity.id, mobId = whelp.id, x = pos.x, z = pos.z }}

    -- 幼龙扑击受害者 (TS whelpLeapToVictim)
    if victim then
        whelp.aggroTargetId = victim.id
        whelp.aiState = "chasing"
        whelp.inCombat = true
        whelp.leapT = 0
        whelp.leapFrom = { x = pos.x, z = pos.z }
        whelp.leapTo = { x = victim.pos.x, z = victim.pos.z }
        local dist = math.sqrt((victim.pos.x - pos.x)^2 + (victim.pos.z - pos.z)^2)
        whelp.leapDuration = math.max(LEAP_MIN_SECONDS, dist / 20)
        require("world.mob.threat").addThreat(whelp.id, victim.id, HATCH_THREAT)
        table.insert(events, { type = "brood_pounce", mobId = whelp.id, pid = victim.id })
    end

    -- 孵化护盾 (TS broodWardOnHatch): 幼龙获得巨大吸收盾
    whelp.auras = whelp.auras or {}
    whelp.auras[WARD_AURA_ID] = {
        id = WARD_AURA_ID, name = "Brood Ward", kind = "absorb",
        value = WARD_ABSORB, duration = 30, remaining = 30,
        sourceId = whelp.id, isDebuff = false,
    }

    return events
end

--- 每 tick 更新龙蛋
function M.update(entities, players, createMobFn, gridModule, dt)
    local events = {}
    local toRemove = {}

    for eggId, def in pairs(broodingEggs) do
        local egg = entities[eggId]
        if not egg then
            toRemove[eggId] = true
            goto continue_egg
        end
        if egg.dead then
            toRemove[eggId] = true
            goto continue_egg
        end

        -- 靠近偷袭: 有玩家进入 24 码内开始计时
        local playerNear = false
        for pid, meta in pairs(players) do
            local pe = entities[pid]
            if pe and not pe.dead then
                local dx = pe.pos.x - egg.pos.x
                local dz = pe.pos.z - egg.pos.z
                if dx * dx + dz * dz <= HATCH_TARGET_RANGE * HATCH_TARGET_RANGE then
                    playerNear = true
                    break
                end
            end
        end

        if playerNear then
            def.hatchSeconds = (def.hatchSeconds or 8) - dt
            if def.hatchSeconds <= 0 then
                local hatchEvents = M._hatchEgg(egg, entities, players, createMobFn, gridModule, def)
                for _, ev in ipairs(hatchEvents) do table.insert(events, ev) end
                toRemove[eggId] = true
            end
        else
            def.hatchSeconds = 8  -- 重置
        end
        ::continue_egg::
    end

    for eggId, _ in pairs(toRemove) do
        broodingEggs[eggId] = nil
    end

    return events
end

--- 清理 (mob 离开/重置)
function M.cleanup()
    broodingEggs = {}
end

return M
