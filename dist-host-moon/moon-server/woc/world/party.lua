-- World of ClaudeCraft — Party System
-- pinvite, paccept, pleave, pkick, ppromote, praid

local M = {}

-- 组队数据: partyId → { leader, members = {pid = name}, invitees = {pid = inviter} }
local parties = {}
-- 玩家所在队伍: pid → partyId
local playerParty = {}

--- 邀请玩家入队
function M.invite(inviterPid, targetPid, entities)
    local inviter = entities[inviterPid]
    local target = entities[targetPid]
    if not inviter or not target then return false, "Player not found" end
    if target.kind ~= "player" then return false, "Not a player" end

    -- 创建或获取队伍
    local partyId = playerParty[inviterPid]
    if not partyId then
        partyId = "party_" .. tostring(inviterPid)
        parties[partyId] = { leader = inviterPid, members = { [inviterPid] = true }, invitees = {} }
        playerParty[inviterPid] = partyId
    end

    if parties[partyId].members[targetPid] then
        return false, "Already in party"
    end

    parties[partyId].invitees[targetPid] = inviterPid
    return true, "Invited"
end

--- 接受邀请
function M.accept(targetPid)
    for partyId, party in pairs(parties) do
        if party.invitees[targetPid] then
            party.members[targetPid] = true
            party.invitees[targetPid] = nil
            if #M.getMembers(partyId) > 5 and not party.isRaid then
                -- 转团队
                party.isRaid = true
            end
            return true, partyId
        end
    end
    return false, "No pending invite"
end

--- 离开队伍
function M.leave(pid)
    local partyId = playerParty[pid]
    if not partyId then return false end

    local party = parties[partyId]
    party.members[pid] = nil
    playerParty[pid] = nil

    if next(party.members) == nil then
        parties[partyId] = nil
    end
    return true
end

--- 踢出成员
function M.kick(leaderPid, targetPid)
    local partyId = playerParty[leaderPid]
    if not partyId then return false end
    local party = parties[partyId]
    if party.leader ~= leaderPid then return false end
    party.members[targetPid] = nil
    playerParty[targetPid] = nil
    return true
end

--- 获取队伍成员列表
function M.getMembers(pid)
    local partyId = playerParty[pid]
    if not partyId then return { pid } end
    local list = {}
    for mid, _ in pairs(parties[partyId].members) do
        table.insert(list, mid)
    end
    return list
end

--- 获取队伍ID
function M.getPartyId(pid)
    return playerParty[pid]
end

return M
