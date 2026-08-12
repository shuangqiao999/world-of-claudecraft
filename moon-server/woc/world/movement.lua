-- World of ClaudeCraft — Player Movement Kernel
-- 对应原项目 src/sim/player_motion.ts (stepPlayerMotion 完整移植)
-- 转向集成 → wish vector → 游泳闩锁 → 陡坡滑落 → 物理求解器 → 垂直状态机 → 墙立面微调

local config = require("config")
local m3d = require("world.math3d")
local terrain = require("world.terrain")
local rideHeight = require("world.ride_height")
local colliders = require("world.colliders")
local charPhysics = require("world.physics.character")
local sweep = require("world.physics.sweep")

local M = {}

-- TS 常量
M.GRAVITY = 16
M.JUMP_VELOCITY = 6
M.MOUNT_JUMP_MULT = 1.25
M.AIR_CONTROL_ACCEL = 20
M.COYOTE_TIME = 0.15
M.FALL_SAFE_DISTANCE = 12
M.STEEP_SLIDE_SPEED = config.RUN_SPEED
M.BACKPEDAL_MULT = 0.65
M.SWIM_SPEED_MULT = 0.65
M.SWIM_BUOYANCY_RISE = 5
M.SWIM_MAX_PLUNGE = 1.2
M.SWIM_DIVE_SPEED_MULT = 0.32
M.SWIM_DIVE_CRUISE_MULT = 0.58
M.SWIM_STROKE_PERIOD = 1.7
M.SWIM_DIVE_RATE = 3.2
M.SWIM_ASCEND_RATE = 4.2
M.SWIM_PLUNGE_PER_SPEED = 0.12
M.SWIM_PLUNGE_MAX = 2.5
M.SWIM_STEER_MIN_RATE = 0.3
M.SWIM_FLOOR_CLEARANCE = 0.35
M.SWIM_SUBMERGE_EPS = 0.12
M.WADE_MIN_DEPTH = 0.22
M.WADE_FULL_DEPTH = 0.75
M.WADE_SPEED_MULT = 0.72

local SWIM_DEPTH = 0.8
local MAX_CLIMB_SLOPE = 1.5
local BODY_RADIUS = 0.5
local TURN_SPEED = 3.0

--- 移动速度倍率 (TS moveSpeedMult)
function M.moveSpeedMult(e, extraSpeedPct)
    extraSpeedPct = extraSpeedPct or 0
    if e.ghost then return 1.25 end
    local slow, speed = 1, 1
    for _, a in pairs(e.auras or {}) do
        if a.kind == "slow" or a.kind == "stealth" then
            slow = math.min(slow, a.value or 1)
        end
        if a.kind == "buff_speed" or a.kind == "form_travel" or a.kind == "form_fireball" then
            speed = math.max(speed, a.value or 1)
        end
        if a.kind == "enrage" then
            speed = math.max(speed, 1.1)
        end
    end
    if e.mountKey then speed = speed + (require("world.mount").mountMoveSpeedPct(e.mountKey)) end
    if extraSpeedPct then speed = speed + extraSpeedPct end
    return slow * speed
end

--- 跳跃高度倍率 (TS jumpMult)
function M.jumpMult(e)
    local m = 1
    for _, a in pairs(e.auras or {}) do
        if a.kind == "buff_jump" then m = math.max(m, a.value or 1) end
    end
    if e.mountKey then m = m * M.MOUNT_JUMP_MULT end
    return m
end

--- 游泳判定 (TS swimsAt: 单次地形采样)
local function swimsAt(y, ground, level)
    return ground < level - SWIM_DEPTH and y <= level - 0.75 + 0.15
end

function M.isSwimming(e, seed)
    local ground = terrain.groundHeight(e.pos.x, e.pos.z)
    return swimsAt(e.pos.y, ground, rideHeight.waterLevelAt(e.pos.x, e.pos.z, seed))
end

function M.isSubmerged(e, seed)
    local ground = terrain.groundHeight(e.pos.x, e.pos.z)
    local level = rideHeight.waterLevelAt(e.pos.x, e.pos.z, seed)
    return swimsAt(e.pos.y, ground, level) and e.pos.y < level - 0.75 - M.SWIM_SUBMERGE_EPS
end

--- 浅水拖拽 (TS wadeSpeedMult)
function M.wadeSpeedMult(feetDepth)
    if not feetDepth or feetDepth <= M.WADE_MIN_DEPTH then return 1 end
    local t = math.min(1, (feetDepth - M.WADE_MIN_DEPTH) / (M.WADE_FULL_DEPTH - M.WADE_MIN_DEPTH))
    return 1 + (M.WADE_SPEED_MULT - 1) * t
