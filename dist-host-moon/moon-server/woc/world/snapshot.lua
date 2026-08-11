-- World of ClaudeCraft — Snapshot Builder
-- 构建 send-to-client 的快照帧：{t:"snap", self, ents, keep}

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

--- 构建 self 字段 JSON (完整，不含 delta-guarded 扩展)
local function buildSelfJson(e, meta)
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
        dyn.cast = e.castingAbility
        dyn.castRem = jh.round2(e.castRemaining or 0)
        dyn.castTot = jh.round2(e.castTotal or 0)
    end
    if e.channeling then dyn.chan = true end
    if e.targetId then dyn.tgt = e.targetId end
    if e.mountKey then dyn.mnt = e.mountKey end
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
    if e.ownerId then dyn.own = e.ownerId end
    if e.objectItemId then dyn.obj = e.objectItemId end
    if e.overheadEmoteId then
        dyn.emo = e.overheadEmoteId
        dyn.emoSeq = e.overheadEmoteSeq or 0
    end
    if e.mainhandItemId then dyn.mh = e.mainhandItemId end
    if e.offhandItemId then dyn.oh = e.offhandItemId end

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

    for _, other in ipairs(visible) do
        if other.id ~= pid then
            local dx = other.pos.x - anchorPos.x
            local dz = other.pos.z - anchorPos.z
            local distSq = dx * dx + dz * dz

            local otherInterest = getInterestForKind(other.kind)
            if distSq <= otherInterest.leave then
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

    local selfJson = buildSelfJson(e, meta)
    local frame = jh.buildSnapFrame(
        tick or 0, simTime or 0,
        selfJson, entsArr, keepArr,
        config.STABLE_TIMER_WIRE_VERSION
    )
    return frame
end

--- 构建广播快照 (返回 {pid → frame} 映射)
function M.buildBroadcast(entities, players, tick, simTime)
    local frames = {}

    for pid, e in pairs(entities) do
        local meta = players[pid]
        if meta then
            local selfJson = buildSelfJson(e, meta)
            local entsFragments = {}

            -- 空间查询: 只包含附近的实体
            local visible = grid.queryRadius(e.pos.x, e.pos.z, config.INTEREST_QUERY_RADIUS, entities)
            for _, other in ipairs(visible) do
                if other.id ~= pid then
                    table.insert(entsFragments, buildEntityLite(other))
                end
            end

            frames[pid] = string.format(
                '{"t":"snap","tick":%d,"time":%.2f,"tw":%d,"self":%s,"ents":[%s]}',
                tick, jh.round2(simTime), config.STABLE_TIMER_WIRE_VERSION,
                selfJson, table.concat(entsFragments, ",")
            )
        end
    end

    return frames  -- { pid → frame }
end

return M
