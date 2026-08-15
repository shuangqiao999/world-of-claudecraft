-- World of ClaudeCraft — DB Service
-- PostgreSQL 数据库访问层: 连接池 + 心跳重连 + 注入安全 SQL 构建

local moon = require("moon")
local pg = require("moon.db.pg")
local json = require("json")
local config = require("config")
local sql = require("shared.sql")

local M = {}

-- 连接池
local POOL_SIZE = config.getDbPoolSize() or 8  -- 连接池大小 (env DB_POOL_SIZE 覆盖, 异步查询并发度)
local BUSY_TIMEOUT_MS = 30000    -- busy 超时: 30s 后强制释放
local pool = {}                  -- { {conn, healthy, busy, busySince}, ... }
local poolCursor = 1
local connecting = false         -- 防止并发重连
local poolReady = false

--- 参数化 SQL 查询: %s/%d/%f → $1/$2/... 走 C 层 json.pq_query 编码 (真参数化, 无注入)
function M.query(fmt, ...)
    if not poolReady then return { code = -1, message = "Not connected" } end
    local paramSql, params = sql.toParams(fmt, ...)
    local hasParams = #params > 0

    -- 从池中取健康空闲连接; 全忙则让出协程短暂重试 (异步连接池, 最多等 ~400ms)
    for wait = 1, 200 do
        for attempt = 1, POOL_SIZE do
            local entry = pool[poolCursor]
            poolCursor = poolCursor % POOL_SIZE + 1
            if entry.healthy then
                -- 超时回收: busy 超过 30s → 强制重置
                if entry.busy and entry.busySince then
                    local elapsed = (os.time() * 1000) - entry.busySince
                    if elapsed > BUSY_TIMEOUT_MS then
                        entry.busy = false; entry.busySince = nil
                        entry.healthy = false
                    end
                end
                if not entry.busy then
                    entry.busy = true
                    entry.busySince = os.time() * 1000
                    local res
                    if hasParams then
                        res = entry.conn:query_params(paramSql, table.unpack(params))
                    else
                        res = entry.conn:query(paramSql)
                    end
                    entry.busy = false; entry.busySince = nil
                    if res.code == "SOCKET" or res.code == "CONNECTION" or res.code == "CONNECTION_NOT_OPEN" then
                        entry.healthy = false
                        M._scheduleReconnect()
                    else
                        return res
                    end
                end
            end
        end
        moon.sleep(2)
    end
    return { code = -1, message = "No healthy connection" }
end

--- 事务: 独占签出池中一个连接, 运行 fn(tx), 成功 COMMIT / 失败 ROLLBACK
--- tx 提供绑定到该连接的 query/queryOne (不经过池轮询)
--- fn 返回 (result, err): result=nil 时回滚语义, err 返回给调用方
--- @return result, err
function M.withTransaction(fn)
    if not poolReady then return nil, "Not connected" end

    -- 找空闲健康连接
    local entry = nil
    for attempt = 1, POOL_SIZE do
        local e = pool[poolCursor]
        poolCursor = poolCursor % POOL_SIZE + 1
        if e.healthy and not e.busy then entry = e; break end
    end
    if not entry then return nil, "No free connection" end
    entry.busy = true

    -- 注意: 不能写成 local tx = { queryOne = function() tx.query() end }
    -- Lua local 在其自身初始化表达式内不可见 → tx 解析为全局 nil.
    local tx = {}
    tx.query = function(fmt, ...)
        local paramSql, params = sql.toParams(fmt, ...)
        local res
        if #params > 0 then
            res = entry.conn:query_params(paramSql, table.unpack(params))
        else
            res = entry.conn:query(paramSql)
        end
        if res.code == "SOCKET" or res.code == "CONNECTION" then
            entry.healthy = false
        end
        return res
    end
    tx.queryOne = function(fmt, ...)
        local res = tx.query(fmt, ...)
        if res.code then return nil end
        local d = res.data
        if d and #d > 0 then return d[1] end
        return nil
    end

    local ok, r1, r2 = pcall(function()
        local b = entry.conn:query("BEGIN")
        if b.code then error("BEGIN failed: " .. tostring(b.message)) end
        local res, resErr = fn(tx)
        local c = entry.conn:query("COMMIT")
        if c.code then error("COMMIT failed: " .. tostring(c.message)) end
        return res, resErr
    end)
    if not ok then
        pcall(function() entry.conn:query("ROLLBACK") end)
        entry.busy = false
        return nil, tostring(r1)
    end
    entry.busy = false
    return r1, r2
