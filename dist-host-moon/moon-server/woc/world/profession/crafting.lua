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
    local n = 0; for _ in pairs(RECIPES) do n = n + 1 end
    print(string.format("[Crafting] Loaded %d recipes from proto", n))
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

--- 训练配方 (加入 knownRecipes)
function M.trainRecipe(meta, recipeId)
    M.initProfessions(meta)
    local recipe = RECIPES[recipeId]
    if not recipe then return false, "Unknown recipe" end
    meta.professions.knownRecipes[recipeId] = true
    return true, recipe
end

--- 插槽工具效果
function M.slotToolEffect(meta, professionId, effectId)
    M.initProfessions(meta)
    if not meta.professions.toolEffectSlots then meta.professions.toolEffectSlots = {} end
    local slots = meta.professions.toolEffectSlots
    if not slots[professionId] then slots[professionId] = {} end
    slots[professionId][1] = effectId
    return true
end

--- 充值工具效果 (消耗材料, 刷新次数)
function M.rechargeToolEffect(meta, professionId)
    M.initProfessions(meta)
    local slots = meta.professions.toolEffectSlots
    if not slots or not slots[professionId] then return false, "No tool effect slotted" end
    if (meta.copper or 0) < 10 then return false, "Not enough copper" end
    meta.copper = meta.copper - 10
    return true
end

--- 分解物品 (移除物品, 给予附魔材料)
function M.disenchantItem(meta, itemId)
    local inv = meta.inventory or {}
    for slot, item in pairs(inv) do
        if item.id == itemId or item.name == itemId then
            if item.quality and (item.quality >= 2) then
                local matCount = item.quality
                local inventory = require("world.inventory")
                for i = 1, matCount do
                    inventory.addItem(meta, { id = "dust_" .. os.time() .. "_" .. i,
                        name = "Enchanted Dust", type = "reagent", value = 1 })
                end
            end
            inv[slot] = nil
            return true, { slot = slot, itemId = item.id or itemId }
        end
    end
    return false, "Item not found"
end

--- 应用附魔
function M.applyEnchant(meta, itemId, enchantId, enchSlot)
    local inv = meta.inventory or {}
    for slot, item in pairs(inv) do
        if item.id == itemId or item.name == itemId then
            if not item.enchants then item.enchants = {} end
            item.enchants[enchSlot or 1] = enchantId
            return true, { slot = slot, enchantId = enchantId }
        end
    end
    return false, "Item not found"
end

--- 拆解物品 (回收材料)
function M.salvageItem(meta, itemId)
    local inv = meta.inventory or {}
    for slot, item in pairs(inv) do
        if item.id == itemId or item.name == itemId then
            local inventory = require("world.inventory")
            inv[slot] = nil
            local mats = math.max(1, (item.value or 1) // 2)
            for i = 1, mats do
                inventory.addItem(meta, { id = "scrap_" .. os.time() .. "_" .. i,
                    name = "Salvaged Scrap", type = "reagent", value = 1 })
            end
            return true, { slot = slot, materials = mats }
        end
    end
    return false, "Item not found"
end

--- 解绑物品
function M.unbindItem(meta, itemId)
    if (meta.copper or 0) < 50 then return false, "Not enough copper" end
    local inv = meta.inventory or {}
    for slot, item in pairs(inv) do
        if item.id == itemId or item.name == itemId then
            item.bound = nil
            item.soulbound = nil
            meta.copper = meta.copper - 50
            return true, { slot = slot }
        end
    end
    return false, "Item not found"
end

--- 放置移动工作台
function M.placeMobileStation(meta, craftId)
    if not meta.mobileStations then meta.mobileStations = {} end
    meta.mobileStations[craftId] = { at = os.time(), craftId = craftId }
    return true
end

return M
