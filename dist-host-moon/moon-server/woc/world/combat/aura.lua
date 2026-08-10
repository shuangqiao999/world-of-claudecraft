-- World of ClaudeCraft — Aura System
-- Buff/Debuff/CC 管理: apply/tick/expire/refresh/dispel/diminishing returns
-- DR 计时使用 sim 时钟 (不是 os.clock)，确保确定性
-- 对应原项目 src/sim/combat/auras.ts + src/sim/combat/cc.ts

local M = {}

-- 施加顺序戳 (LIFO 吸收盾 / 刷新判定用)
local auraOrderCounter = 0

--- Aura 构造函数
function M.new(id, name, duration, opts)
    opts = opts or {}
    return {
        id = id,
        name = name,
        kind = opts.kind,                           -- aura kind (buff_ap, form_bear, etc.)
        duration = duration,
        remaining = duration,
        tickInterval = opts.tickInterval or 0,
        tickRemaining = opts.tickInterval or 0,
        mechanic = opts.mechanic,                   -- "stun","root","fear","silence","snare","disorient"
        stacks = opts.stacks or 1,
        maxStacks = opts.maxStacks or 1,
        value = opts.value or 0,                    -- 光环数值 (用于 kind-based 识别)
        statMods = opts.statMods or {},
        healingMod = opts.healingMod or 0,
        damageMod = opts.damageMod or 0,
        isDebuff = opts.isDebuff or false,
        sourceId = opts.sourceId,
        auraType = opts.auraType or "magic",        -- "magic","curse","poison","disease","physical"
        order = 0,
    }
end

--- 施加光环到目标 (TS applyAura)
function M.applyAura(target, aura)
    if not target.auras then target.auras = {} end

    -- CC 免疫检查 (TS 6698-6717): 免疫控制的光环目标拒绝非自身来源的控制
    if target.ccImmune and aura.isDebuff and aura.mechanic and aura.sourceId ~= target.id then
        local ctrl = { stun = true, root = true, fear = true, disorient = true, silence = true, disarm = true, lockout = true }
        if ctrl[aura.mechanic] then return false end
    end
    if target.slowImmune and aura.mechanic == "snare" and aura.sourceId ~= target.id then
        return false
    end

    local existing = target.auras[aura.id]
    if existing then
        local sameName = existing.name == aura.name
        -- 刷新时重新戳 order (重新计为最新)
        auraOrderCounter = auraOrderCounter + 1
        existing.order = auraOrderCounter
        if existing.maxStacks > 1 and existing.stacks < existing.maxStacks then
            existing.stacks = existing.stacks + 1
            existing.remaining = math.max(existing.remaining, aura.duration)
            M._applyStatMods(target, existing, 1)
            aura.refreshed = sameName
        else
            existing.remaining = math.max(existing.remaining, aura.duration)
            aura.refreshed = sameName
        end
        -- 刷新/替换事件语义 (TS 6744-6754): 异名替换发 fade
        local events = {}
        if not sameName then
            table.insert(events, { type = "aura", targetId = target.id, name = existing.name, gained = false, sourceId = existing.sourceId })
        end
        table.insert(events, { type = "aura", targetId = target.id, name = aura.name, gained = true, sourceId = aura.sourceId, refresh = sameName })
        M._recalcIfPlayer(target)
        return true, events
    end

    auraOrderCounter = auraOrderCounter + 1
    aura.order = auraOrderCounter
    target.auras[aura.id] = aura
    M._applyStatMods(target, aura, aura.stacks)

    -- TS: 施加后立即重算玩家属性
    M._recalcIfPlayer(target)

    return true, { { type = "aura", targetId = target.id, name = aura.name, gained = true, sourceId = aura.sourceId } }
end

-- 玩家施加 stat 光环后立即重算属性 (TS applyAura 6790-6800)
function M._recalcIfPlayer(target)
    if target.kind == "player" and target.meta then
        local meta = target.meta
        local pcall_ok, perr = pcall(function()
            require("world.player_stats").recalcPlayerStats(target, meta.class or target.templateId, meta.equipment or {}, meta.talentMods, nil)
        end)
        if not pcall_ok then
            print(string.format("[Aura] recalcPlayerStats error: %s", tostring(perr)))
        end
    end
end