end

--- 游泳速度倍率 (TS swimSpeedMult: 下潜→巡航缓入)
function M.swimSpeedMult(strokeT, submerged)
    if not submerged then return M.SWIM_SPEED_MULT end
    local t = math.min(1, math.max(0, strokeT / M.SWIM_STROKE_PERIOD))
    local eased = t * t * (3 - 2 * t)
    return M.SWIM_DIVE_SPEED_MULT + (M.SWIM_DIVE_CRUISE_MULT - M.SWIM_DIVE_SPEED_MULT) * eased
end

-- PlayerMotionDeps 闭包绑定 (由 processInputs 构造)
local deps = nil

--- 绑定依赖 (init.lua 启动时)
function M.bindDeps(d)
    deps = d
end

-- 求解器 scratch
local moveParams = { seed = 0, radius = 0, stepHeight = 0, maxSlope = 0, grounded = false, swimming = false, ignoreFences = false }
local moveOut = { x = 0, y = 0, z = 0, blocked = false, stepped = 0 }

--- 垂直状态机 (TS verticalPass:582-735; ground/waterHere 由调用方缓存传入)
local function verticalPass(p, inp, wishX, wishZ, wishSpeed, swimming, steepGround, mountLocked, ground, waterHere)
    if ground == nil then ground = terrain.placementHeight(p.pos.x, p.pos.z) end
    local support = charPhysics.floorHeightAt(deps.seed, p.pos.x, p.pos.z, BODY_RADIUS,
        p.pos.y + (p.onGround and 0 or colliders.MANTLE_REACH))
    if waterHere == nil then waterHere = rideHeight.waterLevelAt(p.pos.x, p.pos.z, deps.seed) end
    local deepWater = ground < waterHere - SWIM_DEPTH

    if deepWater and p.pos.y <= waterHere - 0.75 + 0.05 then
        M._swimVerticalPass(p, inp, wishX, wishZ, wishSpeed, mountLocked, ground, waterHere)
        return
    end

    local coyote = (not p.onGround) and (not p.jumping) and (not swimming)
        and (p.vy or 0) <= 0 and (p.vy or 0) > -M.GRAVITY * M.COYOTE_TIME
        and terrain.terrainSteepnessAt(p.pos.x, p.pos.z) <= MAX_CLIMB_SLOPE

    if inp.jump and (p.onGround or coyote) and not M._isRooted(p) and not steepGround and not mountLocked then
        p.vy = M.JUMP_VELOCITY * M.jumpMult(p)
        p.vx = wishX * wishSpeed
        p.vz = wishZ * wishSpeed
        p.onGround = false
        p.jumping = true
        p.fallStartY = p.pos.y
    end

    if not p.onGround then
        p.vy = (p.vy or 0) - M.GRAVITY * deps.dt
        p.pos.y = p.pos.y + p.vy * deps.dt
        p.fallStartY = math.max(p.fallStartY or p.pos.y, p.pos.y)

        if deepWater and p.pos.y <= waterHere - 0.75 then
            local impact = -(p.vy or 0)
            local plunge = math.min(M.SWIM_PLUNGE_MAX, math.max(0, (impact - M.JUMP_VELOCITY) * M.SWIM_PLUNGE_PER_SPEED))
            local plungeFloor = math.min(waterHere - 0.75, ground + M.SWIM_FLOOR_CLEARANCE)
            p.pos.y = math.max(plungeFloor, waterHere - 0.75 - plunge)
            p.vy = 0
            p.vx = 0
            p.vz = 0
            p.onGround = true
            p.jumping = false
            p.fallStartY = p.pos.y
            return
        end

        if p.pos.y <= support then
            p.pos.y = support
            p.vy = 0
            p.vx = 0
            p.vz = 0
            p.onGround = true
            p.jumping = false
            local drop = (p.fallStartY or p.pos.y) - support
            if drop > M.FALL_SAFE_DISTANCE then
                local dmg = math.round(p.maxHp * (drop - M.FALL_SAFE_DISTANCE) * 0.07)
                if dmg > 0 and deps.dealDamage then deps.dealDamage(p, dmg) end
            end
            p.fallStartY = support
        end
    else
        local run = m3d.dist(p.pos.x - (p.prevPos and p.prevPos.x or p.pos.x), p.pos.z - (p.prevPos and p.prevPos.z or p.pos.z))
        local maxStepDown = math.max(charPhysics.MAX_STEP_HEIGHT, 0.4 + run * MAX_CLIMB_SLOPE)
        if support < p.pos.y - maxStepDown then
            p.onGround = false
            p.jumping = false
            p.vx = (p.pos.x - (p.prevPos and p.prevPos.x or p.pos.x)) / deps.dt
            p.vz = (p.pos.z - (p.prevPos and p.prevPos.z or p.pos.z)) / deps.dt
            p.vy = 0
            p.fallStartY = p.pos.y
        else
            p.pos.y = support
            p.fallStartY = support
        end
    end
