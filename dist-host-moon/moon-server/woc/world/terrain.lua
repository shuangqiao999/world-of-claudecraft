-- World of ClaudeCraft — 3D Terrain / Water / Voxel System
-- 地面高度场、水体、隧道 (voxel subtracted)、世界种子
-- 对应原项目 src/sim/world.ts + src/sim/voxel.ts + src/sim/world_seed.ts

local M = {}

local m3d = require("world.math3d")

-- 世界种子 (固定, 确定性) — 与客户端 src/sim/world_seed.ts WORLD_SEED=20061 一致
local WORLD_SEED = require("config").WORLD_SEED

-- 预计算高度表 (Lua→客户端 terrain 对齐): proto/heightmap.json, 5yd 间距, ±50yd 范围
local HMAP_X = {}
local HMAP_Z = {}
local HMAP_POINTS = {}
local HMAP_GRID = 5
local HMAP_LOADED = false
do
    local ok, err = pcall(function()
        local f = io.open("proto/heightmap.json", "r")
        if not f then f = io.open("woc/proto/heightmap.json", "r") end
        if f then
            local raw = f:read("*a"); f:close()
            local jh = require("shared.json_helpers")
            local data = jh.safeDecode(raw)
            if data and data.points and data.zTicks then
                HMAP_Z = data.zTicks
                HMAP_POINTS = data.points
                HMAP_LOADED = true
                print(string.format("[Terrain] Heightmap loaded: %s rows x %d cols, grid=%d", 
                    tostring(HMAP_Z[1] == -50 and "21" or "?"), #HMAP_Z, HMAP_GRID))
            end
        end
    end)
    if not ok or not HMAP_LOADED then
        print("[Terrain] Heightmap NOT loaded, using FBM fallback")
    end
end

-- 水体
local WATER_LEVEL = -4.3

-- 地形参数
local TERRAIN_AMPLITUDE = 8
local TERRAIN_SCALE = 0.008
local TERRAIN_OCTAVES = 4

-- 隧道定义 (手写胶囊体, 从地形中减去)
local TUNNELS = {
    -- 东隧道
    { start = { x = 30, y = -4, z = 0 }, endPos = { x = 30, y = -4, z = 80 }, radius = 3 },
    -- 西隧道
    { start = { x = -30, y = -4, z = 0 }, endPos = { x = -30, y = -4, z = -80 }, radius = 3 },
}

--- 简单 hash 函数 (mulberry32 种子)
local function hash2(x, y)
    local h = WORLD_SEED ~ (x * 374761393 + y * 668265263)
    h = (h ~ (h >> 13)) * 1274126177
    h = (h ~ (h >> 16)) * 1274126177
    h = (h ~ (h >> 16)) & 0xFFFFFFFF
    return h / 0xFFFFFFFF
end

--- 2D 噪声 (value noise)
local function noise2(x, z)
    local ix = math.floor(x)
    local iz = math.floor(z)
    local fx = x - ix
    local fz = z - iz

    -- Smoothstep
    local sx = fx * fx * (3 - 2 * fx)
    local sz = fz * fz * (3 - 2 * fz)

    local n00 = hash2(ix, iz)
    local n10 = hash2(ix + 1, iz)
    local n01 = hash2(ix, iz + 1)
    local n11 = hash2(ix + 1, iz + 1)

    local nx0 = n00 + (n10 - n00) * sx
    local nx1 = n01 + (n11 - n01) * sx

    return nx0 + (nx1 - nx0) * sz
end

--- 分形噪声 (FBM — Fractal Brownian Motion)
local function fbm2(x, z, octaves)
    local value = 0
    local amplitude = 1
    local frequency = 1
    local maxValue = 0

    for i = 1, octaves or TERRAIN_OCTAVES do
        value = value + amplitude * noise2(x * frequency, z * frequency)

        maxValue = maxValue + amplitude
        amplitude = amplitude * 0.5
        frequency = frequency * 2.0
    end

    return value / maxValue
end

--- 获取纯地形高度 (无隧道修正)
function M.terrainHeight(x, z)
    local nx = x * TERRAIN_SCALE
    local nz = z * TERRAIN_SCALE
    local height = (fbm2(nx, nz) - 0.5) * 2 * TERRAIN_AMPLITUDE
    return height
end

--- 高度表查询 (最近邻, 5yd 间隔)
local function heightmapLookup(x, z)
    if not HMAP_LOADED then return nil end
    -- zTicks: [-50,-45,...,0,5,...,50], 1-based Lua array
    local half = (#HMAP_Z - 1) / 2  -- 10 for 21 entries
    local iz = math.floor(z / HMAP_GRID + 0.5) + half + 1  -- convert to 1-based index
    if iz < 1 or iz > #HMAP_Z then return nil end
    local hx = tostring(math.floor(x / HMAP_GRID + 0.5) * HMAP_GRID)
    local row = HMAP_POINTS[hx]
    if not row then return nil end
    return row[iz]
end

--- 获取地面高度 (优先高度表, 回退 FBM)
function M.groundHeight(x, z)
    local h = heightmapLookup(x, z)
    if not h then
        h = M.terrainHeight(x, z)
    end

    -- 检查是否在隧道内 (隧道内返回水底)
    for _, tunnel in ipairs(TUNNELS) do
        local distToTunnel = M._distanceToLineSegment(
            x, z,
            tunnel.start.x, tunnel.start.z,
            tunnel.endPos.x, tunnel.endPos.z
        )

        if distToTunnel < tunnel.radius then
            -- 隧道在该点削去地形, 降至水底
            return tunnel.start.y - tunnel.radius
        end
    end

    return terrainY
end

--- 实体放置高度 (groundHeight + 客户端 visual terrain 偏移)
function M.placementHeight(x, z)
    return M.groundHeight(x, z) + require("config").TERRAIN_Y_OFFSET
end

--- 检查点是否在水中
function M.isUnderwater(pos)
    local groundY = M.groundHeight(pos.x, pos.z)
    -- 水底: 地面低于水面
    if groundY < WATER_LEVEL then
        return pos.y < WATER_LEVEL
    end
    return pos.y < WATER_LEVEL and pos.y < groundY
end

--- 该点是否有水体 (地面低于水线的盆地 = 湖/海)
function M.isInWaterBody(x, z)
    return M.groundHeight(x, z) < WATER_LEVEL
end

--- 获取水面高度
function M.getWaterLevel()
    return WATER_LEVEL
end

--- 检查点是否在隧道内 (voxel density query)
function M.isInTunnel(x, y, z)
    for _, tunnel in ipairs(TUNNELS) do
        local dist2D = M._distanceToLineSegment(
            x, z,
            tunnel.start.x, tunnel.start.z,
            tunnel.endPos.x, tunnel.endPos.z
        )
        -- 垂直范围
        local minY = math.min(tunnel.start.y, tunnel.endPos.y) - tunnel.radius
        local maxY = math.max(tunnel.start.y, tunnel.endPos.y) + tunnel.radius

        if dist2D < tunnel.radius and y >= minY and y <= maxY then
            return true
        end
    end
    return false
end

--- 点到线段的最短距离 (2D)
function M._distanceToLineSegment(px, pz, ax, az, bx, bz)
    local abx = bx - ax
    local abz = bz - az
    local lenSq = abx * abx + abz * abz

    if lenSq < 0.001 then
        local dx = px - ax
        local dz = pz - az
        return m3d.dist(dx, dz)
    end

    local t = math.max(0, math.min(1, ((px - ax) * abx + (pz - az) * abz) / lenSq))
    local cx = ax + t * abx
    local cz = az + t * abz
    local dx = px - cx
    local dz = pz - cz
    return m3d.dist(dx, dz)
end

--- 检查该点是否为可行走表面 (斜率 < 30 度)
function M.isWalkable(x, z)
    local h = M.groundHeight(x, z)
    local hx = M.groundHeight(x + 1, z)
    local hz = M.groundHeight(x, z + 1)
    local slopeX = math.abs(hx - h) / 1.0
    local slopeZ = math.abs(hz - h) / 1.0
    local maxSlope = math.tan(math.rad(30))
    return slopeX < maxSlope and slopeZ < maxSlope
end

-- TS STEEPNESS_SAMPLE = 0.35 yards
local STEEPNESS_SAMPLE = 0.35

--- 地形陡峭度 (TS terrainSteepness: 中心差分梯度)
function M.terrainSteepness(x, z)
    local e = STEEPNESS_SAMPLE
    local hx = (M.groundHeight(x + e, z) - M.groundHeight(x - e, z)) / (2 * e)
    local hz = (M.groundHeight(x, z + e) - M.groundHeight(x, z - e)) / (2 * e)
    return m3d.dist(hx, hz)
end

-- 陡峭度缓存 (TS terrainSteepnessAt: 1 码格 memo)
local steepMemo = {}
local STEEP_CAP = 400000

function M.terrainSteepnessAt(x, z)
    local ix = math.floor(x + 0.5)
    local iz = math.floor(z + 0.5)
    local key = ix * 100000 + iz
    local v = steepMemo[key]
    if v ~= nil then return v end
    if next(steepMemo) and #steepMemo >= STEEP_CAP then
        steepMemo = {}
    end
    local s = M.terrainSteepness(x, z)
    steepMemo[key] = s
    return s
end

--- 下坡单位方向 (TS terrainDownhill: 中心差分)
function M.terrainDownhill(x, z)
    local e = STEEPNESS_SAMPLE
    local hx = (M.groundHeight(x + e, z) - M.groundHeight(x - e, z)) / (2 * e)
    local hz = (M.groundHeight(x, z + e) - M.groundHeight(x, z - e)) / (2 * e)
    local len = m3d.dist(hx, hz)
    if len < 1e-6 then return nil end
    return { x = -hx / len, z = -hz / len }
end

--- 墙立面环形采样微调 (TS terrainWallStandoffPass)
function M.terrainWallStandoffPass(x, z, radius, maxSlope)
    local px, pz = x, z
    local best, bestSlope = nil, maxSlope
    local angles = { 0, math.pi / 2, math.pi, math.pi * 3 / 2, math.pi / 4, math.pi * 3 / 4, math.pi * 5 / 4, math.pi * 7 / 4 }
    for _, a in ipairs(angles) do
        local sx = x + math.cos(a) * radius
        local sz = z + math.sin(a) * radius
        local sl = M.terrainSteepnessAt(sx, sz)
        if sl < bestSlope then
            bestSlope = sl
            best = { x = sx, z = sz }
        end
    end
    return best or { x = px, z = pz }
end

--- 墙立面微调 (TS terrainWallStandoff: 至多 3 次迭代, 上限一个体半径)
function M.terrainWallStandoff(x, z, radius, maxSlope)
    local px, pz = x, z
    for i = 1, 3 do
        local n = M.terrainWallStandoffPass(px, pz, radius, maxSlope)
        if math.abs(n.x - px) < 1e-4 and math.abs(n.z - pz) < 1e-4 then break end
        px, pz = n.x, n.z
    end
    local dx = px - x
    local dz = pz - z
    local d = m3d.dist(dx, dz)
    if d > radius then
        local k = radius / d
        px = x + dx * k
        pz = z + dz * k
    end
    return { x = px, z = pz }
end

--- 获取世界种子
function M.getWorldSeed()
    return WORLD_SEED
end

-- === 确定性装饰生成 (TS world.ts generateDecorations, DECORATION_STEP=10) ===
local DECORATION_STEP = 10

--- 生成指定范围内的装饰 (rocks/trees), 确定性
--- @param minX,minZ,maxX,maxZ 范围
--- @return table { {kind, x, z, scale}, ... }
function M.generateDecorationsInBounds(minX, minZ, maxX, maxZ)
    local out = {}
    local gx0 = math.floor(minX / DECORATION_STEP) - 1
    local gx1 = math.floor(maxX / DECORATION_STEP) + 1
    local gz0 = math.floor(minZ / DECORATION_STEP) - 1
    local gz1 = math.floor(maxZ / DECORATION_STEP) + 1
    for gx = gx0, gx1 do
        for gz = gz0, gz1 do
            local cx = gx * DECORATION_STEP
            local cz = gz * DECORATION_STEP
            -- 确定性 hash 决定是否生成 + 类型 + 抖动
            local h = hash2(gx, gz)
            local density = h  -- 0..1
            if density > 0.35 then  -- 65% 格有装饰
                local x = cx + (hash2(gx * 7 + 1, gz * 13) - 0.5) * 10
                local z = cz + (hash2(gx * 3 + 5, gz * 11) - 0.5) * 10
                local kindRoll = hash2(gx * 17, gz * 19)
                local kind = kindRoll < 0.6 and "tree" or "rock"
                local scale = 0.7 + hash2(gx * 23, gz * 29) * 1.0
                -- 避开水体
                if M.groundHeight(x, z) > WATER_LEVEL then
                    table.insert(out, { kind = kind, x = x, z = z, scale = scale })
                end
            end
        end
    end
    return out
end

--- 全量装饰 (超大范围 — 谨慎使用, 一般用 InBounds)
function M.generateDecorations()
    return M.generateDecorationsInBounds(-2000, -2000, 2000, 2000)
end

return M
