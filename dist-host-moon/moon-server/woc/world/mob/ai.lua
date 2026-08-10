-- World of ClaudeCraft — Mob AI (Behavior Tree)
-- 巡逻 → 索敌 → 追击 → 战斗 → 返回/重生

local config = require("config")
local simrng = require("world.simrng")
local targeting = require("world.mob.targeting")
local combatProfile = require("world.mob.combat_profile")
local threatMod = require("world.mob.threat")
local moveModule = require("world.movement")
local spiritMod = require("world.spirit")

local M = {}

-- AI 状态
local AI_STATE = {
    IDLE = "idle",
    PATROL = "patrol",
    CHASING = "chasing",
    COMBAT = "combat",
    FLEEING = "flee",           -- 逃跑 (低血量)
    RETURNING = "returning",
    EVADING = "evade",          -- 脱离战斗中 (不可击败)
    DEAD = "dead",
}

-- 脱离检测阈值
local CHASE_STALL_THRESHOLD = 4.0   -- 4 秒无法接近目标判定为脱离
local EVADE_DURATION = 5.0          -- 脱离状态持续时间
local FLEE_HEALTH_PCT = 0.2         -- 20% 血量以下逃跑
local FLEE_HELP_RADIUS = 40         -- 逃跑召集盟友半径 (TS FLEE_HELP_RADIUS)
local FLEE_RECOVERY_SECONDS = 6.0   -- 逃跑后恢复

-- mob AI 数据: mobId → { state, target, spawnPos, profile, combatTimer, patrolDir, ... }
local aiData = {}

--- 初始化 mob AI
--- @param mob Entity
--- @param templateId string
--- @param spawnPos table {x, y, z}
function M.initMob(mob, templateId, spawnPos, opts)
    opts = opts or {}
    local proto = require("proto.load")
    local template = proto.getMob(templateId)

    -- 战斗技能 profile (abilities 配置表)
    local profile = combatProfile.getProfile(templateId or "default")
    profile = combatProfile.scaleProfile(profile, mob.level or 1)

    if template then
        -- 英雄难度缩放 (TS heroic: hp×1.5, dmg×1.3, level+2)
        local heroicScale = { hpMult = 1, dmgMult = 1, levelOffset = 0 }
        if opts.heroic then
            heroicScale = require("world.heroic_dungeon").getHeroicScale(true)
        end
        -- TS createMob (entity.ts:733-778): hpBase/hpPerLevel + elite 缩放
        local hpMult = (template.elite and 2.3 or 1) * heroicScale.hpMult
        local dmgMult = (template.elite and 1.5 or 1) * heroicScale.dmgMult
        local lvl = (mob.level or 1) + heroicScale.levelOffset
        mob.level = lvl
        mob.maxHp = math.round((template.hpBase + template.hpPerLevel * (lvl - 1)) * hpMult)
        mob.hp = mob.maxHp
        local dmg = (template.dmgBase + template.dmgPerLevel * (lvl - 1)) * dmgMult
        mob.weapon = {
            min = math.round(dmg * 0.8),
            max = math.round(dmg * 1.25),
            speed = template.attackSpeed,
        }
        mob.stats = mob.stats or {}
        mob.stats.armor = math.round(template.armorPerLevel * (lvl - 1))
        mob.moveSpeed = template.moveSpeed or mob.moveSpeed
        mob.scale = template.scale or 1
        mob.color = template.color or 0xffffff
        mob.aggroRadius = template.aggroRadius or 0
        -- Boss 机制计时器从 template 种子化 (TS createMob 758-771)
        if template.stomp then mob.stompTimer = template.stomp.every end
        if template.terrify then mob.terrifyTimer = template.terrify.every end
        if template.aoeSlow then mob.aoeSlowTimer = template.aoeSlow.every end
        if template.deathZoneCast then mob.deathZoneCastTimer = template.deathZoneCast.every end
        if template.infernoChannel then mob.infernoTimer = template.infernoChannel.every end
        if template.bigCast then mob.bigCastTimer = template.bigCast.every end
        if template.mendAlly then mob.mendTimer = template.mendAlly.every end
        if template.wardAllies then mob.wardTimer = template.wardAllies.every end
        if template.rally then mob.rallyTimer = template.rally.every end
        if template.warcry then mob.warcryTimer = template.warcry.every end
        -- 特殊标记
        mob.isBoss = template.boss or false
        mob.ccImmune = template.ccImmune or false
        mob.slowImmune = template.slowImmune or false
    else
        -- 回退到 combat_profile 内置数据
        mob.maxHp = profile.baseHp or 50
        mob.hp = mob.maxHp
        mob.attackPower = profile.baseAp or 5
        mob.weapon = mob.weapon or { min = 2, max = 4, speed = 2.0 }
    end

    mob.maxResource = 100
    mob.resource = 100

    -- Boss 兜底机制计时器
    if profile.isBoss or mob.isBoss then
        mob.stompTimer = mob.stompTimer or 15
        mob.deathZoneCastTimer = mob.deathZoneCastTimer or 10
        mob.terrifyTimer = mob.terrifyTimer or 25
        mob.aoeSlowTimer = mob.aoeSlowTimer or 20
        mob.bigCastTimer = mob.bigCastTimer or 12
        mob.infernoTimer = mob.infernoTimer or 30
    end

    aiData[mob.id] = {
        state = AI_STATE.IDLE,
        targetId = nil,
        spawnPos = { x = spawnPos.x, y = spawnPos.y, z = spawnPos.z },
        profile = profile,
        combatTimer = 0,
        cooldowns = {},
        patrolDir = simrng.randfloat(0, math.pi * 2),
        patrolTimer = 0,
        socialAggroId = nil,
        respawnTimer = 0,
    }

    return profile
