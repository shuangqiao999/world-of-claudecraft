-- World of ClaudeCraft — Breath (Underwater Drowning) System
-- 对应原项目 src/sim/breath.ts
-- 水下 60 秒肺活量; 空的肺每 tick 扣 maxHp * 10%; 出水时 10x 速度恢复

local config = require("config")
local M = {}

local BREATH_SECONDS = 60
local BREATH_REFILL_MULT = 10
local DROWN_PULSE_PCT = 0.1

local BREATH_TICKS = math.round(BREATH_SECONDS / config.DT)
local DROWN_PULSE_TICKS = math.round(1 / config.DT)

--- 更新呼吸 (每个 tick, 对每个玩家)
function M.updateBreath(e, isSubmerged)
    if not e or e.kind ~= "player" then return end
    if e.dead then
        e.breathUsedTicks = 0
        e.drownTicks = 0
        return
    end
    if isSubmerged then
        if e.breathUsedTicks < BREATH_TICKS then
            e.breathUsedTicks = e.breathUsedTicks + 1
            e.drownTicks = 0
            return
        end
        -- 肺空了还在水下: 溺水时钟
        e.drownTicks = e.drownTicks + 1
        if e.drownTicks % DROWN_PULSE_TICKS == 0 then
            local dmg = math.max(1, math.round(e.maxHp * DROWN_PULSE_PCT))
            return { dmg = dmg }
        end
        return
    end
    e.drownTicks = 0
    e.breathUsedTicks = math.max(0, e.breathUsedTicks - BREATH_REFILL_MULT)
    return
end

--- 显示侧镜像时钟 (秒)
function M.breathFraction(usedSeconds)
    return math.min(1, math.max(0, 1 - usedSeconds / BREATH_SECONDS))
end

return M
