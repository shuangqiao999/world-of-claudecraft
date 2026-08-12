-- World of ClaudeCraft — Gate Service (API + WebSocket on internal port)
-- 由 Node.js 代理转发 /api/* 和 /ws，代理负责静态文件

local moon = require("moon")
local socket = require("moon.socket")
local spack = require("shared.sproto_helpers")
spack.init()
local json = require("json")
local crypt = require("crypt")
local config = require("config")
local jh = require("shared.json_helpers")

-- 速率限制 (Phase 3)
local rateLimit = require("world.msg_rate_limit")

-- DB Service 路由 (单一数据库入口, 无直连 PG)
local sessions, pids = {}, {}
-- 按 characterId 的 session 索引 (断线重连复用, 对应 linkdead.ts planJoin)
local sessionsByChar = {}
local nextEntityId = 1000

local WS_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

------------------------------------------------------------
-- DB Service 调用 (moon.call 跨 worker, 无直连)
------------------------------------------------------------

--- 调用 DB Service 操作
--- @return data, err
local function dbCall(op, ...)
    local dbSvc = moon.queryservice("db")
    if not dbSvc then return nil, "db service unavailable" end
    local resp = moon.call("lua", dbSvc, { op = op, args = { ... } })
    if resp and resp.ok then
        return resp.data, nil
    end
    return nil, (resp and resp.error) or "db error"
end

--- DB Service 是否可用
local function dbUp()
    return moon.queryservice("db") ~= nil
end

--- DB Service 是否可用
local function dbUp()
    return moon.queryservice("db") ~= nil
end

------------------------------------------------------------
-- HTTP 处理
------------------------------------------------------------

local function sendHttpResponse(fd, status, contentType, body)
    local resp = string.format("HTTP/1.1 %s\r\nContent-Type: %s\r\nContent-Length: %d\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n%s",
        status, contentType, #body, body)
    -- write_then_close: 原子写+关 (socket.write + socket.close 在 CPU 争用下会丢数据)
    socket.write_then_close(fd, resp)
end

local function sendJson(fd, data)
    local body = json.encode(data)
    sendHttpResponse(fd, "200 OK", "application/json", body)
end

local function parseHeaders(fd, firstLine)
    local headerData = firstLine .. "\n" .. socket.read(fd, "\r\n\r\n")
    if not headerData then return nil end
    local lines = {}
    for line in headerData:gmatch("[^\r\n]+") do table.insert(lines, line) end
    if #lines == 0 then return nil end
    local method, path, _ = string.match(lines[1] or "", "^(%w+)%s+([^%s]+)%s+HTTP/(%d%.%d)$")
    if not method then return nil end
    local headers = {}
    for i = 2, #lines do
        local k, v = string.match(lines[i], "^([^:]+):%s*(.+)$")
        if k then headers[k:lower()] = v end
    end
    local clen = tonumber(headers["content-length"] or "0")
    local body = ""
    if clen > 0 then body = socket.read(fd, clen) or "" end
    return { method = method, path = path, headers = headers, body = body }
end

local hash = require("shared.password_hash")

local function handleHttpRequest(fd, req)
    if not req then sendJson(fd, { error = "Bad request" }); return end
    if req.method == "OPTIONS" then
        sendHttpResponse(fd, "200 OK", "application/json", "{}")
        return
    end

    local path, method = req.path, req.method

    if path == "/api/register" and method == "POST" then
        local b = json.decode(req.body or "{}")
        if not b then sendJson(fd, { error = "Invalid JSON" }); return end
        if type(b.username)~="string" or #b.username<3 then sendJson(fd, { error = "Invalid username" }); return end
        if type(b.password)~="string" or #b.password<6 then sendJson(fd, { error = "Password too short" }); return end
        if not dbUp() then sendJson(fd, { error = "DB not ready" }); return end
        local existing = dbCall("findAccount", b.username)
        if existing then sendJson(fd, { error = "Username taken" }); return end
        local pwHash = hash.hashPassword(b.password)
        local acct, err = dbCall("createAccount", b.username, pwHash)
        if not acct then sendJson(fd, { error = "Failed", reason = err }); return end
        local token = hash.newToken()
        dbCall("saveToken", token, acct.id, 168, "full")
        if b.email then dbCall("setAccountEmail", acct.id, b.email) end
        sendJson(fd, { token = token, username = acct.username, accountId = acct.id, emailMissing = false })
        return
    end

    if path == "/api/login" and method == "POST" then
        local b = json.decode(req.body or "{}")
        if not b then sendJson(fd, { error = "Invalid JSON" }); return end
        if not dbUp() then sendJson(fd, { error = "DB not ready" }); return end
        local acct = dbCall("findAccount", b.username or "")
        if not acct then sendJson(fd, { error = "Invalid credentials" }); return end
        if not hash.verifyPassword(b.password or "", acct.password_hash) then sendJson(fd, { error = "Invalid credentials" }); return end
        local token = hash.newToken()
        dbCall("saveToken", token, acct.id, 168, "full")
        sendJson(fd, { token = token, username = acct.username, emailMissing = not acct.email or #acct.email == 0 })
        return
    end

    if path == "/api/characters" and method == "GET" then
        local auth = req.headers["authorization"] or ""
        local token = string.match(auth, "^Bearer%s+(.+)$")
        if not token then sendJson(fd, { error = "Auth required" }); return end
        if not dbUp() then sendJson(fd, { error = "DB not ready" }); return end
        local acct = dbCall("accountAndScopeForToken", token)
        if not acct then sendJson(fd, { error = "Invalid token" }); return end
        local rows = dbCall("getCharactersByAccount", acct.account_id) or {}
        local chars = {}
        for _, c in ipairs(rows) do table.insert(chars, { id = c.id, name = c.name, class = c.class, level = c.level, skin = 0, online = false, forceRename = false }) end
        sendJson(fd, { realm = config.getRealm(), characters = chars })
        return
    end

    if path == "/api/characters" and method == "POST" then
        local auth = req.headers["authorization"] or ""
        local token = string.match(auth, "^Bearer%s+(.+)$")
        if not token then sendJson(fd, { error = "Auth required" }); return end
        local b = json.decode(req.body or "{}")
        if not b or not b.name or not b.class then sendJson(fd, { error = "Invalid request" }); return end
        if not dbUp() then sendJson(fd, { error = "DB not ready" }); return end
        local acct = dbCall("accountAndScopeForToken", token)
        if not acct then sendJson(fd, { error = "Invalid token" }); return end
        -- createCharacter 内部做全局唯一预检 + 事务
        local c, cerr = dbCall("createCharacter", acct.account_id, b.name, b.class)
        if not c then
            if cerr == "name_taken" then
                sendJson(fd, { error = "Name taken" }); return
            end
            sendJson(fd, { error = "Failed", reason = cerr }); return
        end
        sendJson(fd, { id = c.id, name = c.name, class = c.class, level = c.level, skin = 0, forceRename = false })
        return
    end

    if path == "/api/realms" then
        local body = '{"current":"' .. config.getRealm() .. '","realms":[{"name":"' .. config.getRealm() .. '","url":"","type":"Normal"}],"characters":{}}'
        sendHttpResponse(fd, "200 OK", "application/json", body)
        return
    end

    if path == "/api/status" then
        local n = 0; for _ in pairs(sessions) do n = n + 1 end
        sendJson(fd, { ok = true, realm = config.getRealm(), players_online = n, players_cap = config.MAX_PLAYERS_PER_REALM, steam = { enabled = false }, epic = { enabled = false }, dev_commands = true, profiler_invulnerability = true })
        return
    end

    if path == "/health" then
        sendJson(fd, { status = "ok", timestamp = os.time(), db = dbUp() and "connected" or "pending" })
        return
    end

    sendJson(fd, { error = "Not Found", path = path })
end

------------------------------------------------------------
-- WebSocket
------------------------------------------------------------

local function wsHandshake(fd, req)
    local key = req.headers["sec-websocket-key"]
    if not key then return false end
    local accept = crypt.base64encode(crypt.sha1(key .. WS_GUID))
    local resp = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: " .. accept .. "\r\n\r\n"
    socket.write(fd, resp)
    return true
end

local function wsWrite(fd, data)
    local len = #data
    local isBinary = len > 0 and string.byte(data, 1) < 0x20  -- Sproto binary starts with 0x01-0x07 type tag
    local opbyte = isBinary and 0x82 or 0x81
    local frame
    if len < 126 then frame = string.char(opbyte, len) .. data
    elseif len < 65536 then frame = string.char(opbyte, 126, math.floor(len/256), len%256) .. data
    else frame = string.char(opbyte, 127) .. string.pack("<I8", len) .. data end
    socket.write(fd, frame)
end

local function wsReadFrame(fd)
    local header = socket.read(fd, 2)
    if not header or #header < 2 then return nil end
    local b1, b2 = string.byte(header, 1, 2)
    local opcode = b1 & 0x0F
    local masked = (b2 & 0x80) ~= 0
    local plen = b2 & 0x7F
    if plen == 126 then
        local ext = socket.read(fd, 2); if not ext or #ext < 2 then return nil end
        plen = (string.byte(ext,1)<<8) | string.byte(ext,2)
    elseif plen == 127 then
        local ext = socket.read(fd, 8); if not ext or #ext < 8 then return nil end
        plen = string.unpack("<I8", ext)
    end
    local mask = ""
    if masked then mask = socket.read(fd, 4); if not mask or #mask < 4 then return nil end end
    local payload = plen > 0 and socket.read(fd, plen) or ""
    if not payload and plen > 0 then return nil end
    if masked and #mask == 4 then
        local decoded = {}
        for i = 1, #payload do decoded[i] = string.char(string.byte(payload, i) ~ string.byte(mask, ((i-1)%4)+1)) end
        payload = table.concat(decoded)
    end
    return opcode, payload
end

local function handleAuth(fd, msg)
    local token, characterId = msg.token, tonumber(msg.character)
    local timerWire = msg.timerWire
    if timerWire ~= config.STABLE_TIMER_WIRE_VERSION and timerWire ~= 1 then wsWrite(fd, spack.packFrame("ErrorFrame", { error = "incompatible world version" })); socket.close(fd); return end
    if not characterId or characterId ~= characterId then wsWrite(fd, spack.packFrame("ErrorFrame", { error = "bad auth message" })); socket.close(fd); return end
    print(string.format("[Gate] Auth fd=%d char=%d", fd, characterId))
    moon.async(function()
        if not dbUp() then wsWrite(fd, spack.packFrame("ErrorFrame", { error = "not authenticated" })); socket.close(fd); return end
        local auth = dbCall("accountAndScopeForToken", token)
        if not auth then wsWrite(fd, spack.packFrame("ErrorFrame", { error = "not authenticated" })); socket.close(fd); return end
        local accountId = auth.account_id
        local status = dbCall("getModerationStatus", accountId)
        if status and (status.banned or status.suspendedUntil or status.deactivated) then
            wsWrite(fd, spack.packFrame("ErrorFrame", { error = "not authenticated" })); socket.close(fd); return
        end
        local cr = dbCall("getCharacter", accountId, characterId)
        if not cr then wsWrite(fd, spack.packFrame("ErrorFrame", { error = "no such character" })); socket.close(fd); return end
        if cr.force_rename then wsWrite(fd, spack.packFrame("ErrorFrame", { error = "This character must be renamed before entering the world." })); socket.close(fd); return end

        -- 断线重连: 若该角色已有 linkdead session 且未超宽限期, 复用其 pid/实体
        -- (对应原 linkdead.ts planJoin resume 分支)
        local existing = sessionsByChar[characterId]
        if existing and existing.linkdead and existing.fd ~= fd then
            local world = moon.queryservice("world")
            local oldFd = existing.fd
            -- 旧 socket 已死, 从索引中摘除, 但保留实体在 world 中
            sessions[oldFd] = nil
            pids[existing.pid] = nil
            existing.fd = fd
            existing.linkdead = false
            existing.leaseNonce = existing.leaseNonce
            sessions[fd] = existing
            pids[existing.pid] = fd
            sessionsByChar[characterId] = existing
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
        sessions[fd] = { fd = fd, accountId = accountId, characterId = characterId, pid = pid, name = cr.name, cls = cr.class, leaseNonce = nonce, lastInputSeq = 0, linkdead = false }
        pids[pid] = fd
        sessionsByChar[characterId] = sessions[fd]
        -- hello seed 必须是 WORLD_SEED: 客户端用其重建整个地形/水体/植被 (online.ts cfg.seed)
        -- 服务器 terrain.lua 也用同一常量, 二者必须一致
        wsWrite(fd, jh.buildHelloFrame(pid, config.WORLD_SEED, cr.name, cr.class, config.getRealm(), {}, nil))
        print(string.format("[Gate] Auth OK: fd=%d pid=%d name=%s cls=%s", fd, pid, cr.name, cr.class))
        local world = moon.queryservice("world")
        if world then
            local sd = cr.state; if type(sd)=="string" then local ok, d = pcall(json.decode, sd); if ok then sd = d end end
            moon.send("lua", world, { t = "joinPlayer", pid = pid, characterId = characterId, accountId = accountId, name = cr.name, cls = cr.class, level = cr.level or 1, state = sd, leaseNonce = nonce })
        end
    end)
end

local function wsMessage(fd, text, isBinary)
    local msg = {}
    if isBinary then
        -- Sproto binary frame: decode via type tag
        local spack = require("shared.sproto_helpers")
        local typename, tbl = spack.unpackFrame(text)
        if typename == "SnapFrame" or typename == "EventsFrame" or typename == "SocialFrame" then
            return  -- server→client frames shouldn't arrive from client
        end
        msg = tbl or {}
    else
        local ok, decoded = pcall(json.decode, text)
        if not ok then return end
        msg = decoded
    end
    local t = msg.t
    if t == config.ONLINE_WORLD_AUTH_TYPE then
        handleAuth(fd, msg)
    elseif t == "input" or t == "cmd" then
        local sess = sessions[fd]; if not sess then return end
        -- 速率限制检查
        if not rateLimit.allowMessage(sess.pid) then
            if rateLimit.isKicked(sess.pid) then
                wsWrite(fd, spack.packFrame("ErrorFrame", { error = "Too many messages. Disconnected." }))
                socket.close(fd)
                sessions[fd] = nil
            end
            return
        end
        local world = moon.queryservice("world"); if not world then return end
        if t == "input" then moon.send("lua", world, { t = "playerInput", pid = sess.pid, seq = msg.seq, mi = msg.mi, facing = msg.facing })
        else moon.send("lua", world, { t = "playerCommand", pid = sess.pid, msg = msg }) end
    elseif t == "logout" then
        local sess = sessions[fd]; if not sess then socket.close(fd); return end
        print(string.format("[Gate] Logout fd=%d pid=%d", fd, sess.pid))
        rateLimit.cleanup(sess.pid)
        if dbUp() and sess.leaseNonce then moon.async(function() dbCall("releaseLease", sess.characterId, sess.leaseNonce) end) end
        local world = moon.queryservice("world")
        if world then moon.send("lua", world, { t = "playerLeave", pid = sess.pid, characterId = sess.characterId, leaseNonce = sess.leaseNonce }) end
        pids[sess.pid] = nil; sessions[fd] = nil
        if sessionsByChar[sess.characterId] == sess then sessionsByChar[sess.characterId] = nil end
        socket.close(fd)
    end
end

local function handleConnection(fd)
    local firstLine = socket.read(fd, "\n")
    if not firstLine then socket.close(fd); return end
    firstLine = firstLine:match("^(.-)\r?\n?$")
    if firstLine:match("^%w+%s+/%S*%s+HTTP/") then
        local req = parseHeaders(fd, firstLine)
        if not req then sendJson(fd, { error = "Bad request" }); return end
        if req.headers["upgrade"] and req.headers["upgrade"]:lower() == "websocket" then
            if wsHandshake(fd, req) then
                print(string.format("[Gate] WS upgrade fd=%d path=%s", fd, req.path))
                while true do
                    local opcode, payload = wsReadFrame(fd)
                    if not opcode then break end
                    if opcode == 0x8 then
                        -- WS 关闭: 标记 linkdead, 不清除会话
                        local sess = sessions[fd]
                        if sess and not sess.linkdead then
                            sess.linkdead = true
                            print(string.format("[Gate] Linkdead fd=%d pid=%d name=%s (grace=%ds)",
                                fd, sess.pid, sess.name, config.LINKDEAD_GRACE_MS / 1000))
                            local world = moon.queryservice("world")
                            if world then moon.send("lua", world, { t = "playerDisconnected", pid = sess.pid }) end
                        end
                        socket.close(fd); return
                    elseif opcode == 0x9 then socket.write(fd, string.char(0x8A, 0) .. (payload or ""))
                    elseif opcode == 0x1 then wsMessage(fd, payload, false) -- text/JSON
                    elseif opcode == 0x2 then wsMessage(fd, payload, true)  -- binary/Sproto
                    end
                end
            end
        else
            handleHttpRequest(fd, req)
        end
    else
        socket.close(fd)
    end
end

------------------------------------------------------------
-- 启动 (端口 8787 = 客户端硬约束, WS + HTTP 同端口; 迁移文档 §1)
------------------------------------------------------------
local gatePort = tonumber(os.getenv("WOC_GATE_PORT")) or 8787
local listenfd = socket.listen("0.0.0.0", gatePort, moon.PTYPE_SOCKET_TCP)
assert(listenfd > 0, "Gate listen failed")
print(string.format("[Gate] API+WS on 0.0.0.0:%d", gatePort))

moon.async(function()
    while true do
        local fd, err = socket.accept(listenfd, moon.id)
        if not fd then moon.sleep(1000)
        else
            -- scrypt 登录验证 (N=16384) 需 ~40s, 默认 15s 超时会在验证中途断开导致崩溃
            socket.settimeout(fd, 120)
            moon.async(function() handleConnection(fd) end)
        end
    end
end)

moon.dispatch("lua", function(sender, session, msg)
    if type(msg) ~= "table" then return end
    if msg.t == "broadcastSnap" and msg.data then
        if type(msg.data) == "table" then
            for fd, sess in pairs(sessions) do
                local frame = msg.data[sess.pid]
                if frame and not sess.linkdead then wsWrite(fd, frame) end
            end
        else
            for fd, sess in pairs(sessions) do
                if not sess.linkdead then wsWrite(fd, msg.data) end
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
    end
end)

moon.shutdown(function()
    socket.close(listenfd)
    moon.quit()
end)

print("[Gate] Service ready")
