-- World of ClaudeCraft — Set Procs
-- 对应原项目 src/sim/combat/set_procs.ts
-- 套装 proc 从 proto/item_sets.json 收集 (recalc 填 e.setProcs), 触发器映射 TS 名称

local simrng = require("world.simrng")
local M = {}

-- TS 触发器名 → 调用点触发器
local TRIGGER_MAP = {
    ["spellCast"] = "on_spell_cast",
    ["weaponCrit"] = "on_attack",
    ["spellCrit"] = "on_spell_cast",
    ["kill"] = "on_kill",
    ["weaponHit"] = "on_attack",
}

--- 映射触发器
function M.mapTrigger(tsTrigger)
    return TRIGGER_MAP[tsTrigger] or tsTrigger
end

--- 应用套装触发
--- @param source 攻击者/施法者
--- @param target 目标
--- @param trigger 触发条件: "on_attack", "on_spell_cast", "on_kill"
--- @param simTime 当前 sim 时间
function M.applySetProcs(source, target, trigger, simTime)
    if not source or not source.setProcs or #source.setProcs == 0 then return end
    if not source.procReadyAt then source.procReadyAt = {} end

    for _, proc in ipairs(source.setProcs) do
        -- 触发器匹配 (TS proc.trigger: spellCast/weaponCrit/spellCrit/kill)
        local procTrigger = M.mapTrigger(proc.trigger)
        if procTrigger == trigger then
            -- PvP-only proc: 只在 PvP 目标生效
            if proc.pvpOnly and not (target and target.kind == "player") then
                goto continue_proc
            end
            -- ICD 检查
            if proc.icd and simTime < (source.procReadyAt[proc.id] or 0) then
                goto continue_proc
            end
            -- 概率
            if not simrng.chance(proc.chance or 0.1) then goto continue_proc end

            source.procReadyAt[proc.id] = simTime + (proc.icd or 0)

            -- 目标选择
            local recipient = proc.applyTo == "target" and target or source
            if not recipient or recipient.dead then goto continue_proc end

            -- 创建光环
            local aura = require("world.combat.aura")
            local duration = proc.duration or 10
            local newAura = aura.new(proc.id, proc.name or proc.id, duration, {
                kind = proc.aura,
                value = proc.value or 0,
                duration = duration,
                tickInterval = proc.tickInterval,
                maxStacks = proc.maxStacks or 1,
                sourceId = source.id,
                school = proc.school,
            })

            -- 叠加
            if proc.maxStacks and proc.maxStacks > 1 then
                local existing = recipient.auras and recipient.auras[proc.id]
                if existing then
                    local stacks = math.min(proc.maxStacks, (existing.stacks or 1) + 1)
                    newAura.stacks = stacks
                    newAura.value = (proc.value or 0) * stacks
                end
            end

            aura.applyAura(recipient, newAura)
        end
        ::continue_proc::
    end
end

return M
