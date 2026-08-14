-- World of ClaudeCraft — Zone Lookup
-- 从 proto/zones.json 加载区域定义, 按坐标查询当前区域 (TS: zone bands)

local M = {}

local zones = {}
local zonesLoaded = false

function M.loadFromProto()
    if zonesLoaded then return end
    local ok, proto = pcall(function() return require("proto.load") end)
    if not ok then return end
    local raw = proto.zones
    if not raw then return end
    for _, z in ipairs(raw) do
        table.insert(zones, {
            id = z.id,
            name = z.name or z.id,
            zMin = z.zMin or -1000,
            zMax = z.zMax or 1000,
            levelRange = z.levelRange or { 1, 20 },
            biome = z.biome,
            hub = z.hub,
            graveyard = z.graveyard,
            lakes = z.lakes or {},
            pois = z.pois or {},
        })
    end
    zonesLoaded = true
    print(string.format("[Zones] Loaded %d zones from proto", #zones))
end

--- 查询坐标所在区域
function M.getZoneAt(x, z)
    for _, zone in ipairs(zones) do
        if z >= zone.zMin and z <= zone.zMax then
            return zone
        end
    end
    return nil
end

--- 查询坐标所在区域的 POI (最近的)
function M.getPoiAt(x, z, poiId)
    local zone = M.getZoneAt(x, z)
    if not zone then return nil end
    for _, poi in ipairs(zone.pois or {}) do
        if not poiId or poi.id == poiId then
            return poi
        end
    end
    return nil
end

--- 最近 POI (用于 zone name 显示)
function M.nearestPoi(x, z)
    local zone = M.getZoneAt(x, z)
    if not zone or not zone.pois then return nil end
    local best, bestD = nil, math.huge
    for _, poi in ipairs(zone.pois) do
        local dx = (poi.x or 0) - x
        local dz = (poi.z or 0) - z
        local d = dx * dx + dz * dz
        if d < bestD then best, bestD = poi, d end
    end
    return best
end

return M
