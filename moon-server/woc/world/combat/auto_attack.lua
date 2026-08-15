-- World of ClaudeCraft — Auto Attack System
-- Swing timer, melee damage, offhand, ranged auto (确定性 RNG)
-- 对应原项目 src/sim/combat/auto_attack.ts
-- 扩展: 副手双持 + 远程自动射击 (TS 273-286 offhand, TS 183-201 ranged)

local config = require("config")
local simrng = require("world.simrng")
local damage = require("world.combat.damage")
local m3d = require("world.math3d")

local M = {}

-- 跨分片 ghost 目标解析器 (由 init.lua 注入): 目标非本地实体时转发给归属分片
local ghostResolver = nil
function M.setGhostResolver(fn) ghostResolver = fn end
local ghostRangedResolver = nil
function M.setGhostRangedResolver(fn) ghostRangedResolver = fn end

local COMBO_EXPIRE_SEC = 6
local OFFHAND_DMG_MULT = 0.5
local RANGED_WEAPON_COEFF = 0.6
local RANGED_MAX_DIST = 35
local rollRangedDamage

--- 开始自动攻击
function M.startAutoAttack(attacker, target)
    attacker.autoAttack = true
    attacker.swingTimer = 0.01
    attacker.offhandSwingTimer = 0.01
    attacker.rangedSwingTimer = 0.01
    attacker.targetId = target and target.id or nil
end

--- 停止自动攻击
function M.stopAutoAttack(attacker)
    attacker.autoAttack = false
    attacker.swingTimer = 0
    attacker.offhandSwingTimer = 0
    attacker.rangedSwingTimer = 0
    attacker.queuedOnSwing = nil
end

--- 更新主手自动攻击
function M.update(attacker, entities, dt, simTime)
    if not attacker.autoAttack then return nil end
    if attacker.dead or attacker.ghost then return nil end
    if attacker.castingAbility and not attacker.castingAbility.isChannel then return nil end

    attacker.swingTimer = (attacker.swingTimer or 0) + dt
    local weaponSpeed = M._getWeaponSpeed(attacker)

    if attacker.swingTimer >= weaponSpeed then
        attacker.swingTimer = attacker.swingTimer - weaponSpeed
        return M._performSwing(attacker, entities, simTime, false)
    end

    return nil
end

--- 更新副手自动攻击
function M.updateOffhand(attacker, entities, dt, simTime)
    if not attacker.autoAttack then return nil end
    if not attacker.dualWielding then return nil end
    if attacker.dead or attacker.ghost then return nil end
    if attacker.castingAbility and not attacker.castingAbility.isChannel then return nil end

    attacker.offhandSwingTimer = (attacker.offhandSwingTimer or 0) + dt
    local offhandWpn = attacker.offhandWeapon or attacker.weapon
    local baseSpeed = offhandWpn and offhandWpn.speed or 2.6
    local haste = attacker.meleeHaste or 0
    local weaponSpeed = baseSpeed / (1 + haste)

    if attacker.offhandSwingTimer >= weaponSpeed then
        attacker.offhandSwingTimer = attacker.offhandSwingTimer - weaponSpeed
        return M._performSwing(attacker, entities, simTime, true)
    end

    return nil
end

--- 更新远程自动攻击
function M.updateRanged(attacker, entities, dt, simTime)
    if not attacker.autoAttack then return nil end
    if attacker.dead or attacker.ghost then return nil end
    if attacker.castingAbility and not attacker.castingAbility.isChannel then return nil end

    local rangedWpn = attacker.weapon
    if not rangedWpn or rangedWpn.kind ~= "ranged" then return nil end

    attacker.rangedSwingTimer = (attacker.rangedSwingTimer or 0) + dt
    local baseSpeed = rangedWpn.speed or 3.0
    local haste = attacker.rangedHaste or 0
    local weaponSpeed = baseSpeed / (1 + haste)

    if attacker.rangedSwingTimer >= weaponSpeed then
        attacker.rangedSwingTimer = attacker.rangedSwingTimer - weaponSpeed
        return M._performRangedSwing(attacker, entities, simTime)
    end

    return nil
end

