-- World of ClaudeCraft — Inventory + Equipment
-- 背包管理: inv_move, equip, unequip, use, discard

local M = {}

--- 初始化玩家背包
function M.initPlayerInventory(meta)
    if not meta.inventory then meta.inventory = {} end
    if not meta.equipment then meta.equipment = {} end
    if not meta.bags then meta.bags = {} end
end

--- 物品移至背包指定位置
function M.invMove(meta, fromSlot, toSlot)
    M.initPlayerInventory(meta)
    local inv = meta.inventory
    local item = inv[fromSlot]
    local dest = inv[toSlot]
    inv[fromSlot] = dest
    inv[toSlot] = item
end

--- 装备物品
function M.equipItem(meta, entity, fromSlot, equipSlot)
    M.initPlayerInventory(meta)
    local item = meta.inventory[fromSlot]
    if not item then return false, "No item in slot" end

    -- 检查物品类型
    if not M._canEquip(item, equipSlot, entity) then
        return false, "Cannot equip to that slot"
    end

    -- 旧装备回背包
    local oldEquip = meta.equipment[equipSlot]
    if oldEquip then
        meta.inventory[fromSlot] = oldEquip
    else
        meta.inventory[fromSlot] = nil
    end
    meta.equipment[equipSlot] = item

    -- 应用装备属性
    M._applyItemStats(entity, item, 1)
    return true
end

--- 卸下装备
function M.unequipItem(meta, entity, equipSlot)
    if not meta.equipment[equipSlot] then return false end

    local item = meta.equipment[equipSlot]
    -- 卸下属性
    M._applyItemStats(entity, item, -1)
    meta.equipment[equipSlot] = nil

    -- 放入背包
    local freeSlot = M._findFreeSlot(meta)
    if freeSlot then
        meta.inventory[freeSlot] = item
    end
    return true
end

--- 使用物品
function M.useItem(meta, entity, slot)
    local item = meta.inventory[slot]
    if not item then return false end

    if item.type == "consume" then
        -- 消耗品
        if item.hp then entity.hp = math.min(entity.maxHp, entity.hp + item.hp) end
        if item.resource then entity.resource = math.min(entity.maxResource, entity.resource + item.resource) end
        meta.inventory[slot] = nil
        return true, { type = "item_used", name = item.name, hp = item.hp }
    end
    return false
end

--- 丢弃物品
function M.discardItem(meta, slot)
    if meta.inventory and meta.inventory[slot] then
        meta.inventory[slot] = nil
        return true
    end
    return false
end

--- 添加到背包
function M.addItem(meta, item)
    M.initPlayerInventory(meta)
    local slot = M._findFreeSlot(meta)
    if slot then
        meta.inventory[slot] = item
        return slot
    end
    return nil
end

--- 生成基础物品
function M.createItem(id, name, itemType, stats)
    return {
        id = id, name = name, type = itemType,
        slot = stats.slot, hp = stats.hp, ap = stats.ap,
        sp = stats.sp, crit = stats.crit, haste = stats.haste,
        value = stats.value or 1,
    }
end

--- 内部函数
function M._findFreeSlot(meta)
    for i = 0, 19 do
        if not meta.inventory[i] then return i end
    end
    return nil
end

function M._canEquip(item, equipSlot, entity)
    if not item.slot then return false end
    local cls = entity.templateId or "warrior"
    -- 简单职业限制
    if item.cls and item.cls ~= cls then return false end
    return item.slot == equipSlot
end

function M._applyItemStats(entity, item, factor)
    if item.ap then entity.attackPower = (entity.attackPower or 0) + item.ap * factor end
    if item.sp then entity.spellPower = (entity.spellPower or 0) + item.sp * factor end
    if item.crit then entity.critChance = (entity.critChance or 5) + item.crit * factor end
    if item.haste then entity.spellHaste = (entity.spellHaste or 0) + item.haste * factor end
end

return M