end

--- 查询单行
function M.queryOne(sqlText, ...)
    local res = M.query(sqlText, ...)
    if res.code then return nil end
    local data = res.data
    if data and #data > 0 then return data[1] end
    return nil
end

-- 消息分发表
local handlers = {}

--- 注册操作处理器 (CRUD 模块经 dbMod:register(op, fn) 冒号调用)
function M.register(self, op, fn)
    handlers[op] = fn
end

--- 消息处理
moon.dispatch("lua", function(sender, session, msg)
    if type(msg) ~= "table" then
        moon.response("lua", sender, session, { ok = false, error = "Invalid message" })
        return
    end
    local op = msg.op
    local args = msg.args or {}
    local fn = handlers[op]
    if fn then
        local ok, result, err2 = pcall(fn, table.unpack(args))
        if ok then
            if result == nil and err2 ~= nil then
                -- handler 返回 (nil, err) 双值约定 → 透传错误
                moon.response("lua", sender, session, { ok = false, error = tostring(err2) })
            else
                moon.response("lua", sender, session, { ok = true, data = result })
            end
        else
            print(string.format("[DB] Error in '%s': %s", tostring(op), tostring(result)))
            moon.response("lua", sender, session, { ok = false, error = tostring(result) })
        end
    else
        moon.response("lua", sender, session, { ok = false, error = "Unknown op: " .. tostring(op) })
    end
end)

--- 解析 DATABASE_URL
--- 支持: postgresql://user:pass@host:port/db 或 postgres://user:pass@host:port/db
local function parseDatabaseUrl(url)
    url = url or ""
    local user, pass, host, port, database = "postgres", nil, "127.0.0.1", 5432, "woc"

    local rest = string.match(url, "^postgresql://(.+)$")
    if not rest then
        rest = string.match(url, "^postgres://(.+)$")
    end

    if rest then
        local u, p, h, po, d =
            string.match(rest, "^([^:]+):([^@]+)@([^:]+):(%d+)/(.+)$")
        if u then
            user = u; pass = p; host = h; port = tonumber(po); database = d
        else
            local u2, h2, po2, d2 =
                string.match(rest, "^([^@]+)@([^:]+):(%d+)/(.+)$")
            if u2 then
                user = u2; host = h2; port = tonumber(po2); database = d2
            end
        end
    end

    return {
        host = host,
        port = port,
        database = database,
        user = user,
        password = pass,
        connect_timeout = 5000,
    }
end

