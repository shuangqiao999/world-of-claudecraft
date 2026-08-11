-- World of ClaudeCraft — Social Service
-- 好友 / 黑名单 / 忽略 / 公会 (业务层, 经 DB Service 持久化)
-- 角色标识统一为 character_id (DB 行 id); world 转发时由 pid 解析

local moon = require("moon")

local M = {}

-- 公会 rank: 0=会长 1=官员 2=成员
local RANK = { LEADER = 0, OFFICER = 1, MEMBER = 2 }

-- 待处理公会邀请: pendingInvites[charId] = { guildId, guildName, fromName, fromCharId }
local pendingInvites = {}

--- 调用 DB Service (每次查询 service, 防服务重启后引用失效)
local function dbCall(op, ...)
    local dbSvc = moon.queryservice("db")
    if not dbSvc then return nil, "db unavailable" end
    local resp = moon.call("lua", dbSvc, { op = op, args = { ... } })
    if resp and resp.ok then return resp.data, nil end
    return nil, (resp and resp.error) or "db error"
end

-- ===== 好友 =====
function M.addFriend(charId, friendId)
    if not charId or not friendId then return false, "Missing character id" end
    if charId == friendId then return false, "Cannot add yourself" end
    local target = dbCall("getCharacterById", friendId)
    if not target then return false, "Character not found" end
    if dbCall("getFriendship", charId, friendId) then return false, "Already friends" end
    local _, err = dbCall("createFriendship", charId, friendId)
    if err then return false, err end
    return true, "Friend added"
end

function M.removeFriend(charId, friendId)
    if not dbCall("getFriendship", charId, friendId) then return false, "Not friends" end
    local _, err = dbCall("deleteFriendship", charId, friendId)
    if err then return false, err end
    return true, "Friend removed"
end

function M.listFriends(charId)
    local data, err = dbCall("getFriendships", charId)
    if err then return {} end
    return data or {}
end

-- ===== 黑名单 =====
function M.blockPlayer(charId, blockedId)
    if charId == blockedId then return false, "Cannot block yourself" end
    local target = dbCall("getCharacterById", blockedId)
    if not target then return false, "Character not found" end
    local _, err = dbCall("createBlock", charId, blockedId)
    if err then return false, err end
    return true, "Player blocked"
end

function M.unblockPlayer(charId, blockedId)
    local _, err = dbCall("deleteBlock", charId, blockedId)
    if err then return false, err end
    return true, "Player unblocked"
end

function M.listBlocks(charId)
    local data, err = dbCall("getBlocks", charId)
    if err then return {} end
    return data or {}
end

-- ===== 忽略 =====
function M.ignorePlayer(charId, ignoredId)
    if charId == ignoredId then return false, "Cannot ignore yourself" end
    local _, err = dbCall("createIgnore", charId, ignoredId)
    if err then return false, err end
    return true, "Player ignored"
end

function M.unignorePlayer(charId, ignoredId)
    local _, err = dbCall("deleteIgnore", charId, ignoredId)
    if err then return false, err end
    return true, "Player unignored"
end

function M.listIgnores(charId)
    local data, err = dbCall("getIgnores", charId)
    if err then return {} end
    return data or {}
end

-- ===== 公会 =====
function M.createGuild(charId, name)
    if not name or type(name) ~= "string" or #name < 2 or #name > 24 then
        return false, "Invalid guild name"
    end
    if dbCall("getGuildByCharacter", charId) then return false, "Already in a guild" end
    if dbCall("getGuildByName", name) then return false, "Guild name taken" end
    local realm = require("config").getRealm()
    local guild, err = dbCall("createGuild", name, realm, charId)
    if err then return false, err end
    return true, guild and guild.id
end

-- 权限: rank <= 1 可管理 (会长/官员)
function M._requireOfficer(charId)
    local guild = dbCall("getGuildByCharacter", charId)
    if not guild then return nil, "You are not in a guild" end
    if (guild.rank or RANK.MEMBER) > RANK.OFFICER then return nil, "Insufficient permissions" end
    return guild, nil
end

function M.inviteToGuild(charId, targetId)
    local guild, err = M._requireOfficer(charId)
    if not guild then return false, err end
    if not dbCall("getCharacterById", targetId) then return false, "Character not found" end
    if dbCall("getGuildByCharacter", targetId) then return false, "Target already in a guild" end
    -- 创建待处理邀请 (TS: pendingGuildInvites 队列, 目标接受/拒绝后生效)
    local from = dbCall("getCharacterById", charId)
    pendingInvites[targetId] = {
        guildId = guild.id,
        guildName = guild.name,
        fromName = from and from.name or "someone",
        fromCharId = charId,
    }
    return true, guild.name
end

function M.acceptGuildInvite(charId)
    local invite = pendingInvites[charId]
    if not invite then return false, "No pending guild invite" end
    if dbCall("getGuildByCharacter", charId) then
        pendingInvites[charId] = nil
        return false, "Already in a guild"
    end
    local _, err = dbCall("addGuildMember", invite.guildId, charId, RANK.MEMBER)
    if err then return false, err end
    pendingInvites[charId] = nil
    return true, invite.guildName
end

function M.declineGuildInvite(charId)
    if not pendingInvites[charId] then return false, "No pending guild invite" end
    pendingInvites[charId] = nil
    return true, "Invite declined"
end

