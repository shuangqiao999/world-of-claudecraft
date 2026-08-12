-- World of ClaudeCraft — 货币分层工具 (铜/银/金)
-- 内部以 copper 整数存储, 此模块提供分层换算与格式化
-- 换算: 100 铜 = 1 银, 100 银 = 1 金 (与客户端 format_money 一致)

local M = {}

M.COPPER_PER_SILVER = 100
M.SILVER_PER_GOLD = 100
M.COPPER_PER_GOLD = 100 * 100 -- 10000

--- 拆分为金/银/铜分量
--- @return gold, silver, copper
function M.split(totalCopper)
    totalCopper = math.floor(totalCopper or 0)
    local gold = math.floor(totalCopper / M.COPPER_PER_GOLD)
    local rem = totalCopper - gold * M.COPPER_PER_GOLD
    local silver = math.floor(rem / M.COPPER_PER_SILVER)
    local copper = rem - silver * M.COPPER_PER_SILVER
    return gold, silver, copper
end

--- 从金/银/铜合成总铜币
function M.fromParts(gold, silver, copper)
    return (gold or 0) * M.COPPER_PER_GOLD + (silver or 0) * M.COPPER_PER_SILVER + (copper or 0)
end

--- 格式化为人类可读字符串 (如 "3g 5s 12c", 空部分省略)
function M.format(totalCopper)
    local g, s, c = M.split(totalCopper)
    local parts = {}
    if g > 0 then table.insert(parts, g .. "g") end
    if s > 0 then table.insert(parts, s .. "s") end
    if c > 0 or #parts == 0 then table.insert(parts, c .. "c") end
    return table.concat(parts, " ")
end

return M