--- 确保数据库 Schema 存在
local function ensureSchema()
    local realm = config.getRealm()

    M.query("CREATE TABLE IF NOT EXISTS accounts (id SERIAL PRIMARY KEY, username TEXT UNIQUE NOT NULL, password_hash TEXT NOT NULL, created_at TIMESTAMPTZ NOT NULL DEFAULT now(), last_login TIMESTAMPTZ, is_admin BOOLEAN NOT NULL DEFAULT FALSE, banned_at TIMESTAMPTZ, suspended_until TIMESTAMPTZ, chat_muted_until TIMESTAMPTZ, chat_strikes INT NOT NULL DEFAULT 0, created_ip TEXT, last_login_ip TEXT, email TEXT, deactivated_at TIMESTAMPTZ, totp_secret TEXT, totp_enabled_at TIMESTAMPTZ, cosmetics JSONB NOT NULL DEFAULT '{}')")
    M.query("CREATE TABLE IF NOT EXISTS auth_tokens (token TEXT PRIMARY KEY, account_id INT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE, created_at TIMESTAMPTZ NOT NULL DEFAULT now(), expires_at TIMESTAMPTZ NOT NULL, scope TEXT NOT NULL DEFAULT 'full')")
    M.query(string.format("CREATE TABLE IF NOT EXISTS characters (id SERIAL PRIMARY KEY, account_id INT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE, name TEXT UNIQUE NOT NULL, class TEXT NOT NULL, realm TEXT NOT NULL DEFAULT '%s', level INT NOT NULL DEFAULT 1, state JSONB, created_at TIMESTAMPTZ NOT NULL DEFAULT now(), updated_at TIMESTAMPTZ NOT NULL DEFAULT now(), last_login TIMESTAMPTZ, hotbar_layout JSONB, is_gm BOOLEAN NOT NULL DEFAULT FALSE, force_rename BOOLEAN NOT NULL DEFAULT FALSE)", realm))
    M.query("CREATE TABLE IF NOT EXISTS character_leases (character_id INT PRIMARY KEY REFERENCES characters(id) ON DELETE CASCADE, realm TEXT NOT NULL, holder TEXT NOT NULL, nonce TEXT NOT NULL, acquired_at TIMESTAMPTZ NOT NULL DEFAULT now(), heartbeat_at TIMESTAMPTZ NOT NULL DEFAULT now(), expires_at TIMESTAMPTZ NOT NULL, account_id INT)")
    M.query("CREATE TABLE IF NOT EXISTS world_state (key TEXT PRIMARY KEY, data JSONB NOT NULL, updated_at TIMESTAMPTZ NOT NULL DEFAULT now())")
    M.query("CREATE TABLE IF NOT EXISTS friendships (character_id INT NOT NULL REFERENCES characters(id) ON DELETE CASCADE, friend_id INT NOT NULL REFERENCES characters(id) ON DELETE CASCADE, created_at TIMESTAMPTZ NOT NULL DEFAULT now(), PRIMARY KEY (character_id, friend_id), CHECK (character_id <> friend_id))")
    M.query("CREATE TABLE IF NOT EXISTS blocks (character_id INT NOT NULL REFERENCES characters(id) ON DELETE CASCADE, blocked_id INT NOT NULL REFERENCES characters(id) ON DELETE CASCADE, PRIMARY KEY (character_id, blocked_id))")
    M.query("CREATE TABLE IF NOT EXISTS ignores (character_id INT NOT NULL REFERENCES characters(id) ON DELETE CASCADE, ignored_id INT NOT NULL REFERENCES characters(id) ON DELETE CASCADE, PRIMARY KEY (character_id, ignored_id))")
    M.query("CREATE TABLE IF NOT EXISTS guilds (id SERIAL PRIMARY KEY, name TEXT UNIQUE NOT NULL, realm TEXT NOT NULL DEFAULT 'Claudemoon', created_at TIMESTAMPTZ NOT NULL DEFAULT now())")
    M.query("ALTER TABLE guilds ADD COLUMN IF NOT EXISTS motd TEXT NOT NULL DEFAULT ''")
    M.query("CREATE TABLE IF NOT EXISTS guild_members (guild_id INT NOT NULL REFERENCES guilds(id) ON DELETE CASCADE, character_id INT NOT NULL REFERENCES characters(id) ON DELETE CASCADE, rank INT NOT NULL DEFAULT 0, joined_at TIMESTAMPTZ NOT NULL DEFAULT now(), PRIMARY KEY (guild_id, character_id))")
    M.query("CREATE TABLE IF NOT EXISTS guild_banks (guild_id INT PRIMARY KEY REFERENCES guilds(id) ON DELETE CASCADE, data JSONB NOT NULL DEFAULT '{}', updated_at TIMESTAMPTZ NOT NULL DEFAULT now())")
    M.query("CREATE TABLE IF NOT EXISTS chat_logs (id BIGSERIAL PRIMARY KEY, account_id INT, character_id INT, character_name TEXT, channel TEXT, message TEXT, created_at TIMESTAMPTZ NOT NULL DEFAULT now())")
    print("[DB] Schema ensured")

    -- 补加缺失列 (原服务器可能未创建)
    M.query("ALTER TABLE auth_tokens ADD COLUMN IF NOT EXISTS scope TEXT NOT NULL DEFAULT 'full'")
    M.query("ALTER TABLE auth_tokens ADD COLUMN IF NOT EXISTS label TEXT")
    M.query("ALTER TABLE accounts ADD COLUMN IF NOT EXISTS email TEXT")
    M.query("ALTER TABLE accounts ADD COLUMN IF NOT EXISTS totp_secret TEXT")
    M.query("ALTER TABLE accounts ADD COLUMN IF NOT EXISTS totp_enabled_at TIMESTAMPTZ")
    M.query("ALTER TABLE accounts ADD COLUMN IF NOT EXISTS is_admin BOOLEAN NOT NULL DEFAULT FALSE")
    M.query("ALTER TABLE accounts ADD COLUMN IF NOT EXISTS banned_at TIMESTAMPTZ")
    M.query("ALTER TABLE accounts ADD COLUMN IF NOT EXISTS suspended_until TIMESTAMPTZ")
    M.query("ALTER TABLE accounts ADD COLUMN IF NOT EXISTS chat_muted_until TIMESTAMPTZ")
    M.query("ALTER TABLE accounts ADD COLUMN IF NOT EXISTS chat_strikes INT NOT NULL DEFAULT 0")
    M.query("ALTER TABLE accounts ADD COLUMN IF NOT EXISTS deactivated_at TIMESTAMPTZ")
    M.query("ALTER TABLE characters ADD COLUMN IF NOT EXISTS hotbar_layout JSONB")
    M.query("ALTER TABLE characters ADD COLUMN IF NOT EXISTS is_gm BOOLEAN NOT NULL DEFAULT FALSE")
    M.query("ALTER TABLE characters ADD COLUMN IF NOT EXISTS force_rename BOOLEAN NOT NULL DEFAULT FALSE")
    M.query("ALTER TABLE characters ADD COLUMN IF NOT EXISTS last_login TIMESTAMPTZ")
    M.query("ALTER TABLE character_leases ADD COLUMN IF NOT EXISTS account_id INT")
    -- 邮件 + 拍卖行 (mail/market 持久化)
    M.query("CREATE TABLE IF NOT EXISTS mail (id BIGSERIAL PRIMARY KEY, from_pid INT NOT NULL, to_pid INT NOT NULL, text TEXT, item_data JSONB, copper INT DEFAULT 0, is_read BOOLEAN DEFAULT FALSE, is_taken BOOLEAN DEFAULT FALSE, created_at TIMESTAMPTZ DEFAULT now())")
    M.query("CREATE TABLE IF NOT EXISTS auctions (id BIGSERIAL PRIMARY KEY, seller_pid INT NOT NULL, item_data JSONB NOT NULL, price INT NOT NULL CHECK (price > 0), sold BOOLEAN DEFAULT FALSE, buyer_pid INT, collected BOOLEAN DEFAULT FALSE, created_at TIMESTAMPTZ DEFAULT now())")
    print("[DB] Schema migrations applied")

    -- ===== 高频查询索引 (性能优化) =====
    -- 角色列表: 按账号+区服查询 (getCharactersByAccount)
    M.query("CREATE INDEX IF NOT EXISTS idx_characters_account_realm ON characters(account_id, realm)")
    -- 租约心跳: 按 holder 批量更新 (heartbeatLeases)
    M.query("CREATE INDEX IF NOT EXISTS idx_character_leases_holder ON character_leases(holder)")
    -- 公会反向查询: 按角色查所属公会 (getGuildByCharacter / removeGuildMember)
    M.query("CREATE INDEX IF NOT EXISTS idx_guild_members_character ON guild_members(character_id)")
    -- 邮件收件箱: 收件人 + 未提取 + 时间倒序 (listInbox 覆盖 filter + sort)
    M.query("CREATE INDEX IF NOT EXISTS idx_mail_inbox ON mail(to_pid, is_taken, created_at DESC)")
    -- 市场搜索: 未售 + 价格 + id (searchAuctions 覆盖 filter + sort)
    M.query("CREATE INDEX IF NOT EXISTS idx_auctions_search ON auctions(sold, price, id)")
    -- 卖家已售/结算: 卖家 + 状态 (collectAuctions / cancelAuction)
    M.query("CREATE INDEX IF NOT EXISTS idx_auctions_seller ON auctions(seller_pid, sold, collected)")
    -- 清理被复合索引取代的旧单列索引 (避免过度索引)
    M.query("DROP INDEX IF EXISTS idx_mail_to_pid")
    M.query("DROP INDEX IF EXISTS idx_mail_taken")
    M.query("DROP INDEX IF EXISTS idx_auctions_sold_price")
    print("[DB] Indexes ensured")