function M.disbandGuild(charId)
    local guild, err = M._requireOfficer(charId)
    if not guild then return false, err end
    if (guild.rank or RANK.MEMBER) ~= RANK.LEADER then return false, "Only the guild master can disband" end
    -- 删除所有成员 + 公会 (TS guildDisband)
    local members = dbCall("getGuildMembers", guild.id) or {}
    for _, m in ipairs(members) do
        dbCall("removeGuildMember", m.character_id)
        pendingInvites[m.character_id] = nil
    end
    dbCall("deleteGuild", guild.id)
    return true, "Guild disbanded"
end

function M.kickFromGuild(charId, targetId)
    local guild, err = M._requireOfficer(charId)
    if not guild then return false, err end
    local targetGuild = dbCall("getGuildByCharacter", targetId)
    if not targetGuild or targetGuild.id ~= guild.id then return false, "Target not in your guild" end
    if (targetGuild.rank or RANK.MEMBER) == RANK.LEADER then return false, "Cannot kick the guild leader" end
    local _, err2 = dbCall("removeGuildMember", targetId)
    if err2 then return false, err2 end
    return true, "Player kicked"
end

function M.leaveGuild(charId)
    local guild = dbCall("getGuildByCharacter", charId)
    if not guild then return false, "You are not in a guild" end
    if (guild.rank or RANK.MEMBER) == RANK.LEADER then
        return false, "Guild leader must transfer ownership first"
    end
    local _, err = dbCall("removeGuildMember", charId)
    if err then return false, err end
    return true, "Left guild"
end

function M.promote(charId, targetId)
    local guild, err = M._requireOfficer(charId)
    if not guild then return false, err end
    local targetGuild = dbCall("getGuildByCharacter", targetId)
    if not targetGuild or targetGuild.id ~= guild.id then return false, "Target not in your guild" end
    local newRank = math.max(RANK.OFFICER, (targetGuild.rank or RANK.MEMBER) - 1)
    local _, err2 = dbCall("setGuildRank", guild.id, targetId, newRank)
    if err2 then return false, err2 end
    return true, "Rank updated"
end

function M.getGuildInfo(charId)
    local guild = dbCall("getGuildByCharacter", charId)
    if not guild then return nil, "Not in a guild" end
    local members, err = dbCall("getGuildMembers", guild.id)
    if err then return nil, err end
    return {
        id = guild.id,
        name = guild.name,
        realm = guild.realm,
        createdAt = guild.created_at,
        rank = guild.rank,
        members = members or {},
    }, nil
end

-- ===== 消息分发 =====
moon.dispatch("lua", function(sender, session, msg)
    if type(msg) ~= "table" then return end
    local op = msg.op
    local charId = msg.charId
    local resp

    if op == "friend_add" then
        local ok, data = M.addFriend(charId, msg.targetId)
        resp = ok and { ok = true, data = data } or { ok = false, error = data }
    elseif op == "friend_remove" then
        local ok, data = M.removeFriend(charId, msg.targetId)
        resp = ok and { ok = true, data = data } or { ok = false, error = data }
    elseif op == "friend_list" then
        resp = { ok = true, data = M.listFriends(charId) }

    elseif op == "block_add" then
        local ok, data = M.blockPlayer(charId, msg.targetId)
        resp = ok and { ok = true, data = data } or { ok = false, error = data }
    elseif op == "block_remove" then
        local ok, data = M.unblockPlayer(charId, msg.targetId)
        resp = ok and { ok = true, data = data } or { ok = false, error = data }
    elseif op == "block_list" then
        resp = { ok = true, data = M.listBlocks(charId) }

    elseif op == "ignore_add" then
        local ok, data = M.ignorePlayer(charId, msg.targetId)
        resp = ok and { ok = true, data = data } or { ok = false, error = data }
    elseif op == "ignore_remove" then
        local ok, data = M.unignorePlayer(charId, msg.targetId)
        resp = ok and { ok = true, data = data } or { ok = false, error = data }
    elseif op == "ignore_list" then
        resp = { ok = true, data = M.listIgnores(charId) }

    elseif op == "guild_create" then
        local ok, data = M.createGuild(charId, msg.name)
        resp = ok and { ok = true, data = data } or { ok = false, error = data }
    elseif op == "guild_invite" then
        local ok, data = M.inviteToGuild(charId, msg.targetId)
        resp = ok and { ok = true, data = data } or { ok = false, error = data }
    elseif op == "guild_accept" then
        local ok, data = M.acceptGuildInvite(charId)
        resp = ok and { ok = true, data = data } or { ok = false, error = data }
    elseif op == "guild_decline" then
        local ok, data = M.declineGuildInvite(charId)
        resp = ok and { ok = true, data = data } or { ok = false, error = data }
    elseif op == "guild_disband" then
        local ok, data = M.disbandGuild(charId)
        resp = ok and { ok = true, data = data } or { ok = false, error = data }
    elseif op == "guild_kick" then
        local ok, data = M.kickFromGuild(charId, msg.targetId)
        resp = ok and { ok = true, data = data } or { ok = false, error = data }
    elseif op == "guild_leave" then
        local ok, data = M.leaveGuild(charId)
        resp = ok and { ok = true, data = data } or { ok = false, error = data }
    elseif op == "guild_promote" then
        local ok, data = M.promote(charId, msg.targetId)
        resp = ok and { ok = true, data = data } or { ok = false, error = data }
    elseif op == "guild_info" then
        local data, err = M.getGuildInfo(charId)
        resp = data and { ok = true, data = data } or { ok = false, error = err }
    else
        resp = { ok = false, error = "Unknown social op: " .. tostring(op) }
    end

    moon.response("lua", sender, session, resp)
end)

print("[Social] Service ready")