end

--- 更新 mob AI (每个 tick)
--- @param mob Entity
--- @param entities table 全局实体表
--- @param players table 玩家元数据
--- @param dt number
--- @return table 事件列表
function M.updateMob(mob, entities, players, dt)
    local data = aiData[mob.id]
    if not data then return {} end

    if mob.dead then
        if data.state ~= AI_STATE.DEAD then
            data.state = AI_STATE.DEAD
            threatMod.clearThreat(mob.id)
        end
        -- Corpse tick (TS locomotion corpse branch): 尸体倒计时 + 尸体爆炸 + 召唤物 unravel
        local events = {}
        if mob.corpseTimer then
            mob.corpseTimer = mob.corpseTimer - dt
            -- 尸体爆炸 (detonate corpse): 对附近玩家造成伤害
            if mob.detonateTimer and mob.detonateTimer < 9999 then
                mob.detonateTimer = mob.detonateTimer - dt
                if mob.detonateTimer <= 0 then
                    for _, e in pairs(entities) do
                        if e.kind == "player" and not e.dead then
                            local dx = e.pos.x - mob.pos.x
                            local dz = e.pos.z - mob.pos.z
                            if dx * dx + dz * dz <= 144 then
                                local dmg = 15 + mob.level * 2
                                e.hp = math.max(0, e.hp - dmg)
                                table.insert(events, { type = "corpse_detonate", pid = e.id, mobId = mob.id, dmg = dmg })
                            end
                        end
                    end
                    mob.detonateTimer = 9999
                end
            end
        end
        return events
    end

    local events = {}

    -- TS locomotion:187 — mob 战斗计时器每 tick 递增
    mob.combatTimer = (mob.combatTimer or 0) + dt

    -- 更新冷却
    if data.cooldowns then
        for id, cd in pairs(data.cooldowns) do
            data.cooldowns[id] = cd - dt
            if data.cooldowns[id] <= 0 then data.cooldowns[id] = nil end
        end
        -- 同步到实体
        mob.cooldowns = data.cooldowns
    end

    local state = data.state

    if state == AI_STATE.IDLE or state == AI_STATE.PATROL then
        -- 巡逻/索敌
        data.patrolTimer = data.patrolTimer + dt

        -- 尝试寻找玩家
        local target = targeting.selectCombatTarget(mob, entities, threatMod)
        if target then
            data.targetId = target.id
            data.state = AI_STATE.CHASING
            events = M._startCombat(mob, data, target, entities)
        else
            -- 巡逻
            if data.patrolTimer > 3.0 then
                data.patrolTimer = 0
                data.patrolDir = data.patrolDir + (simrng.randfloat(-0.25, 0.25))
            end
            M._patrolMovement(mob, data, dt)
        end

    elseif state == AI_STATE.CHASING then
        local target = entities[data.targetId]
        if not target or target.dead or target.ghost then
            data.state = AI_STATE.RETURNING
            data.targetId = nil
            mob.chaseStall = 0
        else
            local dx = mob.pos.x - target.pos.x
            local dz = mob.pos.z - target.pos.z
            local distSq = dx * dx + dz * dz

            -- 脱离检测: 储存上一帧的距离
            local prevDistSq = data._prevDistSq or distSq
            if prevDistSq - distSq < 0.01 then
                -- 距离没有明显缩短 → 可能被地形阻挡
                mob.chaseStall = (mob.chaseStall or 0) + config.DT
            else
                mob.chaseStall = 0
            end
            data._prevDistSq = distSq

            -- 脱离判定
            if mob.chaseStall >= CHASE_STALL_THRESHOLD then
                data.state = AI_STATE.EVADING
                data.targetId = nil
                mob.chaseStall = 0
                mob.evadeEpoch = (mob.evadeEpoch or 0) + 1
                threatMod.clearThreat(mob.id)
                return {}  -- 立即进入脱离
            end

            -- 超出追击范围
            local leaseSq = targeting.getLeashRangeSq(mob)
            local homeDx = mob.pos.x - data.spawnPos.x
            local homeDz = mob.pos.z - data.spawnPos.z
            if homeDx * homeDx + homeDz * homeDz > leaseSq then
                data.state = AI_STATE.RETURNING
                data.targetId = nil
                mob.chaseStall = 0
                threatMod.clearThreat(mob.id)
            elseif distSq <= targeting.getCombatRangeSq() then
                data.state = AI_STATE.COMBAT
                mob.chaseStall = 0
            else
                M._chaseMovement(mob, target, dt)
            end
        end

    elseif state == AI_STATE.COMBAT then
        local target = entities[data.targetId]
        if not target or target.dead or target.ghost then
            data.state = AI_STATE.RETURNING
            data.targetId = nil
            mob.chaseStall = 0
        else
            local dx = mob.pos.x - target.pos.x
            local dz = mob.pos.z - target.pos.z
            local distSq = dx * dx + dz * dz
            local homeDx = mob.pos.x - data.spawnPos.x
            local homeDz = mob.pos.z - data.spawnPos.z

            -- 脱离检测
            local prevDistSq = data._prevDistSq or distSq
            if prevDistSq - distSq < 0.01 then
                mob.chaseStall = (mob.chaseStall or 0) + config.DT
            else
                mob.chaseStall = 0
            end
            data._prevDistSq = distSq

            if mob.chaseStall >= CHASE_STALL_THRESHOLD then
                data.state = AI_STATE.EVADING
                data.targetId = nil
                mob.chaseStall = 0
                mob.evadeEpoch = (mob.evadeEpoch or 0) + 1
                threatMod.clearThreat(mob.id)
                return {}
            end

            -- 超出追击范围
            if homeDx * homeDx + homeDz * homeDz > targeting.getLeashRangeSq(mob) then
                data.state = AI_STATE.RETURNING
                data.targetId = nil
                mob.chaseStall = 0
            elseif distSq > targeting.getCombatRangeSq() * 1.5 then
                data.state = AI_STATE.CHASING
            else
                -- 逃跑检查 (TS flee: 低血量且非Boss)
                if not mob.hasFled and not mob.isBoss and (mob.hp or 0) < mob.maxHp * FLEE_HEALTH_PCT then
                    data.state = AI_STATE.FLEEING
                    mob.fleeTimer = 0
                    mob.hostile = false
                    goto continue_combat
                end
                -- 威胁切换 (TS updateMobTarget: 110%/130% pull-over)
                targeting.updateMobTarget(mob, entities, threatMod)
                local switchedTarget = entities[mob.aggroTargetId]
                if switchedTarget and switchedTarget ~= target then
                    target = switchedTarget
                    data.targetId = target.id
                end
                local isCaster = data.profile and data.profile.isCaster
                if isCaster then
                    -- Caster 行为 (TS updateCasterCombat): 保持距离 + 远程施法
                    local preferredRange = data.profile.preferredRange or 20
                    local prSq = preferredRange * preferredRange
                    if distSq < (preferredRange * 0.6) ^ 2 then
                        -- 太近, 后退
                        M._retreatMovement(mob, target, dt)
                    elseif distSq > prSq then
                        -- 太远, 前进
                        M._chaseMovement(mob, target, dt)
                    end
                    data.combatTimer = data.combatTimer + dt
                    if data.combatTimer > 2.0 then
                        data.combatTimer = 0
                        local ab = combatProfile.selectAbility(mob, data.profile, target)
                        if ab then
                            data.cooldowns[ab.id] = ab.cooldown or 3
                            local ev = M._useAbility(mob, target, ab, entities)
                            if ev then table.insert(events, ev) end
                        end
                    end
                else
                    local autoResult = M._autoAttackMob(mob, target, data, dt)
                    if autoResult then table.insert(events, autoResult) end
                end

                -- Boss 机制执行 (仅近战 boss)
                if not isCaster then
                    local bossEvents = M._tickBossMechanics(mob, entities, data, dt)
                    for _, ev in ipairs(bossEvents) do table.insert(events, ev) end
                end

                -- 近战技能
                if not isCaster then
                    data.combatTimer = data.combatTimer + dt
                    if data.combatTimer > 2.0 then
                        data.combatTimer = 0
                        local ab = combatProfile.selectAbility(mob, data.profile, target)
                        if ab then
                            data.cooldowns[ab.id] = ab.cooldown or 3
                            local ev = M._useAbility(mob, target, ab, entities)
                            if ev then table.insert(events, ev) end
                        end
                    end
                end
            end
            ::continue_combat::
        end

    elseif state == AI_STATE.EVADING then
        -- 脱离: 免伤返回出生点
        mob.hostile = false  -- 标记为非敌对，damage.lua 中免伤
        mob.evadeStall = (mob.evadeStall or 0) + dt
        M._returnMovement(mob, data, dt)

        -- 到达出生点后全量重置 (TS resetEvadingMob)
        local dx = mob.pos.x - data.spawnPos.x
        local dz = mob.pos.z - data.spawnPos.z
        if dx * dx + dz * dz < 4 then
            M._resetEvadingMob(mob, data)
        end

    elseif state == AI_STATE.FLEEING then
        local target = entities[mob.aggroTargetId]
        if target then
            mob.fleeTimer = (mob.fleeTimer or 0) + dt
            -- 逃跑移动
            if mob.fleeTimer < FLEE_RECOVERY_SECONDS then
                M._fleeMovement(mob, target, dt)
                -- 逃跑召集盟友 (一次)
                if not mob.ralliedOnFlee then
                    mob.ralliedOnFlee = true
                    local rallyEvents = M._rallyFleeingAllies(mob, entities)
                    for _, ev in ipairs(rallyEvents) do table.insert(events, ev) end
                end
            else
                -- 恢复: 回到战斗或脱离
                mob.hasFled = true
                mob.fleeTimer = nil
                mob.ralliedOnFlee = nil
                if mob.hp > mob.maxHp * 0.35 then
                    data.state = AI_STATE.COMBAT
                    mob.hostile = true
                else
                    data.state = AI_STATE.RETURNING
                    data.targetId = nil
                    threatMod.clearThreat(mob.id)
                end
            end
        else
            data.state = AI_STATE.RETURNING
            data.targetId = nil
        end

    elseif state == AI_STATE.RETURNING then
        local dx = mob.pos.x - data.spawnPos.x
        local dz = mob.pos.z - data.spawnPos.z
        local distSq = dx * dx + dz * dz

        if distSq < 4 then
            -- 到达出生点
            data.state = AI_STATE.IDLE
            mob.hp = mob.maxHp  -- 回满血
            mob.pos.x = data.spawnPos.x
            mob.pos.z = data.spawnPos.z
        else
            -- 移回出生点
            M._returnMovement(mob, data, dt)
        end
    end

    -- 更新网格位置
    local gridModule = require("world.grid")
    if gridModule then
        gridModule.update(mob)
    end

    return events
