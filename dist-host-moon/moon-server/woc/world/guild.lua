-- World of ClaudeCraft — Guild System
-- guild_create, guild_invite, guild_accept, guild_leave, guild_kick, guild_promote

local M = {}

local guilds = {}     -- guildName → { name, realm, leader, members, bank }
local playerGuild = {} -- pid → guildName

--- 创建工会
function M.create(playerPid, guildName, playerName, realm)
    if guilds[guildName] then return false, "Guild name taken" end
    guilds[guildName] = {
        name = guildName, realm = realm or "Claudemoon",
        leader = playerPid,
        members = { [playerPid] = { name = playerName, rank = 0 } },  -- 0=leader
        bank = { copper = 0, items = {} },
        createdAt = os.time(),
    }
    playerGuild[playerPid] = guildName
    return true, guildName
end

--- 邀请
function M.invite(inviterPid, targetPid)
    local gname = playerGuild[inviterPid]
    if not gname then return false, "Not in a guild" end
    if playerGuild[targetPid] then return false, "Already in a guild" end
    return true, gname
end

--- 接受邀请
function M.accept(targetPid, guildName, targetName)
    if not guilds[guildName] then return false, "Guild not found" end
    guilds[guildName].members[targetPid] = { name = targetName, rank = 1 }  -- 1=member
    playerGuild[targetPid] = guildName
    return true
end

--- 离开
function M.leave(pid)
    local gname = playerGuild[pid]
    if not gname then return false end
    local g = guilds[gname]
    g.members[pid] = nil
    playerGuild[pid] = nil
    if g.leader == pid then
        -- 传位给第一个成员
        local nextLeader = next(g.members)
        if nextLeader then g.leader = nextLeader; g.members[nextLeader].rank = 0
        else guilds[gname] = nil end
    end
    return true
end

--- 踢人
function M.kick(leaderPid, targetPid)
    local gname = playerGuild[leaderPid]
    if not gname then return false end
    local g = guilds[gname]
    if g.leader ~= leaderPid then return false end
    g.members[targetPid] = nil
    playerGuild[targetPid] = nil
    return true
end

--- 晋升
function M.promote(leaderPid, targetPid)
    local gname = playerGuild[leaderPid]
    if not gname then return false end
    local g = guilds[gname]
    if g.leader ~= leaderPid then return false end
    if not g.members[targetPid] then return false end
    g.members[targetPid].rank = math.max(0, g.members[targetPid].rank - 1)
    return true
end

--- 降级
function M.demote(leaderPid, targetPid)
    local gname = playerGuild[leaderPid]
    if not gname then return false end
    local g = guilds[gname]
    if g.leader ~= leaderPid then return false end
    if not g.members[targetPid] then return false end
    g.members[targetPid].rank = g.members[targetPid].rank + 1
    return true
end

--- 获取工会名
function M.getGuild(pid)
    local gname = playerGuild[pid]
    if gname then return guilds[gname] end
    return nil
end

return M
