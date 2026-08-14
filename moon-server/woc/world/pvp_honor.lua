-- World of ClaudeCraft — PvP Honor System
-- WARFARE 荣誉货币 + 战斗等级规则
-- 对应原项目 src/sim/pvp/honor.ts

local M = {}

-- PvP 等级
local RANKS = {
    { name = "Private", minHonor = 0 },
    { name = "Corporal", minHonor = 100 },
    { name = "Sergeant", minHonor = 300 },
    { name = "Master Sergeant", minHonor = 700 },
    { name = "Knight", minHonor = 1500 },
    { name = "Knight-Captain", minHonor = 3000 },
    { name = "Commander", minHonor = 5000 },
    { name = "Grand Marshal", minHonor = 10000 },
}

-- 玩家荣誉: { pid = honorPoints }
local playerHonor = {}
-- 玩家 WARFARE 货币
local warfareCurrency = {}

--- 初始化
function M.initPlayer(pid)
    if not playerHonor[pid] then playerHonor[pid] = 0 end
    if not warfareCurrency[pid] then warfareCurrency[pid] = 0 end
end

--- 获取荣誉
function M.getHonor(pid)
    M.initPlayer(pid)
    return playerHonor[pid]
end

--- 获取军衔
function M.getRank(pid)
    local honor = M.getHonor(pid)
    local rank = RANKS[1]
    for _, r in ipairs(RANKS) do
        if honor >= r.minHonor then rank = r end
    end
    return rank
end

--- 获取 WARFARE 货币
function M.getWarfare(pid)
    M.initPlayer(pid)
    return warfareCurrency[pid]
end

--- 消耗 WARFARE
function M.spendWarfare(pid, amount)
    M.initPlayer(pid)
    if warfareCurrency[pid] < amount then return false end
    warfareCurrency[pid] = warfareCurrency[pid] - amount
    return true
end

--- 奖励荣誉 (击杀敌对玩家)
function M.awardHonor(pid, targetLevel)
    M.initPlayer(pid)
    local baseHonor = 10
    local levelBonus = (targetLevel or 1) * 1.5
    local honorGain = math.floor(baseHonor + levelBonus + 0.5)

    playerHonor[pid] = playerHonor[pid] + honorGain
    -- 同时给予 WARFARE
    warfareCurrency[pid] = warfareCurrency[pid] + math.floor(honorGain * 0.5 + 0.5)

    return honorGain
end

--- 获取 PvP 战斗力加成 (简化)
function M.getPvpPower(pid)
    return 0  -- Phase 1 暂不实现
end

return M
