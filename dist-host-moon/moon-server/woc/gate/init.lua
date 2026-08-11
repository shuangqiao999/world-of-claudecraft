-- World of ClaudeCraft — Gate Service (API + WebSocket on internal port)
-- 由 Node.js 代理转发 /api/* 和 /ws，代理负责静态文件

local moon = require("moon")
local socket = require("moon.socket")
local json = require("json")
local crypt = require("crypt")
local config = require("config")
local jh = require("shared.json_helpers")
local sql = require("shared.sql")

-- 速率限制 (Phase 3)
local rateLimit = require("world.msg_rate_limit")

-- PG
local pg = require("moon.db.pg")
local gateDb, gateDbReady
local sessions, pids = {}, {}
local nextEntityId = 1000

local WS_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

local function escG(s) if not s then return "NULL" end return "'" .. string.gsub(tostring(s), "'", "''") .. "'" end
local function asBool(v) if v == nil then return nil end if type(v)=="boolean" then return v end if type(v)=="string" then local s = v:gsub("%z",""):match("^%s*(.-)%s*$"); if s=="" or s=="false" then return false end end return true end

------------------------------------------------------------
-- PG 连接
------------------------------------------------------------

moon.async(function()
    local realmCfg = require("config")
    local function parseUrl(url)
        url = url or ""
        local u, p, h, po, d = "postgres", nil, "127.0.0.1", 5432, "woc"
        local rest = string.match(url, "^postgresql://(.+)$") or string.match(url, "^postgres://(.+)$")
        if rest then local m = { string.match(rest, "^([^:]+):([^@]+)@([^:]+):(%d+)/(.+)$") }; if m[1] then u, p, h, po, d = m[1], m[2], m[3], tonumber(m[4]), m[5] end end
        return { host = h, port = po, database = d, user = u, password = p, connect_timeout = 5000 }
    end
    gateDb = pg.connect(parseUrl(realmCfg.getDatabaseUrl()))
    if gateDb.code then print(string.format("[Gate] PG connect FAILED: %s", tostring(gateDb.code))) else gateDbReady = true; print("[Gate] PG connected") end
end)

------------------------------------------------------------
-- HTTP 处理
------------------------------------------------------------

local function sendHttpResponse(fd, status, contentType, body)
    local resp = string.format("HTTP/1.1 %s\r\nContent-Type: %s\r\nContent-Length: %d\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n%s",
        status, contentType, #body, body)
    socket.write(fd, resp)
end

local function sendJson(fd, data)
    local body = json.encode(data)
    sendHttpResponse(fd, "200 OK", "application/json", body)
    socket.close(fd)
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
        if not gateDbReady then sendJson(fd, { error = "DB not ready" }); return end
        local r = gateDb:query(sql.fmt("SELECT id FROM accounts WHERE username=%s", b.username))
        if r.data and #r.data > 0 then sendJson(fd, { error = "Username taken" }); return end
        local pwHash = hash.hashPassword(b.password)
        local r2 = gateDb:query(sql.fmt("INSERT INTO accounts (username, password_hash) VALUES (%s, %s) RETURNING id, username", b.username, pwHash))
        if r2.code then sendJson(fd, { error = "Failed" }); return end
        local acct = r2.data[1]
        local token = hash.newToken()
        gateDb:query(sql.fmt("INSERT INTO auth_tokens (token, account_id, expires_at, scope) VALUES (%s, %d, now() + interval '168 hours', 'full')", token, acct.id))
        if b.email then gateDb:query(sql.fmt("UPDATE accounts SET email=%s WHERE id=%d", b.email, acct.id)) end
        sendJson(fd, { token = token, username = acct.username, accountId = acct.id, emailMissing = false })
        return
    end

    if path == "/api/login" and method == "POST" then
        local b = json.decode(req.body or "{}")
        if not b then sendJson(fd, { error = "Invalid JSON" }); return end
        if not gateDbReady then sendJson(fd, { error = "DB not ready" }); return end
        local r = gateDb:query(sql.fmt("SELECT id, username, password_hash, email FROM accounts WHERE username=%s", b.username or ""))
        if not r.data or #r.data == 0 then sendJson(fd, { error = "Invalid credentials" }); return end
        local acct = r.data[1]
        if not hash.verifyPassword(b.password or "", acct.password_hash) then sendJson(fd, { error = "Invalid credentials" }); return end
        local token = hash.newToken()
        gateDb:query(sql.fmt("INSERT INTO auth_tokens (token, account_id, expires_at, scope) VALUES (%s, %d, now() + interval '168 hours', 'full')", token, acct.id))
        sendJson(fd, { token = token, username = acct.username, emailMissing = not acct.email or #acct.email == 0 })
        return
    end

    if path == "/api/characters" and method == "GET" then
        local auth = req.headers["authorization"] or ""
        local token = string.match(auth, "^Bearer%s+(.+)$")
        if not token then sendJson(fd, { error = "Auth required" }); return end
        if not gateDbReady then sendJson(fd, { error = "DB not ready" }); return end
        local r = gateDb:query(sql.fmt("SELECT account_id FROM auth_tokens WHERE token=%s AND expires_at > now()", token))
        if not r.data or #r.data == 0 then sendJson(fd, { error = "Invalid token" }); return end
        local agoDb = r.data[1].account_id
        local r2 = gateDb:query(sql.fmt("SELECT id, name, class, level FROM characters WHERE account_id=%d AND realm=%s ORDER BY id", agoDb, config.getRealm()))
        local chars = {}
        for _, c in ipairs(r2.data or {}) do table.insert(chars, { id = c.id, name = c.name, class = c.class, level = c.level, skin = 0, online = false, forceRename = false }) end
        sendJson(fd, { realm = config.getRealm(), characters = chars })
        return
    end

    if path == "/api/characters" and method == "POST" then
        local auth = req.headers["authorization"] or ""
        local token = string.match(auth, "^Bearer%s+(.+)$")
        if not token then sendJson(fd, { error = "Auth required" }); return end
        local b = json.decode(req.body or "{}")
        if not b or not b.name or not b.class then sendJson(fd, { error = "Invalid request" }); return end
        if not gateDbReady then sendJson(fd, { error = "DB not ready" }); return end
        local r = gateDb:query(sql.fmt("SELECT account_id FROM auth_tokens WHERE token=%s AND expires_at > now()", token))
        if not r.data or #r.data == 0 then sendJson(fd, { error = "Invalid token" }); return end
        local agoDb = r.data[1].account_id
        local r2 = gateDb:query(sql.fmt("SELECT id FROM characters WHERE name=%s AND realm=%s", b.name, config.getRealm()))
        if r2.data and #r2.data > 0 then sendJson(fd, { error = "Name taken" }); return end
        local r3 = gateDb:query(sql.fmt("INSERT INTO characters (account_id, name, class, realm, level, state) VALUES (%d, %s, %s, %s, 1, '{}') RETURNING id, name, class, level", agoDb, b.name, b.class, config.getRealm()))
        if r3.code then sendJson(fd, { error = "Failed" }); return end
        local c = r3.data[1]
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
        sendJson(fd, { status = "ok", timestamp = os.time(), db = gateDbReady and "connected" or "pending" })
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

local function wsWrite(fd, text)
    local len = #text
    local frame
    if len < 126 then frame = string.char(0x81, len) .. text
    elseif len < 65536 then frame = string.char(0x81, 126, math.floor(len/256), len%256) .. text
    else frame = string.char(0x81, 127) .. string.pack("<I8", len) .. text end
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
    if timerWire ~= config.STABLE_TIMER_WIRE_VERSION and timerWire ~= 1 then wsWrite(fd, '{"t":"error","error":"incompatible world version"}'); socket.close(fd); return end
    if not characterId or characterId ~= characterId then wsWrite(fd, '{"t":"error","error":"bad auth message"}'); socket.close(fd); return end
    print(string.format("[Gate] Auth fd=%d char=%d", fd, characterId))
    moon.async(function()
        if not gateDbReady then wsWrite(fd, '{"t":"error","error":"not authenticated"}'); socket.close(fd); return end
        local r = gateDb:query(sql.fmt("SELECT account_id, scope FROM auth_tokens WHERE token=%s AND expires_at > now()", token))
        if not r.data or #r.data == 0 then wsWrite(fd, '{"t":"error","error":"not authenticated"}'); socket.close(fd); return end
        local accountId, scope = r.data[1].account_id, r.data[1].scope
        if scope ~= "full" and scope ~= "read" then wsWrite(fd, '{"t":"error","error":"not authenticated"}'); socket.close(fd); return end
        local r2 = gateDb:query(sql.fmt("SELECT banned_at, suspended_until, deactivated_at FROM accounts WHERE id=%s", accountId))
        if r2.data and #r2.data > 0 then local row = r2.data[1]; if asBool(row.banned_at) or asBool(row.suspended_until) or asBool(row.deactivated_at) then wsWrite(fd, '{"t":"error","error":"not authenticated"}'); socket.close(fd); return end end
        local r3 = gateDb:query(sql.fmt("SELECT id, account_id, name, class, level, state, is_gm, force_rename, hotbar_layout FROM characters WHERE id=%s AND account_id=%s AND realm=%s", characterId, accountId, config.getRealm()))
        if not r3.data or #r3.data == 0 then wsWrite(fd, '{"t":"error","error":"no such character"}'); socket.close(fd); return end
        local cr = r3.data[1]
        if cr.force_rename then wsWrite(fd, '{"t":"error","error":"This character must be renamed before entering the world."}'); socket.close(fd); return end
        local nonce = string.format("%s%d", tostring(math.random(100000,999999)), os.time())
        local leaseHolder = string.format("%s#%s", config.getRealm(), tostring(math.random(100000, 999999)))
        gateDb:query(sql.fmt("INSERT INTO character_leases (character_id, realm, holder, nonce, account_id, acquired_at, heartbeat_at, expires_at) VALUES (%s, %s, %s, %s, %s, now(), now(), now() + make_interval(secs => %s)) ON CONFLICT (character_id) DO UPDATE SET realm=EXCLUDED.realm, holder=EXCLUDED.holder, nonce=EXCLUDED.nonce, account_id=EXCLUDED.account_id, acquired_at=now(), heartbeat_at=now(), expires_at=EXCLUDED.expires_at WHERE character_leases.expires_at < now() OR character_leases.holder=EXCLUDED.holder OR character_leases.account_id=EXCLUDED.account_id", characterId, config.getRealm(), leaseHolder, nonce, accountId, config.LEASE_TTL_SECONDS))
        local pid = nextEntityId; nextEntityId = nextEntityId + 1
        sessions[fd] = { fd = fd, accountId = accountId, characterId = characterId, pid = pid, name = cr.name, cls = cr.class, leaseNonce = nonce, leaseHolder = leaseHolder, lastInputSeq = 0, linkdead = false }
        pids[pid] = fd
        wsWrite(fd, jh.buildHelloFrame(pid, msg.clientSeed ~= "" and msg.clientSeed or tostring(os.time()), cr.name, cr.class, config.getRealm(), {}, nil))
        print(string.format("[Gate] Auth OK: fd=%d pid=%d name=%s cls=%s", fd, pid, cr.name, cr.class))
        local world = moon.queryservice("world")
        if world then
            local sd = cr.state; if type(sd)=="string" then local ok, d = pcall(json.decode, sd); if ok then sd = d end end
            moon.send("lua", world, { t = "joinPlayer", pid = pid, characterId = characterId, accountId = accountId, name = cr.name, cls = cr.class, level = cr.level or 1, state = sd, leaseNonce = nonce })
        end
    end)
end

local function wsMessage(fd, text)
    local ok, msg = pcall(json.decode, text)
    if not ok then return end
    local t = msg.t
    if t == config.ONLINE_WORLD_AUTH_TYPE then
        handleAuth(fd, msg)
    elseif t == "input" or t == "cmd" then
        local sess = sessions[fd]; if not sess then return end
        -- 速率限制检查
        if not rateLimit.allowMessage(sess.pid) then
            if rateLimit.isKicked(sess.pid) then
                wsWrite(fd, '{"t":"error","error":"Too many messages. Disconnected."}')
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
        if gateDbReady and sess.leaseNonce then moon.async(function() gateDb:query(sql.fmt("DELETE FROM character_leases WHERE character_id=%s AND holder=%s AND nonce=%s", sess.characterId, sess.leaseHolder or "", sess.leaseNonce)) end) end
        local world = moon.queryservice("world")
        if world then moon.send("lua", world, { t = "playerLeave", pid = sess.pid, characterId = sess.characterId, leaseNonce = sess.leaseNonce }) end
        pids[sess.pid] = nil; sessions[fd] = nil; socket.close(fd)
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
                    elseif opcode == 0x1 then wsMessage(fd, payload) end
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
-- 启动 (端口 8788，由代理转发)
------------------------------------------------------------
local gatePort = tonumber(os.getenv("WOC_GATE_PORT")) or 8788
local listenfd = socket.listen("0.0.0.0", gatePort, moon.PTYPE_SOCKET_TCP)
assert(listenfd > 0, "Gate listen failed")
print(string.format("[Gate] API+WS on 0.0.0.0:%d", gatePort))

moon.async(function()
    while true do
        local fd, err = socket.accept(listenfd, moon.id)
        if not fd then moon.sleep(1000)
        else
            socket.settimeout(fd, 15)
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
    end
end)

moon.shutdown(function()
    socket.close(listenfd)
    moon.quit()
end)

print("[Gate] Service ready")
