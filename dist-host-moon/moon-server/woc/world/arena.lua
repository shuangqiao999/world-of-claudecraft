-- World of ClaudeCraft — Arena System (Elo Matchmaking)
-- 2v2 排名竞技场，Elo 评分
-- 对应原项目 src/sim/social/arena.ts

local M = {}
local deeds = require("world.deeds")

-- 全局配置
local ARENA_ELO_K = 32         -- Elo K 因子
local ARENA_LADDER_SIZE = 100  -- 排行榜大小
local ARENA_MATCH_QUEUE_TIMEOUT = 60  -- 匹配队列超时(秒)

-- 队伍结构: { teamId, players = {pid1, pid2}, mmr }
local teams = {}
local queue = {}             -- { teamId, queueTime }
local matches = {}           -- { matchId, team1, team2, startTime }
local matchCounter = 0

-- 玩家 Elo 评分
local playerRating = {}      -- { pid = rating }

-- 默认 MMR
local DEFAULT_RATING = 1000

--- 获取玩家 MMR
function M.getRating(pid)
    return playerRating[pid] or DEFAULT_RATING
end

--- 获取队伍成员 pid 列表
function M.getTeamPlayers(teamId)
    local t = teams[teamId]
    if not t then return {} end
    return t.players
end

--- 创建队伍
function M.createTeam(pid1, pid2)
    local teamId = pid1 .. "_" .. pid2
    teams[teamId] = {
        teamId = teamId,
        players = { pid1, pid2 },
        mmr = math.floor((M.getRating(pid1) + M.getRating(pid2)) / 2),
    }
    return teamId
end

--- 加入竞技场队列
function M.queueTeam(teamId, simTime)
    if not teams[teamId] then return false end
    queue[teamId] = simTime
    return true
end

--- 离开队列
function M.leaveQueue(teamId)
    queue[teamId] = nil
end

--- 查找匹配
local function findMatch()
    local queuedList = {}
    for teamId, qt in pairs(queue) do
        table.insert(queuedList, { teamId = teamId, mmr = teams[teamId].mmr, queueTime = qt })
    end

    if #queuedList < 2 then return nil end

    -- 按 MMR 排序
    table.sort(queuedList, function(a, b) return a.mmr < b.mmr end)

    -- 找 MMR 差值最小的配对
    local best, bestDiff = nil, math.huge
    for i = 1, #queuedList do
        for j = i + 1, #queuedList do
            local diff = math.abs(queuedList[i].mmr - queuedList[j].mmr)
            if diff < bestDiff then
                bestDiff = diff
                best = { queuedList[i], queuedList[j] }
            end
        end
    end

    if best then
        local team1, team2 = best[1], best[2]
        matchCounter = matchCounter + 1
        matches[matchCounter] = {
            matchId = matchCounter,
            team1 = team1.teamId,
            team2 = team2.teamId,
            startTime = 0,  -- 在 tick 中设置
            winner = nil,
        }
        queue[team1.teamId] = nil
        queue[team2.teamId] = nil
        return matches[matchCounter]
    end

    return nil
end

--- 更新竞技场 (每个 tick)
--- @param simTime number
--- @param dt number
--- @return table 事件列表
function M.update(simTime, dt, entities)
    local events = {}

    -- 队列超时检查
    for teamId, qt in pairs(queue) do
        if simTime - qt > ARENA_MATCH_QUEUE_TIMEOUT then
            queue[teamId] = nil
        end
    end

    -- 匹配
    local match = findMatch()
    if match then
        table.insert(events, {
            type = "arena_match_found",
            matchId = match.matchId,
            team1 = match.team1,
            team2 = match.team2,
        })
    end

    -- 活动比赛逻辑 (简化: 只跟踪)
    for matchId, m in pairs(matches) do
        if not m.winner then
            -- 检查是否有一方全灭
            local t1 = teams[m.team1]
            local t2 = teams[m.team2]
            if t1 and t2 then
                local t1Alive = false
                for _, pid in ipairs(t1.players) do
                    if entities[pid] and not entities[pid].dead then t1Alive = true end
                end
                local t2Alive = false
                for _, pid in ipairs(t2.players) do
                    if entities[pid] and not entities[pid].dead then t2Alive = true end
                end
                if not t1Alive and t2Alive then
                    m.winner = m.team2
                    M._applyElo(m.team1, m.team2)
                elseif t1Alive and not t2Alive then
                    m.winner = m.team1
                    M._applyElo(m.team2, m.team1)
                end
                if m.winner then
                    local winnerTeam = teams[m.winner]
                    if winnerTeam then
                        for _, wpid in ipairs(winnerTeam.players) do
                            deeds.onArenaWin(wpid)
                        end
                    end
                    table.insert(events, {
                        type = "arena_match_end",
                        matchId = matchId,
                        winner = m.winner,
                    })
                end
            end
        end
    end

    -- 清理已结束的比赛
    local toRemove = {}
    for matchId, m in pairs(matches) do
        if m.winner and simTime - (m.startTime or simTime) > 30 then
            table.insert(toRemove, matchId)
        end
    end
    for _, matchId in ipairs(toRemove) do
        matches[matchId] = nil
    end

    return events
end

--- 应用 Elo 更新
function M._applyElo(loserTeam, winnerTeam)
    local lt = teams[loserTeam]
    local wt = teams[winnerTeam]
    if not lt or not wt then return end

    local expected = 1 / (1 + 10 ^ ((lt.mmr - wt.mmr) / 400))
    local scoreDiff = ARENA_ELO_K * (1 - expected)

    -- 更新团队 MMR
    lt.mmr = math.max(0, lt.mmr - scoreDiff)
    wt.mmr = math.min(3000, wt.mmr + scoreDiff)

    -- 更新个人评分
    for _, pid in ipairs(lt.players) do
        playerRating[pid] = math.max(0, M.getRating(pid) - scoreDiff / 2)
    end
    for _, pid in ipairs(wt.players) do
        playerRating[pid] = math.min(3000, M.getRating(pid) + scoreDiff / 2)
    end
end

return M