end

--- 清理 mob AI 数据
function M.cleanup(mobId)
    aiData[mobId] = nil
    threatMod.clearThreat(mobId)
end

--- 获取 mob 状态
function M.getState(mobId)
    local d = aiData[mobId]
    return d and d.state or "unknown"
end

--- 设置社交仇恨目标
function M.setSocialAggro(mobId, targetId)
    local d = aiData[mobId]
    if d and d.state == AI_STATE.IDLE then
        d.targetId = targetId
        d.state = AI_STATE.CHASING
        threatMod.addThreat(mobId, targetId, 50)
    end
end

----------------------------------------
-- 内部函数
----------------------------------------

function M._patrolMovement(mob, data, dt)
    local speed = 1.5  -- 巡逻速度慢
    mob.pos.x = mob.pos.x + math.sin(data.patrolDir) * speed * dt
    mob.pos.z = mob.pos.z - math.cos(data.patrolDir) * speed * dt
    mob.facing = data.patrolDir

    -- 限制巡逻范围 (出生点 10 yards)
    local dx = mob.pos.x - data.spawnPos.x
    local dz = mob.pos.z - data.spawnPos.z
    if dx * dx + dz * dz > 100 then
        data.patrolDir = data.patrolDir + math.pi
    end
end

function M._chaseMovement(mob, target, dt)
    local dx = target.pos.x - mob.pos.x
    local dz = target.pos.z - mob.pos.z
    local dist = math.sqrt(dx * dx + dz * dz)
    if dist > 0.01 then
        -- TS pursuit profile: chaseSpeedMult (模板), 默认 0.9x
        local mult = (mob.moveSpeed and mob.moveSpeed / config.RUN_SPEED) or 0.9
        local speed = config.RUN_SPEED * mult
        mob.pos.x = mob.pos.x + (dx / dist) * speed * dt
        mob.pos.z = mob.pos.z + (dz / dist) * speed * dt
        mob.facing = math.atan(dx, -dz)
    end
