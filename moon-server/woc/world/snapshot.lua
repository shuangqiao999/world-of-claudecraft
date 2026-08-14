-- World of ClaudeCraft — Snapshot Builder
-- 构建 send-to-client 的快照帧：{t:"snap", self, ents, keep}
-- 与客户端 src/net/online.ts applySnapshot / tests/snapshots.test.ts 对齐:
--   - self 基础标量总是发送 (res/mres/rtype/lxp/rxp/prk/copper/ap/sp/sh/crit/...)
--   - delta-guarded 字段 (ALL_DELTA_KEYS: cds/ncd/achg/achr/stats/inv/bags/equip/
--     einst/qlog/qdone/tal/party/bank/market/mail/corpse/hbl/... ) 只在变化时发送,
--     客户端以 `if (s.X !== undefined)` 语义保留旧值
--   - 实体 FULL (首次/身份变化) + LITE (动态字段 delta) + keep (未变化)

local config = require("config")
local jh = require("shared.json_helpers")
local grid = require("world.grid")
local Entity = require("world.entity")
local inventory = require("world.inventory")

local M = {}

--- 构建身份哈希 (身份 + 外观冷字段); 冷字段变化时哈希变化, 触发 full 记录重发
local function buildIdentityHash(e)
    local parts = {
        e.kind or "?",
        e.templateId or "",
        e.name or "",
        tostring(e.level or 1),
        tostring(e.skin or ""),
        tostring(e.skinCatalog or ""),
        tostring(e.mountKey or ""),
        tostring(e.mainhandItemId or ""),
        tostring(e.offhandItemId or ""),
        tostring(e.weaponSkinId or ""),
        tostring(e.holderTier or ""),
        tostring(e.holderBalance or ""),
        tostring(e.discordTier or ""),
        tostring(e.discordName or ""),
        tostring(e.discordAvatar or ""),
        tostring(e.discordJoined or ""),
        tostring(e.discordRole or ""),
        tostring(e.devTier or ""),
        tostring(e.devMergedPrs or ""),
        tostring(e.githubLogin or ""),
        tostring(e.guild or ""),
        tostring(e.title or ""),
        tostring(e.dungeonId or ""),
        tostring(e.riftTier or ""),
        tostring(e.objectItemId or ""),
        tostring(e.scale or 1),
        tostring(e.color or 0xffffff),
    }
    if e.streamerLinks and #e.streamerLinks > 0 then
        parts[#parts + 1] = table.concat(e.streamerLinks, ",")
    end
    return table.concat(parts, "|")
end

--- 计算身份哈希 (检测实体身份/外观变化); 缓存到实体, level 或 _idVer 变化时重算
--- _idVer 由各冷字段写入点 (装备/皮肤/坐骑/副本等) 递增
local function identityHash(e)
    local ver = e._idVer or 0
    if not e._idHash or e._idHashLevel ~= e.level or e._idHashVer ~= ver then
        e._idHash = buildIdentityHash(e)
        e._idHashLevel = e.level
        e._idHashVer = ver
    end
    return e._idHash
end

-- LITE 周期刷新间隔 (tick): 动态字段最多延迟这么久才强制重发 (兜底)
local LITE_REFRESH_TICKS = 20

--- 序列化玩家 buff/debuff 列表 (客户端 ClientWireAura 形状)
local function wireAuras(e)
    local out = {}
    for _, a in pairs(e.auras or {}) do
        table.insert(out, {
            id = a.id,
            name = a.name,
            duration = a.duration or 0,
            remaining = a.remaining or 0,
            isDebuff = a.isDebuff or false,
            stacks = a.stacks or 1,
            kind = a.kind,
        })
    end
    return out
end

--- delta 守卫: 检查字段是否变化 (不编码, 由调用方统一 json.encode)
--- 优化: 对标量值直接比较, 表值用 hash 比较, 避免每 tick 逐个 json.encode
local function fieldChanged(session, key, value)
    if value == nil then return false end
    local t = type(value)
    if not session.lastRaw then session.lastRaw = {} end
    if t ~= "table" then
        local lastRaw = session.lastRaw[key]
        if value == lastRaw then return false end
        session.lastRaw[key] = value
        return true
    end
    local enc = jh.safeEncode(value)
    local last = session.lastSent and session.lastSent[key]
    if enc == last then return false end
    if not session.lastSent then session.lastSent = {} end
    session.lastSent[key] = enc
    session.lastRaw[key] = enc
    return true
end

--- 构建 self 字段 (基础标量 + delta-guarded 扩展)
--- @param session table 每玩家 delta 追踪 { seenEntities, lastDyn, lastSent }
local function buildSelfJson(e, meta, session)
    -- 基础字段 (总是发送)
    local self = {
        id = e.id,
        k = e.kind or "player",
        tid = e.templateId or "",
        nm = e.name or "",
        lv = e.level or 1,
        x = jh.round2(e.pos.x),
        y = jh.round2(e.pos.y),
        z = jh.round2(e.pos.z),
        f = jh.round2(e.facing or 0),
        hp = math.floor(e.hp or 0),
        mhp = e.maxHp or 100,
    }

    -- 当前区域 (从 proto/zones.json)
    if e.kind == "player" then
        local zok, zzone = pcall(function() return require("world.zone").getZoneAt(e.pos.x, e.pos.z) end)
        if zok and zzone then
            self.zone = zzone.id
            self.zoneName = zzone.name
        end
    end

    -- 资源
    self.res = jh.round2(e.resource or 0)
    self.mres = e.maxResource or 100
    self.rtype = e.resourceType or "mana"
    self.xp = meta.xp or 0
    self.lxp = meta.lifetimeXp or 0
    self.rxp = meta.restedXp or 0
    self.prk = meta.prestigeRank or 0
    self.copper = meta.copper or 0

    -- 战斗
    self.gcd = jh.round2(e.gcdRemaining or 0)
    self.pcd = jh.round2(e.potionCdRemaining or 0)
    self.fcd = jh.round2(e.firebottleCdRemaining or 0)
    self.swing = jh.round2(e.swingTimer or 0)
    self.combo = e.comboPoints or 0
    self.target = e.targetId
    self.auto = e.autoAttack or false
    self.queued = e.queuedOnSwing or false

    -- 属性
    self.ap = e.attackPower or 0
    self.rp = e.rangedPower or 0
    self.sp = e.spellPower or 0
    self.sh = jh.round2(e.spellHaste or 0)
    self.crit = jh.round2(e.critChance or 0)
    self.dodge = jh.round2(e.dodgeChance or 0)
    self.blk = jh.round2(e.blockChance or 0)
    self.bval = e.blockValue or 0
    self.crat = e.critRating or 0
    self.hrat = e.hasteRating or 0
    self.hirat = e.hitRating or 0

    -- 状态
    self.dead = e.dead or false
    self.gh = e.ghost or false
    self.sit = e.sitting or false
    self.ack = meta.lastAcknowledgedSeq or 0

    -- 吃/喝
    if e.eating then self.eat = { remaining = e.eating.remaining or 0 } end
    if e.drinking then self.drk = { remaining = e.drinking.remaining or 0 } end

    -- 副本难度
    if meta.dungeonDifficulty then self.ddiff = meta.dungeonDifficulty end

    -- 尸体位置 (鬼魂时)
    if e.ghost and e.corpsePos then self.corpse = { x = e.corpsePos.x, z = e.corpsePos.z } end

    -- 施法 (self cast mirror)
    if e.castingAbility then
        self.cast = e.castingAbility.id or e.castingAbility
        self.castRem = jh.round2(e.castRemaining or 0)
        self.castTot = jh.round2(e.castTotal or 0)
    end

    -- ===== delta-guarded 扩展: 直接放入 self 表, 最后一次性 json.encode =====
    -- cds: 冷却时间表
    local cds = {}
    for abilityId, rem in pairs(e.cooldowns or {}) do
        if type(rem) == "number" and rem > 0 then cds[abilityId] = jh.round2(rem) end
    end
    if next(cds) and fieldChanged(session, "cds", cds) then self.cds = cds end

    local ncd = e.nodeCooldowns
    if ncd and next(ncd) and fieldChanged(session, "ncd", ncd) then self.ncd = ncd end

    local stats = e.stats and {
        str = e.stats.str or 0, agi = e.stats.agi or 0, sta = e.stats.sta or 0,
        int = e.stats.int or 0, spi = e.stats.spi or 0,
        armor = e.stats.armor or 0, pvpOffense = e.stats.pvpOffense or 0, pvpDefense = e.stats.pvpDefense or 0,
    } or nil
    if fieldChanged(session, "stats", stats) then self.stats = stats end

    local aur = wireAuras(e)
    if #aur > 0 and fieldChanged(session, "auras", aur) then self.auras = aur end

    -- 玩家 meta 字段 (inventory/bank/talents 等): 仅在 meta 变化或周期刷新时才计算/编码,
    -- 避免每 tick 对空/未变化的 meta 表做 toWireArray + json.encode
    session.selfCall = (session.selfCall or 0) + 1
    local selfVer = meta._wireVer or 0
    local metaDirty = (selfVer ~= session.lastSelfVer) or (session.selfCall % 20 == 0)
    session.lastSelfVer = selfVer

    if metaDirty then
        local invWire = inventory.toWireArray(meta.inventory)
        if fieldChanged(session, "inv", invWire) then self.inv = invWire end
        local bbk = require("world.vendor").buybackView(meta)
        if #bbk > 0 and fieldChanged(session, "buyback", bbk) then self.buyback = bbk end
        local equipWire = inventory.equipmentToWire(meta.equipment)
        if fieldChanged(session, "equip", equipWire) then self.equip = equipWire end
        if fieldChanged(session, "einst", meta.equipmentInstance) then self.einst = meta.equipmentInstance end

        if fieldChanged(session, "qlog", meta.qlog) then self.qlog = meta.qlog end
        if fieldChanged(session, "qdone", meta.qdone) then self.qdone = meta.qdone end
        if fieldChanged(session, "milestones", meta.unlockedMilestones) then self.milestones = meta.unlockedMilestones end

        if fieldChanged(session, "tal", meta.talents) then self.tal = meta.talents end

        if fieldChanged(session, "party", meta.party) then self.party = meta.party end
        if fieldChanged(session, "duel", meta.duel) then self.duel = meta.duel end
        if fieldChanged(session, "arena", meta.arena) then self.arena = meta.arena end

        if fieldChanged(session, "honor", meta.honor) then self.honor = meta.honor end
        if fieldChanged(session, "lhonor", meta.lifetimeHonor) then self.lhonor = meta.lifetimeHonor end

        if fieldChanged(session, "bank", meta.bank) then self.bank = meta.bank end

        if fieldChanged(session, "deeds", meta.deedsEarned) then self.deeds = meta.deedsEarned end
        if fieldChanged(session, "atitle", meta.activeTitle) then self.atitle = meta.activeTitle end
        if fieldChanged(session, "renown", meta.renown) then self.renown = meta.renown end

        if fieldChanged(session, "prof", meta.professions) then self.prof = meta.professions end
        if fieldChanged(session, "cprof", meta.currentProfession) then self.cprof = meta.currentProfession end

        if fieldChanged(session, "mntOwn", meta.ownedMounts) then self.mntOwn = meta.ownedMounts end
        if fieldChanged(session, "mntRtd", meta.ridingTrained and true or nil) then self.mntRtd = meta.ridingTrained and true or nil end

        if fieldChanged(session, "hbl", meta.hotbarLayout) then self.hbl = meta.hotbarLayout end

        if fieldChanged(session, "mktU", meta.marketUncollected and true or nil) then self.mktU = meta.marketUncollected and true or nil end
        if fieldChanged(session, "mailU", meta.mailUnread) then self.mailU = meta.mailUnread end

        if fieldChanged(session, "market", meta.marketInfo) then self.market = meta.marketInfo end

        local gb = meta.guildId and { guildId = meta.guildId, guildBankOpen = meta.guildBankOpen or false } or nil
        if fieldChanged(session, "guildBank", gb) then self.guildBank = gb end
    end

    -- 地面/水面状态 (TS 基础字段, delta-guarded)
    if fieldChanged(session, "grd", e.onGround and true or nil) then self.grd = e.onGround and true or nil end
    if fieldChanged(session, "swm", e.swimming and true or nil) then self.swm = e.swimming and true or nil end

    return jh.safeEncode(self)
end

--- 填充 Entity LITE 记录表 (玩家/宠物; 写入传入的 dyn 表, 供双缓冲复用避免每 tick 分配)
local function fillEntityDyn(dyn, e)
    for k in pairs(dyn) do dyn[k] = nil end
    dyn.id = e.id
    dyn.x = jh.round2(e.pos.x)
    dyn.y = jh.round2(e.pos.y)
    dyn.z = jh.round2(e.pos.z)
    dyn.f = jh.round2(e.facing or 0)
    dyn.hp = math.floor(e.hp or 0)
    dyn.mhp = e.maxHp or 100

    if e.dead then dyn.dead = true end
    if e.ghost then dyn.gh = true end
    if e.lootable then dyn.loot = true end
    if e.hostile then dyn.h = true end
    if e.afk then dyn.ak = true end
    if e.resourceType then dyn.rtype = e.resourceType end
    if e.resource and e.resource > 0 then dyn.res = jh.round2(e.resource) end
    if e.maxResource then dyn.mres = e.maxResource end
    if e.castingAbility then
        dyn.cast = e.castingAbility.id or e.castingAbility
        dyn.castRem = jh.round2(e.castRemaining or 0)
        dyn.castTot = jh.round2(e.castTotal or 0)
    end
    if e.channeling then dyn.chan = true end
    if e.targetId then dyn.tgt = e.targetId end
    if e.aggroTargetId then dyn.aggro = e.aggroTargetId end
    if e.forcedTargetId then
        dyn.ft = e.forcedTargetId
        dyn.ftm = jh.round2(e.forcedTargetTimer or 0)
    end
    if e.tappedById then dyn.tap = e.tappedById end
    if e.ownerId then dyn.own = e.ownerId end
    if e.mountCastKey then dyn.mck = e.mountCastKey; dyn.mcr = jh.round2(e.mountCastRemaining or 0) end
    if e.weaponStowed then dyn.ws = true end
    if e.helmHidden then dyn.hh = true end
    if e.riftSliding then dyn.sld = true end
    if e.overheadEmoteId then
        dyn.emo = e.overheadEmoteId
        dyn.emoSeq = e.overheadEmoteSeq or 0
    end
    if e.petMode then dyn.pm = e.petMode end
    if e.petTauntTimer and e.petTauntTimer > 0 then dyn.pt = true end
    if e.petAutoTaunt then dyn.pa = true end
    if e.petAutoWaterJet then dyn.pw = true end

    -- buffs/debuffs (仅在存在光环时才分配/编码)
    if e.auras and next(e.auras) then
        local aur = wireAuras(e)
        if #aur > 0 then dyn.auras = aur end
    end
end

--- 填充 Mob/NPC LITE 记录表 (跳过玩家/宠物专属字段, 减少 mob 每 tick 建表开销)
local function fillMobDyn(dyn, e)
    for k in pairs(dyn) do dyn[k] = nil end
    dyn.id = e.id
    dyn.x = jh.round2(e.pos.x)
    dyn.y = jh.round2(e.pos.y)
    dyn.z = jh.round2(e.pos.z)
    dyn.f = jh.round2(e.facing or 0)
    dyn.hp = math.floor(e.hp or 0)
    dyn.mhp = e.maxHp or 100

    if e.dead then dyn.dead = true end
    if e.lootable then dyn.loot = true end
    if e.hostile then dyn.h = true end
    if e.resourceType then dyn.rtype = e.resourceType end
    if e.resource and e.resource > 0 then dyn.res = jh.round2(e.resource) end
    if e.maxResource then dyn.mres = e.maxResource end
    if e.castingAbility then
        dyn.cast = e.castingAbility.id or e.castingAbility
        dyn.castRem = jh.round2(e.castRemaining or 0)
        dyn.castTot = jh.round2(e.castTotal or 0)
    end
    if e.channeling then dyn.chan = true end
    if e.targetId then dyn.tgt = e.targetId end
    if e.aggroTargetId then dyn.aggro = e.aggroTargetId end
    if e.forcedTargetId then
        dyn.ft = e.forcedTargetId
        dyn.ftm = jh.round2(e.forcedTargetTimer or 0)
    end
    if e.tappedById then dyn.tap = e.tappedById end
    if e.ownerId then dyn.own = e.ownerId end
    if e.overheadEmoteId then
        dyn.emo = e.overheadEmoteId
        dyn.emoSeq = e.overheadEmoteSeq or 0
    end

    -- buffs/debuffs (仅在存在光环时才分配/编码)
    if e.auras and next(e.auras) then
        local aur = wireAuras(e)
        if #aur > 0 then dyn.auras = aur end
    end
end

--- 深度比较两个 LITE dyn 表 (字段级, 避免每 tick 对未变化实体做 JSON 编码)
local function liteEqual(a, b)
    if a == b then return true end
    if a == nil or b == nil then return false end
    local an = 0
    for k, v in pairs(a) do
        an = an + 1
        local bv = b[k]
        if type(v) == "table" then
            if type(bv) ~= "table" or not liteEqual(v, bv) then return false end
        elseif v ~= bv then
            return false
        end
    end
    local bn = 0
    for _ in pairs(b) do bn = bn + 1 end
    return an == bn
end

--- 构建 Entity FULL 记录 (基础 + 身份/外观冷字段; 冷字段客户端仅 full 记录读取)
local function buildEntityFull(e)
    local dyn = {
        id = e.id,
        k = e.kind or "mob",
        tid = e.templateId or "",
        nm = e.name or "",
        lv = e.level or 1,
        x = jh.round2(e.pos.x),
        y = jh.round2(e.pos.y),
        z = jh.round2(e.pos.z),
        f = jh.round2(e.facing or 0),
        hp = math.floor(e.hp or 0),
        mhp = e.maxHp or 100,
        dead = e.dead or false,
        gh = e.ghost or false,
        loot = e.lootable or false,
        h = e.hostile or false,
        tgt = e.targetId,
    }
    if e.skinCatalog then dyn.cat = e.skinCatalog end
    if e.skin then dyn.sk = e.skin end
    if e.mountKey then dyn.mnt = e.mountKey end
    if e.mainhandItemId then dyn.mh = e.mainhandItemId end
    if e.offhandItemId then dyn.oh = e.offhandItemId end
    if e.weaponSkinId then dyn.wsk = e.weaponSkinId end
    if e.holderTier then dyn.ht = e.holderTier end
    if e.holderBalance then dyn.hb = e.holderBalance end
    if e.discordTier then dyn.dt = e.discordTier end
    if e.discordName then dyn.dnm = e.discordName end
    if e.discordAvatar then dyn.dav = e.discordAvatar end
    if e.discordJoined then dyn.dj = true end
    if e.discordRole then dyn.dr = e.discordRole end
    if e.devTier then dyn.dvt = e.devTier end
    if e.devMergedPrs then dyn.dvc = e.devMergedPrs end
    if e.githubLogin then dyn.dgl = e.githubLogin end
    if e.streamerLinks and #e.streamerLinks > 0 then dyn.slk = e.streamerLinks end
    if e.guild then dyn.gd = e.guild end
    if e.title then dyn.title = e.title end
    if e.dungeonId then dyn.dgn = e.dungeonId end
    if e.riftTier then dyn.rt = e.riftTier end
    if e.objectItemId then dyn.obj = e.objectItemId end
    if e.scale ~= 1 then dyn.sc = e.scale end
    if e.color then dyn.c = e.color end
    return jh.safeEncode(dyn)
end

--- 为某个玩家构建快照
--- @param entities table 全局实体表
--- @param players table 全局玩家元数据
--- @param pid number 玩家实体 ID
--- @param session table Gate 会话 (含 seenEntities, lastDyn, lastSent)
function M.buildForPlayer(entities, players, pid, session, tick, simTime)
    local e = entities[pid]
    local meta = players[pid]
    if not e or not meta then return nil end

    if not session.lastStamp then session.lastStamp = {} end
    if not session.lastRefresh then session.lastRefresh = {} end
    if not session.lastSentTick then session.lastSentTick = {} end
    if not session.scratchDyn then session.scratchDyn = {} end

    local anchorPos = e.pos
    -- 复用 session 内的 scratch 表 (避免每 tick 分配/GC)
    local entsArr = session.entsArr
    if entsArr then for i = #entsArr, 1, -1 do entsArr[i] = nil end
    else entsArr = {}; session.entsArr = entsArr end
    local keepArr = session.keepArr
    if keepArr then for i = #keepArr, 1, -1 do keepArr[i] = nil end
    else keepArr = {}; session.keepArr = keepArr end

    -- 查询可视实体 (螺旋最近优先, 提前停止: 只需最近 maxVisible*2 个再按 leave 半径过滤)
    local maxVisible = config.MAX_VISIBLE_ENTITIES or 50
    local visible = grid.queryRadius(anchorPos.x, anchorPos.z, config.INTEREST_QUERY_RADIUS, entities, maxVisible * 2)

    -- 本次可见实体集合 (用于清理离场实体的 seen 记录)
    local seenThisTick = session.seenThisTick
    if seenThisTick then for k in pairs(seenThisTick) do seenThisTick[k] = nil end
    else seenThisTick = {}; session.seenThisTick = seenThisTick end

    -- AOI: visible 已按螺旋(中心优先)顺序返回, 直接截断最近 N 个, 无需排序/候选表
    local shown = 0
    for _, other in ipairs(visible) do
        if other.id ~= pid then
            local dx = other.pos.x - anchorPos.x
            local dz = other.pos.z - anchorPos.z
            local distSq = dx * dx + dz * dz

            local leaveSq = (other.kind == "player" or other.kind == "pet")
                and config.INTEREST_DROP_RADIUS_SQ or config.NPC_DROP_RADIUS_SQ
            if distSq <= leaveSq then
                seenThisTick[other.id] = true
                local seenBefore = session.seenEntities[other.id]
                local idHash = identityHash(other)

                if not seenBefore or seenBefore ~= idHash then
                    -- Full record (首次或身份变化)
                    session.seenEntities[other.id] = idHash
                    table.insert(entsArr, buildEntityFull(other))
                    session.lastDyn[other.id] = nil
                    session.lastStamp[other.id] = nil
                    session.lastRefresh[other.id] = tick
                    session.lastSentTick[other.id] = tick
                else
                    -- 距离分级更新频率: 全速(55yd 内/目标/攻击者), 半速(80yd), 更远 1/4 速
                    local isFullRate = distSq <= config.FULL_RATE_RADIUS_SQ
                        or (e.targetId == other.id)
                        or (other.aggroTargetId == e.id)
                    if not isFullRate then
                        local divisor = (distSq <= config.HALF_RATE_RADIUS_SQ)
                            and config.HALF_RATE_DIVISOR or config.QUARTER_RATE_DIVISOR
                        local lastSent = session.lastSentTick[other.id] or -divisor
                        if tick - lastSent < divisor then
                            table.insert(keepArr, other.id)
                            goto continue_entity
                        end
                    end

                    -- Lite record: _wireVer 脏标记 + 周期刷新(冷字段), 仅变化时才 JSON 编码
                    local ver = other._wireVer or 0
                    local lastVer = session.lastStamp[other.id]
                    local lastRefresh = session.lastRefresh[other.id] or -LITE_REFRESH_TICKS
                    if ver == lastVer and tick - lastRefresh < LITE_REFRESH_TICKS then
                        table.insert(keepArr, other.id)
                    else
                        -- 双缓冲: 复用 scratch 表填充, 变化时与 lastDyn 交换, 避免每 tick 分配
                        local dyn = session.scratchDyn[other.id]
                        if not dyn then dyn = {}; session.scratchDyn[other.id] = dyn end
                        if other.kind == "mob" or other.kind == "npc" then
                            fillMobDyn(dyn, other)
                        else
                            fillEntityDyn(dyn, other)
                        end
                        session.lastStamp[other.id] = ver
                        session.lastRefresh[other.id] = tick
                        local lastDyn = session.lastDyn[other.id]
                        if not liteEqual(dyn, lastDyn) then
                            session.lastDyn[other.id] = dyn
                            session.scratchDyn[other.id] = lastDyn
                            session.lastSentTick[other.id] = tick
                            table.insert(entsArr, jh.safeEncode(dyn))
                        else
                            table.insert(keepArr, other.id)
                        end
                    end
                end
                ::continue_entity::

                shown = shown + 1
                if shown >= maxVisible then break end
            end
        end
    end

    -- 清理已离场/被裁剪实体的 seen/delta 记录 (重入场一律发 FULL, 避免 lite 无 full 前导)
    for id in pairs(session.seenEntities) do
        if not seenThisTick[id] then
            session.seenEntities[id] = nil
            session.lastDyn[id] = nil
            session.lastStamp[id] = nil
            session.lastRefresh[id] = nil
        end
    end

    local selfJson = buildSelfJson(e, meta, session)
    local frame = jh.buildSnapFrame(
        tick or 0, simTime or 0,
        selfJson, entsArr, keepArr,
        config.STABLE_TIMER_WIRE_VERSION
    )
    grid.releaseRadiusResult(visible)
    return frame
end

--- 构建广播快照 (返回 {pid → frame} 映射) — 旧接口保留给兼容
function M.buildBroadcast(entities, players, tick, simTime)
    local frames = {}
    for pid, e in pairs(entities) do
        local meta = players[pid]
        if meta then
            local session = { seenEntities = {}, lastDyn = {}, lastSent = {} }
            local frame = M.buildForPlayer(entities, players, pid, session, tick, simTime)
            if frame then frames[pid] = frame end
        end
    end
    return frames
end

return M
