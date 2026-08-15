-- World of ClaudeCraft — Frozen Orb Manager
-- 对应原项目 src/sim/combat/frozen_orb.ts
-- 冰冻球: 直线飞行/停止脉冲/过期清除

local config = require("config")
local grid = require("world.grid")
local M = {}

local FROZEN_ORB_SPEED = 12  -- yards/sec

-- frozenOrbs: { sourceId, x, z, dirX, dirZ, radius, remaining, pulseTimer, interval, halted }
local frozenOrbs = {}

--- 施放冰冻球
function M.launch(sourceId, sourcePos, facing, opts)
    opts = opts or {}
    table.insert(frozenOrbs, {
        sourceId = sourceId,
        x = sourcePos.x,
        z = sourcePos.z,
        dirX = math.sin(facing),
        dirZ = math.cos(facing),
        radius = opts.radius or 8,
        remaining = opts.duration or 10,
        pulseTimer = 0,
        interval = opts.interval or 1,
        halted = false,
    })
end

--- Tick: 推进冰冻球
function M.tick(entities, dt, simrng)
    local events = {}
    local active = {}

    for i, orb in ipairs(frozenOrbs) do
        local source = entities[orb.sourceId]
        if not source or source.dead then
            goto skip_orb
        end

        -- 移动 (未停止时)
        if not orb.halted then
            orb.x = orb.x + orb.dirX * FROZEN_ORB_SPEED * dt
            orb.z = orb.z + orb.dirZ * FROZEN_ORB_SPEED * dt
        end

        orb.remaining = orb.remaining - dt
        orb.pulseTimer = orb.pulseTimer - dt

        if orb.pulseTimer <= 0 then
            orb.pulseTimer = orb.pulseTimer + orb.interval
            -- 脉冲: 对范围内的敌对实体造成伤害
            local cand = grid.queryRadius(orb.x, orb.z, orb.radius, entities)
            for _, e in ipairs(cand) do
                if e.id ~= orb.sourceId and not e.dead then
                    local dmg = (source.spellPower or 0) * 0.1 + 5
                    e.hp = math.max(0, e.hp - math.floor(dmg + 0.5))
                    table.insert(events, { type = "frozen_orb_pulse", sourceId = orb.sourceId, targetId = e.id, dmg = math.floor(dmg + 0.5) })
                end
            end
            grid.releaseRadiusResult(cand)
        end

        if orb.remaining > 0 then
            table.insert(active, orb)
        end
        ::skip_orb::
    end

    frozenOrbs = active
    return events
end

function M.getActiveCount()
    return #frozenOrbs
end

return M
