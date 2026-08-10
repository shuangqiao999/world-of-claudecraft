-- World of ClaudeCraft — Character Physics Solver
-- 对应原项目 src/sim/physics/character.ts (moveCharacter/floorHeightAt)
-- 顺序: 去穿透 → 至多4次 sweep-and-slide → STEP UP → 地形墙门控 (等高线滑移)

local colliders = require("world.colliders")
local rideHeight = require("world.ride_height")
local terrain = require("world.terrain")
local sweep = require("world.physics.sweep")

local M = {}

M.MAX_STEP_HEIGHT = 0.9

local MAX_SLIDE_ITERATIONS = 4
local MAX_DEPENETRATION_ITERATIONS = 4
local TOP_EPS = 1e-3
local MIN_MOTION = 1e-7
local STEP_COMMIT_DISTANCE = 0.35
local STEP_COMMIT_TRIES = 4

M.physicsStats = { solves = 0, candidates = 0, sweeps = 0, overlaps = 0 }

function M.resetPhysicsStats()
    M.physicsStats.solves = 0
    M.physicsStats.candidates = 0
    M.physicsStats.sweeps = 0
    M.physicsStats.overlaps = 0
end

-- scratch
local candidates = {}
local hit = { t = 0, nx = 0, nz = 0 }
local push = { nx = 0, nz = 0, depth = 0 }
local depen = { x = 0, z = 0 }

local function pruneCandidates(x, z, dx, dz, reach)
    local minX = math.min(x, x + dx) - reach
    local maxX = math.max(x, x + dx) + reach
    local minZ = math.min(z, z + dz) - reach
    local maxZ = math.max(z, z + dz) + reach
    local kept = 0
    for i = 1, #candidates do
        local c = candidates[i]
        local ext = c.type == "circle" and c.r or math.sqrt(c.hw * c.hw + c.hd * c.hd)
        if not (c.x + ext < minX or c.x - ext > maxX or c.z + ext < minZ or c.z - ext > maxZ) then
            kept = kept + 1
            candidates[kept] = c
        end
    end
    for i = #candidates, kept + 1, -1 do candidates[i] = nil end
end

local function supportFromCandidates(x, z, r, maxY)
    local best = -math.huge
    local reachR = r * colliders.SUPPORT_OVERLAP
    for i = 1, #candidates do
        local c = candidates[i]
        if c.standable and c.moveTopY ~= nil then
            local inReach = false
            if c.type == "circle" then
                local dx = x - c.x
                local dz = z - c.z
                local reach = c.r + reachR
                inReach = dx * dx + dz * dz < reach * reach
            else
                local lx = math.abs(x - c.x)
                local lz = math.abs(z - c.z)
                inReach = lx < c.hw + reachR and lz < c.hd + reachR
            end
            if inReach then
                local top = colliders.colliderTopAt(c, x, z)
                if top > maxY + TOP_EPS or top <= best then goto continue_c end
                best = top
            end
            ::continue_c::
        end
    end
    return best
end

local function blocksAt(c, x, z, feetY, params)
    if params.ignoreFences and c.type == "obb" and c.isFence then return false end
    if c.moveTopY == nil then return true end
    local lift = (not params.grounded) and (c.standable == true) and colliders.MANTLE_REACH or 0
    return colliders.colliderTopAt(c, x, z) > feetY + lift + TOP_EPS
end

local function steppableAt(c, feetY, params)
    return params.grounded and c.standable == true and c.moveTopY ~= nil
        and c.moveTopY > feetY and c.moveTopY - feetY <= params.stepHeight
end

local function isClear(x, z, feetY, params)
    for i = 1, #candidates do
        local c = candidates[i]
        if blocksAt(c, x, z, feetY, params) then
            M.physicsStats.overlaps = M.physicsStats.overlaps + 1
            if sweep.overlapCollider(c, x, z, params.radius, push) then return false end
        end
    end
    return true
end

local function depenetrate(x, z, feetY, params, out)
    local px, pz = x, z
    for iter = 1, MAX_DEPENETRATION_ITERATIONS do
        local moved = false
        for i = 1, #candidates do
            local c = candidates[i]
            if blocksAt(c, px, pz, feetY, params) then
                M.physicsStats.overlaps = M.physicsStats.overlaps + 1
                if sweep.overlapCollider(c, px, pz, params.radius, push) then
                    px = px + push.nx * (push.depth + sweep.SKIN_WIDTH)
                    pz = pz + push.nz * (push.depth + sweep.SKIN_WIDTH)
                    moved = true
                end
            end
        end
        if not moved then break end
    end
    out.x = px
    out.z = pz
end

