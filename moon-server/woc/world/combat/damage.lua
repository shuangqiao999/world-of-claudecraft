-- World of ClaudeCraft — Complete Damage System
-- 完整 TS 伤害管道: 状态修正 → 输出放大 → Titan's Grip → DR → 护盾吸收 → 暴击bonus
-- 对应原项目 src/sim/combat/damage.ts + src/sim/combat/auto_attack.ts meleeSwing

local config = require("config")
local simrng = require("world.simrng")
local M = {}

-- 命中表常量
local BASE_MISS_CHANCE = 0.05
local DUAL_WIELD_WHITE_MISS_PENALTY = 0.1
local BASE_GLANCE_CHANCE = 0.10
local DEFENSIVE_STANCE_CUT = 0.9
local TITANS_GRIP_DMG_PENALTY = 0.12
local STANCE_MASTERY_BATTLE_CRIT_DMG = 0.15
local STANCE_MASTERY_GUARDED_HP_PCT = 0.2
local STANCE_MASTERY_GUARDED_CUT = 0.15
local BERSERKER_CRIT_DAMAGE = 0.03
local CRIT_SUPPRESSION_PER_LEVEL = 0.002
local MIN_CRIT_CHANCE = 0.005

-- 暴击基准 (物理 200%, 法术 150%, 治疗 150%)
local BASE_PHYS_CRIT = 2.0
local BASE_SPELL_CRIT = 1.5
local BASE_HEAL_CRIT = 1.5

-- 武器伤害范围 → 单次伤害
local function rollWeaponDamage(weapon)
    if weapon and weapon.max and weapon.max > weapon.min then
        return simrng.randint(weapon.min, weapon.max)
    end
    return weapon and weapon.min or 1
end

-- 护甲减免 (TS armorReduction)
local function armorReductionFactor(armor, attackerLevel)
    attackerLevel = math.max(1, attackerLevel or 1)
    if armor <= 0 then return 1.0 end
    local denom = armor + 400 + 85 * attackerLevel
    if denom <= 0 then return 1.0 end
    return 1.0 - math.min(0.75, armor / denom)
end

-- swingMissChance: nonlinear aboveLevelMissPct table (TS classic-era rules)
local ABOVE_LEVEL_MISS_PCT = { 0.025, 0.14, 0.21 }

