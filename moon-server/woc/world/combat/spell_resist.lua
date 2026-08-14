-- World of ClaudeCraft — Spell Resistance System
-- 法术可以完全抵抗(无伤害, 无效果), 基于等级差
-- Mob vs Player: 有底线保证, 不会因等级差距完全免疫
-- 对应原项目 src/sim/combat/spell_resist.ts

local simrng = require("world.simrng")
local M = {}

-- Spell hit by level diff: 96% at equal level, tops at 99%, floors at 5%
local function spellHitChance(casterLevel, targetLevel)
    local diff = targetLevel - casterLevel
    if diff <= 0 then
        -- 同级=96%, 每低1级+1%
        return math.min(0.99, 0.96 + math.abs(diff) * 0.01)
    end

    -- 高于你的目标: 用 ABOVE_LEVEL_MISS_PCT 表
    local ABOVE_LEVEL_MISS_PCT = { 2.5, 14, 21 }
    local idx = diff
    if idx > #ABOVE_LEVEL_MISS_PCT then idx = #ABOVE_LEVEL_MISS_PCT end
    local penalty = ABOVE_LEVEL_MISS_PCT[idx] / 100

    return 1.0 - math.min(0.5, penalty)  -- cap at 50% miss = 50% hit
end

-- 有效法术命中率 (caster gear +hit)
function M.effectiveSpellHit(casterLevel, targetLevel, hitBonus)
    hitBonus = hitBonus or 0
    return math.min(1, spellHitChance(casterLevel, targetLevel) + hitBonus)
end

-- Mob vs Player 最大抵抗率 (mirrors MOB_VS_PLAYER_MAX_MISS)
local MOB_VS_PLAYER_MAX_RESIST = 0.4  -- 40%

--- 检查法术是否被完全抵抗
function M.isSpellResisted(casterLevel, targetLevel, hitBonus)
    local hit = M.effectiveSpellHit(casterLevel, targetLevel, hitBonus)
    return not simrng.chance(hit)
end

--- 检查 Mob 法术是否被抵抗 (对 Player 有底线保护)
function M.isMobSpellResisted(caster, target, hitBonus)
    if not caster or not target then return false end

    local hit = M.effectiveSpellHit(caster.level or 1, target.level or 1, hitBonus or 0)

    -- Mob 攻击 Player 时有底线: 至少 60% 命中率
    local isMobToPlayer = caster.kind == "mob" and caster.hostile and not caster.ownerId and
        (target.kind == "player" or target.ownerId)

    local flooredHit = hit
    if isMobToPlayer then
        flooredHit = math.max(hit, 1 - MOB_VS_PLAYER_MAX_RESIST)
    end

    return not simrng.chance(flooredHit)
end

--- 检查是否发生部分抵抗 (每次法术伤害时调用, 3% 概率减半)
function M.rollPartialResist(casterLevel, targetLevel)
    if targetLevel <= casterLevel then return 1.0 end  -- 同级或更低 = 全伤
    local diff = targetLevel - casterLevel
    if diff <= 0 then return 1.0 end

    -- 每级 3% 概率部分抵抗
    if simrng.chance(diff * 0.03) then
        if simrng.chance(0.5) then return 0.75  -- 25% resist (75% damage)
        else return 0.5 end  -- 50% resist
    end

    return 1.0  -- 全伤
end

return M
