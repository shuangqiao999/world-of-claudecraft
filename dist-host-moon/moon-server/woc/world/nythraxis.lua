-- World of ClaudeCraft — Nythraxis the Corrupted (Complete Raid Encounter)
-- 5 阶段完整 Boss AI: 对话 → 防守 → 第一阶段 → Aldric干预 → 狂暴
-- 机制: Wardstone守卫/死亡区域/地狱火/召唤小怪/狂暴/石墙禁制/晕震预警
-- 对应原项目 src/sim/encounters/nythraxis.ts (完整)

local simrng = require("world.simrng")
local M = {}

local NYTHRAXIS_ID = "nythraxis_the_corrupted"
local WARDSTONE_COUNT = 4
local ADDS_INTERVAL = 30
local DEATH_ZONE_RADIUS = 8
local INFERNO_RADIUS = 12
local INFERNO_DURATION = 8
local INFERNO_TICK = 0.8

local PHASE = {
    INACTIVE = 0, INTRO = 1, DEFENSE = 2,
    BOSS_P1 = 3, ALDRIC = 4, BOSS_P2 = 5,
    VICTORY = 6,
}

local encounters = {}

--- 初始化遭遇
function M.startEncounter(bossEntity, bossPos, playerPids)
    local wardstones = {}
    for i = 1, WARDSTONE_COUNT do
        local angle = (i - 1) * (math.pi / 2) + math.pi / 4
        table.insert(wardstones, {
            id = "wardstone_" .. i,
            hp = 500, maxHp = 500,
            pos = { x = bossPos.x + math.cos(angle) * 15, z = bossPos.z + math.sin(angle) * 15 },
            broken = false,
            barrierActive = true,
        })
    end

    encounters[bossEntity.id] = {
        bossId = bossEntity.id,
        boss = bossEntity,
        bossPos = bossPos,
        phase = PHASE.INTRO,
        phaseTimer = 8,
        wardstones = wardstones,
        addsSpawnTimer = ADDS_INTERVAL,
        deathZones = {},  -- {pos, radius, remaining}
        inferno = nil,     -- {pos, radius, remaining, tickTimer}
        aldricArrived = false,
        playerPids = playerPids or {},
        p1Timer = 120,
        p2Timer = 90,
        addCount = 0,
        stompTimer = 15,
        telegraphPosition = nil,
        telegraphTimer = 0,
    }
    return bossEntity.id
end

