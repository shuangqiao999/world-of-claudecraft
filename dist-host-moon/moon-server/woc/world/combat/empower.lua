-- World of ClaudeCraft — Empower Next / Thorns Charge
-- empower_next: 下一个技能免费或强化, 消耗时移除
-- thorns_charge: 荆棘充能, 每层反弹伤害, 消耗时移除一层
-- 对应原项目 src/sim/combat/empower_next.ts + src/sim/combat/thorns_charge.ts

local M = {}

--- 消耗 empower_next 光环 (下一个技能免费)
-- @return boolean 是否有免费施法可用
function M.consumeEmpowerNext(e, abilityId)
    if not e.auras then return false end
    for id, aura in pairs(e.auras) do
        if aura.kind == "empower_next" then
            e.auras[id] = nil
            return true
        end
    end
    return false
end

--- 检查是否有 empower_next 光环
function M.hasEmpowerNext(e)
    if not e.auras then return false end
    for _, aura in pairs(e.auras) do
        if aura.kind == "empower_next" then return true end
    end
    return false
end

--- 消耗荆棘充能 (反弹伤害时)
-- @return number 荆棘反弹伤害值
function M.consumeThornsCharge(target)
    if not target.auras then return 0 end
    for id, aura in pairs(target.auras) do
        if aura.kind == "thorns_charge" then
            local dmg = aura.value or 0
            aura.stacks = (aura.stacks or 1) - 1
            if aura.stacks <= 0 then
                target.auras[id] = nil
            end
            return dmg
        end
    end
    return 0
end

--- 检查是否有荆棘充能
function M.hasThornsCharge(e)
    if not e.auras then return false end
    for _, aura in pairs(e.auras) do
        if aura.kind == "thorns_charge" then return true end
    end
    return false
end

--- 施加减速抗性 (不能同时被多个控制影响)
function M.isUnbreakableControlAura(aura)
    local unbreakable = { stasis = true }
    return unbreakable[aura.kind] == true
end

return M
