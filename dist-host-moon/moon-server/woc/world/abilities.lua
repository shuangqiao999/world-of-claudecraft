-- World of ClaudeCraft — Ability Definitions
-- 技能数据表，对应原项目 src/sim/content/classes.ts ABILITIES
-- 硬编码为主, 从 proto/abilities.json 合并 TS 结构 (directDamage 等)

local M = {}

local protoLoaded = false

--- 从 proto/abilities.json 合并 TS 结构能力 (directDamage/selfBuff/buffTarget 等)
--- 按 id 覆盖/补充硬编码表; TS effect 词汇由 effect_dispatch 处理
function M.loadFromProto()
    if protoLoaded then return end
    local ok, proto = pcall(function() return require("proto.load") end)
    if not ok then return end
    local abilities = proto.getAbilitiesForClass and nil
    local merged = 0
    for cls, clsAbilities in pairs(proto.abilities or {}) do
        for id, def in pairs(clsAbilities) do
            -- 合并 TS 能力 (保留 castTime/cooldown/range/school/effects)
            if type(def) == "table" and def.id then
                local entry = {}
                for k, v in pairs(def) do entry[k] = v end
                -- TS effects 结构透传给 effect_dispatch (directDamage 等)
                entry.effects = def.effects or {}
                if not M.ABILITIES[id] then merged = merged + 1 end
                M.ABILITIES[id] = entry
            end
        end
    end
    protoLoaded = true
    print(string.format("[Abilities] Proto merge: %d new abilities, total %d", merged, #M.ABILITIES))
end

M.ABILITIES = {
    -- ======== 通用 ========
    attack = {
        id = "attack", name = "Attack", class = "warrior",
        cost = 0, castTime = 0, cooldown = 0, range = 0,
        school = "physical", requiresTarget = true,
        effects = {},
    },

    -- ======== 战士 ========
    heroic_strike = {
        id = "heroic_strike", name = "Reaver Strike", class = "warrior",
        learnLevel = 1, resourceCost = 15, resourceType = "rage",
        castTime = 0, cooldown = 3, range = 0,
        school = "physical", requiresTarget = true,
        effects = {
            { type = "damage", school = "physical", value = 18, target = "enemy" },
        },
    },
    mortal_strike = {
        id = "mortal_strike", name = "Mortal Strike", class = "warrior",
        learnLevel = 4, resourceCost = 30, resourceType = "rage",
        castTime = 0, cooldown = 6, range = 0,
        school = "physical", requiresTarget = true,
        effects = {
            { type = "damage", school = "physical", value = 35, target = "enemy" },
        },
    },
    battle_shout = {
        id = "battle_shout", name = "Battle Shout", class = "warrior",
        learnLevel = 2, resourceCost = 10, resourceType = "rage",
        castTime = 0, cooldown = 5,
        effects = {
            { type = "buff", name = "Battle Shout", kind = "buff_ap_pct", duration = 120,
              value = 15, target = "self" },
        },
    },
    charge = {
        id = "charge", name = "Charge", class = "warrior",
        learnLevel = 3, resourceCost = 0, resourceType = "rage",
        castTime = 0, cooldown = 12, range = 25,
        school = "physical", requiresTarget = true,
        effects = {
            { type = "debuff", name = "Charge Stun", mechanic = "stun", duration = 1.5, target = "enemy" },
        },
    },
    thunder_clap = {
        id = "thunder_clap", name = "Thunder Clap", class = "warrior",
        learnLevel = 6, resourceCost = 20, resourceType = "rage",
        castTime = 0, cooldown = 10, school = "physical",
        effects = {
            { type = "damage", school = "physical", value = 12, target = "aoe",
              radius = 5, maxTargets = 5, targetKind = "mob" },
        },
    },

    -- ======== 法师 ========
    fireball = {
        id = "fireball", name = "Fireball", class = "mage",
        learnLevel = 1, resourceCost = 40, resourceType = "mana",
        castTime = 2.0, cooldown = 0, range = 35,
        school = "fire", requiresTarget = true,
        effects = {
            { type = "damage", school = "fire", value = 35, coeff = 0.8, target = "enemy" },
        },
    },
    frostbolt = {
        id = "frostbolt", name = "Frostbolt", class = "mage",
        learnLevel = 4, resourceCost = 30, resourceType = "mana",
        castTime = 1.5, cooldown = 0, range = 30,
        school = "frost", requiresTarget = true,
        effects = {
            { type = "damage", school = "frost", value = 20, coeff = 0.6, target = "enemy" },
            { type = "debuff", name = "Chilled", mechanic = "snare", duration = 4,
              statMods = {}, target = "single" },
        },
    },
    blizzard = {
        id = "blizzard", name = "Blizzard", class = "mage",
        learnLevel = 8, resourceCost = 60, resourceType = "mana",
        castTime = 0, cooldown = 8, isChannel = true, school = "frost",
        effects = {
            { type = "damage", school = "frost", value = 12, coeff = 0.3,
              target = "aoe", radius = 8, maxTargets = 5, targetKind = "mob" },
        },
    },
    frost_armor = {
        id = "frost_armor", name = "Frost Armor", class = "mage",
        learnLevel = 1, resourceCost = 10, resourceType = "mana",
        castTime = 0, cooldown = 5,
        effects = {
            { type = "buff", name = "Frost Armor", kind = "buff_armor", duration = 600,
              value = 50, target = "self" },
        },
    },
    arcane_intellect = {
        id = "arcane_intellect", name = "Arcane Intellect", class = "mage",
        learnLevel = 4, resourceCost = 30, resourceType = "mana",
        castTime = 0, cooldown = 5,
        effects = {
            { type = "buff", name = "Arcane Intellect", kind = "buff_int", duration = 600,
              value = 5, target = "self" },
        },
    },

    -- ======== 牧师 ========
    heal = {
        id = "heal", name = "Heal", class = "priest",
        learnLevel = 1, resourceCost = 50, resourceType = "mana",
        castTime = 2.5, cooldown = 0, range = 40, school = "holy",
        effects = {
            { type = "heal", value = 40, coeff = 0.7, target = "single" },
        },
    },
    flash_heal = {
        id = "flash_heal", name = "Flash Heal", class = "priest",
        learnLevel = 2, resourceCost = 40, resourceType = "mana",
        castTime = 1.0, cooldown = 0, range = 40, school = "holy",
        effects = {
            { type = "heal", value = 25, coeff = 0.5, target = "single" },
        },
    },
    renew = {
        id = "renew", name = "Renew", class = "priest",
        learnLevel = 3, resourceCost = 25, resourceType = "mana",
        castTime = 0, cooldown = 0, range = 40, school = "holy",
        effects = {
            { type = "hot", name = "Renew", duration = 12, tickInterval = 3, tickValue = 8, target = "single" },
        },
    },
    smite = {
        id = "smite", name = "Smite", class = "priest",
        learnLevel = 1, resourceCost = 35, resourceType = "mana",
        castTime = 2.0, cooldown = 0, range = 30, school = "holy", requiresTarget = true,
        effects = {
            { type = "damage", school = "holy", value = 16, coeff = 0.6, target = "enemy" },
        },
    },
    power_word_fortitude = {
        id = "power_word_fortitude", name = "Power Word: Fortitude", class = "priest",
        learnLevel = 2, resourceCost = 20, resourceType = "mana",
        castTime = 0, cooldown = 5,
        effects = {
            { type = "buff", name = "Fortitude", kind = "buff_sta", duration = 600,
              value = 5, target = "self" },
        },
    },

    -- ======== 盗贼 ========
    backstab = {
        id = "backstab", name = "Backstab", class = "rogue",
        learnLevel = 1, resourceCost = 35, resourceType = "energy",
        castTime = 0, cooldown = 0, range = 0,
        school = "physical", requiresTarget = true,
        effects = {
            { type = "damage", school = "physical", value = 30, target = "enemy" },
        },
    },
    eviscerate = {
        id = "eviscerate", name = "Eviscerate", class = "rogue",
        learnLevel = 2, resourceCost = 25, resourceType = "energy",
        castTime = 0, cooldown = 0, range = 0,
        school = "physical", requiresTarget = true,
        effects = {
            { type = "damage", school = "physical", value = 15, coeff = 0.3, target = "enemy" },
        },
    },

    -- ======== 圣骑士 ========
    holy_light = {
        id = "holy_light", name = "Holy Light", class = "paladin",
        learnLevel = 1, resourceCost = 35, resourceType = "mana",
        castTime = 2.5, cooldown = 0, range = 40, school = "holy",
        effects = {
            { type = "heal", value = 30, coeff = 0.8, target = "single" },
        },
    },
    judgement = {
        id = "judgement", name = "Judgement", class = "paladin",
        learnLevel = 2, resourceCost = 15, resourceType = "mana",
        castTime = 0, cooldown = 8, range = 10, school = "holy", requiresTarget = true,
        effects = {
            { type = "damage", school = "holy", value = 18, coeff = 0.4, target = "enemy" },
        },
    },
    devotion_aura = {
        id = "devotion_aura", name = "Devotion Aura", class = "paladin",
        learnLevel = 3, resourceCost = 0, resourceType = "mana",
        castTime = 0, cooldown = 2,
        effects = {
            { type = "buff", name = "Devotion Aura", kind = "buff_armor_pct", duration = -1,
              value = 10, target = "self" },
        },
    },

    -- ======== 猎人 ========
    arcane_shot = {
        id = "arcane_shot", name = "Arcane Shot", class = "hunter",
        learnLevel = 1, resourceCost = 15, resourceType = "mana",
        castTime = 0, cooldown = 6, range = 35, school = "arcane", requiresTarget = true,
        effects = {
            { type = "damage", school = "arcane", value = 15, target = "enemy" },
        },
    },
    serpent_sting = {
        id = "serpent_sting", name = "Serpent Sting", class = "hunter",
        learnLevel = 2, resourceCost = 20, resourceType = "mana",
        castTime = 0, cooldown = 6, range = 35,
        effects = {
            { type = "dot", name = "Serpent Sting", duration = 12, tickInterval = 3, tickValue = 5,
              auraType = "poison", target = "single" },
        },
    },

    -- ======== 萨满 ========
    lightning_bolt = {
        id = "lightning_bolt", name = "Lightning Bolt", class = "shaman",
        learnLevel = 1, resourceCost = 20, resourceType = "mana",
        castTime = 2.5, cooldown = 0, range = 30, school = "nature", requiresTarget = true,
        effects = {
            { type = "damage", school = "nature", value = 18, coeff = 0.7, target = "enemy" },
        },
    },
    healing_wave = {
        id = "healing_wave", name = "Healing Wave", class = "shaman",
        learnLevel = 2, resourceCost = 30, resourceType = "mana",
        castTime = 3.0, cooldown = 0, range = 40, school = "nature",
        effects = {
            { type = "heal", value = 28, coeff = 0.8, target = "single" },
        },
    },

    -- ======== 术士 ========
    shadow_bolt = {
        id = "shadow_bolt", name = "Shadow Bolt", class = "warlock",
        learnLevel = 1, resourceCost = 15, resourceType = "mana",
        castTime = 2.5, cooldown = 0, range = 30, school = "shadow", requiresTarget = true,
        effects = {
            { type = "damage", school = "shadow", value = 20, coeff = 0.8, target = "enemy" },
        },
    },
    corruption = {
        id = "corruption", name = "Corruption", class = "warlock",
        learnLevel = 3, resourceCost = 20, resourceType = "mana",
        castTime = 0, cooldown = 6, range = 30,
        effects = {
            { type = "dot", name = "Corruption", duration = 15, tickInterval = 3, tickValue = 6,
              auraType = "magic", target = "single" },
        },
    },

    -- ======== 德鲁伊 ========
    wrath = {
        id = "wrath", name = "Wrath", class = "druid",
        learnLevel = 1, resourceCost = 15, resourceType = "mana",
        castTime = 2.0, cooldown = 0, range = 30, school = "nature", requiresTarget = true,
        effects = {
            { type = "damage", school = "nature", value = 16, coeff = 0.5, target = "enemy" },
        },
    },
    healing_touch = {
        id = "healing_touch", name = "Healing Touch", class = "druid",
        learnLevel = 1, resourceCost = 40, resourceType = "mana",
        castTime = 3.5, cooldown = 0, range = 40, school = "nature",
        effects = {
            { type = "heal", value = 35, coeff = 1.0, target = "single" },
        },
    },
    mark_of_the_wild = {
        id = "mark_of_the_wild", name = "Mark of the Wild", class = "druid",
        learnLevel = 2, resourceCost = 20, resourceType = "mana",
        castTime = 0, cooldown = 5,
        effects = {
            { type = "buff", name = "MotW", kind = "buff_allstats", duration = 600,
              value = 3, target = "self" },
        },
    },
}

return M
