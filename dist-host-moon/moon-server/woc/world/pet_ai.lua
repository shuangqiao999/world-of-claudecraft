-- World of ClaudeCraft — Pet AI System
-- 宠物跟随/攻击/嘲讽/命令
-- 对应原项目 src/sim/pet/pet_ai.ts + src/sim/pet/pet_commands.ts

local config = require("config")
local simrng = require("world.simrng")
local M = {}

local FOLLOW_DISTANCE = 8     -- 跟随距离
local ATTACK_RANGE_SQ = 25    -- 5^2
local PET_TAUNT_COOLDOWN = 8
local GLOBAL_PET_COOLDOWN = 1.5

-- 宠物模式
local MODE = {
    PASSIVE = "passive",
    DEFENSIVE = "defensive",
    AGGRESSIVE = "aggressive",
}

--- 召唤宠物 (创建实体)
function M.summonPet(owner, petTemplate, entities, gridModule, allocIdFn)
    local petId = allocIdFn()
    local pet = {
        id = petId,
        kind = "pet",
        templateId = petTemplate.id or "wolf",
        name = petTemplate.name or "Pet",
        level = owner.level or 1,
        pos = { x = owner.pos.x + 1, y = owner.pos.y, z = owner.pos.z + 1 },
        facing = owner.facing,
        hp = petTemplate.maxHp or 50,
        maxHp = petTemplate.maxHp or 50,
        resource = 100, maxResource = 100,
        attackPower = petTemplate.attackPower or 10,
        autoAttack = false,
        swingTimer = 0,
        weapon = { min = 3, max = 6, speed = 2.0 },
        auras = {},
        cooldowns = {},
        dead = false, ghost = false,
        ownerId = owner.id,
        petMode = MODE.DEFENSIVE,
        petTauntTimer = 0,
        targetId = nil,
        inCombat = false,
        combatTimer = 99,
        moveSpeed = 7,
        threat = {},
    }
    entities[pet.id] = pet
    if gridModule then gridModule.insert(pet) end
    owner.petEntityId = pet.id
    return pet
end

--- 解散宠物
function M.despawnPet(owner, entities, gridModule)
    if not owner.petEntityId then return end
    local pet = entities[owner.petEntityId]
    if pet then
        if gridModule then gridModule.remove(pet) end
        entities[pet.id] = nil
    end
    owner.petEntityId = nil
end

--- 更新宠物 AI (每个 tick)
function M.updatePet(owner, entities, dt)
    if not owner or not owner.petEntityId then return nil, nil end
    local pet = entities[owner.petEntityId]
    if not pet or pet.dead then return nil, nil end

    -- 更新 GCD
    if pet.gcdRemaining and pet.gcdRemaining > 0 then
        pet.gcdRemaining = pet.gcdRemaining - dt
    end

    -- 嘲讽计时器
    if pet.petTauntTimer > 0 then
        pet.petTauntTimer = pet.petTauntTimer - dt
    end

    local mode = pet.petMode or MODE.DEFENSIVE
    local target = pet.targetId and entities[pet.targetId]

    -- 自动目标选择 (aggressive 模式)
    if mode == MODE.AGGRESSIVE and not target then
        for _, e in pairs(entities) do
            if e.kind == "mob" and not e.dead and e.hostile then
                local dx = pet.pos.x - e.pos.x
                local dz = pet.pos.z - e.pos.z
                if dx * dx + dz * dz < 400 then  -- 20yd
                    target = e
                    pet.targetId = e.id
                    pet.autoAttack = true
                    break
                end
            end
        end
    end

    -- Defensive: 保护主人
    if mode == MODE.DEFENSIVE and not target then
        local ownerTarget = entities[owner.targetId]
        if ownerTarget and ownerTarget.kind == "mob" and not ownerTarget.dead then
            target = ownerTarget
            pet.targetId = target.id
            pet.autoAttack = true
        end
    end

    -- Passive: 不攻击
    if mode == MODE.PASSIVE then
        pet.autoAttack = false
        pet.targetId = nil
        target = nil
    end

    local events = {}

    if target and pet.autoAttack then
        -- 移动到目标附近
        local dx = target.pos.x - pet.pos.x
        local dz = target.pos.z - pet.pos.z
        local distSq = dx * dx + dz * dz
        if distSq > ATTACK_RANGE_SQ then
            local dist = math.sqrt(distSq)
            if dist > 0.01 then
                pet.pos.x = pet.pos.x + (dx / dist) * 5 * dt
                pet.pos.z = pet.pos.z + (dz / dist) * 5 * dt
            end
            pet.facing = math.atan(dx, -dz)
        else
            -- 自动攻击
            if not pet.swingTimer then pet.swingTimer = 0 end
            pet.swingTimer = pet.swingTimer + dt
            local speed = pet.weapon.speed or 2.0
            if pet.swingTimer >= speed then
                pet.swingTimer = pet.swingTimer - speed
                local dmg = pet.weapon.min + (pet.attackPower or 0) * 0.1
                dmg = math.max(1, math.floor(dmg + 0.5))
                target.hp = math.max(0, target.hp - dmg)
                table.insert(events, {
                    type = "pet_attack",
                    petId = pet.id,
                    ownerId = owner.id,
                    targetId = target.id,
                    dmg = dmg,
                })
                -- 宠物嘲讽
                if pet.petAutoTaunt and pet.petTauntTimer <= 0 then
                    pet.petTauntTimer = PET_TAUNT_COOLDOWN
                    table.insert(events, {
                        type = "pet_taunt",
                        petId = pet.id,
                        targetId = target.id,
                    })
                end
            end
        end
    else
        -- 跟随主人
        local dx = owner.pos.x - pet.pos.x
        local dz = owner.pos.z - pet.pos.z
        local distSq = dx * dx + dz * dz
        if distSq > FOLLOW_DISTANCE * FOLLOW_DISTANCE then
            local dist = math.sqrt(distSq)
            if dist > 0.01 then
                pet.pos.x = pet.pos.x + (dx / dist) * config.RUN_SPEED * 0.8 * dt
                pet.pos.z = pet.pos.z + (dz / dist) * config.RUN_SPEED * 0.8 * dt
            end
            pet.facing = math.atan(dx, -dz)
        end
    end

    return pet, events
end

--- 命令: 攻击目标
function M.commandAttack(owner, targetId, entities)
    if not owner or not owner.petEntityId then return false end
    local pet = entities[owner.petEntityId]
    if not pet or pet.dead then return false end
    local target = entities[targetId]
    if not target or target.dead then return false end
    pet.targetId = targetId
    pet.autoAttack = true
    return true
end

--- 命令: 跟随/停战
function M.commandFollow(owner, entities)
    if not owner or not owner.petEntityId then return false end
    local pet = entities[owner.petEntityId]
    if not pet then return false end
    pet.targetId = nil
    pet.autoAttack = false
    return true
end

--- 设置宠物模式
function M.setMode(owner, mode, entities)
    if not owner or not owner.petEntityId then return false end
    local pet = entities[owner.petEntityId]
    if not pet then return false end
    pet.petMode = mode
    return true
end

--- 同步宠物等级到主人
function M.syncPetLevel(owner, entities)
    if not owner or not owner.petEntityId then return end
    local pet = entities[owner.petEntityId]
    if not pet then return end
    pet.level = owner.level
    pet.maxHp = owner.level * 15 + 30
    pet.hp = math.min(pet.hp, pet.maxHp)
    pet.attackPower = 5 + owner.level * 3
end

return M
