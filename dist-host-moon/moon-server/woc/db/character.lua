-- World of ClaudeCraft — DB Service: Character CRUD + Lease

local config = require("config")

local M = {}
local leaseHolder = nil

function M.getLeaseHolder()
    if not leaseHolder then
        leaseHolder = string.format("%s#%s#%s", config.getRealm(), tostring(math.random(100000, 999999)), tostring(os.time()))
    end
    return leaseHolder
end

function M.register(dbMod)
    local q = dbMod.query
    local qOne = dbMod.queryOne
    local realm = config.getRealm()

    dbMod:register("getCharacter", function(accountId, characterId)
        return qOne("SELECT id, account_id, name, class, level, state, is_gm, force_rename, hotbar_layout FROM characters WHERE id=%s AND account_id=%s AND realm=%s",
            characterId, accountId, realm)
    end)

    dbMod:register("getCharactersByAccount", function(accountId)
        local res = q("SELECT id, name, class, level, created_at, last_login FROM characters WHERE account_id=%s AND realm=%s ORDER BY id", accountId, realm)
        if res.code then return {} end
        return res.data or {}
    end)

    dbMod:register("createCharacter", function(accountId, name, cls)
        -- 全局唯一 + 事务: 预检+插入原子化; 错误经 error() 抛出 (dispatch pcall 捕获)
        local created, txErr = dbMod.withTransaction(function(tx)
            local existing = tx.queryOne("SELECT id FROM characters WHERE name=%s", name)
            if existing then
                error("name_taken")
            end
            local row = tx.queryOne(
                "INSERT INTO characters (account_id, name, class, realm, level, state) VALUES (%s, %s, %s, %s, 1, '{}') RETURNING id, name, class, level",
                accountId, name, cls, realm)
            if not row then error("insert_failed") end
            return row
        end)
        if created then return created end
        -- 唯一约束违规 (SQLSTATE 23505) 兜底 → 明确错误码
        local msg = tostring(txErr or "create_failed")
        if msg:find("unique", 1, true) then error("name_taken") end
        error(msg)
    end)

    dbMod:register("saveCharacterState", function(characterId, level, stateTable, leaseNonce)
        local json = require("json")
        local stateJson = json.encode(stateTable)

        if leaseNonce then
            local holder = M.getLeaseHolder()
            q("UPDATE characters SET level=%s, state=%s::jsonb, updated_at=now() WHERE id=%s AND EXISTS (SELECT 1 FROM character_leases WHERE character_id=%s AND holder=%s AND nonce=%s)",
                level, stateJson, characterId, characterId, holder, leaseNonce)
        else
            q("UPDATE characters SET level=%s, state=%s::jsonb, updated_at=now() WHERE id=%s",
                level, stateJson, characterId)
        end
        return true
    end)

    dbMod:register("acquireLease", function(characterId, accountId, nonce)
        local holder = M.getLeaseHolder()
        local ttl = config.LEASE_TTL_SECONDS
        q("INSERT INTO character_leases (character_id, realm, holder, nonce, account_id, acquired_at, heartbeat_at, expires_at) VALUES (%s, %s, %s, %s, %s, now(), now(), now() + make_interval(secs => %s)) ON CONFLICT (character_id) DO UPDATE SET realm=EXCLUDED.realm, holder=EXCLUDED.holder, nonce=EXCLUDED.nonce, account_id=EXCLUDED.account_id, acquired_at=now(), heartbeat_at=now(), expires_at=EXCLUDED.expires_at WHERE character_leases.expires_at < now() OR character_leases.holder=EXCLUDED.holder OR character_leases.account_id=EXCLUDED.account_id",
            characterId, realm, holder, nonce, accountId, ttl)
        return true
    end)

    dbMod:register("releaseLease", function(characterId, nonce)
        local holder = M.getLeaseHolder()
        if nonce then
            q("DELETE FROM character_leases WHERE character_id=%s AND holder=%s AND nonce=%s", characterId, holder, nonce)
        else
            q("DELETE FROM character_leases WHERE character_id=%s AND holder=%s", characterId, holder)
        end
        return true
    end)

    dbMod:register("heartbeatLeases", function()
        q("UPDATE character_leases SET heartbeat_at=now() WHERE holder=%s", M.getLeaseHolder())
        return true
    end)
end

return M
