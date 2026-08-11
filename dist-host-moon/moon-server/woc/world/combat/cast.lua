-- World of ClaudeCraft — Casting System
-- 对应原项目 src/sim/combat/casting_lifecycle.ts
-- GCD (下限 0.75s), 施法时间, 资源消耗(先检查), 引导, 队列施法, pushback, CC中断

local config = require("config")
local M = {}

local BASE_GCD = config.GCD  -- 1.5s
local MIN_GCD = 0.75
local CAST_QUEUE_WINDOW_SEC = 0.4
local CAST_PUSHBACK_SEC = 0.5
local CHANNEL_PUSHBACK_FRACTION = 0.25
local CAST_COMPLETE_EPS = 0.001

--- 检查是否有控制类 CC (stun/root/silence/lockout)
local function ccModule()
    return require("world.combat.cc_dr")
end

--- 检查实体是否被沉默 (非物理施法中断)
local function isSilenced(e)
    for _, aura in pairs(e.auras or {}) do
        if aura.mechanic == "silence" then return true end
    end
    return false
end

local function isStunned(e)
    for _, aura in pairs(e.auras or {}) do
        local m = aura.mechanic
        if m == "stun" or m == "disorient" then return true end
    end
    return false
end

local function isRooted(e)
    for _, aura in pairs(e.auras or {}) do
        if aura.mechanic == "root" then return true end
    end
    return false
end

--- 检查实体是否有锁校 (school lockout)
local function isLockedOut(e, school)
    for _, aura in pairs(e.auras or {}) do
        if aura.mechanic == "lockout" and (aura.school == school or not aura.school) then
            return true
        end
    end
    return false
end

--- 检查施法是否可以开始 (castAbility gate set)
--- @return boolean, string|nil
function M.canCast(caster, ability)
    if caster.dead then return false, "dead" end
    if ability.usableWhileControlled then return true, nil end
    if isStunned(caster) then return false, "stunned" end
    -- 缴械: 物理伤害能力禁用 (TS cc)
    if ability.school == "physical" and ability.damage and ability.damage > 0 then
        local aura = require("world.combat.aura")
        if aura.isDisarmed(caster) then return false, "disarmed" end
    end
    if ability.school and ability.school ~= "physical" then
        if isSilenced(caster) then return false, "silenced" end
        if isLockedOut(caster, ability.school) then return false, "silenced" end
        -- blind / tongues (TS cc)
        local aura = require("world.combat.aura")
        local block = aura.isCastingBlocked(caster, ability.school)
        if block then return false, block end
    end
    return true, nil
end

