-- World of ClaudeCraft — Swept-Volume Collision Math
-- 对应原项目 src/sim/physics/sweep.ts (纯函数, 无状态, 无 rng)
-- 连续时击 (TOI): 运动体圆 vs 世界静态圆/OBB

local M = {}

local m3d = require("world.math3d")

-- 接触间隙 (防止下一 tick 的 sweep 从表面开始)
M.SKIN_WIDTH = 0.01
local MIN_MOTION = 1e-9

-- scratch (无分配热路径)
local localStart = { x = 0, z = 0 }
local localDelta = { x = 0, z = 0 }
local worldNormal = { x = 0, z = 0 }

-- 世界偏移旋转进 OBB 局部坐标系 (three.js rotation.y 约定)
local function rotYInto(lx, lz, rot, out)
    local c = math.cos(rot)
    local s = math.sin(rot)
    out.x = lx * c + lz * s
    out.z = -lx * s + lz * c
end

-- 点 (px,pz) 以 (dx,dz) 运动 vs 半径 R 圆 (Minkowski 和) 的 TOI
local function sweepPointCircle(px, pz, dx, dz, cx, cz, R, out)
    local fx = px - cx
    local fz = pz - cz
    local c = fx * fx + fz * fz - R * R
    if c <= 0 then
        local d = m3d.dist(fx, fz)
        out.t = 0
        out.nx = d > 1e-9 and fx / d or 1
        out.nz = d > 1e-9 and fz / d or 0
        return true
    end
    local a = dx * dx + dz * dz
    if a < MIN_MOTION then return false end
    local b = 2 * (fx * dx + fz * dz)
    if b >= 0 then return false end
    local disc = b * b - 4 * a * c
    if disc < 0 then return false end
    local t = (-b - math.sqrt(disc)) / (2 * a)
    if t < 0 or t > 1 then return false end
    local hx = px + dx * t - cx
    local hz = pz + dz * t - cz
    local hl = m3d.dist(hx, hz)
    out.t = t
    out.nx = hl > 1e-9 and hx / hl or 1
    out.nz = hl > 1e-9 and hz / hl or 0
    return true
end

--- 体圆 vs 单个碰撞体的 TOI (Minkowski 和, OBB 圆角矩形)
--- @return boolean 是否命中; out {t, nx, nz}
function M.sweepCollider(c, x, z, dx, dz, r, out)
    if c.type == "circle" then
        return sweepPointCircle(x, z, dx, dz, c.x, c.z, c.r + r, out)
    end

    -- OBB: 局部坐标系中为轴对齐圆角矩形, 范围 (hw+r, hd+r), 角半径 r
    rotYInto(x - c.x, z - c.z, -c.rot, localStart)
    rotYInto(dx, dz, -c.rot, localDelta)
    local ex = c.hw + r
    local ez = c.hd + r
    local sx, sz = localStart.x, localStart.z
    local vx, vz = localDelta.x, localDelta.z

    if math.abs(sx) <= ex and math.abs(sz) <= ez then
        -- 起点在膨胀盒内: 沿最浅轴逃离
        local px = ex - math.abs(sx)
        local pz = ez - math.abs(sz)
        local lnx, lnz
        if px <= pz then lnx = (sx ~= 0 and (sx > 0 and 1 or -1)) or 1; lnz = 0
        else lnx = 0; lnz = (sz ~= 0 and (sz > 0 and 1 or -1)) or 1 end
        rotYInto(lnx, lnz, c.rot, worldNormal)
        out.t = 0
        out.nx = worldNormal.x
        out.nz = worldNormal.z
        return true
    end

    -- 膨胀盒 slab test
    local tEnter, tExit = 0, 1
    local enterAxis, enterSign = 0, 0
    if math.abs(vx) < MIN_MOTION then
        if sx < -ex or sx > ex then return false end
    else
        local inv = 1 / vx
        local t1, t2 = (-ex - sx) * inv, (ex - sx) * inv
        local sign = -1
        if t1 > t2 then t1, t2 = t2, t1; sign = 1 end
        if t1 > tEnter then tEnter = t1; enterAxis = 1; enterSign = sign end
        if t2 < tExit then tExit = t2 end
    end
    if math.abs(vz) < MIN_MOTION then
        if sz < -ez or sz > ez then return false end
    else
        local inv = 1 / vz
        local t1, t2 = (-ez - sz) * inv, (ez - sz) * inv
        local sign = -1
        if t1 > t2 then t1, t2 = t2, t1; sign = 1 end
        if t1 > tEnter then tEnter = t1; enterAxis = 2; enterSign = sign end
        if t2 < tExit then tExit = t2 end
    end
    if tEnter > tExit or tEnter > 1 or tEnter < 0 then return false end

    local hx = sx + vx * tEnter
    local hz = sz + vz * tEnter
    -- 角落区域: 精确圆角 (体半径圆)
    if r > 0 and math.abs(hx) > c.hw and math.abs(hz) > c.hd then
        local cornerX = (hx > 0 and 1 or -1) * c.hw
        local cornerZ = (hz > 0 and 1 or -1) * c.hd
        if not sweepPointCircle(sx, sz, vx, vz, cornerX, cornerZ, r, out) then return false end
        rotYInto(out.nx, out.nz, c.rot, worldNormal)
        out.nx = worldNormal.x
        out.nz = worldNormal.z
        return true
    end

    local lnx = enterAxis == 1 and enterSign or 0
    local lnz = enterAxis == 2 and enterSign or 0
    rotYInto(lnx, lnz, c.rot, worldNormal)
    out.t = tEnter
    out.nx = worldNormal.x
    out.nz = worldNormal.z
    return true
end

--- 最小平移推出 (体圆重叠时)
--- @return boolean 是否重叠; out {nx, nz, depth}
function M.overlapCollider(c, x, z, r, out)
    if c.type == "circle" then
        local dx = x - c.x
        local dz = z - c.z
        local min = c.r + r
        local d2 = m3d.distSq(dx, dz)
        if d2 >= min * min then return false end
        local d = m3d.dist(dx, dz)
        if d < 1e-9 then
            out.nx = 1; out.nz = 0; out.depth = min
            return true
        end
        out.nx = dx / d
        out.nz = dz / d
        out.depth = min - d
        return true
    end
    rotYInto(x - c.x, z - c.z, -c.rot, localStart)
    local ex = c.hw + r
    local ez = c.hd + r
    local lx, lz = localStart.x, localStart.z
    if math.abs(lx) >= ex or math.abs(lz) >= ez then return false end
    local px = ex - math.abs(lx)
    local pz = ez - math.abs(lz)
    local lnx, lnz
    if px <= pz then lnx = (lx ~= 0 and (lx > 0 and 1 or -1)) or 1; lnz = 0
    else lnx = 0; lnz = (lz ~= 0 and (lz > 0 and 1 or -1)) or 1 end
    rotYInto(lnx, lnz, c.rot, worldNormal)
    out.nx = worldNormal.x
    out.nz = worldNormal.z
    out.depth = math.min(px, pz)
    return true
end

return M
