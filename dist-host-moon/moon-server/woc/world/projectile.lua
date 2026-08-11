-- World of ClaudeCraft — In-Flight Projectile Manager
-- 对应原项目 src/sim/projectile_travel.ts scheduleProjectile
-- 投射物在命中时执行回调 (施法完成时锁定, 命中时解析)

local config = require("config")
local m3d = require("world.math3d")
local M = {}

local PROJECTILE_SPEED = 40  -- yards/second

-- pendingProjectiles: { sourceId, targetId, abilityId, remaining, onHit }
local pendingProjectiles = {}

--- 发射投射物 (TS scheduleProjectile: 命中时调用 onHit(source, target))
function M.launch(sourceId, targetId, abilityId, sourcePos, targetPos, onHit, opts)
    opts = opts or {}
    local dx = (targetPos.x or targetPos) - (sourcePos.x or 0)
    local dz = (targetPos.z or 0) - (sourcePos.z or 0)
    local dist = m3d.dist(dx, dz)
    local travelTime = opts.travelTime or (dist > 0 and dist / PROJECTILE_SPEED or 0.25)
    if travelTime < 0.1 then travelTime = 0.1 end

    table.insert(pendingProjectiles, {
        sourceId = sourceId,
        targetId = targetId,
        abilityId = abilityId,
        remaining = travelTime,
        onHit = onHit,
    })
end

--- Tick: 推进所有飞行中的投射物
function M.tick(entities, dt)
    local events = {}
    local active = {}

    for _, proj in ipairs(pendingProjectiles) do
        proj.remaining = proj.remaining - dt
        if proj.remaining <= 0 then
            -- 投射物到达目标 (目标死亡则落空)
            local target = entities[proj.targetId]
            local source = entities[proj.sourceId]
            if target and source and not target.dead then
                table.insert(events, {
                    type = "projectile_hit",
                    sourceId = proj.sourceId,
                    targetId = proj.targetId,
                    abilityId = proj.abilityId,
                })
                if proj.onHit then
                    local hitEvents = proj.onHit(source, target)
                    if hitEvents then
                        for _, ev in ipairs(hitEvents) do
                            table.insert(events, ev)
                        end
                    end
                end
            end
        else
            table.insert(active, proj)
        end
    end

    pendingProjectiles = active
    return events
end

function M.getActiveCount()
    return #pendingProjectiles
end

return M
