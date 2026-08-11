-- math3d wrapper: C acceleration via clib/math3d.dll, with pure-Lua fallback
-- Provides 2D-optimized convenience functions for the game server's hot paths.
local M = {}
local lib = nil

-- try loading C module
pcall(function()
    lib = require("math3d")
    M._backend = "c"
end)
if not lib then
    M._backend = "lua"
end

--- 2D convenience: distance between two points dx=x2-x1, dz=z2-z1
function M.dist(dx, dz)
    return math.sqrt(dx * dx + dz * dz)
end

--- 2D convenience: distance squared (avoids sqrt, for range checks)
function M.distSq(dx, dz)
    return dx * dx + dz * dz
end

--- 2D convenience: normalize (dx, dz) → (nx, nz), returns normalized components
function M.norm(dx, dz)
    local len = math.sqrt(dx * dx + dz * dz)
    if len < 0.0001 then return 0, 0 end
    return dx / len, dz / len
end

--- 2D convenience: move toward target, returns new px, pz
function M.moveToward(px, pz, tx, tz, speed, dt)
    local dx = tx - px
    local dz = tz - pz
    local dist = math.sqrt(dx * dx + dz * dz)
    if dist < speed * dt then return tx, tz end
    local step = speed * dt
    return px + (dx / dist) * step, pz + (dz / dist) * step
end

--- 2D convenience: direction from (px,pz) to (tx,tz) → (nx, nz)
function M.dirTo(px, pz, tx, tz)
    local dx = tx - px
    local dz = tz - pz
    return M.norm(dx, dz)
end

--- 2D convenience: facing angle from pos to target
function M.facingTo(px, pz, tx, tz)
    return math.atan(tx - px, -(tz - pz))
end

return M
