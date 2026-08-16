-- World of ClaudeCraft — Mob Melee Swing
-- 对应原项目 src/sim/mob/mob_swing.ts + base hit-table shell
-- Mob 普攻使用完整命中表 (miss/dodge/crit/block), 与玩家一致
-- 输出标准 damage 事件 (世界广播), 与玩家普攻共享客户端事件契约

local simrng = require("world.simrng")
local damage = require("world.combat.damage")
local eventWire = require("world.combat.event_wire")
local M = {}

local SWING_INTERVAL = 2.0  -- 默认挥击间隔 (template attackSpeed 优先)

--- 更新 mob 普攻 (返回事件)
--- @param mob Entity
--- @param target Entity
--- @param dt number
function M.updateSwing(mob, target, dt)
    if not mob or not target or target.dead then return nil end

    mob.swingTimer = (mob.swingTimer or 0) + dt
    local speed = (mob.weapon and mob.weapon.speed) or SWING_INTERVAL
    if mob.swingTimer < speed then return nil end
    mob.swingTimer = mob.swingTimer - speed

    -- 距离检查
    local dx = target.pos.x - mob.pos.x
    local dz = target.pos.z - mob.pos.z
    local distSq = dx * dx + dz * dz
    if distSq > 9 then return nil end  -- 3yd melee

    -- 完整命中表 (复用玩家物理命中表)
    local result = damage.rollPhysicalHit(mob, target, { whiteDualWieldPenalty = false })

    if result.result == "miss" or result.result == "dodge" or result.result == "parry" then
        return eventWire.damage(mob.id, target.id, 0, false,
            eventWire.kindFromResult(result.result))
    end

    -- 基础伤害: 武器 min/max (TS meleeSwing: weaponDmg + AP×speed/14×0.5)
    local weapon = mob.weapon or { min = 2, max = 4, speed = 2 }
    local baseDmg = simrng.randint(weapon.min or 2, weapon.max or 4)
    local ap = mob.attackPower or 0
    baseDmg = baseDmg + (ap / 14) * (weapon.speed or 2) * 0.5

    -- 暴击
    if result.crit then
        baseDmg = baseDmg * 2.0
    end

    -- 完整伤害管道 (含护甲/DR/吸收/防姿)
    local final = damage.dealDamage(nil, mob, target, baseDmg, result.crit, "physical", "auto", {})
    if final <= 0 then
        return eventWire.damage(mob.id, target.id, 0, false, "block")
    end

    target.hp = math.max(0, target.hp - final)
    require("world.mob.threat").addThreat(mob.id, target.id, final)

    -- 受击怒气 (玩家)
    if target.resourceType == "rage" then
        local rageMod = require("world.combat.rage")
        target.resource = math.min(target.maxResource, target.resource + rageMod.rageFromTaking(final, mob.level or 1))
    end

    -- 荆棘反伤 (TS mob thorns: boar Bristled Hide)
    local tpl = nil
    local okp, proto = pcall(function() return require("proto.load") end)
    if okp then tpl = proto.getMob(mob.templateId) end
    if tpl and tpl.thorns then
        local thornsDmg = tpl.thorns.value or 2
        target.hp = math.max(0, target.hp - thornsDmg)
    end

    -- 生命汲取 (TS lifeleech: mob 造成伤害自愈)
    if tpl and tpl.lifeleech then
        local leechPct = tpl.lifeleech.pct or 0.1
        local healed = math.min(math.round(final * leechPct), mob.maxHp - mob.hp)
        if healed > 0 then mob.hp = mob.hp + healed end
    end

    -- 受击狂暴 (TS frenzyOnHit: 概率提速)
    if tpl and tpl.frenzyOnHit and simrng.random() < (tpl.frenzyOnHit.chance or 0) then
        mob.weapon = mob.weapon or { min = 2, max = 4, speed = 2 }
        mob.weapon.speed = mob.weapon.speed / (tpl.frenzyOnHit.hasteMult or 1.3)
        mob._frenzied = true
    end

    return eventWire.damage(mob.id, target.id, final, result.crit,
        eventWire.kindFromResult(result.result))
end

return M
