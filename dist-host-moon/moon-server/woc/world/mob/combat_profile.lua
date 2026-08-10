-- World of ClaudeCraft — Mob Combat Profile
-- Mob 技能配置表、AI 技能使用逻辑 (确定性 RNG)
-- 对应原项目 src/sim/mob/combat_profile.ts

local simrng = require("world.simrng")
local M = {}

-- 对应 src/sim/mob/yells.ts: YELL_RANGE = 100
local YELL_RANGE = 100

--- 广播 mob 喊话 (TS emitMobYell)
function M.emitMobYell(mob, text, entities)
    local events = {}
    local rangeSq = YELL_RANGE * YELL_RANGE
    for _, e in pairs(entities) do
        if e.kind == "player" and not e.dead then
            local dx = e.pos.x - mob.pos.x
            local dz = e.pos.z - mob.pos.z
            if dx * dx + dz * dz <= rangeSq then
                table.insert(events, {
                    type = "mob_yell",
                    pid = e.id,
                    mobId = mob.id,
                    text = text,
                    color = "#ff9933",
                })
            end
        end
    end
    return events
end

local PROFILES = {
    wolf = {
        abilities = {
            { id = "bite", name = "Bite", damage = 15, cooldown = 4, castTime = 0,
              effects = {{ type = "damage", school = "physical", value = 15, target = "enemy" }} },
        },
        autoAttackDmg = 5,
        baseHp = 80,
        baseAp = 15,
    },
    bear = {
        abilities = {
            { id = "maul", name = "Maul", damage = 25, cooldown = 6, castTime = 0,
              effects = {{ type = "damage", school = "physical", value = 25, target = "enemy" }} },
            { id = "swipe", name = "Swipe", damage = 18, cooldown = 8, castTime = 0,
              effects = {{ type = "damage", school = "physical", value = 18, target = "aoe", radius = 5, maxTargets = 3, targetKind = "player" }} },
        },
        autoAttackDmg = 8,
        baseHp = 200,
        baseAp = 25,
    },
    spider = {
        abilities = {
            { id = "poison_bite", name = "Poison Bite", damage = 10, cooldown = 3, castTime = 0,
              effects = {
                  { type = "damage", school = "physical", value = 10, target = "enemy" },
                  { type = "dot", name = "Poison", duration = 6, tickInterval = 2, tickValue = 4,
                    auraType = "poison", target = "single" },
              } },
            { id = "web", name = "Web", damage = 0, cooldown = 10, castTime = 0,
              effects = {{ type = "debuff", name = "Webbed", mechanic = "root", duration = 3,
                statMods = {}, auraType = "physical", target = "single" }} },
        },
        autoAttackDmg = 4,
        baseHp = 60,
        baseAp = 10,
    },
    skeleton_warrior = {
        abilities = {
            { id = "cleave", name = "Cleave", damage = 20, cooldown = 5, castTime = 0,
              effects = {{ type = "damage", school = "physical", value = 20, target = "aoe", radius = 4, maxTargets = 2, targetKind = "player" }} },
        },
        autoAttackDmg = 7,
        baseHp = 150,
        baseAp = 20,
    },
    shadow_mage = {
        isCaster = true,
        preferredRange = 25,
        abilities = {
            { id = "shadow_bolt_cast", name = "Shadow Bolt", damage = 20, cooldown = 3, castTime = 1.5, range = 25,
              effects = {{ type = "damage", school = "shadow", value = 20, coeff = 0.5, target = "enemy" }} },
            { id = "shadow_word", name = "Shadow Word", damage = 10, cooldown = 6, castTime = 0, range = 25,
              effects = {{ type = "dot", name = "Shadow Word", duration = 6, tickInterval = 2, tickValue = 4, auraType = "shadow", target = "single" }} },
        },
        autoAttackDmg = 4,
        baseHp = 100,
        baseAp = 12,
    },
    necromancer = {
        isCaster = true,
        preferredRange = 25,
        abilities = {
            { id = "shadow_bolt_cast", name = "Shadow Bolt", damage = 22, cooldown = 3, castTime = 1.5, range = 25,
              effects = {{ type = "damage", school = "shadow", value = 22, coeff = 0.5, target = "enemy" }} },
            { id = "curse_of_weakness", name = "Curse of Weakness", damage = 0, cooldown = 10, castTime = 0, range = 25,
              effects = {{ type = "debuff", name = "Weakness", mechanic = "snare", duration = 8, statMods = {}, target = "single" }} },
        },
        autoAttackDmg = 4,
        baseHp = 140,
        baseAp = 14,
    },
    fire_elemental = {
        isCaster = true,
        preferredRange = 20,
        abilities = {
            { id = "fireball_cast", name = "Fireball", damage = 25, cooldown = 3, castTime = 1.5, range = 20,
              effects = {{ type = "damage", school = "fire", value = 25, coeff = 0.5, target = "enemy" }} },
            { id = "fire_nova", name = "Fire Nova", damage = 15, cooldown = 10, castTime = 0, range = 20,
              effects = {{ type = "damage", school = "fire", value = 15, target = "aoe", radius = 8, maxTargets = 5, targetKind = "player" }} },
        },
        autoAttackDmg = 6,
        baseHp = 250,
        baseAp = 28,
    },
    boss_wolf = {
        abilities = {
            { id = "howl", name = "Howl", damage = 0, cooldown = 15, castTime = 1.0,
              effects = {{ type = "buff", name = "Bloodlust", kind = "buff_ap", duration = 10,
                statMods = { attackPower = 30, critChance = 0.10 }, value = 30, target = "self" }} },
            { id = "ravage", name = "Ravage", damage = 40, cooldown = 8, castTime = 0,
              effects = {{ type = "damage", school = "physical", value = 40, target = "enemy" }} },
        },
        autoAttackDmg = 15,
        baseHp = 800,
        baseAp = 50,
        isBoss = true,
    },
    default = {
        abilities = {},
        autoAttackDmg = 3,
        baseHp = 50,
        baseAp = 5,
    },
}

