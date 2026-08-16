-- World of ClaudeCraft — Standard Combat Event Builders
-- 把 Moon 内部命中结果映射为客户端标准 SimEvent 形状 (世界广播, 不带 pid)。
-- 对应 src/sim/types.ts DamageEventKind: 'hit' | 'miss' | 'dodge' | 'parry' | 'block' | 'resist' | 'evade'
-- 只构造事件表, 不改动任何战斗逻辑。事件不带 pid, 由 noteEvents 按世界事件广播。

local M = {}

-- moon 命中结果字符串 (rollPhysicalHit / mob_swing) → 客户端 kind
local KIND_FROM_RESULT = {
    miss = "miss",
    dodge = "dodge",
    parry = "parry",
    block = "block",
    blocked = "block",
    glance = "hit",
    crit = "hit",
    hit = "hit",
}

--- 命中结果字符串 → 客户端 kind
function M.kindFromResult(r)
    return KIND_FROM_RESULT[r] or "hit"
end

--- 布尔命中标志 (missed/dodged/blocked) → 客户端 kind
function M.kindFromFlags(missed, dodged, blocked)
    if missed then return "miss" end
    if dodged then return "dodge" end
    if blocked then return "block" end
    return "hit"
end

--- 标准近战伤害事件 (普攻/怪物挥击共享)
function M.damage(sourceId, targetId, amount, crit, kind)
    return {
        type = "damage",
        sourceId = sourceId,
        targetId = targetId,
        amount = amount or 0,
        crit = crit or false,
        school = "physical",
        ability = nil,
        kind = kind or "hit",
    }
end

--- 标准法术/技能伤害事件
function M.spellDamage(sourceId, targetId, amount, crit, school, ability)
    return {
        type = "damage",
        sourceId = sourceId,
        targetId = targetId,
        amount = amount or 0,
        crit = crit or false,
        school = school or "magic",
        ability = ability,
        kind = "hit",
    }
end

--- 标准法术抵抗事件
function M.resist(sourceId, targetId, school, ability)
    return {
        type = "damage",
        sourceId = sourceId,
        targetId = targetId,
        amount = 0,
        crit = false,
        school = school or "magic",
        ability = ability,
        kind = "resist",
    }
end

--- 标准治疗事件
function M.heal2(sourceId, targetId, amount, crit, ability, opts)
    local ev = {
        type = "heal2",
        sourceId = sourceId,
        targetId = targetId,
        amount = amount or 0,
        crit = crit or false,
        ability = ability,
    }
    if opts then
        if opts.absorbed then ev.absorbed = opts.absorbed end
        if opts.overheal then ev.overheal = opts.overheal end
        if opts.hot then ev.hot = true end
        if opts.abilityId then ev.abilityId = opts.abilityId end
    end
    return ev
end

--- 标准死亡事件
function M.death(entityId, killerId)
    return { type = "death", entityId = entityId, killerId = killerId }
end

return M
