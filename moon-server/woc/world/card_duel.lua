-- World of ClaudeCraft — Card Duel Minigame
-- 卡牌大师 NPC 的卡牌决斗小游戏
-- 对应原项目 src/sim/social/card_duel.ts + src/sim/minigames/card_hand.ts

local simrng = require("world.simrng")
local M = {}

local CARD_DUEL_QUEUE_TIMEOUT = 30
local CARD_DUEL_TURN_TIME = 30

-- 卡牌手牌 (每回合抽 1 张)
local CARD_VALUES = { 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 }

-- 玩家状态: { pid, opponentPid, hand, score, turn, turnTimer }
local duels = {}

--- 开始决斗 (双方玩家都在卡牌大师附近时)
function M.startDuel(pid1, pid2, entities)
    if duels[pid1] or duels[pid2] then return false end

    local hand1 = {}
    local hand2 = {}
    for i = 1, 3 do
        hand1[i] = CARD_VALUES[simrng.randint(1, #CARD_VALUES)]
        hand2[i] = CARD_VALUES[simrng.randint(1, #CARD_VALUES)]
    end

    duels[pid1] = {
        pid = pid1, opponentPid = pid2,
        hand = hand1, score = 0, turn = 1, turnTimer = CARD_DUEL_TURN_TIME,
        playedThisTurn = false,
    }
    duels[pid2] = {
        pid = pid2, opponentPid = pid1,
        hand = hand2, score = 0, turn = 1, turnTimer = CARD_DUEL_TURN_TIME,
        playedThisTurn = false,
    }

    return true
end

--- 出牌
function M.playCard(pid, cardIndex)
    local duel = duels[pid]
    if not duel then return false, "Not in a duel" end
    if duel.playedThisTurn then return false, "Already played" end
    if cardIndex < 1 or cardIndex > #duel.hand then return false, "Invalid card" end

    local cardValue = table.remove(duel.hand, cardIndex)
    duel.score = duel.score + cardValue
    duel.playedThisTurn = true

    -- 抽新牌
    table.insert(duel.hand, CARD_VALUES[simrng.randint(1, #CARD_VALUES)])

    return true, cardValue
end

--- 结束回合
function M.endTurn(pid)
    local duel = duels[pid]
    if not duel then return false end
    duel.turn = duel.turn + 1
    duel.turnTimer = CARD_DUEL_TURN_TIME
    duel.playedThisTurn = false
    return true
end

--- 更新卡牌决斗 (每个 tick)
function M.update(simTime, entities, dt)
    local events = {}
    local toRemove = {}

    for pid, duel in pairs(duels) do
        local opponent = duels[duel.opponentPid]
        if not opponent then
            toRemove[pid] = true
            goto continue_duel
        end

        -- 回合计时器
        duel.turnTimer = duel.turnTimer - dt
        if duel.turnTimer <= 0 then
            M.endTurn(pid)  -- 超时自动结束回合
        end

        -- 检查对手是否已结束回合（同步回合推进）
        if opponent.turn > duel.turn then
            duel.turn = opponent.turn
            duel.turnTimer = CARD_DUEL_TURN_TIME
            duel.playedThisTurn = false
        end

        -- 10 回合后比赛结束
        if duel.turn > 10 or opponent.turn > 10 then
            local winner
            if duel.score > opponent.score then winner = pid
            elseif opponent.score > duel.score then winner = duel.opponentPid end
            table.insert(events, {
                type = "card_duel_end",
                pid = pid,
                opponentPid = duel.opponentPid,
                score = duel.score,
                opponentScore = opponent.score,
                winner = winner,
            })
            toRemove[pid] = true
            toRemove[duel.opponentPid] = true
        end

        ::continue_duel::
    end

    for pid, _ in pairs(toRemove) do
        duels[pid] = nil
    end

    return events
end

--- 玩家离开卡牌大师范围时取消
function M.cancelDuel(pid)
    local duel = duels[pid]
    if duel then
        duels[duel.opponentPid] = nil
        duels[pid] = nil
    end
end

-- 卡牌大师的等待队列
local cardQueue = {}

--- 加入卡牌排队
function M.joinCardQueue(pid)
    for _, qp in ipairs(cardQueue) do
        if qp == pid then return false end
    end
    if duels[pid] then return false end
    table.insert(cardQueue, pid)
    if #cardQueue >= 2 then
        local p1 = table.remove(cardQueue, 1)
        local p2 = table.remove(cardQueue, 1)
        M.startDuel(p1, p2)
        return true, "matched"
    end
    return true, "waiting"
end

--- 离开卡牌排队
function M.leaveCardQueue(pid)
    for i, qp in ipairs(cardQueue) do
        if qp == pid then table.remove(cardQueue, i); return true end
    end
    return false
end

--- 认输
function M.forfeitCardDuel(pid)
    local duel = duels[pid]
    if not duel then return false, "Not in a duel" end
    local oppPid = duel.opponentPid
    duels[pid] = nil
    if oppPid then duels[oppPid] = nil end
    return true, oppPid
end

--- 获取决斗状态
function M.getDuel(pid)
    return duels[pid]
end

return M
