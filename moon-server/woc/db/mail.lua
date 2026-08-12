-- World of ClaudeCraft — DB Service: Mail CRUD
-- PostgreSQL 持久化 + 归属校验 (to_pid) + 附件原子提取

local json = require("json")

local M = {}

function M.register(dbMod)
    local q = dbMod.query
    local qOne = dbMod.queryOne

    -- 发送邮件 (items 序列化为 JSONB 数组)
    dbMod:register("sendMail", function(fromPid, toPid, text, items, copper)
        if not toPid or toPid <= 0 then return nil, "Invalid recipient" end
        local itemJson = (items and #items > 0) and json.encode(items) or nil
        local row = qOne(
            "INSERT INTO mail (from_pid, to_pid, text, item_data, copper) VALUES (%s, %s, %s, %s, %s) RETURNING id",
            fromPid, toPid, text or "", itemJson, copper or 0)
        return row and row.id or nil
    end)

    -- 收件箱 (仅属于该玩家且未提取)
    dbMod:register("listInbox", function(pid)
        local res = q(
            "SELECT id, from_pid, text, copper, item_data, is_read, is_taken, created_at FROM mail WHERE to_pid=%s AND is_taken=false ORDER BY created_at DESC",
            pid)
        if res.code then return {} end
        return res.data or {}
    end)

    -- 阅读 (归属校验: 只有属于该玩家的才更新并返回)
    dbMod:register("readMail", function(pid, mailId)
        local row = qOne(
            "UPDATE mail SET is_read=true WHERE id=%s AND to_pid=%s RETURNING id, from_pid, text, copper, item_data, is_read, is_taken, created_at",
            mailId, pid)
        return row
    end)

    -- 提取附件 (原子: 归属 + 未提取才更新, 防重复领取)
    dbMod:register("takeMail", function(pid, mailId)
        local row = qOne(
            "UPDATE mail SET is_taken=true WHERE id=%s AND to_pid=%s AND is_taken=false RETURNING id, from_pid, text, copper, item_data, is_read, is_taken, created_at",
            mailId, pid)
        return row
    end)

    -- 删除 (归属校验)
    dbMod:register("deleteMail", function(pid, mailId)
        q("DELETE FROM mail WHERE id=%s AND to_pid=%s", mailId, pid)
        return true
    end)
end

return M