--- 更新遭遇 (每 tick)
function M.update(entities, players, dt, simTime)
    local events = {}
    local toRemove = {}

    for encId, enc in pairs(encounters) do
        local boss = entities[enc.bossId]
        if not boss or boss.dead then
            if enc.phase ~= PHASE.VICTORY then
                table.insert(events, {
                    type = "nythraxis_defeated",
                    bossId = enc.bossId,
                })
                enc.phase = PHASE.VICTORY
            end
            goto cleanup_enc
        end

        enc.phaseTimer = enc.phaseTimer - dt

        -- ==== Phase 1: 对话 ====
        if enc.phase == PHASE.INTRO then
            if enc.phaseTimer <= 5 and not enc._saidIntro then
                enc._saidIntro = true
                table.insert(events, {
                    type = "nythraxis_dialogue",
                    text = "Fools! You dare enter my sanctum? The wardstones shall be your tomb.",
                    speaker = NYTHRAXIS_ID,
                })
            end
            if enc.phaseTimer <= 0 then
                enc.phase = PHASE.DEFENSE
                enc.phaseTimer = 0
                table.insert(events, {
                    type = "nythraxis_phase",
                    phase = "defense",
                    text = "Destroy the wardstones to weaken the barrier!",
                })
            end

        -- ==== Phase 2: 守卫石防守 ====
        elseif enc.phase == PHASE.DEFENSE then
            -- 守卫石存活检查
            local alive = 0
            for _, stone in ipairs(enc.wardstones) do
                if stone.hp > 0 then alive = alive + 1 end
            end

            if alive == 0 then
                enc.phase = PHASE.BOSS_P1
                enc.phaseTimer = 90
                boss.hostile = true
                table.insert(events, {
                    type = "nythraxis_wardstones_down",
                    text = "The wardstones crumble! Nythraxis is vulnerable — strike now!",
                })
            else
                -- 刷新小怪
                enc.addsSpawnTimer = enc.addsSpawnTimer - dt
                if enc.addsSpawnTimer <= 0 then
                    enc.addsSpawnTimer = ADDS_INTERVAL
                    enc.addCount = enc.addCount + 1
                    local count = enc.addCount >= 3 and 4 or 2
                    table.insert(events, {
                        type = "nythraxis_adds_spawn",
                        count = count,
                        bossId = enc.bossId,
                        bossPos = enc.bossPos,
                    })
                end
            end

        -- ==== Phase 3: Boss 第一阶段 ====
        elseif enc.phase == PHASE.BOSS_P1 then
            M._bossPhase1Mechanics(enc, boss, dt, events)

            -- 25% HP 触发地狱火
            if boss.hp <= boss.maxHp * 0.25 and not enc._infernoTriggered then
                enc._infernoTriggered = true
                enc.inferno = {
                    pos = { x = boss.pos.x, z = boss.pos.z },
                    radius = INFERNO_RADIUS,
                    remaining = INFERNO_DURATION,
                    tickTimer = 0,
                }
                table.insert(events, {
                    type = "nythraxis_inferno",
                    text = "BURN IN CHAOS FIRE!",
                    pos = enc.inferno.pos,
                    radius = INFERNO_RADIUS,
                })
            end

            -- 地狱火 tick
            M._tickInferno(enc, entities, players, dt, events)

            -- HP 到 0 或时间到 → Aldric 阶段
            if boss.hp <= 0 or enc.phaseTimer <= 0 then
                enc.phase = PHASE.ALDRIC
                enc.phaseTimer = 6
                enc.aldricArrived = true
                boss.hp = math.max(1, math.floor(boss.maxHp * 0.15 + 0.5))
                boss.invulnerable = true
                table.insert(events, {
                    type = "nythraxis_aldric_arrives",
                    text = "Aldric Lightbringer: 'Stand aside, heroes! I will seal the corruption!'",
                })
            end

        -- ==== Phase 4: Aldric 干预 ====
        elseif enc.phase == PHASE.ALDRIC then
            if enc.phaseTimer <= 0 then
                enc.phase = PHASE.BOSS_P2
                enc.phaseTimer = 60
                boss.invulnerable = false
                boss.enraged = true
                boss.attackPower = boss.attackPower * 1.5
                boss.maxHp = math.floor(boss.maxHp * 0.6 + 0.5)
                boss.hp = boss.maxHp
                enc._sealed = true
                table.insert(events, {
                    type = "nythraxis_sealed",
                    text = "The seal holds! Finish him — he is weakened but enraged!",
                })
            end

        -- ==== Phase 5: Boss 第二阶段 (狂暴) ====
        elseif enc.phase == PHASE.BOSS_P2 then
            -- 狂暴增强机制
            M._bossPhase2Mechanics(enc, boss, dt, events, simTime)

            -- HP 耗尽 = 胜利
            if boss.hp <= 0 then
                enc.phase = PHASE.VICTORY
                boss.dead = true
                table.insert(events, {
                    type = "nythraxis_victory",
                    text = "Nythraxis has been sealed forever! The realm is safe.",
                })
            end
        end

        ::cleanup_enc::
    end

    for encId, _ in pairs(toRemove) do
        encounters[encId] = nil
    end

    return events
end

--- 第一阶段 Boss 机制
function M._bossPhase1Mechanics(enc, boss, dt, events)
    -- Stomp 晕震预警(15秒cd)
    enc.stompTimer = (enc.stompTimer or 15) - dt
    if enc.stompTimer <= 2.5 and not enc._telegraphShown then
        enc._telegraphShown = true
        enc.telegraphPosition = { x = boss.pos.x, z = boss.pos.z }
        enc.telegraphTimer = 2.5
        table.insert(events, {
            type = "nythraxis_telegraph",
            ability = "stomp",
            pos = enc.telegraphPosition,
            radius = 12,
            warningTime = 2.5,
        })
    end
    if enc.stompTimer <= 0 and enc._telegraphShown then
        enc.stompTimer = 15
        enc._telegraphShown = false
        -- Stomp 对范围内的玩家造成伤害
        for _, pid in ipairs(enc.playerPids) do
            local p = entities[pid]
            if p and not p.dead then
                local dx = p.pos.x - boss.pos.x
                local dz = p.pos.z - boss.pos.z
                if dx * dx + dz * dz <= 144 then
                    table.insert(events, {
                        type = "nythraxis_stomp",
                        pid = pid,
                        dmg = 60 + boss.level * 5,
                    })
                end
            end
        end
    end

    -- Death Zone 时间
    enc.dzTimer = (enc.dzTimer or 10) - dt
    if enc.dzTimer <= 0 then
        enc.dzTimer = 10
        -- 向随机玩家位置放置死亡区域
        for _, pid in ipairs(enc.playerPids) do
            local p = entities[pid]
            if p and not p.dead and simrng.chance(0.4) then
                table.insert(enc.deathZones, {
                    pos = { x = p.pos.x, z = p.pos.z },
                    radius = DEATH_ZONE_RADIUS,
                    remaining = 6,
                })
            end
        end
    end
