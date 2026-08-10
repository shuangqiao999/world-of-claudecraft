-- World of ClaudeCraft — Exclusive Auras (Aura Replacement)
-- 互斥光环: 同一来源的 buff 替换, 跨来源的组 buff 去重
-- 对应原项目 src/sim/combat/exclusive_aura.ts + src/sim/combat/aura_stacking.ts

local M = {}

-- 跨来源独立的组 buff (一个目标只能有一个)
-- 这些 buff 无论谁施放, 后到的替换先到的
local SOURCE_INDEPENDENT_GROUP_BUFF_IDS = {
    ["arcane_intellect"] = true,
    ["battle_shout"] = true,
    ["blessing_of_might"] = true,
    ["devotion_aura"] = true,
    ["mark_of_the_wild"] = true,
    ["power_word_fortitude"] = true,
    ["rallying_cry_dr"] = true,
    ["rallying_cry_hp"] = true,
    ["trueshot_aura_ap"] = true,
    ["sanguine_aura"] = true,
}

--- 检查是否跨来源替换组 buff
function M.isSourceIndependent(id)
    return SOURCE_INDEPENDENT_GROUP_BUFF_IDS[id] == true
end

--- 检查互斥冲突: 返回需要移除的现有光环索引
-- 如果现有光环相同 ID + 相同来源 → 替换
-- 如果现有光环相同 ID + 跨来源独立 → 替换 (不管来源)
function M.auraReplacementConflicts(existingAuras, newAura)
    local conflicts = {}
    local replaceAcrossSources = M.isSourceIndependent(newAura.id)

    for i = #existingAuras, 1, -1 do
        local existing = existingAuras[i]
        if existing.id == newAura.id then
            if replaceAcrossSources or existing.sourceId == newAura.sourceId then
                table.insert(conflicts, i)
            end
        end
    end

    return conflicts
end

--- 应用互斥检查: 在新光环应用前移除冲突光环
function M.applyExclusive(target, newAura)
    if not target.auras then return end

    local toRemove = {}
    for auraId, existing in pairs(target.auras) do
        if auraId == newAura.id then
            local replace = M.isSourceIndependent(newAura.id) or
                (existing.sourceId and existing.sourceId == newAura.sourceId)
            if replace then
                table.insert(toRemove, auraId)
            end
        end
    end

    for _, auraId in ipairs(toRemove) do
        target.auras[auraId] = nil
    end
end

--- 检查多个互斥形态: 只能有一个形态生效
-- Bear/Cat/Moonkin 互斥
local EXCLUSIVE_FORMS = { "form_bear", "form_cat", "form_moonkin", "form_travel" }

function M.resolveFormExclusivity(target, newAura)
    for _, formKind in ipairs(EXCLUSIVE_FORMS) do
        if newAura.kind == formKind then
            -- 移除所有其他形态
            for id, aura in pairs(target.auras or {}) do
                for _, fk in ipairs(EXCLUSIVE_FORMS) do
                    if aura.kind == fk and fk ~= formKind then
                        target.auras[id] = nil
                    end
                end
            end
        end
    end
end

return M