end

--- 加载 CRUD 模块
local function loadModules()
    require("db.account").register(M)
    require("db.auth").register(M)
    require("db.character").register(M)
    require("db.world_state").register(M)
    require("db.mail").register(M)
    require("db.auction").register(M)
    require("db.social").register(M)
    local n = 0
    for _ in pairs(handlers) do n = n + 1 end
    print(string.format("[DB] CRUD modules loaded (%d ops)", n))
end

--- 建立单个连接
local function connectOne()
    local dbConfig = parseDatabaseUrl(config.getDatabaseUrl())
    return pg.connect(dbConfig)
end

--- 连接池 (每连接独立 socket; 单连接慢查询不再拖垮整个 service 的后备)
local function buildPool()
    for i = 1, POOL_SIZE do
        local conn = connectOne()
        if conn.code then
            pool[i] = { conn = nil, healthy = false, busy = false, busySince = nil }
        else
            pool[i] = { conn = conn, healthy = true, busy = false, busySince = nil }
        end
    end
    local healthyCount = 0
    for _, e in ipairs(pool) do
        if e.healthy then healthyCount = healthyCount + 1 end
    end
    poolReady = healthyCount > 0
    return healthyCount
end

--- 连接数据库 (重试; 全池建立)
local function tryConnect()
    local healthyCount = buildPool()
    if healthyCount == 0 then
        print("[DB] All connections failed — retrying in 3s")
        moon.timeout(3000, function()
            moon.async(tryConnect)
        end)
        return false
    end

    print(string.format("[DB] Connected (%d/%d connections)", healthyCount, POOL_SIZE))
    if not M._schemaDone then
        ensureSchema()
        loadModules()
        M._schemaDone = true
    end
    print("[DB] Service ready")
    return true
