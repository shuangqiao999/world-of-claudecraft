-- World of ClaudeCraft — Guild Bank System
-- 公会金库: 共享仓库, 物品/金币存取, 官员权限
-- 对应原项目 src/sim/guild_bank.ts

local M = {}

-- 公会金库: { guildId = { id, name, gold = 0, items = {}, totalSlots = 10, purchasedSlots = 0, log = {} } }
local guildBanks = {}

local DEFAULT_SLOTS = 10
local SLOT_EXPANSION_COST = 50  -- 每扩展一格 cost 50 copper
local GUILD_BANK_EDIT_RANKS = { 0 }  -- leader only
local GUILD_BANK_LOG_LIMIT = 50

-- 日志序号 (TS bank_ledger id 单调递增)
local logSeq = 1

--- 追加公会金库日志 (TS guild_bank_log append-only)
local function appendLog(bank, op, actor, itemId, count, copper)
    if not bank.log then bank.log = {} end
    table.insert(bank.log, {
        id = logSeq,
        at = os.time() * 1000,
        op = op,
        actor = actor or nil,
        itemId = itemId or nil,
        count = count or nil,
        copper = copper or nil,
    })
    logSeq = logSeq + 1
    if #bank.log > GUILD_BANK_LOG_LIMIT then table.remove(bank.log, 1) end
end

--- 创建公会金库
function M.createGuildBank(guildId, guildName)
    guildBanks[guildId] = {
        id = guildId,
        name = guildName,
        gold = 0,
        items = {},
        totalSlots = DEFAULT_SLOTS,
        purchasedSlots = 0,
    }
end

--- 删除公会金库 (公会解散时)
function M.deleteGuildBank(guildId)
    guildBanks[guildId] = nil
end

--- 存入金币
function M.depositGold(guildId, pid, amount, playerRank, actorName)
    local bank = guildBanks[guildId]
    if not bank then return false, "Bank not found" end
    if amount <= 0 then return false, "Invalid amount" end
    bank.gold = bank.gold + amount
    appendLog(bank, "deposit_gold", actorName, nil, nil, amount)
    return true, bank.gold
end

--- 取出金币 (官员以上)
function M.withdrawGold(guildId, pid, amount, playerRank, actorName)
    local bank = guildBanks[guildId]
    if not bank then return false, "Bank not found" end
    if playerRank and not M._canEdit(playerRank) then return false, "Not authorized" end
    if amount <= 0 or bank.gold < amount then return false, "Insufficient gold" end
    bank.gold = bank.gold - amount
    appendLog(bank, "withdraw_gold", actorName, nil, nil, amount)
    return true, amount
end

--- 存入物品
function M.depositItem(guildId, pid, item, playerRank, actorName)
    local bank = guildBanks[guildId]
    if not bank then return false, "Bank not found" end
    if #bank.items >= bank.totalSlots then return false, "Bank full" end
    table.insert(bank.items, item)
    appendLog(bank, "deposit", actorName, item and item.id, 1, nil)
    return true
end

--- 取出物品 (官员以上)
function M.withdrawItem(guildId, pid, slotIndex, playerRank, actorName)
    local bank = guildBanks[guildId]
    if not bank then return false, "Bank not found" end
    if playerRank and not M._canEdit(playerRank) then return false, "Not authorized" end
    if slotIndex < 1 or slotIndex > #bank.items then return false, "Invalid slot" end
    local item = table.remove(bank.items, slotIndex)
    appendLog(bank, "withdraw", actorName, item and item.id, 1, nil)
    return true, item
end

--- 扩展银行槽位
function M.buySlots(guildId, pid, count, playerRank, actorName)
    local bank = guildBanks[guildId]
    if not bank then return false, "Bank not found" end
    if playerRank and not M._canEdit(playerRank) then return false, "Not authorized" end
    bank.totalSlots = bank.totalSlots + count
    bank.purchasedSlots = bank.purchasedSlots + count
    appendLog(bank, "buy_slots", actorName, nil, nil, SLOT_EXPANSION_COST * count)
    return true, bank.totalSlots
end

--- 获取金库信息
function M.getBankInfo(guildId)
    return guildBanks[guildId]
end

--- 获取金库活动日志 (TS guild_bank_log 一次性 gbanklog 帧数据)
function M.getLog(guildId)
    local bank = guildBanks[guildId]
    if not bank or not bank.log then return {} end
    local out = {}
    for _, e in ipairs(bank.log) do
        table.insert(out, {
            id = e.id,
            at = e.at,
            actor = e.actor,
            op = e.op,
            itemId = e.itemId,
            count = e.count,
            copper = e.copper,
        })
    end
    return out
end

--- 检查是否可编辑
function M._canEdit(rank)
    for _, r in ipairs(GUILD_BANK_EDIT_RANKS) do
        if r == rank then return true end
    end
    return false
end

--- 序列化 (保存到 world_state)
function M.serialize(guildId)
    local bank = guildBanks[guildId]
    if not bank then return nil end
    return {
        gold = bank.gold,
        items = bank.items,
        totalSlots = bank.totalSlots,
        purchasedSlots = bank.purchasedSlots,
    }
end

--- 反序列化 (从 world_state 加载)
function M.deserialize(guildId, guildName, data)
    guildBanks[guildId] = {
        id = guildId,
        name = guildName,
        gold = data.gold or 0,
        items = data.items or {},
        totalSlots = data.totalSlots or DEFAULT_SLOTS,
        purchasedSlots = data.purchasedSlots or 0,
    }
end

return M
