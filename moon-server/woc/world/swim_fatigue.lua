-- World of ClaudeCraft — Swim Fatigue (Open-Sea Distance Clock)
-- 对应原项目 src/sim/fatigue.ts
-- 远海无墙, 距离本身逼退泳者: 警告 → 宽限 → 递升无豁免伤害

local config = require("config")
local m3d = require("world.math3d")
local M = {}

-- TS 常量 (SLOWDOWN = 5, 全部乘以 5)
local SLOWDOWN = 5
local GRACE_TICKS = 160 * SLOWDOWN      -- 40s 警告期
local PULSE_TICKS = 20 * SLOWDOWN       -- 之后每 5s 一次脉冲
local PULSE_PCT = 0.08                  -- 递升: 8%, 16%, 24%... of maxHp
local REWARN_TICKS = 80 * SLOWDOWN      -- 每 20s 重复屏幕警告
local FATIGUE_WARNING = "The open sea saps your strength. Swim back to shore!"

-- 简化世界: 距原点超过此距离视为远海 (Hollow 开放海域)
local OPEN_SEA_RADIUS = 500
local WATER_LEVEL = -1.5

--- 是否在远海 (TS inHollowOpenSea 简化: 距离 + 水中)
function M.inHollowOpenSea(x, z)
    local dist = m3d.dist(x, z)
    return dist > OPEN_SEA_RADIUS
end

--- 更新泳者疲劳 (每 tick, 每个玩家)
function M.updateSwimFatigue(e, pos)
    if e.kind ~= "player" then return {} end
    local events = {}

    -- TS: swimmingOut = pos.y <= waterLevel + 0.4 && inHollowOpenSea && !dead
    local swimmingOut = (pos.y or 0) <= WATER_LEVEL + 0.4 and M.inHollowOpenSea(pos.x, pos.z) and not e.dead
    if not swimmingOut then
        e.fatigueTicks = 0
        return events
    end

    e.fatigueTicks = (e.fatigueTicks or 0) + 1
    if e.fatigueTicks == 1 then
        table.insert(events, { type = "log", text = FATIGUE_WARNING, color = "#f96", pid = e.id })
    end
    if e.fatigueTicks % REWARN_TICKS == 1 then
        table.insert(events, { type = "error", text = FATIGUE_WARNING, pid = e.id })
    end

    local past = e.fatigueTicks - GRACE_TICKS
    if past > 0 and past % PULSE_TICKS == 0 then
        local pulses = math.floor(past / PULSE_TICKS)
        local dmg = math.max(5, math.round(e.maxHp * PULSE_PCT * pulses))
        if dmg > 0 then
            e.hp = math.max(0, e.hp - dmg)
            table.insert(events, { type = "damage", sourceId = -1, targetId = e.id,
                amount = dmg, crit = false, school = "physical", ability = nil, kind = "hit" })
        end
    end

    return events
end

return M
