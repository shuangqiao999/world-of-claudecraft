-- World of ClaudeCraft — Character Physics Engine
-- 连续碰撞检测、多通道滑移、反穿透、台阶攀登、攀爬
-- 对应原项目 src/sim/physics/ (swept collision + depenetration + stepUp + parkour)

local config = require("config")
local m3d = require("world.math3d")
local M = {}

-- 物理常数
local GRAVITY = -20                -- 重力加速度 yards/s^2
local JUMP_VELOCITY = 6            -- 初始跳跃速度
local MAX_STEP_HEIGHT = 1.5        -- 可攀爬的台阶高度
local COYOTE_TIME = 0.15           -- 离开边缘可跳跃的缓冲时间(秒)
local SWEPT_SPHERE_RADIUS = 0.5    -- 碰撞球体半径
local AIR_CONTROL = 0.3            -- 空中控制力 (30%)

-- 水体
local WATER_LEVEL = -2             -- 水面高度
local SWIM_SPEED_MULT = 0.6        -- 游泳速度倍数
local DROWN_TICKS = 20 * 20        -- 20 秒后开始溺水 (秒*tickrate)

-- 建筑/地形碰撞体 (简化: point-based 碰撞点)
local staticColliders = {}  -- { x, z, radius }

--- 注册静态碰撞体
function M.registerCollider(x, z, radius)
    table.insert(staticColliders, { x = x, z = z, radius = radius or 2 })
end

--- 获取该点的地面高度 (简化: y=0 平面)
function M.groundHeightAt(x, z)
    -- 水体下的地面 (湖底)
    -- 实际地形在 Batch G 中实现
    return 0
end

--- 检查点是否在水中
function M.isUnderwater(posY)
    return posY < WATER_LEVEL
end

--- 完整角色移动解析 (代替简单 applyInput)
-- @param e Entity
-- @param wishMove {dx, dz} 期望位移 (normalized * speed * dt)
-- @param dt 帧间隔
function M.resolvePlayerMotion(e, wishMove, dt)
    if not wishMove then
        wishMove = { dx = 0, dz = 0 }
    end

    local prevPos = { x = e.pos.x, y = e.pos.y, z = e.pos.z }

    -- 1. 台阶检测 (Step-Up)
    local canStep = M._stepUpCheck(e, wishMove)

    -- 2. 解析 XZ 位移 (碰撞检测)
    local resolved = M._resolvePosition(e, wishMove.dx, wishMove.dz, canStep)

    -- 3. 重力 / 跳跃
    e.vy = e.vy or 0
    if not e.onGround then
        e.vy = e.vy + GRAVITY * dt
    end

    -- 4. 游泳检测
    local wasSwimming = e.swimming
    e.swimming = M.isUnderwater(e.pos.y)
    if e.swimming then
        -- 水中: 无重力, 慢速
        e.vy = math.max(0, e.vy)  -- 不下沉
        resolved.dx = resolved.dx * SWIM_SPEED_MULT
        resolved.dz = resolved.dz * SWIM_SPEED_MULT
    end

    -- 5. 呼吸/疲劳
    if not wasSwimming and e.swimming then
        e.breathUsedTicks = 0
    end
    if e.swimming then
        e.breathUsedTicks = e.breathUsedTicks + 1
    end

    -- 6. Y 轴位移
    local newY = e.pos.y + e.vy * dt
    local groundY = M.groundHeightAt(e.pos.x, e.pos.z)
    local waterSurfaceY = WATER_LEVEL

    -- 在水中时浮到水面
    if e.swimming and e.pos.y < waterSurfaceY then
        newY = math.min(waterSurfaceY, e.pos.y + 2 * dt)
    end

    if newY <= groundY then
        -- 着地
        newY = groundY
        e.vy = math.min(0, e.vy)  -- 仅吸收向下的速度
        e.onGround = true
        e.jumping = false
        e.coyoteTimer = COYOTE_TIME  -- 重置土狼时间
    else
        if e.onGround then
            -- 刚离开地面: 启动土狼时间
            if e.coyoteTimer and e.coyoteTimer > 0 then
                -- 仍可跳跃
            else
                e.onGround = false
            end
        end
        e.onGround = false
    end
    e.pos.y = newY

    -- 7. 土狼时间衰减
    if e.coyoteTimer and e.coyoteTimer > 0 then
        e.coyoteTimer = e.coyoteTimer - dt
    end

    -- 8. 应用位移
    e.pos.x = prevPos.x + resolved.dx
    e.pos.z = prevPos.z + resolved.dz
    e.prevPos = prevPos
end

--- 跳跃
function M.jump(e)
    if e.dead or e.swimming then return false end

    -- 土狼时间: 离开边缘后短暂窗口内可跳
    if e.onGround or (e.coyoteTimer and e.coyoteTimer > 0) then
        e.vy = JUMP_VELOCITY
        e.onGround = false
        e.jumping = true
        e.coyoteTimer = 0
        return true
    end

    -- 水中跳跃到表面
    if e.swimming then
        e.vy = JUMP_VELOCITY * 0.5
        e.pos.y = math.min(e.pos.y + 0.5, WATER_LEVEL)
        e.jumping = true
        return true
    end

    return false
