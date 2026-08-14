-- World of ClaudeCraft — Battleground System
-- Thornhollow Fields 5v5 CTF (简化版)
-- 对应原项目 src/sim/social/battleground.ts

local M = {}

local QUEUE_SIZE = 10           -- 5v5
local BATTLEGROUND_CAP_SCORE = 3  -- 3 次夺旗获胜
local BATTLEGROUND_DURATION = 20 * 60  -- 20 分钟上限

-- 战场队列
local bgQueue = {}              -- { pid = joinTime }
local activeMatch = nil         -- { horde = {pid1,...}, alliance = {pid1,...}, flagHeldBy, scores, startTime }

--- 加入战场队列
function M.queuePlayer(pid, simTime)
    bgQueue[pid] = simTime
end

--- 离开战场队列
function M.leaveQueue(pid)
    bgQueue[pid] = nil
end

--- 获取队列数量
function M.queueSize()
    local n = 0
    for _ in pairs(bgQueue) do n = n + 1 end
    return n
end

--- 更新战场 (每个 tick)
--- @param simTime number
--- @param entities table
--- @return table 事件列表
function M.update(simTime, entities)
    local events = {}

    -- 检查是否可以开始新战场
    if not activeMatch and M.queueSize() >= QUEUE_SIZE then
        local players = {}
        local count = 0
        for pid, _ in pairs(bgQueue) do
            if count < QUEUE_SIZE then
                table.insert(players, pid)
                bgQueue[pid] = nil
                count = count + 1
            end
        end

        if #players >= QUEUE_SIZE then
            -- 分配到两个队伍
            local horde = {}
            local alliance = {}
            for i, pid in ipairs(players) do
                if i <= QUEUE_SIZE / 2 then
                    table.insert(horde, pid)
                else
                    table.insert(alliance, pid)
                end
            end

            activeMatch = {
                horde = horde,
                alliance = alliance,
                hordeScore = 0,
                allianceScore = 0,
                flagHeldBy = nil,          -- "horde" or "alliance"
                flagCarrierId = nil,
                startTime = simTime,
            }

            table.insert(events, {
                type = "battleground_start",
                horde = horde,
                alliance = alliance,
            })
            print(string.format("[BG] Battle started! Horde=%d Alliance=%d", #horde, #alliance))
        end
    end

    -- 比赛计时/完成检查
    if activeMatch then
        -- 时间到
        if simTime - activeMatch.startTime > BATTLEGROUND_DURATION then
            local winner
            if activeMatch.hordeScore > activeMatch.allianceScore then
                winner = "horde"
            elseif activeMatch.allianceScore > activeMatch.hordeScore then
                winner = "alliance"
            end
            table.insert(events, {
                type = "battleground_end",
                hordeScore = activeMatch.hordeScore,
                allianceScore = activeMatch.allianceScore,
                winner = winner,
            })
            activeMatch = nil
        end

        -- 夺旗满
        if activeMatch and (activeMatch.hordeScore >= BATTLEGROUND_CAP_SCORE or activeMatch.allianceScore >= BATTLEGROUND_CAP_SCORE) then
            local winner
            if activeMatch.hordeScore >= BATTLEGROUND_CAP_SCORE then winner = "horde"
            else winner = "alliance" end
            table.insert(events, {
                type = "battleground_end",
                hordeScore = activeMatch.hordeScore,
                allianceScore = activeMatch.allianceScore,
                winner = winner,
            })
            activeMatch = nil
        end
    end

    return events
end

--- 获取战场状态
function M.getState()
    return activeMatch
end

--- 记录夺旗 (由命令系统调用)
function M.captureFlag(pid)
    if not activeMatch then return end

    local teamOf = M.getPlayerTeam(pid)
    if not teamOf then return end

    if teamOf == "horde" then
        activeMatch.hordeScore = activeMatch.hordeScore + 1
    else
        activeMatch.allianceScore = activeMatch.allianceScore + 1
    end
end

--- 获取玩家所在队伍
function M.getPlayerTeam(pid)
    if not activeMatch then return nil end
    for _, hp in ipairs(activeMatch.horde) do
        if hp == pid then return "horde" end
    end
    for _, ap in ipairs(activeMatch.alliance) do
        if ap == pid then return "alliance" end
    end
    return nil
end

return M
