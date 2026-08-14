-- World of ClaudeCraft — XP / Level-Up System
-- 对应原项目 src/sim/combat/damage.ts grantXp + src/sim/progression/xp.ts
-- rested 加成 → lifetimeXp 累积 → 等级循环 → 属性重算

local M = {}

-- TS XP_TABLE (types.ts 6001-6004), MAX_LEVEL = 20
local XP_TABLE = {
    400, 900, 1400, 2100, 2800, 3600, 4500, 5400, 6500, 7600,
    8800, 10100, 11400, 12900, 14400, 16000, 17700, 19400, 21300, 23200,
}
local MAX_LEVEL = 20

--- 获取某等级所需 XP
function M.xpForLevel(level)
    local idx = math.min(level - 1, #XP_TABLE)
    return XP_TABLE[math.max(1, idx)]
end

-- TS mobXpValue: 灰怪零差距带 (types.ts:6362-6367)
function M.zeroDiff(playerLevel)
    if playerLevel <= 7 then return 5 end
    if playerLevel <= 9 then return 6 end
    if playerLevel <= 15 then return 7 end
    return 8
end

-- TS mobXpValue: base = 45 + 5*mobLevel, 等级差缩放 (types.ts:6370-6379)
function M.mobXpValue(mobLevel, playerLevel)
    local base = 45 + 5 * mobLevel
    local diff = mobLevel - playerLevel
    if diff >= 0 then
        return math.round(base * (1 + 0.05 * math.min(diff, 4)))
    end
    local zd = M.zeroDiff(playerLevel)
    if -diff >= zd then return 0 end  -- gray
    return math.round(base * (1 - (-diff) / zd))
end

--- 授予 XP (TS grantXp)
--- @param amount number
--- @param meta PlayerMeta
--- @param e Entity
--- @param opts table|nil { fromKill }
--- @param recalcFn function recalcPlayerStats 引用
--- @param talentRecalcFn function 重算 talentMods
--- @return table 事件列表
function M.grantXp(amount, meta, e, opts, recalcFn, talentRecalcFn)
    local events = {}
    if not e or amount <= 0 then return events end

    -- rested 加成: 仅击杀 XP, min(floor(restedXp), amount)
    local restedBonus = 0
    if opts and opts.fromKill and e.level < MAX_LEVEL and (meta.restedXp or 0) > 0 then
        restedBonus = math.min(math.floor(meta.restedXp), amount)
        meta.restedXp = (meta.restedXp or 0) - restedBonus
        amount = amount + restedBonus
    end

    -- lifetimeXp 始终累积 (含满级)
    meta.lifetimeXp = (meta.lifetimeXp or 0) + amount
    meta.xpGained = (meta.xpGained or 0) + amount

    table.insert(events, { type = "xp", amount = amount, pid = e.id, rested = restedBonus > 0 and restedBonus or nil })

    if e.level >= MAX_LEVEL then
        -- 满级: 清零经验条 (已在 lifetimeXp 累积)
        meta.xp = 0
        return events
    end

    meta.xp = (meta.xp or 0) + amount
    while e.level < MAX_LEVEL and meta.xp >= M.xpForLevel(e.level) do
        meta.xp = meta.xp - M.xpForLevel(e.level)
        e.level = e.level + 1
        meta.levelUps = (meta.levelUps or 0) + 1
        meta.level = e.level

        -- 重算 talentMods + 玩家属性
        if talentRecalcFn then pcall(talentRecalcFn, meta, e) end
        if recalcFn then pcall(recalcFn, e, meta.class or e.templateId, meta.equipment or {}, meta.talentMods, nil) end

        e.hp = e.maxHp
        if e.resourceType == "mana" then e.resource = e.maxResource end

        table.insert(events, { type = "levelup", level = e.level, pid = e.id })
    end

    if e.level >= MAX_LEVEL then meta.xp = 0 end
    return events
end

return M