end

--- 游泳垂直状态机 (TS swimVerticalPass:750-818)
function M._swimVerticalPass(p, inp, wishX, wishZ, wishSpeed, mountLocked, ground, waterHere)
    local surface = waterHere - 0.75
    local floor = math.min(surface, ground + M.SWIM_FLOOR_CLEARANCE)
    local controllable = not M._isRooted(p) and not mountLocked
    p.vx = 0
    p.vz = 0
    p.vy = 0
    p.onGround = true
    p.jumping = false

    local steer = 1
    if type(inp.swimSteer) == "number" and inp.swimSteer > 0 then
        local t = math.min(1, math.max(0, inp.swimSteer))
        steer = M.SWIM_STEER_MIN_RATE + (1 - M.SWIM_STEER_MIN_RATE) * t
    end

    if inp.jump and controllable and p.pos.y >= surface - 1e-3 then
        p.vy = M.JUMP_VELOCITY * 0.7 * M.jumpMult(p)
        p.vx = wishX * wishSpeed
        p.vz = wishZ * wishSpeed
        p.onGround = false
        p.jumping = true
    elseif inp.jump and controllable then
        p.swimDiving = false
        p.pos.y = math.min(surface, p.pos.y + M.SWIM_ASCEND_RATE * deps.dt)
    elseif inp.dive and controllable then
        p.swimDiving = true
        p.pos.y = math.max(floor, p.pos.y - M.SWIM_DIVE_RATE * steer * deps.dt)
    elseif inp.surface and controllable then
        p.pos.y = math.min(surface, p.pos.y + M.SWIM_ASCEND_RATE * steer * deps.dt)
    elseif p.swimDiving then
        p.pos.y = math.min(surface, math.max(floor, p.pos.y))
    else
        p.pos.y = math.min(surface, p.pos.y + M.SWIM_ASCEND_RATE * deps.dt)
    end
    if p.pos.y >= surface - 1e-6 then p.swimDiving = false end
    p.fallStartY = p.pos.y
end

--- CC 谓词 (stun/root)
function M._isRooted(e)
    for _, a in pairs(e.auras or {}) do
        if a.mechanic == "root" then return true end
    end
    return false
end

local function isStunned(e)
    for _, a in pairs(e.auras or {}) do
        local m = a.mechanic
        if m == "stun" or m == "disorient" then return true end
    end
    return false
end

