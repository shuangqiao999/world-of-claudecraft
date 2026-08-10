-- World of ClaudeCraft — Profession System
-- harvest_node, craft_item, 简化版采集+制造

local M = {}

-- 采集点数据
local NODES = {
    herb = { name = "Herb", skill = "herbalism", minSkill = 1, xp = 10, item = "Herb" },
    ore = { name = "Ore", skill = "mining", minSkill = 1, xp = 10, item = "Ore" },
    wood = { name = "Wood", skill = "woodcutting", minSkill = 1, xp = 10, item = "Wood" },
}

-- 制造配方
local RECIPES = {
    health_potion_brew = { name = "Brew Health Potion", skill = "alchemy", minSkill = 1, xp = 20,
        reagents = { { item = "Herb", count = 2 } }, result = { id = "health_potion", name = "Health Potion", type = "consume", hp = 50, value = 5 } },
    mana_potion_brew = { name = "Brew Mana Potion", skill = "alchemy", minSkill = 1, xp = 20,
        reagents = { { item = "Herb", count = 1 } }, result = { id = "mana_potion", name = "Mana Potion", type = "consume", resource = 50, value = 5 } },
    ingot_smelt = { name = "Smelt Ingot", skill = "blacksmithing", minSkill = 1, xp = 15,
        reagents = { { item = "Ore", count = 2 } }, result = { id = "iron_ingot", name = "Iron Ingot", type = "reagent", value = 3 } },
}

--- 初始化专业技能
function M.initProfessions(meta)
    if not meta.professions then meta.professions = { skills = {}, knownRecipes = {} } end
end

--- 采集节点
function M.harvestNode(meta, entity, nodeType)
    M.initProfessions(meta)
    local node = NODES[nodeType]
    if not node then return false, "Unknown node" end

    -- 增加技能点
    local skills = meta.professions.skills
    skills[node.skill] = (skills[node.skill] or 0) + 1

    -- 给予物品
    local inventory = require("world.inventory")
    local item = { id = node.item.."_"..os.time(), name = node.item, type = "reagent", value = 1 }
    local slot = inventory.addItem(meta, item)

    return true, { item = node.item, skill = node.skill, level = skills[node.skill] }
end

--- 制造物品
function M.craftItem(meta, recipeId)
    M.initProfessions(meta)
    local recipe = RECIPES[recipeId]
    if not recipe then return false, "Unknown recipe" end

    -- 检查材料
    local inv = meta.inventory or {}
    for _, req in ipairs(recipe.reagents) do
        local found = 0
        for slot, item in pairs(inv) do
            if item.name == req.item then found = found + 1 end
        end
        if found < req.count then return false, "Missing reagent: " .. req.item end
    end

    -- 消耗材料
    for _, req in ipairs(recipe.reagents) do
        local toRemove = req.count
        for slot, item in pairs(inv) do
            if item.name == req.item and toRemove > 0 then
                inv[slot] = nil
                toRemove = toRemove - 1
            end
        end
    end

    -- 制造
    local inventory = require("world.inventory")
    inventory.addItem(meta, recipe.result)

    -- 增加技能
    meta.professions.skills[recipe.skill] = (meta.professions.skills[recipe.skill] or 0) + 1

    return true, recipe.result
end

--- 获取配方列表
function M.getRecipes()
    return RECIPES
end

--- 获取节点列表
function M.getNodes()
    return NODES
end

return M
