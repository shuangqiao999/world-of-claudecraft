-- World of ClaudeCraft — Auto Attack System
-- Swing timer, melee damage, combo points (确定性 RNG)
-- 对应原项目 src/sim/combat/auto_attack.ts

local config = require("config")
local simrng = require("world.simrng")
local damage = require("world.combat.damage")

local M = {}

-- 连击点过期时间 (TS: combo points fade after ~6s out of combat)
local COMBO_EXPIRE_SEC = 6

--- 开始自动攻击
function M.startAutoAttack(attacker, target)
    attacker.autoAttack = true
    attacker.swingTimer = 0.01  -- 立即发起第一次攻击 (不直接 0 以免双重触发)
    attacker.targetId = target and target.id or nil
end

--- 停止自动攻击
function M.stopAutoAttack(attacker)
    attacker.autoAttack = false
    attacker.swingTimer = 0
    attacker.queuedOnSwing = nil
end

--- 更新自动攻击 (tick)
--- @param attacker Entity
--- @param entities table
--- @param dt number
--- @return table|nil {damage, crit, blocked, dodged, missed, result}
function M.update(attacker, entities, dt, simTime)
    if not attacker.autoAttack then return nil end
    if attacker.dead or attacker.ghost then return nil end

    -- 非引导施法中暂停 swing (引导法术可继续 swing)
    if attacker.castingAbility and not attacker.castingAbility.isChannel then return nil end

    attacker.swingTimer = (attacker.swingTimer or 0) + dt

    -- 武器速度 (受 meleeHaste 影响)
    local weaponSpeed = M._getWeaponSpeed(attacker)

    if attacker.swingTimer >= weaponSpeed then
        attacker.swingTimer = attacker.swingTimer - weaponSpeed

        local target = entities[attacker.targetId]
        if not target or target.dead then return nil end

        -- 距离检查 + 角度检查 (MELEE_ARC: 120 度)
        local dx = target.pos.x - attacker.pos.x
        local dz = target.pos.z - attacker.pos.z
        local distSq = dx * dx + dz * dz
        if distSq > config.MELEE_RANGE_SQ then return nil end

        -- 近战角度: MELEE_ARC = 2.2 弧度 half-arc (TS types.ts:25)
        local MELEE_ARC = 2.2
        local dist = math.sqrt(distSq)
        if dist > 0.01 then
            local angle = math.abs(math.atan(dx, -dz) - attacker.facing)
            if angle > MELEE_ARC / 2 then return nil end
        end

        -- Swing 队列
        if attacker.queuedOnSwing then
            attacker.queuedOnSwing = false
            -- 队列施法在上游 dispatchMessage 中处理
        end

        -- 造成伤害 (使用命中表)
        local result = damage.calcPhysical(attacker, target)
        if result.damage > 0 then
            target.hp = math.max(0, target.hp - result.damage)
            -- 传奇武器 on-hit procs (TS equip_procs)
            local equipProcEvents = require("world.combat.equip_procs").applyWeaponProcs(
                attacker, target, result.crit and "on_crit" or "on_hit", "auto", entities, simTime)
            if equipProcEvents and #equipProcEvents > 0 then
                result.procEvents = equipProcEvents
            end
            -- 连击点 (盗贼/德鲁伊，最多 5 点; TS: comboUntil 到期清空)
            if attacker.templateId == "rogue" or attacker.templateId == "druid" then
                attacker.comboPoints = math.min(5, (attacker.comboPoints or 0) + 1)
                attacker.comboUntil = simTime + COMBO_EXPIRE_SEC
            end
        end

        return result
    end

    return nil
end

--- 获取武器速度 (受 meleeHaste 影响)
function M._getWeaponSpeed(e)
    local baseSpeed = e.weapon and e.weapon.speed or 2.6
    local haste = e.meleeHaste or 0
    return baseSpeed / (1 + haste)
end

--- 获取武器伤害范围
function M._getWeaponDamage(e)
    local weapon = e.weapon or { min = 1, max = 2, speed = 2 }
    return weapon
end

return M