end

--- 心跳检查: 每 15s SELECT 1, 断线触发重连 (P0 #3)
function M.heartbeat()
    moon.timeout(15000, function()
        moon.async(function()
            -- 找一个健康连接探测
            local ok = false
            for _, e in ipairs(pool) do
                if e.healthy then
                    local res = e.conn:query("SELECT 1")
                    if res.code == "SOCKET" or res.code == "CONNECTION" then
                        e.healthy = false
                    else
                        ok = true
                    end
                end
            end
            if not ok then
                print("[DB] Heartbeat failed — reconnecting")
                M._scheduleReconnect()
            end
            M.heartbeat()
        end)
    end)
end

--- 异步重连 (只补健康连接, 保留已健康连接)
function M._scheduleReconnect()
    if connecting then return end
    connecting = true
    moon.async(function()
        local healthyCount = 0
        for _, e in ipairs(pool) do
            if not e.healthy then
                local conn = connectOne()
                if conn.code then
                    e.conn = nil
                else
                    e.conn = conn
                    e.healthy = true
                end
            end
            if e.healthy then healthyCount = healthyCount + 1 end
        end
        poolReady = healthyCount > 0
        connecting = false
        if healthyCount == 0 then
            print("[DB] Reconnect failed — retrying in 3s")
            moon.timeout(3000, function()
                moon.async(M._scheduleReconnect)
            end)
        else
            print(string.format("[DB] Reconnected (%d/%d)", healthyCount, POOL_SIZE))
        end
    end)
end

-- 启动: 在协程中连接数据库
moon.async(tryConnect)
-- 启动心跳
moon.async(function()
    moon.sleep(15000)
    M.heartbeat()
end)
