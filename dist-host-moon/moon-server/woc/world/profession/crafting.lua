-- World of ClaudeCraft — Profession System
-- harvest_node, craft_item (从 proto/recipes.json 加载配方)

local M = {}

-- 采集点数据
local NODES = {
    herb = { name = "Herb", skill = "herbalism", minSkill = 1, xp = 10, item = "Herb" },
    ore = { name = "Ore", skill = "mining", minSkill = 1, xp = 10, item = "Ore" },
    wood = { name = "Wood", skill = "woodcutting", minSkill = 1, xp = 10, item = "Wood" },
}

-- 制造配方 (从 proto/recipes.json 加载)
local RECIPES = {}
local recipesLoaded = false

function M.loadFromProto()
    if recipesLoaded then return end
    local ok, proto = pcall(function() return require("proto.load") end)
    if not ok then return end
    local recipes = proto.recipesById
    if not recipes then return end
    for rid, r in pairs(recipes) do
        if type(r) == "table" and r.id then
            local reagents = {}
            for _, rg in ipairs(r.reagents or {}) do
                table.insert(reagents, { item = rg.itemId or rg.item, count = rg.count or 1 })
            end
            RECIPES[rid] = {
                id = rid,
                name = r.name or rid,
                skill = r.professionId or "crafting",
                minSkill = r.skillReq or 0,
                xp = 15,
                reagents = reagents,
                result = { id = r.resultItemId, name = r.resultItemId, count = r.resultCount or 1 },
                resultItemId = r.resultItemId,
                resultCount = r.resultCount or 1,
            }
        end
    end
    recipesLoaded = true
    print(string.format("[Crafting] Loaded %d recipes from proto", #RECIPES))
end

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

    -- 检查材料 (TS: reagents 用 itemId 匹配)
    local inv = meta.inventory or {}
    for _, req in ipairs(recipe.reagents) do
        local found = 0
        for slot, item in pairs(inv) do
            if (item.id == req.item) or (item.name == req.item) then found = found + 1 end
        end
        if found < req.count then return false, "Missing reagent: " .. req.item end
    end

    -- 消耗材料
    for _, req in ipairs(recipe.reagents) do
        local toRemove = req.count
        for slot, item in pairs(inv) do
            if (item.id == req.item or item.name == req.item) and toRemove > 0 then
                inv[slot] = nil
                toRemove = toRemove - 1
            end
        end
    end

    -- 制造 (解析 resultItemId → 完整物品)
    local inventory = require("world.inventory")
    local resultItem = recipe.result
    local itemDef = nil
    local okp, proto = pcall(function() return require("proto.load") end)
    if okp and recipe.resultItemId then itemDef = proto.getItem(recipe.resultItemId) end
    if itemDef then
        resultItem = inventory.createItem(recipe.resultItemId, itemDef.name or recipe.resultItemId, itemDef.kind or "misc", itemDef)
    end
    inventory.addItem(meta, resultItem)

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
