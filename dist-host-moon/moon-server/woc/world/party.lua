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

--- 拒绝邀请 (TS partyDecline)
function M.decline(targetPid)
    for partyId, party in pairs(parties) do
        if party.invitees[targetPid] then
            party.invitees[targetPid] = nil
            return true, "Invite declined"
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

--- 移动团队成员到指定组 (TS moveRaidMember, group 1|2)
function M.moveRaidMember(leaderPid, targetPid, group)
    local partyId = playerParty[leaderPid]
    if not partyId then return false, "Not in a party" end
    local party = parties[partyId]
    if party.leader ~= leaderPid then return false, "Leader only" end
    if not party.isRaid then return false, "Not a raid" end
    if not party.members[targetPid] then return false, "Not in raid" end
    if group ~= 1 and group ~= 2 then return false, "Invalid group" end
    party.groups = party.groups or { [1] = {}, [2] = {} }
    for g, pids in pairs(party.groups) do
        if pids[targetPid] then pids[targetPid] = nil end
    end
    party.groups[group][targetPid] = true
    return true, "Moved to group " .. group
end

--- 设置队伍/团队拾取模式 (TS setPartyLootMaster, threshold: uncommon|rare|epic)
function M.setLootMaster(leaderPid, enabled, looter, threshold)
    local partyId = playerParty[leaderPid]
    if not partyId then return false, "Not in a party" end
    local party = parties[partyId]
    if party.leader ~= leaderPid then return false, "Leader only" end
    party.lootMaster = { enabled = enabled == true, looter = looter, threshold = threshold or "rare" }
    return true, "Loot master set"
end

--- 团长分配战利品 (TS assignMasterLoot: 1 pid 直接授予, 2+ 开 roll)
function M.assignMasterLoot(leaderPid, rollId, pids)
    local partyId = playerParty[leaderPid]
    if not partyId then return false, "Not in a party" end
    local party = parties[partyId]
    if party.leader ~= leaderPid then return false, "Leader only" end
    if not pids or #pids == 0 then return false, "No targets" end
    local lootRoll = require("world.loot_roll")
    if #pids == 1 then
        -- 直接授予
        local roll = lootRoll.getRoll(rollId)
        if roll then
            lootRoll.resolveWinner(roll, pids[1])
            return true, "Granted"
        end
        return false, "Roll not found"
    else
        -- 多人开 roll
        local roll = lootRoll.getRoll(rollId)
        if roll then
            roll.eligiblePlayers = pids
            return true, "Roll opened"
        end
        return false, "Roll not found"
    end
end

--- 获取队伍ID
function M.getPartyId(pid)
    return playerParty[pid]
end

return M
