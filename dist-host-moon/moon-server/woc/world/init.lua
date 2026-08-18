-- World of ClaudeCraft — World Service
-- 核心仿真: tick 循环、实体管理、命令调度
-- 对应原项目 server/game.ts GameServer + src/sim/sim.ts tick()
-- 确定性协议: 所有随机调用使用共享 simrng 单例

local moon = require("moon")
local json = require("json")
local config = require("config")
local moonCore = require("moon.core")
local Entity = require("world.entity")
local simrng = require("world.simrng")
local move = require("world.movement")
local grid = require("world.grid")
local chat = require("world.chat")
local snapshot = require("world.snapshot")
local ghost = require("world.ghost")
local jh = require("shared.json_helpers")
local playerStats = require("world.player_stats")

-- 战斗模块
local damage = require("world.combat.damage")
local healMod = require("world.combat.heal")
local castSys = require("world.combat.cast")
local eventWire = require("world.combat.event_wire")
local aura = require("world.combat.aura")
local autoAttack = require("world.combat.auto_attack")
local combatState = require("world.combat_state")
local wanted = require("world.wanted")
local fxDispatch = require("world.combat.effect_dispatch")
local spirit = require("world.spirit")
local abilities = require("world.abilities")

-- 高级战斗模块 (Batch A+B)
local ccDr = require("world.combat.cc_dr")
local spellResist = require("world.combat.spell_resist")
local rage = require("world.combat.rage")
local formSwing = require("world.combat.form_swing")
local setProcs = require("world.combat.set_procs")
local exclusiveAura = require("world.combat.exclusive_aura")
local empower = require("world.combat.empower")

-- 物理引擎 (Batch C)
local physics = require("world.physics")
local terrain = require("world.terrain")

-- Mob AI 模块
local mobAI = require("world.mob.ai")
local mobLifecycle = require("world.mob.lifecycle")
local mobProfile = require("world.mob.combat_profile")
local threatMod = require("world.mob.threat")
local targetingMod = require("world.mob.targeting")

-- Phase 5-6 模块
local inventory = require("world.inventory")
local vendor = require("world.vendor")
local quest = require("world.quest")
local talent = require("world.talent")
local partyMod = require("world.party")
local tradeMod = require("world.trade")
local duelMod = require("world.duel")
local bankMod = require("world.bank")
local profession = require("world.profession.crafting")
local instanceMod = require("world.instance.instance")

-- Phase 2 新模块
local regen = require("world.regen")
local warriorStance = require("world.warrior_stance")
local restedXp = require("world.rested_xp")
local worldBoss = require("world.world_boss")
local arena = require("world.arena")
local battleground = require("world.battleground")

-- Batch 1: 地面AoE + 飞行物 + 宠物AI + 裂隙
local groundAoE = require("world.ground_aoe")
local projectile = require("world.projectile")
local petAI = require("world.pet_ai")
local rift = require("world.rift")

-- Batch 2: Delve + 地下城查找器 + 卡牌决斗 + 战利品 + 就位检查
local delve = require("world.delve")
local dungeonFinder = require("world.dungeon_finder")
local cardDuel = require("world.card_duel")
local lootRoll = require("world.loot_roll")
local readyCheck = require("world.ready_check")

-- Batch 3: 功勋 + PvP + 公会金库 + 团队锁定
local deeds = require("world.deeds")
local pvpHonor = require("world.pvp_honor")
local guildBank = require("world.guild_bank")
local raidLockout = require("world.raid_lockout")

-- Batch 4: 钓鱼 + 坐骑 + 寻路 + 解除卡死 + 复活提议 + 英雄副本 + Raid
local fishing = require("world.fishing")
local mount = require("world.mount")
local pathfind = require("world.pathfind")
local unstuck = require("world.unstuck")
local resurrectionOffer = require("world.resurrection_offer")
local heroicDungeon = require("world.heroic_dungeon")
local nythraxis = require("world.nythraxis")

-- Phase C 新模块: breath/frozenOrbs/despawnDecay
local breath = require("world.breath")
local frozenOrb = require("world.frozen_orb")
local despawnDecay = require("world.despawn_decay")
local delayedEvents = require("world.delayed_events")
local xp = require("world.xp")
local swimFatigue = require("world.swim_fatigue")
local dragonkinBrood = require("world.dragonkin_brood")
local pedestrian = require("world.pedestrian")
local doorTriggers = require("world.door_triggers")
local escorts = require("world.escorts")
local commissionOrders = require("world.commission_orders")
local valeCup = require("world.vale_cup")
local naturesFury = require("world.natures_fury")
local zone = require("world.zone")

local entities = {}     -- id → Entity
local players = {}      -- pid → PlayerMeta
local snapSessions = {} -- pid → { seenEntities, lastDyn, lastSent } 快照 delta 追踪

-- 跨分片 ghost 实体 (id → {x, z, json}); ghostByShard 按源分片分组, 便于全量替换
local ghostEntities = {}
local ghostByShard = {}
local ghostTick = 0

-- 内存泄漏诊断: mob 生成/移除计数 (生成源按 templateId 归组)
local mobSpawnCount = 0
local mobRemoveCount = 0
local mobMigrateCount = 0
local mobSpawnByTemplate = {}

-- 分片标识: 从服务名 "world_N" 解析 (main.lua 以 world_0..world_N-1 创建)
local shardId = 0
local shardCount = 1
do
    local name = moon.name or ""
    local idx = name:match("^world_(%d+)$")
    if idx then shardId = tonumber(idx) end
    shardCount = config.getWorldShards()
end
local function shardTag(s)
    return string.format("[W%d/%d] ", shardId, shardCount) .. s
end

-- forward 声明 (pushSocialFrame 定义在 joinPlayer 之后, 需先声明)
local pushSocialFrame
local simTime = 0
local tick = 0
local running = false
local nextId = 10000

-- 实体 id 全局唯一: 前缀分片 id, 避免跨分片 ghost 实体 id 冲突 (shardId * 1000000 + 本地计数)
local function allocId() nextId = nextId + 1; return shardId * 1000000 + nextId end