end

--- 地狱火 tick
function M._tickInferno(enc, entities, players, dt, events)
    if not enc.inferno then return end
    enc.inferno.tickTimer = enc.inferno.tickTimer + dt
    enc.inferno.remaining = enc.inferno.remaining - dt

    if enc.inferno.remaining <= 0 then
        enc.inferno = nil
        return
    end

    if enc.inferno.tickTimer >= INFERNO_TICK then
        enc.inferno.tickTimer = enc.inferno.tickTimer - INFERNO_TICK

        for _, pid in ipairs(enc.playerPids) do
            local p = entities[pid]
            if p and not p.dead then
                local dx = p.pos.x - enc.inferno.pos.x
                local dz = p.pos.z - enc.inferno.pos.z
                if dx * dx + dz * dz <= INFERNO_RADIUS * INFERNO_RADIUS then
                    local dmg = 15 + math.random() * 5
                    table.insert(events, {
                        type = "nythraxis_inferno_tick",
                        pid = pid,
                        dmg = dmg,
                    })
                end
            end
        end
    end
end

--- 第二阶段 Boss 机制 (狂暴)
function M._bossPhase2Mechanics(enc, boss, dt, events, simTime)
    -- 死亡区域仍然放置
    enc.dzTimer = (enc.dzTimer or 4) - dt
    if enc.dzTimer <= 0 then
        enc.dzTimer = 4
        for _, pid in ipairs(enc.playerPids) do
            local p = entities[pid]
            if p and not p.dead and simrng.chance(0.6) then
                table.insert(enc.deathZones, {
                    pos = { x = p.pos.x, z = p.pos.z },
                    radius = DEATH_ZONE_RADIUS,
                    remaining = 8,
                })
            end
        end
    end

    -- 二次 Stomp (缩短至 8 秒)
    enc.stompTimer = (enc.stompTimer or 8) - dt
    if enc.stompTimer <= 1.5 and not enc._telegraphShown then
        enc._telegraphShown = true
        enc.telegraphPosition = { x = boss.pos.x, z = boss.pos.z }
        enc.telegraphTimer = 1.5
        table.insert(events, {
            type = "nythraxis_telegraph",
            ability = "fury_stomp",
            pos = enc.telegraphPosition,
            radius = 15,
            warningTime = 1.5,
        })
    end
    if enc.stompTimer <= 0 and enc._telegraphShown then
        enc.stompTimer = 8
        enc._telegraphShown = false
        for _, pid in ipairs(enc.playerPids) do
            local p = entities[pid]
            if p and not p.dead then
                local dx = p.pos.x - boss.pos.x
                local dz = p.pos.z - boss.pos.z
                if dx * dx + dz * dz <= 225 then
                    table.insert(events, {
                        type = "nythraxis_stomp",
                        pid = pid,
                        dmg = 120 + boss.level * 8,
                    })
                end
            end
        end
    end

    -- 死亡区域 tick + 过期清理
    local activeDZ = {}
    for _, dz in ipairs(enc.deathZones) do
        dz.remaining = dz.remaining - dt
        if dz.remaining > 0 then
            table.insert(activeDZ, dz)
            -- 每 1 秒 tick
            dz.tickTimer = (dz.tickTimer or 0) + dt
            if dz.tickTimer >= 1 then
                dz.tickTimer = dz.tickTimer - 1
                for _, pid in ipairs(enc.playerPids) do
                    local p = entities[pid]
                    if p and not p.dead then
                        local dx = p.pos.x - dz.pos.x
                        local dz2 = p.pos.z - dz.pos.z
                        if dx * dx + dz2 * dz2 <= dz.radius * dz.radius then
                            table.insert(events, {
                                type = "nythraxis_death_zone_tick",
                                pid = pid,
                                dmg = 25 + 10 * simrng.random(),
                            })
                        end
                    end
                end
            end
        end
    end
    enc.deathZones = activeDZ
end

function M.getEncounter(bossId)
    return encounters[bossId]
end

return M
