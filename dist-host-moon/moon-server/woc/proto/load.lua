-- World of ClaudeCraft — Proto Loader (Complete Data Tables)
-- Loads ALL content JSON files exported from src/sim/data.ts

local json = require("json")
local M = {}

local loaded = false

local ALL_FILES = {
    "abilities", "items", "classes", "quests", "quest_order", "mobs",
    "npcs", "camps", "zones", "gather_nodes", "roads", "dungeons",
    "delves", "item_sets", "props", "mounts", "dungeon_layouts",
}

function M.load()
    if loaded then return true end
    local dataDir = "proto/"

    for _, name in ipairs(ALL_FILES) do
        M[name] = M.loadFile(dataDir .. name .. ".json")
        if M[name] then
            local n = 0
            for _ in pairs(M[name]) do n = n + 1 end
            if #M[name] > 0 then n = #M[name] end
            print(string.format("[Proto] Loaded %s (%d entries)", name, n))
        else
            print(string.format("[Proto] WARN %s not found", name))
        end
    end

    M.buildIndexes()
    loaded = true
    return true
end

function M.loadFile(path)
    local f, err = io.open(path, "r")
    if not f then return nil end
    local content = f:read("*all"); f:close()
    if not content or #content == 0 then return nil end
    local ok, decoded = pcall(json.decode, content)
    if not ok then return nil end
    return decoded
end

function M.buildIndexes()
    -- abilities: organized by class
    M.abilitiesById = {}
    if M.abilities then
        for cls, clsAbilities in pairs(M.abilities) do
            for id, def in pairs(clsAbilities) do
                M.abilitiesById[id] = def
            end
        end
    end

    M.itemsById = M.items or {}
    M.classesById = M.classes or {}
    M.mobsById = M.mobs or {}
    M.itemSetsById = M.item_sets or {}
    M.npcsById = M.npcs or {}
    M.mountsById = M.mounts or {}

    -- quests (array → byId map)
    M.questsById = {}
    if M.quests then
        for _, q in ipairs(M.quests) do
            M.questsById[q.id] = q
        end
    end

    -- dungeons (already keyed by id)
    M.dungeonsById = M.dungeons or {}
end

--- Lookup helpers
function M.getItem(id) return (M.itemsById or {})[id] end
function M.getClass(id) return (M.classesById or {})[id] end
function M.getAbility(id) return (M.abilitiesById or {})[id] end
function M.getQuest(id) return (M.questsById or {})[id] end
function M.getMob(templateId) return (M.mobsById or {})[templateId] end
function M.getNpc(id) return (M.npcsById or {})[id] end
function M.getAbilitiesForClass(cls) return M.abilities and M.abilities[cls] end
function M.getDungeons() return M.dungeons end
function M.getDungeon(id) return (M.dungeons or {})[id] end
function M.getItemSets() return M.itemSetsById end
function M.getItemSet(id) return (M.itemSetsById or {})[id] end
function M.getMounts() return M.mountsById end
function M.getMount(id) return (M.mountsById or {})[id] end
function M.getProps() return M.props end
function M.getDungeonLayouts() return M.dungeon_layouts end
function M.getDungeonLayout(interior) return (M.dungeon_layouts or {})[interior] end
function M.getCamps() return M.camps end
function M.getZones() return M.zones end
function M.getGatherNodes() return M.gather_nodes end
function M.getRoads() return M.roads end

return M
