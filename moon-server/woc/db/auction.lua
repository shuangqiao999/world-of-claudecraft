-- World of ClaudeCraft — DB Service: Auction House CRUD
-- PostgreSQL 持久化 + 行级锁 (FOR UPDATE) 防一物多卖 + 事务

local json = require("json")

local M = {}

function M.register(dbMod)
    local q = dbMod.query

    -- 上架
    dbMod:register("listAuction", function(pid, item, price)
        if not item or not price or price <= 0 then return nil, "Invalid params" end
        local itemJson = json.encode(item)
        local res = q(
            "INSERT INTO auctions (seller_pid, item_data, price) VALUES (%s, %s, %s) RETURNING id",
            pid, itemJson, price)
        if res.code then return nil, tostring(res.message) end
        local d = res.data
        if d and d[1] then return d[1].id end
        return nil, "insert_failed"
    end)

    -- 搜索 (未售, 名称 ILIKE, LIMIT 防巨量)
    dbMod:register("searchAuctions", function(query, limit)
        limit = limit or 50
        local res
        if query and query ~= "" then
            res = q(
                "SELECT id, seller_pid, item_data, price, created_at FROM auctions WHERE sold=false AND lower(item_data->>'name') LIKE lower(%s) ORDER BY price ASC, id ASC LIMIT %s",
                "%" .. query .. "%", limit)
        else
            res = q(
                "SELECT id, seller_pid, item_data, price, created_at FROM auctions WHERE sold=false ORDER BY price ASC, id ASC LIMIT %s",
                limit)
        end
        if res.code then return {} end
        return res.data or {}
    end)

    -- 购买 (事务 + FOR UPDATE 行锁: 绝对防一物多卖)
    dbMod:register("buyAuction", function(buyerPid, listingId)
        local auction, err = dbMod.withTransaction(function(tx)
            -- 悲观锁: 锁定该行
            local res = tx.query(
                "SELECT id, seller_pid, item_data, price, sold FROM auctions WHERE id=%s FOR UPDATE",
                listingId)
            if res.code then error("select_failed: " .. tostring(res.message)) end
            local d = res.data
            if not d or #d == 0 then return nil, "not_found" end
            local a = d[1]
            if a.sold then return nil, "already_sold" end

            -- 标记已售
            local up = tx.query(
                "UPDATE auctions SET sold=true, buyer_pid=%s WHERE id=%s RETURNING id, seller_pid, item_data, price",
                buyerPid, listingId)
            if up.code then error("update_failed: " .. tostring(up.message)) end
            local ud = up.data
            if not ud or #ud == 0 then return nil, "not_found" end
            return ud[1]
        end)
        if auction then
            -- 反序列化 item_data
            if auction.item_data and type(auction.item_data) == "string" then
                local ok, decoded = pcall(json.decode, auction.item_data)
                if ok then auction.item_data = decoded end
            end
            return auction, nil
        end
        return nil, err or "buy_failed"
    end)

    -- 取消上架 (原子: 归属 + 未售, 返回 item_data 供退物)
    dbMod:register("cancelAuction", function(pid, listingId)
        local res = q(
            "UPDATE auctions SET sold=true WHERE id=%s AND seller_pid=%s AND sold=false RETURNING id, item_data, price",
            listingId, pid)
        if res.code then return nil end
        local d = res.data
        if d and #d > 0 then
            local row = d[1]
            if row.item_data and type(row.item_data) == "string" then
                local ok, decoded = pcall(json.decode, row.item_data)
                if ok then row.item_data = decoded end
            end
            return row
        end
        return nil
    end)

    -- 卖家已售记录 (供结算)
    dbMod:register("collectAuctions", function(pid)
        local res = q(
            "SELECT id, item_data, price, buyer_pid, created_at FROM auctions WHERE seller_pid=%s AND sold=true AND collected=false ORDER BY id ASC",
            pid)
        if res.code then return {} end
        local rows = res.data or {}
        for _, r in ipairs(rows) do
            if r.item_data and type(r.item_data) == "string" then
                local ok, decoded = pcall(json.decode, r.item_data)
                if ok then r.item_data = decoded end
            end
        end
        return rows
    end)

    -- 标记已结算
    dbMod:register("markAuctionsCollected", function(pid, ids)
        if not ids or #ids == 0 then return true end
        local placeholders = {}
        for i = 1, #ids do table.insert(placeholders, "%s") end
        q(string.format("UPDATE auctions SET collected=true WHERE seller_pid=%s AND id IN (%s)", pid, table.concat(placeholders, ",")),
          table.unpack(ids))
        return true
    end)
end

return M
