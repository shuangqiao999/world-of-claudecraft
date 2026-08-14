-- World of ClaudeCraft — Book of Deeds (Renown Scoring)
-- 功勋之书: 成就追踪、声望评分
-- 对应原项目 src/sim/deeds.ts

local M = {}

-- 功勋定义 (简化版)
local DEEDS = {
    -- 探索
    explorer = { id = "explorer", name = "Explorer", description = "Discover 3 zones", threshold = 3, renown = 10 },
    -- 战斗
    first_blood = { id = "first_blood", name = "First Blood", description = "Kill your first boss", threshold = 1, renown = 15 },
    boss_slayer = { id = "boss_slayer", name = "Boss Slayer", description = "Kill 5 bosses", threshold = 5, renown = 30 },
    mob_slayer = { id = "mob_slayer", name = "Mob Slayer", description = "Kill 100 mobs", threshold = 100, renown = 20 },
    -- 升级
    novice = { id = "novice", name = "Novice", description = "Reach level 10", threshold = 10, renown = 10 },
    veteran = { id = "veteran", name = "Veteran", description = "Reach level 20", threshold = 20, renown = 25 },
    -- 社交
    party_leader = { id = "party_leader", name = "Party Leader", description = "Complete 10 dungeons", threshold = 10, renown = 25 },
    -- 竞技
    arena_rookie = { id = "arena_rookie", name = "Arena Rookie", description = "Win 5 arena matches", threshold = 5, renown = 20 },
    arena_veteran = { id = "arena_veteran", name = "Arena Veteran", description = "Win 20 arena matches", threshold = 20, renown = 35 },
    -- 裂隙
    rift_runner = { id = "rift_runner", name = "Rift Runner", description = "Complete 5 rifts", threshold = 5, renown = 25 },
    -- 财富
    tycoon = { id = "tycoon", name = "Tycoon", description = "Accumulate 10,000 copper", threshold = 10000, renown = 15 },
    -- 深入探索
    deep_diver = { id = "deep_diver", name = "Deep Diver", description = "Complete 3 delves", threshold = 3, renown = 30 },
}

-- 玩家功勋追踪: { pid → { deedId = count, ... } }
local playerDeeds = {}
-- 玩家已完成的功勋: { pid → { deedId = true, ... } }
local completedDeeds = {}
-- 玩家声望分数
local renownScores = {}

--- 初始化玩家功勋追踪
function M.initPlayer(pid)
    if not playerDeeds[pid] then
        playerDeeds[pid] = {}
        completedDeeds[pid] = {}
        renownScores[pid] = 0
    end
end

--- 清理
function M.cleanupPlayer(pid)
    playerDeeds[pid] = nil
    completedDeeds[pid] = nil
    renownScores[pid] = nil
end

--- 记录事件进度
function M.track(pid, deedType, count)
    M.initPlayer(pid)

    local deeds = playerDeeds[pid]
    deeds[deedType] = (deeds[deedType] or 0) + (count or 1)
end

--- 检查功勋完成 (每个 tick)
function M.update(pid)
    local events = {}
    M.initPlayer(pid)

    local deeds = playerDeeds[pid]
    local completed = completedDeeds[pid]

    for deedId, deed in pairs(DEEDS) do
        if not completed[deedId] then
            local progress = deeds[deedId] or 0
            if progress >= deed.threshold then
                completed[deedId] = true
                renownScores[pid] = (renownScores[pid] or 0) + deed.renown
                table.insert(events, {
                    type = "deed_unlocked",
                    pid = pid,
                    deedId = deedId,
                    name = deed.name,
                    renown = deed.renown,
                })
            end
        end
    end

    return events
end

--- 获取声望分数
function M.getRenown(pid)
    return renownScores[pid] or 0
end

--- 获取已完成功勋
function M.getCompleted(pid)
    return completedDeeds[pid] or {}
end

--- 记录击杀 (在 onKill 时调用)
function M.onKill(pid, templateId)
    if templateId and (templateId == "boss_wolf" or templateId:find("boss")) then
        M.track(pid, "first_blood", 1)
        M.track(pid, "boss_slayer", 1)
    end
    M.track(pid, "mob_slayer", 1)
end

--- 记录升级
function M.onLevelUp(pid, newLevel)
    if newLevel >= 10 then M.track(pid, "novice", 1) end
    if newLevel >= 20 then M.track(pid, "veteran", 1) end
end

--- 记录地下城完成
function M.onDungeonComplete(pid)
    M.track(pid, "party_leader", 1)
end

--- 记录竞技场胜利
function M.onArenaWin(pid)
    M.track(pid, "arena_rookie", 1)
    M.track(pid, "arena_veteran", 1)
end

--- 记录裂隙完成
function M.onRiftComplete(pid)
    M.track(pid, "rift_runner", 1)
end

--- 记录深入探索完成
function M.onDelveComplete(pid)
    M.track(pid, "deep_diver", 1)
end

--- 记录财富变化
function M.onCopperChange(pid, totalCopper)
    M.track(pid, "tycoon", 0)  -- 初始化追踪
    -- 检查是否达到阈值
    local deeds = playerDeeds[pid] or {}
    if totalCopper >= DEEDS.tycoon.threshold then
        deeds.tycoon = totalCopper
    end
end

return M
