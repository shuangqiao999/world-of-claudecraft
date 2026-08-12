-- World of ClaudeCraft — Trade System
-- trade_req, trade_accept, trade_offer, trade_confirm, trade_cancel
-- 完整实现: 物品/铜币在双方背包间真实交换

local M = {}

-- 交易状态: { pid1, pid2, offer1, offer2, confirmed1, confirmed2, players, entities }
local activeTrades = {}

local inventory = require("world.inventory")

--- 发起交易请求
function M.requestTrade(fromPid, targetPid, entities, players)
    local from = entities[fromPid]; local target = entities[targetPid]
    if not from or not target then return false, "Player not found" end
    if from.dead or target.dead then return false, "Cannot trade dead players" end

    local tradeId = "trade_" .. fromPid .. "_" .. targetPid
    activeTrades[tradeId] = {
        pid1 = fromPid, pid2 = targetPid,
        offer1 = { items = {}, copper = 0 }, offer2 = { items = {}, copper = 0 },
        confirmed1 = false, confirmed2 = false,
        players = players, entities = entities,
    }
    return true, tradeId
end

--- 查找某玩家参与的活跃交易 id
function M.tradeIdOf(pid)
    for tid, t in pairs(activeTrades) do
        if t.pid1 == pid or t.pid2 == pid then return tid end
    end
    return nil
end

--- 接受交易
function M.acceptTrade(pid, tradeId)
    local t = activeTrades[tradeId]
    if not t then return false end
    return true
end

--- 提供物品 (放入交易窗口)
function M.offerItem(pid, tradeId, slot, meta)
    local t = activeTrades[tradeId]
    if not t then return false end
    if pid ~= t.pid1 and pid ~= t.pid2 then return false end

    local item = meta.inventory and meta.inventory[slot]
    if not item then return false end

    local isP1 = (pid == t.pid1)
    if isP1 then
        table.insert(t.offer1.items, { slot = slot, item = item })
    else
        table.insert(t.offer2.items, { slot = slot, item = item })
    end
    return true
end

--- 提供铜币
function M.offerCopper(pid, tradeId, amount, meta)
    local t = activeTrades[tradeId]
    if not t then return false end
    if amount < 0 then return false end
    if amount > (meta.copper or 0) then return false end

    if pid == t.pid1 then t.offer1.copper = amount
    else t.offer2.copper = amount end
    return true
end

--- 确认交易
function M.confirmTrade(pid, tradeId)
    local t = activeTrades[tradeId]
    if not t then return false end

    if pid == t.pid1 then t.confirmed1 = true
    else t.confirmed2 = true end

    if t.confirmed1 and t.confirmed2 then
        return M._executeTrade(tradeId)
    end
    return true, "waiting"
end

--- 取消交易
function M.cancelTrade(tradeId)
    activeTrades[tradeId] = nil
    return true
end

--- 执行交易 (真实移动物品/铜币)
function M._executeTrade(tradeId)
    local t = activeTrades[tradeId]
    if not t then return false end
    local players = t.players or {}
    local meta1 = players[t.pid1]
    local meta2 = players[t.pid2]
    if not meta1 or not meta2 then
        activeTrades[tradeId] = nil
        return false, "Player missing"
    end

    -- 校验铜币余额
    if (t.offer1.copper or 0) > (meta1.copper or 0) then
        activeTrades[tradeId] = nil
        return false, "Not enough copper (player 1)"
    end
    if (t.offer2.copper or 0) > (meta2.copper or 0) then
        activeTrades[tradeId] = nil
        return false, "Not enough copper (player 2)"
    end

    -- 校验物品仍在背包
    for _, off in ipairs(t.offer1.items or {}) do
        local it = meta1.inventory and meta1.inventory[off.slot]
        if not it or it ~= off.item then
            activeTrades[tradeId] = nil
            return false, "Item no longer in inventory (player 1)"
        end
    end
    for _, off in ipairs(t.offer2.items or {}) do
        local it = meta2.inventory and meta2.inventory[off.slot]
        if not it or it ~= off.item then
            activeTrades[tradeId] = nil
            return false, "Item no longer in inventory (player 2)"
        end
    end

    -- 移动物品: pid1 的 offer1 给 pid2, pid2 的 offer2 给 pid1
    local movedItems = {}
    for _, off in ipairs(t.offer1.items or {}) do
        meta1.inventory[off.slot] = nil
        local dst = inventory.addItem(meta2, off.item)
        if not dst then
            meta1.inventory[off.slot] = off.item -- 回滚
            activeTrades[tradeId] = nil
            return false, "Player 2 inventory full"
        end
        table.insert(movedItems, { item = off.item, from = t.pid1, to = t.pid2 })
    end
    for _, off in ipairs(t.offer2.items or {}) do
        meta2.inventory[off.slot] = nil
        local dst = inventory.addItem(meta1, off.item)
        if not dst then
            meta2.inventory[off.slot] = off.item -- 回滚
            activeTrades[tradeId] = nil
            return false, "Player 1 inventory full"
        end
        table.insert(movedItems, { item = off.item, from = t.pid2, to = t.pid1 })
    end

    -- 移动铜币
    local c1 = t.offer1.copper or 0
    local c2 = t.offer2.copper or 0
    meta1.copper = (meta1.copper or 0) - c1 + c2
    meta2.copper = (meta2.copper or 0) - c2 + c1

    activeTrades[tradeId] = nil
    return true, { success = true, items = movedItems, copper1 = c1, copper2 = c2 }
end

return M
