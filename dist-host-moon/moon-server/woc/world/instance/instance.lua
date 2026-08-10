-- World of ClaudeCraft — Instance (Dungeon/Delve) System
-- enter_dungeon, leave_dungeon, enter_delve, leave_delve

local M = {}

-- 副本实例: instanceId → { type, difficulty, players, mobs, ... }
local instances = {}
-- player instance: pid → instanceId
local playerInstance = {}

--- 进入副本
function M.enterDungeon(pid, dungeonId, difficulty, entities)
    if playerInstance[pid] then return false, "Already in an instance" end

    local instId = dungeonId .. "_inst_" .. #instances
    instances[instId] = {
        type = "dungeon", dungeonId = dungeonId, difficulty = difficulty or "normal",
        players = { [pid] = true },
        mobs = {}, started = false, createdAt = os.time(),
    }
    playerInstance[pid] = instId
    return true, instId
end

--- 离开副本
function M.leaveInstance(pid)
    local instId = playerInstance[pid]
    if not instId then return false end
    local inst = instances[instId]
    if inst then
        inst.players[pid] = nil
        if next(inst.players) == nil then instances[instId] = nil end
    end
    playerInstance[pid] = nil
    return true
end

--- 进入 deep学习
function M.enterDelve(pid, delveId, layer)
    return M.enterDungeon(pid, "delve_" .. delveId, "layer" .. tostring(layer or 1))
end

--- 获取副本信息
function M.getInstanceId(pid)
    return playerInstance[pid]
end

--- 清理玩家所有实例
function M.cleanup(pid)
    M.leaveInstance(pid)
end

return M
