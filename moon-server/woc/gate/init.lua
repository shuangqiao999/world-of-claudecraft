-- World of ClaudeCraft — Gate Service (API + WebSocket)
-- 由 Node.js 代理层 (launcher_moon.mjs) 对外统一 8787, 内部分流:
--   /api/* 与 /health  → moon 的 HTTP 端口 (config.getPort(), 默认 8788)
--   WS upgrade        → moon 的 WS 端口 (WOC_WS_PORT, 默认 8789)
-- 底层 HTTP/WS 改用 moon 自带模块 (C++ 解析/缓冲/心跳):
--   moon.http.server   : HTTP 解析 + 路由 + keepalive
--   moon.http.websocket: WS 帧/掩码/心跳, 免手写背压与掩码循环
-- 会话/认证/广播等业务逻辑保持不变。

local moon = require("moon")
local socket = require("moon.socket")
local jh = require("shared.json_helpers")
local json = require("json")
local crypt = require("crypt")
local config = require("config")
local httpServer = require("moon.http.server")
local websocket = require("moon.http.websocket")

-- 速率限制 (Phase 3)
local rateLimit = require("world.msg_rate_limit")

-- DB Service 路由 (单一数据库入口, 无直连 PG)
local sessions, pids = {}, {}
-- 按 characterId 的 session 索引 (断线重连复用, 对应 linkdead.ts planJoin)
local sessionsByChar = {}
-- 按分片索引的 session 表: shardId → { [fd]=true, ... } (广播只遍历本分片)
local sessionsByShard = {}
local nextEntityId = 1000

-- 世界分片路由: pid % shardCount 决定玩家初始落在哪个 world_N 服务 (迁移后按会话 shard 路由)
local worldShardCount = config.getWorldShards()
local worldSvcCache = {}
local function worldSvcByShard(shard)
    local svc = worldSvcCache[shard]
    -- 世界分片可能在 gate 之后才创建完成, 缓存为空时重查
    if not svc then
        svc = moon.queryservice("world_" .. shard)
        if svc then worldSvcCache[shard] = svc end
    end
    return svc
end
local function worldSvc(pid)
    return worldSvcByShard(pid % worldShardCount)
end

-- 会话归属分片
local function shardOf(pid)
    return pid % worldShardCount
end

-- 连接限流 (令牌桶): 防止 login 风暴瞬间压垮 world 快照广播 + DB 连接池
local joinTokens = config.JOIN_RATE_LIMIT
local joinLastRefill = os.time()
local function joinGate()
    if config.JOIN_RATE_LIMIT <= 0 then return end
    while true do
        local now = os.time()
        if now > joinLastRefill then
            joinTokens = config.JOIN_RATE_LIMIT
            joinLastRefill = now
        end
        if joinTokens > 0 then
            joinTokens = joinTokens - 1
            return
        end
        moon.sleep(10)
    end
end

-- 端口: HTTP 用 config.getPort (launcher 转发 /api), WS 用 WOC_WS_PORT
local httpPort = config.getPort()
local wsPort = tonumber(os.getenv("WOC_WS_PORT")) or (httpPort + 1)

-----------------------------------------------------------------
-- DB Service 调用 (moon.call 跨 worker, 无直连)
-----------------------------------------------------------------
local function dbCall(op, ...)
    local dbSvc = moon.queryservice("db")
    if not dbSvc then return nil, "db service unavailable" end
    local resp = moon.call("lua", dbSvc, { op = op, args = { ... } })
    if resp and resp.ok then
        return resp.data, nil
    end
    return nil, (resp and resp.error) or "db error"
end

local function dbUp()
    return moon.queryservice("db") ~= nil
end

-----------------------------------------------------------------
-- WebSocket 发送 (官方模块 C++ 帧编码)
-----------------------------------------------------------------
local function wsWrite(fd, text)
    websocket.write_text(fd, text)
end

-----------------------------------------------------------------
-- 认证 (进入世界) — 业务逻辑不变
-----------------------------------------------------------------
local function handleAuth(fd, msg)
    local token, characterId = msg.token, tonumber(msg.character)
    local timerWire = msg.timerWire
    if timerWire ~= config.STABLE_TIMER_WIRE_VERSION and timerWire ~= 1 then wsWrite(fd, jh.buildErrorFrame("incompatible world version")); socket.close(fd); return end
    if not characterId or characterId ~= characterId then wsWrite(fd, jh.buildErrorFrame("bad auth message")); socket.close(fd); return end
    print(string.format("[Gate] Auth fd=%d char=%d", fd, characterId))
    moon.async(function()
        joinGate()
        if not dbUp() then wsWrite(fd, jh.buildErrorFrame("not authenticated")); socket.close(fd); return end
        local auth = dbCall("accountAndScopeForToken", token)
        if not auth then wsWrite(fd, jh.buildErrorFrame("not authenticated")); socket.close(fd); return end
        local accountId = auth.account_id
        local status = dbCall("getModerationStatus", accountId)
        if status and (status.banned or status.suspendedUntil or status.deactivated) then
            wsWrite(fd, jh.buildErrorFrame("not authenticated")); socket.close(fd); return
        end
        local cr = dbCall("getCharacter", accountId, characterId)
        if not cr then wsWrite(fd, jh.buildErrorFrame("no such character")); socket.close(fd); return end
        if cr.force_rename then wsWrite(fd, jh.buildErrorFrame("This character must be renamed before entering the world.")); socket.close(fd); return end

        -- 断线重连: 若该角色已有 linkdead session 且未超宽限期, 复用其 pid/实体
        local existing = sessionsByChar[characterId]
        if existing and existing.linkdead and existing.fd ~= fd then
            local world = worldSvcByShard(existing.shard)
            local oldFd = existing.fd
            -- 旧 socket 已死, 从索引中摘除, 但保留实体在 world 中
            sessions[oldFd] = nil
            pids[existing.pid] = nil
            local oldShard = sessionsByShard[existing.shard]
            if oldShard then oldShard[oldFd] = nil end
            existing.fd = fd
            existing.linkdead = false
            sessions[fd] = existing
            pids[existing.pid] = fd
            sessionsByChar[characterId] = existing
            local sh = sessionsByShard[existing.shard]
            if not sh then sh = {}; sessionsByShard[existing.shard] = sh end
            sh[fd] = true
            print(string.format("[Gate] Auth RESUME char=%d pid=%d (linkdead recovered)", characterId, existing.pid))
            wsWrite(fd, jh.buildHelloFrame(existing.pid, config.WORLD_SEED, cr.name, cr.class, config.getRealm(), {}, nil))
            if world then
                moon.send("lua", world, { t = "playerResumed", pid = existing.pid })
            end
            return
        end

        local nonce = string.format("%s%d", tostring(require("random").rand_range(100000, 999999)), os.time())
        dbCall("acquireLease", characterId, accountId, nonce)
        local pid = nextEntityId; nextEntityId = nextEntityId + 1
        local shard = shardOf(pid)
        sessions[fd] = { fd = fd, accountId = accountId, characterId = characterId, pid = pid, name = cr.name, cls = cr.class, leaseNonce = nonce, lastInputSeq = 0, linkdead = false, shard = shard }
        pids[pid] = fd
        sessionsByChar[characterId] = sessions[fd]
        local sh = sessionsByShard[shard]
        if not sh then sh = {}; sessionsByShard[shard] = sh end
        sh[fd] = true
        wsWrite(fd, jh.buildHelloFrame(pid, config.WORLD_SEED, cr.name, cr.class, config.getRealm(), {}, nil))
        print(string.format("[Gate] Auth OK: fd=%d pid=%d name=%s cls=%s shard=%d", fd, pid, cr.name, cr.class, shard))
        local world = worldSvcByShard(shard)
        if world then
            local sd = cr.state; if type(sd)=="string" then local ok, d = pcall(json.decode, sd); if ok then sd = d end end
            moon.send("lua", world, { t = "joinPlayer", pid = pid, characterId = characterId, accountId = accountId, name = cr.name, cls = cr.cls, level = cr.level or 1, state = sd, leaseNonce = nonce })
        end
    end)
end

-----------------------------------------------------------------
-- WS 消息分发 — 业务逻辑不变 (由官方 websocket 回调驱动)
-----------------------------------------------------------------
local function wsMessage(fd, text)
    local ok, msg = pcall(json.decode, text)
    if not ok then return end
    local t = msg.t
    if t == config.ONLINE_WORLD_AUTH_TYPE then
        handleAuth(fd, msg)
    elseif t == "input" or t == "cmd" then
        local sess = sessions[fd]; if not sess then return end
        if not rateLimit.allowMessage(sess.pid) then
            if rateLimit.isKicked(sess.pid) then
                wsWrite(fd, jh.buildErrorFrame("Too many messages. Disconnected."))
                socket.close(fd)
                sessions[fd] = nil
            end
            return
        end
        local world = worldSvcByShard(sess.shard); if not world then return end
        if t == "input" then
            moon.send("lua", world, { t = "playerInput", pid = sess.pid, seq = msg.seq, mi = msg.mi, facing = msg.facing })
        else moon.send("lua", world, { t = "playerCommand", pid = sess.pid, msg = msg }) end
    elseif t == "logout" then
        local sess = sessions[fd]; if not sess then socket.close(fd); return end
        print(string.format("[Gate] Logout fd=%d pid=%d", fd, sess.pid))
        rateLimit.cleanup(sess.pid)
        if dbUp() and sess.leaseNonce then moon.async(function() dbCall("releaseLease", sess.characterId, sess.leaseNonce) end) end
        local world = worldSvcByShard(sess.shard)
        if world then moon.send("lua", world, { t = "playerLeave", pid = sess.pid, characterId = sess.characterId, leaseNonce = sess.leaseNonce }) end
        pids[sess.pid] = nil; sessions[fd] = nil
        local sh = sessionsByShard[sess.shard]
        if sh then sh[fd] = nil end
        if sessionsByChar[sess.characterId] == sess then sessionsByChar[sess.characterId] = nil end
        socket.close(fd)
    end
end

-----------------------------------------------------------------
-- HTTP API 路由 (官方 moon.http.server 注册)
-----------------------------------------------------------------
local hash = require("shared.password_hash")

local function writeJson(response, data)
    response.status_code = 200
    response:write_header("Content-Type", "application/json")
    response:write(json.encode(data))
end

httpServer.on("/api/register", function(request, response)
    local b = json.decode(request.body or "{}")
    if not b then return writeJson(response, { error = "Invalid JSON" }) end
    if type(b.username)~="string" or #b.username<3 then return writeJson(response, { error = "Invalid username" }) end
    if type(b.password)~="string" or #b.password<6 then return writeJson(response, { error = "Password too short" }) end
    if not dbUp() then return writeJson(response, { error = "DB not ready" }) end
    local existing = dbCall("findAccount", b.username)
    if existing then return writeJson(response, { error = "Username taken" }) end
    local pwHash = hash.hashPassword(b.password)
    local acct, err = dbCall("createAccount", b.username, pwHash)
    if not acct then return writeJson(response, { error = "Failed", reason = err }) end
    local token = hash.newToken()
    dbCall("saveToken", token, acct.id, 168, "full")
    if b.email then dbCall("setAccountEmail", acct.id, b.email) end
    writeJson(response, { token = token, username = acct.username, accountId = acct.id, emailMissing = false })
end)

httpServer.on("/api/login", function(request, response)
    local b = json.decode(request.body or "{}")
    if not b then return writeJson(response, { error = "Invalid JSON" }) end
    if not dbUp() then return writeJson(response, { error = "DB not ready" }) end
    local acct = dbCall("findAccount", b.username or "")
    if not acct then return writeJson(response, { error = "Invalid credentials" }) end
    if not hash.verifyPassword(b.password or "", acct.password_hash) then return writeJson(response, { error = "Invalid credentials" }) end
    local token = hash.newToken()
    dbCall("saveToken", token, acct.id, 168, "full")
    writeJson(response, { token = token, username = acct.username, emailMissing = not acct.email or #acct.email == 0 })
end)

httpServer.on("/api/characters", function(request, response)
    local auth = request.headers["authorization"] or ""
    local token = string.match(auth, "^Bearer%s+(.+)$")
    if not token then return writeJson(response, { error = "Auth required" }) end
    if not dbUp() then return writeJson(response, { error = "DB not ready" }) end
    local acct = dbCall("accountAndScopeForToken", token)
    if not acct then return writeJson(response, { error = "Invalid token" }) end
    if request.method == "GET" then
        local rows = dbCall("getCharactersByAccount", acct.account_id) or {}
        local chars = {}
        for _, c in ipairs(rows) do table.insert(chars, { id = c.id, name = c.name, class = c.class, level = c.level, skin = 0, online = false, forceRename = false }) end
        writeJson(response, { realm = config.getRealm(), characters = chars })
    elseif request.method == "POST" then
        local b = json.decode(request.body or "{}")
        if not b or not b.name or not b.class then return writeJson(response, { error = "Invalid request" }) end
        local c, cerr = dbCall("createCharacter", acct.account_id, b.name, b.class)
        if not c then
            if cerr == "name_taken" then return writeJson(response, { error = "Name taken" }) end
            return writeJson(response, { error = "Failed", reason = cerr })
        end
        writeJson(response, { id = c.id, name = c.name, class = c.class, level = c.level, skin = 0, forceRename = false })
    else
        response.status_code = 405; response:write_header("Content-Type", "text/plain"); response:write("Method Not Allowed")
    end
end)

httpServer.on("/api/realms", function(request, response)
    local body = '{"current":"' .. config.getRealm() .. '","realms":[{"name":"' .. config.getRealm() .. '","url":"","type":"Normal"}],"characters":{}}'
    response.status_code = 200; response:write_header("Content-Type", "application/json"); response:write(body)
end)

httpServer.on("/api/status", function(request, response)
    local n = 0; for _ in pairs(sessions) do n = n + 1 end
    writeJson(response, { ok = true, realm = config.getRealm(), players_online = n, players_cap = config.MAX_PLAYERS_PER_REALM, steam = { enabled = false }, epic = { enabled = false }, dev_commands = true, profiler_invulnerability = true })
end)

httpServer.on("/health", function(request, response)
    writeJson(response, { status = "ok", timestamp = os.time(), db = dbUp() and "connected" or "pending" })
end)

-- CORS preflight + 兜底
httpServer.fallback(function(request, response, next)
    if request.method == "OPTIONS" then
        response.status_code = 200
        response:write_header("Content-Type", "application/json")
        response:write("{}")
    else
        response.status_code = 404
        response:write_header("Content-Type", "application/json")
        response:write(json.encode({ error = "Not Found", path = request.path }))
    end
end)

-----------------------------------------------------------------
-- 官方 websocket 回调: 消息 / 关闭 (C++ 帧解码驱动)
-----------------------------------------------------------------
websocket.wson("message", function(fd, msg)
    -- 'Z' = payload string (S 是 sender 数字); 文本帧载荷用 Z 取
    local text = moon.decode(msg, "Z")
    if text then wsMessage(fd, text) end
end)

websocket.wson("close", function(fd)
    print(string.format("[Gate] WS close fd=%d", fd))
    local sess = sessions[fd]
    if sess and not sess.linkdead then
        sess.linkdead = true
        print(string.format("[Gate] Linkdead fd=%d pid=%d name=%s (grace=%ds)", fd, sess.pid, sess.name, config.LINKDEAD_GRACE_MS / 1000))
        local world = worldSvcByShard(sess.shard)
        if world then moon.send("lua", world, { t = "playerDisconnected", pid = sess.pid }) end
    end
    socket.close(fd)
end)

-----------------------------------------------------------------
-- 启动: HTTP (官方 server) + WS (官方 websocket) 双监听
-----------------------------------------------------------------
print(string.format("[Gate] HTTP on 0.0.0.0:%d (proxy /api)", httpPort))
httpServer.listen("0.0.0.0", httpPort, 30)

print(string.format("[Gate] WS on 0.0.0.0:%d (proxy upgrade)", wsPort))
websocket.listen("0.0.0.0", wsPort)

-----------------------------------------------------------------
-- 跨服务消息: 快照广播 / 单发 / 会话迁移 (业务逻辑不变)
-----------------------------------------------------------------
moon.dispatch("lua", function(sender, session, msg)
    if type(msg) ~= "table" then return end
    if msg.t == "broadcastSnap" and msg.data then
        if type(msg.data) == "table" then
            -- 快照 (pid→frame): 只发给本分片会话。sender 是 world_N, 从服务名解析分片
            local shard = msg.shard
            local sh = (shard ~= nil) and sessionsByShard[shard]
            if sh then
                for fd in pairs(sh) do
                    local sess = sessions[fd]
                    if sess and not sess.linkdead then
                        local frame = msg.data[sess.pid]
                        if frame then wsWrite(fd, frame) end
                    end
                end
            else
                -- 兼容无 shard 标记: 全量遍历
                for fd, sess in pairs(sessions) do
                    local frame = msg.data[sess.pid]
                    if frame and not sess.linkdead then wsWrite(fd, frame) end
                end
            end
        else
            -- 世界事件 (无 pid): 只发给同一分片的会话
            local shard = msg.shard
            if shard ~= nil and sessionsByShard[shard] then
                for fd in pairs(sessionsByShard[shard]) do
                    local sess = sessions[fd]
                    if sess and not sess.linkdead then wsWrite(fd, msg.data) end
                end
            else
                for fd, sess in pairs(sessions) do
                    if not sess.linkdead then wsWrite(fd, msg.data) end
                end
            end
        end
    elseif msg.t == "commandOutcome" then
        -- 把 world 的命令结果回发给特定玩家 (cmdWithOutcome 5s 超时前必须应答)
        local fd = msg.pid and pids[msg.pid]
        if fd and sessions[fd] and not sessions[fd].linkdead then
            wsWrite(fd, jh.buildCommandOutcomeFrame(msg.rid, msg.ok == true))
        end
    elseif msg.t == "sendToPlayer" and msg.pid then
        -- 单玩家定向帧 (social 快照 / 个人事件等)
        local fd = pids[msg.pid]
        if fd and sessions[fd] and not sessions[fd].linkdead and msg.frame then
            wsWrite(fd, msg.frame)
        end
    elseif msg.t == "playerMigrated" then
        -- 跨分片玩家会话迁移: 更新会话归属分片, 后续 input/cmd/snapshot 按新分片路由
        local fd = pids[msg.pid]
        local sess = fd and sessions[fd]
        if sess and msg.shard and msg.shard ~= sess.shard then
            local oldShard = sess.shard
            local oldSh = sessionsByShard[oldShard]
            if oldSh then oldSh[fd] = nil end
            sess.shard = msg.shard
            local sh = sessionsByShard[msg.shard]
            if not sh then sh = {}; sessionsByShard[msg.shard] = sh end
            sh[fd] = true
        end
    elseif msg.t == "linkdeadClear" and msg.pid then
        local fd = pids[msg.pid]
        local sess = fd and sessions[fd]
        if sess then sess.linkdead = false end
    end
end)
