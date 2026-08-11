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

local M = {}

-- 兴趣半径映射
local function getInterestForKind(kind)
    if kind == "player" or kind == "pet" then
        return { enter = config.INTEREST_RADIUS, leave = config.INTEREST_DROP_RADIUS_SQ }
    else
        return { enter = config.NPC_INTEREST_RADIUS, leave = config.NPC_DROP_RADIUS_SQ }
    end
end

--- 计算身份哈希 (检测实体身份变化)
local function identityHash(e)
    return (e.kind or "?") .. "|" .. (e.templateId or "") .. "|" .. (e.name or "") .. "|" .. tostring(e.level or 1)
end

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

    if fieldChanged(session, "inv", meta.inventory) then self.inv = meta.inventory end
    local bbk = require("world.vendor").buybackView(meta)
    if #bbk > 0 and fieldChanged(session, "buyback", bbk) then self.buyback = bbk end
    if fieldChanged(session, "equip", meta.equipment) then self.equip = meta.equipment end
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

    return jh.safeEncode(self)
end

--- 构建 Entity LITE 记录 (动态字段)
local function buildEntityLite(e)
    local dyn = {
        id = e.id,
        x = jh.round2(e.pos.x),
        y = jh.round2(e.pos.y),
        z = jh.round2(e.pos.z),
        f = jh.round2(e.facing or 0),
        hp = math.floor(e.hp or 0),
        mhp = e.maxHp or 100,
    }

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
    if e.mountKey then dyn.mnt = e.mountKey end
    if e.mountCastKey then dyn.mck = e.mountCastKey; dyn.mcr = jh.round2(e.mountCastRemaining or 0) end
    if e.weaponStowed then dyn.ws = true end
    if e.helmHidden then dyn.hh = true end
    if e.riftSliding then dyn.sld = true end
    if e.riftTier then dyn.rt = e.riftTier end
    if e.skin then dyn.sk = e.skin end
    if e.scale ~= 1 then dyn.sc = e.scale end
    if e.skinCatalog then dyn.cat = e.skinCatalog end
    if e.guild then dyn.gd = e.guild end
    if e.title then dyn.title = e.title end
    if e.dungeonId then dyn.dgn = e.dungeonId end
    if e.objectItemId then dyn.obj = e.objectItemId end
    if e.overheadEmoteId then
        dyn.emo = e.overheadEmoteId
        dyn.emoSeq = e.overheadEmoteSeq or 0
    end
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
    if e.color then dyn.c = e.color end
    if e.petMode then dyn.pm = e.petMode end
    if e.petTauntTimer and e.petTauntTimer > 0 then dyn.pt = true end
    if e.petAutoTaunt then dyn.pa = true end
    if e.petAutoWaterJet then dyn.pw = true end

    -- buffs/debuffs
    local aur = wireAuras(e)
    if #aur > 0 then dyn.auras = aur end

    return jh.safeEncode(dyn)
end

--- 构建 Entity FULL 记录 (LITE + 身份字段)
local function buildEntityFull(e)
    return jh.safeEncode({
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
    })
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

    local anchorPos = e.pos
    local entsArr = {}
    local keepArr = {}

    -- 查询可视实体
    local visible = grid.queryRadius(anchorPos.x, anchorPos.z, config.INTEREST_QUERY_RADIUS, entities)

    -- 本次可见实体集合 (用于清理离场实体的 seen 记录)
    local seenThisTick = {}

    for _, other in ipairs(visible) do
        if other.id ~= pid then
            local dx = other.pos.x - anchorPos.x
            local dz = other.pos.z - anchorPos.z
            local distSq = dx * dx + dz * dz

            local otherInterest = getInterestForKind(other.kind)
            if distSq <= otherInterest.leave then
                seenThisTick[other.id] = true
                local seenBefore = session.seenEntities[other.id]
                local idHash = identityHash(other)

                if not seenBefore or seenBefore ~= idHash then
                    -- Full record (首次或身份变化)
                    session.seenEntities[other.id] = idHash
                    table.insert(entsArr, buildEntityFull(other))
                    session.lastDyn[other.id] = nil
                else
                    -- Lite record (delta: 只有移动/状态变化才发送)
                    local newDyn = buildEntityLite(other)
                    local oldDyn = session.lastDyn[other.id]

                    if newDyn ~= oldDyn then
                        session.lastDyn[other.id] = newDyn
                        table.insert(entsArr, newDyn)
                    else
                        table.insert(keepArr, tostring(other.id))
                    end
                end
            end
        end
    end

    -- 清理已离场实体的 seen/delta 记录 (避免重入场只发 lite 而无 full)
    for id in pairs(session.seenEntities) do
        if not seenThisTick[id] and not entities[id] then
            session.seenEntities[id] = nil
            session.lastDyn[id] = nil
        end
    end

    local selfJson = buildSelfJson(e, meta, session)
    local frame = jh.buildSnapFrame(
        tick or 0, simTime or 0,
        selfJson, entsArr, keepArr,
        config.STABLE_TIMER_WIRE_VERSION
    )
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
