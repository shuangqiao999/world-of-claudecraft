-- math3d — 纯 Lua 标量数学库
--
-- 原 clib/math3d.dll C SIMD 后端已移除: 服务器仿真是 2.5D (x/z 平面 + y 高度),
-- 热点数学是 2D 标量距离/法线, 单次调用下 C 向量对象分配 (lib.vector) + 跨 Lua/C
-- 边界 + GC 的开销高于 Lua 5.4 原生 math.sqrt (math.* 本身是 C 实现), 故标量函数
-- 统一走原生 math.*。
--
-- API:
--   dist(dx,dz)      — 2D distance
--   distSq(dx,dz)    — 2D distance squared (no sqrt, for range checks)
--   dist3(dx,dy,dz)  — 3D distance
--   norm(dx,dz)      — normalize → nx, nz
--   norm3(dx,dy,dz)  — normalize → nx, ny, nz
--   dirTo(px,pz,tx,tz) → nx, nz
--   facingTo(px,pz,tx,tz) → radians
--   moveToward(px,pz,tx,tz,speed,dt) → newX, newZ
--   dot3(ax,ay,az,bx,by,bz) → float
--   cross3(ax,ay,az,bx,by,bz) → cx,cy,cz

local M = {}

function M.dist(dx, dz)
    return math.sqrt(dx * dx + dz * dz)
end

function M.distSq(dx, dz)
    return dx * dx + dz * dz
end

function M.dist3(dx, dy, dz)
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

function M.norm(dx, dz)
    local len = math.sqrt(dx * dx + dz * dz)
    if len < 0.0001 then return 0, 0 end
    return dx / len, dz / len
end

function M.norm3(dx, dy, dz)
    local len = math.sqrt(dx * dx + dy * dy + dz * dz)
    if len < 0.0001 then return 0, 0, 0 end
    return dx / len, dy / len, dz / len
end

function M.dirTo(px, pz, tx, tz)
    return M.norm(tx - px, tz - pz)
end

function M.facingTo(px, pz, tx, tz)
    return math.atan(tx - px, tz - pz)
end

function M.moveToward(px, pz, tx, tz, speed, dt)
    local dx = tx - px
    local dz = tz - pz
    local dist = math.sqrt(dx * dx + dz * dz)
    if dist < speed * dt then return tx, tz end
    local step = speed * dt
    return px + (dx / dist) * step, pz + (dz / dist) * step
end

function M.dot3(ax, ay, az, bx, by, bz)
    return ax * bx + ay * by + az * bz
end

function M.cross3(ax, ay, az, bx, by, bz)
    return ay * bz - az * by, az * bx - ax * bz, ax * by - ay * bx
end

function M.lerp3(ax, ay, az, bx, by, bz, t)
    return ax + (bx - ax) * t, ay + (by - ay) * t, az + (bz - az) * t
end

return M
