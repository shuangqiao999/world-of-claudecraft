-- World of ClaudeCraft — Rested XP System
-- 在城镇或安全区域获取双倍经验
-- 对应原项目 src/sim/progression/xp.ts updateRested

local M = {}

-- 休息 XP 累积率: 每 tick 累积 1% 的休息经验池
local RESTED_ACCUMULATION_RATE = 0.01  -- 每 tick 1% of max
local MAX_RESTED_MULTIPLIER = 1.0       -- 最多 1 级额外经验 (100%)

--- 检查实体是否在休息区域
--- @param e Entity
--- @return boolean
function M.isResting(e)
    -- 简化: 玩家周围没有 hostile mob 即视为安全区域
    -- 完整实现需要检查建筑/营地距离
    return e.pos.y < 1  -- 假设地面高度 < 1 是安全区域 (简化)
end

--- 更新休息 XP
--- @param e Entity
--- @param meta PlayerMeta
--- @param dt number
function M.updateRested(e, meta, dt)
    if not meta then return end

    -- 是否在休息
    if M.isResting(e) then
        local maxRestXp = meta.xp or 0  -- 简化: 使用当前经验值作为上限
        local maxAccumulation = maxRestXp * MAX_RESTED_MULTIPLIER
        local currentRest = meta.restedXp or 0
        if currentRest < maxAccumulation then
            meta.restedXp = math.min(maxAccumulation,
                currentRest + maxRestXp * RESTED_ACCUMULATION_RATE * dt)
        end
    end
end

return M
