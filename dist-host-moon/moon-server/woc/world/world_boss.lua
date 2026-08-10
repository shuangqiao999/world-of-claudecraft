-- World of ClaudeCraft — World Boss System
-- 对应原项目 src/sim/world_boss.ts
-- 固定间隔刷新、HP 随参与者缩放、个人拾取 (raid 锁定)、确定性 rng 顺序

local simrng = require("world.simrng")
local M = {}

local WORLD_BOSS_INTERVAL_SECONDS = 3600
local WORLD_BOSS_CORPSE_SECONDS = 900
local WORLD_BOSS_LOCKOUT_PREFIX = "worldboss:"

local function worldBossLockoutId(bossId)
    return WORLD_BOSS_LOCKOUT_PREFIX .. bossId
end

-- 世界 Boss 定义 (TS thunzharr_waking_peak: 40k solo +5k/参与者, 上限 1M)
local WORLD_BOSSES = {
    {
        id = "thunzharr",
        templateId = "thunzharr_waking_peak",
        name = "Thunzharr, Waking Peak",
        pos = { x = 110, z = 760 },
        intervalSeconds = WORLD_BOSS_INTERVAL_SECONDS,
        hpScale = { base = 40000, perPlayer = 5000, max = 1000000 },
        loot = {
            { itemId = "ancient_bark", chance = 0.9, rollGroup = "gear" },
            { itemId = "treant_heart", chance = 0.3, rollGroup = "gear" },
            { itemId = "plate_chest", chance = 0.2, rollGroup = "gear" },
        },
        copper = 500,
    },
}

-- 调度状态
local worldBossState = {
    nextAt = { 300 },       -- 首次 5 分钟后刷新
    entityIds = { nil },    -- 当前存活 boss 实体
    currentDef = nil,
    contributors = {},      -- hate-table 派生的贡献者
    bossDamagers = {},      -- 永久伤害者
    spawnAnnounced = false,
}

--- 初始化
function M.init()
    worldBossState.nextAt = { 300 }
    worldBossState.entityIds = { nil }
    worldBossState.contributors = {}
    worldBossState.bossDamagers = {}
    worldBossState.currentDef = nil
end

--- 检查贡献者 (从仇恨表派生, TS worldBossContributors)
--- @param mob Entity
--- @param players table
function M._contributors(mob, players)
    local seen = {}
    local out = {}
    for attackerId, _ in pairs(mob.threat or {}) do
        local pid = attackerId
        -- 宠物威胁归属主人
        -- (简化: threat 表直接存 pid)
        if not seen[pid] then
            seen[pid] = true
            if players[pid] then table.insert(out, pid) end
        end
    end
    table.sort(out)  -- 按 entityId 排序保证 rng 顺序确定
    return out
end

--- HP 缩放 (TS scaleWorldBossHp: 只在变大, base + perPlayer*(n-1), 钳制 max)
function M._scaleHp(boss, def, participants)
    if boss.maxHp >= def.hpScale.max then return end
    local target = math.min(def.hpScale.max, def.hpScale.base + def.hpScale.perPlayer * math.max(0, participants - 1))
    if target > boss.maxHp then
        local delta = target - boss.maxHp
        boss.maxHp = target
        boss.hp = math.min(boss.maxHp, boss.hp + delta)
    end
end

--- 生成个人拾取 (TS rollWorldBossLoot)
function M._rollPersonalLoot(mob, def, contributors, players)
    local events = {}
    for _, pid in ipairs(contributors) do
        -- raid 锁定检查
        local meta = players[pid]
        if not meta then goto continue_contrib end
        if meta.worldBossLockouts and meta.worldBossLockouts[def.id] then goto continue_contrib end

        local rolledGroups = {}
        local gearWon = false
        for _, entry in ipairs(def.loot) do
            if entry.rollGroup then
                if rolledGroups[entry.rollGroup] then goto continue_entry end
                rolledGroups[entry.rollGroup] = true
                -- 组内 roll (一次一个, 顺序固定)
                local roll = simrng.random()
                local cumulative = 0
                for _, g in ipairs(def.loot) do
                    if g.rollGroup == entry.rollGroup then
                        cumulative = cumulative + g.chance
                        if roll < cumulative then
                            if g.itemId and not gearWon then
                                table.insert(events, { type = "world_boss_loot", pid = pid, itemId = g.itemId, count = 1, personal = true })
                                gearWon = true
                            end
                            goto continue_entry
                        end
                    end
                end
                goto continue_entry
            end
            -- 非组条目: 独立 chance
            if simrng.random() < (entry.chance or 0) and entry.itemId then
                table.insert(events, { type = "world_boss_loot", pid = pid, itemId = entry.itemId, count = 1, personal = true })
            end
            ::continue_entry::
        end
        -- 铜币
        if def.copper and def.copper > 0 then
            table.insert(events, { type = "world_boss_loot", pid = pid, copper = def.copper })
        end
        ::continue_contrib::
    end
    return events