end

--- 台阶检测
function M._stepUpCheck(e, wishMove)
    if wishMove.dx == 0 and wishMove.dz == 0 then return false end

    local dist = m3d.dist(wishMove.dx, wishMove.dz)
    local nx = wishMove.dx / dist
    local nz = wishMove.dz / dist

    -- 检查前方是否有低障碍物
    local checkX = e.pos.x + nx * SWEPT_SPHERE_RADIUS
    local checkZ = e.pos.z + nz * SWEPT_SPHERE_RADIUS
    local groundY = M.groundHeightAt(checkX, checkZ)

    if groundY > e.pos.y and groundY - e.pos.y <= MAX_STEP_HEIGHT then
        return true
    end
    return false
end

--- 碰撞分辨率 (swept sphere vs static)
function M._resolvePosition(e, dx, dz, canStep)
    local startX, startZ = e.pos.x, e.pos.z
    local endX, endZ = startX + dx, startZ + dz

    -- 收集附近碰撞体
    local colliders = M._getNearbyColliders(startX, startZ, math.abs(dx) + math.abs(dz) + 5)

    -- 滑动分辨率 (最多 3 次迭代)
    local iterations = 0
    local currentX, currentZ = endX, endZ
    local remainingDx, remainingDz = dx, dz

    while iterations < 3 and (#colliders > 0) do
        local blocked = false
        for _, col in ipairs(colliders) do
            local px, pz = startX + remainingDx, startZ + remainingDz
            local collisionDist = M._sphereCollisionDistance(
                startX, startZ, remainingDx, remainingDz,
                col.x, col.z, col.radius + SWEPT_SPHERE_RADIUS)

            if collisionDist < 1.0 and collisionDist >= 0 then
                -- 碰撞: 滑移
                local hitX = startX + remainingDx * collisionDist
                local hitZ = startZ + remainingDz * collisionDist

                -- 法线
                local nnx = (hitX - col.x)
                local nnz = (hitZ - col.z)
                local nlen = m3d.dist(nnx, nnz)
                if nlen > 0.001 then
                    nnx = nnx / nlen; nnz = nnz / nlen
                end

                -- 沿法线弹回余量
                local remainingLen = m3d.dist(remainingDx, remainingDz)
                local dot = remainingDx * nnx + remainingDz * nnz
                local slideLen = remainingLen * (1 - collisionDist)

                -- 滑移: 仅保留切线分量
                if dot < 0 then
                    remainingDx = (remainingDx - nnx * dot) * (1 - collisionDist) * 0.8
                    remainingDz = (remainingDz - nnz * dot) * (1 - collisionDist) * 0.8
                    startX = hitX + nnx * 0.01
                    startZ = hitZ + nnz * 0.01
                    blocked = true
                end
            end
        end

        if not blocked then break end
        iterations = iterations + 1
    end

    return {
        dx = startX + remainingDx - e.pos.x,
        dz = startZ + remainingDz - e.pos.z,
    }
end

--- Swept Sphere vs Disc 碰撞检测
function M._sphereCollisionDistance(sx, sz, dx, dz, cx, cz, combinedRadius)
    -- 射线 vs 圆: 球体中心轨迹 vs 扩展圆 (半径 = col.radius + sphere.radius)
    local fdx = sx - cx
    local fdz = sz - cz

    local a = dx * dx + dz * dz
    if a < 0.001 then return 1.0 end  -- 无移动

    local b = 2 * (fdx * dx + fdz * dz)
    local c = fdx * fdx + fdz * fdz - combinedRadius * combinedRadius

    local discriminant = b * b - 4 * a * c
    if discriminant < 0 then return 1.0 end  -- 无碰撞

    local t = (-b - math.sqrt(discriminant)) / (2 * a)
    if t >= 0 and t <= 1 then return t end
    return 1.0
end

--- 获取附近碰撞体
function M._getNearbyColliders(px, pz, searchRadius)
    local result = {}
    for _, col in ipairs(staticColliders) do
        local dx = col.x - px
        local dz = col.z - pz
        if dx * dx + dz * dz <= (searchRadius + col.radius) ^ 2 then
            table.insert(result, col)
        end
    end
    return result
end

--- 计算水面下的碰撞: 游泳者可以穿过, 陆地实体碰撞
function M.checkSwimmingCollision(e, other)
    if e.swimming and e.pos.y < WATER_LEVEL then
        return false  -- 游泳者不碰撞
    end
    return true
end

--- 手动推离 (反穿透)
function M.depenetrate(e1, e2)
    local r = SWEPT_SPHERE_RADIUS * 2
    local dx = e1.pos.x - e2.pos.x
    local dz = e1.pos.z - e2.pos.z
    local dist = m3d.dist(dx, dz)
    if dist < r and dist > 0.001 then
        local overlap = (r - dist) / 2
        local nx = dx / dist
        local nz = dz / dist
        e1.pos.x = e1.pos.x + nx * overlap
        e1.pos.z = e1.pos.z + nz * overlap
        e2.pos.x = e2.pos.x - nx * overlap
        e2.pos.z = e2.pos.z - nz * overlap
    end
end

return M