--- 移除光环
function M.removeAura(target, auraId)
    if not target.auras then return end
    local aura = target.auras[auraId]
    if aura then
        M._removeStatMods(target, aura)
        target.auras[auraId] = nil
    end
end

--- 驱散光环
function M.dispelAuras(target, auraType, maxCount)
    maxCount = maxCount or 1
    local removed = {}
    if not target.auras then return removed end

    for id, aura in pairs(target.auras) do
        if #removed >= maxCount then break end
        if aura.isDebuff and (auraType == "all" or aura.auraType == auraType) then
            table.insert(removed, aura.name)
            M._removeStatMods(target, aura)
            target.auras[id] = nil
        end
    end
    return removed
end

--- 更新所有光环 (tick, TS updateAuras 对应)
--- @param entities table
--- @param players table
--- @param dt number
--- @param simTime number
--- @return table 事件列表
function M.updateAll(entities, players, dt, simTime)
    local events = {}

    for id, e in pairs(entities) do
        if not e.auras then goto continue_loop end

        -- 死亡实体: 只维护 stealthed, 不 tick 光环
        if e.dead then
            e.stealthed = false
            for _, a in pairs(e.auras) do
                if a.kind == "stealth" then e.stealthed = true end
            end
            goto continue_loop
        end

        local statsDirty = false

        -- 遍历快照 (避免中途修改 auras 的问题)
        local snapshot = {}
        for auraId, a in pairs(e.auras) do
            table.insert(snapshot, { id = auraId, aura = a })
        end

        for _, entry in ipairs(snapshot) do
            local auraId = entry.id
            local aura = entry.aura
            if not e.auras[auraId] then goto continue_aura end  -- 已被副作用移除

            aura.remaining = (aura.remaining or 0) - dt

            -- Tick (DOT/HOT/polymorph)
            local tickInterval = aura.tickInterval
            if tickInterval and tickInterval > 0 then
                aura.tickTimer = (aura.tickTimer or tickInterval) - dt
                if aura.tickTimer <= 0.001 then
                    aura.tickTimer = aura.tickTimer + tickInterval

                    if aura.kind == "dot" then
                        -- DoT: 走 dealDamage 管道 (TS 256-317)
                        local tickDamage = aura.value or 0
                        -- bleed_vuln 放大 (物理 DoT)
                        if aura.school == "physical" then
                            local bleedAmp = 0
                            for _, targetAura in pairs(e.auras) do
                                if targetAura.kind == "bleed_vuln" then
                                    bleedAmp = bleedAmp + ((targetAura.value or 0) / 100)
                                end
                            end
                            if bleedAmp > 0 then
                                tickDamage = math.round(tickDamage * (1 + bleedAmp))
                            end
                        end
                        local source = entities[aura.sourceId]
                        local ev = M._dealDotDamage(source, e, tickDamage, aura.school)
                        if ev then table.insert(events, ev) end
                        -- leech (吸血)
                        if aura.leechPct and source and not source.dead then
                            local intended = math.round(tickDamage * aura.leechPct)
                            local healed = math.min(intended, source.maxHp - source.hp)
                            if healed > 0 then
                                source.hp = source.hp + healed
                                table.insert(events, { type = "heal2", sourceId = source.id, targetId = source.id, amount = healed, crit = false, ability = aura.name })
                            end
                        end
                        if e.dead then goto continue_loop end
                    elseif aura.kind == "hot" then
                        -- HoT: round(value * healingTakenMult)
                        local mult = M._healingTakenMult(e)
                        local intended = math.round((aura.value or 0) * mult)
                        local healed = math.min(intended, e.maxHp - e.hp)
                        if healed > 0 then
                            e.hp = e.hp + healed
                            table.insert(events, { type = "heal2", sourceId = aura.sourceId, targetId = e.id, amount = healed, crit = false, ability = aura.name, hot = true, abilityId = aura.id })
                        end
                    elseif aura.kind == "polymorph" then
                        -- Polymorph: 每 tick 治疗 maxHp * 10%
                        local heal = math.round(e.maxHp * 0.1)
                        e.hp = math.min(e.maxHp, e.hp + heal)
                    end
                end
            end

            -- 过期处理 (TS 344-379)
            if aura.remaining <= 0.001 then
                M._removeStatMods(e, aura)
                e.auras[auraId] = nil
                table.insert(events, { type = "aura", targetId = e.id, name = aura.name, gained = false })
                -- statsDirty: buff/form/debuff_ap/die_by_sword/enrage/bloodbath/berserker_stance
                if aura.kind and (aura.kind:find("^buff") or aura.kind:find("^form") or
                    aura.kind == "debuff_ap" or aura.kind == "die_by_sword" or
                    aura.kind == "enrage" or aura.kind == "bloodbath" or
                    aura.kind == "berserker_stance") then
                    statsDirty = true
                end
            end

            ::continue_aura::
        end

        -- statsDirty → 重算玩家属性 (TS 381-385)
        if statsDirty and e.kind == "player" then
            M._recalcIfPlayer(e)
        end

        -- stealthed 重算 (TS 386)
        e.stealthed = false
        for _, a in pairs(e.auras) do
            if a.kind == "stealth" then e.stealthed = true end
        end

        ::continue_loop::
    end

    return events
