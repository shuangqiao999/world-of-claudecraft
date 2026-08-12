-- World of ClaudeCraft — Spirit (Death) System
-- 对应原项目 src/sim/spirit.ts
-- 死亡、鬼魂、复活、灵魂医者、复活虚弱

local M = {}

-- 常量 (对齐 TS)
local CORPSE_REZ_RANGE = 35
local RES_HP_FRACTION = 0.5
local RES_HEALER_HP_FRACTION = 0.2
local SICKNESS_DURATION = 600  -- 10 分钟

--- 死亡后保留的光环种类 (TS aurasSurvivingDeath: undispellable)
local function auraSurvivesDeath(aura)
    if aura.undispellable then return true end
    if aura.kind == "encounter_lock" or aura.kind == "nythraxis_lock" then return true end
    return false
end

--- 复活状态清理 (TS reviveAt: 清除战斗/施法/采集/钓鱼/宠物状态)
local function clearDeathState(e, meta)
    e.dead = false
    e.ghost = false
    e.corpsePos = nil
    e.corpseInstanceId = nil
    -- 清除采集/制造/钓鱼隐藏状态 (TS cancelProfessionSessionOnDisplacement)
    e.gatherCastNodeId = ""
    e.gatherCastToolRarity = ""
    e.gatherCastEffectConfirmed = false
    e.craftCastRecipeId = ""
    e.craftCastCommission = false
    e.craftCastBatchRemaining = 0
    e.craftCastBatchTotal = 0
    e.enchantCastItemId = ""
    e.enchantCastEquipSlot = ""
    e.enchantCastEnchantId = ""
    e.toolRechargeCastProfessionId = ""
    e.fishBiteAtTick = 0
    e.fishReelDeadlineTick = 0
    e.fishCastZoneId = ""
    -- 战斗状态重置
    e.targetId = nil
    e.autoAttack = false
    e.queuedOnSwing = nil
    e.queuedCastAbility = nil
    e.queuedCastAim = nil
    e.combatTimer = 99
    e.inCombat = false
    -- 保留死亡穿越光环
    if e.auras then
        local surv = {}
        for _, a in pairs(e.auras) do
            if auraSurvivesDeath(a) then table.insert(surv, a) end
        end
        e.auras = surv
    end
    -- CC DR 清除
    if e.ccDr then e.ccDr = {} end
    -- 重算属性
    pcall(function()
        require("world.player_stats").recalcPlayerStats(
            e, e.templateId or "warrior",
            meta and meta.equipment or {},
            meta and meta.talentMods,
            nil)
    end)
end

--- 检查实体是否死亡
function M.checkDeath(e)
    if not e.dead and e.hp <= 0 then
        e.dead = true
        e.hp = 0
        return true
    end
    return false
end

--- 释放灵魂 (进入鬼魂状态, 传送至灵魂医者)
function M.releaseSpirit(e)
    if not e.dead then return end
    e.ghost = true
    e.corpsePos = { x = e.pos.x, y = e.pos.y, z = e.pos.z }
    e.pos.x = 0
    e.pos.z = 0
    e.pos.y = require("world.terrain").groundHeight(0, 0)
    M.resurrectSpiritHealer(e)
end

--- 施加复活虚弱 (TS applyResurrectionSickness: 全属性 -75%)
function M.applyResurrectionSickness(target)
    if not target.auras then target.auras = {} end
    target.auras["resurrection_sickness"] = {
        id = "resurrection_sickness",
        name = "Resurrection Sickness",
        duration = SICKNESS_DURATION,
        remaining = SICKNESS_DURATION,
        kind = "buff_allstats_pct",
        value = -0.75,
        isDebuff = true,
    }
end

--- 跑尸复活
function M.resurrectCorpse(e, corpsePos)
    if not e.dead or not e.ghost then return false end
    local dx = e.pos.x - (corpsePos.x or e.pos.x)
    local dz = e.pos.z - (corpsePos.z or e.pos.z)
    local distSq = dx * dx + dz * dz
    if distSq > CORPSE_REZ_RANGE * CORPSE_REZ_RANGE then return false end
    M.reviveAt(e, e.pos, RES_HP_FRACTION, false)
    return true
end

--- 治疗者复活
function M.resurrectHealer(target)
    if not target.dead then return end
    M.reviveAt(target, target.pos, RES_HEALER_HP_FRACTION, true)
end

--- 灵魂医者复活 (满血复活, 虚弱 debuff)
function M.resurrectSpiritHealer(target)
    if not target.dead then return end
    M.reviveAt(target, target.pos, 1.0, true)
end

--- 通用复活 (TS reviveAt): 位置 + HP 比例 + 可选虚弱
function M.reviveAt(e, pos, hpFrac, applySickness)
    local meta = e.meta  -- player meta (world 初始化时设置)
    -- 状态清理
    clearDeathState(e, meta)
    -- 位置
    if pos then
        e.pos.x = pos.x or e.pos.x
        e.pos.y = pos.y or e.pos.y
        e.pos.z = pos.z or e.pos.z
    end
    -- HP / 资源
    local hp = hpFrac or RES_HP_FRACTION
    e.hp = math.max(1, math.floor(e.maxHp * hp))
    if e.resourceType == "mana" then
        e.resource = math.floor(e.maxResource * hp)
    elseif e.resourceType == "energy" then
        e.resource = 100
    else
        e.resource = 0
    end
    -- 可选虚弱
    if applySickness then
        M.applyResurrectionSickness(e)
    end
    return true
end

return M
