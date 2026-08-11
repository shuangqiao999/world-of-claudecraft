-- World of ClaudeCraft — Vendor (NPC Shop)
-- buy, sell, buyback, sell_all_junk
-- 商店商品从 proto/items.json 生成 (value 字段为售价)

local M = {}

-- 商店商品表 (启动时从 proto 填充)
local VENDOR_ITEMS = {}
local vendorLoaded = false

--- 从 proto/items.json 构建商店 (TS: NPC vendorItems 引用 items)
function M.loadFromProto()
    if vendorLoaded then return end
    local ok, proto = pcall(function() return require("proto.load") end)
    if not ok then return end
    local items = proto.itemsById
    if not items then return end

    for id, item in pairs(items) do
        -- 可出售且有价值的普通物品 (非任务/非唯一材料)
        -- TS ItemDef: 售价字段为 sellValue (不是 value)
        local price = item.sellValue or item.value or 0
        if type(price) == "number" and price > 0 and item.kind ~= "quest" then
            table.insert(VENDOR_ITEMS, {
                id = id,
                name = item.name or id,
                kind = item.kind or "misc",
                slot = item.slot,
                value = price,
                requiredLevel = item.requiredLevel,
                item = item,
            })
        end
    end
    table.sort(VENDOR_ITEMS, function(a, b) return (a.requiredLevel or 0) < (b.requiredLevel or 0) end)
    vendorLoaded = true
    print(string.format("[Vendor] Loaded %d buyable items", #VENDOR_ITEMS))
end

--- 购买物品
--- @param meta playerMeta
--- @param entity Entity
--- @param itemId string
--- @return boolean, string|table
function M.buyItem(meta, entity, itemId, npcStock)
    -- NPC 专属库存过滤 (TS: NPC vendorItems 引用 items)
    local inStock = function(entry)
        if not npcStock then return true end
        for _, vid in ipairs(npcStock) do
            if vid == entry.id then return true end
        end
        return false
    end
    for _, item in ipairs(VENDOR_ITEMS) do
        if item.id == itemId and inStock(item) then
            local cost = item.value
            if (meta.copper or 0) < cost then
                return false, "Not enough copper"
            end

            meta.copper = meta.copper - cost
            local inventory = require("world.inventory")
            local newItem = inventory.createItem(item.id, item.name, item.kind or "misc", item.item or item)
            local slot = inventory.addItem(meta, newItem)
            if not slot then
                meta.copper = meta.copper + cost
                return false, "Inventory full"
            end
            return true, { name = item.name, cost = cost, slot = slot }
        end
    end
    return false, "Item not found"
end

--- 卖出物品
function M.sellItem(meta, slot)
    local inventory = require("world.inventory")
    local item = meta.inventory and meta.inventory[slot]
    if not item then return false, "No item to sell" end

    -- 售价: 优先 sellValue (TS ItemDef), 回退 value; 25% 回收价
    local sellValue = item.sellValue or item.value or 1
    local price = math.floor(sellValue * 0.25)
    meta.copper = (meta.copper or 0) + price
    meta.inventory[slot] = nil
    return true, { name = item.name, price = price }
end

--- 卖出所有灰色物品
function M.sellAllJunk(meta)
    local total = 0
    local inv = meta.inventory
    if not inv then return 0 end
    for slot, item in pairs(inv) do
        if item.quality == "junk" then
            total = total + math.floor((item.value or 1) * 0.25)
            inv[slot] = nil
        end
    end
    meta.copper = (meta.copper or 0) + total
    return total
end

--- 获取商店商品列表
function M.getVendorList()
    return VENDOR_ITEMS
end

return M