-- 服务查找
local function dbSvc() return moon.queryservice("db") end
-- 多 gate (P1): gate 由 pid 反解 (pid = gateIndex * GATE_PID_STRIDE + seq), 无需注册表
local function gateOf(pid) return math.floor(pid / config.GATE_PID_STRIDE) end
local function gateSvcFor(pid) return moon.queryservice("gate_" .. gateOf(pid)) end
local function allGateSvcs()
    local list = {}
    for k = 0, config.getGateCount() - 1 do
        local s = moon.queryservice("gate_" .. k)
        if s then list[#list + 1] = s end
    end
    return list
end

-- 帮助函数
-- 事件路由: 个人事件 (带 pid/toPid) 只发相关玩家; 世界事件 (无 pid) 广播全部
-- 与 server/game.ts routeEvents 的 per-session 语义对齐, 避免私聊/个人 loot 泄漏
local function noteEvents(evs)
    if not evs or #evs == 0 then return end
    local perPid = {}
    local world = {}
    for _, ev in ipairs(evs) do
        local recipient = ev.pid or ev.toPid
        if type(recipient) == "number" then
            if not perPid[recipient] then perPid[recipient] = {} end
            table.insert(perPid[recipient], ev)
        else
            table.insert(world, ev)
        end
    end
    if #world > 0 then
        -- 世界事件: 广播到所有 gate (各 gate 只发给本分片会话)
        for _, gs in ipairs(allGateSvcs()) do
            moon.send("lua", gs, { t = "broadcastSnap", shard = shardId, data = jh.buildEventsFrame(world) })
        end
    end
    for targetPid, evs2 in pairs(perPid) do
        local gs = gateSvcFor(targetPid)
        if gs then moon.send("lua", gs, { t = "sendToPlayer", pid = targetPid, frame = jh.buildEventsFrame(evs2) }) end
    end
end

-- 模块级 safeCall: 供 combatTick 等独立函数复用 (doGameTick 内的局部版本已移除)
local function safeCall(modName, fn)
    local ok, result = pcall(fn)
    if not ok then
        print(string.format("[World] TICK ERROR in %s: %s", modName, tostring(result)))
    end
    return ok and result or {}
end

-- 分相计时 (PhaseDiag): 每 200 tick (10s) 打印各相耗时(ms) + 内存/GC
local phaseAcc = {}
local phaseOrder = { "prologue", "player", "combat", "misc", "broadcast", "bcastBuild", "bcastSend", "brood", "engaged", "save" }
local phaseLastReport = 0
local function phaseEnd(name, t0)
    phaseAcc[name] = (phaseAcc[name] or 0) + (moonCore.clock() - t0)
end
local function countTbl(t)
    local n = 0
    for _ in pairs(t) do n = n + 1 end
    return n
end
local function phaseReport()
    local parts = {}
    for _, name in ipairs(phaseOrder) do
        table.insert(parts, string.format("%s=%.2f", name, (phaseAcc[name] or 0) * 1000))
    end
    local memBefore = collectgarbage("count")
    local gcT0 = moonCore.clock()
    collectgarbage("collect")
    local memAfter = collectgarbage("count")
    local gcMs = (moonCore.clock() - gcT0) * 1000
    local thrMobs, thrEntries = threatMod.stats()
    local gs = grid.stats()
    local rsp, deaths = mobLifecycle.stats()
    local top = {}
    for tid, n in pairs(mobSpawnByTemplate) do top[#top + 1] = { tid, n } end
    table.sort(top, function(a, b) return a[2] > b[2] end)
    local topStr = {}
    for i = 1, math.min(3, #top) do topStr[#topStr + 1] = top[i][1] .. ":" .. top[i][2] end
    print(string.format("[PhaseDiag] tick=%d gc=%.2fms mem=%.0fKB freed=%.0fKB ent=%d ply=%d snap=%d threat=%d/%d ai=%d grid=%d/%d mobSpawn=%d mobRemove=%d migrate=%d respawn=%d death=%d top=%s %s",
        tick, gcMs, memAfter, memBefore - memAfter,
        countTbl(entities), countTbl(players), countTbl(snapSessions),
        thrMobs, thrEntries, mobAI.stats(), gs.cells, gs.entities,
        mobSpawnCount, mobRemoveCount, mobMigrateCount, rsp, deaths, table.concat(topStr, ","),
        table.concat(parts, " ")))
    phaseAcc = {}
end

local function marketOp(pid, msg, cb)
    moon.async(function()
        local svc = moon.queryservice("market")
        if not svc then noteEvents({ { type = "log", text = "Market unavailable", pid = pid } }); return end
        local resp = moon.call("lua", svc, msg)
        local ok = resp and resp.ok
        if cb then cb(ok and resp.data or nil, ok and nil or (resp and resp.error)) end
        noteEvents({ { type = "log", text = ok and "Market OK" or (resp and resp.error or "Market failed"), pid = pid } })
    end)
end

local function mailOp(pid, msg, cb)
    moon.async(function()
        local svc = moon.queryservice("mail")
        if not svc then noteEvents({ { type = "log", text = "Mail unavailable", pid = pid } }); return end
        local resp = moon.call("lua", svc, msg)
        local ok = resp and resp.ok
        if cb then cb(ok and resp.data or nil, ok and nil or (resp and resp.error)) end
        noteEvents({ { type = "log", text = ok and "Mail OK" or (resp and resp.error or "Mail failed"), pid = pid } })
    end)
end

local function guildBankOp(pid, msg)
    moon.async(function()
        local meta = players[pid]
        if not meta or not meta.characterId then return end
        local svc = moon.queryservice("social")
        if not svc then noteEvents({ { type = "log", text = "Guild unavailable", pid = pid } }); return end
        -- 解析公会成员身份 (guild id + rank)
        local ginfo = moon.call("lua", svc, { op = "guild_info", charId = meta.characterId })
        local guild = ginfo and ginfo.data
        if not guild then noteEvents({ { type = "log", text = "You are not in a guild", pid = pid } }); return end
        local bank = guildBank.getBankInfo(guild.id)
        if not bank then guildBank.createGuildBank(guild.id, guild.name) bank = guildBank.getBankInfo(guild.id) end
        local rank = guild.rank or 2
        local actor = meta.name or nil

        local op = msg.op
        if op == "deposit_gold" then
            local amount = msg.amount or 0
            if amount <= 0 then noteEvents({ { type = "log", text = "Invalid amount", pid = pid } }); return end
            if (meta.copper or 0) < amount then noteEvents({ { type = "log", text = "Not enough copper", pid = pid } }); return end
            meta.copper = meta.copper - amount
            local ok, gold = guildBank.depositGold(guild.id, pid, amount, rank, actor)
            noteEvents({ { type = "log", text = ok and ("Deposited " .. amount .. " copper (treasury " .. gold .. ")") or tostring(gold), pid = pid } })
        elseif op == "withdraw_gold" then
            local amount = msg.amount or 0
            local ok, gold = guildBank.withdrawGold(guild.id, pid, amount, rank, actor)
            if ok then meta.copper = (meta.copper or 0) + amount end
            noteEvents({ { type = "log", text = ok and ("Withdrew " .. amount .. " copper") or tostring(gold), pid = pid } })
        elseif op == "deposit_item" then
            local slot = msg.slot
            local item = meta.inventory and meta.inventory[slot]
            if not item then noteEvents({ { type = "log", text = "No item in that slot", pid = pid } }); return end
            local ok, err = guildBank.depositItem(guild.id, pid, item, rank, actor)
            if ok then meta.inventory[slot] = nil end
            noteEvents({ { type = "log", text = ok and "Deposited item" or tostring(err), pid = pid } })
        elseif op == "withdraw_item" then
            local slot = msg.slot or 1
            local ok, item = guildBank.withdrawItem(guild.id, pid, slot, rank, actor)
            if ok and item then
                local invItem = inventory.createItem(item.id, item.name or item.id, item.type or "misc", item)
                local addSlot = inventory.addItem(meta, invItem)
                if not addSlot then
                    guildBank.depositItem(guild.id, pid, item, rank, actor)
                    noteEvents({ { type = "log", text = "Inventory full", pid = pid } })
                    return
                end
                noteEvents({ { type = "log", text = "Withdrew " .. (item.name or item.id), pid = pid } })
            else
                noteEvents({ { type = "log", text = tostring(item) or "Withdraw failed", pid = pid } })
            end
        elseif op == "buy_slots" then
            local cost = 50
            if (meta.copper or 0) < cost then noteEvents({ { type = "log", text = "Not enough copper", pid = pid } }); return end
            meta.copper = meta.copper - cost
            local ok, total = guildBank.buySlots(guild.id, pid, 1, rank, actor)
            noteEvents({ { type = "log", text = ok and ("Expanded to " .. total .. " slots") or tostring(total), pid = pid } })
        elseif op == "log" then
            local entries = guildBank.getLog(guild.id)
            local gs = gateSvcFor(pid)
            if gs then
                local json = require("json")
                local frame = json.encode({ t = "gbanklog", ok = true, entries = entries })
                moon.send("lua", gs, { t = "sendToPlayer", pid = pid, frame = frame })
            end
            return
        end
        -- 刷新个人银行/公会金库快照标记 (gold/物品变化)
        if meta then meta.guildBankDirty = true end
    end)
end

local function protoGet(itemId)
    local ok, proto = pcall(function() return require("proto.load") end)
    if ok and proto then return proto.getItem(itemId) end
    return nil
end

local function nodeTypeFor(nodeId)
    local ok, proto = pcall(function() return require("proto.load") end)
    if not ok or not proto then return nil end
    local node = proto.gather_nodes and proto.gather_nodes[nodeId]
    if node then
        return node.resourceType or node.harvestType or node.type or nil
    end
    return nil
end

-- 最近敌人 (空间索引: 只查兴趣半径内实体, 避免攻击/tab/施法命令每次全表 O(n) 扫描)
local function findNearestEnemy(e)
    local visible = grid.queryRadius(e.pos.x, e.pos.z, config.INTEREST_QUERY_RADIUS, entities, nil)
    local best, bestDistSq = nil, math.huge
    for _, other in ipairs(visible) do
        -- 开放世界全自由互攻: 目标可为 mob/玩家/路人NPC (排除自己/死亡/鬼魂/采集节点)
        if (other.kind == "mob" or other.kind == "player" or (other.kind == "npc" and other.pedestrian)) and other.id ~= e.id and not other.dead and not other.ghost then
            local dx = e.pos.x - other.pos.x
            local dz = e.pos.z - other.pos.z
            local dsq = dx * dx + dz * dz
            if dsq < bestDistSq then
                best = other; bestDistSq = dsq
            end
        end
    end
    grid.releaseRadiusResult(visible)
    return best
end

-- 跨分片目标选择: 本地实体(空间索引) + 相邻分片 ghost(空间索引)
local function findNearestTarget(e)
    local best = findNearestEnemy(e)
    local bestDistSq = math.huge
    if best then
        local bdx = best.pos.x - e.pos.x
        local bdz = best.pos.z - e.pos.z
        bestDistSq = bdx * bdx + bdz * bdz
    end
    local ghosts = grid.queryGhosts(e.pos.x, e.pos.z, config.INTEREST_QUERY_RADIUS)
    for _, g in ipairs(ghosts) do
        if (g.kind == "mob" or g.kind == "player" or (g.kind == "npc" and g.pedestrian)) and g.id ~= e.id and not g.dead then
            local gdx = g.x - e.pos.x
            local gdz = g.z - e.pos.z
            local gsq = gdx * gdx + gdz * gdz
            if gsq < bestDistSq then
                bestDistSq = gsq
                best = g
            end
        end
    end
    grid.releaseGhosts(ghosts)
    return best
end

-- 跨分片战斗快照: 序列化攻击者战斗属性 (近战/远程/法术通用)
local function buildCombatSnapshot(attacker)
    return {
        id = attacker.id,
        kind = attacker.kind or "player",
        templateId = attacker.templateId,
        level = attacker.level or 1,
        hp = attacker.hp or 0,
        maxHp = attacker.maxHp or 100,
        dead = attacker.dead or false,
        attackPower = attacker.attackPower or 0,
        rangedPower = attacker.rangedPower or 0,
        spellPower = attacker.spellPower or 0,
        meleeHaste = attacker.meleeHaste or 0,
        spellHaste = attacker.spellHaste or 0,
        critChance = attacker.critChance,
        critDmgPhysBonus = attacker.critDmgPhysBonus or 0,
        critDmgSpellBonus = attacker.critDmgSpellBonus or 0,
        hitBonus = attacker.hitBonus or 0,
        weapon = attacker.weapon,
        dualWielding = attacker.dualWielding,
        titansGrip = attacker.titansGrip,
        overpowerUntil = attacker.overpowerUntil,
        auras = attacker.auras,
        resourceType = attacker.resourceType,
        maxResource = attacker.maxResource,
        resource = attacker.resource,
        stats = attacker.stats,
        -- PVP 门控 (damage.lua dealDamage) 需要: 跨分片转发时快照携带战斗状态与决斗对象,
        -- 否则归属分片判 consented 失败, 玩家对玩家伤害被压成 0
        combatState = attacker.combatState,
        duelPartnerId = attacker.duelPartnerId,
    }
end

-- mob 死亡营地计数: 本地 mob 直接扣本地营地; 迁移来的 mob 回传 home 分片扣营地
local function accountMobDeath(mob)
    if mob.homeShard and mob.homeShard ~= shardId then
        local hs = moon.queryservice("world_" .. mob.homeShard)
        if hs then
            moon.send("lua", hs, { t = "mobCampDeath", templateId = mob.templateId })
        end
    else
        mobLifecycle.onMobDeath(mob.id, entities)
    end
end

-- 跨分片击杀: 归属分片内联标记死亡 + 清理
local function applyForwardedKill(target)
    target.dead = true
    target.aiState = "dead"
    target.corpseTimer = 60
    if target.kind == "mob" then
        mobAI.cleanup(target.id)
        accountMobDeath(target)
    end
end

-- 解析施法目标: 优先本地实体, 其次跨分片 ghost, 回退最近本地敌人
local function resolveCastTarget(e)
    local target = entities[e.targetId]
    if target then return target, false end
    local g = ghostEntities[e.targetId]
    if g then return g, true end
    return findNearestEnemy(e), false
end

-- 跨分片施法转发: 目标为 ghost 时, 把攻击者快照+技能转发给归属分片结算。
-- delayMs > 0 用于投射物飞行延迟 (归属分片延时结算)。
local function forwardCast(attacker, targetId, ability, delayMs)
    local g = ghostEntities[targetId]
    if not g or not g.ownerShard then return false end
    local svc = moon.queryservice("world_" .. g.ownerShard)
    if not svc then return false end
    moon.send("lua", svc, {
        t = "castForward",
        attacker = buildCombatSnapshot(attacker),
        targetId = targetId,
        abilityId = ability.id,
        delayMs = delayMs or 0,
    })
    return true
end

--- 跨分片 PVP 同意转发: 攻击方 pvp_attack 指向 ghost 玩家时, 通知归属分片标记被攻击方
local function forwardPvpConsent(attackerId, targetId)
    local g = ghostEntities[targetId]
    if not g or not g.ownerShard then return false end
    local svc = moon.queryservice("world_" .. g.ownerShard)
    if not svc then return false end
    moon.send("lua", svc, { t = "pvpConsent", attackerId = attackerId, targetId = targetId })
    return true
end

----------------------------------------------
-- 实体管理
----------------------------------------------

local function createPlayerEntity(pid, cls, name, level, stateData)
    local terrain = require("world.terrain")
    local pos = { x = 0, y = terrain.placementHeight(0, 0), z = 0 }
    if stateData and stateData.pos then
        pos = { x = stateData.pos.x or 0, y = stateData.pos.y or terrain.placementHeight(stateData.pos.x or 0, stateData.pos.z or 0), z = stateData.pos.z or 0 }
        -- 兜底: 存档 y 明显偏离地形 (陷地/浮空, 由旧高度表最近邻误差或半空坠落产生) 时 snap 到放置高度
        local ph = terrain.placementHeight(pos.x, pos.z)
        if type(pos.y) ~= "number" or math.abs(pos.y - ph) > 1.0 then
            pos.y = ph
        end
    end

    local e = Entity.new(pid, "player", cls, name, level, pos)

    -- 恢复状态
    if stateData then
        e.facing = stateData.facing or 0
        e.hp = stateData.hp or e.maxHp
        e.dead = stateData.dead or false
        e.ghost = stateData.ghost or false
        if stateData.corpsePos then e.corpsePos = stateData.corpsePos end
        if stateData.cooldowns then
            e.cooldowns = {}
            for k, v in pairs(stateData.cooldowns) do
                if type(v) == "number" and v > 0 then e.cooldowns[k] = v end
            end
        end
        if stateData.skin then e.skin = stateData.skin end
        if stateData.skinCatalog then e.skinCatalog = stateData.skinCatalog end
        if stateData.weaponSkinId then e.weaponSkinId = stateData.weaponSkinId end
        -- 装备重算 (装备实例/签名)
        if stateData.equipmentInstance then e.equippedInstances = stateData.equipmentInstance end
    end

    -- 调用 recalcPlayerStats 计算完整属性
    local eq = stateData and stateData.equipment or {}
    playerStats.recalcPlayerStats(e, cls, eq, nil, nil)
    playerStats.fullVitals(e, cls)

    -- 确保 HP 等于 maxHp (除非是死亡状态)
    if not e.dead then
        e.hp = e.maxHp
    end

    return e
end

local function createMobEntity(templateId, name, level, pos, opts)
    mobSpawnCount = mobSpawnCount + 1
    local tid = templateId or "?"
    mobSpawnByTemplate[tid] = (mobSpawnByTemplate[tid] or 0) + 1
    local id = allocId()
    local e = Entity.new(id, "mob", templateId, name, level, pos)
    e.hostile = true
    e.spawnPos = { x = pos.x, y = pos.y, z = pos.z }
    e.homeShard = shardId
    mobAI.initMob(e, templateId, pos, opts)
    return e
end

-- 临时平民 NPC (dev 测试专用): 与 pedestrian.spawn 的 makePedestrian 同属性,
-- 但位置由调用方指定 (不依赖 simrng 随机散布) 且静止不漫游 (moveSpeed 0),
-- 供测试「击杀平民 → 通缉」逻辑 (否则平民漫游脱离近战范围, 回血抵消伤害)。
local function createPedestrianEntity(name, level, pos)
    local id = allocId()
    local y = terrain.placementHeight(pos.x, pos.z)
    local e = Entity.new(id, "npc", "pedestrian", name or "Test Villager", level or 5, { x = pos.x, y = y, z = pos.z })
    e.pedestrian = true
    e.hostile = false
    e.level = level or 5
    mobAI.initMob(e, "pedestrian", { x = pos.x, y = y, z = pos.z })
    e.maxHp = 50
    e.hp = 50
    e.attackPower = 10
    e.weapon = { min = 3, max = 6, speed = 2.6 }
    e.moveSpeed = 0
    e.family = "humanoid"
    return e
end

-- 销毁实体 (dev 测试专用): 清 AI/空间索引/实体表, 防止多次跑测试残留堆积。
local function despawnEntity(id)
    local e = entities[id]
    if not e then return false end
    mobAI.cleanup(id)
    grid.remove(e)
    entities[id] = nil
    return true
end

-- 跨分片 mob 迁移: mob 追到相邻 region 且该 region 映射到其他分片时, 迁到归属分片。
-- 完整状态迁移: 保留 AI 状态/仇恨/目标/出生点, 目标分片重建后继续追击。
local function migrateMobOut(e)
    local rx, rz = config.regionOf(e.pos.x, e.pos.z)
    local ns = config.regionToShard(rx, rz)
    if ns == shardId then return false end
    local svc = moon.queryservice("world_" .. ns)
    if not svc then return false end

    moon.send("lua", svc, {
        t = "entityMigrate",
        entity = {
            id = e.id, kind = e.kind, templateId = e.templateId, name = e.name,
            level = e.level,
            pos = { x = e.pos.x, y = e.pos.y, z = e.pos.z },
            facing = e.facing,
            hp = e.hp, maxHp = e.maxHp,
            auras = e.auras,
            hostile = e.hostile,
            aggroTargetId = e.aggroTargetId,
            combatTimer = e.combatTimer,
            ai = mobAI.serialize(e.id),
            threat = threatMod.serializeThreat(e.id),
            homeShard = e.homeShard or shardId,
            migrateCooldown = simTime + 5,
        },
    })

    mobAI.cleanup(e.id)
    grid.remove(e)
    entities[e.id] = nil
    mobMigrateCount = mobMigrateCount + 1
    print(string.format("[Mob] Migrate out: id=%d %s shard %d -> %d", e.id, e.templateId, shardId, ns))
    return true
end

local function joinPlayer(pid, characterId, accountId, name, cls, level, state, leaseNonce)
    local e = createPlayerEntity(pid, cls, name, level, state)
    entities[pid] = e
    local meta = {
        characterId = characterId, accountId = accountId,
        name = name, class = cls, level = level or 1,
        leaseNonce = leaseNonce,
        _wireVer = 0,
        xp = (state and state.xp) or 0,
        copper = (state and state.copper) or 0,
        lifetimeXp = (state and state.lifetimeXp) or 0,
        restedXp = (state and state.restedXp) or 0,
        prestigeRank = (state and state.prestigeRank) or 0,
        honor = state and state.honor, lifetimeHonor = state and state.lifetimeHonor,
        warfare = (state and state.warfare) or 0,
        inventory = (state and state.inventory) or {},
        equipment = (state and state.equipment) or {},
        bags = state and state.bags,
        equipmentInstance = state and state.equipmentInstance,
        qlog = state and state.qlog, qdone = state and state.qdone,
        questMilestones = state and state.questMilestones,
        talents = state and state.talents, talentPoints = state and state.talentPoints,
        loadouts = state and state.loadouts, spec = state and state.activeSpec,
        bank = state and state.bank,
        professions = state and state.professions, currentProfession = state and state.currentProfession,
        deedsEarned = state and state.deedsEarned, deedStats = state and state.deedStats,
        activeTitle = state and state.activeTitle, renown = state and state.renown,
        ownedMounts = state and state.ownedMounts, ridingTrained = state and state.ridingTrained or false,
        hotbarLayout = state and state.hotbarLayout,
        petName = state and state.petName,
        townFocus = state and state.townFocus,
        dungeonDifficulty = state and state.dungeonDifficulty,
        lastAcknowledgedSeq = 0,
    }
    players[pid] = meta
    -- 实体持有 meta 引用, 供 aura 施加/过期时重算属性
    e.meta = meta
    -- 同步骑术训练到实体 (startMount 检查 e.ridingTrained)
    e.ridingTrained = meta.ridingTrained or false
    grid.insert(e)
    quest.initQuestData(meta)
    talent.initTalents(meta, cls)
    bankMod.initBank(meta)
    profession.initProfessions(meta)

    -- 新手初始化: 背包为空且从未有装备时, 给初始武器 + 启动金币
    -- (老角色有 inventory/equipment 则不覆盖; 保证新角色可玩)
    local isEmptyInv = true
    for _ in pairs(meta.inventory or {}) do isEmptyInv = false; break end
    if isEmptyInv and (meta.level or 1) == 1 then
        local starter = inventory.createItem("worn_sword", "Pitted Shortsword", "weapon", protoGet("worn_sword") or { id = "worn_sword" })
        inventory.addItem(meta, starter)
        if not meta.copper or meta.copper == 0 then meta.copper = 100 end
        if not meta.hotbarLayout then meta.hotbarLayout = { [1] = "heroic_strike", [2] = "charge" } end
        -- 自动装备初始武器
        inventory.equipItem(meta, e, 0, "mainhand")
        -- 新手坐骑: 首只坐骑所有权 + 骑术已训练
        if not meta.ownedMounts then meta.ownedMounts = {} end
        if next(meta.ownedMounts) == nil then meta.ownedMounts["valorsteed"] = true end
        if not meta.ridingTrained then meta.ridingTrained = true end
        playerStats.recalcPlayerStats(e, cls, meta.equipment, nil, nil)
        playerStats.fullVitals(e, cls)
        e.hp = e.maxHp
    end

    if meta.talents then
        talent.recomputeForLevel(meta, e, cls)
        playerStats.recalcPlayerStats(e, cls, meta.equipment, meta.talentMods, nil)
    end
    deeds.initPlayer(pid)
    pvpHonor.initPlayer(pid)
    -- 登录后推送社交帧 (好友/黑名单/公会窗口)
    pushSocialFrame(pid)
    print(string.format("[World] Player joined: pid=%d name=%s cls=%s lv=%d str=%d ap=%d hp=%d",
        pid, name, cls, level, e.stats.str, e.attackPower, e.maxHp))
end

local serializeCharacter

local function leavePlayer(pid)
    local meta = players[pid]; local e = entities[pid]
    if not meta then return end
    grid.remove(e)
    aura.cleanupDRTracker(pid)
    deeds.cleanupPlayer(pid)
    -- 清理所有 mob 对此玩家的威胁/仇恨 (全局 threat 表, 非死字段 m.threat)
    for _, m in pairs(entities) do
        if m.kind == "mob" then
            threatMod.removeThreat(m.id, pid)
            if m.aggroTargetId == pid then m.aggroTargetId = nil end
            if m.forcedTargetId == pid then m.forcedTargetId = nil; m.forcedTargetTimer = 0 end
            if m.targetId == pid then m.targetId = nil end
        end
    end
    -- 清除其他玩家指向此玩家的 target
    for _, other in pairs(entities) do
        if other.targetId == pid then other.targetId = nil end
    end
    -- 清理玩家参与的社交/队列状态 (组队/交易/决斗/队列)
    partyMod.leave(pid)
    tradeMod.cleanupPlayer(pid)
    duelMod.cleanupPlayer(pid)
    dungeonFinder.leaveQueue(pid)
    valeCup.leaveQueue(pid)
    battleground.leaveQueue(pid)
    cardDuel.leaveCardQueue(pid)
    if dbSvc() and meta.leaseNonce then
        local st = serializeCharacter(pid)
        local dbs = dbSvc()
        if st then moon.async(function()
            moon.call("lua", dbs, { op = "saveCharacterState", args = { meta.characterId, meta.level, st, meta.leaseNonce } })
            moon.call("lua", dbs, { op = "releaseLease", args = { meta.characterId, meta.leaseNonce } })
        end) end
    end
    entities[pid] = nil; players[pid] = nil
    snapSessions[pid] = nil
    print(string.format("[World] Player left: pid=%d name=%s", pid, meta.name))
end

serializeCharacter = function(pid)
    local e = entities[pid]; local meta = players[pid]
    if not e or not meta then return nil end
    return {
        level = meta.level or 1, xp = meta.xp or 0, copper = meta.copper or 0,
        lifetimeXp = meta.lifetimeXp or 0,
        restedXp = meta.restedXp or 0, prestigeRank = meta.prestigeRank or 0,
        honor = meta.honor, lifetimeHonor = meta.lifetimeHonor,
        warfare = meta.warfare,
        pos = { x = e.pos.x, y = e.pos.y, z = e.pos.z }, facing = e.facing or 0,
        hp = e.hp or 100, dead = e.dead or false, ghost = e.ghost or false,
        corpsePos = e.corpsePos,
        inventory = meta.inventory or {}, equipment = meta.equipment or {},
        bags = meta.bags, equipmentInstance = meta.equipmentInstance,
        qlog = meta.qlog, qdone = meta.qdone,
        questMilestones = meta.questMilestones,
        talents = meta.talents, talentPoints = meta.talentPoints,
        loadouts = meta.loadouts, activeSpec = meta.spec,
        bank = meta.bank,
        professions = meta.professions, currentProfession = meta.currentProfession,
        deedsEarned = meta.deedsEarned, deedStats = meta.deedStats,
        activeTitle = meta.activeTitle, renown = meta.renown,
        ownedMounts = meta.ownedMounts, ridingTrained = meta.ridingTrained,
        cooldowns = e.cooldowns, hotbarLayout = meta.hotbarLayout,
        skin = e.skin, skinCatalog = e.skinCatalog,
        weaponSkinId = e.weaponSkinId,
        petName = meta.petName,
        townFocus = meta.townFocus,
        dungeonDifficulty = meta.dungeonDifficulty,
        unlockReason = meta.unlockReason,
    }
end

-- 跨分片玩家迁移 (Phase 5 MVP): 玩家走到相邻 region 且该 region 映射到其他分片时迁到归属分片。
-- 复用 serializeCharacter/joinPlayer 做全量状态迁移; 源分片做轻量清理 (不保存/不释放 lease/不退出社交),
-- 目标分片重建后 snapSessions 缺失会触发全量快照重发 (MVP 要求)。
local function cleanupPlayerLocal(pid)
    local e = entities[pid]
    if not e then return end
    local px, pz = e.pos.x, e.pos.z
    grid.remove(e)
    aura.cleanupDRTracker(pid)
    deeds.cleanupPlayer(pid)
    -- 只扫描玩家 AOI 内的实体 (引用该玩家的 mob 仇恨/目标、其他玩家 target 都在兴趣半径内),
    -- 避免每次迁移全表 O(n) 两遍扫描
    local nearby = grid.queryRadius(px, pz, config.INTEREST_QUERY_RADIUS, entities, nil)
    for _, other in ipairs(nearby) do
        if other.kind == "mob" then
            threatMod.removeThreat(other.id, pid)
            if other.aggroTargetId == pid then other.aggroTargetId = nil end
            if other.forcedTargetId == pid then other.forcedTargetId = nil; other.forcedTargetTimer = 0 end
            if other.targetId == pid then other.targetId = nil end
        elseif other.targetId == pid then
            other.targetId = nil
        end
    end
    grid.releaseRadiusResult(nearby)
    entities[pid] = nil
    players[pid] = nil
    snapSessions[pid] = nil
end

local function migratePlayerOut(pid)
    local e = entities[pid]
    local meta = players[pid]
    if not e or not meta then return false end
    -- 迁移冷却 (防边界来回振荡); simTime 为分片内时钟, 冷却只在当前分片生效
    if meta._migrateCooldown and meta._migrateCooldown > simTime then return false end
    local rx, rz = config.regionOf(e.pos.x, e.pos.z)
    local ns = config.regionToShard(rx, rz)
    if ns == shardId then return false end
    local svc = moon.queryservice("world_" .. ns)
    if not svc then return false end
    local st = serializeCharacter(pid)
    if not st then return false end

    moon.send("lua", svc, {
        t = "playerMigrate",
        pid = pid,
        characterId = meta.characterId,
        accountId = meta.accountId,
        name = meta.name,
        cls = meta.class,
        level = meta.level,
        state = st,
        leaseNonce = meta.leaseNonce,
        -- 迁移保留瞬态战斗状态 (PvP 同意/决斗对象), 否则跨片 PvP 同意会被 joinPlayer 重置回 idle
        combatState = e.combatState,
        duelPartnerId = e.duelPartnerId,
    })

    -- 通知 gate 更新会话路由
    local gs = gateSvcFor(pid)
    if gs then moon.send("lua", gs, { t = "playerMigrated", pid = pid, shard = ns }) end

    cleanupPlayerLocal(pid)
    print(string.format("[World] Player migrate out: pid=%d %s shard %d -> %d", pid, meta.name, shardId, ns))
    return true
end

----------------------------------------------
-- 战斗 Tick (Phase 3-4: 确定性 RNG 驱动)
----------------------------------------------

-- 解析施法效果 (供瞬发 + 投射物命中复用; 含怒气/威胁/套装)
local function resolveCastEffects(e, target, ability, combatEvents, entities, simTime)
    if not ability then return end
    local evs = fxDispatch.execute(e, target, ability, entities, simTime)
    for _, ev in ipairs(evs) do
        table.insert(combatEvents, ev)
        if ev.type == "damage" and target then
            if e.resourceType == "rage" then
                local rageGain = rage.rageFromDealing(ev.amount or 0, e.level)
                e.resource = math.min(e.maxResource, e.resource + rageGain)
            end
            setProcs.applySetProcs(e, target, "on_attack", simTime)
            threatMod.addThreat(target.id, e.id, ev.amount or 0, ability.school, e)
        elseif ev.type == "heal2" then
            local healedTarget = entities[ev.targetId]
            if healedTarget then
                healMod.healingThreat(e, healedTarget, ev.amount or 0, entities, threatMod)
            end
        end
    end
    setProcs.applySetProcs(e, target, "on_spell_cast", simTime)
    -- 传奇武器 on-hit procs (TS equip_procs)
    local equipProcEvents = require("world.combat.equip_procs").applyWeaponProcs(e, target, "on_hit", ability.id, entities, simTime)
    for _, ev in ipairs(equipProcEvents) do table.insert(combatEvents, ev) end
    -- 注: 不在此处 checkDeath/发 death 事件, 死亡统一由主死亡循环结算掉落/金币/XP。
end

local function combatTick(dt)
    local combatEvents = {}

    -- combatTick 是独立函数, 不能访问 doGameTick 的局部 hasPlayers; 本地计算
    local hasPlayers = false
    for _ in pairs(players) do hasPlayers = true; break end

    -- 玩家施法 + 自动攻击
    for pid in pairs(players) do
        local e = entities[pid]
        if e and not e.dead then
            -- TS updateTimers: 每 tick 递增 fiveSecondRule/combatTimer/gcd/药水cd
            regen.updateTimers(e, dt)
            castSys.updateCooldowns(e, dt)
            -- 连击点过期 (TS updateComboExpiry)
            if e.comboUntil and e.comboUntil > 0 and simTime >= e.comboUntil then
                e.comboPoints = 0
                e.comboUntil = -1
            end

            local castingAbility = e.castingAbility
            local castResult = castSys.updateCast(e, dt)

            -- 排队施法: updateCast 返回排队技能表 (TS fireQueuedCast 重跑 gate)
            if type(castResult) == "table" then
                local queuedAbility = castResult
                local qtarget, qghost = resolveCastTarget(e)
                if qghost then
                    forwardCast(e, e.targetId, queuedAbility, 0)
                else
                    local qok, qct = castSys.startCast(e, queuedAbility, qtarget)
                    if qok then
                        -- 瞬发直接执行
                        if qct == 0 then
                            local qevs = fxDispatch.execute(e, qtarget, queuedAbility, entities, simTime)
                            for _, ev in ipairs(qevs) do table.insert(combatEvents, ev) end
                        end
                    end
                end
                goto continue_player_cast
            end

            -- 通道 tick: 执行一次通道效果
            if castResult == "channel_tick" and castingAbility then
                local ctTarget, ctGhost = resolveCastTarget(e)
                if ctGhost then
                    forwardCast(e, e.targetId, castingAbility, 0)
                else
                    local ctEvs = fxDispatch.execute(e, ctTarget, castingAbility, entities, simTime)
                    for _, ev in ipairs(ctEvs) do
                        table.insert(combatEvents, ev)
                        if ev.type == "damage" and ctTarget then
                            threatMod.addThreat(ctTarget.id, pid, ev.amount or 0)
                        end
                    end
                end
            end

            if castResult == "complete" and castingAbility then
                local target, isGhost = resolveCastTarget(e)

                -- TS applyAbility: 非物理法术默认作为投射物发射 (fireball 有飞行时间)
                local isSpell = castingAbility.school and castingAbility.school ~= "physical"
                local firesProjectile = castingAbility.projectile
                    or (isSpell and not castingAbility.noProjectile)

                if isGhost then
                    -- 跨分片: 转发施法给归属分片 (投射物按飞行时间延迟)
                    local delayMs = 0
                    if firesProjectile then
                        local gdx = target.x - e.pos.x
                        local gdz = target.z - e.pos.z
                        local dist = math.sqrt(gdx * gdx + gdz * gdz)
                        delayMs = math.max(100, math.floor((dist / 40) * 1000))
                    end
                    forwardCast(e, e.targetId, castingAbility, delayMs)
                elseif firesProjectile and target and target ~= e then
                    -- 投射物: 命中时解析 (TS scheduleProjectile)
                    projectile.launch(e.id, target.id, castingAbility.id, e.pos, target.pos,
                        function(src, tgt)
                            local pEvents = {}
                            -- 命中时法术抵抗
                            if isSpell then
                                if spellResist.isSpellResisted(src.level, tgt.level, src.hitBonus or 0) then
                                    table.insert(pEvents, eventWire.resist(src.id, tgt.id,
                                        castingAbility.school or "magic", castingAbility.name))
                                    regen.enterCombat(src, tgt)
                                    return pEvents
                                end
                            end
                            -- 在命中时刻解析效果 (捕获 combatEvents)
                            resolveCastEffects(src, tgt, castingAbility, pEvents, entities, simTime)
                            return pEvents
                        end)
                    -- 施法完成触发 (投射物仍在飞行)
                    setProcs.applySetProcs(e, target, "on_spell_cast", simTime)
                else
                    -- 瞬发/近战: 立即解析 (TS applyAbility 1986-2024)
                    -- TS 1895-1925: 友善目标法术永不落空 (heal/buff 跳过抵抗)
                    local isFriendly = false
                    if castingAbility.effects then
                        for _, ef in ipairs(castingAbility.effects) do
                            if ef.type == "heal" or ef.type == "aoeHeal" or ef.type == "hot" or
                               (ef.type == "buff" and ef.target == "self") or ef.target == "friendly" then
                                isFriendly = true
                                break
                            end
                        end
                    end
                    if isSpell and target and not isFriendly then
                        local resisted = false
                        if e.kind == "mob" and e.hostile then
                            resisted = spellResist.isMobSpellResisted(e, target, e.hitBonus or 0)
                        else
                            resisted = spellResist.isSpellResisted(e.level, target.level, e.hitBonus or 0)
                        end
                        if resisted then
                            table.insert(combatEvents, eventWire.resist(e.id, target.id,
                                castingAbility.school or "magic", castingAbility.name))
                            regen.enterCombat(e, target)
                            goto continue_player_cast
                        end
                    end
                    resolveCastEffects(e, target, castingAbility, combatEvents, entities, simTime)
                end
            end
            ::continue_player_cast::

            -- 自动攻击 (使用命中表 + 形态速度 + 怒气)
            local function processAutoResult(aaResult)
                if not aaResult then return end
                if aaResult.forward then return end  -- 跨分片: 已转发, 本地不产生伤害事件
                if aaResult.damage > 0 then
                    if e.resourceType == "rage" then
                        local rageGain = rage.rageFromDealing(aaResult.damage, e.level)
                        local rageMult = rage.rageGenAuraMult(e.auras)
                        e.resource = math.min(e.maxResource, e.resource + rageGain * rageMult)
                    end
                    setProcs.applySetProcs(e, entities[e.targetId], "on_attack", simTime)
                end
                table.insert(combatEvents, eventWire.damage(pid, e.targetId,
                    aaResult.damage, aaResult.crit,
                    eventWire.kindFromResult(aaResult.result)))
                if e.targetId then threatMod.addThreat(e.targetId, pid, aaResult.damage) end
                -- 注: 不在此处 checkDeath/发 death 事件。死亡统一由主死亡循环
                -- (for entities + spirit.checkDeath) 处理掉落/金币/XP, 这里提前 checkDeath
                -- 会把目标 dead 置 true, 导致主循环跳过掉落结算 (金币入账失效)。
            end

            -- 目标失效校验 (死亡/消失/跨分片迁移 → 回 idle)
            -- 仅当玩家有显式目标时才校验: pvp_fight 的被攻击方 (flagPvp) 无目标, 不应被误清回 idle
            if e.combatState == "auto_fight" or e.combatState == "pvp_fight" then
                if e.targetId then
                    local ct = entities[e.targetId] or ghostEntities[e.targetId]
                    if not ct or ct.dead then
                        combatState.idle(e)
                    end
                end
            end

            -- 自动面向目标 (auto_fight / pvp_fight: 自动攻击持续转向目标; 追击时持续面向)
            -- 仅战斗状态 (auto_fight/pvp_fight) 且 autoAttack 开启时生效; 点空地停手
            -- (stopattack → fleeing) 或死亡后不转向, 玩家可自由逃跑/转身。
            if (e.combatState == "auto_fight" or e.combatState == "pvp_fight")
               and e.autoAttack and e.targetId then
                local ft = entities[e.targetId] or ghostEntities[e.targetId]
                if ft and not ft.dead then
                    local desired = math.atan(ft.pos.x - e.pos.x, ft.pos.z - e.pos.z)
                    local diff = desired - e.facing
                    while diff > math.pi do diff = diff - 2 * math.pi end
                    while diff < -math.pi do diff = diff + 2 * math.pi end
                    -- 限速转向 (复用键盘转向速度, 避免瞬转)
                    local turnStep = 3.0 * dt
                    if math.abs(diff) <= turnStep then
                        e.facing = desired
                    else
                        e.facing = e.facing + (diff > 0 and turnStep or -turnStep)
                    end
                    while e.facing > math.pi * 2 do e.facing = e.facing - math.pi * 2 end
                    while e.facing < 0 do e.facing = e.facing + math.pi * 2 end
                end
            end

            -- 自动追随移动 (auto_fight / pvp_fight 自动追随战斗)
            -- 激活条件: 目标有效存活 + targetHasAutoChase=true (选中目标即激活, 未被人手介入)。
            -- 距离控制: 距目标 > 近战攻击阈值 → 朝目标自动移动 (复用 move 模块碰撞/地形校验);
            --            ≤ 阈值 → 停止自动移动, 原地站桩挥击。
            -- 玩家手动介入 (processInputs 检测方向键) 会把 targetHasAutoChase 置 false,
            -- 本次 target 生命周期内不再自动追随; 重新选中目标才重新激活。
            -- 退出: 目标死亡/销毁/targetId 置空/切换目标/玩家死亡 (combat_state 统一重置标记)。
            if (e.combatState == "auto_fight" or e.combatState == "pvp_fight")
               and e.autoAttack
               and e.targetHasAutoChase and e.targetId then
                local ft = entities[e.targetId] or ghostEntities[e.targetId]
                if ft and not ft.dead then
                    local dx = ft.pos.x - e.pos.x
                    local dz = ft.pos.z - e.pos.z
                    local distSq = dx * dx + dz * dz
                    if distSq > config.MELEE_RANGE_SQ then
                        -- 生成前进移动意图交给 move 模块 (碰撞/地形/游泳校验与玩家输入同链路);
                        -- 朝向已由上方自动面向锁定, 前进即朝目标方向移动。
                        move.applyInput(e, { f = 1 }, nil, config.DT)
                        grid.update(e)
                    end
                end
            end

            processAutoResult(autoAttack.update(e, entities, dt, simTime))
            processAutoResult(autoAttack.updateOffhand(e, entities, dt, simTime))
            processAutoResult(autoAttack.updateRanged(e, entities, dt, simTime))
        end
    end

    -- 光环更新 (传递 simTime 用于 DR, 仅在有玩家时)
    local auraEvents = {}
    if hasPlayers then
        auraEvents = safeCall("aura.updateAll", function() return aura.updateAll(entities, players, dt, simTime) end)
    end
    for _, ev in ipairs(auraEvents) do table.insert(combatEvents, ev) end

    -- Mob AI 更新 (空间裁剪: 用玩家 cell 集合快速判断 200yd 内是否有存活玩家, 避免 O(mobs×players))
    local playerCells = {}
    for pid, _ in pairs(players) do
        local pe = entities[pid]
        if pe and not pe.dead then
            playerCells[grid.cellKey(pe.pos.x, pe.pos.z)] = true
        end
    end
    if next(playerCells) ~= nil then
        local migrateOut = {}
        for _, e in pairs(entities) do
            if e.kind == "mob" and not e.dead then
                local cx = math.floor(e.pos.x / 32)
                local cz = math.floor(e.pos.z / 32)
                local nearPlayer = false
                for dcx = -7, 7 do
                    for dcz = -7, 7 do
                        if playerCells[(cx + dcx) * 100000 + (cz + dcz)] then
                            nearPlayer = true
                            break
                        end
                    end
                    if nearPlayer then break end
                end
                if nearPlayer then
                    local mobEvents = mobAI.updateMob(e, entities, players, dt)
                    for _, ev in ipairs(mobEvents) do table.insert(combatEvents, ev) end
                    -- 跨分片迁移检测: 追击中的 mob 跨到相邻 region 且该 region 映射到其他分片。
                    -- 仅迁移追击/战斗/逃跑态 (排除巡逻/返回, 避免营地贴近边界时来回振荡)。
                    local rx, rz = config.regionOf(e.pos.x, e.pos.z)
                    if config.regionToShard(rx, rz) ~= shardId then
                        local st = mobAI.getState(e.id)
                        local canMigrate = (st == "chasing" or st == "combat" or st == "flee")
                            and (not e.migrateCooldown or e.migrateCooldown <= simTime)
                        if canMigrate then
                            table.insert(migrateOut, e)
                        end
                    end
                end
            end
        end
        for _, e in ipairs(migrateOut) do
            migrateMobOut(e)
        end
    end

    -- 路人 NPC AI 更新 (漫游 + 反击)
    safeCall("pedestrian.update", function() pedestrian.update(entities, players, dt, simTime) end)

    -- Mob 刷新检查
    local spawned = mobLifecycle.checkRespawn(entities, createMobEntity, grid, simTime)
    for _, mob in ipairs(spawned) do
        entities[mob.id] = mob
        grid.insert(mob)
        table.insert(combatEvents, { type = "mob_spawn", mobId = mob.id, name = mob.name, level = mob.level })
    end

    -- 死亡检查 + 掉落 + 社交仇恨
    for _, e in pairs(entities) do
        if spirit.checkDeath(e) then
            -- TS handleDeath: 清除施法/采集/钓鱼状态
            e.castingAbility = nil
            e.castTargetId = nil
            e.gatherCastNodeId = ""
            e.craftCastRecipeId = ""
            e.fishBiteAtTick = 0
            e.fishCastZoneId = ""

            if e.kind == "player" then
                -- 保存尸体位置
                e.corpsePos = { x = e.pos.x, y = e.pos.y, z = e.pos.z }
                -- 强制下马 + 清除战斗状态 (TS 1175-1200)
                e.mountKey = nil
                e._idVer = (e._idVer or 0) + 1
                e.mountCastRemaining = nil
                e.mountCastKey = nil
                e.autoAttack = false
                e.queuedOnSwing = nil
                e.queuedCastAbility = nil
                e.comboPoints = 0
                e.eating = nil
                e.drinking = nil
                e.sitting = false
                e.chargeTargetId = nil
                e.followTargetId = nil
                table.insert(combatEvents, { type = "death", entityId = e.id, x = e.pos.x, z = e.pos.z })
                print(string.format("[World] Player died: pid=%d name=%s hp=0", e.id, e.name or "?"))
                -- 从所有 mob 仇恨表移除死亡玩家 (TS 1164-1172)
                for _, m in pairs(entities) do
                    if m.kind == "mob" then
                        threatMod.removeThreat(m.id, e.id)
                        if m.forcedTargetId == e.id then
                            m.forcedTargetId = nil
                            m.forcedTargetTimer = 0
                        end
                    end
                end
            else
                e.aiState = "dead"
                e.corpseTimer = 60
                e.respawnTimer = 60
                table.insert(combatEvents, { type = "death", entityId = e.id })
            end

            if e.kind == "mob" then
                mobAI.cleanup(e.id)
                accountMobDeath(e)
                -- 掉落拆分: copper 金币不进入 loot 事件 (避免客户端 createItem 无 itemId),
                -- 击杀瞬间直接入击杀者钱包; 物品类掉落保持原样广播 (尸体/拾取逻辑不变)。
                local loot = mobLifecycle.getLoot(e)
                local mobCopper = 0
                if loot and #loot > 0 then
                    for _, item in ipairs(loot) do
                        if item.type == "copper" then
                            mobCopper = mobCopper + (item.amount or 0)
                        else
                            table.insert(combatEvents, { type = "loot", mobId = e.id, item = item })
                        end
                    end
                end
                local killer = e.aggroTargetId or e.lastAttackerId or e.targetId
                if killer and players[killer] then
                    mobLifecycle.socialAggro(e.id, killer, entities, mobAI)
                    local qUpdates = quest.onKill(players[killer], e.templateId)
                    for _, qu in ipairs(qUpdates) do
                        table.insert(combatEvents, { type = "quest_progress", pid = killer,
                            questId = qu.questId, current = qu.current, required = qu.required })
                    end
                    -- 功勋追踪: Boss/通用击杀
                    deeds.onKill(killer, e.templateId)
                    -- 击杀 XP (TS mobXpValue: 45+5*level, 等级差缩放 + elite ×2)
                    local kMeta = players[killer]
                    local kEnt = entities[killer]
                    if kMeta and kEnt then
                        local mobXpVal = xp.mobXpValue(e.level, kEnt.level)
                        if e.isBoss or (e.templateId and (e.templateId:find("boss") or e.templateId:find("nythraxis"))) then
                            mobXpVal = mobXpVal * 2  -- elite mult
                        end
                        local xpEvents = xp.grantXp(mobXpVal, kMeta, kEnt, { fromKill = true },
                            playerStats.recalcPlayerStats,
                            function(m, ent)
                                talent.recomputeForLevel(m, ent, m.class or ent.templateId)
                            end)
                        for _, xev in ipairs(xpEvents) do table.insert(combatEvents, xev) end
                        -- PvE 金币: 击杀瞬间自动入击杀者钱包 (不经过尸体拾取)
                        if mobCopper > 0 then
                            kMeta.copper = (kMeta.copper or 0) + mobCopper
                            table.insert(combatEvents, {
                                type = "loot", pid = killer,
                                text = "You loot " .. mobCopper .. " copper.",
                            })
                        end
                    end
                    -- 团队副本锁定: Boss 击杀
                    if e.templateId and (e.templateId:find("boss") or e.templateId:find("nythraxis")) then
                        local meta = players[killer]
                        if meta then
                            raidLockout.lock(meta.characterId, e.dungeonId or "world")
                        end
                    end
                    -- 副本 Boss 击杀追踪
                    if e.dungeonId then
                        deeds.onDungeonComplete(killer)
                        local bossMeta = players[killer]
                        if bossMeta then heroicDungeon.awardHeroicMarks(bossMeta.characterId, 1) end
                    end
                end
            elseif e.kind == "npc" and e.pedestrian then
                -- 路人 NPC 死亡: 掉落铜币 + 物品 (尸体可拾取)
                mobAI.cleanup(e.id)
                -- 击杀平民 → 通缉 (GTA: 全城 NPC 敌视)
                local pedKiller = e.aggroTargetId or e.lastAttackerId
                if pedKiller and players[pedKiller] then
                    wanted.addWanted(players[pedKiller], 1)
                end
                local pedLoot = {}
                local coinCount = simrng.randint(2, 5)
                for i = 1, coinCount do
                    table.insert(pedLoot, { id = "copper_coin_" .. e.id .. "_" .. i, name = "Copper Coin", kind = "misc", value = 5, sellValue = 5 })
                end
                if simrng.random() < 0.6 then
                    table.insert(pedLoot, { id = "cloth_scrap_" .. e.id, name = "Cloth Scrap", kind = "misc", value = 3, sellValue = 3 })
                end
                e.loot = pedLoot
                e.lootable = true
                table.insert(combatEvents, { type = "death", entityId = e.id })
            elseif e.kind == "player" then
                -- PvP 击杀: 最后造成伤害的玩家 (dealDamage 记录的 lastAttackerId)
                local killerPid = e.lastAttackerId or e.targetId
                if killerPid and players[killerPid] and killerPid ~= e.id then
                    local honorGain = pvpHonor.awardHonor(killerPid, e.level)
                    -- 持久化到 meta (serializeCharacter 保存)
                    local kMeta = players[killerPid]
                    if kMeta then
                        kMeta.honor = (kMeta.honor or 0) + honorGain
                        kMeta.lifetimeHonor = (kMeta.lifetimeHonor or 0) + honorGain
                        kMeta.warfare = (kMeta.warfare or 0) + math.floor(honorGain * 0.5 + 0.5)
                    end
                    -- 击杀玩家 → 通缉 (GTA)
                    wanted.addWanted(players[killerPid], 1)
                    -- PvP 金币转移: 死者身上铜币按比例转入击杀者钱包 (带保护阈值)
                    -- 只有玩家击杀玩家触发; 怪物杀死玩家不扣铜币 (边界约束 2)
                    local deadMeta = players[e.id]
                    if kMeta and deadMeta then
                        local deadCopper = deadMeta.copper or 0
                        if deadCopper > config.PVP_COPPER_SAFE_MIN then
                            local loss = math.floor(deadCopper * config.PVP_COPPER_DROP_RATE)
                            if loss > 0 then
                                deadMeta.copper = deadCopper - loss
                                kMeta.copper = (kMeta.copper or 0) + loss
                                table.insert(combatEvents, {
                                    type = "loot", pid = killerPid,
                                    text = "You gain " .. loss .. " copper from your kill!",
                                })
                                table.insert(combatEvents, {
                                    type = "loot", pid = e.id,
                                    text = "You lost " .. loss .. " copper upon death!",
                                })
                            end
                        end
                    end
                end
                e.lastAttackerId = nil
            end
        end
    end

    -- 战斗外威胁清理 (TS: 不衰减, 只在 mob 回到 idle/evade 时 clearThreat)
    for _, e in pairs(entities) do
        if e.kind == "mob" and (e.aiState == "idle" or e.aiState == "returning") then
            threatMod.clearThreat(e.id)
        end
    end

    return combatEvents
end

----------------------------------------------
-- Tick 循环 (完整相位: 对应 src/sim/sim.ts tick())
----------------------------------------------

local inputQueue = {}
local saveTimer = 0

local function processInputs()
    for pid, input in pairs(inputQueue) do
        local e = entities[pid]
        if e and (not e.dead or e.ghost) then
            -- 玩家手动介入移动检测: f/b/sl/sr 任一方向键按下 → 关闭自动追随。
            -- 核心规则: 玩家一旦介入, 本次 target 生命周期内不再自动恢复追随,
            -- 角色变站桩 (auto-fight/自动面向仍保留), 只有重新选中目标才重新激活。
            local mi = input.mi or {}
            local manualMove = (mi.f and mi.f > 0) or (mi.b and mi.b > 0)
                or (mi.sl and mi.sl > 0) or (mi.sr and mi.sr > 0)
            if manualMove then
                e.targetHasAutoChase = false
            end
            move.applyInput(e, input.mi, input.facing, config.DT)
            grid.update(e)
        end
        inputQueue[pid] = nil
    end
end

--- 跨分片 ghost 同步: 每 K tick 把本分片边界实体发送给相邻分片
-- 只发给实体实际靠近的那条边 (1-2 个邻居), 避免 8 邻居全发导致 ghost 表膨胀
local function ghostSync()
    ghostTick = ghostTick + 1
    if ghostTick < config.GHOST_SYNC_INTERVAL_TICKS then return end
    ghostTick = 0

    local R = config.INTEREST_QUERY_RADIUS
    local groups = {}
    for _, e in pairs(entities) do
        if not e.dead then
            local rx, rz = config.regionOf(e.pos.x, e.pos.z)
            local minX, minZ = rx * config.REGION_SIZE, rz * config.REGION_SIZE
            local maxX, maxZ = (rx + 1) * config.REGION_SIZE, (rz + 1) * config.REGION_SIZE
            local nearL = e.pos.x - minX < R
            local nearR = maxX - e.pos.x < R
            local nearB = e.pos.z - minZ < R
            local nearT = maxZ - e.pos.z < R
            if not (nearL or nearR or nearB or nearT) then goto continue_gsync end

            local ser = nil
            local function add(dx, dz)
                local ns = config.regionToShard(rx + dx, rz + dz)
                if ns ~= shardId then
                    ser = ser or ghost.serialize(e, shardId)
                    groups[ns] = groups[ns] or {}
                    table.insert(groups[ns], ser)
                end
            end
            if nearL then add(-1, 0) end
            if nearR then add(1, 0) end
            if nearB then add(0, -1) end
            if nearT then add(0, 1) end
            ::continue_gsync::
        end
    end
    for ns, list in pairs(groups) do
        local svc = moon.queryservice("world_" .. ns)
        if svc then
            moon.send("lua", svc, { t = "ghostSync", shardId = shardId, ghosts = list })
        end
    end
end

--- 跨分片战斗: 目标为 ghost 时, 序列化攻击者战斗属性并转发给归属分片结算
local function resolveGhostSwing(attacker, targetId, isOffhand)
    local g = ghostEntities[targetId]
    if not g or not g.ownerShard then return nil end
    -- 近战距离校验 (ghost 路径绕过 _performSwing 的距离检查, 需在此补上避免隔空命中)
    local gdx = g.x - attacker.pos.x
    local gdz = g.z - attacker.pos.z
    if gdx * gdx + gdz * gdz > config.MELEE_RANGE_SQ then return nil end
    local svc = moon.queryservice("world_" .. g.ownerShard)
    if not svc then return nil end
    moon.send("lua", svc, { t = "combatForward", attacker = buildCombatSnapshot(attacker), targetId = targetId, isOffhand = isOffhand })
    return { forward = true, targetId = targetId }
end

-- 跨分片远程自动攻击转发 (远程有死角 + 最大射程)
local function resolveGhostRanged(attacker, targetId)
    local g = ghostEntities[targetId]
    if not g or not g.ownerShard then return nil end
    local gdx = g.x - attacker.pos.x
    local gdz = g.z - attacker.pos.z
    local dsq = gdx * gdx + gdz * gdz
    if dsq < config.MELEE_RANGE_SQ then return nil end  -- 死角
    if dsq > 35 * 35 then return nil end  -- RANGED_MAX_DIST
    local svc = moon.queryservice("world_" .. g.ownerShard)
    if not svc then return nil end
    moon.send("lua", svc, { t = "combatForward", attacker = buildCombatSnapshot(attacker), targetId = targetId, ranged = true })
    return { forward = true, targetId = targetId }
end

autoAttack.setGhostResolver(resolveGhostSwing)
autoAttack.setGhostRangedResolver(resolveGhostRanged)

local function broadcastSnapshot()
    if next(allGateSvcs()) == nil then return end
    local frames = {}
    local tb = moonCore.clock()
    for pid, meta in pairs(players) do
        local session = snapSessions[pid]
        if not session then
            session = { seenEntities = {}, lastDyn = {}, lastSent = {} }
            snapSessions[pid] = session
        end
        local ok, frame = pcall(snapshot.buildForPlayer, entities, players, ghostEntities, pid, session, tick, simTime)
        if not ok then
            print(string.format("[World] SNAPSHOT ERROR pid=%d: %s", pid, tostring(frame)))
        elseif frame then frames[pid] = frame end
    end
    phaseEnd("bcastBuild", tb)
    local ts = moonCore.clock()
    if next(frames) then
        -- 多 gate: 按 pid 反解 gate, 每 gate 只收本 gate 玩家帧 (减消息体积)
        local byGate = {}
        for pid, frame in pairs(frames) do
            local gi = gateOf(pid)
            local m = byGate[gi]
            if not m then m = {}; byGate[gi] = m end
            m[pid] = frame
        end
        for gi, m in pairs(byGate) do
            local gs = moon.queryservice("gate_" .. gi)
            if gs then moon.send("lua", gs, { t = "broadcastSnap", shard = shardId, data = m }) end
        end
    end
    phaseEnd("bcastSend", ts)
end

local function sendCombatEvents(combatEvents)
    if #combatEvents == 0 then return end
    -- 战斗事件大多带 pid (个人) — 走 per-session 路由, 世界事件广播
    noteEvents(combatEvents)
end

local function autosave()
    local dbs = dbSvc()
    if not dbs then return end
    local batch = {}
    for pid, meta in pairs(players) do
        local st = serializeCharacter(pid)
        if st and meta.leaseNonce then
            table.insert(batch, { charId = meta.characterId, level = meta.level, state = st, nonce = meta.leaseNonce })
        end
    end
    if #batch == 0 then return end
    moon.send("lua", dbs, { op = "batchSaveCharacters", args = { batch } })
    moon.send("lua", dbs, { op = "heartbeatLeases", args = {} })
    print(string.format("[World] Autosave: %d players", #batch))
end

-- 断线宽限期清理 (5 分钟)
local function sweepLinkdead()
    local now = os.time()
    for pid, meta in pairs(players) do
        if meta.linkdeadSince then
            local elapsed = now - meta.linkdeadSince
            if elapsed * 1000 >= config.LINKDEAD_GRACE_MS then
                print(string.format("[World] Linkdead expired: pid=%d name=%s", pid, meta.name))
                leavePlayer(pid)
            end
        end
    end
end

local function doGameTick()
    simTime = simTime + config.DT
    tick = tick + 1

    -- 快速路径: 无在线玩家时跳过重量级 entity 遍历
    local hasPlayers = false
    for _ in pairs(players) do hasPlayers = true; break end

    if tick <= 3 then
        print(string.format("[World] Tick #%d — simTime=%.1f", tick, simTime))
    end

    local t0 = moonCore.clock()

    -- Phase: 门触发器 (TS updateDoorTriggers: 移动后检测副本入口)
    pcall(function()
        for pid in pairs(players) do
            local e = entities[pid]
            if e and not e.dead and not e.dungeonId then
                local doorEvents = doorTriggers.checkPlayerDoors(e, entities, players, simTime)
                for _, ev in ipairs(doorEvents) do
                    table.insert(combatEvents, ev)
                end
            end
        end
    end)

    local combatEvents = {}

    -- Phase: 序章 (TS tick 顺序: respawns → worldBosses → groundAoEs → frozenOrbs → despawnDecay → projectiles)
    local worldBossEvents = safeCall("worldBoss.tick", function() return worldBoss.tick(entities, players, createMobEntity, grid, simTime) end)
    local groundAoEEvents = safeCall("groundAoE.tick", function() return groundAoE.tick(entities, config.DT) end)
    local frozenOrbEvents = safeCall("frozenOrb.tick", function() return frozenOrb.tick(entities, config.DT, simrng) end)
    local despawnToRemove = safeCall("despawnDecay.tick", function() return despawnDecay.tick(entities, config.DT) end)
    local projectileEvents = safeCall("projectile.tick", function() return projectile.tick(entities, config.DT) end)
    local riftEvents = safeCall("rift.update", function() return rift.update(simTime, entities, players, config.DT) end)

    -- 清理 despawn 的实体
    if despawnToRemove then
        for id, _ in pairs(despawnToRemove) do
            if entities[id] then
                local isMob = entities[id].kind == "mob"
                mobAI.cleanup(id)
                grid.remove(entities[id])
                entities[id] = nil
                if isMob then mobRemoveCount = mobRemoveCount + 1 end
            end
        end
    end

    phaseEnd("prologue", t0); t0 = moonCore.clock()

    -- Phase: 玩家状态更新 (TS per-player loop, 仅在在线时执行)
    if hasPlayers then
    processInputs()  -- TS: movement applied inside per-player loop, after prologue

    -- 跨分片玩家迁移检测: 玩家走到相邻 region 且该 region 映射到其他分片
    local migratePlayers = {}
    for pid, meta in pairs(players) do
        local pe = entities[pid]
        if pe and not pe.dead and not meta.linkdeadSince then
            local prx, prz = config.regionOf(pe.pos.x, pe.pos.z)
            if config.regionToShard(prx, prz) ~= shardId then
                table.insert(migratePlayers, pid)
            end
        end
    end
    for _, pid in ipairs(migratePlayers) do
        migratePlayerOut(pid)
    end

    for pid, meta in pairs(players) do
        local e = entities[pid]
        if e then
            wanted.decayWanted(meta, config.DT)
            pcall(function()
                if not e.dead then
                    warriorStance.ensureWarriorStance(e, meta)
                    local regenEvents = regen.updateRegen(e, meta, tick)
                    for _, ev in ipairs(regenEvents) do table.insert(combatEvents, ev) end
                    restedXp.updateRested(e, meta, config.DT)
                    mount.update(e, config.DT, false)
                    local fishEvent = fishing.update(e, config.DT, tick)
                    if fishEvent then table.insert(combatEvents, fishEvent) end
                    -- 呼吸/溺水
                    local isSubmerged = e.pos.y < -1.5
                    local drown = breath.updateBreath(e, isSubmerged)
                    if drown and drown.dmg then
                        e.hp = math.max(0, e.hp - drown.dmg)
                        table.insert(combatEvents, { type = "damage", sourceId = -1, targetId = pid,
                            amount = drown.dmg, crit = false, school = "physical", ability = nil, kind = "hit" })
                        if e.hp <= 0 then e.dead = true end
                    end
                    -- 泳者疲劳
                    local fatigueEvents = swimFatigue.updateSwimFatigue(e, e.pos)
                    for _, ev in ipairs(fatigueEvents) do table.insert(combatEvents, ev) end
                    -- 自然之怒
                    local nfEvents = naturesFury.tickNaturesFury(e, meta, tick, partyMod)
                    for _, ev in ipairs(nfEvents) do table.insert(combatEvents, ev) end
                    -- 采集授权下发
                    if meta.pendingGatherGrants and #meta.pendingGatherGrants > 0 then
                        meta.pendingGatherGrants = {}
                    end
                    -- 城镇专精重配
                    if meta.pendingTownFocus and meta.pendingTownFocus > 0 then
                        meta.pendingTownFocus = nil
                    end
                    -- 坠落伤害事件
                    if e._fallDamage and e._fallDamage > 0 then
                        table.insert(combatEvents, { type = "damage", sourceId = -1, targetId = pid,
                            amount = e._fallDamage, crit = false, school = "physical", ability = nil, kind = "hit" })
                        e._fallDamage = nil
                    end
                end
                -- 宠物 AI (无论玩家死活, 宠物仍需更新)
                if e.kind == "player" then
                    local _, petEvents = petAI.updatePet(e, entities, config.DT)
                    if petEvents then
                        for _, ev in ipairs(petEvents) do table.insert(combatEvents, ev) end
                    end
                end
            end)
        end
    end
    end -- hasPlayers guard for player state update

    phaseEnd("player", t0); t0 = moonCore.clock()

    -- Phase: 战斗 (仅在有玩家时)
    if hasPlayers then
    local cEvents = safeCall("combatTick", function() return combatTick(config.DT) end)
    for _, ev in ipairs(cEvents) do table.insert(combatEvents, ev) end
    for _, ev in ipairs(worldBossEvents) do table.insert(combatEvents, ev) end
    for _, ev in ipairs(groundAoEEvents) do table.insert(combatEvents, ev) end
    for _, ev in ipairs(frozenOrbEvents) do table.insert(combatEvents, ev) end
    for _, ev in ipairs(projectileEvents) do table.insert(combatEvents, ev) end
    for _, ev in ipairs(riftEvents) do table.insert(combatEvents, ev) end

    -- Phase: 社交系统 (竞技场/战场)
    local arenaEvents = safeCall("arena.update", function() return arena.update(simTime, config.DT, entities) end)
    local bgEvents = safeCall("battleground.update", function() return battleground.update(simTime, entities) end)
    for _, ev in ipairs(arenaEvents) do table.insert(combatEvents, ev) end
    for _, ev in ipairs(bgEvents) do table.insert(combatEvents, ev) end
    -- 竞技场匹配/结束事件 → 同步玩家 self.arena 状态
    for _, ev in ipairs(arenaEvents) do
        if ev.type == "arena_match_found" then
            for _, pid in ipairs(arena.getTeamPlayers(ev.team1)) do
                if players[pid] then players[pid].arena = { rating = arena.getRating(pid), inMatch = ev.matchId, inQueue = false } end
            end
            for _, pid in ipairs(arena.getTeamPlayers(ev.team2)) do
                if players[pid] then players[pid].arena = { rating = arena.getRating(pid), inMatch = ev.matchId, inQueue = false } end
            end
        elseif ev.type == "arena_match_end" then
            for _, pid in ipairs(arena.getTeamPlayers(ev.team1)) do
                if players[pid] then players[pid].arena = { rating = arena.getRating(pid), inMatch = false } end
            end
            for _, pid in ipairs(arena.getTeamPlayers(ev.team2)) do
                if players[pid] then players[pid].arena = { rating = arena.getRating(pid), inMatch = false } end
            end
        end
    end

    -- Phase: 深层系统
    local delveEvents = safeCall("delve.update", function() return delve.update(simTime, entities, players, config.DT) end)
    local dfEvents = safeCall("dungeonFinder.update", function() return dungeonFinder.update(simTime) end)
    local cdEvents = safeCall("cardDuel.update", function() return cardDuel.update(simTime, entities, config.DT) end)
    local lrEvents = safeCall("lootRoll.update", function() return lootRoll.update(config.DT) end)
    local rcEvents = safeCall("readyCheck.update", function() return readyCheck.update(config.DT) end)
    for _, ev in ipairs(delveEvents) do table.insert(combatEvents, ev) end
    for _, ev in ipairs(dfEvents) do table.insert(combatEvents, ev) end
    for _, ev in ipairs(cdEvents) do table.insert(combatEvents, ev) end
    for _, ev in ipairs(lrEvents) do table.insert(combatEvents, ev) end
    for _, ev in ipairs(rcEvents) do table.insert(combatEvents, ev) end
    end -- hasPlayers combat guard

    phaseEnd("combat", t0); t0 = moonCore.clock()

    -- Phase: 功勋 + 解除卡死 + 复活提议 + Raid Boss
    if hasPlayers then
    for pid, meta in pairs(players) do
        local deedEvents = safeCall("deeds.update", function() return deeds.update(pid) end)
        for _, ev in ipairs(deedEvents) do table.insert(combatEvents, ev) end
    end
    local unstuckEvents = safeCall("unstuck.update", function() return unstuck.update(config.DT, entities) end)
    local roEvents = safeCall("resurrectionOffer.update", function() return resurrectionOffer.update(config.DT) end)
    local nythEvents = safeCall("nythraxis.update", function() return nythraxis.update(entities, players, config.DT) end)
    for _, ev in ipairs(unstuckEvents) do table.insert(combatEvents, ev) end
    for _, ev in ipairs(roEvents) do table.insert(combatEvents, ev) end
    for _, ev in ipairs(nythEvents) do table.insert(combatEvents, ev) end

    -- Phase: 延迟事件清空 (TS drainDelayedEvents: tick 尾部, 在 deeds 之前)
    local delayedDue = safeCall("delayedEvents.drain", function() return delayedEvents.drain(simTime) end)
    for _, ev in ipairs(delayedDue) do table.insert(combatEvents, ev) end

    -- Phase: 委托订单板清理 (TS updateCommissionOrders: 无 rng)
    safeCall("commissionOrders.update", function() commissionOrders.update() end)

    -- Phase: 护送 (TS updateEscorts: 无 rng)
    local escortEvents = safeCall("escorts.update", function()
        return escorts.update(entities, players, createMobEntity, grid, config.DT)
    end)
    for _, ev in ipairs(escortEvents) do table.insert(combatEvents, ev) end
    end -- hasPlayers: deeds/unstuck/nyth/escort guard

    phaseEnd("misc", t0); t0 = moonCore.clock()

    -- Phase: 广播 — 每 tick 发快照+事件 (内部遍历 players 表, 空表时零开销)
    pcall(ghostSync)
    pcall(broadcastSnapshot)
    pcall(function() sendCombatEvents(combatEvents) end)

    phaseEnd("broadcast", t0); t0 = moonCore.clock()

    -- Phase: Dragonkin Brood (龙蛋靠近偷袭/孵化, 仅在有玩家时)
    if hasPlayers then
    local broodEvents = safeCall("dragonkinBrood.update", function()
        return dragonkinBrood.update(entities, players, createMobEntity, grid, config.DT)
    end)
    for _, ev in ipairs(broodEvents) do table.insert(combatEvents, ev) end
    end

    phaseEnd("brood", t0); t0 = moonCore.clock()

    -- Phase: EngagedPids pass + NPC aura cleanse + object respawn (仅在有玩家时)
    if hasPlayers then
    local engagedPids = {}
    for _, e in pairs(entities) do
        -- engaged 收集
        if not e.dead then
            if e.kind == "mob" then
                if e.ownerId == nil then
                    local state = e.aiState
                    if (state == "chasing" or state == "combat" or state == "fleeing") and e.aggroTargetId then
                        engagedPids[e.aggroTargetId] = true
                        local tgt = entities[e.aggroTargetId]
                        if tgt and tgt.ownerId then
                            engagedPids[tgt.ownerId] = true
                        end
                    end
                elseif e.aggroTargetId and e.combatTimer < 5 then
                    engagedPids[e.ownerId] = true
                end
            elseif e.kind == "npc" then
                -- NPC 光环清理
                if e.auras then
                    local toRemove = {}
                    for id, a in pairs(e.auras) do
                        if a.isDebuff then table.insert(toRemove, id) end
                    end
                    for _, id in ipairs(toRemove) do e.auras[id] = nil end
                end
            elseif e.kind == "object" and not e.lootable then
                e.respawnTimer = (e.respawnTimer or 0) - config.DT
                if e.respawnTimer <= 0 then e.lootable = true end
            end
        end
    end
    for pid, meta in pairs(players) do
        local p = entities[pid]
        if p then
            p.inCombat = engagedPids[pid] or (p.combatTimer or 0) < 5
        end
    end
    end -- hasPlayers engagedPids guard

    phaseEnd("engaged", t0); t0 = moonCore.clock()

    -- Phase: 玩家网格刷新
    -- grid.update 已在 processInputs / mob AI 按实体调用, 无需全量 refresh
    local playerEntities = {}
    for pid, meta in pairs(players) do
        local pe = entities[pid]
        if pe then table.insert(playerEntities, pe) end
    end

    -- Phase: 保存
    saveTimer = saveTimer + config.DT
    if saveTimer >= config.AUTOSAVE_SECONDS then
        saveTimer = 0; pcall(autosave)
    end

    -- Phase: 断线宽限期清理 (每 10 秒检查)
    if tick % (config.TICK_RATE * 10) == 0 then
        pcall(sweepLinkdead)
    end

    phaseEnd("save", t0)

    -- 周期性状态日志 (含 tick 耗时); 生产模式不输出, 减少日志噪音
    if not config.isProduction() and tick % (config.TICK_RATE * 10) == 0 then
        local n = 0; for _ in pairs(players) do n = n + 1 end
        local m = 0; for _, e in pairs(entities) do if e.kind == "mob" and not e.dead then m = m + 1 end end
        print(string.format(shardTag("[World]") .. " t=%d time=%.1f players=%d mobs=%d", tick, simTime, n, m))
    end

    -- 分相计时: 每 10 秒墙上时间打印一次 (tick 慢时不受 200-tick 间隔影响); 生产模式不输出
    if not config.isProduction() then
        local phaseNow = moonCore.clock()
        if phaseNow - phaseLastReport >= 10 then
            phaseLastReport = phaseNow
            phaseReport()
        end
    end
end

local function gameTick()
    if not running then return end

    -- 墙上时钟高精度秒测量 tick 耗时, 补偿调度到固定 DT 间隔
    -- os.clock() 是 CPU 时间, 会因 GC/I/O/多线程漂移; core.clock() 是真实墙上时钟
    local start = moonCore.clock()
    local ok, err = pcall(doGameTick)
    if not ok then
        print(string.format("[World] TICK CRASH: %s", tostring(err)))
    end
    local elapsed = moonCore.clock() - start
    local delay = math.max(1, math.floor((config.DT - elapsed) * 1000))
    if tick % 200 == 0 then
        print(string.format(shardTag("[TickDiag]") .. " tick=%d elapsed=%.2fms delay=%dms", tick, elapsed * 1000, delay))
    end
    moon.timeout(delay, gameTick)
end

----------------------------------------------
-- 消息处理
----------------------------------------------

moon.dispatch("lua", function(sender, session, msg)
    if type(msg) ~= "table" then return end
    local t = msg.t

    if t == "joinPlayer" then
        local okj, errj = pcall(joinPlayer, msg.pid, msg.characterId, msg.accountId, msg.name, msg.cls, msg.level, msg.state, msg.leaseNonce)
        if not okj then
            print(string.format("[World] joinPlayer ERROR pid=%d: %s", msg.pid, tostring(errj)))
        end
        moon.response("lua", sender, session, { ok = okj })
    elseif t == "playerLeave" then
        leavePlayer(msg.pid)
        moon.response("lua", sender, session, { ok = true })
    elseif t == "playerDisconnected" then
        local meta = players[msg.pid]
        if meta then
            meta.linkdeadSince = os.time()
            print(string.format("[World] Linkdead: pid=%d name=%s (sweep in %ds)", msg.pid, meta.name, math.floor(config.LINKDEAD_GRACE_MS / 1000)))
        end
    elseif t == "playerResumed" then
        -- 断线重连: 清除 linkdead 标记, 继续使用原实体 (对应 linkdead.ts planJoin resume)
        local meta = players[msg.pid]
        if meta then
            meta.linkdeadSince = nil
            -- 重连清自动战斗状态: 不会上线继续自动打怪 (GTA 异常兜底)
            local re = entities[msg.pid]
            if re then combatState.idle(re) end
            print(string.format("[World] Resume: pid=%d name=%s", msg.pid, meta.name))
        end
    elseif t == "queryPlayerGate" then
        -- 多 gate 跨实例 resume 查询: 角色在本分片则返回 pid/shard/所属 gate/linkdead
        local found = false
        for pid, meta in pairs(players) do
            if meta.characterId == msg.characterId then
                moon.response("lua", sender, session, {
                    ok = true,
                    pid = pid,
                    shard = shardId,
                    gateIndex = gateOf(pid),
                    linkdead = meta.linkdeadSince ~= nil,
                })
                found = true
                break
            end
        end
        if not found then moon.response("lua", sender, session, { ok = false }) end
    elseif t == "playerInput" then
        local pid = msg.pid
        local e = entities[pid]
        if e and (not e.dead or e.ghost) then
            inputQueue[pid] = { mi = msg.mi, facing = msg.facing, seq = msg.seq }
        end
    elseif t == "playerCommand" then
        local hc = moon.exports.handleCommand
        if hc then
            local ok = hc(msg.pid, msg.msg)
            if msg.msg and msg.msg.rid then
                local gs = gateSvcFor(msg.pid)
                if gs then moon.send("lua", gs, { t = "commandOutcome", pid = msg.pid, rid = msg.msg.rid, ok = ok }) end
            end
        end
    elseif t == "getPlayerCount" then
        local n = 0; for _ in pairs(players) do n = n + 1 end
        moon.response("lua", sender, session, { ok = true, data = n })
    elseif t == "ghostSync" then
        -- 接收相邻分片的 ghost 实体 (全量替换该源分片的旧 ghost)
        local src = msg.shardId
        if ghostByShard[src] then
            for _, g in ipairs(ghostByShard[src]) do
                ghostEntities[g.id] = nil
                grid.ghostRemove(g)
            end
        end
        ghostByShard[src] = msg.ghosts or {}
        for _, g in ipairs(ghostByShard[src]) do
            -- 跳过已变成本地实体的 id (如刚迁移入站的 mob), 避免快照重复下发
            if not entities[g.id] then
                ghostEntities[g.id] = g
                grid.ghostInsert(g)
            end
        end
    elseif t == "combatForward" then
        -- 跨分片战斗: 归属分片用重建的攻击者快照结算伤害, 结果回传攻击者分片
        local target = entities[msg.targetId]
        local res = { damage = 0, crit = false, offhand = msg.isOffhand }
        if target and not target.dead and msg.attacker then
            local atk = msg.attacker
            if msg.ranged then
                local rr = autoAttack.rangedSwingResult(atk, target)
                res = { damage = rr.damage, crit = rr.crit, ranged = true }
                if rr.damage > 0 then
                    if target.kind == "mob" then
                        threatMod.addThreat(target.id, atk.id, rr.damage)
                    end
                    if target.hp <= 0 then applyForwardedKill(target); res.targetDead = true end
                end
            else
                local opts = {
                    weaponMult = msg.isOffhand and 0.5 or 1,
                    whiteDualWieldPenalty = msg.isOffhand and true or nil,
                }
                local r = damage.calcPhysical(atk, target, opts)
                res = { damage = r.damage, crit = r.crit, offhand = msg.isOffhand,
                        blocked = r.blocked, dodged = r.dodged, missed = r.missed }
                if r.damage > 0 then
                    target.hp = math.max(0, target.hp - r.damage)
                    if target.kind == "mob" then
                        threatMod.addThreat(target.id, atk.id, r.damage)
                    end
                    if target.hp <= 0 then applyForwardedKill(target); res.targetDead = true end
                end
            end
        end
        moon.send("lua", sender, { t = "combatResult", attackerId = msg.attacker and msg.attacker.id, targetId = msg.targetId, result = res })
    elseif t == "combatResult" then
        -- 跨分片战斗结果回传: 生成标准 damage 事件 (世界广播)
        if msg.result and msg.result.damage > 0 then
            noteEvents({
                eventWire.damage(msg.attackerId, msg.targetId,
                    msg.result.damage, msg.result.crit,
                    eventWire.kindFromFlags(msg.result.missed, msg.result.dodged, msg.result.blocked)),
            })
        end
    elseif t == "castForward" then
        -- 跨分片施法结算: 归属分片用攻击者快照+技能解析效果 (可选投射物飞行延迟)
        local function resolve()
            local target = entities[msg.targetId]
            if not target or target.dead or not msg.attacker then return end
            local ability = abilities.ABILITIES[msg.abilityId]
            if not ability then return end
            local atk = msg.attacker
            local events = {}
            local isSpell = ability.school and ability.school ~= "physical"
            local isFriendly = false
            if ability.effects then
                for _, ef in ipairs(ability.effects) do
                    if ef.type == "heal" or ef.type == "aoeHeal" or ef.type == "hot" or
                       (ef.type == "buff" and ef.target == "self") or ef.target == "friendly" then
                        isFriendly = true
                        break
                    end
                end
            end
            if isSpell and not isFriendly then
                if spellResist.isSpellResisted(atk.level, target.level, atk.hitBonus or 0) then
                    table.insert(events, eventWire.resist(atk.id, target.id, ability.school or "magic", ability.name))
                    moon.send("lua", sender, { t = "castResult", attackerId = atk.id, targetId = target.id, events = events })
                    return
                end
            end
            local evs = fxDispatch.execute(atk, target, ability, entities, simTime)
            for _, ev in ipairs(evs) do
                table.insert(events, ev)
                if ev.type == "damage" and target.kind == "mob" then
                    threatMod.addThreat(target.id, atk.id, ev.amount or 0, ability.school, atk)
                end
            end
            if target.hp <= 0 then applyForwardedKill(target) end
            moon.send("lua", sender, { t = "castResult", attackerId = atk.id, targetId = target.id, events = events })
        end
        if msg.delayMs and msg.delayMs > 0 then
            moon.timeout(msg.delayMs, resolve)
        else
            resolve()
        end
    elseif t == "castResult" then
        -- 跨分片施法结果回传: 标准 damage/heal2 事件走世界广播
        if msg.events and #msg.events > 0 then
            noteEvents(msg.events)
        end
    elseif t == "pvpConsent" then
        -- 跨分片 PVP 同意: 被攻击方标记进入 PVP_FIGHT (不改其目标/自动攻击)
        local target = entities[msg.targetId]
        if target and target.kind == "player" and not target.dead then
            combatState.flagPvp(target)
        end
    elseif t == "entityMigrate" then
        -- 跨分片 mob 迁移入站: 以原 id 重建实体 + 恢复 AI/仇恨 (完整状态迁移)
        local ser = msg.entity
        if ser and ser.id and ser.kind == "mob" and not entities[ser.id] then
            local pos = ser.pos or { x = 0, y = 0, z = 0 }
            local homePos = (ser.ai and ser.ai.spawnPos) or pos
            local e = Entity.new(ser.id, "mob", ser.templateId, ser.name, ser.level, pos)
            e.facing = ser.facing or 0
            e.hostile = ser.hostile ~= false
            e.spawnPos = { x = homePos.x, y = homePos.y, z = homePos.z }
            e.homeShard = ser.homeShard or shardId
            mobAI.initMob(e, ser.templateId, e.spawnPos)
            e.hp = ser.hp or e.hp
            e.maxHp = ser.maxHp or e.maxHp
            e.auras = ser.auras or {}
            e.aggroTargetId = ser.aggroTargetId
            e.combatTimer = ser.combatTimer
            e.migrateCooldown = ser.migrateCooldown
            if ser.ai then mobAI.restore(e.id, ser.ai) end
            if ser.threat then threatMod.restoreThreat(e.id, ser.threat) end
            entities[e.id] = e
            ghostEntities[e.id] = nil  -- 清除迁移前的残留 ghost (避免快照重复)
            grid.insert(e)
            print(string.format("[Mob] Migrate in: id=%d %s shard %d", e.id, ser.templateId, shardId))
        end
    elseif t == "mobCampDeath" then
        -- 迁移走的 mob 在目标分片死亡, 回传 home 分片扣除营地计数
        if msg.templateId then
            mobLifecycle.onMobCampDeath(msg.templateId)
        end
    elseif t == "playerMigrate" then
        -- 跨分片玩家迁移入站: 以原 pid 重建玩家 (复用 joinPlayer 全量重建)
        if msg.pid and msg.state and not entities[msg.pid] then
            joinPlayer(msg.pid, msg.characterId, msg.accountId, msg.name, msg.cls, msg.level, msg.state, msg.leaseNonce)
            -- 迁移冷却: 目标分片用本地 simTime 重新计时, 防边界振荡
            local meta = players[msg.pid]
            if meta then meta._migrateCooldown = simTime + 5 end
            -- 恢复瞬态战斗状态 (PvP 同意/决斗对象), 避免跨片迁移把 pvp_fight 重置回 idle
            local ne = entities[msg.pid]
            if ne then
                if msg.combatState then ne.combatState = msg.combatState end
                if msg.duelPartnerId then ne.duelPartnerId = msg.duelPartnerId end
            end
            print(string.format("[World] Player migrate in: pid=%d %s shard %d", msg.pid, msg.name, shardId))
        end
    end
end)

----------------------------------------------
-- 命令处理 (通过 moon.exports 暴露)
----------------------------------------------

-- 转发社交命令到 Social Service (pid → character_id 解析, 异步 + 回执 log)
-- 变更成功后推送 social 帧给客户端 (好友/黑名单/公会窗口)
local function normalizeSocialList(rows)
    local out = {}
    for _, r in ipairs(rows or {}) do
        table.insert(out, {
            id = r.friend_id or r.blocked_id or r.ignored_id or r.id,
            name = r.name or "",
            class = r.class,
            level = r.level,
            online = false,
        })
    end
    return out
end

pushSocialFrame = function(pid)
    local meta = players[pid]
    if not meta or not meta.characterId then return end
    moon.async(function()
        local svc = moon.queryservice("social")
        local gs = gateSvcFor(pid)
        if not svc or not gs then return end
        local charId = meta.characterId
        local friends = moon.call("lua", svc, { op = "friend_list", charId = charId })
        local blocks = moon.call("lua", svc, { op = "block_list", charId = charId })
        local ignores = moon.call("lua", svc, { op = "ignore_list", charId = charId })
        local guild = moon.call("lua", svc, { op = "guild_info", charId = charId })
        if guild and guild.data then
            meta.guildId = guild.data.id
            meta.guildRank = guild.data.rank or 2
        end
        local frame = jh.buildSocialFrame({
            friends = normalizeSocialList(friends and friends.data),
            blocks = normalizeSocialList(blocks and blocks.data),
            ignores = normalizeSocialList(ignores and ignores.data),
            guild = guild and guild.data or nil,
        })
        moon.send("lua", gs, { t = "sendToPlayer", pid = pid, frame = frame })
    end)
end

local function socialCmd(pid, op, targetPid, name)
    local meta = players[pid]
    if not meta or not meta.characterId then return end
    local charId = meta.characterId

    local targetCharId = nil
    if targetPid then
        local tmeta = players[targetPid]
        if tmeta and tmeta.characterId then
            targetCharId = tmeta.characterId
        end
    end

    moon.async(function()
        local svc = moon.queryservice("social")
        if not svc then
            noteEvents({{ type = "log", text = "Social service unavailable", pid = pid }})
            return
        end
        local msg = { op = op, charId = charId }
        if op == "guild_create" then msg.name = name or ""
        elseif op == "guild_set_motd" then msg.motd = name or ""
        elseif targetCharId then msg.targetId = targetCharId
        elseif op == "guild_accept" or op == "guild_decline" or op == "guild_disband"
            or op == "guild_leave" or op == "friend_list" or op == "block_list"
            or op == "ignore_list" or op == "guild_info" then
            -- 无需目标 (自操作 / 读列表)
        else
            noteEvents({{ type = "log", text = "Target not online", pid = pid }})
            return
        end
        local resp = moon.call("lua", svc, msg)
        local ok = resp and resp.ok
        local text = ok and (resp.data or "ok") or (resp and resp.error or "Failed")
        print(string.format("[World] socialCmd pid=%d op=%s ok=%s text=%s", pid, op, tostring(ok), tostring(text)))
        noteEvents({{ type = "log", text = tostring(text), pid = pid }})
        if ok then
            if op == "guild_invite" and targetPid then
                -- 通知被邀请者 (客户端 guildInvite 事件弹窗)
                noteEvents({{
                    type = "guildInvite",
                    fromName = meta.name,
                    guildName = tostring(text),
                    pid = targetPid,
                }})
            end
            pushSocialFrame(pid)
        end
    end)
end

moon.exports.handleCommand = function(pid, cmd)
    if not pid or not cmd or not cmd.cmd then return false end
    local e = entities[pid]
    if not e then return false end

    -- 统一分发: 以客户端 COMMAND_NAMES 为准 (command_dispatch.lua)
    local ok = require("world.command_dispatch").dispatch({
        entities = entities, players = players, simTime = simTime, tick = tick,
        grid = grid, config = config,
        abilities = abilities, autoAttack = autoAttack, combatState = combatState, castSys = castSys,
        fxDispatch = fxDispatch, spirit = spirit, aura = aura, ccDr = ccDr,
        spellResist = spellResist, rage = rage, setProcs = setProcs,
        empower = empower, regen = regen, playerStats = playerStats,
        talent = talent, inventory = inventory, vendor = vendor, quest = quest,
        bank = bankMod, profession = profession, instanceMod = instanceMod,
        arena = arena, battleground = battleground, rift = rift, delve = delve,
        dungeonFinder = dungeonFinder, cardDuel = cardDuel, lootRoll = lootRoll,
        readyCheck = readyCheck, petAI = petAI, fishing = fishing, mount = mount,
        commissionOrders = commissionOrders, valeCup = valeCup, unstuck = unstuck, resurrectionOffer = resurrectionOffer,
        heroicDungeon = heroicDungeon, guildBank = guildBank, partyMod = partyMod,
        tradeMod = tradeMod, duelMod = duelMod, chat = chat, xp = xp,
        deeds = deeds, pvpHonor = pvpHonor, doorTriggers = doorTriggers,
        noteEvents = noteEvents, socialCmd = socialCmd,
        findNearestEnemy = findNearestEnemy,
        findNearestTarget = findNearestTarget, ghostEntities = ghostEntities,
        forwardCast = forwardCast,
        forwardPvpConsent = forwardPvpConsent,
        createMobEntity = createMobEntity, allocId = allocId,
        createPedestrianEntity = createPedestrianEntity, despawnEntity = despawnEntity,
        marketOp = marketOp, mailOp = mailOp, guildBankOp = guildBankOp,
        protoGet = protoGet, nodeTypeFor = nodeTypeFor,
    }, pid, cmd)
    local meta = players[pid]
    if meta then meta._wireVer = (meta._wireVer or 0) + 1 end
    return ok == true
end

-- 旧实现保留为死代码 (不执行, 待后续清理)
-- 启动
running = true

-- 加载内容数据表 (proto/*.json)
pcall(function()
    require("proto.load").load()
end)

-- 加载副本门触发器 (依赖 proto dungeons)
pcall(function()
    doorTriggers.loadDoors()
end)

-- 加载任务定义 (从 proto/quests.json)
pcall(function()
    quest.loadFromProto()
end)

-- 构建商店商品 (从 proto/items.json)
pcall(function()
    vendor.loadFromProto()
end)

-- 加载坐骑数据 (从 proto/mounts.json)
pcall(function()
    mount.loadFromProto()
end)

-- 合并 proto 技能 (从 proto/abilities.json, TS 结构)
pcall(function()
    abilities.loadFromProto()
end)

-- 加载地下城查找器列表 (从 proto/dungeons.json)
pcall(function()
    dungeonFinder.loadFromProto()
end)

-- 加载 Delve 定义 (从 proto/delves.json)
pcall(function()
    delve.loadFromProto()
end)

-- 加载制造配方 (从 proto/recipes.json)
pcall(function()
    profession.loadFromProto()
end)

-- 加载区域定义 (从 proto/zones.json)
pcall(function()
    zone.loadFromProto()
end)

-- 生成 NPC 实体 (从 proto/npcs.json)
local npcOk, npcErr = pcall(function()
    require("world.npc_spawn").spawnAll(entities, grid, function(id, kind, templateId, name, level, pos)
        return Entity.new(id, kind, templateId, name, level, pos)
    end, allocId, shardId)
end)
if not npcOk then
    print(string.format("[World] WARNING: Failed to spawn NPCs: %s", tostring(npcErr)))
end

-- 地形诊断: 打印出生点及周边 groundHeight (确认实体 Y 正确)
do
    local t = require("world.terrain")
    local samples = { {0,0}, {5,0}, {0,5}, {-5,0}, {0,-5}, {10,10} }
    local parts = {}
    for _, s in ipairs(samples) do
        local h = t.groundHeight(s[1], s[2])
        table.insert(parts, string.format("(%d,%d)=%s", s[1], s[2], h and string.format("%.2f", h) or "nil"))
    end
    local ws = require("world.ride_height").waterLevelAt(0, 0, 0)
    print(string.format("[Terrain] Seed=%d WaterLevel=%.1f Heights: %s", t.getWorldSeed(), ws and ws or 0, table.concat(parts, " ")))
end

-- 生成采集节点实体 (从 proto/gather_nodes.json)
pcall(function()
    require("world.gather_node_spawn").spawnAll(entities, grid, function(id, kind, templateId, name, level, pos)
        return Entity.new(id, kind, templateId, name, level, pos)
    end, allocId, shardId)
end)

-- 注册世界静态碰撞体 (PROPS + 装饰 + 街灯, 确定性)
pcall(function()
    require("world.world_colliders").registerAll(terrain.getWorldSeed())
end)

-- 初始化确定性 RNG (使用固定种子确保可重现)
simrng.init(42)
print(string.format("[World] SimRNG initialized seed=%d", simrng.getSeed()))

-- 生成路人 NPC (城镇 + 野外, 漫游 + 被攻击反击)
pcall(function()
    pedestrian.spawn(entities, grid, function(id, kind, templateId, name, level, pos)
        return Entity.new(id, kind, templateId, name, level, pos)
    end, allocId, shardId)
end)

-- 绑定移动内核依赖 (TS PlayerMotionDeps)
move.bindDeps({
    seed = 0,
    dt = config.DT,
    cancelCast = function(e) castSys.cancelCast(e) end,
    standUp = function(e) e.sitting = false end,
    dealDamage = function(p, dmg)
        p.hp = math.max(0, p.hp - dmg)
        p._fallDamage = dmg
    end,
})

-- 初始化裂隙传送门 (依赖 simrng)
rift.initWorldPortals()
print("[World] Rift portals initialized")

-- 初始化 Nythraxis 传送门 (仅注册)
print("[World] All modules loaded — starting tick loop")

-- 从 proto/camps.json 加载世界营地 (全图 mob 刷新)
local campsOk, campsErr = pcall(function()
    mobLifecycle.loadCampsFromProto(shardId)
end)
if not campsOk then
    print(string.format("[World] WARNING: Failed to load camps from proto: %s", tostring(campsErr)))
else
    -- 世界启动时一次性填充全部营地 mob。
    -- 否则 mob 只能在玩家上线后由 checkRespawn (被 hasPlayers 门控) 逐个补出,
    -- 导致首个玩家连接时 700 mob 突然集中生成 + AI 全激活 → 死亡螺旋/内存堆积。
    local spawned = mobLifecycle.fillInitialMobs(entities, createMobEntity, grid)
    for _, mob in ipairs(spawned) do
        entities[mob.id] = mob
        grid.insert(mob)
    end
    print(string.format("[World] Filled %d initial camp mobs", #spawned))
end

moon.async(function()
    moon.sleep(1500)
    local db = dbSvc(); local gs = gateSvcFor(1000) -- gate_0 探测
    if db then print(string.format("[World] DB=0x%X", db)) end
    if gs then print(string.format("[World] Gate=0x%X", gs)) end
end)
moon.timeout(1000, gameTick)
print(shardTag("[World] Service ready"))
