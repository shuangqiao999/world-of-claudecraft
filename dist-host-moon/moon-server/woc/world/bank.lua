-- World of ClaudeCraft — Bank System
-- bank_deposit, bank_withdraw, bank_buy_slots

local M = {}

--- 初始化银行数据
function M.initBank(meta)
    if not meta.bank then
        meta.bank = { items = {}, slots = 20 }
    end
end

--- 存款
function M.deposit(meta, invSlot)
    M.initBank(meta)
    local item = meta.inventory and meta.inventory[invSlot]
    if not item then return false, "No item in slot" end

    local freeSlot = M._findFreeSlot(meta.bank)
    if not freeSlot then return false, "Bank is full" end

    meta.bank.items[freeSlot] = item
    meta.inventory[invSlot] = nil
    return true
end

--- 取款
function M.withdraw(meta, bankSlot)
    M.initBank(meta)
    local item = meta.bank.items[bankSlot]
    if not item then return false, "No item in bank slot" end

    local inventory = require("world.inventory")
    local freeSlot = inventory._findFreeSlot(meta)
    if not freeSlot then return false, "Inventory full" end

    meta.inventory[freeSlot] = item
    meta.bank.items[bankSlot] = nil
    return true
end

--- 购买银行格子
function M.buySlots(meta, count)
    M.initBank(meta)
    local cost = count * 50  -- 50 copper per slot
    if (meta.copper or 0) < cost then return false, "Not enough copper" end
    meta.copper = meta.copper - cost
    meta.bank.slots = meta.bank.slots + count
    return true
end

function M._findFreeSlot(bank)
    for i = 0, bank.slots - 1 do
        if not bank.items[i] then return i end
    end
    return nil
end

return M
