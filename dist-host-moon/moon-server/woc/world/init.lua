-- World of ClaudeCraft — World Service
-- 核心仿真: tick 循环、实体管理、命令调度
-- 对应原项目 server/game.ts GameServer + src/sim/sim.ts tick()
-- 确定性协议: 所有随机调用使用共享 simrng 单例

local moon = require("moon")
local json = require("json")
local config = require("config")
local Entity = require("world.entity")
local simrng = require("world.simrng")
local move = require("world.movement")
local grid = require("world.grid")
local chat = require("world.chat")
local snapshot = require("world.snapshot")
local jh = require("shared.json_helpers")
require("shared.sproto_helpers").init()
local playerStats = require("world.player_stats")

-- 战斗模块
local damage = require("world.combat.damage")
local healMod = require("world.combat.heal")
local castSys = require("world.combat.cast")
local aura = require("world.combat.aura")
local autoAttack = require("world.combat.auto_attack")
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
local doorTriggers = require("world.door_triggers")
local escorts = require("world.escorts")
local commissionOrders = require("world.commission_orders")
local valeCup = require("world.vale_cup")
local naturesFury = require("world.natures_fury")
local zone = require("world.zone")

local entities = {}     -- id → Entity
local players = {}      -- pid → PlayerMeta
local snapSessions = {} -- pid → { seenEntities, lastDyn, lastSent } 快照 delta 追踪

-- forward 声明 (pushSocialFrame 定义在 joinPlayer 之后, 需先声明)
local pushSocialFrame
local simTime = 0
local tick = 0
local running = false
local nextId = 10000

local function allocId() nextId = nextId + 1; return nextId end

-- 服务查找
local function dbSvc() return moon.queryservice("db") end
local function gateSvc() return moon.queryservice("gate") end

-- 帮助函数
-- 事件路由: 个人事件 (带 pid/toPid) 只发相关玩家; 世界事件 (无 pid) 广播全部
-- 与 server/game.ts routeEvents 的 per-session 语义对齐, 避免私聊/个人 loot 泄漏
local function noteEvents(evs)
    if not gateSvc() or not evs or #evs == 0 then return end
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
        moon.send("lua", gateSvc(), { t = "broadcastSnap", data = jh.buildEventsFrame(world) })
    end
    for targetPid, evs2 in pairs(perPid) do
        moon.send("lua", gateSvc(), { t = "sendToPlayer", pid = targetPid, frame = jh.buildEventsFrame(evs2) })
    end
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

