-- World of ClaudeCraft — Despawn Decay System
-- 对应原项目 src/sim/entity_roster.ts runDespawnDecay + DAMAGE_IDLE_DESPAWN
-- 闲置 mob 超时清理; 尸体倒计时清理

local config = require("config")
local M = {}

local DAMAGE_IDLE_DESPAWN_SECONDS = 60
local CORPSE_DECAY_SECONDS = 60

-- 需要闲置清理的 mob 类型
local DESPAWN_IDS = {
    ["varkas_boneguard"] = true,
    ["bound_guardian"] = true,
    ["dragonkin_whelp"] = true,
}

--- Tick: 处理 despawn decay
function M.tick(entities, dt)
    local toRemove = {}

    for id, e in pairs(entities) do
        if e.kind == "mob" then
            -- 闲置超时清理 (仅 boss adds / summoned adds)
            if e.summonedAdd then
                if e.idleTimer then
                    e.idleTimer = e.idleTimer - dt
                    if e.idleTimer <= 0 and not e.inCombat then
                        toRemove[id] = true
                    end
                else
                    e.idleTimer = DAMAGE_IDLE_DESPAWN_SECONDS
                end
            elseif DESPAWN_IDS[e.templateId] then
                if e.idleTimer then
                    e.idleTimer = e.idleTimer - dt
                    if e.idleTimer <= 0 and not e.inCombat then
                        toRemove[id] = true
                    end
                else
                    e.idleTimer = DAMAGE_IDLE_DESPAWN_SECONDS
                end
            end

            -- 尸体倒计时
            if e.dead then
                if not e.corpseTimer or e.corpseTimer <= 0 then
                    e.corpseTimer = CORPSE_DECAY_SECONDS
                end
                e.corpseTimer = e.corpseTimer - dt
                if e.corpseTimer <= 0 then
                    toRemove[id] = true
                end
            end
        end
    end

    return toRemove
end

--- 记录 mob 受击时重置闲置计时器
function M.resetIdleTimer(e)
    if e then e.idleTimer = DAMAGE_IDLE_DESPAWN_SECONDS end
end

return M
