-- World of ClaudeCraft — Talent System
-- applyTalents, respec: 生成 TalentModifiers 供 recalcPlayerStats 使用
-- 对应原项目 src/sim/progression/talents.ts computeTalentModifiers
-- 原则: 天赋在分配/重置时一次性计算成 flat mods，不每 tick 遍历天赋树

local M = {}

-- 9 职业天赋 (每职业一行, 简化 spec 系统)
local TALENTS = {
    warrior = {
        { id = "w1", name = "Improved Strike", rank = 0, maxRank = 3, cost = 1, stats = { ap = 5 } },
        { id = "w2", name = "Toughness", rank = 0, maxRank = 2, cost = 1, stats = { maxHpPct = 0.02 } },
        { id = "w3", name = "Deep Wounds", rank = 0, maxRank = 3, cost = 1, stats = { critDmg = 0.03 } },
    },
    mage = {
        { id = "m1", name = "Improved Fireball", rank = 0, maxRank = 3, cost = 1, stats = { sp = 5 } },
        { id = "m2", name = "Arcane Focus", rank = 0, maxRank = 2, cost = 1, stats = { crit = 0.02 } },
        { id = "m3", name = "Presence of Mind", rank = 0, maxRank = 2, cost = 1, stats = { haste = 0.03 } },
    },
    rogue = {
        { id = "r1", name = "Dagger Specialization", rank = 0, maxRank = 3, cost = 1, stats = { ap = 5 } },
        { id = "r2", name = "Lethality", rank = 0, maxRank = 2, cost = 1, stats = { critDmg = 0.05 } },
        { id = "r3", name = "Elusiveness", rank = 0, maxRank = 2, cost = 1, stats = { dodge = 0.02 } },
    },
    paladin = {
        { id = "p1", name = "Divine Strength", rank = 0, maxRank = 3, cost = 1, stats = { str = 3 } },
        { id = "p2", name = "Divine Intellect", rank = 0, maxRank = 2, cost = 1, stats = { int = 3 } },
        { id = "p3", name = "Holy Power", rank = 0, maxRank = 2, cost = 1, stats = { sp = 5 } },
    },
    hunter = {
        { id = "h1", name = "Improved Aspect", rank = 0, maxRank = 3, cost = 1, stats = { ap = 5 } },
        { id = "h2", name = "Killer Instinct", rank = 0, maxRank = 2, cost = 1, stats = { crit = 0.02 } },
        { id = "h3", name = "Survival", rank = 0, maxRank = 2, cost = 1, stats = { maxHpPct = 0.02 } },
    },
    priest = {
        { id = "pr1", name = "Improved Healing", rank = 0, maxRank = 3, cost = 1, stats = { sp = 5 } },
        { id = "pr2", name = "Mental Agility", rank = 0, maxRank = 2, cost = 1, stats = { manaPct = 0.03 } },
        { id = "pr3", name = "Spiritual Guidance", rank = 0, maxRank = 2, cost = 1, stats = { spi = 3 } },
    },
    shaman = {
        { id = "s1", name = "Concussion", rank = 0, maxRank = 3, cost = 1, stats = { sp = 5 } },
        { id = "s2", name = "Elemental Devastation", rank = 0, maxRank = 2, cost = 1, stats = { crit = 0.02 } },
        { id = "s3", name = "Ancestral Knowledge", rank = 0, maxRank = 2, cost = 1, stats = { int = 3 } },
    },
    warlock = {
        { id = "w1", name = "Improved Shadow Bolt", rank = 0, maxRank = 3, cost = 1, stats = { sp = 5 } },
        { id = "w2", name = "Cataclysm", rank = 0, maxRank = 2, cost = 1, stats = { crit = 0.02 } },
        { id = "w3", name = "Demonic Embrace", rank = 0, maxRank = 2, cost = 1, stats = { maxHpPct = 0.02 } },
    },
    druid = {
        { id = "d1", name = "Improved Wrath", rank = 0, maxRank = 3, cost = 1, stats = { sp = 5 } },
        { id = "d2", name = "Natural Weapons", rank = 0, maxRank = 2, cost = 1, stats = { ap = 5 } },
        { id = "d3", name = "Master Shapeshifter", rank = 0, maxRank = 2, cost = 1, stats = { allStatsPct = 0.02 } },
    },
    default = {
        { id = "d1", name = "Vitality", rank = 0, maxRank = 5, cost = 1, stats = { maxHpPct = 0.02 } },
    },
}

