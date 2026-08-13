-- math3d wrapper: C acceleration via clib/math3d.dll, with pure-Lua fallback.
-- Scalar-argument APIs create a temporary vector per call (C alloc + length/dot/cross/lerp).
-- For high-frequency loops prefer re-using pre-allocated vec objects via M.vec3() + M.lib.
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
local lib = nil
M.backend = "lua"

-- 禁用 math3d C 后端: 其 vector() 返回 lightuserdata (无 __gc), 临时向量标记后
-- 永不 unmark, 对象在池中无限累积导致内存暴涨 (玩家加入后 8MB/s)。纯 Lua 回退
-- 无此问题, 性能差异在游戏规模下可忽略。
-- pcall(function()
--     lib = require("math3d")
--     M.backend = "c"
-- end)

-- ===================================================================
-- C-accelerated path
-- ===================================================================
if lib then

    function M.dist(dx, dz)
        local v = lib.vector(dx, 0, dz, 0)
        return lib.length(v)
    end

    function M.distSq(dx, dz)
        return dx * dx + dz * dz
    end

    function M.dist3(dx, dy, dz)
        local v = lib.vector(dx, dy, dz, 0)
        return lib.length(v)
    end

    function M.norm(dx, dz)
        local v = lib.vector(dx, 0, dz, 0)
        local len = lib.length(v)
        if len < 0.0001 then return 0, 0 end
        return dx / len, dz / len
    end

    function M.norm3(dx, dy, dz)
        local v = lib.vector(dx, dy, dz, 0)
        local len = lib.length(v)
        if len < 0.0001 then return 0, 0, 0 end
        return dx / len, dy / len, dz / len
    end

    function M.dirTo(px, pz, tx, tz)
        return M.norm(tx - px, tz - pz)
    end

    function M.facingTo(px, pz, tx, tz)
        return math.atan(tx - px, -(tz - pz))
    end

    function M.moveToward(px, pz, tx, tz, speed, dt)
        local dx = tx - px
        local dz = tz - pz
        local v = lib.vector(dx, 0, dz, 0)
        local dist = lib.length(v)
        if dist < speed * dt then return tx, tz end
        local step = speed * dt
        return px + (dx / dist) * step, pz + (dz / dist) * step
    end

    function M.dot3(ax, ay, az, bx, by, bz)
        local a = lib.vector(ax, ay, az, 0)
        local b = lib.vector(bx, by, bz, 0)
        return lib.dot(a, b)
    end

    function M.cross3(ax, ay, az, bx, by, bz)
        local a = lib.vector(ax, ay, az, 0)
        local b = lib.vector(bx, by, bz, 0)
        local c = lib.cross(a, b)
        local x, y, z = lib.index(c, 1, 2, 3)
        return x, y, z
    end

    function M.lerp3(ax, ay, az, bx, by, bz, t)
        local a = lib.vector(ax, ay, az, 0)
        local b = lib.vector(bx, by, bz, 0)
        local c = lib.lerp(a, b, t)
        local x, y, z = lib.index(c, 1, 2, 3)
        return x, y, z
    end

    -- expose raw math3d for advanced use
    M.lib = lib
    M.vec3 = function(x, y, z) return lib.vector(x, y, z, 0) end
    M.vec4 = function(x, y, z, w) return lib.vector(x, y, z, w or 0) end

else
-- ===================================================================
-- Pure Lua fallback (identical behavior, no C dependency)
-- ===================================================================

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
        return math.atan(tx - px, -(tz - pz))
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

    M.lib = nil
    M.vec3 = nil
    M.vec4 = nil
end

return M