end

--- Tick: 世界 Boss 调度
function M.tick(entities, players, createMobFn, gridModule, currentTime)
    local events = {}
    local def = WORLD_BOSSES[1]
    local liveId = worldBossState.entityIds[1]

    if liveId then
        local boss = entities[liveId]
        if not boss then
            worldBossState.entityIds[1] = nil
        elseif not boss.dead then
            -- HP 缩放 (每 tick)
            local participants = #M._contributors(boss, players)
            M._scaleHp(boss, def, participants)
            -- 记录永久伤害者 (bossDamagers 来自仇恨表)
            for attackerId, _ in pairs(boss.threat or {}) do
                if players[attackerId] then worldBossState.bossDamagers[attackerId] = true end
            end
        end

        if boss and boss.dead then
            -- Boss 死亡: 尸体 900s 后移除
            boss.corpseTimer = (boss.corpseTimer or WORLD_BOSS_CORPSE_SECONDS)
            -- 结算个人拾取 (在仇恨表清空前)
            if not worldBossState._lootSettled then
                worldBossState._lootSettled = true
                local contribs = M._contributors(boss, players)
                -- 合并永久伤害者
                local merged = {}
                for pid, _ in pairs(worldBossState.bossDamagers) do
                    if players[pid] then table.insert(merged, pid) end
                end
                for _, pid in ipairs(contribs) do
                    if not worldBossState.bossDamagers[pid] then table.insert(merged, pid) end
                end
                table.sort(merged)
                local lootEvents = M._rollPersonalLoot(boss, def, merged, players)
                for _, ev in ipairs(lootEvents) do table.insert(events, ev) end
                table.insert(events, { type = "world_boss_defeated", name = def.name })
            end
            -- 尸体到期移除
            boss.corpseTimer = boss.corpseTimer - (0.05)
            if boss.corpseTimer <= 0 then
                entities[liveId] = nil
                worldBossState.entityIds[1] = nil
                worldBossState.currentDef = nil
                worldBossState._lootSettled = nil
                worldBossState.bossDamagers = {}
                worldBossState.nextAt[1] = currentTime + def.intervalSeconds
            end
        end
    end

    -- 刷新
    if currentTime >= worldBossState.nextAt[1] and worldBossState.entityIds[1] == nil then
        local pos = { x = def.pos.x, z = def.pos.z }
        local mob = createMobFn(def.templateId, def.name, 20, pos)
        if mob then
            entities[mob.id] = mob
            gridModule.insert(mob)
            worldBossState.entityIds[1] = mob.id
            worldBossState.currentDef = def
            worldBossState.bossDamagers = {}
            worldBossState._lootSettled = nil
            mob.bossDamagers = {}
            mob.maxHp = def.hpScale.base
            mob.hp = mob.maxHp
            table.insert(events, { type = "world_boss_spawn", name = def.name, mobId = mob.id, level = 20 })
            print(string.format("[WorldBoss] %s spawned at (%d, %d) id=%d", def.name, def.pos.x, def.pos.z, mob.id))
        end
    end

    return events
end

--- 记录对 boss 造成伤害 (供 bossDamagers)
function M.noteDamage(bossId, pid)
    worldBossState.bossDamagers[pid] = true
end

--- 检查 boss 拾取锁定
function M.isLootEligible(meta, bossId)
    if not meta or not meta.worldBossLockouts then return true end
    local untilTime = meta.worldBossLockouts[worldBossLockoutId(bossId)]
    return not untilTime or untilTime <= os.time()
end

--- 领取时记录锁定
function M.markLooted(meta, bossId, untilMs)
    if not meta.worldBossLockouts then meta.worldBossLockouts = {} end
    if untilMs > 0 then
        meta.worldBossLockouts[worldBossLockoutId(bossId)] = untilMs
    end
end

return M
