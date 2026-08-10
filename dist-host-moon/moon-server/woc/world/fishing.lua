-- World of ClaudeCraft — Fishing System
-- 钓鱼: 咬钩计时器, 收杆截止, 区域锁定
-- 对应原项目 src/sim entity.ts fishing fields + fish bite/reel logic

local simrng = require("world.simrng")
local M = {}

local FISH_BITE_MIN = 3    -- 最小咬钩时间 (秒)
local FISH_BITE_MAX = 12   -- 最大
local REEL_WINDOW = 2      -- 咬钩后 2 秒内收杆

-- 钓鱼产出表
local FISH_TABLE = {
    { name = "Raw Fish", weight = 40, value = 2 },
    { name = "Brightscale", weight = 25, value = 5 },
    { name = "Mudfish", weight = 20, value = 3 },
    { name = "Golden Koi", weight = 10, value = 15 },
    { name = "Anchored Rune", weight = 5, value = 25 },
}

--- 开始钓鱼
function M.startFishing(e, zoneId)
    if e.dead or e.ghost then return false end
    if e.fishCastZoneId and e.fishCastZoneId ~= "" then return false end  -- 已在钓鱼

    e.fishCastZoneId = zoneId or "lake"
    e.fishBiteAtTick = simrng.randfloat(FISH_BITE_MIN, FISH_BITE_MAX)
    e.fishReelDeadlineTick = 0
    return true
end

--- 停止钓鱼
function M.stopFishing(e)
    e.fishCastZoneId = ""
    e.fishBiteAtTick = 0
    e.fishReelDeadlineTick = 0
end

--- 更新 (每个 tick)
function M.update(e, dt, currentTick)
    if not e.fishCastZoneId or e.fishCastZoneId == "" then return nil end

    if e.fishBiteAtTick > 0 then
        e.fishBiteAtTick = e.fishBiteAtTick - dt
        if e.fishBiteAtTick <= 0 then
            -- 鱼上钩了!
            e.fishReelDeadlineTick = currentTick + REEL_WINDOW
            e.fishBiteAtTick = 0
            return { type = "fish_bite", pid = e.id, zoneId = e.fishCastZoneId }
        end
    end

    return nil
end

--- 收杆
function M.reel(e)
    if not e.fishCastZoneId or e.fishCastZoneId == "" then return false, nil end
    if e.fishReelDeadlineTick <= 0 then return false, nil end

    local caught = false
    if e.fishReelDeadlineTick >= 0 then  -- 在窗口内
        caught = M._rollFish()
    end

    M.stopFishing(e)
    return caught
end

--- 掷骰鱼类型
function M._rollFish()
    local roll = simrng.random() * 100
    local accumulated = 0
    for _, fish in ipairs(FISH_TABLE) do
        accumulated = accumulated + fish.weight
        if roll <= accumulated then
            return fish
        end
    end
    return FISH_TABLE[1]
end

return M
