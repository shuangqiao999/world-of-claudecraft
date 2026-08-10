-- World of ClaudeCraft — Effect Dispatch
-- 技能效果分发: 对齐 TS src/sim/combat/effect_dispatch.ts 效果类型
-- 支持 TS 类型: directDamage/aoeDamage/heal/aoeHeal/hot/dot/buffTarget/selfBuff/applyDebuff
-- 兼容旧类型: damage/heal/buff/debuff/aoe

local damage = require("world.combat.damage")
local heal = require("world.combat.heal")
local aura = require("world.combat.aura")
local simrng = require("world.simrng")
local config = require("config")

local M = {}

--- 执行技能效果
function M.execute(caster, target, ability, entities, simTime)
    if not ability or not ability.effects then return {} end
    local events = {}
    for _, effect in ipairs(ability.effects) do
        local effectEvents = M._applyEffect(caster, target, effect, entities, simTime)
        for _, ev in ipairs(effectEvents) do
            table.insert(events, ev)
        end
    end
    return events
end

--- directDamage 伤害掷骰 (TS: rng.range(min,max) + 评分系数)
local function rollDirectDamage(caster, effect, ability)
    local min = effect.min or effect.value or 1
    local max = effect.max or min
    local dmg = simrng.randfloat(min, max)
    -- 评分系数: spellPower/AP
    local coeff = effect.coeff or 0.5
    local scale = effect.scalePower and caster.spellPower or 0
    if effect.scaleAP then scale = caster.attackPower or 0 end
    dmg = dmg + scale * coeff
    return dmg
end

