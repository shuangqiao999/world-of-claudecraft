-- World of ClaudeCraft — DB Service: Social CRUD
-- 好友 / 黑名单 / 忽略 / 公会 (PostgreSQL 持久化)

local M = {}

function M.register(dbMod)
    local q = dbMod.query
    local qOne = dbMod.queryOne

    -- 角色基础信息 (按 character id)
    dbMod:register("getCharacterById", function(characterId)
        return qOne("SELECT id, account_id, name, class, level, realm FROM characters WHERE id=%s", characterId)
    end)

    -- ===== 好友 =====
    dbMod:register("getFriendship", function(charId, friendId)
        return qOne("SELECT 1 FROM friendships WHERE character_id=%s AND friend_id=%s", charId, friendId)
    end)
    dbMod:register("createFriendship", function(charId, friendId)
        q("INSERT INTO friendships (character_id, friend_id) VALUES (%s, %s) ON CONFLICT DO NOTHING", charId, friendId)
        return true
    end)
    dbMod:register("deleteFriendship", function(charId, friendId)
        q("DELETE FROM friendships WHERE character_id=%s AND friend_id=%s", charId, friendId)
        return true
    end)
    dbMod:register("getFriendships", function(characterId)
        local res = q("SELECT f.friend_id, c.name, c.class, c.level FROM friendships f JOIN characters c ON f.friend_id = c.id WHERE f.character_id=%s ORDER BY c.name", characterId)
        if res.code then return {} end
        return res.data or {}
    end)

    -- ===== 黑名单 =====
    dbMod:register("createBlock", function(charId, blockedId)
        q("INSERT INTO blocks (character_id, blocked_id) VALUES (%s, %s) ON CONFLICT DO NOTHING", charId, blockedId)
        return true
    end)
    dbMod:register("deleteBlock", function(charId, blockedId)
        q("DELETE FROM blocks WHERE character_id=%s AND blocked_id=%s", charId, blockedId)
        return true
    end)
    dbMod:register("getBlocks", function(characterId)
        local res = q("SELECT b.blocked_id, c.name FROM blocks b JOIN characters c ON b.blocked_id = c.id WHERE b.character_id=%s ORDER BY c.name", characterId)
        if res.code then return {} end
        return res.data or {}
    end)

    -- ===== 忽略 =====
    dbMod:register("createIgnore", function(charId, ignoredId)
        q("INSERT INTO ignores (character_id, ignored_id) VALUES (%s, %s) ON CONFLICT DO NOTHING", charId, ignoredId)
        return true
    end)
    dbMod:register("deleteIgnore", function(charId, ignoredId)
        q("DELETE FROM ignores WHERE character_id=%s AND ignored_id=%s", charId, ignoredId)
        return true
    end)
    dbMod:register("getIgnores", function(characterId)
        local res = q("SELECT i.ignored_id, c.name FROM ignores i JOIN characters c ON i.ignored_id = c.id WHERE i.character_id=%s ORDER BY c.name", characterId)
        if res.code then return {} end
        return res.data or {}
    end)

    -- ===== 公会 =====
    dbMod:register("getGuildByName", function(name)
        return qOne("SELECT id, name, realm, created_at FROM guilds WHERE name=%s", name)
    end)
    dbMod:register("getGuildByCharacter", function(characterId)
        return qOne(
            "SELECT g.id, g.name, g.realm, g.created_at, gm.rank FROM guild_members gm JOIN guilds g ON gm.guild_id = g.id WHERE gm.character_id=%s",
            characterId)
    end)
    dbMod:register("createGuild", function(name, realm, leaderId)
        -- 事务: 建会 + 入会原子化
        local g, err = dbMod.withTransaction(function(tx)
            local g0, gErr = tx.queryOne("INSERT INTO guilds (name, realm) VALUES (%s, %s) RETURNING id, name, realm, created_at", name, realm)
            if not g0 then return nil, gErr or "guild_insert_failed" end
            local mErr = tx.query("INSERT INTO guild_members (guild_id, character_id, rank) VALUES (%s, %s, 0)", g0.id, leaderId)
            if mErr and mErr.code then return nil, tostring(mErr.message) end
            return g0
        end)
        return g, err
    end)
    dbMod:register("addGuildMember", function(guildId, characterId, rank)
        q("INSERT INTO guild_members (guild_id, character_id, rank) VALUES (%s, %s, %s) ON CONFLICT DO NOTHING", guildId, characterId, rank or 2)
        return true
    end)
    dbMod:register("removeGuildMember", function(characterId)
        q("DELETE FROM guild_members WHERE character_id=%s", characterId)
        return true
    end)
    dbMod:register("setGuildRank", function(guildId, characterId, rank)
        q("UPDATE guild_members SET rank=%s WHERE guild_id=%s AND character_id=%s", rank, guildId, characterId)
        return true
    end)
    dbMod:register("getGuildMembers", function(guildId)
        local res = q(
            "SELECT gm.character_id, gm.rank, gm.joined_at, c.name, c.class, c.level FROM guild_members gm JOIN characters c ON gm.character_id = c.id WHERE gm.guild_id=%s ORDER BY gm.rank ASC, gm.joined_at ASC",
            guildId)
        if res.code then return {} end
        return res.data or {}
    end)
    dbMod:register("deleteGuild", function(guildId)
        dbMod.withTransaction(function(tx)
            tx.query("DELETE FROM guild_members WHERE guild_id=%s", guildId)
            tx.query("DELETE FROM guilds WHERE id=%s", guildId)
        end)
        return true
    end)
    dbMod:register("setGuildMotd", function(guildId, motd)
        q("UPDATE guilds SET motd=%s WHERE id=%s", motd or "", guildId)
        return true
    end)
    dbMod:register("getGuildMotd", function(guildId)
        local row = qOne("SELECT motd FROM guilds WHERE id=%s", guildId)
        return row and row.motd or ""
    end)
end

return M
