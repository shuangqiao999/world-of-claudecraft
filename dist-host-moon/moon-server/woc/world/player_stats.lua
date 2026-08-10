-- World of ClaudeCraft — Player Stats Recalculation
-- 角色属性重算: 职业基础 → 等级成长 → 装备总合 → 天赋 → 光环 → 形态变换
-- 对应原项目 src/sim/entity.ts recalcPlayerStats (400+ 行)
-- 这是计算角色战斗属性的唯一入口，不要在其他地方直接改属性

local M = {}

-- 战斗属性推导常量
local AGI_PER_DODGE = 0.0005        -- 每点敏捷 = 0.05% 闪避
local AGI_PER_ARMOR = 2              -- 每点敏捷 = 2 护甲
local SPELL_POWER_PER_INT = 1        -- 每点智力 = 1 法伤
local SHIELD_BLOCK_BASE = 0.05       -- 持盾基础格挡率

-- 耐力 → HP 公式: 前 20 点耐 1 点 = 10 HP, 后续 1 点 = 10 HP (简化)
local function hpFromStamina(sta)
    if sta <= 20 then return sta * 10 end
    return 20 * 10 + (sta - 20) * 10
end

-- 智力 → Mana 公式: 前 20 点智 1 点 = 15 Mana, 后续 1 点 = 15 Mana (简化)
local function manaFromIntellect(intellect)
    if intellect <= 20 then return intellect * 15 end
    return 20 * 15 + (intellect - 20) * 15
end

-- 各职业基础属性 (对应 CLASSES.ts)
local CLASS_DEFS = {
    warrior = {
        baseStats = { str = 23, agi = 20, sta = 22, int = 10, spi = 11, armor = 50 },
        statsPerLevel = { str = 2, agi = 1, sta = 2, int = 0, spi = 0, armor = 12 },
        baseHp = 50, hpPerLevel = 18,
        baseMana = 100, manaPerLevel = 0,
        resourceType = "rage",
    },
    mage = {
        baseStats = { str = 10, agi = 12, sta = 14, int = 24, spi = 22, armor = 25 },
        statsPerLevel = { str = 0, agi = 0, sta = 1, int = 3, spi = 2, armor = 4 },
        baseHp = 40, hpPerLevel = 12,
        baseMana = 100, manaPerLevel = 24,
        resourceType = "mana",
    },
    rogue = {
        baseStats = { str = 17, agi = 25, sta = 17, int = 11, spi = 12, armor = 40 },
        statsPerLevel = { str = 1, agi = 3, sta = 1, int = 0, spi = 0, armor = 8 },
        baseHp = 45, hpPerLevel = 15,
        baseMana = 100, manaPerLevel = 0,
        resourceType = "energy",
    },
    paladin = {
        baseStats = { str = 22, agi = 17, sta = 22, int = 13, spi = 14, armor = 45 },
        statsPerLevel = { str = 2, agi = 1, sta = 2, int = 1, spi = 1, armor = 12 },
        baseHp = 55, hpPerLevel = 17,
        baseMana = 80, manaPerLevel = 20,
        resourceType = "mana",
    },
    hunter = {
        baseStats = { str = 14, agi = 25, sta = 19, int = 13, spi = 14, armor = 45 },
        statsPerLevel = { str = 1, agi = 3, sta = 2, int = 1, spi = 1, armor = 8 },
        baseHp = 50, hpPerLevel = 15,
        baseMana = 80, manaPerLevel = 18,
        resourceType = "mana",
    },
    priest = {
        baseStats = { str = 10, agi = 11, sta = 13, int = 22, spi = 24, armor = 20 },
        statsPerLevel = { str = 0, agi = 0, sta = 1, int = 2, spi = 3, armor = 4 },
        baseHp = 38, hpPerLevel = 11,
        baseMana = 110, manaPerLevel = 26,
        resourceType = "mana",
    },
    shaman = {
        baseStats = { str = 18, agi = 16, sta = 20, int = 18, spi = 18, armor = 40 },
        statsPerLevel = { str = 1, agi = 1, sta = 2, int = 2, spi = 2, armor = 10 },
        baseHp = 48, hpPerLevel = 15,
        baseMana = 90, manaPerLevel = 22,
        resourceType = "mana",
    },
    warlock = {
        baseStats = { str = 11, agi = 12, sta = 15, int = 21, spi = 21, armor = 22 },
        statsPerLevel = { str = 0, agi = 0, sta = 1, int = 3, spi = 2, armor = 4 },
        baseHp = 42, hpPerLevel = 12,
        baseMana = 105, manaPerLevel = 25,
        resourceType = "mana",
    },
    druid = {
        baseStats = { str = 15, agi = 15, sta = 17, int = 19, spi = 20, armor = 30 },
        statsPerLevel = { str = 1, agi = 1, sta = 2, int = 2, spi = 2, armor = 6 },
        baseHp = 45, hpPerLevel = 13,
        baseMana = 95, manaPerLevel = 22,
        resourceType = "mana",
    },
}