--- 应用单个效果
function M._applyEffect(caster, target, effect, entities, simTime)
    local events = {}
    local etype = effect.type
    local targets = M._resolveTargets(caster, target, effect, entities)

    for _, t in ipairs(targets) do
        if not t.dead or etype == "resurrect" then
            local ev = nil

            -- TS: directDamage (min/max + 暴击)
            if etype == "directDamage" then
                local isSpell = (effect.school or "physical") ~= "physical"
                local raw = rollDirectDamage(caster, effect, nil)
                local critChance = caster.critChance or 0.05
                local crit = simrng.random() < critChance
                local critMult = (isSpell and 1.5 or 2.0) + (isSpell and (caster.critDmgSpellBonus or 0) or (caster.critDmgPhysBonus or 0))
                if crit then raw = raw * critMult end
                -- 护甲/法术管道
                local final = isSpell
                    and damage.dealDamage(nil, caster, t, raw, crit, effect.school, effect.name, {})
                    or damage.dealDamage(nil, caster, t, raw, crit, "physical", effect.name, {})
                if final > 0 then
                    t.hp = math.max(0, t.hp - final)
                    ev = { type = "combat_damage", hp = final, crit = crit, pid = t.id, sid = caster.id, school = effect.school }
                end

            -- 兼容旧: damage (flat value)
            elseif etype == "damage" then
                local result
                if effect.school == "physical" then
                    result = damage.calcPhysical(caster, t)
                else
                    result = damage.calcSpell(caster, t, effect.value or 1, effect.coeff or 0.5)
                end
                if result.damage > 0 then
                    t.hp = math.max(0, t.hp - result.damage)
                    ev = { type = "combat_damage", hp = result.damage, crit = result.crit,
                           pid = t.id, sid = caster.id, school = effect.school,
                           blocked = result.blocked, dodged = result.dodged, missed = result.missed }
                end

            -- TS: aoeDamage / 兼容旧 aoe
            elseif etype == "aoeDamage" or etype == "aoe" then
                local raw = rollDirectDamage(caster, effect, nil)
                local crit = simrng.random() < (caster.critChance or 0.05)
                if crit then raw = raw * (1.5 + (caster.critDmgSpellBonus or 0)) end
                local final = damage.dealDamage(nil, caster, t, raw, crit, effect.school or "spell", effect.name, {})
                if final > 0 then
                    t.hp = math.max(0, t.hp - final)
                    ev = { type = "combat_damage", hp = final, crit = crit, pid = t.id, sid = caster.id, school = effect.school }
                end

            -- TS: heal
            elseif etype == "heal" then
                local baseHeal = (effect.min or effect.value or 1)
                if effect.max then
                    baseHeal = simrng.randfloat(effect.min or 1, effect.max)
                end
                local result = heal.applyHeal(caster, t, baseHeal, effect.name or "heal", true)
                if result.heal > 0 then
                    ev = { type = "combat_heal", hp = result.heal, crit = result.crit, pid = t.id, sid = caster.id,
                           absorbed = result.absorbed, overheal = result.overheal }
                end

            -- TS: aoeHeal
            elseif etype == "aoeHeal" then
                local baseHeal = (effect.min or effect.value or 1)
                if effect.max then baseHeal = simrng.randfloat(effect.min or 1, effect.max) end
                local result = heal.applyHeal(caster, t, baseHeal, effect.name or "aoeHeal", true)
                if result.heal > 0 then
                    ev = { type = "combat_heal", hp = result.heal, crit = result.crit, pid = t.id, sid = caster.id }
                end

            -- TS: dot (value = per-tick base, tickInterval)
            elseif etype == "dot" then
                local tickValue = (effect.value or effect.perTick or 5)
                if effect.total and effect.duration and effect.interval then
                    tickValue = math.max(1, math.round(effect.total / (effect.duration / effect.interval)))
                end
                local dot = aura.new(effect.auraId or tostring(effect.id or "dot"), effect.name or "dot",
                    effect.duration or 6, {
                    id = effect.auraId or ("dot_" .. (abilityIdOf(effect))),
                    kind = "dot",
                    tickInterval = effect.interval or effect.tickInterval or 2,
                    value = tickValue,
                    school = effect.school or "magic",
                    isDebuff = true,
                    auraType = effect.auraType or "magic",
                    sourceId = caster.id,
                })
                aura.applyAura(t, dot)

            -- TS: hot (value = per-tick)
            elseif etype == "hot" then
                local hot = aura.new(effect.auraId or tostring(effect.id or "hot"), effect.name or "hot",
                    effect.duration or 6, {
                    id = effect.auraId or ("hot_" .. (effect.id or "")),
                    kind = "hot",
                    tickInterval = effect.interval or effect.tickInterval or 2,
                    value = effect.value or 5,
                    sourceId = caster.id,
                })
                aura.applyAura(t, hot)

            -- TS: buffTarget / 兼容旧 buff (kind-based)
            elseif etype == "buffTarget" or etype == "buff" then
                local buff = aura.new(effect.auraId or effect.id or "buff", effect.name or "buff",
                    effect.duration or 30, {
                    id = effect.auraId or effect.id or ("buff_" .. (effect.kind or "")),
                    kind = effect.kind,
                    value = effect.value or 0,
                    duration = effect.duration or 30,
                    sourceId = caster.id,
                })
                aura.applyAura(t, buff)

            -- TS: selfBuff (含形态/姿态互斥)
            elseif etype == "selfBuff" then
                local isForm = effect.kind and effect.kind:find("^form")
                if isForm then
                    -- 形态互斥: 移除其他形态
                    local toRemove = {}
                    for id, a in pairs(t.auras or {}) do
                        if a.kind and a.kind:find("^form") and a.kind ~= effect.kind then
                            table.insert(toRemove, id)
                        end
                    end
                    for _, id in ipairs(toRemove) do t.auras[id] = nil end
                end
                local buff = aura.new(effect.auraId or effect.id or abilityIdOf(effect), effect.name or "buff",
                    effect.duration or -1, {
                    id = effect.auraId or effect.id or ("selfbuff_" .. (effect.kind or "")),
                    kind = effect.kind,
                    value = effect.value or 0,
                    duration = effect.duration or -1,
                    sourceId = caster.id,
                })
                aura.applyAura(t, buff)

            -- TS: applyDebuff / 兼容旧 debuff (CC DR)
            elseif etype == "applyDebuff" or etype == "debuff" then
                local dur = aura.checkDiminishingReturns(t.id, effect.mechanic or "snare",
                    effect.duration or 10, simTime)
                if dur > 0 then
                    local debuff = aura.new(effect.auraId or effect.id or "debuff", effect.name or "debuff",
                        dur, {
                        id = effect.auraId or effect.id or ("debuff_" .. (effect.kind or "")),
                        kind = effect.kind,
                        mechanic = effect.mechanic,
                        value = effect.value or 0,
                        isDebuff = true,
                        auraType = effect.auraType or "magic",
                        sourceId = caster.id,
                    })
                    aura.applyAura(t, debuff)
                end

            -- TS: taunt (嘲讽强制目标)
            elseif etype == "taunt" then
                if t.kind == "mob" then
                    require("world.mob.targeting").applyTaunt(t, caster.id, require("world.mob.threat"), entities)
                    ev = { type = "taunt", pid = t.id, target = caster.id }
                end
            end

            if ev then
                table.insert(events, ev)
            end
        end
    end

    return events
end

local function abilityIdOf(effect)
    return effect.auraId or effect.id or ""
end

--- 根据效果范围解析目标
function M._resolveTargets(caster, primary, effect, entities)
    local targets = {}

    if effect.target == "self" or (effect.type == "selfBuff") then
        table.insert(targets, caster)
    elseif effect.target == "enemy" or effect.target == "single" or effect.target == "friendly" then
        if primary then table.insert(targets, primary) end
    elseif effect.target == "aoe" then
        local center = (effect.center == "self") and caster or (primary or caster)
        local radius = effect.radius or 8
        local radiusSq = radius * radius

        for _, e in pairs(entities) do
            if e.kind == effect.targetKind or not effect.targetKind then
                local dx = e.pos.x - center.pos.x
                local dz = e.pos.z - center.pos.z
                if dx * dx + dz * dz <= radiusSq then
                    table.insert(targets, e)
                end
            end
        end

        if effect.maxTargets and #targets > effect.maxTargets then
            table.sort(targets, function(a, b)
                local da = (a.pos.x - center.pos.x)^2 + (a.pos.z - center.pos.z)^2
                local db = (b.pos.x - center.pos.x)^2 + (b.pos.z - center.pos.z)^2
                return da < db
            end)
            while #targets > effect.maxTargets do
                table.remove(targets)
            end
        end
    end

    return targets
end

return M