function M.initTalents(meta, cls)
    if not meta.talents then
        meta.talents = {}
        local tree = TALENTS[cls] or TALENTS["default"]
        for _, talent in ipairs(tree) do
            meta.talents[talent.id] = talent.rank or 0
        end
        meta.talentPoints = (meta.level or 1) - 1
        -- 构建初始 talentMods (空)
        meta.talentMods = { stats = {}, global = {} }
    end
end

--- 计算 TalentModifiers (在分配/重置后用)
local function computeTalentMods(meta, cls)
    local mods = { stats = {}, global = {} }
    local tree = TALENTS[cls] or TALENTS["default"]

    for _, talent in ipairs(tree) do
        local rank = meta.talents[talent.id] or 0
        if rank > 0 then
            if talent.stats then
                for stat, val in pairs(talent.stats) do
                    mods.stats[stat] = (mods.stats[stat] or 0) + val * rank
                end
            end
            if talent.global then
                for key, val in pairs(talent.global) do
                    mods.global[key] = (mods.global[key] or 0) + val * rank
                end
            end
        end
    end

    return mods
end

--- 分配天赋点
function M.applyTalents(meta, entity, talentId)
    local cls = entity.templateId or "warrior"
    M.initTalents(meta, cls)

    if (meta.talentPoints or 0) <= 0 then
        return false, "No talent points available"
    end

    local tree = TALENTS[cls] or TALENTS["default"]
    for _, talent in ipairs(tree) do
        if talent.id == talentId then
            local cur = meta.talents[talent.id] or 0
            if cur >= talent.maxRank then
                return false, "Max rank reached"
            end
            meta.talents[talent.id] = cur + 1
            meta.talentPoints = meta.talentPoints - 1

            -- 重新计算 talentMods (供 recalcPlayerStats 在下游使用)
            meta.talentMods = computeTalentMods(meta, cls)

            return true, talent
        end
    end
    return false, "Talent not found"
end

--- 重置天赋
function M.respec(meta, entity, cls)
    M.initTalents(meta, cls)
    for tid, _ in pairs(meta.talents or {}) do
        meta.talents[tid] = 0
    end
    meta.talentPoints = (meta.level or 1) - 1
    meta.talentMods = computeTalentMods(meta, cls)
    return true
end

function M.getTalentTree(cls)
    return TALENTS[cls] or TALENTS["default"]
end

--- 获取当前 talentModifiers
function M.getMods(meta, cls)
    if not meta.talentMods then
        M.initTalents(meta, cls)
    end
    return meta.talentMods
end

--- 选择天赋行 (row-level choice)
local TALENT_ROWS = { 5, 8, 11, 14, 20 }

function M.selectTalentRow(meta, entity, level, optionId)
    local cls = entity.templateId or "warrior"
    local validLevel = false
    for _, lv in ipairs(TALENT_ROWS) do
        if lv == level then validLevel = true; break end
    end
    if not validLevel then return false, "Invalid talent row level" end
    if entity.level < level then return false, "Level too low" end
    if not meta.talentRows then meta.talentRows = {} end
    if optionId then
        meta.talentRows[level] = optionId
    else
        meta.talentRows[level] = nil
    end
    return true, optionId
end

--- 升级时重算 talentMods (等级相关的天赋量级重新计算)
function M.recomputeForLevel(meta, entity, cls)
    M.initTalents(meta, cls)
    meta.talentMods = computeTalentMods(meta, cls)
    return meta.talentMods
end

return M