end

function M._returnMovement(mob, data, dt)
    local dx = data.spawnPos.x - mob.pos.x
    local dz = data.spawnPos.z - mob.pos.z
    local dist = math.sqrt(dx * dx + dz * dz)
    if dist > 0.01 then
        local speed = config.RUN_SPEED * 0.7
        mob.pos.x = mob.pos.x + (dx / dist) * speed * dt
        mob.pos.z = mob.pos.z + (dz / dist) * speed * dt
        mob.facing = math.atan(dx, -dz)
    end
end

-- Caster 后退 (保持距离)
function M._retreatMovement(mob, target, dt)
    local dx = mob.pos.x - target.pos.x
    local dz = mob.pos.z - target.pos.z
    local dist = math.sqrt(dx * dx + dz * dz)
    if dist > 0.01 then
        local speed = config.RUN_SPEED * 0.7
        mob.pos.x = mob.pos.x + (dx / dist) * speed * dt
        mob.pos.z = mob.pos.z + (dz / dist) * speed * dt
        mob.facing = math.atan(-dx, dz)
    end
end

--- 逃跑移动 (远离目标) (TS fleeMoveSpeed)
function M._fleeMovement(mob, target, dt)
    local dx = mob.pos.x - target.pos.x
    local dz = mob.pos.z - target.pos.z
    local dist = math.sqrt(dx * dx + dz * dz)
    if dist > 0.01 then
        local speed = config.RUN_SPEED * 1.1  -- 逃跑更快
        mob.pos.x = mob.pos.x + (dx / dist) * speed * dt
        mob.pos.z = mob.pos.z + (dz / dist) * speed * dt
    end
