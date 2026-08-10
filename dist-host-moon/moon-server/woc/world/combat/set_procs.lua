-- World of ClaudeCraft — Set Procs System
-- 物品套装触发: 2/4/6 件套效果, 内部冷却, 叠层
-- 对应原项目 src/sim/combat/set_procs.ts

local simrng = require("world.simrng")
local M = {}

-- 简易套装数据库 (完整版在 proto/item_sets.json)
local ITEM_SETS = {
    -- 战士: Battlelord 套
    battlelord = {
        id = "battlelord",
        name = "Battlelord's Armor",
        procs = {
            [2] = { id = "battlelord_rage", name = "Rage of the Battlelord", aura = "buff_rage_gen",
                trigger = "on_attack", chance = 0.15, value = 0.1, duration = 10, icd = 30 },
            [4] = { id = "battlelord_might", name = "Might of the Battlelord", aura = "buff_ap",
                trigger = "on_attack", chance = 0.1, value = 30, duration = 15, icd = 45 },
        },
    },
    -- 法师: Arcanist 套
    arcanist = {
        id = "arcanist",
        name = "Arcanist's Regalia",
        procs = {
            [2] = { id = "arcanist_focus", name = "Arcane Focus", aura = "buff_spellpower",
                trigger = "on_spell_cast", chance = 0.2, value = 20, duration = 10, icd = 30 },
            [4] = { id = "arcanist_surge", name = "Arcane Surge", aura = "buff_spellcrit",
                trigger = "on_spell_cast", chance = 0.1, value = 0.05, duration = 15, icd = 45 },
        },
    },
}

--- 应用套装触发
-- @param source 攻击者/施法者
-- @param target 目标 (可选)
-- @param trigger 触发条件: "on_attack", "on_spell_cast", "on_hit"
-- @param simTime 当前 sim 时间
function M.applySetProcs(source, target, trigger, simTime)
    if not source.setProcs or #source.setProcs == 0 then return end
    if not source.procReadyAt then source.procReadyAt = {} end

    for _, proc in ipairs(source.setProcs) do
        if proc.trigger == trigger then
            -- ICD 检查
            if proc.icd and simTime < (source.procReadyAt[proc.id] or 0) then
                goto continue_proc
            end

            -- 目标选择: applyTo=target 时影响目标, 否则 self
            local recipient = proc.applyTo == "target" and target or source
            if not recipient or recipient.dead then goto continue_proc end

            -- 概率检查
            if not simrng.chance(proc.chance or 0.1) then goto continue_proc end

            -- 设置 ICD
            source.procReadyAt[proc.id] = simTime + (proc.icd or 0)

            -- 创建光环
            local aura = {
                id = proc.id,
                name = proc.name,
                kind = proc.aura,
                duration = proc.duration or 10,
                remaining = proc.duration or 10,
                sourceId = source.id,
                value = proc.value or 0,
                stacks = 1,
                maxStacks = proc.maxStacks or 1,
            }

            -- 叠加: 检查已有光环
            if proc.maxStacks and proc.maxStacks > 1 then
                if recipient.auras and recipient.auras[proc.id] then
                    local existing = recipient.auras[proc.id]
                    aura.stacks = math.min(proc.maxStacks, (existing.stacks or 1) + 1)
                    aura.value = (proc.value or 0) * aura.stacks
                end
            end

            -- 应用 (需要通过 aura 模块, 这里直接写入)
            if not recipient.auras then recipient.auras = {} end
            recipient.auras[proc.id] = aura

            ::continue_proc::
        end
    end
end

--- 获取套装定义
function M.getSetDef(setId)
    return ITEM_SETS[setId]
end

return M
