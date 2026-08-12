-- World of ClaudeCraft — Duel System
-- duel_req, duel_accept, duel_decline

local M = {}

-- 决斗状态: { pid1, pid2, accepted2, started, hp1_snapshot, hp2_snapshot }
local activeDuels = {}

--- 发起决斗
function M.requestDuel(fromPid, targetPid, entities)
    local from = entities[fromPid]; local target = entities[targetPid]
    if not from or not target then return false, "Player not found" end
    if from.dead or target.dead then return false, "Cannot duel dead players" end

    local duelId = "duel_" .. fromPid .. "_" .. targetPid
    activeDuels[duelId] = {
        pid1 = fromPid, pid2 = targetPid, accepted2 = false, started = false,
        hp1_snap = from.hp, hp2_snap = target.hp,
    }
    return true, duelId
end

--- 接受决斗 (设置双方 duelPartnerId 以启用 1HP 钳制)
function M.acceptDuel(targetPid, duelId, entities)
    local d = activeDuels[duelId]
    if not d then return false end
    if d.pid2 ~= targetPid then return false end
    d.accepted2 = true
    d.started = true
    -- 设置决斗伙伴 (damage.lua 1HP 钳制依赖此字段)
    if entities then
        local e1 = entities[d.pid1]
        local e2 = entities[d.pid2]
        if e1 and e2 then
            e1.duelPartnerId = d.pid2
            e2.duelPartnerId = d.pid1
        end
    end
    return true, { pid1 = d.pid1, pid2 = d.pid2 }
end

--- 拒绝决斗
function M.declineDuel(duelId, entities)
    local d = activeDuels[duelId]
    activeDuels[duelId] = nil
    -- 清除可能已设置的决斗伙伴 (若曾接受)
    if d and entities then
        local e1 = entities[d.pid1]
        local e2 = entities[d.pid2]
        if e1 then e1.duelPartnerId = nil end
        if e2 then e2.duelPartnerId = nil end
    end
    return true
end

--- 检查决斗状态
function M.isDueling(pid)
    for _, d in pairs(activeDuels) do
        if d.started and (d.pid1 == pid or d.pid2 == pid) then
            return true
        end
    end
    return false
end

--- 结束决斗 (清除双方 duelPartnerId)
function M.endDuel(winner, loser, entities)
    for id, d in pairs(activeDuels) do
        if (d.pid1 == winner and d.pid2 == loser) or (d.pid1 == loser and d.pid2 == winner) then
            activeDuels[id] = nil
            if entities then
                local e1 = entities[d.pid1]
                local e2 = entities[d.pid2]
                if e1 then e1.duelPartnerId = nil end
                if e2 then e2.duelPartnerId = nil end
            end
            return true
        end
    end
    return false
end

--- 决斗中死亡 (HP 回1而不是真死)
function M.onDuelDeath(loser, entities)
    local e = entities[loser]
    if e then
        e.hp = 1
        e.dead = false
    end
end

return M
