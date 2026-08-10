-- World of ClaudeCraft — Loot Rolling System
-- 战利品投掷 / 团队拾取策略 / FFA 超时
-- 对应原项目 src/sim/loot/loot_roll.ts + src/sim/loot/loot_ffa.ts

local simrng = require("world.simrng")
local M = {}

local LOOT_ROLL_TIMEOUT = 60     -- 60 秒 roll 超时
local FFA_TIMER = 120             -- 120 秒后自由拾取

-- 活跃的战利品 roll: { itemId, itemName, rollTimeout, rolls = {pid=value}, winnerPid }
local activeRolls = {}

--- 开始战利品 roll
function M.startLootRoll(mobId, itemId, itemName, eligiblePlayers)
    local rollId = mobId .. "_" .. itemId .. "_" .. os.time()
    activeRolls[rollId] = {
        rollId = rollId,
        itemId = itemId,
        itemName = itemName,
        mobId = mobId,
        rollTimeout = LOOT_ROLL_TIMEOUT,
        rolls = {},
        eligiblePlayers = eligiblePlayers,
        winnerPid = nil,
        completed = false,
    }
    return rollId
end

--- 玩家投掷
function M.rollLoot(rollId, pid)
    local roll = activeRolls[rollId]
    if not roll then return false end
    if roll.completed then return false end

    local isEligible = false
    for _, ep in ipairs(roll.eligiblePlayers) do
        if ep == pid then isEligible = true; break end
    end
    if not isEligible then return false end

    if roll.rolls[pid] then return false end  -- 已经投过

    local value = simrng.randint(1, 100)
    roll.rolls[pid] = value

    -- 检查是否所有人已投
    local allRolled = true
    for _, ep in ipairs(roll.eligiblePlayers) do
        if not roll.rolls[ep] then allRolled = false; break end
    end

    if allRolled then
        M._resolveRoll(roll)
    end

    return true, value
end

--- 更新战利品 roll (每个 tick)
function M.update(dt)
    local events = {}
    local toRemove = {}

    for rollId, roll in pairs(activeRolls) do
        if not roll.completed then
            roll.rollTimeout = roll.rollTimeout - dt
            if roll.rollTimeout <= 0 then
                M._resolveRoll(roll)  -- 超时: 用已投的人决定赢家
                events[rollId] = roll
            end
        end
        if roll.completed then
            toRemove[rollId] = true
            table.insert(events, {
                type = "loot_roll_result",
                itemId = roll.itemId,
                itemName = roll.itemName,
                winner = roll.winnerPid,
            })
        end
    end

    for rollId, _ in pairs(toRemove) do
        activeRolls[rollId] = nil
    end

    return events
end

--- 解决 roll 结果
function M._resolveRoll(roll)
    roll.completed = true
    local best, bestVal = nil, -1
    for pid, val in pairs(roll.rolls) do
        if val > bestVal then
            best = pid; bestVal = val
        end
    end
    roll.winnerPid = best
end

--- 自由拾取超时 (FFA)
function M.updateFfa(mobId, dt)
    -- 简化: 由 lifecycle 直接调用的 mob 尸体处理
    -- 在实际 TS 中，lootFfaTimer 在 entity 上
end

return M