--- 获取职业定义
function M.getClassDef(cls)
    return CLASS_DEFS[cls] or CLASS_DEFS["warrior"]
end

--- 重算玩家属性 (核心函数)
--- @param e Entity 玩家实体
--- @param cls string 职业
--- @param equipment table 装备表 { mainhand = "worn_sword", chest = "recruit_tunic", ... }
--- @param mods table|nil 天赋修正 { stats = {...}, global = {...} }
--- @param items table|nil ITEMS 数据表 (可选，用于读取物品属性)
function M.recalcPlayerStats(e, cls, equipment, mods, items)
    local def = M.getClassDef(cls)
    local lvl = e.level or 1

    -- 1. 计算基础属性 (职业基础 + 等级成长)
    local s = {
        str = def.baseStats.str + def.statsPerLevel.str * (lvl - 1),
        agi = def.baseStats.agi + def.statsPerLevel.agi * (lvl - 1),
        sta = def.baseStats.sta + def.statsPerLevel.sta * (lvl - 1),
        int = def.baseStats.int + def.statsPerLevel.int * (lvl - 1),
        spi = def.baseStats.spi + def.statsPerLevel.spi * (lvl - 1),
        armor = def.baseStats.armor + def.statsPerLevel.armor * (lvl - 1),
        pvpOffense = 0,
        pvpDefense = 0,
    }

    -- 2. 装备属性总合
    local bonusSp = 0
    local bonusCritRating = 0
    local bonusHasteRating = 0
    local bonusHitRating = 0
    local bonusAp = 0

    if equipment and items then
        for slot, itemId in pairs(equipment) do
            local item = items[itemId]
            if item then
                -- 等级要求检查
                if not item.requiredLevel or lvl >= item.requiredLevel then
                    bonusSp = bonusSp + (item.spellPower or 0)
                    bonusCritRating = bonusCritRating + (item.critRating or 0)
                    bonusHasteRating = bonusHasteRating + (item.hasteRating or 0)
                    bonusHitRating = bonusHitRating + (item.hitRating or 0)
                    if item.stats then
                        s.str = s.str + (item.stats.str or 0)
                        s.agi = s.agi + (item.stats.agi or 0)
                        s.sta = s.sta + (item.stats.sta or 0)
                        s.int = s.int + (item.stats.int or 0)
                        s.spi = s.spi + (item.stats.spi or 0)
                        s.armor = s.armor + (item.stats.armor or 0)
                    end
                    if item.weapon then
                        bonusAp = bonusAp + (item.attackPower or 0)
                    end
                end
            end
        end
    end

    -- 3. 天赋修正
    if mods and mods.stats then
        local m = mods.stats
        s.str = s.str + (m.str or 0)
        s.agi = s.agi + (m.agi or 0)
        s.sta = s.sta + (m.sta or 0)
        s.int = s.int + (m.int or 0)
        s.spi = s.spi + (m.spi or 0)
        s.armor = s.armor + (m.armor or 0)
        bonusAp = bonusAp + (m.ap or 0)

        -- 百分比加成
        if m.staPct then s.sta = math.floor(s.sta * (1 + m.staPct) + 0.5) end
        if m.strPct then s.str = math.floor(s.str * (1 + m.strPct) + 0.5) end
        if m.agiPct then s.agi = math.floor(s.agi * (1 + m.agiPct) + 0.5) end
        if m.intPct then s.int = math.floor(s.int * (1 + m.intPct) + 0.5) end
        if m.spiPct then s.spi = math.floor(s.spi * (1 + m.spiPct) + 0.5) end
        if m.armorPct then s.armor = math.floor(s.armor * (1 + m.armorPct) + 0.5) end
    end

    -- 4. 光环修正 (遍历 e.auras)
    local maxHpPctAura = 0
    local buffArmorPct = 0
    local buffApPct = 0
    local flatAuraArmor = 0
    local bearForm = false
    local catForm = false
    local moonkinForm = false
    local scaleMul = 1
    local auraBonusDodge = 0
    local auraBonusCrit = 0
    local allStatsPct = 0

    if e.auras then
        for _, a in pairs(e.auras) do
            if a.kind == "buff_ap" then
                bonusAp = bonusAp + (a.value or 0)
            elseif a.kind == "buff_ap_pct" then
                buffApPct = buffApPct + (a.value or 0) / 100
            elseif a.kind == "buff_armor" then
                flatAuraArmor = flatAuraArmor + (a.value or 0)
            elseif a.kind == "buff_armor_pct" then
                buffArmorPct = buffArmorPct + (a.value or 0) / 100
            elseif a.kind == "buff_str" then
                s.str = s.str + (a.value or 0)
            elseif a.kind == "buff_agi" then
                s.agi = s.agi + (a.value or 0)
            elseif a.kind == "buff_sta" then
                s.sta = s.sta + (a.value or 0)
            elseif a.kind == "buff_int" then
                s.int = s.int + (a.value or 0)
            elseif a.kind == "buff_spi" then
                s.spi = s.spi + (a.value or 0)
            elseif a.kind == "buff_allstats" then
                s.str = s.str + (a.value or 0)
                s.agi = s.agi + (a.value or 0)
                s.sta = s.sta + (a.value or 0)
                s.int = s.int + (a.value or 0)
                s.spi = s.spi + (a.value or 0)
            elseif a.kind == "buff_allstats_pct" then
                local m = 1 + (a.value or 0)
                s.str = math.floor(s.str * m + 0.5)
                s.agi = math.floor(s.agi * m + 0.5)
                s.sta = math.floor(s.sta * m + 0.5)
                s.int = math.floor(s.int * m + 0.5)
                s.spi = math.floor(s.spi * m + 0.5)
            elseif a.kind == "buff_stats_pct" then
                allStatsPct = allStatsPct + (a.value or 0) / 100
            elseif a.kind == "buff_sta_pct" then
                s.sta = math.floor(s.sta * (1 + (a.value or 0) / 100) + 0.5)
            elseif a.kind == "buff_int_pct" then
                s.int = math.floor(s.int * (1 + (a.value or 0) / 100) + 0.5)
            elseif a.kind == "buff_str_pct" then
                s.str = math.floor(s.str * (1 + (a.value or 0) / 100) + 0.5)
            elseif a.kind == "buff_agi_pct" then
                s.agi = math.floor(s.agi * (1 + (a.value or 0) / 100) + 0.5)
            elseif a.kind == "debuff_ap" then
                -- PvP AP 汲取
                bonusAp = bonusAp - (a.value or 0)
            elseif a.kind == "buff_spellpower" then
                bonusSp = bonusSp + (a.value or 0)
            elseif a.kind == "buff_crit" or a.kind == "buff_reckless" or a.kind == "bloodbath" then
                auraBonusCrit = auraBonusCrit + (a.value or 0)
            elseif a.kind == "buff_dodge" then
                auraBonusDodge = auraBonusDodge + (a.value or 0)
            elseif a.kind == "buff_maxhp_pct" then
                maxHpPctAura = maxHpPctAura + (a.value or 0)
            elseif a.kind == "buff_scale" then
                scaleMul = scaleMul * (a.value or 1)
            elseif a.kind == "form_bear" then
                bearForm = true
            elseif a.kind == "form_cat" then
                catForm = true
            elseif a.kind == "form_moonkin" then
                bonusSp = bonusSp + (a.value or 0)
                moonkinForm = true
            end
        end
    end

    -- 百分比统计光环 (在基础+装备+天赋+光环flat之后应用)
    if allStatsPct > 0 then
        s.str = math.floor(s.str * (1 + allStatsPct) + 0.5)
        s.agi = math.floor(s.agi * (1 + allStatsPct) + 0.5)
        s.sta = math.floor(s.sta * (1 + allStatsPct) + 0.5)
        s.int = math.floor(s.int * (1 + allStatsPct) + 0.5)
        s.spi = math.floor(s.spi * (1 + allStatsPct) + 0.5)
    end

    -- 5. 敏捷推导护甲 + 闪避
    s.agi = math.max(0, s.agi)
    s.armor = s.armor + s.agi * AGI_PER_ARMOR

    -- 形态变换修正
    if bearForm then
        s.armor = math.floor(s.armor * 2.3 + 0.5)
        bonusAp = bonusAp + 15 + math.floor(s.agi * 1.5 + 0.5)
    end
    if catForm then
        bonusAp = bonusAp + 8 + lvl * 2
        s.agi = s.agi + math.max(2, math.floor(lvl / 2))
    end
    if moonkinForm then
        s.armor = math.floor(s.armor * 1.5 + 0.5)
    end

    -- 光环护甲 (Devotion Aura 等)
    if flatAuraArmor > 0 then s.armor = s.armor + flatAuraArmor end
    if buffArmorPct > 0 then s.armor = math.floor(s.armor * (1 + buffArmorPct) + 0.5) end

    s.spi = math.max(0, s.spi)

    -- 6. 存储 stats
    e.stats = s

    -- 7. 武器解析
    local mainhandItem = equipment and equipment.mainhand and items and items[equipment.mainhand]
    local weapon
    if mainhandItem and mainhandItem.weapon then
        local ok = true
        if mainhandItem.requiredLevel and lvl < mainhandItem.requiredLevel then ok = false end
        if ok then
            weapon = mainhandItem.weapon
        end
    end
    if not weapon then
        weapon = { min = 1, max = 2, speed = 2 }
    end
    e.weapon = weapon

    -- 盾牌格挡
    local offhandItem = equipment and equipment.offhand and items and items[equipment.offhand]
    if offhandItem and offhandItem.kind == "shield" then
        e.blockChance = SHIELD_BLOCK_BASE
        e.blockValue = offhandItem.blockValue or 0
    else
        e.blockChance = 0
        e.blockValue = 0
    end

    -- 物品 ID (用于渲染)
    e.mainhandItemId = equipment and equipment.mainhand
    e.offhandItemId = equipment and equipment.offhand

    -- 8. 攻击强度 (按职业)
    local apFromStats
    if cls == "warrior" or cls == "paladin" or cls == "shaman" or cls == "druid" then
        apFromStats = s.str * 2
    elseif cls == "rogue" or cls == "hunter" then
        apFromStats = s.str + s.agi
    else
        apFromStats = s.str
    end
    apFromStats = math.max(0, apFromStats)
    e.attackPower = math.max(0, math.floor((apFromStats + bonusAp) * (1 + buffApPct) + 0.5))

    -- 猎人远程 AP
    if cls == "hunter" then
        e.rangedPower = math.max(0, math.floor((s.agi * 2 + bonusAp) * (1 + buffApPct) + 0.5))
    else
        e.rangedPower = 0
    end

    -- 9. 法术强度
    e.spellPower = math.max(0, math.floor(s.int * SPELL_POWER_PER_INT + bonusSp))

    -- 10. 暴击率 (5% 基础 + 0.05%/agi)
    e.critChance = 0.05 + s.agi * AGI_PER_DODGE + auraBonusCrit

    -- 11. 闪避率 (5% 基础 + 0.05%/agi + 光环)
    e.dodgeChance = math.max(0, 0.05 + s.agi * AGI_PER_DODGE + auraBonusDodge)

    -- 12. 生命值
    local hpFrac = 1
    if e.maxHp and e.maxHp > 0 then hpFrac = e.hp / e.maxHp end

    e.maxHp = def.baseHp + def.hpPerLevel * (lvl - 1) + hpFromStamina(s.sta)
    if bearForm then e.maxHp = math.floor(e.maxHp * 1.15 + 0.5) end
    if maxHpPctAura ~= 0 then e.maxHp = math.max(1, math.floor(e.maxHp * (1 + maxHpPctAura) + 0.5)) end
    if mods and mods.stats and mods.stats.maxHpPct then
        e.maxHp = math.floor(e.maxHp * (1 + mods.stats.maxHpPct) + 0.5)
    end
    if scaleMul > 1 then e.maxHp = math.floor(e.maxHp * scaleMul + 0.5) end

    e.hp = math.max(1, math.floor(e.maxHp * hpFrac + 0.5))
    if e.dead then e.hp = 0 end

    -- 13. 缩放
    if e.kind == "player" then e.scale = scaleMul end

    -- 14. 资源 (Mana/Rage/Energy)
    local formResource = nil
    if bearForm then formResource = "rage"
    elseif catForm then formResource = "energy" end

    if formResource then
        if e.resourceType == "mana" then e.savedMana = e.resource end
        if e.resourceType ~= formResource then
            e.resource = formResource == "energy" and 100 or 0
        end
        e.resourceType = formResource
        e.maxResource = 100
    elseif def.resourceType == "mana" then
        local cameFromForm = e.resourceType ~= "mana"
        local manaFrac = 1
        if e.maxResource and e.maxResource > 0 then manaFrac = e.resource / e.maxResource end

        e.resourceType = "mana"
        e.maxResource = math.floor(
            (def.baseMana + def.manaPerLevel * (lvl - 1) + manaFromIntellect(s.int)) *
            (1 + (mods and mods.global and mods.global.manaPct or 0))
        )
        if cameFromForm then
            e.resource = math.min(e.savedMana or 0, e.maxResource)
        else
            e.resource = math.floor(e.maxResource * manaFrac + 0.5)
        end
    else
        e.resourceType = def.resourceType
        e.maxResource = 100
        e.resource = math.min(e.resource or 0, 100)
    end

    -- 15. 其他评分 (TS: haste/crit/hit rating → 分数)
    e.critRating = bonusCritRating
    e.hasteRating = bonusHasteRating
    e.hitRating = bonusHitRating
    -- TS: hitFractionFromRating = rating/1000 (10 rating/%), hasteFractionFromRating = rating/2000
    e.hitBonus = e.hitRating * 0.001
    local hasteFrac = e.hasteRating / 2000
    e.spellHaste = hasteFrac
    e.meleeHaste = hasteFrac
    e.rangedHaste = hasteFrac

    -- 16. 施法者暴击 (TS spellCritFromInt: sharedCritBonus + crit rating/2000)
    local sharedCritBonus = 0
    for _, a in pairs(e.auras or {}) do
        if a.kind == "buff_spellcrit" or a.kind == "berserker_stance" then
            sharedCritBonus = sharedCritBonus + (a.value or 0)
        end
    end
    local critFromRating = e.critRating / 2000
    e.sharedCritBonus = sharedCritBonus
    e.critChance = 0.05 + s.agi * AGI_PER_DODGE + auraBonusCrit + critFromRating + sharedCritBonus

    -- 17. PvP power/resilience (TS pvpFractionsFromRatings: 评分开方/100 上限)
    local pvpOffenseRating = e.pvpOffenseRating or 0
    local pvpDefenseRating = e.pvpDefenseRating or 0
    local pvpOffense = math.min(0.3, math.sqrt(pvpOffenseRating) / 100)
    local pvpDefense = math.min(0.3, math.sqrt(pvpDefenseRating) / 100)
    s.pvpOffense = pvpOffense
    s.pvpDefense = pvpDefense
    e.stats.pvpOffense = pvpOffense
    e.stats.pvpDefense = pvpDefense

    -- 18. 双持/副手 (TS canDualWield + offhand weapon)
    e.dualWielding = false
    e.titansGrip = false
    e.offhandWeapon = nil
    if equipment and items then
        local mainItem = items[equipment.mainhand]
        local offItem = items[equipment.offhand]
        local mainWpn = mainItem and mainItem.weapon
        local offWpn = offItem and offItem.weapon
        if mainWpn and offWpn then
            e.dualWielding = true
            e.offhandWeapon = offWpn
            -- Titan's Grip: 双持双手武器 (rogue 不适用)
            if (mainWpn.twoHand or false) and (offWpn.twoHand or false) and cls ~= "rogue" then
                e.titansGrip = true
            end
        end
    end

    -- 19. 套装收集 (TS aggregateSetBonuses → setProcs)
    e.setCounts = {}
    if equipment then
        local itemLookup = items
        if not itemLookup then
            local ok, proto = pcall(function() return require("proto.load") end)
            if ok then itemLookup = proto.getItem end
        end
        for slot, itemId in pairs(equipment) do
            local item = type(itemLookup) == "function" and itemLookup(itemId) or (itemLookup and itemLookup[itemId])
            if item and item.setId then
                e.setCounts[item.setId] = (e.setCounts[item.setId] or 0) + 1
            end
        end
    end
    e.setProcs = {}
end

--- 创建满血满资源状态 (新角色加入)
function M.fullVitals(e, cls)
    local def = M.getClassDef(cls)
    e.hp = e.maxHp
    e.resource = e.maxResource
    e.gcdRemaining = 0
    e.cooldowns = {}
end

return M
