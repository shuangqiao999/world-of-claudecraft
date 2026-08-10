-- World of ClaudeCraft — World Static Colliders
-- 对应原项目 src/sim/colliders.ts staticWorldColliders
-- 启动时从 content 注册: PROPS (建筑/摊位/井/板条箱/码头) + 装饰 (岩石/树) + 街灯

local colliders = require("world.colliders")
local terrain = require("world.terrain")
local M = {}

local registered = false

-- 岩石碰撞最小 scale (TS ROCK_COLLIDER_MIN_SCALE)
local ROCK_COLLIDER_MIN_SCALE = 0.9

-- 树冠高度 (全高树干, 树冠不阻挡)
local TREE_TRUNK_RADIUS_MULT = 0.55

-- 街灯间距
local STREETLAMP_SPACING = 14

--- 注册一个 prop 碰撞体 (TS: buildings 全高 OBB, stalls 可站立, wells/crates 圆)
local function registerProp(prop, kind)
    if kind == "buildings" or kind == "tents" or kind == "docks" then
        -- 全高 OBB
        colliders.addCollider({
            type = "obb", x = prop.x, z = prop.z,
            hw = (prop.w or 4) / 2, hd = (prop.d or 4) / 2,
            rot = prop.rot or 0,
        })
    elseif kind == "stalls" or kind == "benches" then
        -- 可站立 OBB
        colliders.addCollider({
            type = "obb", x = prop.x, z = prop.z,
            hw = (prop.w or 3) / 2, hd = (prop.d or 2) / 2,
            rot = prop.rot or 0,
            standable = true, moveTopY = 1.0,
        })
    elseif kind == "wells" or kind == "mines" or kind == "marshReeds" then
        -- 全高圆 (trunk/base)
        colliders.addCollider({
            type = "circle", x = prop.x, z = prop.z, r = prop.r or 1.5,
        })
    elseif kind == "crates" then
        -- 可站立圆
        colliders.addCollider({
            type = "circle", x = prop.x, z = prop.z, r = prop.r or 1.0,
            standable = true, moveTopY = 1.35,  -- CRATE_TOP
        })
    end
end

--- 生成并注册装饰碰撞体 (岩石/树) — 按查询区域惰性注册会在物理层做, 这里注册一份静态集
local function registerDecorations(seed)
    -- 世界范围太大, 只注册起始区域附近 (Eastbrook 周边 ±600)
    local decos = terrain.generateDecorationsInBounds(-600, -600, 600, 600)
    for _, d in ipairs(decos) do
        if d.kind == "rock" and d.scale >= ROCK_COLLIDER_MIN_SCALE then
            colliders.addCollider({
                type = "circle", x = d.x, z = d.z, r = 0.5 + d.scale * 0.3,
                standable = true, moveTopY = d.scale * 0.7,
            })
        elseif d.kind == "tree" then
            colliders.addCollider({
                type = "circle", x = d.x, z = d.z, r = TREE_TRUNK_RADIUS_MULT * d.scale,
            })
        end
    end
    return #decos
end

--- 注册街灯碰撞体 (沿道路 polyline)
local function registerStreetlamps(seed)
    local ok, proto = pcall(function() return require("proto.load") end)
    if not ok then return 0 end
    local roads = proto.getRoads()
    if not roads then return 0 end

    local count = 0
    for _, road in ipairs(roads) do
        if type(road) == "table" then
            for i = 1, #road - 1 do
                local a, b = road[i], road[i + 1]
                local len = math.sqrt((b.x - a.x)^2 + (b.z - a.z)^2)
                local steps = math.floor(len / STREETLAMP_SPACING)
                for s = 1, steps do
                    local t = s / math.max(1, steps)
                    local x = a.x + (b.x - a.x) * t
                    local z = a.z + (b.z - a.z) * t
                    colliders.addCollider({
                        type = "circle", x = x, z = z, r = 0.3,
                    })
                    count = count + 1
                end
            end
        end
    end
    return count
end

--- 注册全部世界碰撞体 (world 启动时调用)
function M.registerAll(seed)
    if registered then return end

    local counts = { props = 0, decos = 0, lamps = 0 }

    -- PROPS (从 proto/props.json)
    local ok, proto = pcall(function() return require("proto.load") end)
    if ok then
        local props = proto.getProps()
        if props then
            for kind, list in pairs(props) do
                if type(list) == "table" then
                    for _, prop in ipairs(list) do
                        registerProp(prop, kind)
                        counts.props = counts.props + 1
                    end
                end
            end
        end
    end

    -- 装饰
    counts.decos = registerDecorations(seed)

    -- 街灯
    counts.lamps = registerStreetlamps(seed)

    registered = true
    print(string.format("[Colliders] Registered props=%d decos=%d streetlamps=%d total=%d",
        counts.props, counts.decos, counts.lamps, colliders.count()))
end

--- 重置
function M.reset()
    registered = false
    colliders.clearColliders()
end

return M