end

--- 逃跑召集盟友 (TS rallyFleeingAllies: 附近的盟友被拉入战斗)
function M._rallyFleeingAllies(mob, entities)
    local events = {}
    for _, other in pairs(entities) do
        if other.kind == "mob" and not other.dead and other.id ~= mob.id
           and other.templateId == mob.templateId then
            local dx = mob.pos.x - other.pos.x
            local dz = mob.pos.z - other.pos.z
            if dx * dx + dz * dz <= FLEE_HELP_RADIUS * FLEE_HELP_RADIUS then
                local otherData = aiData[other.id]
                if otherData and (otherData.state == AI_STATE.IDLE or otherData.state == AI_STATE.PATROL) then
                    otherData.targetId = mob.aggroTargetId
                    otherData.state = AI_STATE.CHASING
                    if other.aggroTargetId ~= mob.aggroTargetId then
                        other.aggroTargetId = mob.aggroTargetId
                        table.insert(events, { type = "mob_rally", mobId = other.id, pid = mob.aggroTargetId })
                    end
                end
            end
        end
    end
    return events
end

--- 全量脱离重置 (TS resetEvadingMob: 清 aura/机制计时器/charge/召唤物/仇恨)
function M._resetEvadingMob(mob, data)
    mob.auras = {}
    mob.tappedById = nil
    mob.yelledEngage = false
    mob.stompTimer = nil
    mob.deathZoneCastTimer = nil
    mob.terrifyTimer = nil
    mob.aoeSlowTimer = nil
    mob.bigCastTimer = nil
    mob.infernoTimer = nil
    mob.mendTimer = nil
    mob.wardTimer = nil
    mob.rallyTimer = nil
    mob.warcryTimer = nil
    mob.chargeTargetId = nil
    mob.chargeTimeLeft = 0
    mob.chargePath = {}
    mob.firedSummons = 0
    mob.summonedIds = {}
    mob.enraged = false
    mob.healedThisPull = false
    mob.chaseStall = 0
    mob.forcedTargetId = nil
    mob.forcedTargetTimer = 0
    mob.fleeTimer = nil
    mob.hasFled = false
    mob.aiState = "idle"
    mob.aggroTargetId = nil
    data.state = AI_STATE.IDLE
    data.targetId = nil
    threatMod.clearThreat(mob.id)
    -- 满血
    mob.hp = mob.maxHp