--- 开始施法 (castAbility 对应)
--- @param caster Entity
--- @param ability table
--- @param target Entity|nil
--- @return boolean, number|string castTime 或错误消息
function M.startCast(caster, ability, target)
    local ok, reason = M.canCast(caster, ability)
    if not ok then return false, reason end

    -- 已经在施法: 尾段排队
    if caster.castingAbility then
        local castRemaining = caster.castRemaining or 0
        if castRemaining <= CAST_QUEUE_WINDOW_SEC then
            caster.queuedCastAbility = ability
            caster.queuedCastAim = nil
            return false, "queued"
        end
        return false, "busy"
    end

    -- GCD gate (offGcd 技能不受影响)
    local isOffGcd = ability.offGcd or false
    if not isOffGcd and caster.gcdRemaining and caster.gcdRemaining > 0 then
        return false, "gcd"
    end

    -- Empower Next 消耗 (TS hasFreeCostFor: 免费施法)
    local isFreeCast = false
    local empower = require("world.combat.empower")
    if empower.hasEmpowerNext(caster) then
        empower.consumeEmpowerNext(caster, ability.id)
        isFreeCast = true
    end

    -- 资源检查 (先检查再扣, TS 786-796; 免费施法跳过)
    local cost = ability.resourceCost or 0
    if cost > 0 and not isFreeCast then
        if caster.resource < cost then
            return false, "not_enough_resource"
        end
    end

    -- GCD 计算 (受 spellHaste 影响, 下限 0.75; TS: gcdRemaining = max(existing, gcd))
    local gcd = 0
    if not isOffGcd then
        local hasteFactor = 1.0 / (1.0 + (caster.spellHaste or 0))
        gcd = math.max(MIN_GCD, BASE_GCD * hasteFactor)
    end

    -- 消耗资源 (TS spendResource: 钳制 0, mana 才重置五秒规则; 免费施法跳过)
    if cost > 0 and not isFreeCast then
        caster.resource = math.max(0, caster.resource - cost)
        if caster.resourceType == "mana" then
            caster.fiveSecondRule = 0
        end
    end

    -- 冷却
    M.startCooldown(caster, ability)

    local hasteFactor = 1.0 / (1.0 + (caster.spellHaste or 0))
    local castTime = (ability.castTime or 0) * hasteFactor

    if castTime <= 0 then
        -- 瞬发技能
        if gcd > 0 then
            caster.gcdRemaining = math.max(caster.gcdRemaining or 0, gcd)
        end
        caster.targetId = target and target.id or nil
        return true, 0
    end

    -- 通道技能 (TS: channelTickEvery/channelTicksLeft 固定次数模型)
    if ability.isChannel then
        local channelDuration = castTime
        caster.castingAbility = ability
        caster.castTotal = channelDuration
        caster.castRemaining = channelDuration
        caster.channeling = true
        local channelTicks = ability.channelTicks or (ability.channelTicksLeft or 5)
        caster.channelTickEvery = channelDuration / channelTicks
        caster.channelTickTimer = caster.channelTickEvery
        caster.channelTicksLeft = channelTicks
        if gcd > 0 then
            caster.gcdRemaining = math.max(caster.gcdRemaining or 0, gcd)
        end
        caster.targetId = target and target.id or nil
        return true, channelDuration
    end

    -- 普通施法
    caster.castingAbility = ability
    caster.castTotal = castTime
    caster.castRemaining = castTime
    caster.targetId = target and target.id or nil
    if gcd > 0 then
        caster.gcdRemaining = math.max(caster.gcdRemaining or 0, gcd)
    end

    return true, castTime
end

--- 更新施法状态 (updateCasting 对应)
--- @param caster Entity
--- @param dt number
--- @return string|nil 施法结果
function M.updateCast(caster, dt)
    -- queued cast: GCD 清空后自动施放
    if not caster.castingAbility then
        if caster.queuedCastAbility then
            local queued = caster.queuedCastAbility
            if caster.gcdRemaining and caster.gcdRemaining <= 0 then
                caster.queuedCastAbility = nil
                caster.queuedCastAim = nil
                return queued  -- 返回排队的技能, 由调用方执行
            end
        end
        return nil
    end

    local ability = caster.castingAbility

    -- 眩晕中断
    if isStunned(caster) then
        M.cancelCast(caster)
        return "interrupted"
    end

    -- 沉默中断 (非物理施法)
    if ability.school and ability.school ~= "physical" then
        if isSilenced(caster) then
            M.cancelCast(caster)
            return "interrupted"
        end
        if isLockedOut(caster, ability.school) then
            M.cancelCast(caster)
            return "interrupted"
        end
    end

    -- 引导技能 (TS: channelTickTimer/channelTicksLeft 固定次数 + 结束 flush)
    if ability.isChannel then
        caster.castRemaining = caster.castRemaining - dt

        -- 通道 tick
        caster.channelTickTimer = (caster.channelTickTimer or 0) - dt
        if caster.channelTickTimer <= 0 then
            caster.channelTickTimer = caster.channelTickTimer + (caster.channelTickEvery or 1)
            if (caster.channelTicksLeft or 0) > 0 then
                caster.channelTicksLeft = caster.channelTicksLeft - 1
            end
            return "channel_tick"
        end

        -- 结束 flush: 补足剩余固定次数 tick
        if caster.castRemaining <= CAST_COMPLETE_EPS then
            local flushed = 0
            while (caster.channelTicksLeft or 0) > 0 and flushed < 20 do
                caster.channelTicksLeft = caster.channelTicksLeft - 1
                flushed = flushed + 1
            end
            return M.finishCast(caster)
        end
        return "channeling"
    end

    -- 普通施法
    caster.castRemaining = caster.castRemaining - dt
    if caster.castRemaining <= CAST_COMPLETE_EPS then
        return M.finishCast(caster)
    end
    return "casting"
