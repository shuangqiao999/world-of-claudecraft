-- World of ClaudeCraft — Form-Specific Combat
-- 德鲁伊形态: 熊/猫/旅行形态改变武器速度、禁用魔杖、形态专属技能条
-- 对应原项目 src/sim/combat/form_swing.ts

local M = {}

-- 盗贼基础攻速 (用于猫形态)
local ROGUE_BASE_SWING_SPEED = 1.8

-- 无魔杖形态 (熊/猫/旅行)
local WANDLESS_FORMS = { ["form_bear"] = true, ["form_cat"] = true, ["form_travel"] = true }

--- 获取形态下的基础攻速
--- Bear/Cat 使用爪子(固定 1.8), Caster 形态使用装备武器攻速
function M.baseSwingSpeed(entity)
    if not entity.auras then return entity.weapon and entity.weapon.speed or 2.6 end
    for _, a in pairs(entity.auras) do
        if a.kind == "form_cat" then return ROGUE_BASE_SWING_SPEED end
    end
    return entity.weapon and entity.weapon.speed or 2.6
end

--- 检查形态是否允许使用魔杖
function M.wandAllowedInForm(entity)
    if not entity.auras then return true end
    for _, a in pairs(entity.auras) do
        if WANDLESS_FORMS[a.kind] then return false end
    end
    return true
end

--- 获取当前可用的远程攻击模式 (wand/autoShot/无)
function M.rangedAutoProfile(entity, cls)
    -- 猎人始终可用 Auto Shot
    if cls == "hunter" then return { type = "auto_shot", maxRange = 35, minRange = 8, speed = 2.3 } end

    -- 施法者需要魔杖且形态允许
    if not M.wandAllowedInForm(entity) then return nil end

    -- 各职业魔杖
    local wandProfiles = {
        mage = { type = "wand", maxRange = 30, minRange = 0, speed = 1.8, school = "arcane" },
        priest = { type = "wand", maxRange = 30, minRange = 0, speed = 1.8, school = "holy" },
        warlock = { type = "wand", maxRange = 30, minRange = 0, speed = 1.8, school = "shadow" },
        druid = { type = "wand", maxRange = 30, minRange = 0, speed = 1.8, school = "nature" },
    }
    return wandProfiles[cls]
end

--- 检查是否有形态光环
function M.isInForm(entity, formKind)
    if not entity.auras then return false end
    for _, a in pairs(entity.auras) do
        if a.kind == formKind then return true end
    end
    return false
end

--- 获取当前形态 (返回 formKinds 列表)
function M.getActiveForms(entity)
    local forms = {}
    if not entity.auras then return forms end
    for _, a in pairs(entity.auras) do
        if a.kind == "form_bear" then forms.bear = true
        elseif a.kind == "form_cat" then forms.cat = true
        elseif a.kind == "form_moonkin" then forms.moonkin = true
        elseif a.kind == "form_travel" then forms.travel = true
        elseif a.kind == "form_shadow" then forms.shadow = true
        elseif a.kind == "form_metamorph" then forms.metamorph = true
        end
    end
    return forms
end

--- 形态专属攻击加成 (熊=200%ap, 猫=150%ap)
function M.formAutoAttackBonus(entity)
    if not entity.auras then return 1.0 end
    for _, a in pairs(entity.auras) do
        if a.kind == "form_bear" then return 2.0 end
        if a.kind == "form_cat" then return 1.5 end
    end
    return 1.0
end

return M
