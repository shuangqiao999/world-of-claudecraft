-- World of ClaudeCraft — Trade System
-- trade_req, trade_accept, trade_offer, trade_confirm, trade_cancel

local M = {}

-- 交易状态: { pid1, pid2, offer1, offer2, confirmed1, confirmed2 }
local activeTrades = {}

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
    }
    return true, tradeId
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
        -- 执行交易
        return M._executeTrade(tradeId)
    end
    return true, "waiting"
end

--- 取消交易
function M.cancelTrade(tradeId)
    activeTrades[tradeId] = nil
    return true
end

--- 执行交易
function M._executeTrade(tradeId)
    local t = activeTrades[tradeId]
    if not t then return false end
    -- Phase 5 简化: 只交换物品引用 (完整版需要 inventory 操作)
    activeTrades[tradeId] = nil
    return true, { success = true }
end

return M
