-- World of ClaudeCraft — DB Service: Auth Token CRUD

local M = {}

function M.register(dbMod)
    local q = dbMod.query
    local qOne = dbMod.queryOne

    dbMod:register("saveToken", function(token, accountId, ttlHours, scope, label)
        ttlHours = ttlHours or (24 * 7)
        scope = scope or "full"
        q("INSERT INTO auth_tokens (token, account_id, expires_at, scope) VALUES (%s, %s, now() + make_interval(hours => %s), %s)",
          token, accountId, ttlHours, scope)
        return true
    end)

    dbMod:register("deleteToken", function(token)
        q("DELETE FROM auth_tokens WHERE token=%s", token)
        return true
    end)

    dbMod:register("accountAndScopeForToken", function(token)
        local row = qOne("SELECT account_id, scope FROM auth_tokens WHERE token=%s AND expires_at > now()", token)
        if not row then return nil end
        if row.scope ~= "full" and row.scope ~= "read" then return nil end
        return row
    end)

    dbMod:register("findAccountByToken", function(token)
        local auth = qOne("SELECT account_id, scope FROM auth_tokens WHERE token=%s AND expires_at > now()", token)
        if not auth then return nil end
        if auth.scope ~= "full" and auth.scope ~= "read" then return nil end
        return qOne("SELECT id, username, password_hash, email FROM accounts WHERE id=%s", auth.account_id)
    end)
end

return M
