-- World of ClaudeCraft — Unstuck Recovery System
-- /unstuck: 解除卡死, 墓地传送/复活, 冷却
-- 对应原项目 src/sim/unstuck.ts

local M = {}

local UNSTUCK_COOLDOWN_SECONDS = 60
local UNSTUCK_COUNTDOWN_SECONDS = 5

-- 玩家解除卡死状态: { pid = { cooldown, countdown, cancelling } }
local unstuckState = {}

--- 开始解除卡死
function M.startUnstuck(pid, entities)
    local player = entities[pid]
    if not player then return false, "Not found" end

    local state = unstuckState[pid]
    if state and state.cooldown > 0 then
        return false, "Unstuck on cooldown (" .. math.floor(state.cooldown) .. "s)"
    end

    unstuckState[pid] = {
        cooldown = 0,
        countdown = UNSTUCK_COUNTDOWN_SECONDS,
        cancelling = false,
    }

    return true
end

--- 取消解除卡死
function M.cancelUnstuck(pid)
    local state = unstuckState[pid]
    if state then
        state.cancelling = true
    end
end

--- 更新解除卡死 (每个 tick)
function M.update(dt, entities)
    local events = {}

    for pid, state in pairs(unstuckState) do
        if state.cancelling then
            unstuckState[pid] = nil
            goto continue
        end

        -- 倒计时
        state.countdown = state.countdown - dt
        if state.countdown <= 0 then
            -- 解除卡死执行
            local player = entities[pid]
            if player then
                if player.dead then
                    -- 死亡: 墓地复活
                    player.pos.x = 0
                    player.pos.z = 0
                    player.dead = false
                    player.ghost = false
                    player.hp = math.max(1, math.floor(player.maxHp * 0.5 + 0.5))
                    table.insert(events, {
                        type = "unstuck_revived",
                        pid = pid,
                    })
                else
                    -- 活着: 墓地传送
                    player.pos.x = 0
                    player.pos.z = 0
                    table.insert(events, {
                        type = "unstuck_teleported",
                        pid = pid,
                    })
                end
            end
            state.cooldown = UNSTUCK_COOLDOWN_SECONDS
        end

        -- 冷却更新 (在倒计时结束后)
        if state.cooldown > 0 then
            state.cooldown = state.cooldown - dt
            if state.cooldown <= 0 then
                unstuckState[pid] = nil
            end
        end

        ::continue::
    end

    return events
end

return M