end

function M._startCombat(mob, data, target, entities)
    mob.hostile = true
    mob.facing = math.atan(target.pos.x - mob.pos.x, -(target.pos.z - mob.pos.z))
    -- TS: aggroTargetId 用于 engagedPids pass
    mob.aggroTargetId = target.id
    mob.combatTimer = 0

    local events = {{ type = "combat_engage", mobId = mob.id, name = mob.name, pid = target.id }}

    -- Boss 喊话 (TS emitMobYell, 仅一次)
    if data.profile and data.profile.isBoss and not mob.yelledEngage then
        mob.yelledEngage = true
        local yellEvents = combatProfile.emitMobYell(mob, mob.name .. " engages!", entities)
        for _, ev in ipairs(yellEvents) do table.insert(events, ev) end
    end

    return events
end

function M._autoAttackMob(mob, target, data, dt)
    -- 完整命中表 (TS mob_swing): miss/dodge/crit/block + 护甲管道
    local mobSwing = require("world.mob.mob_swing")
    local ev = mobSwing.updateSwing(mob, target, dt)
    if not ev then return nil end

    if ev.dmg > 0 and spiritMod.checkDeath(target) then
        return { type = "death", pid = target.id, mobAutoAttack = true }
    end
    return { type = "mob_attack", mobId = mob.id, pid = target.id, dmg = ev.dmg, crit = ev.crit, result = ev.result }
end