end

--- 完成施法
function M.finishCast(caster)
    local ability = caster.castingAbility
    caster.castingAbility = nil
    caster.castRemaining = 0
    caster.castTotal = 0
    caster.channeling = false
    return "complete"
end

--- 施法击退 (pushbackCast, TS: factor = 1 - castPushbackReduction)
function M.pushbackCast(caster)
    if not caster.castingAbility then return end
    -- castShield 检查 (简化: 有 cast_shield aura 免疫)
    for _, a in pairs(caster.auras or {}) do
        if a.kind == "cast_shield" then return end
    end

    local factor = 1 - (caster.castPushbackReduction or 0)
    if caster.channeling then
        caster.castRemaining = caster.castRemaining + caster.castTotal * CHANNEL_PUSHBACK_FRACTION * factor
    else
        caster.castRemaining = caster.castRemaining + CAST_PUSHBACK_SEC * factor
        caster.castTotal = caster.castTotal + CAST_PUSHBACK_SEC * factor
    end
end

--- 取消施法 (TS cancelCast: 不返还资源, 清空所有 hidden state)
function M.cancelCast(caster)
    caster.castingAbility = nil
    caster.castRemaining = 0
    caster.castTotal = 0
    caster.channeling = false
    caster.castTargetId = nil
    caster.castAim = nil
    caster.queuedCastAbility = nil
    caster.queuedCastAim = nil
    -- 清理 profession hidden state
    caster.gatherCastNodeId = ""
    caster.gatherCastToolRarity = ""
    caster.gatherCastEffectConfirmed = false
    caster.craftCastRecipeId = ""
    caster.craftCastCommission = false
    caster.craftCastBatchRemaining = 0
    caster.craftCastBatchTotal = 0
    caster.enchantCastItemId = ""
    caster.enchantCastEquipSlot = ""
    caster.enchantCastEnchantId = ""
    caster.toolRechargeCastProfessionId = ""
    caster.fishBiteAtTick = 0
    caster.fishReelDeadlineTick = 0
    caster.fishCastZoneId = ""
end

--- 开始冷却
function M.startCooldown(caster, ability)
    if not ability.cooldown or ability.cooldown <= 0 then return end
    if not caster.cooldowns then caster.cooldowns = {} end
    caster.cooldowns[ability.id or ability.name] = ability.cooldown
end

--- 更新冷却
function M.updateCooldowns(caster, dt)
    if not caster.cooldowns then return end
    for id, remaining in pairs(caster.cooldowns) do
        remaining = remaining - dt
        if remaining <= 0 then
            caster.cooldowns[id] = nil
        else
            caster.cooldowns[id] = remaining
        end
    end
end

--- 检查冷却
function M.isOnCooldown(caster, ability)
    if not caster.cooldowns then return false end
    local remaining = caster.cooldowns[ability.id or ability.name]
    return remaining and remaining > 0
end

--- 更新全局 GCD
function M.updateGCD(caster, dt)
    if caster.gcdRemaining and caster.gcdRemaining > 0 then
        caster.gcdRemaining = caster.gcdRemaining - dt
        if caster.gcdRemaining < 0 then caster.gcdRemaining = 0 end
    end
    if caster.potionCdRemaining and caster.potionCdRemaining > 0 then
        caster.potionCdRemaining = caster.potionCdRemaining - dt
        if caster.potionCdRemaining < 0 then caster.potionCdRemaining = 0 end
    end
end

return M