local function mailOp(pid, msg)
    moon.async(function()
        local svc = moon.queryservice("mail")
        if not svc then noteEvents({ { type = "log", text = "Mail unavailable", pid = pid } }); return end
        local resp = moon.call("lua", svc, msg)
        local ok = resp and resp.ok
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
            local gs = gateSvc()
            if gs then
                moon.send("lua", gs, { t = "sendToPlayer", pid = pid, frame = require("shared.sproto_helpers").packFrame("GbankLogFrame", { ok = true, entries = entries }) })
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

local function findNearestEnemy(e)
    local best, bestDistSq = nil, math.huge
    for id, other in pairs(entities) do
        if other.kind == "mob" and not other.dead then
            local dx = e.pos.x - other.pos.x
            local dz = e.pos.z - other.pos.z
            local dsq = dx * dx + dz * dz
            if dsq < bestDistSq then
                best = other; bestDistSq = dsq
            end
        end
    end
    return best
end

----------------------------------------------
-- 实体管理
----------------------------------------------

local function createPlayerEntity(pid, cls, name, level, stateData)
    local terrain = require("world.terrain")
    local pos = { x = 0, y = terrain.placementHeight(0, 0), z = 0 }
    if stateData and stateData.pos then
        pos = { x = stateData.pos.x or 0, y = stateData.pos.y or terrain.placementHeight(stateData.pos.x or 0, stateData.pos.z or 0), z = stateData.pos.z or 0 }
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
    local id = allocId()
    local e = Entity.new(id, "mob", templateId, name, level, pos)
    e.hostile = true
    e.spawnPos = { x = pos.x, y = pos.y, z = pos.z }
    mobAI.initMob(e, templateId, pos, opts)
    return e
end

local function joinPlayer(pid, characterId, accountId, name, cls, level, state, leaseNonce)
    local e = createPlayerEntity(pid, cls, name, level, state)
    entities[pid] = e
    local meta = {
        characterId = characterId, accountId = accountId,
        name = name, class = cls, level = level or 1,
        leaseNonce = leaseNonce,
        xp = (state and state.xp) or 0,
        copper = (state and state.copper) or 0,
        lifetimeXp = (state and state.lifetimeXp) or 0,
        restedXp = (state and state.restedXp) or 0,
        prestigeRank = (state and state.prestigeRank) or 0,
        honor = state and state.honor, lifetimeHonor = state and state.lifetimeHonor,
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

local function leavePlayer(pid)
    local meta = players[pid]; local e = entities[pid]
    if not meta then return end
    grid.remove(e)
    aura.cleanupDRTracker(pid)
    deeds.cleanupPlayer(pid)
    -- 清理所有 mob 对此玩家的威胁/仇恨
    for _, m in pairs(entities) do
        if m.kind == "mob" and m.threat then
            m.threat[pid] = nil
            if m.aggroTargetId == pid then m.aggroTargetId = nil end
            if m.forcedTargetId == pid then m.forcedTargetId = nil; m.forcedTargetTimer = 0 end
            if m.targetId == pid then m.targetId = nil end
        end
    end
    -- 清除其他玩家指向此玩家的 target
    for _, other in pairs(entities) do
        if other.targetId == pid then other.targetId = nil end
    end
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

local function serializeCharacter(pid)
    local e = entities[pid]; local meta = players[pid]
    if not e or not meta then return nil end
    return {
        level = meta.level or 1, xp = meta.xp or 0, copper = meta.copper or 0,
        lifetimeXp = meta.lifetimeXp or 0,
        restedXp = meta.restedXp or 0, prestigeRank = meta.prestigeRank or 0,
        honor = meta.honor, lifetimeHonor = meta.lifetimeHonor,
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

----------------------------------------------
-- 战斗 Tick (Phase 3-4: 确定性 RNG 驱动)
----------------------------------------------

-- 解析施法效果 (供瞬发 + 投射物命中复用; 含怒气/威胁/套装)
local function resolveCastEffects(e, target, ability, combatEvents, entities, simTime)
    if not ability then return end
    local evs = fxDispatch.execute(e, target, ability, entities, simTime)
    for _, ev in ipairs(evs) do
        table.insert(combatEvents, ev)
        if ev.type == "combat_damage" and target then
            if e.resourceType == "rage" then
                local rageGain = rage.rageFromDealing(ev.hp or 0, e.level)
                e.resource = math.min(e.maxResource, e.resource + rageGain)
            end
            setProcs.applySetProcs(e, target, "on_attack", simTime)
            threatMod.addThreat(target.id, e.id, ev.hp or 0, ability.school, e)
        elseif ev.type == "combat_heal" then
            local healedTarget = entities[ev.pid]
            if healedTarget then
                healMod.healingThreat(e, healedTarget, ev.hp or 0, entities, threatMod)
            end
        end
    end
    setProcs.applySetProcs(e, target, "on_spell_cast", simTime)
    -- 传奇武器 on-hit procs (TS equip_procs)
    local equipProcEvents = require("world.combat.equip_procs").applyWeaponProcs(e, target, "on_hit", ability.id, entities, simTime)
    for _, ev in ipairs(equipProcEvents) do table.insert(combatEvents, ev) end
    if target and spirit.checkDeath(target) then
        table.insert(combatEvents, { type = "death", pid = target.id })
    end
end

local function combatTick(dt)
    local combatEvents = {}

    -- 玩家施法 + 自动攻击
    for pid, e in pairs(entities) do
        if players[pid] and not e.dead then
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
                local qtarget = entities[e.targetId] or findNearestEnemy(e)
                local qok, qct = castSys.startCast(e, queuedAbility, qtarget)
                if qok then
                    -- 瞬发直接执行
                    if qct == 0 then
                        local qevs = fxDispatch.execute(e, qtarget, queuedAbility, entities, simTime)
                        for _, ev in ipairs(qevs) do table.insert(combatEvents, ev) end
                    end
                end
                goto continue_player_cast
            end

            -- 通道 tick: 执行一次通道效果
            if castResult == "channel_tick" and castingAbility then
                local ctTarget = entities[e.targetId] or findNearestEnemy(e)
                local ctEvs = fxDispatch.execute(e, ctTarget, castingAbility, entities, simTime)
                for _, ev in ipairs(ctEvs) do
                    table.insert(combatEvents, ev)
                    if ev.type == "combat_damage" and ctTarget then
                        threatMod.addThreat(ctTarget.id, pid, ev.hp or 0)
                    end
                end
            end

            if castResult == "complete" and castingAbility then
                local target = entities[e.targetId]
                if not target then target = findNearestEnemy(e) end

                -- TS applyAbility: 非物理法术默认作为投射物发射 (fireball 有飞行时间)
                local isSpell = castingAbility.school and castingAbility.school ~= "physical"
                local firesProjectile = castingAbility.projectile
                    or (isSpell and not castingAbility.noProjectile)

                if firesProjectile and target and target ~= e then
                    -- 投射物: 命中时解析 (TS scheduleProjectile)
                    projectile.launch(e.id, target.id, castingAbility.id, e.pos, target.pos,
                        function(src, tgt)
                            local pEvents = {}
                            -- 命中时法术抵抗
                            if isSpell then
                                if spellResist.isSpellResisted(src.level, tgt.level, src.hitBonus or 0) then
                                    table.insert(pEvents, { type = "spell_resisted", pid = pid, sid = src.id, targetId = tgt.id })
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
                            table.insert(combatEvents, { type = "spell_resisted", pid = pid, sid = e.id, targetId = target.id })
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
                if aaResult.damage > 0 then
                    if e.resourceType == "rage" then
                        local rageGain = rage.rageFromDealing(aaResult.damage, e.level)
                        local rageMult = rage.rageGenAuraMult(e.auras)
                        e.resource = math.min(e.maxResource, e.resource + rageGain * rageMult)
                    end
                    setProcs.applySetProcs(e, entities[e.targetId], "on_attack", simTime)
                end
                table.insert(combatEvents, {
                    type = "auto_attack", pid = pid, targetId = e.targetId,
                    dmg = aaResult.damage, crit = aaResult.crit, offhand = aaResult.offhand,
                    blocked = aaResult.blocked, dodged = aaResult.dodged, missed = aaResult.missed,
                })
                if e.targetId then threatMod.addThreat(e.targetId, pid, aaResult.damage) end
                local target = entities[e.targetId]
                if target and spirit.checkDeath(target) then
                    table.insert(combatEvents, { type = "death", pid = target.id })
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

    -- Mob AI 更新 (空间裁剪: 仅更新 200yd 内有存活玩家的 mob)
    local MOB_AI_RANGE_SQ = 200 * 200
    for _, e in pairs(entities) do
        if e.kind == "mob" and not e.dead then
            local nearPlayer = false
            for pid, _ in pairs(players) do
                local pe = entities[pid]
                if pe and not pe.dead then
                    local dx = e.pos.x - pe.pos.x
                    local dz = e.pos.z - pe.pos.z
                    if dx * dx + dz * dz <= MOB_AI_RANGE_SQ then
                        nearPlayer = true
                        break
                    end
                end
            end
            if nearPlayer then
                local mobEvents = mobAI.updateMob(e, entities, players, dt)
                for _, ev in ipairs(mobEvents) do table.insert(combatEvents, ev) end
            end
        end
    end

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
                table.insert(combatEvents, { type = "death", pid = e.id, x = e.pos.x, z = e.pos.z })
                print(string.format("[World] Player died: pid=%d name=%s hp=0", e.id, e.name or "?"))
                -- 从所有 mob 仇恨表移除死亡玩家 (TS 1164-1172)
                for _, m in pairs(entities) do
                    if m.kind == "mob" and m.threat then
                        m.threat[e.id] = nil
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
                table.insert(combatEvents, { type = "death", pid = e.id })
            end

            if e.kind == "mob" then
                mobAI.cleanup(e.id)
                mobLifecycle.onMobDeath(e.id, entities)
                local loot = mobLifecycle.getLoot(e)
                if loot and #loot > 0 then
                    for _, item in ipairs(loot) do
                        table.insert(combatEvents, { type = "loot", mobId = e.id, item = item })
                    end
                end
                local killer = e.targetId
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
            elseif e.kind == "player" then
                -- PvP 击杀: 找到最后造成伤害的玩家
                local killerPid = e.targetId
                if killerPid and players[killerPid] and killerPid ~= e.id then
                    pvpHonor.awardHonor(killerPid, e.level)
                end
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
            -- 使用原有移动引擎 (已验证可用)
            move.applyInput(e, input.mi, input.facing, config.DT)
            grid.update(e)
        end
        inputQueue[pid] = nil
    end
end

local function broadcastSnapshot()
    if not gateSvc() then return end
    local frames = {}
    for pid, meta in pairs(players) do
        local session = snapSessions[pid]
        if not session then
            session = { seenEntities = {}, lastDyn = {}, lastSent = {} }
            snapSessions[pid] = session
        end
        local ok, frame = pcall(snapshot.buildForPlayer, entities, players, pid, session, tick, simTime)
        if not ok then
            print(string.format("[World] SNAPSHOT ERROR pid=%d: %s", pid, tostring(frame)))
        elseif frame then frames[pid] = frame end
    end
    if next(frames) then
        moon.send("lua", gateSvc(), { t = "broadcastSnap", data = frames })
    end
end

local function sendCombatEvents(combatEvents)
    if not gateSvc() or #combatEvents == 0 then return end
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

    -- Phase: 门触发器 (TS updateDoorTriggers: 移动后检测副本入口)
    pcall(function()
        for pid, e in pairs(entities) do
            if players[pid] and not e.dead and not e.dungeonId then
                local doorEvents = doorTriggers.checkPlayerDoors(e, entities, players, simTime)
                for _, ev in ipairs(doorEvents) do
                    table.insert(combatEvents, ev)
                end
            end
        end
    end)

    local combatEvents = {}

    local function safeCall(modName, fn)
        local ok, result = pcall(fn)
        if not ok then
            print(string.format("[World] TICK ERROR in %s: %s", modName, tostring(result)))
        end
        return ok and result or {}
    end

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
                grid.remove(entities[id])
                entities[id] = nil
            end
        end
    end

    -- Phase: 玩家状态更新 (TS per-player loop, 仅在在线时执行)
    if hasPlayers then
    processInputs()  -- TS: movement applied inside per-player loop, after prologue

    for pid, e in pairs(entities) do
        local meta = players[pid]
        if meta then
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
                        table.insert(combatEvents, { type = "drown", pid = pid, dmg = drown.dmg })
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
                        table.insert(combatEvents, { type = "combat_damage", hp = e._fallDamage, pid = pid, school = "physical" })
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

    -- Phase: 广播 — 每 tick 发快照+事件 (内部遍历 players 表, 空表时零开销)
    pcall(broadcastSnapshot)
    pcall(function() sendCombatEvents(combatEvents) end)

    -- Phase: Dragonkin Brood (龙蛋靠近偷袭/孵化, 仅在有玩家时)
    if hasPlayers then
    local broodEvents = safeCall("dragonkinBrood.update", function()
        return dragonkinBrood.update(entities, players, createMobEntity, grid, config.DT)
    end)
    for _, ev in ipairs(broodEvents) do table.insert(combatEvents, ev) end
    end

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

    -- 周期性状态日志 (含 tick 耗时)
    if tick % (config.TICK_RATE * 10) == 0 then
        local n = 0; for _ in pairs(players) do n = n + 1 end
        local m = 0; for _, e in pairs(entities) do if e.kind == "mob" and not e.dead then m = m + 1 end end
        print(string.format("[World] t=%d time=%.1f players=%d mobs=%d", tick, simTime, n, m))
    end
end

local function gameTick()
    if not running then return end

    local start = os.clock()
    local ok, err = pcall(doGameTick)
    if not ok then
        print(string.format("[World] TICK CRASH: %s", tostring(err)))
    end
    local elapsed = os.clock() - start
    if elapsed > config.DT * 1.5 then
        print(string.format("[World] SLOW TICK: %.0fms (DT=%.0fms)", elapsed * 1000, config.DT * 1000))
    end

    -- Next tick at exactly DT seconds from start (not from end)
    local delay = math.max(1, math.floor((config.DT - elapsed) * 1000))
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
            print(string.format("[World] Resume: pid=%d name=%s", msg.pid, meta.name))
        end
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
                local gs = gateSvc()
                if gs then moon.send("lua", gs, { t = "commandOutcome", pid = msg.pid, rid = msg.msg.rid, ok = ok }) end
            end
        end
    elseif t == "getPlayerCount" then
        local n = 0; for _ in pairs(players) do n = n + 1 end
        moon.response("lua", sender, session, { ok = true, data = n })
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
        local gs = gateSvc()
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
        abilities = abilities, autoAttack = autoAttack, castSys = castSys,
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
        createMobEntity = createMobEntity, allocId = allocId,
        marketOp = marketOp, mailOp = mailOp, guildBankOp = guildBankOp,
        protoGet = protoGet, nodeTypeFor = nodeTypeFor,
    }, pid, cmd)
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
    end, allocId)
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
    end, allocId)
end)

-- 注册世界静态碰撞体 (PROPS + 装饰 + 街灯, 确定性)
pcall(function()
    require("world.world_colliders").registerAll(terrain.getWorldSeed())
end)

-- 初始化确定性 RNG (使用固定种子确保可重现)
simrng.init(42)
print(string.format("[World] SimRNG initialized seed=%d", simrng.getSeed()))

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
    mobLifecycle.loadCampsFromProto()
end)
if not campsOk then
    print(string.format("[World] WARNING: Failed to load camps from proto: %s", tostring(campsErr)))
end

moon.async(function()
    moon.sleep(1500)
    local db = dbSvc(); local gs = gateSvc()
    if db then print(string.format("[World] DB=0x%X", db)) end
    if gs then print(string.format("[World] Gate=0x%X", gs)) end
end)
moon.timeout(1000, gameTick)
print("[World] Service ready")
