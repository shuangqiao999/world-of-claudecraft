-- World of ClaudeCraft — Static Collider Registry
-- 对应原项目 src/sim/colliders.ts (网格 broadphase + supportHeightAt + resolvePosition)
-- 挤出 2D 几何: 圆/OBB, 从地面升到已知 top (moveTopY, 缺省 = 全高)

local M = {}

-- 常量
M.MANTLE_REACH = 0.9
M.SUPPORT_OVERLAP = 0.5
M.SIGHT_HEIGHT = 1.6
local GRID_CELL = 16

-- 碰撞体集合: colliders = { {type="circle", x,z,r, standable, moveTopY, gridIndex}, ... }
local colliders = {}

-- 网格索引: cellKey → { collider, ... }
local grid = {}
-- 去重 stamp 缓冲
local stamps = {}
local stampCounter = 0

--- 打包整数网格键 (TS cellKey)
local function cellKey(cx, cz)
    local ix = math.floor(cx / GRID_CELL)
    local iz = math.floor(cz / GRID_CELL)
    -- 有符号到无符号打包
    local ux = ix < 0 and (ix + 0x10000) or ix
    local uz = iz < 0 and (iz + 0x10000) or iz
    return ux * 0x10000 + uz
end

--- 注册碰撞体 (world 内容构建时调用)
function M.addCollider(c)
    c.gridIndex = cellKey(c.x, c.z)
    table.insert(colliders, c)
    local key = c.gridIndex
    if not grid[key] then grid[key] = {} end
    table.insert(grid[key], c)
end

--- 清空碰撞体
function M.clearColliders()
    colliders = {}
    grid = {}
    stamps = {}
end

--- 碰撞体采样 top (倾斜顶: 在查询点采样)
function M.colliderTopAt(c, x, z)
    if c.topSlope then
        -- 简化: 锥/脊顶按距中心比例插值 (无 content 时通常无 topSlope)
        return c.moveTopY or math.huge
    end
    return c.moveTopY or math.huge
end

--- 最高可站立 top ≤ maxY (TS supportHeightAt)
function M.supportHeightAt(seed, x, z, r, maxY)
    local best = -math.huge
    local reachR = r * M.SUPPORT_OVERLAP
    for _, c in ipairs(colliders) do
        if c.standable and c.moveTopY ~= nil then
            local inReach = false
            if c.type == "circle" then
                local dx = x - c.x
                local dz = z - c.z
                local reach = c.r + reachR
                inReach = dx * dx + dz * dz < reach * reach
            else
                -- OBB 简化: AABB 判定
                local lx = math.abs(x - c.x)
                local lz = math.abs(z - c.z)
                inReach = lx < c.hw + reachR and lz < c.hd + reachR
            end
            if inReach then
                local top = M.colliderTopAt(c, x, z)
                if top > maxY + 1e-3 then goto continue_c end
                if top > best then best = top end
            end
            ::continue_c::
        end
    end
    return best
end

--- 区域宽相位查询 (TS queryOpenWorldColliders)
--- @param minX,minZ,maxX,maxZ 范围
--- @param out table 追加输出
function M.queryOpenWorldColliders(seed, minX, minZ, maxX, maxZ, out)
    local minKeyX = math.floor(minX / GRID_CELL)
    local maxKeyX = math.floor(maxX / GRID_CELL)
    local minKeyZ = math.floor(minZ / GRID_CELL)
    local maxKeyZ = math.floor(maxZ / GRID_CELL)
    stampCounter = stampCounter + 1
    local stamp = stampCounter
    for ix = minKeyX, maxKeyX do
        for iz = minKeyZ, maxKeyZ do
            local key = cellKey(ix * GRID_CELL, iz * GRID_CELL)
            local cell = grid[key]
            if cell then
                for _, c in ipairs(cell) do
                    if stamps[c] ~= stamp then
                        stamps[c] = stamp
                        table.insert(out, c)
                    end
                end
            end
        end
    end
end

--- 位置解析 (滑动) — TS resolvePosition 简化: 逐碰撞体推出
function M.resolvePosition(seed, x, z, r, ignoreFences)
    r = r or 0.5
    local px, pz = x, z
    for iter = 1, 4 do
        local moved = false
        for _, c in ipairs(colliders) do
            if ignoreFences and c.type == "obb" and c.isFence then goto continue_c end
            -- 粗略距离检查
            local reach = c.type == "circle" and (c.r + r) or (c.hw + c.hd + r)
            local dx = px - c.x
            local dz = pz - c.z
            if dx * dx + dz * dz < reach * reach then
                local ok, nx, nz, depth = M._overlapPush(c, px, pz, r)
                if ok then
                    px = px + nx * (depth + 0.01)
                    pz = pz + nz * (depth + 0.01)
                    moved = true
                end
            end
            ::continue_c::
        end
        if not moved then break end
    end
    return { x = px, z = pz }
end

--- 最小平移推出 (内部)
function M._overlapPush(c, x, z, r)
    if c.type == "circle" then
        local dx = x - c.x
        local dz = z - c.z
        local min = c.r + r
        local d2 = dx * dx + dz * dz
        if d2 >= min * min then return false end
        local d = math.sqrt(d2)
        if d < 1e-9 then return true, 1, 0, min end
        return true, dx / d, dz / d, min - d
    end
    local lx = math.abs(x - c.x)
    local lz = math.abs(z - c.z)
    local ex = c.hw + r
    local ez = c.hd + r
    if lx >= ex or lz >= ez then return false end
    local px = ex - lx
    local pz = ez - lz
    if px <= pz then
        return true, (x - c.x > 0 and 1 or -1), 0, px
    end
    return true, 0, (z - c.z > 0 and 1 or -1), pz
end

--- 碰撞体数量
function M.count()
    return #colliders
end

return M
