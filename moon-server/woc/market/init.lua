-- World of ClaudeCraft — Market Service (Auction House)
-- DB Service 路由 + PostgreSQL 持久化 + FOR UPDATE 行锁 (防一物多卖)

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
    if op == "search" then
        local data, err = dbCall("searchAuctions", msg.query or "", msg.limit)
        moon.response("lua", sender, session, { ok = data ~= nil, data = data or {}, error = err })
    elseif op == "list_item" then
        local id, err = dbCall("listAuction", msg.pid, msg.item, msg.price)
        moon.response("lua", sender, session, { ok = id ~= nil, data = id, error = err })
    elseif op == "list_instance" then
        -- 上架单个实例副本 (TS marketListInstance): 校验 item + instance 形状
        if type(msg.item) ~= "table" or type(msg.instance) ~= "table" then
            moon.response("lua", sender, session, { ok = false, error = "Invalid listing" })
            return
        end
        local id, err = dbCall("listAuction", msg.pid, msg.item, msg.price)
        moon.response("lua", sender, session, { ok = id ~= nil, data = id, error = err })
    elseif op == "buy" then
        local auction, err = dbCall("buyAuction", msg.pid, msg.listingId)
        moon.response("lua", sender, session, { ok = auction ~= nil, data = auction, error = err })
    elseif op == "cancel" then
        local row, err = dbCall("cancelAuction", msg.pid, msg.listingId)
        moon.response("lua", sender, session, { ok = row ~= nil, data = row, error = row and nil or (err or "Not found") })
    elseif op == "collect" then
        local rows, err = dbCall("collectAuctions", msg.pid)
        moon.response("lua", sender, session, { ok = rows ~= nil, data = rows or {}, error = err })
    elseif op == "mark_collected" then
        local _, err = dbCall("markAuctionsCollected", msg.pid, msg.ids)
        moon.response("lua", sender, session, { ok = not err, error = err })
    end
end)

print("[Market] Service ready (PostgreSQL)")