local function swingMissChance(attacker, defender)
    local diff = (defender.level or 1) - (attacker.level or 1)
    local base = 0.05
    if diff > 0 then
        local idx = math.min(diff, #ABOVE_LEVEL_MISS_PCT)
        base = 0.05 + ABOVE_LEVEL_MISS_PCT[idx]
    end
    local mobToPlayer = attacker.kind == "mob" and attacker.hostile and not attacker.ownerId
    local playerSide = defender.kind == "player" or defender.ownerId
    if mobToPlayer and playerSide then
        base = math.min(base, 0.2)
    end
    if attacker.hitBonus then
        base = math.max(0, base - attacker.hitBonus)
    end
    return base
end

-- 双持命中率
local function dualWieldMissChance(attacker, defender, isWhiteDualWield)
    local base = swingMissChance(attacker, defender)
    if isWhiteDualWield and attacker.dualWielding then
        base = base + DUAL_WIELD_WHITE_MISS_PENALTY
    end
    return base
end

-- 闪避率 (mob 对 player: 5% + 0.5% * levelDiff)
local function getDodgeChance(attacker, defender)
    if defender.kind == "player" then
        return defender.dodgeChance or 0.05
    end
    local levelDiff = math.max(0, (defender.level or 1) - (attacker.level or 1))
    return math.min(0.15, 0.05 + levelDiff * 0.005)
end

-- 招架率 (仅玩家)
local function getParryChance(defender, attacker)
    if defender.kind ~= "player" then return 0 end
    return 0.05  -- 简化: 5% 基础招架
end

-- 格挡率
local function getBlockChance(defender)
    return defender.blockChance or 0
end

-- 格挡值
local function getBlockValue(defender)
    return defender.blockValue or 0
end

-- === 完整物理命中表 (单次掷骰, meleeSwing 对应) ===
-- 掷骰顺序: miss → dodge → parry → block → glance → hit/crit
function M.rollPhysicalHit(attacker, defender, opts)
    opts = opts or {}
    local missChance = dualWieldMissChance(attacker, defender, opts.whiteDualWieldPenalty)
    local cannotBeDodged = opts.cannotBeDodged
    local dodgeChance = cannotBeDodged and 0 or getDodgeChance(attacker, defender)
    local parryChance = getParryChance(defender, attacker)
    local blockChance = getBlockChance(defender)

    local roll = simrng.random()
    local accumulated = missChance

    if roll < accumulated then
        return { result = "miss", damage = 0, crit = false, missed = true }
    end

    accumulated = accumulated + dodgeChance
    if roll < accumulated then
        if attacker.kind == "player" then
            attacker.overpowerUntil = -1  -- 简化为立即可用
        end
        return { result = "dodge", damage = 0, crit = false, dodged = true }
    end

    accumulated = accumulated + parryChance
    if roll < accumulated then
        return { result = "parry", damage = 0, crit = false }
    end

    accumulated = accumulated + blockChance
    if roll < accumulated then
        return { result = "block", damage = 0, crit = false, blocked = true }
    end

    -- 偏斜 (+2 级以上)
    local levelDiff = (defender.level or 1) - (attacker.level or 1)
    if levelDiff >= 2 then
        local glanceChance = math.min(0.3, (levelDiff - 1) * 0.1)
        accumulated = accumulated + glanceChance
        if roll < accumulated then
            return { result = "glance", damage = 0, crit = false, glanced = true }
        end
    end

    -- 暴击判定
    local critChance = M._getEffectiveCritChance(attacker, defender, opts.forceCrit, opts.critBonus)
    accumulated = accumulated + critChance
    if roll < accumulated then
        return { result = "crit", damage = 0, crit = true }
    end

    return { result = "hit", damage = 0, crit = false }
end

-- 有效暴击率 (含碾压抑制)
function M._getEffectiveCritChance(attacker, defender, forceCrit, critBonus)
    if forceCrit then return 1.0 end
    local base = attacker.critChance or 0.05
    if critBonus then base = base + critBonus end
    local levelDiff = math.max(0, (defender.level or 1) - (attacker.level or 1))
    local suppression = levelDiff * CRIT_SUPPRESSION_PER_LEVEL
    return math.max(MIN_CRIT_CHANCE, base - suppression)
end

-- === 完整伤害管道 dealDamage ===
function M.dealDamage(ctx, source, target, rawAmount, crit, school, abilityId, opts)
    opts = opts or {}
    if target.dead then return 0 end
    if target.kind == "mob" and target.aiState == "evade" and not target.ownerId then
        return 0
    end

    -- 0. Stasis / Ice Block / 免疫: 无敌目标免疫伤害 (TS:168)
    if target.auras then
        local immune = false
        for _, a in pairs(target.auras) do
            if a.kind == "stasis" or a.kind == "ice_block" or a.kind == "cc_immune" or a.kind == "immunity" then
                immune = true
                break
            end
        end
        if immune then return 0 end
    end

    local amount = math.max(0, rawAmount)
    if amount <= 0 then return 0 end

    -- 0b. Shield Wall: 最强的非叠加减伤 (TS:248)
    if not opts.alreadyFinal and source and source.id ~= target.id and amount > 0 then
        local swReduction = 0
        if target.auras then
            for _, a in pairs(target.auras) do
                if a.kind == "shield_wall" then
                    swReduction = math.max(swReduction, a.value or 0)
                end
            end
        end
        if swReduction > 0 then
            amount = math.floor(amount * math.max(0, 1 - swReduction) + 0.5)
        end
    end

    -- 1. Source-side: Defensive Stance 削减
    if not opts.alreadyFinal and source and source.id ~= target.id and source.kind == "player" then
        local inDefensive = false
        if source.auras then
            for _, a in pairs(source.auras) do
                if a.kind == "defensive_stance" then inDefensive = true; break end
            end
        end
        if inDefensive then amount = math.floor(amount * DEFENSIVE_STANCE_CUT + 0.5) end
    end

    -- 1b. Target Defensive Stance ×0.9 (TS:238)
    if not opts.alreadyFinal and source and source.id ~= target.id and target.auras then
        local tDefensive = false
        for _, a in pairs(target.auras) do
            if a.kind == "defensive_stance" then tDefensive = true; break end
        end
        if tDefensive then amount = math.floor(amount * DEFENSIVE_STANCE_CUT + 0.5) end
    end

    -- 2. Hex output mult
    if not opts.alreadyFinal and source and source.id ~= target.id then
        local hexMult = 1.0
        if source.auras then
            for _, a in pairs(source.auras) do
                if a.kind == "hex" then hexMult = 1 - (a.value or 0); break end
            end
        end
        if hexMult ~= 1 then amount = math.floor(amount * hexMult + 0.5) end
    end

    -- 3. buff_dmg_done stacking (含 bloodbath, avatar, enrage, sanguine)
    if not opts.alreadyFinal and source and source.id ~= target.id and amount > 0 then
        local dmgDone = 0
        if source.auras then
            for _, a in pairs(source.auras) do
                if a.kind == "buff_dmg_done" or a.kind == "bloodbath" or
                   a.kind == "buff_avatar" or a.kind == "enrage" then
                    dmgDone = dmgDone + (a.value or 0)
                elseif a.kind == "sanguine" then
                    dmgDone = dmgDone + (a.value2 or a.value or 0)
                end
            end
        end
        if dmgDone ~= 0 then
            amount = math.floor(amount * math.max(0, 1 + dmgDone) + 0.5)
        end
    end

    -- 4. Titan's Grip: 双持双手武器 -12% 物理伤害
    if not opts.alreadyFinal and source and source.id ~= target.id and
       amount > 0 and school == "physical" and source.titansGrip then
        amount = math.floor(amount * (1 - TITANS_GRIP_DMG_PENALTY) + 0.5)
    end

    -- 4b. Expose: 目标物理伤害放大 (TS:257)
    if school == "physical" and target.auras then
        local exposeAmp = 0
        for _, a in pairs(target.auras) do
            if a.kind == "expose" then exposeAmp = exposeAmp + (a.value or 0) end
        end
        if exposeAmp > 0 then
            amount = math.floor(amount * (1 + exposeAmp) + 0.5)
        end
    end

    -- 4c. Vulnerability (sunder & vulnerability 法术): 目标全伤害放大 (TS:278)
    if target.auras then
        local vulnAmp = 0
        for _, a in pairs(target.auras) do
            if a.kind == "vulnerability" then vulnAmp = vulnAmp + (a.value or 0) end
        end
        if vulnAmp > 0 then
            amount = math.floor(amount * (1 + vulnAmp) + 0.5)
        end
    end

    -- 4d. Spellvuln: 魔法学派放大 (TS:267)
    if school ~= "physical" and target.auras then
        local svAmp = 0
        for _, a in pairs(target.auras) do
            if a.kind == "spellvuln" then svAmp = svAmp + (a.value or 0) end
        end
        if svAmp > 0 then
            amount = math.floor(amount * (1 + svAmp) + 0.5)
        end
    end

    -- 4e. PvP power/resilience (WARFARE, 介于免伤与吸收之间) (TS:416)
    if source and target and source.kind == "player" and target.kind == "player" then
        local pvpMult = 1 + ((source.stats and source.stats.pvpOffense) or 0) - ((target.stats and target.stats.pvpDefense) or 0)
        if pvpMult ~= 1 then
            amount = math.floor(amount * math.max(0.5, pvpMult) + 0.5)
        end
    end

    -- 5a. Target DR (buff_dr)
    if source and source.id ~= target.id and amount > 0 and target.auras then
        local reduction = 0
        for _, a in pairs(target.auras) do
            if a.kind == "buff_dr" or a.kind == "die_by_sword" then
                reduction = reduction + (a.value or 0)
            end
        end
        if reduction > 0 then
            amount = math.floor(amount * math.max(0, 1 - reduction) + 0.5)
        end
    end

    -- 5b. Target physical DR
    if source and source.id ~= target.id and amount > 0 and school == "physical" and target.auras then
        local reduction = 0
        for _, a in pairs(target.auras) do
            if a.kind == "buff_dr_phys" then reduction = reduction + (a.value or 0) end
        end
        if reduction > 0 then
            amount = math.floor(amount * math.max(0, 1 - reduction) + 0.5)
        end
    end

    -- 6. Crit vulnerability bonus
    if crit and amount > 0 and source and source.id ~= target.id then
        local bonus = M._getCritVulnBonus(target)
        if bonus > 0 then amount = math.floor(amount * (1 + bonus) + 0.5) end
    end

    -- 7. Berserker Stance: crit +3% damage
    if not opts.alreadyFinal and crit and amount > 0 and source and source.id ~= target.id and source.auras then
        for _, a in pairs(source.auras) do
            if a.kind == "berserker_stance" then
                amount = math.floor(amount * (1 + BERSERKER_CRIT_DAMAGE) + 0.5)
                break
            end
        end
    end

    -- 8. Stance Mastery Battle: +15% crit dmg
    if not opts.alreadyFinal and crit and amount > 0 and source and source.id ~= target.id and source.auras then
        for _, a in pairs(source.auras) do
            if a.kind == "battle_stance" then
                amount = math.floor(amount * (1 + STANCE_MASTERY_BATTLE_CRIT_DMG) + 0.5)
                break
            end
        end
    end

    -- 9. Guarded Stance: >20% maxHp hit → -15%
    if source and source.id ~= target.id and amount >= target.maxHp * STANCE_MASTERY_GUARDED_HP_PCT and target.auras then
        for _, a in pairs(target.auras) do
            if a.kind == "defensive_stance" then
                amount = math.floor(amount * (1 - STANCE_MASTERY_GUARDED_CUT) + 0.5)
                break
            end
        end
    end

    -- 10. LIFO 吸收护盾 (按施加顺序, 最新先耗)
    local totalAbsorbed = 0
    if amount > 0 and target.auras then
        local shieldList = {}
        for id, a in pairs(target.auras) do
            if a.kind == "absorb" then table.insert(shieldList, { id = id, aura = a }) end
        end
        -- LIFO: 后施加的先消耗 (按 order 降序, 缺省 0 当作最旧)
        table.sort(shieldList, function(x, y)
            return (x.aura.order or 0) > (y.aura.order or 0)
        end)
        for _, entry in ipairs(shieldList) do
            if amount <= 0 then break end
            local a = entry.aura
            local soaked = math.min(a.value or 0, amount)
            a.value = (a.value or 0) - soaked
            amount = amount - soaked
            totalAbsorbed = totalAbsorbed + soaked
            if a.value <= 0 then
                target.auras[entry.id] = nil
            end
        end
    end

    amount = math.max(0, amount)

    -- 10b. 可击破控制 (breakable-aura: 伤害达到阈值击破 CC) (TS damage-break)
    if source and source.id ~= target.id and amount > 0 and target.auras then
        local toBreak = {}
        for id, a in pairs(target.auras) do
            if a.breaksOnDamage and (a.mechanic or a.kind) then
                local thresh = a.breakThreshold or 1000000
                if amount >= thresh then
                    table.insert(toBreak, id)
                end
            end
        end
        for _, id in ipairs(toBreak) do
            target.auras[id] = nil
        end
    end

    -- 10c. 荆棘反弹 (melee thorns / Lightning Shield 充能) (TS:1140-1160)
    if source and target and source.id ~= target.id and school == "physical" and amount > 0 and target.auras then
        local thornsDmg = 0
        for _, a in pairs(target.auras) do
            if a.kind == "thorns" then
                thornsDmg = thornsDmg + (a.value or 0)
            elseif a.kind == "thorns_charge" then
                thornsDmg = thornsDmg + (a.value or 0)
                a.stacks = (a.stacks or 1) - 1
                if a.stacks <= 0 then a.stacks = 1 end  -- 保持至少1层
            end
        end
        if thornsDmg > 0 and source and not source.dead then
            source.hp = math.max(0, source.hp - thornsDmg)
        end
    end

    -- 11. 宠物伤害分摊 (简化: 直接跳过)

    -- 12. 进入战斗状态 (TS: 每次命中双方 combatTimer = 0, inCombat = true)
    if source and target and source.id ~= target.id and amount > 0 then
        local regenMod = require("world.regen")
        regenMod.enterCombat(source, target)
    end

    -- 13. 受击怒气 (TS rageFromTaking: 战士受击获得怒气)
    if source and target and amount > 0 and target.resourceType == "rage" and target.id ~= (source and source.id) then
        local rageMod = require("world.combat.rage")
        local gain = rageMod.rageFromTaking(amount, source and source.level or 1)
        target.resource = math.min(target.maxResource, target.resource + gain)
    end

    -- 14. 决斗 1HP 钳制 (TS damage.ts:426): 决斗双方不会把对方打到 0
    if target.duelPartnerId and source and source.id == target.duelPartnerId and amount > 0 then
        amount = math.min(amount, math.max(0, (target.hp or 1) - 1))
    end

    -- 15. Vale Cup 球零伤害地板 (TS:426-711)
    if target.kind == "mob" and target.templateId and target.templateId:find("vale_cup") then
        amount = 0
    end

    return math.floor(amount + 0.5)
end

-- 计算物理伤害 (完整管道: 命中表 → 护甲 → dealDamage)
function M.calcPhysical(attacker, defender, opts)
    opts = opts or {}
    local weapon = opts.weapon or attacker.weapon or { min = 2, max = 4, speed = 2.6 }
    local weaponMult = opts.weaponMult or 1
    local weaponDmg = rollWeaponDamage(weapon) * weaponMult
    local ap = attacker.attackPower or 0
    local apSwingSpeed = opts.apSwingSpeed or weapon.speed
    local apDmg = (ap / 14) * apSwingSpeed
    local rawDmg = weaponDmg + apDmg

    -- 护甲
    local armor = defender.stats and defender.stats.armor or 50
    rawDmg = rawDmg * math.max(0.05, armorReductionFactor(armor, attacker.level or 1))

    local hitResult = M.rollPhysicalHit(attacker, defender, opts)
    if hitResult.result == "miss" or hitResult.result == "dodge" or hitResult.result == "parry" then
        hitResult.damage = 0
        return hitResult
    end

    if hitResult.result == "glance" then
        rawDmg = rawDmg * 0.7
    end

    if hitResult.crit then
        rawDmg = rawDmg * (BASE_PHYS_CRIT + (attacker.critDmgPhysBonus or 0))
    end

    if hitResult.result == "block" then
        rawDmg = math.max(1, rawDmg - getBlockValue(defender))
    end

    -- 伤痛管道
    rawDmg = M.dealDamage(nil, attacker, defender, rawDmg, hitResult.crit, "physical", nil, {
        whiteDualWieldPenalty = opts.whiteDualWieldPenalty,
    })

    hitResult.damage = math.max(1, math.floor(rawDmg + 0.5))
    return hitResult
end

-- 法术伤害 (含抵抗)
function M.calcSpell(attacker, defender, baseDamage, coeff)
    local sp = attacker.spellPower or 0
    coeff = coeff or 0.5
    local rawDmg = baseDamage + sp * coeff
    rawDmg = rawDmg * (0.95 + simrng.random() * 0.1)
    local result = { damage = rawDmg, crit = false }

    local critChance = M._getEffectiveCritChance(attacker, defender, false, 0)
    if simrng.random() < critChance then
        result.crit = true
        rawDmg = rawDmg * (BASE_SPELL_CRIT + (attacker.critDmgSpellBonus or 0))
    end

    rawDmg = M.dealDamage(nil, attacker, defender, rawDmg, result.crit, "magic", nil)
    result.damage = math.max(1, math.floor(rawDmg + 0.5))
    return result
end

-- 远程伤害
function M.calcRanged(attacker, defender, baseDamage)
    local ap = attacker.rangedPower or attacker.attackPower or 0
    local speed = attacker.weapon and attacker.weapon.speed or 3.0
    local rawDmg = baseDamage + (ap / 14) * speed * 0.5
    local result = { damage = rawDmg, crit = false }

    local critChance = M._getEffectiveCritChance(attacker, defender, false, 0)
    if simrng.random() < critChance then
        result.crit = true
        rawDmg = rawDmg * (BASE_PHYS_CRIT + (attacker.critDmgPhysBonus or 0))
    end

    result.damage = math.max(1, math.floor(rawDmg + 0.5))
    return result
end

-- 护甲百分比
function M.getArmorMitigation(armor, level)
    return armorReductionFactor(armor, level or 1)
end

-- 内部 helpers
function M._getCritVulnBonus(target)
    if not target.auras then return 0 end
    local bonus = 0
    for _, a in pairs(target.auras) do
        if a.kind == "critvuln" then bonus = bonus + (a.value or 0) end
    end
    return bonus
end

function M.getDualWieldMissPenalty()
    return DUAL_WIELD_WHITE_MISS_PENALTY
end

return M
