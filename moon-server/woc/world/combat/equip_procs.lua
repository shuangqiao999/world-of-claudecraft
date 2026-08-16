-- World of ClaudeCraft — Legendary Weapon Procs
-- 对应原项目 src/sim/combat/equip_procs.ts
-- 传奇武器 on-hit/on-crit 词缀级联

local simrng = require("world.simrng")
local M = {}

-- 武器 proc 定义: { id, trigger = "on_hit"|"on_crit", chance, effect }
local WEAPON_PROCS = {
    -- 传奇武器示例 (无 content 时为空集合)
}

--- 注册武器 proc (装备加载时)
function M.registerWeaponProcs(weaponId, procs)
    if not procs or #procs == 0 then return end
    if not WEAPON_PROCS[weaponId] then WEAPON_PROCS[weaponId] = {} end
    for _, p in ipairs(procs) do
        table.insert(WEAPON_PROCS[weaponId], p)
    end
end

--- 获取武器 proc 列表
function M.getWeaponProcs(weaponId)
    return WEAPON_PROCS[weaponId] or {}
end

--- 触发检查 (on-hit / on-crit)
function M.applyWeaponProcs(source, target, trigger, abilityId, entities, simTime)
    local events = {}
    local weaponId = source.mainhandItemId
    if not weaponId then return events end
    local procs = M.getWeaponProcs(weaponId)
    if #procs == 0 then return events end

    for _, proc in ipairs(procs) do
        if proc.trigger == trigger then
            if not simrng.chance(proc.chance or 0.1) then goto continue_proc end
            -- ICD
            if proc.icd and simTime < (source._procReadyAt and source._procReadyAt[proc.id] or 0) then
                goto continue_proc
            end
            if not source._procReadyAt then source._procReadyAt = {} end
            source._procReadyAt[proc.id] = simTime + (proc.icd or 0)

            -- 效果: 伤害 / 治疗 / 光环
            if proc.damage then
                local dmg = math.round(proc.damage + (source.attackPower or 0) * (proc.apScale or 0))
                if target and not target.dead then
                    target.hp = math.max(0, target.hp - dmg)
                    table.insert(events, { type = "damage", sourceId = source.id, targetId = target.id,
                        amount = dmg, crit = false, school = "physical",
                        ability = proc.name or proc.id, kind = "hit" })
                end
            elseif proc.heal then
                if source.hp < source.maxHp then
                    local heal = math.min(math.round(proc.heal), source.maxHp - source.hp)
                    source.hp = source.hp + heal
                    table.insert(events, { type = "heal2", sourceId = source.id, targetId = source.id,
                        amount = heal, crit = false, ability = proc.name or proc.id })
                end
            elseif proc.aura then
                require("world.combat.aura").applyAura(source, require("world.combat.aura").new(proc.id, proc.name or proc.id,
                    proc.duration or 8, { kind = proc.aura, value = proc.value or 0, sourceId = source.id }))
            end
        end
        ::continue_proc::
    end
    return events
end

return M