--- 执行近战挥击 (共享主手/副手逻辑)
function M._performSwing(attacker, entities, simTime, isOffhand)
    local target = entities[attacker.targetId]
    if not target or target.dead then
        -- 跨分片 ghost 目标: 转发给归属分片结算 (伤害由归属分片回传)
        if ghostResolver then
            return ghostResolver(attacker, attacker.targetId, isOffhand)
        end
        return nil
    end

    local dx = target.pos.x - attacker.pos.x
    local dz = target.pos.z - attacker.pos.z
    local distSq = dx * dx + dz * dz
    if distSq > config.MELEE_RANGE_SQ then return nil end

    local MELEE_ARC = 2.2
    local dist = m3d.dist(dx, dz)
    if dist > 0.01 then
        -- 朝向差: angleTo(p,t)=atan2(dx,dz), 归一化到 [-π,π] 后与 facing 比较 (对齐 TS auto_attack.ts)
        local diff = math.atan(dx, dz) - attacker.facing
        while diff > math.pi do diff = diff - 2 * math.pi end
        while diff < -math.pi do diff = diff + 2 * math.pi end
        if math.abs(diff) > MELEE_ARC then return nil end
    end

    if not isOffhand and attacker.queuedOnSwing then
        attacker.queuedOnSwing = nil
    end

    local opts = { weaponMult = isOffhand and OFFHAND_DMG_MULT or 1, whiteDualWieldPenalty = isOffhand and true or nil }
    local result = damage.calcPhysical(attacker, target, opts)

    if result.damage > 0 then
        target.hp = math.max(0, target.hp - result.damage)
        local equipProcEvents = require("world.combat.equip_procs").applyWeaponProcs(
            attacker, target, result.crit and "on_crit" or "on_hit", "auto", entities, simTime)
        if equipProcEvents and #equipProcEvents > 0 then
            result.procEvents = equipProcEvents
        end
        if (attacker.templateId == "rogue" or attacker.templateId == "druid") and not isOffhand then
            attacker.comboPoints = math.min(5, (attacker.comboPoints or 0) + 1)
            attacker.comboUntil = simTime + COMBO_EXPIRE_SEC
        end
    end

    result.offhand = isOffhand
    return result
end

--- 执行远程射击
function M._performRangedSwing(attacker, entities, simTime)
    local target = entities[attacker.targetId]
    if not target or target.dead then
        -- 跨分片 ghost 目标: 转发给归属分片结算
        if ghostRangedResolver then
            return ghostRangedResolver(attacker, attacker.targetId)
        end
        return nil
    end

    local dx = target.pos.x - attacker.pos.x
    local dz = target.pos.z - attacker.pos.z
    local distSq = dx * dx + dz * dz
    if distSq > RANGED_MAX_DIST * RANGED_MAX_DIST then return nil end
    if distSq < config.MELEE_RANGE_SQ then return nil end  -- 死角

    return M.rangedSwingResult(attacker, target)
end

--- 远程射击伤害结算 (本地与跨片转发共用; 归属分片以攻击者快照为 attacker 调用)
function M.rangedSwingResult(attacker, target)
    local weapon = attacker.weapon or { min = 1, max = 2, speed = 3.0 }
    local baseDmg = rollRangedDamage(weapon)
    local ap = attacker.rangedPower or attacker.attackPower or 0
    local rawDmg = (baseDmg + (ap / 14) * weapon.speed) * RANGED_WEAPON_COEFF
    local armor = target.stats and target.stats.armor or 50
    rawDmg = rawDmg * math.max(0.05, damage.getArmorMitigation(armor, attacker.level or 1))

    local critChance = damage._getEffectiveCritChance(attacker, target, false, 0)
    local crit = simrng.random() < critChance
    if crit then
        rawDmg = rawDmg * (1.5 + (attacker.critDmgPhysBonus or 0))
    end

    rawDmg = damage.dealDamage(nil, attacker, target, rawDmg, crit, "physical", nil)
    local dmg = math.max(1, math.floor(rawDmg + 0.5))
    target.hp = math.max(0, target.hp - dmg)

    return { damage = dmg, crit = crit, ranged = true }
end

rollRangedDamage = function(weapon)
    local raw = weapon.max and weapon.max > weapon.min and simrng.randint(weapon.min, weapon.max) or (weapon.min or 1)
    return raw * ((weapon.speed or 3.0) / 2.0)
end

function M._getWeaponSpeed(e)
    local baseSpeed = e.weapon and e.weapon.speed or 2.6
    local haste = e.meleeHaste or 0
    return baseSpeed / (1 + haste)
end

function M._getWeaponDamage(e)
    local weapon = e.weapon or { min = 1, max = 2, speed = 2 }
    return weapon
end

return M