function M.getProfile(templateId)
    return PROFILES[templateId] or PROFILES["default"]
end

function M.scaleProfile(profile, level)
    local p = {}
    for k, v in pairs(profile) do
        if type(v) == "table" then
            p[k] = M._deepCopy(v)
        else
            p[k] = v
        end
    end

    p.level = level
    if not p.isBoss then
        p.baseHp = p.baseHp + (level - 1) * 15
        p.baseAp = p.baseAp + (level - 1) * 3
    else
        p.baseHp = p.baseHp + (level - 1) * 80
        p.baseAp = p.baseAp + (level - 1) * 10
    end

    if p.abilities then
        for _, ab in ipairs(p.abilities) do
            if ab.damage then ab.damage = ab.damage + (level - 1) * 2 end
            if ab.effects then
                for _, ef in ipairs(ab.effects) do
                    if ef.value then ef.value = ef.value + (level - 1) * 2 end
                    if ef.tickValue then ef.tickValue = ef.tickValue + (level - 1) * 1 end
                end
            end
        end
    end

    return p
end

function M._deepCopy(t)
    local copy = {}
    for k, v in pairs(t) do
        if type(v) == "table" then
            copy[k] = M._deepCopy(v)
        else
            copy[k] = v
        end
    end
    return copy
end

--- 选择下一个技能 (确定性 RNG + 距离检查)
function M.selectAbility(mob, profile, target)
    if not profile.abilities or #profile.abilities == 0 then return nil end
    if not target then return nil end

    -- 距离检查 (Caster 技能有 range)
    local dx = mob.pos.x - target.pos.x
    local dz = mob.pos.z - target.pos.z
    local distSq = dx * dx + dz * dz

    local available = {}
    for _, ab in ipairs(profile.abilities) do
        local valid = true
        if mob.cooldowns then
            local cd = mob.cooldowns[ab.id]
            if cd and cd > 0 then valid = false end
        end
        if valid and ab.range then
            local rangeSq = ab.range * ab.range
            if distSq > rangeSq then valid = false end
        end
        if valid then table.insert(available, ab) end
    end

    if #available == 0 then return nil end

    return available[simrng.randint(1, #available)]
end

return M
