-- World of ClaudeCraft — Ready Check System
-- /ready 命令: 团队就位检查
-- 对应原项目 src/sim/social/ready_check.ts

local M = {}

local READY_CHECK_TIMEOUT = 30

-- 活跃的就位检查: { checkId, leaderPid, responses = {pid=true/false}, expiry }
local activeChecks = {}

--- 发起就位检查
function M.startReadyCheck(leaderPid, memberPids)
    local checkId = "rc_" .. tostring(os.time()) .. "_" .. leaderPid
    local responses = {}
    for _, pid in ipairs(memberPids) do
        responses[pid] = nil  -- nil = 未回应
    end
    activeChecks[checkId] = {
        checkId = checkId,
        leaderPid = leaderPid,
        responses = responses,
        expiry = READY_CHECK_TIMEOUT,
        completed = false,
    }
    return checkId
end

--- 回应就位
function M.respond(pid, ready)
    for _, check in pairs(activeChecks) do
        if not check.completed and check.responses[pid] == nil then
            check.responses[pid] = ready
            return true
        end
    end
    return false
end

--- 更新就位检查 (每个 tick)
function M.update(dt)
    local events = {}
    local toRemove = {}

    for checkId, check in pairs(activeChecks) do
        if not check.completed then
            check.expiry = check.expiry - dt

            local allResponded = true
            local readyCount = 0
            local totalCount = 0
            for _, resp in pairs(check.responses) do
                totalCount = totalCount + 1
                if resp == nil then allResponded = false
                elseif resp then readyCount = readyCount + 1 end
            end

            if allResponded or check.expiry <= 0 then
                check.completed = true
                table.insert(events, {
                    type = "ready_check_result",
                    leader = check.leaderPid,
                    readyCount = readyCount,
                    totalCount = totalCount,
                    allReady = readyCount == totalCount,
                })
                toRemove[checkId] = true
            end
        else
            toRemove[checkId] = true
        end
    end

    for checkId, _ in pairs(toRemove) do
        activeChecks[checkId] = nil
    end

    return events
end

return M