--- 移动角色体 (dx, dz), 解析碰撞 + 滑动 + 台阶
function M.moveCharacter(params, x, y, z, dx, dz, out)
    out.x = x
    out.y = y
    out.z = z
    out.blocked = false
    out.stepped = 0

    local pad = params.radius + params.stepHeight + 1
    for i = #candidates, 1, -1 do candidates[i] = nil end
    colliders.queryOpenWorldColliders(params.seed,
        math.min(x, x + dx) - pad, math.min(z, z + dz) - pad,
        math.max(x, x + dx) + pad, math.max(z, z + dz) + pad,
        candidates)
    pruneCandidates(x, z, dx, dz, params.radius + STEP_COMMIT_DISTANCE + sweep.SKIN_WIDTH)
    M.physicsStats.solves = M.physicsStats.solves + 1
    M.physicsStats.candidates = M.physicsStats.candidates + #candidates

    local feetY = y
    depenetrate(x, z, feetY, params, depen)
    local px, pz = depen.x, depen.z
    local remX, remZ = dx, dz
    local blocked = false
    local stepped = 0
    local entryFeetY = feetY

    for iter = 1, MAX_SLIDE_ITERATIONS do
        local len = math.sqrt(remX * remX + remZ * remZ)
        if len < MIN_MOTION then break end

        local bestT, bestIndex, bestNx, bestNz = math.huge, -1, 0, 0
        for i = 1, #candidates do
            local c = candidates[i]
            if blocksAt(c, px, pz, feetY, params) then
                M.physicsStats.sweeps = M.physicsStats.sweeps + 1
                if sweep.sweepCollider(c, px, pz, remX, remZ, params.radius, hit) then
                    if hit.t < bestT then
                        bestT, bestIndex, bestNx, bestNz = hit.t, i, hit.nx, hit.nz
                    end
                end
            end
        end
        if bestIndex < 0 then
            px = px + remX
            pz = pz + remZ
            break
        end

        local skinT = math.min(bestT, sweep.SKIN_WIDTH / len)
        local advance = math.max(0, bestT - skinT)
        px = px + remX * advance
        pz = pz + remZ * advance
        remX = remX * (1 - advance)
        remZ = remZ * (1 - advance)

        local blocker = candidates[bestIndex]
        if steppableAt(blocker, feetY, params) then
            local lifted = blocker.moveTopY + TOP_EPS
            local dirLen = math.sqrt(remX * remX + remZ * remZ)
            local ux, uz = 0, 0
            if dirLen > MIN_MOTION then ux, uz = remX / dirLen, remZ / dirLen end
            local committed = false
            for s = 0, STEP_COMMIT_TRIES - 1 do
                if committed then break end
                local adv = (s * STEP_COMMIT_DISTANCE) / (STEP_COMMIT_TRIES - 1)
                local cx = px + ux * adv
                local cz = pz + uz * adv
                if isClear(cx, cz, lifted, params) then
                    local floor = supportFromCandidates(cx, cz, params.radius, lifted + TOP_EPS)
                    if floor >= lifted - TOP_EPS then
                        px, pz = cx, cz
                        local consumed = math.min(adv, dirLen)
                        remX = remX - ux * consumed
                        remZ = remZ - uz * consumed
                        stepped = stepped + (lifted - feetY)
                        feetY = lifted
                        committed = true
                    end
                end
            end
            if committed then goto continue_slide end
        end

        blocked = true
        local into = remX * bestNx + remZ * bestNz
        if into < 0 then
            remX = remX - into * bestNx
            remZ = remZ - into * bestNz
        else
            break
        end
        ::continue_slide::
    end

    -- 地形墙门控
    local wls = rideHeight.stepWaterLevel(x, z, px, pz, params.seed)
    local rawEnd = terrain.groundHeight(px, pz)
    local groundStart = math.max(terrain.groundHeight(x, z), wls)
    local groundEnd = math.max(rawEnd, wls)
    local run = math.sqrt(dx * dx + dz * dz)
    local airborneClears = (not params.grounded) and groundEnd <= feetY
    if (not params.swimming) and (not airborneClears) and groundEnd > groundStart and run > 1e-5 then
        local rise = groundEnd - groundStart
        local unwalkable = false
        if rise / run > params.maxSlope then unwalkable = true end
        if (not unwalkable) and rawEnd >= wls and rideHeight.rideSteepnessAt(px, pz, params.seed) > params.maxSlope then
            unwalkable = true
        end
        if unwalkable and not rideHeight.shoreStepOut(x, z, px, pz, params.seed, params.maxSlope) then
            blocked = true
            local slope = terrain.terrainDownhill(x, z)
            local gx, gz = slope and slope.x or 0, slope and slope.z or 0
            local glen = math.sqrt(gx * gx + gz * gz)
            px, pz = depen.x, depen.z
            feetY = entryFeetY
            stepped = 0
            if glen > 1e-6 then
                local ux, uz = gx / glen, gz / glen
                local along = dx * ux + dz * uz
                local contourX = dx - along * ux
                local contourZ = dz - along * uz
                if math.sqrt(contourX * contourX + contourZ * contourZ) > MIN_MOTION then
                    local cx = x + contourX
                    local cz = z + contourZ
                    local contourWls = rideHeight.stepWaterLevel(x, z, cx, cz, params.seed)
                    local contourRaw = terrain.groundHeight(cx, cz)
                    local contourGround = math.max(contourRaw, contourWls)
                    local contourRise = contourGround - math.max(groundStart, contourWls)
                    local contourRun = math.sqrt(contourX * contourX + contourZ * contourZ)
                    local contourOk = (contourRise <= 0 or contourRise / contourRun <= params.maxSlope)
                        and (contourRaw < contourWls or rideHeight.rideSteepnessAt(cx, cz, params.seed) <= params.maxSlope)
                    if contourOk and isClear(cx, cz, feetY, params) then
                        px, pz = cx, cz
                    end
                end
            end
            groundEnd = terrain.groundHeight(px, pz)
        end
    end

    out.x = px
    out.z = pz
    out.y = feetY
    out.blocked = blocked
    out.stepped = stepped
end

--- 表面高度 (地形 vs 可站立 prop top)
function M.floorHeightAt(seed, x, z, radius, maxY)
    return math.max(terrain.groundHeight(x, z), colliders.supportHeightAt(seed, x, z, radius, maxY))
end

return M
