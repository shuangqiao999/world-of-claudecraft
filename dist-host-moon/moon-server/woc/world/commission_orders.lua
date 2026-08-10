-- World of ClaudeCraft — Commission Order Board
-- 对应原项目 src/sim/sim.ts updateCommissionOrders (issue #1298)
-- 过期开放订单清理 + 终态订单保留窗口

local M = {}

-- 开放订单保留 (秒)
local OPEN_ORDER_EXPIRE = 7 * 24 * 3600
-- 终态订单保留 (秒)
local TERMINAL_RETAIN = 24 * 3600

-- orders: { {id, status="open"|"complete"|"expired", updatedAt} }
local orders = {}

--- 发布订单
function M.publish(order)
    table.insert(orders, {
        id = order.id,
        status = order.status or "open",
        updatedAt = os.time(),
        payload = order.payload,
    })
end

--- 更新订单状态
function M.updateStatus(orderId, status)
    for _, o in ipairs(orders) do
        if o.id == orderId then
            o.status = status
            o.updatedAt = os.time()
            return true
        end
    end
    return false
end

--- 每 tick 清理 (TS updateCommissionOrders: 无 rng)
function M.update()
    local now = os.time()
    local toRemove = {}
    for i, o in ipairs(orders) do
        if o.status == "open" and now - o.updatedAt > OPEN_ORDER_EXPIRE then
            o.status = "expired"
            o.updatedAt = now
        elseif o.status ~= "open" and now - o.updatedAt > TERMINAL_RETAIN then
            toRemove[i] = true
        end
    end
    for i = #orders, 1, -1 do
        if toRemove[i] then table.remove(orders, i) end
    end
end

--- 获取开放订单
function M.getOpenOrders()
    local open = {}
    for _, o in ipairs(orders) do
        if o.status == "open" then table.insert(open, o) end
    end
    return open
end

return M
