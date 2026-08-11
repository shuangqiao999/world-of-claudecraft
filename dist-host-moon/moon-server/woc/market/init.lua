-- World of ClaudeCraft — Market Service (Auction House)

local moon = require("moon")

local M = {}

-- 拍卖列表 (简化内存版, 后续迁移到 world_state 表)
local listings = {}
local nextListingId = 1

moon.dispatch("lua", function(sender, session, msg)
    if type(msg) ~= "table" then return end
    local op = msg.op
    if op == "search" then moon.response("lua", sender, session, { listings = M.search(msg.query or "") })
    elseif op == "list_item" then moon.response("lua", sender, session, M.listItem(msg.pid, msg.item, msg.price))
    elseif op == "buy" then moon.response("lua", sender, session, M.buy(msg.pid, msg.listingId))
    elseif op == "cancel" then moon.response("lua", sender, session, M.cancel(msg.pid, msg.listingId))
    elseif op == "collect" then moon.response("lua", sender, session, M.collect(msg.pid))
    end
end)

--- 搜索
function M.search(query)
    local results = {}
    for _, li in ipairs(listings) do
        if not li.sold and string.find(li.item.name:lower(), query:lower()) then
            table.insert(results, li)
        end
    end
    return results
end

--- 上架
function M.listItem(pid, item, price)
    if not item or not price then return false, "Invalid params" end
    local listing = { id = nextListingId, pid = pid, item = item, price = price, sold = false, createdAt = os.time() }
    nextListingId = nextListingId + 1
    table.insert(listings, listing)
    return true, listing.id
end

--- 购买
function M.buy(buyerPid, listingId)
    for _, li in ipairs(listings) do
        if li.id == listingId and not li.sold then
            li.sold = true
            li.buyer = buyerPid
            return true, li
        end
    end
    return false, "Not found"
end

--- 取消
function M.cancel(pid, listingId)
    for _, li in ipairs(listings) do
        if li.id == listingId and not li.sold and li.pid == pid then
            li.sold = true
            return true
        end
    end
    return false, "Not found"
end

--- 收款 (简化: 标记为已收)
function M.collect(pid)
    local collected = {}
    for _, li in ipairs(listings) do
        if li.sold and li.buyer and li.collected == nil then
            li.collected = true
            table.insert(collected, li)
        end
    end
    return collected
end

print("[Market] Service ready")
