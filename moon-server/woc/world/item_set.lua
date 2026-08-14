-- World of ClaudeCraft — Item Set Bonuses
-- 对应原项目 src/sim/content/item_sets.ts aggregateSetBonuses
-- 层级堆叠: 穿 4 件得 2+3+4 件效果; 减伤类取最大; 评分求和; procs 收集

local M = {}

local STAT_KEYS = { "str", "agi", "sta", "int", "spi", "ap", "sp", "crit", "critRating", "haste", "hasteRating", "hitRating" }
local MITIGATION_KEYS = { "castPushbackReduction", "knockbackResistance", "ccDurationReduction" }
local PVP_KEYS = { "pvpOffenseRating", "pvpDefenseRating" }

--- 从 proto 加载套装 (已加载 item_sets.json)
local function getSets()
    local ok, proto = pcall(function() return require("proto.load") end)
    if not ok then return {} end
    return proto.getItemSets() or {}
end

--- 聚合套装效果 (TS aggregateSetBonuses)
--- @param setCounts table { setId = count }
--- @return table { stats, mitigation, pvp, procs }
function M.aggregateSetBonuses(setCounts)
    local result = {
        stats = {},
        mitigation = {},
        pvp = {},
        procs = {},
    }
    if not setCounts then return result end

    local sets = getSets()
    for setId, count in pairs(setCounts) do
        local set = sets[setId]
        if set and set.bonuses then
            for _, tier in ipairs(set.bonuses) do
                if count >= tier.pieces and tier.effect then
                    local effect = tier.effect
                    -- 平铺属性求和
                    for _, k in ipairs(STAT_KEYS) do
                        local v = effect[k]
                        if v and v ~= 0 then
                            result.stats[k] = (result.stats[k] or 0) + v
                        end
                    end
                    -- 减伤类取最大并钳制 0..1
                    for _, k in ipairs(MITIGATION_KEYS) do
                        local v = effect[k]
                        if v and v > 0 then
                            result.mitigation[k] = math.min(1, math.max(result.mitigation[k] or 0, v))
                        end
                    end
                    -- PvP 评分求和
                    for _, k in ipairs(PVP_KEYS) do
                        local v = effect[k]
                        if v and v ~= 0 then
                            result.pvp[k] = (result.pvp[k] or 0) + v
                        end
                    end
                    -- proc 收集
                    if effect.proc then
                        table.insert(result.procs, effect.proc)
                    end
                end
            end
        end
    end
    return result
end

--- 获取某件物品的套装 ID
function M.setIdOf(itemId, proto)
    if not proto then proto = require("proto.load") end
    local item = proto.getItem(itemId)
    return item and item.setId or nil
end

return M
