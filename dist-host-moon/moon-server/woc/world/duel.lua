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

--- 接受决斗
function M.acceptDuel(targetPid, duelId)
    local d = activeDuels[duelId]
    if not d then return false end
    if d.pid2 ~= targetPid then return false end
    d.accepted2 = true
    d.started = true
    -- 决斗开始标志
    return true, { pid1 = d.pid1, pid2 = d.pid2 }
end

--- 拒绝决斗
function M.declineDuel(duelId)
    activeDuels[duelId] = nil
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

--- 结束决斗
function M.endDuel(winner, loser)
    for id, d in pairs(activeDuels) do
        if (d.pid1 == winner and d.pid2 == loser) or (d.pid1 == loser and d.pid2 == winner) then
            activeDuels[id] = nil
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