end

-- DoT 伤害通过 dealDamage 管道
function M._dealDotDamage(source, target, tickDamage, school)
    local damage = require("world.combat.damage")
    local amount = damage.dealDamage(nil, source, target, tickDamage, false, school or "magic", nil, {})
    if amount > 0 then
        target.hp = math.max(0, target.hp - amount)
        return { type = "aura_tick", pid = target.id, auraName = "dot", dmg = amount }
    end
    return nil
end

-- incoming-heal 倍率 (mortal_wound)
function M._healingTakenMult(target)
    local mult = 1
    for _, a in pairs(target.auras or {}) do
        if a.kind == "mortal_wound" then mult = mult * (1 - (a.value or 0)) end
    end
    return mult < 0 and 0 or mult
end

--- CC 递减检查 (Diminishing Returns) —— 使用 simTime 而非 os.clock
--- DR 分类: stun, fear, disorient, root, silence
local DRIFT_TRACKER = {}
local DR_CATEGORIES = {
    stun = { 0, 25, 50, 75 },      -- 第1次全效, 第2次50%, 第3次25%, 第4次免疫
    fear = { 0, 25, 50, 75 },
    disorient = { 0, 25, 50, 75 },
    root = { 0, 25, 50, 75 },
    silence = { 0, 25, 50, 75 },
}
local DR_RESET_SECONDS = 15

function M.checkDiminishingReturns(targetId, mechanic, duration, simTime)
    local cat = DR_CATEGORIES[mechanic]
    if not cat then return duration end

    if not DRIFT_TRACKER[targetId] then DRIFT_TRACKER[targetId] = {} end
    local tracker = DRIFT_TRACKER[targetId]

    if not tracker[mechanic] then
        tracker[mechanic] = { count = 0, resetTime = 0 }
    end

    local dr = tracker[mechanic]

    -- simTime 驱动的重置
    if simTime and dr.resetTime < simTime then
        dr.count = 0
    end

    dr.count = dr.count + 1
    if simTime then dr.resetTime = simTime + DR_RESET_SECONDS end

    if dr.count > #cat then return 0 end  -- 完全免疫

    local reduction = cat[dr.count] / 100
    return duration * (1 - reduction)
end

--- 清理 DR 追踪器 (玩家离开)
function M.cleanupDRTracker(targetId)
    DRIFT_TRACKER[targetId] = nil
end

--- 检查是否有控制类光环 (stun/root/silence)
function M.hasControlAura(e)
    if not e.auras then return false end
    for _, a in pairs(e.auras) do
        local m = a.mechanic
        if m == "stun" or m == "root" or m == "silence" or m == "fear" or m == "disorient" then
            return true
        end
    end
    return false
end

----------------------------------------
-- 内部辅助
----------------------------------------

function M._applyStatMods(target, aura, factor)
    for stat, value in pairs(aura.statMods or {}) do
        if target[stat] then
            local cur = target[stat] or 0
            target[stat] = cur + value * (factor or 1)
        end
    end
end

function M._removeStatMods(target, aura)
    for stat, value in pairs(aura.statMods or {}) do
        if target[stat] then
            local cur = target[stat] or 0
            target[stat] = cur - value * (aura.stacks or 1)
        end
    end
end

return M
