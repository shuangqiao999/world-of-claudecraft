-- math3d 标量函数测试 — 验证纯 Lua 标量数学正确性
-- Run: bin/moon.exe woc/test_math3d.lua
local m3d = require("world.math3d")
local ok = 0
local fail = 0
local function check(name, cond)
    if cond then ok = ok + 1; print("PASS " .. name)
    else fail = fail + 1; print("FAIL " .. name) end
end

-- Dist
check("dist-simple", math.abs(m3d.dist(3, 4) - 5) < 0.001)
check("dist-3d",  math.abs(m3d.dist3(1, 2, 2) - 3) < 0.001)

-- Norm
do
    local nx, nz = m3d.norm(3, 4)
    check("norm-len",  math.abs(nx*nx + nz*nz - 1) < 0.001)
    check("norm-ratio", math.abs(nx / nz - 3/4) < 0.001)
end
do
    local nx, nz = m3d.norm(0, 0)
    check("norm-zero", nx == 0 and nz == 0)
end

-- DirTo
do
    local nx, nz = m3d.dirTo(0, 0, 3, 4)
    check("dirTo-len",  math.abs(nx*nx + nz*nz - 1) < 0.001)
    check("dirTo-dir",  math.abs(nx / nz - 3/4) < 0.001)
end

-- facingTo
do
    local a = m3d.facingTo(0, 0, 1, 0)  -- east
    check("facing-east", math.abs(a - math.pi / 2) < 0.01)
end

-- moveToward
do
    local x, z = m3d.moveToward(0, 0, 10, 0, 5, 0.1)
    check("moveToward-x", x > 0 and x < 10)  -- moved but didn't reach
    check("moveToward-z", math.abs(z) < 0.01) -- straight line, z ~0
end
do
    local x, z = m3d.moveToward(0, 0, 0.1, 0, 5, 0.1)
    check("moveToward-snap", math.abs(x - 0.1) < 0.01 and math.abs(z) < 0.01)
end

-- dot3
check("dot3-self",   math.abs(m3d.dot3(1,2,3, 1,2,3) - 14) < 0.001)
check("dot3-ortho",  math.abs(m3d.dot3(1,0,0, 0,1,0)) < 0.001)
check("dot3-neg",    math.abs(m3d.dot3(1,2,3, -1,-2,-3) + 14) < 0.001)

-- cross3
do
    local cx, cy, cz = m3d.cross3(1, 0, 0, 0, 1, 0)
    check("cross3-x", math.abs(cx) < 0.001)
    check("cross3-y", math.abs(cy) < 0.001)
    check("cross3-z", math.abs(cz - 1) < 0.001)
end

-- lerp3
do
    local x, y, z = m3d.lerp3(0, 0, 0, 10, 20, 30, 0.5)
    check("lerp3-x", math.abs(x - 5) < 0.001)
    check("lerp3-y", math.abs(y - 10) < 0.001)
    check("lerp3-z", math.abs(z - 15) < 0.001)
end

-- Performance benchmark (100K iterations)
local iters = 100000
local start = os.clock()
for i = 1, iters do m3d.dist(i % 100, i % 200) end
local distTime = os.clock() - start

start = os.clock()
for i = 1, iters do m3d.norm(i % 100 + 1, i % 200 + 1) end
local normTime = os.clock() - start

start = os.clock()
for i = 1, iters do m3d.dot3(i % 10, i % 20, i % 30, 1, 2, 3) end
local dotTime = os.clock() - start

start = os.clock()
for i = 1, iters do m3d.cross3(1, 0, 0, 0, 1, i % 10) end
local crossTime = os.clock() - start

print(string.format("\n=== Performance (%d iterations) ===", iters))
print(string.format("dist   %dK: %.3fs  (%.1f ns/call)", iters/1000, distTime, distTime/iters*1e9))
print(string.format("norm   %dK: %.3fs  (%.1f ns/call)", iters/1000, normTime, normTime/iters*1e9))
print(string.format("dot3   %dK: %.3fs  (%.1f ns/call)", iters/1000, dotTime, dotTime/iters*1e9))
print(string.format("cross3 %dK: %.3fs  (%.1f ns/call)", iters/1000, crossTime, crossTime/iters*1e9))

--- Final result
print(string.format("\n=== %d/%d passed, %d failed ===", ok, ok+fail, fail))
if fail == 0 then
    print("ALL PASS")
else
    print("FAILURES DETECTED")
end
