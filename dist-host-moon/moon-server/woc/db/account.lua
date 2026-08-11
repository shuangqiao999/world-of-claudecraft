-- World of ClaudeCraft — DB Service: Account + Auth Token CRUD

local M = {}

function M.register(dbMod)
    local q = dbMod.query
    local qOne = dbMod.queryOne

    dbMod:register("findAccount", function(username)
        return qOne("SELECT id, username, password_hash, email, totp_secret, totp_enabled_at, is_admin, banned_at, suspended_until, chat_muted_until, chat_strikes, deactivated_at FROM accounts WHERE username=%s", username)
    end)

    dbMod:register("createAccount", function(username, passwordHash)
        return qOne("INSERT INTO accounts (username, password_hash) VALUES (%s, %s) RETURNING id, username", username, passwordHash)
    end)

    dbMod:register("accountAndScopeForToken", function(token)
        local row = qOne("SELECT account_id, scope FROM auth_tokens WHERE token=%s AND expires_at > now()", token)
        if not row then return nil end
        if row.scope ~= "full" and row.scope ~= "read" then return nil end
        return row
    end)

    dbMod:register("saveToken", function(token, accountId, ttlHours, scope)
        q("INSERT INTO auth_tokens (token, account_id, expires_at, scope) VALUES (%s, %s, now() + interval '%s hours', %s)",
          token, accountId, tostring(ttlHours or 168), scope or "full")
        return true
    end)

    dbMod:register("deleteToken", function(token)
        q("DELETE FROM auth_tokens WHERE token=%s", token)
        return true
    end)

    dbMod:register("getModerationStatus", function(accountId)
        local row = qOne("SELECT banned_at, suspended_until, chat_muted_until, chat_strikes, deactivated_at FROM accounts WHERE id=%s", accountId)
        if not row then return { locked = false, banned = false, suspendedUntil = nil, reason = "", message = "", chatMutedUntil = nil, chatStrikes = 0 } end
        local r = { banned = row.banned_at ~= nil, suspendedUntil = row.suspended_until, chatMutedUntil = row.chat_muted_until, chatStrikes = row.chat_strikes or 0, deactivated = row.deactivated_at ~= nil, locked = false, reason = "", message = "" }
        if r.banned then r.locked = true; r.message = "Banned" end
        if r.suspendedUntil then r.locked = true; r.message = "Suspended" end
        if r.deactivated then r.locked = true; r.message = "Deactivated" end
        return r
    end)

    dbMod:register("touchLogin", function(accountId, ip)
        q("UPDATE accounts SET last_login = now(), last_login_ip = %s WHERE id=%s", ip or "", accountId)
        return true
    end)

    dbMod:register("setAccountEmail", function(accountId, email)
        q("UPDATE accounts SET email = %s WHERE id=%s", email, accountId)
        return true
    end)

    dbMod:register("updatePasswordHash", function(accountId, newHash)
        q("UPDATE accounts SET password_hash = %s WHERE id=%s", newHash, accountId)
        return true
    end)
end

return M
