-- World of ClaudeCraft — Mail Service (DB Service 路由, 持久化)
-- 无内存存储, 无直连 PG; 数据经 db service (PostgreSQL mail 表)

local moon = require("moon")

local M = {}

local function dbCall(op, ...)
    local dbSvc = moon.queryservice("db")
    if not dbSvc then return nil, "db unavailable" end
    local resp = moon.call("lua", dbSvc, { op = op, args = { ... } })
    if resp and resp.ok then return resp.data, nil end
    return nil, (resp and resp.error) or "db error"
end

moon.dispatch("lua", function(sender, session, msg)
    if type(msg) ~= "table" then return end
    local op = msg.op
    if op == "send" then
        local id, err = dbCall("sendMail", msg.from, msg.to, msg.text, msg.items, msg.copper)
        moon.response("lua", sender, session, { ok = id ~= nil, data = id, error = err })
    elseif op == "list" then
        local data, err = dbCall("listInbox", msg.pid)
        moon.response("lua", sender, session, { ok = data ~= nil, data = data or {}, error = err })
    elseif op == "read" then
        local data, err = dbCall("readMail", msg.pid, msg.mailId)
        moon.response("lua", sender, session, { ok = data ~= nil, data = data, error = data and nil or (err or "Not found") })
    elseif op == "take" then
        local data, err = dbCall("takeMail", msg.pid, msg.mailId)
        moon.response("lua", sender, session, { ok = data ~= nil, data = data, error = data and nil or (err or "Not found or already taken") })
    elseif op == "delete" then
        local _, err = dbCall("deleteMail", msg.pid, msg.mailId)
        moon.response("lua", sender, session, { ok = not err, error = err })
    end
end)

print("[Mail] Service ready (PostgreSQL)")