function M._useAbility(mob, target, ability, entities)
    if not ability.effects then return nil end

    for _, effect in ipairs(ability.effects) do
        if effect.type == "damage" then
            local dmg = (ability.damage or 10) + (mob.attackPower or 0) * 0.2
            dmg = math.max(1, math.floor(dmg + 0.5))
            target.hp = math.max(0, target.hp - dmg)
            threatMod.addThreat(mob.id, target.id, dmg * 1.5)

            local ev = { type = "mob_ability", mobId = mob.id, ability = ability.name, pid = target.id, dmg = dmg }

            if spiritMod.checkDeath(target) then
                return { type = "death", pid = target.id, mobVictory = mob.id }
            end
            return ev

        elseif effect.type == "aoe" then
            local radius = effect.radius or 5
            local events = {}
            for _, e in pairs(entities) do
                if e.kind == "player" and not e.dead then
                    local dx = mob.pos.x - e.pos.x
                    local dz = mob.pos.z - e.pos.z
                    if dx * dx + dz * dz <= radius * radius then
                        local dmg = (ability.damage or 8) + (mob.attackPower or 0) * 0.1
                        dmg = math.max(1, math.floor(dmg + 0.5))
                        e.hp = math.max(0, e.hp - dmg)
                        if #events < (effect.maxTargets or 3) then
                            table.insert(events, { type = "mob_ability", mobId = mob.id, ability = ability.name, pid = e.id, dmg = dmg })
                        end
                    end
                end
            end
            return events[1]

        elseif effect.type == "debuff" or effect.type == "dot" then
            local auraMod = require("world.combat.aura")
            local dur = effect.duration or 6
            local dot = auraMod.new(ability.id .. "_dot", ability.name, dur, {
                tickInterval = effect.tickInterval or 2,
                damageMod = effect.type == "dot" and -((effect.tickValue or 5) + (mob.attackPower or 0) * 0.05) or nil,
                mechanic = effect.mechanic,
                isDebuff = true,
                auraType = effect.auraType or "poison",
                sourceId = mob.id,
            })
            auraMod.applyAura(target, dot)
            return { type = "mob_debuff", mobId = mob.id, pid = target.id, debuff = ability.name }
        end
    end

    return nil
end

--- Boss 机制 tick (Stomp, Death Zone, Terrify, AoE Slow)
function M._tickBossMechanics(mob, entities, data, dt)
    local events = {}
    local profile = data.profile
    if not profile or not profile.isBoss then return events end

    -- Stomp (15秒CD, 12码范围)
    mob.stompTimer = (mob.stompTimer or 15) - dt
    if mob.stompTimer <= 0 then
        mob.stompTimer = 15
        for _, e in pairs(entities) do
            if e.kind == "player" and not e.dead then
                local dx = e.pos.x - mob.pos.x; local dz = e.pos.z - mob.pos.z
                if dx * dx + dz * dz <= 144 then
                    local dmg = 20 + mob.level * 3
                    e.hp = math.max(0, e.hp - dmg)
                    table.insert(events, { type = "boss_stomp", pid = e.id, mobId = mob.id, dmg = dmg })
                end
            end
        end
    end

    -- Death Zone (10秒CD)
    mob.deathZoneCastTimer = (mob.deathZoneCastTimer or 10) - dt
    if mob.deathZoneCastTimer <= 0 then
        mob.deathZoneCastTimer = 10
        for _, e in pairs(entities) do
            if e.kind == "player" and not e.dead and simrng.random() < 0.3 then
                table.insert(events, { type = "boss_death_zone", pid = e.id, mobId = mob.id,
                    duration = 6 })
            end
        end
    end

    -- Terrify (25秒CD)
    mob.terrifyTimer = (mob.terrifyTimer or 25) - dt
    if mob.terrifyTimer <= 0 then
        mob.terrifyTimer = 25
        for _, e in pairs(entities) do
            if e.kind == "player" and not e.dead then
                local dx = e.pos.x - mob.pos.x; local dz = e.pos.z - mob.pos.z
                if dx * dx + dz * dz <= 400 then
                    table.insert(events, { type = "boss_terrify", pid = e.id, mobId = mob.id, duration = 3 })
                end
            end
        end
    end

    return events
end

return M
