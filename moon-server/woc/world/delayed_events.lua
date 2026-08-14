-- World of ClaudeCraft — Delayed Events System
-- 对应原项目 src/sim/sim.ts drainDelayedEvents (scheduleDelayedEvent/drainDelayedEvents)
-- 定时延迟事件队列, 在 tick 尾部清空

local config = require("config")
local M = {}

-- delayedEvents: { at, event, guard }
local delayedEvents = {}

--- 调度延迟事件
function M.schedule(at, event, guard)
    table.insert(delayedEvents, { at = at, event = event, guard = guard })
end

--- Tick: 清理到期的延迟事件
function M.drain(simTime)
    local due = {}
    local remaining = {}

    for _, de in ipairs(delayedEvents) do
        if simTime >= de.at then
            if de.guard then
                local ok, passes = pcall(de.guard)
                if ok and passes then
                    table.insert(due, de.event)
                end
            else
                table.insert(due, de.event)
            end
        else
            table.insert(remaining, de)
        end
    end

    delayedEvents = remaining
    return due
end

function M.getPendingCount()
    return #delayedEvents
end

return M
