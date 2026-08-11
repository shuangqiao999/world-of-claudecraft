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

--- delta 守卫: 字段值仅在变化时输出 (客户端语义: 缺失 = 保留旧值)
local function maybeDelta(session, key, value)
    if value == nil then return nil end
    local enc = value
    if type(value) ~= "string" then enc = jh.safeEncode(value) end
    local last = session.lastSent and session.lastSent[key]
    if enc == last then return nil end
    if not session.lastSent then session.lastSent = {} end
    session.lastSent[key] = enc
    return key, enc
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

    -- ===== delta-guarded 扩展 (仅在变化时发送) =====
    -- 基础对象编码为 {...}; 去掉尾部 '}' 以便把 delta 字段拼接进对象内部
    local base = jh.safeEncode(self)
    if type(base) == "string" and #base > 1 and base:sub(-1) == "}" then
        base = base:sub(1, -2)
    end
    local parts = { base }

    -- cds: 冷却时间表
    local cds = {}
    for abilityId, rem in pairs(e.cooldowns or {}) do
        if type(rem) == "number" and rem > 0 then cds[abilityId] = jh.round2(rem) end
    end
    if next(cds) then
        local k, v = maybeDelta(session, "cds", cds)
        if k then table.insert(parts, ',"' .. k .. '":' .. v) end
    end

    -- ncd: 采集节点冷却 (简化: 复用实体字段)
    local ncd = e.nodeCooldowns
    if ncd and next(ncd) then
        local k, v = maybeDelta(session, "ncd", ncd)
        if k then table.insert(parts, ',"' .. k .. '":' .. v) end
    end

    -- stats: 聚合次要属性
    local stats = e.stats and {
        str = e.stats.str or 0,
        agi = e.stats.agi or 0,
        sta = e.stats.sta or 0,
        int = e.stats.int or 0,
        spi = e.stats.spi or 0,
        armor = e.stats.armor or 0,
        pvpOffense = e.stats.pvpOffense or 0,
        pvpDefense = e.stats.pvpDefense or 0,
    } or nil
    local k, v = maybeDelta(session, "stats", stats)
    if k then table.insert(parts, ',"' .. k .. '":' .. v) end

    -- auras: 自身 buff/debuff
    local aur = wireAuras(e)
    if #aur > 0 then
        local k2, v2 = maybeDelta(session, "auras", aur)
        if k2 then table.insert(parts, ',"' .. k2 .. '":' .. v2) end
    end

    -- inv / bags / equip / einst (背包与装备)
    local inv = meta.inventory
    local k3, v3 = maybeDelta(session, "inv", inv)
    if k3 then table.insert(parts, ',"' .. k3 .. '":' .. v3) end
    local k5, v5 = maybeDelta(session, "equip", meta.equipment)
    if k5 then table.insert(parts, ',"' .. k5 .. '":' .. v5) end
    local k6, v6 = maybeDelta(session, "einst", meta.equipmentInstance)
    if k6 then table.insert(parts, ',"' .. k6 .. '":' .. v6) end

    -- qlog / qdone / milestones (任务)
    local k7, v7 = maybeDelta(session, "qlog", meta.qlog)
    if k7 then table.insert(parts, ',"' .. k7 .. '":' .. v7) end
    local k8, v8 = maybeDelta(session, "qdone", meta.qdone)
    if k8 then table.insert(parts, ',"' .. k8 .. '":' .. v8) end
    local k9, v9 = maybeDelta(session, "milestones", meta.unlockedMilestones)
    if k9 then table.insert(parts, ',"' .. k9 .. '":' .. v9) end

    -- tal / loadouts (天赋)
    local tal = meta.talents
    local k10, v10 = maybeDelta(session, "tal", tal)
    if k10 then table.insert(parts, ',"' .. k10 .. '":' .. v10) end

    -- 社交/组队
    local k11, v11 = maybeDelta(session, "party", meta.party)
    if k11 then table.insert(parts, ',"' .. k11 .. '":' .. v11) end
    local k12, v12 = maybeDelta(session, "duel", meta.duel)
    if k12 then table.insert(parts, ',"' .. k12 .. '":' .. v12) end

    -- 荣誉
    local k13, v13 = maybeDelta(session, "honor", meta.honor)
    if k13 then table.insert(parts, ',"' .. k13 .. '":' .. v13) end
    local k14, v14 = maybeDelta(session, "lhonor", meta.lifetimeHonor)
    if k14 then table.insert(parts, ',"' .. k14 .. '":' .. v14) end

    -- 银行
    local k15, v15 = maybeDelta(session, "bank", meta.bank)
    if k15 then table.insert(parts, ',"' .. k15 .. '":' .. v15) end

    -- 成就 / 头衔
    local k16, v16 = maybeDelta(session, "deeds", meta.deedsEarned)
    if k16 then table.insert(parts, ',"' .. k16 .. '":' .. v16) end
    local k17, v17 = maybeDelta(session, "atitle", meta.activeTitle)
    if k17 then table.insert(parts, ',"' .. k17 .. '":' .. v17) end
    local k18, v18 = maybeDelta(session, "renown", meta.renown)
    if k18 then table.insert(parts, ',"' .. k18 .. '":' .. v18) end

    -- 专业
    local k19, v19 = maybeDelta(session, "prof", meta.professions)
    if k19 then table.insert(parts, ',"' .. k19 .. '":' .. v19) end
    local k20, v20 = maybeDelta(session, "cprof", meta.currentProfession)
    if k20 then table.insert(parts, ',"' .. k20 .. '":' .. v20) end

    -- 坐骑
    local k21, v21 = maybeDelta(session, "mntOwn", meta.ownedMounts)
    if k21 then table.insert(parts, ',"' .. k21 .. '":' .. v21) end
    local k22, v22 = maybeDelta(session, "mntRtd", meta.ridingTrained and true or nil)
    if k22 then table.insert(parts, ',"' .. k22 .. '":' .. v22) end

    -- 热键布局
    local k23, v23 = maybeDelta(session, "hbl", meta.hotbarLayout)
    if k23 then table.insert(parts, ',"' .. k23 .. '":' .. v23) end

    -- 市场/邮件通知
    local k24, v24 = maybeDelta(session, "mktU", meta.marketUncollected and true or nil)
    if k24 then table.insert(parts, ',"' .. k24 .. '":' .. v24) end
    local k25, v25 = maybeDelta(session, "mailU", meta.mailUnread)
    if k25 then table.insert(parts, ',"' .. k25 .. '":' .. v25) end

    -- market: 搜索结果 (market_search 命令回填 meta.marketInfo)
    local k26, v26 = maybeDelta(session, "market", meta.marketInfo)
    if k26 then table.insert(parts, ',"' .. k26 .. '":' .. v26) end

    parts[#parts + 1] = "}"
    return table.concat(parts)
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