--- 完整移动内核 (TS stepPlayerMotion)
--- @param e Entity
--- @param mi table MoveInput (f,b,sl,sr,tl,tr,j,dive,surface,swimSteer)
--- @param facing number|nil 鼠标朝向
function M.stepPlayerMotion(e, mi, facing)
    if not deps then return end

    -- 转向 (TS: turnRight 减小 facing)
    if not isStunned(e) then
        if mi.tl and mi.tl > 0 then e.facing = e.facing + TURN_SPEED * deps.dt end
        if mi.tr and mi.tr > 0 then e.facing = e.facing - TURN_SPEED * deps.dt end
    end
    if facing then e.facing = facing end
    while e.facing > math.pi * 2 do e.facing = e.facing - math.pi * 2 end
    while e.facing < 0 do e.facing = e.facing + math.pi * 2 end

    -- 局部输入 (z 前, x 右)
    local mx, mz = 0, 0
    if mi.f and mi.f > 0 then mz = mz + 1 end
    if mi.b and mi.b > 0 then mz = mz - 1 end
    if mi.sl and mi.sl > 0 then mx = mx - 1 end
    if mi.sr and mi.sr > 0 then mx = mx + 1 end

    local wantsMove = mx ~= 0 or mz ~= 0 or (mi.j and mi.j > 0)
    if wantsMove and e.sitting then deps.standUp(e) end

    local hasMoveInput = mx ~= 0 or mz ~= 0
    -- 同帧缓存: terrain.groundHeight 对同一 (x,z) 只计算一次 (节省 14+ 次冗余 FBM 噪声)
    local ground = terrain.groundHeight(e.pos.x, e.pos.z)
    local swimGround = ground
    local swimLevel = rideHeight.waterLevelAt(e.pos.x, e.pos.z, deps.seed)
    local swimming = swimsAt(e.pos.y, swimGround, swimLevel)
    local submerged = swimming and e.pos.y < swimLevel - 0.75 - M.SWIM_SUBMERGE_EPS

    if submerged then
        e.swimStroke = math.min(M.SWIM_STROKE_PERIOD, (e.swimStroke or 0) + (hasMoveInput and deps.dt or 0))
    else
        e.swimStroke = 0
    end
    if not swimming then e.swimDiving = false end

    -- 陡坡滑落 (TS rideSteepnessAt + terrainDownhill)
    local steepFlagged = e.onGround and not swimming and rideHeight.rideSteepnessAt(e.pos.x, e.pos.z, deps.seed) > MAX_CLIMB_SLOPE
    local steepSlide = steepFlagged and terrain.terrainDownhill(e.pos.x, e.pos.z) or nil
    local steepGround = steepSlide ~= nil

    -- 坐骑通道移动取消
    if (e.mountCastRemaining or 0) > 0 and e.mountCastKey ~= "" and hasMoveInput then
        e.mountCastRemaining = 0
        e.mountCastKey = ""
    end
    local mountLocked = (e.mountCastRemaining or 0) > 0 and e.mountCastKey == ""

    local moving = hasMoveInput and not M._isRooted(e) and not steepGround and not mountLocked
    local wishX, wishZ, wishSpeed = 0, 0, 0
    if moving then
        if e.castingAbility then
            local mobile = false
            for _, a in pairs(e.auras or {}) do
                if a.kind == "ice_floes" then mobile = true end
            end
            if not mobile then deps.cancelCast(e) end
        end
        local nx, nz = m3d.norm(mx, mz)
        local speed = config.RUN_SPEED * M.moveSpeedMult(e)
        if mz < 0 then speed = speed * M.BACKPEDAL_MULT end
        if swimming then
            speed = speed * M.swimSpeedMult(e.swimStroke, submerged)
        elseif e.onGround then
            speed = speed * M.wadeSpeedMult(swimLevel - e.pos.y)
        end
        local sin, cos = math.sin(e.facing), math.cos(e.facing)
        wishX = nz * sin - nx * cos
        wishZ = nz * cos + nx * sin
        wishSpeed = speed
    end

    -- 空中控制
    local airSteering = moving and not e.onGround and not swimming
    if airSteering then
        local accel = M.AIR_CONTROL_ACCEL * deps.dt
        local dvx = wishX * wishSpeed - (e.vx or 0)
        local dvz = wishZ * wishSpeed - (e.vz or 0)
        local dLen = m3d.dist(dvx, dvz)
        if dLen > accel then
            local k = accel / dLen
            dvx = dvx * k
            dvz = dvz * k
        end
        local before = m3d.dist(e.vx or 0, e.vz or 0)
        e.vx = (e.vx or 0) + dvx
        e.vz = (e.vz or 0) + dvz
        local after = m3d.dist(e.vx or 0, e.vz or 0)
        local cap = math.max(wishSpeed, before)
        if after > cap and after > 1e-9 then
            local k = cap / after
            e.vx = e.vx * k
            e.vz = e.vz * k
        end
    end

    local movingOnGround = moving and (e.onGround or swimming)
    local slide = steepSlide
    if slide or movingOnGround or airSteering or ((not e.onGround) and ((e.vx or 0) ~= 0 or (e.vz or 0) ~= 0)) then
        if slide and e.castingAbility then deps.cancelCast(e) end
        local stepX = slide and (slide.x * M.STEEP_SLIDE_SPEED) or (movingOnGround and (wishX * wishSpeed) or (e.vx or 0))
        local stepZ = slide and (slide.z * M.STEEP_SLIDE_SPEED) or (movingOnGround and (wishZ * wishSpeed) or (e.vz or 0))
        local clearFences = (not e.onGround) and e.jumping
        local stepStartX, stepStartZ = e.pos.x, e.pos.z

        -- 开放世界: 物理求解器
        moveParams.seed = deps.seed
        moveParams.radius = BODY_RADIUS
        moveParams.stepHeight = charPhysics.MAX_STEP_HEIGHT
        moveParams.maxSlope = MAX_CLIMB_SLOPE
        moveParams.grounded = e.onGround and not swimming
        moveParams.swimming = swimming
        moveParams.ignoreFences = clearFences
        charPhysics.moveCharacter(moveParams, e.pos.x, e.pos.y, e.pos.z, stepX * deps.dt, stepZ * deps.dt, moveOut)

        e.pos.x = moveOut.x
        e.pos.z = moveOut.z
        if moveOut.stepped > 0 then e.pos.y = moveOut.y end
        if not e.onGround and moveOut.blocked then
            e.vx = (e.pos.x - stepStartX) / deps.dt
            e.vz = (e.pos.z - stepStartZ) / deps.dt
        end
    elseif e.onGround and not swimming then
        -- 静止站立: 仍运行 verticalPass 确保 Y 在 terrain surface (TS standoffPass 等价)
        verticalPass(e, mi, wishX, wishZ, wishSpeed, swimming, steepGround, mountLocked, ground, swimLevel)
    end

    -- 记录 prevPos
    if not e.prevPos then e.prevPos = { x = e.pos.x, y = e.pos.y, z = e.pos.z } end
    e.prevPos.x = e.pos.x
    e.prevPos.y = e.pos.y
    e.prevPos.z = e.pos.z

    verticalPass(e, mi, wishX, wishZ, wishSpeed, swimming, steepGround, mountLocked, ground, swimLevel)

    -- standoffPass: 仅在严重偏离时校正 Y (TS player_motion.ts:907)
    -- 不做渐进校正 — 避免与 verticalPass/道具站立冲突导致穿模振荡
    if e.onGround and not swimming and deps and deps.seed then
        local gh = terrain.placementHeight(e.pos.x, e.pos.z)
        local fh = charPhysics.floorHeightAt(deps.seed, e.pos.x, e.pos.z, BODY_RADIUS, e.pos.y + 0.5)
        if fh > gh + 0.1 then
            -- 站在道具顶 (crate/rock/canopy): 信任 floorHeightAt, 不校正到裸地形
        else
            local diff = e.pos.y - gh
            if diff < -0.01 or diff > 2.0 then
                e.pos.y = gh
            end
        end
    end
