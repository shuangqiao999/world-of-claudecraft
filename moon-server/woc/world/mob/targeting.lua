-- World of ClaudeCraft — Mob Targeting
-- 对应原项目 src/sim/mob/targeting.ts + src/sim/threat.ts
-- 感知范围/威胁切换/isTrivialTo/威胁倍率

local config = require("config")
local m3d = require("world.math3d")
local M = {}

-- TS 常量
local TRIVIAL_LEVEL_GAP = 10
local MAX_AGGRO_RADIUS = 20
local MELEE_RANGE = 5
local MELEE_SWITCH_MULT = 1.1
local RANGED_SWITCH_MULT = 1.3
local DEFENSIVE_STANCE_THREAT_MULT = 1.3
local BEAR_FORM_THREAT_MULT = 1.3
local CAT_FORM_THREAT_MULT = 0.71
local RIGHTEOUS_FURY_THREAT_MULT = 1.6
local TAUNT_FORCE_SECONDS = 3

--- mob 感知范围 (TS mobCanSeeTarget: clamp(4, 20, aggroRadius + (mobLv - playerLv) * 1.5))
function M.getAggroRangeSq(mob, target)
    local base = math.max(4, math.min(MAX_AGGRO_RADIUS, (mob.aggroRadius or 0) + ((mob.level or 1) - (target.level or 1)) * 1.5))
    return base * base
end

--- 近战范围平方 (TS MELEE_RANGE = 3yd)
function M.getCombatRangeSq(mob)
    return MELEE_RANGE * MELEE_RANGE
end

--- 追击范围 (leash)
function M.getLeashRangeSq(mob)
    return config.LEASH_DISTANCE * config.LEASH_DISTANCE
end

--- isTrivialTo: 灰怪 (玩家等级 - mob 等级 >= 10, 非Boss/精英/稀有)
function M.isTrivialTo(mob, player)
    if mob.isBoss or mob.isElite or mob.isRare then return false end
    return (player.level or 1) - (mob.level or 1) >= TRIVIAL_LEVEL_GAP
end

--- 威胁倍率 (TS threatModifier: 防御姿态/熊×1.3, 猫×0.71, 正义之怒×1.6 holy)
function M.threatModifier(source, school)
    local mod = 1
    for _, a in pairs(source.auras or {}) do
        if a.kind == "defensive_stance" then mod = mod * DEFENSIVE_STANCE_THREAT_MULT
        elseif a.kind == "form_bear" then mod = mod * BEAR_FORM_THREAT_MULT
        elseif a.kind == "form_cat" then mod = mod * CAT_FORM_THREAT_MULT
        elseif a.kind == "righteous_fury" and school == "holy" then mod = mod * RIGHTEOUS_FURY_THREAT_MULT
        end
    end
    return mod
end

--- 选择战斗目标 (idle 索敌): 威胁最高的活跃玩家
function M.selectCombatTarget(mob, entities, threatMod)
    local best, bestT = nil, -1
    for _, e in pairs(entities) do
        if e.kind == "player" and not e.dead and not e.ghost then
            -- 灰怪不主动攻击
            if M.isTrivialTo(mob, e) then goto continue_target end
            -- 感知范围检查
            local dx = e.pos.x - mob.pos.x
            local dz = e.pos.z - mob.pos.z
            local distSq = dx * dx + dz * dz
            local aggroSq = M.getAggroRangeSq(mob, e)
            if distSq > aggroSq then goto continue_target end

            -- 威胁值 (有威胁则优先选威胁高的)
            local t = threatMod.getThreatValue(mob.id, e.id)
            if t > bestT then
                bestT = t
                best = e
            end
            ::continue_target::
        end
    end
    return best
end

--- 威胁切换 (TS updateMobTarget: 近战 110% / 远程 130% pull-over + 嘲讽强制)
function M.updateMobTarget(mob, entities, threatMod)
    -- 嘲讽强制目标
    if mob.forcedTargetId then
        mob.forcedTargetTimer = (mob.forcedTargetTimer or 0) - config.DT
        local forced = entities[mob.forcedTargetId]
        if forced and not forced.dead then
            mob.aggroTargetId = forced.id
            if mob.forcedTargetTimer <= 0 then mob.forcedTargetId = nil end
            return
        end
        if mob.forcedTargetTimer <= 0 then mob.forcedTargetId = nil end
    end

    local cur = mob.aggroTargetId and entities[mob.aggroTargetId]
    if not cur or cur.dead then
        -- retarget 到最高威胁
        local next = M._highestThreatTarget(mob, entities)
        if next then mob.aggroTargetId = next.id end
        return
    end

    local curThreat = threatMod.getThreatValue(mob.id, cur.id)
    local best, bestT = cur, curThreat
    for pid, t in pairs(threatMod.getThreats(mob.id)) do
        if pid == cur.id or t <= bestT then goto continue_scan end
        local e = entities[pid]
        if not e or e.dead then goto continue_scan end
        local dx = mob.pos.x - e.pos.x
        local dz = mob.pos.z - e.pos.z
        local dist = m3d.dist(dx, dz)
        local needed = curThreat * (dist <= MELEE_RANGE * 1.2 and MELEE_SWITCH_MULT or RANGED_SWITCH_MULT)
        if t > needed then
            best, bestT = e, t
        end
        ::continue_scan::
    end
    if best ~= cur then mob.aggroTargetId = best.id end
end

--- 最高威胁活跃目标 (TS highestThreatTarget)
function M._highestThreatTarget(mob, entities)
    local best, bestT = nil, -1
    for pid, t in pairs(threatMod.getThreats(mob.id)) do
        local e = entities[pid]
        if not e or e.dead then goto continue_threat end
        if t > bestT then best, bestT = e, t end
        ::continue_threat::
    end
    return best
end

--- 嘲讽: 设置强制目标 (TS taunt force 3s)
function M.applyTaunt(mob, targetId, threatMod, entities)
    mob.forcedTargetId = targetId
    mob.forcedTargetTimer = TAUNT_FORCE_SECONDS
    mob.aggroTargetId = targetId
    -- 嘲讽威胁设为仇恨表最高值
    local top = threatMod.topThreatValue(mob.id)
    threatMod.setThreat(mob.id, targetId, top + 1)
end

return M
