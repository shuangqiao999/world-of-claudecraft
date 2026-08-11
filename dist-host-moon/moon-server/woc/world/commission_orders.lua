-- World of ClaudeCraft — Commission Order Board
-- 对应原项目 src/sim/sim.ts updateCommissionOrders (issue #1298)
-- 过期开放订单清理 + 终态订单保留窗口

local M = {}

-- 开放订单保留 (秒)
local OPEN_ORDER_EXPIRE = 7 * 24 * 3600
-- 终态订单保留 (秒)
local TERMINAL_RETAIN = 24 * 3600

-- orders: { {id, status="open"|"complete"|"cancelled"|"expired", updatedAt, ownerPid, crafterPid, recipeId, scope} }
local orders = {}
local nextId = 1

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

--- 创建佣金订单
function M.openOrder(meta, recipeId, scope)
    local id = nextId; nextId = nextId + 1
    local order = {
        id = id,
        status = "open",
        updatedAt = os.time(),
        ownerPid = meta.charId,
        ownerName = meta.name,
        recipeId = recipeId,
        scope = scope or "public",
        crafterPid = nil,
        crafterName = nil,
    }
    table.insert(orders, order)
    return id
end

--- 取消佣金订单
function M.cancelOrder(orderId, pid)
    for _, o in ipairs(orders) do
        if o.id == orderId then
            if o.ownerPid and o.ownerPid ~= pid then return false, "Not your order" end
            if o.status ~= "open" then return false, "Order already " .. o.status end
            o.status = "cancelled"
            o.updatedAt = os.time()
            return true
        end
    end
    return false, "Order not found"
end

--- 接受佣金订单
function M.acceptOrder(orderId, pid, crafterName)
    for _, o in ipairs(orders) do
        if o.id == orderId then
            if o.status ~= "open" then return false, "Order not open" end
            if o.crafterPid then return false, "Already claimed" end
            o.crafterPid = pid
            o.crafterName = crafterName
            return true, o
        end
    end
    return false, "Order not found"
end

--- 完成佣金订单 (交付)
function M.deliverOrder(orderId, pid)
    for _, o in ipairs(orders) do
        if o.id == orderId then
            if o.crafterPid and o.crafterPid ~= pid then return false, "Not your order" end
            if o.status ~= "open" then return false, "Order already " .. o.status end
            o.status = "complete"
            o.updatedAt = os.time()
            return true, o
        end
    end
    return false, "Order not found"
end

return M