end

--- 兼容入口 (processInputs 调用)
function M.applyInput(e, mi, facing, dt)
    if not deps then
        -- 绑定默认依赖 (dt 注入)
        deps = { seed = 0, dt = dt or 0.05 }
    end
    deps.dt = dt or 0.05
    M.stepPlayerMotion(e, M.sanitizeMoveInput(mi), facing)
end

-- 客户端 wire 字段 → 移动内核字段映射 (对应 src/sim/move_input.ts sanitizeMoveInput)
-- wire: f,b,tl,tr,sl,sr,j,dv,sf,ss  | 内核: forward,back,turnLeft,turnRight,strafeLeft,
-- strafeRight,jump,dive,surface,swimSteer
local WIRE_TO_FULL = {
    { "forward", { "f" } }, { "back", { "b" } },
    { "turnLeft", { "tl" } }, { "turnRight", { "tr" } },
    { "strafeLeft", { "sl" } }, { "strafeRight", { "sr" } },
    { "jump", { "j" } }, { "dive", { "dv" } }, { "surface", { "sf" } },
}

--- 将客户端紧凑字段标准化为内核字段 (保留紧凑名, 便于既有逻辑; 额外填充完整名)
function M.sanitizeMoveInput(mi)
    if type(mi) ~= "table" then return {} end
    local out = {}
    for k, v in pairs(mi) do out[k] = v end
    for _, pair in ipairs(WIRE_TO_FULL) do
        local full, compacts = pair[1], pair[2]
        if out[full] == nil then
            for _, c in ipairs(compacts) do
                if out[c] == 1 or out[c] == true then out[full] = 1 break end
            end
        end
        -- 只保留布尔/0/1 (TS isMoveFlag)
        out[full] = (out[full] == true or out[full] == 1) and 1 or nil
    end
    -- 游泳转向 (ss 或 swimSteer), 0..1
    local ss = out.ss
    if type(out.swimSteer) == "number" and out.swimSteer >= 0 and out.swimSteer <= 1 then
        ss = out.swimSteer
    end
    if type(ss) == "number" and ss >= 0 and ss <= 1 then out.swimSteer = ss end
    return out
end

return M
