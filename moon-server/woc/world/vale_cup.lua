-- World of ClaudeCraft — Vale Cup Arena
-- 4v4 competitive queue with bets and practice mode
local M = {}
local queue = {}
local matches = {}
local bets = {}      -- { pid, amount, vcp }
local matchCounter = 0

function M.queuePlayer(pid)
    if not queue[pid] then queue[pid] = os.time() end
end

function M.leaveQueue(pid)
    queue[pid] = nil
end

function M.setRole(pid, role)
    queue[pid] = (queue[pid] and { joined = queue[pid], role = role }) or nil
end

function M.setReady(pid)
    for _, m in pairs(matches) do
        for _, mid in ipairs(m.players or {}) do
            if mid == pid then
                m.readyResponses = (m.readyResponses or {})
                m.readyResponses[pid] = true
                return true
            end
        end
    end
    return false
end

function M.placeBet(pid, amount, targetTeam)
    bets[pid] = { amount = amount, target = targetTeam or "teamA", placedAt = os.time() }
    return true
end

function M.joinPractice(pid)
    matchCounter = matchCounter + 1
    matches[matchCounter] = { matchId = matchCounter, players = { pid }, practice = true }
    return matchCounter
end

return M
