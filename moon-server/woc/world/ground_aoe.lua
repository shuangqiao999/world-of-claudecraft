-- World of ClaudeCraft — Ground AoE Manager
-- 管理持续性地面 AoE 效果 (Blizzard, Consecration, etc.)
-- 对应原项目 src/sim/entity_roster.ts tickGroundAoEs

local config = require("config")
local grid = require("world.grid")
local M = {}

-- 地面 AoE 列表: { sourceId, pos{x,z}, radius, remaining, tickInterval, tickTimer, abilityId, school, damage }
local groundAoEs = {}

--- 放置地面 AoE
function M.add(sourceId, pos, opts)
    table.insert(groundAoEs, {
        sourceId = sourceId,
        pos = { x = pos.x, z = pos.z },
        radius = opts.radius or 8,
        remaining = opts.duration or 6,
        tickInterval = opts.tickInterval or 1,
        tickTimer = 0,
        abilityId = opts.abilityId,
        school = opts.school or "frost",
        damage = opts.damage or 5,
        damageCoeff = opts.damageCoeff or 0.1,
        maxTargets = opts.maxTargets or 10,
        targetKind = opts.targetKind or "mob",
    })
end

--- Tick: 更新所有地面 AoE (应用伤害 + 清理过期)
function M.tick(entities, dt)
    local events = {}
    local active = {}

    for _, gae in ipairs(groundAoEs) do
        gae.remaining = gae.remaining - dt
        if gae.remaining <= 0 then
            table.insert(events, { type = "ground_aoe_expired", abilityId = gae.abilityId })
        else
            gae.tickTimer = gae.tickTimer + dt
            if gae.tickTimer >= gae.tickInterval then
                gae.tickTimer = gae.tickTimer - gae.tickInterval

                local targets = {}
                local cand = grid.queryRadius(gae.pos.x, gae.pos.z, gae.radius, entities)
                for _, e in ipairs(cand) do
                    if (not gae.targetKind or e.kind == gae.targetKind) and not e.dead then
                        table.insert(targets, e)
                    end
                end
                grid.releaseRadiusResult(cand)

                -- 限制目标数
                if #targets > gae.maxTargets then
                    table.sort(targets, function(a, b)
                        local da = (a.pos.x - gae.pos.x)^2 + (a.pos.z - gae.pos.z)^2
                        local db = (b.pos.x - gae.pos.x)^2 + (b.pos.z - gae.pos.z)^2
                        if da ~= db then return da < db end
                        return a.id < b.id
                    end)
                    while #targets > gae.maxTargets do table.remove(targets) end
                end

                for _, t in ipairs(targets) do
                    local dmg = gae.damage
                    local source = entities[gae.sourceId]
                    if source then
                        dmg = dmg + (source.spellPower or 0) * gae.damageCoeff
                    end
                    t.hp = math.max(0, t.hp - math.floor(dmg + 0.5))
                    table.insert(events, {
                        type = "damage",
                        sourceId = gae.sourceId,
                        targetId = t.id,
                        amount = math.floor(dmg + 0.5),
                        crit = false,
                        school = gae.school or "magic",
                        ability = gae.abilityId,
                        kind = "hit",
                    })
                end
            end
            table.insert(active, gae)
        end
    end

    groundAoEs = active
    return events
end

return M
