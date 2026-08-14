-- World of ClaudeCraft — Healing System
-- 对应原项目 src/sim/combat/heal.ts (全文件)
-- applyHeal 完整管道: crit × hexOutput × healingTaken × healAbsorb × overheal

local simrng = require("world.simrng")
local config = require("config")  -- 加载 math.round polyfill
local M = {}

local HEAL_THREAT_FACTOR = 0.5

--- incoming-heal 倍率 (mortal_wound 叠加)
function M.healingTakenMult(target)
    local mult = 1
    for _, a in pairs(target.auras or {}) do
        if a.kind == "mortal_wound" then mult = mult * (1 - (a.value or 0)) end
    end
    return mult < 0 and 0 or mult
end

--- Weakening Hex: 来源的伤害和治疗 × (1 - value)
function M.hexOutputMult(source)
    if not source then return 1 end
    local mult = 1
    for _, a in pairs(source.auras or {}) do
        if a.kind == "hex" then mult = mult * (1 - (a.value or 0)) end
    end
    return mult < 0 and 0 or mult
end

--- 消耗 Heal-Absorb 护盾 (classic necrotic blight)
function M.consumeHealAbsorb(target, healed)
    if healed <= 0 then return healed end
    local remaining = healed
    local depleted = false
    for id, a in pairs(target.auras or {}) do
        if a.kind == "heal_absorb" and (a.value or 0) > 0 then
            local eaten = math.min(remaining, a.value)
            a.value = a.value - eaten
            remaining = remaining - eaten
            if a.value <= 0 then
                depleted = true
                target.auras[id] = nil
            end
            if remaining <= 0 then break end
        end
    end
    return remaining
end

--- critVulnBonus: 最大的 critvuln aura 值
function M.critVulnBonus(target)
    local bonus = 0
    for _, a in pairs(target.auras or {}) do
        if a.kind == "critvuln" and (a.value or 0) > bonus then
            bonus = a.value
        end
    end
    return bonus
end

--- 计算治疗 (TS applyHeal)
--- @param source Entity
--- @param target Entity
--- @param amount number 基础治疗
--- @param ability string
--- @param canCrit boolean 是否可暴击
--- @return table {heal, crit, absorbed, overheal}
function M.applyHeal(source, target, amount, ability, canCrit)
    local result = { heal = 0, crit = false, absorbed = 0, overheal = 0 }
    if not target or target.dead then return result end

    -- 暴击判定 (单一 rng draw)
    local crit = false
    if canCrit ~= false then
        crit = simrng.random() < (source.critChance or 0.05)
    end
    result.crit = crit

    -- 完整管道: amount × critMult × hexOutput × healingTaken
    local critMult = crit and (1.5 + (source.critDmgHealBonus or 0)) or 1
    local healed = math.round(
        amount * critMult * M.hexOutputMult(source) * M.healingTakenMult(target)
    )

    -- 消耗 heal-absorb 盾
    local beforeAbsorb = healed
    healed = M.consumeHealAbsorb(target, healed)
    result.absorbed = beforeAbsorb - healed

    -- 钳制到 maxHp (overheal)
    local beforeClamp = healed
    healed = math.min(healed, target.maxHp - target.hp)
    result.overheal = beforeClamp - healed

    target.hp = target.hp + healed
    result.heal = healed
    return result
end

--- 治疗仇恨 (TS healingThreat: 总仇恨 = healed × 0.5 × threatMod, 平分给战斗中的 mob)
--- 含宠物归属匹配 (threatEntryMatchesEntity)
function M.healingThreat(source, target, healed, entities, threatMod)
    if not source or source.kind ~= "player" or healed <= 0 then return end
    if not threatMod or not entities then return end

    local total = healed * HEAL_THREAT_FACTOR
    local aware = {}
    for mid, m in pairs(entities) do
        if m.kind == "mob" and not m.dead and m.hostile and m.inCombat then
            -- 目标自身或其宠物在 mob 全局仇恨表上 (TS threatEntryMatchesEntity)
            local mobThreat = threatMod.getThreats(mid)
            local matches = mobThreat[target.id]
            if not matches and target.kind == "player" then
                for tid, _ in pairs(mobThreat) do
                    local entry = entities[tid]
                    if entry and entry.ownerId == target.id then
                        matches = true
                        break
                    end
                end
            end
            if matches then table.insert(aware, mid) end
        end
    end
    if #aware == 0 then return end
    local per = total / #aware
    for _, mid in ipairs(aware) do
        threatMod.addThreat(mid, source.id, per)
    end
end

return M
