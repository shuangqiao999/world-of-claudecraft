-- World of ClaudeCraft — Threat Table
-- 仇恨值管理：每个 mob 维护一个仇恨表，决定攻击目标

local M = {}

-- 全局仇恨表: mobId → { attackerId = threatValue, ... }
local threats = {}

--- 获取或创建 mob 的仇恨表
function M.getThreats(mobId)
    if not threats[mobId] then
        threats[mobId] = {}
    end
    return threats[mobId]
end

--- 增加仇恨 (TS addThreat + threatModifier: 姿态/形态倍率)
--- @param mobId number mob 实体 ID
--- @param attackerId number 攻击者实体 ID
--- @param amount number 仇恨值
--- @param school string|nil 伤害学派 (Righteous Fury holy 才生效)
--- @param source Entity|nil 攻击者实体 (用于威胁倍率)
function M.addThreat(mobId, attackerId, amount, school, source)
    if amount <= 0 then return end
    local t = M.getThreats(mobId)
    local mod = 1
    if source then
        mod = require("world.mob.targeting").threatModifier(source, school or "physical")
    end
    t[attackerId] = (t[attackerId] or 0) + amount * mod
end

--- 获取单个目标的仇恨值
function M.getThreatValue(mobId, targetId)
    local t = threats[mobId]
    return t and t[targetId] or 0
end

--- 是否存在非空仇恨表 (供索敌快速短路)
function M.hasThreat(mobId)
    local t = threats[mobId]
    return t ~= nil and next(t) ~= nil
end

--- 设置仇恨值 (嘲讽用)
function M.setThreat(mobId, targetId, amount)
    local t = M.getThreats(mobId)
    t[targetId] = amount
end

--- 最高仇恨值 (TS topThreatValue)
function M.topThreatValue(mobId)
    local t = threats[mobId]
    if not t then return 0 end
    local top = 0
    for _, val in pairs(t) do
        if val > top then top = val end
    end
    return top
end

--- 治疗仇恨: 被治疗的玩家对附近所有战斗中的 mob 产生仇恨
--- 经典 Era: 治疗仇恨 = 治疗量 * 0.5，所有正在战斗的 mob 平分
--- @param healedPid number 被治疗的玩家 ID
--- @param healerPid number 治疗者 ID
--- @param healAmount number 治疗量
--- @param entities table 全局实体表
function M.addHealerThreat(healedPid, healerPid, healAmount, entities)
    if not entities then return end

    local healThreat = healAmount * 0.5  -- 50% 治疗转为仇恨

    -- 找到所有正在攻击 healedPid 的 mob (或 healedPid 正在战斗的 mob)
    local mobsInCombat = {}
    for mobId, _ in pairs(threats) do
        local mob = entities[mobId]
        if mob and not mob.dead and threats[mobId][healedPid] then
            table.insert(mobsInCombat, mobId)
        end
    end

    -- 平分仇恨给所有战斗中的 mob
    if #mobsInCombat > 0 then
        local perMob = healThreat / #mobsInCombat
        for _, mobId in ipairs(mobsInCombat) do
            M.addThreat(mobId, healerPid, perMob)
        end
    end
end

--- 获取最高仇恨目标
--- @param mobId number
--- @return number|nil 目标 ID
function M.getTopTarget(mobId)
    local t = threats[mobId]
    if not t then return nil end

    local best, bestVal = nil, -1
    for id, val in pairs(t) do
        if val > bestVal then
            best, bestVal = id, val
        end
    end
    return best
end

--- 获取仇恨列表 (排序后)
--- @param mobId number
--- @return table 按仇恨值降序排列的 {id, threat} 列表
function M.getSortedTargets(mobId)
    local t = threats[mobId]
    if not t then return {} end

    local list = {}
    for id, val in pairs(t) do
        table.insert(list, { id = id, threat = val })
    end
    table.sort(list, function(a, b) return a.threat > b.threat end)
    return list
end

--- 清除 mob 的仇恨
function M.clearThreat(mobId)
    threats[mobId] = nil
end

--- 清除特定目标对 mob 的仇恨
function M.removeThreat(mobId, targetId)
    if threats[mobId] then
        threats[mobId][targetId] = nil
    end
end

--- 重置所有仇恨 (服务器重启)
function M.resetAll()
    threats = {}
end

--- 治疗仇恨扩散
function M._spreadHealerThreat(mobId, healerId, amount)
    for oid, ot in pairs(threats) do
        if oid ~= mobId and ot[healerId] then
            ot[healerId] = (ot[healerId] or 0) + amount
        end
    end
end

--- 统计仇恨表 (内存诊断): 返回 mob 数, 总仇恨条目数
function M.stats()
    local mobs = 0
    local entries = 0
    for _, t in pairs(threats) do
        mobs = mobs + 1
        for _ in pairs(t) do entries = entries + 1 end
    end
    return mobs, entries
end

return M
