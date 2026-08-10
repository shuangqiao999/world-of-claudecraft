-- World of ClaudeCraft — Rage Generation Formulas
-- 造成伤害获得怒气: (7.5 * damage) / rageConversion(level)
-- 受到伤害获得怒气: damage / (attackerLevel * 1.5)
-- 姿态修正: Battle Stance +10%, 鲁莽 +50%
-- 对应原项目 src/sim/types.ts rageFromDealing/rageFromTaking/rageGenAuraMult

local M = {}

-- 怒气转换公式: 0.0091 * level^2 + 3.23 * level + 4.27
local function rageConversion(level)
    return 0.0091 * level * level + 3.23 * level + 4.27
end

-- 姿态/光环常数
local STANCE_RAGE_GEN = 0.1       -- Battle Stance +10%
local RECKLESSNESS_RAGE_GEN = 0.5 -- Recklessness +50%

--- 造成伤害获得的怒气
function M.rageFromDealing(damage, level)
    if damage <= 0 then return 0 end
    local conv = rageConversion(math.max(1, level))
    return (7.5 * damage) / conv
end

--- 受到伤害获得的怒气
function M.rageFromTaking(damage, attackerLevel)
    if damage <= 0 then return 0 end
    return damage / (math.max(1, attackerLevel) * 1.5)
end

--- 计算怒气生成倍率 (遍历 aura)
function M.rageGenAuraMult(auraEntries)
    if not auraEntries then return 1 end
    local mult = 1
    for _, a in pairs(auraEntries) do
        if a.kind == "buff_rage_gen" then mult = mult + (a.value or 0)
        elseif a.kind == "buff_reckless" then mult = mult + RECKLESSNESS_RAGE_GEN
        elseif a.kind == "stance_battle" then mult = mult + STANCE_RAGE_GEN
        end
    end
    return mult
end

--- 获取战士姿态暴击伤害加成
function M.berserkerCritDamage(auraEntries)
    if not auraEntries then return 0 end
    for _, a in pairs(auraEntries) do
        if a.kind == "berserker_stance" then return 0.03 end
    end
    return 0
end

--- 获取战士姿态天赋暴击加成
function M.stanceMasteryBattleCritDmg(auraEntries)
    if not auraEntries then return 0 end
    for _, a in pairs(auraEntries) do
        if a.kind == "stance_battle" then
            -- Combat Mastery: Battle Stance +15% crit dmg
            -- (简化: 总是返回, 实际需要天赋前置)
            return 0.15
        end
    end
    return 0
end

-- Titan's Grip: 双持双手武器时, 所有物理伤害 -12%
local TITANS_GRIP_DMG_PENALTY = 0.12

function M.titansGripPenalty(dualWielding, titansGrip)
    if dualWielding and titansGrip then
        return TITANS_GRIP_DMG_PENALTY
    end
    return 0
end

return M
