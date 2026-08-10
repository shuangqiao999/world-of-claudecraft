-- World of ClaudeCraft — Heroic Dungeon System
-- 英雄副本: 难度/掉落/英雄标记/军需官
-- 对应原项目 src/sim/instances/difficulty.ts + src/sim/instances/heroic_vendor.ts

local M = {}

-- 英雄难度配置
local HEROIC_HP_MULT = 1.5
local HEROIC_DMG_MULT = 1.3
local HEROIC_LEVEL_OFFSET = 2  -- Boss 等级 +2
local HEROIC_MARKS_PER_BOSS = 1
local HEROIC_MAX_MARKS_PER_DAY = 5

-- 英雄标记追踪
local heroicMarks = {}     -- { characterId = marks }
local dailyMarkLimit = {}  -- { characterId = { dateStr = count } }

--- 设置副本难度
function M.setDifficulty(dungeonId, difficulty)
    -- 简化: 存储难度配置
    return true
end

--- 获取英雄缩放
function M.getHeroicScale(isHeroic)
    if not isHeroic then return { hpMult = 1, dmgMult = 1, levelOffset = 0 } end
    return {
        hpMult = HEROIC_HP_MULT,
        dmgMult = HEROIC_DMG_MULT,
        levelOffset = HEROIC_LEVEL_OFFSET,
    }
end

--- 奖励英雄标记
function M.awardHeroicMarks(characterId, bossCount)
    if not heroicMarks[characterId] then heroicMarks[characterId] = 0 end

    local today = os.date("%Y%m%d")
    if not dailyMarkLimit[characterId] then
        dailyMarkLimit[characterId] = {}
    end

    local daily = dailyMarkLimit[characterId]
    if daily.date ~= today then
        daily.date = today
        daily.count = 0
    end

    local marksToAward = math.min(bossCount * HEROIC_MARKS_PER_BOSS,
        HEROIC_MAX_MARKS_PER_DAY - daily.count)
    if marksToAward <= 0 then return 0 end

    heroicMarks[characterId] = heroicMarks[characterId] + marksToAward
    daily.count = daily.count + marksToAward

    return marksToAward
end

--- 获取英雄标记数量
function M.getMarks(characterId)
    return heroicMarks[characterId] or 0
end

--- 消费英雄标记
function M.spendMarks(characterId, amount)
    local marks = heroicMarks[characterId] or 0
    if marks < amount then return false end
    heroicMarks[characterId] = marks - amount
    return true
end

--- 军需官商店
local HEROIC_VENDOR_ITEMS = {
    { itemId = "heroic_trinket", name = "Heroic Trinket", cost = 3,
      stats = { str = 5, agi = 5, sta = 5, int = 5, spi = 5 } },
    { itemId = "heroic_cloak", name = "Heroic Cloak", cost = 5,
      stats = { sta = 8, armor = 15 }, spellPower = 8 },
    { itemId = "heroic_ring", name = "Heroic Ring", cost = 2,
      stats = { sta = 3 }, critRating = 10 },
}

--- 获取军需官商品
function M.getVendorItems()
    return HEROIC_VENDOR_ITEMS
end

--- 购买军需官物品
function M.buyItem(characterId, itemId)
    for _, item in ipairs(HEROIC_VENDOR_ITEMS) do
        if item.itemId == itemId then
            if M.spendMarks(characterId, item.cost) then
                return true, item
            end
            return false, "Not enough heroics"
        end
    end
    return false, "Item not found"
end

return M
