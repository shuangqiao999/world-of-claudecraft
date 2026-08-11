-- World of ClaudeCraft — Health/Mana/Energy Regen per 2s Tick
-- 对应原项目 src/sim/combat/auras.ts updateRegen (79-157)
-- 每 2 秒执行一次 (tickCount % 40 == 0); 经典 Era 五秒规则

local config = require("config")
local M = {}

local SECOND_WIND_THRESHOLD = 0.35
local REGEN_INTERVAL_TICKS = math.round(2.0 / config.DT)  -- 每 2 秒 (随 TICK_RATE 缩放)

--- 更新玩家的回复 (每 2 秒 tick)
--- @param e Entity
--- @param meta PlayerMeta
--- @param tickCount number 当前 tick 数
--- @return table 事件列表
function M.updateRegen(e, meta, tickCount)
    if not e or e.dead then return {} end
    if tickCount % REGEN_INTERVAL_TICKS ~= 0 then return {} end

    local events = {}

    -- Lifesap (resource_sap aura): 恢复当前资源条
    for _, aura in pairs(e.auras or {}) do
        if aura.kind == "resource_sap" then
            e.resource = math.min(e.maxResource, e.resource + math.round(aura.value or 0))
        end
    end

    -- 资源回复
    if e.resourceType == "mana" then
        if e.fiveSecondRule >= 5 then
            -- 非战斗 mana 回复: (spi/3 + 4 + floor(level/5)) * (1 + manaRegenPct)
            local spi = (e.stats and e.stats.spi) or 0
            local manaRegenPct = (meta and meta.manaRegenPct) or 0
            local regen = (spi / 3 + 4 + math.floor(e.level / 5)) * (1 + manaRegenPct)
            e.resource = math.min(e.maxResource, e.resource + math.round(regen))
        end
    elseif e.resourceType == "energy" then
        -- 能量回复: 20 * (1 + buff_energyregen value)
        local regen = 20
        for _, a in pairs(e.auras or {}) do
            if a.kind == "buff_energyregen" then
                regen = regen * (1 + (a.value or 0))
            end
        end
        e.resource = math.min(e.maxResource, e.resource + math.round(regen))
    elseif e.resourceType == "rage" and not e.inCombat then
        -- 怒气衰减: 非战斗 -2
        e.resource = math.max(0, e.resource - 2)
    end

    -- HP 回复 (非战斗 + 未满血 + eating.hpPer2s != 0): sta * 0.3 + 2
    local eatingHpPer2s = (e.eating and e.eating.hpPer2s) or 0
    if not e.inCombat and e.hp < e.maxHp and eatingHpPer2s ~= 0 then
        local sta = (e.stats and e.stats.sta) or 0
        local regen = sta * 0.3 + 2
        e.hp = math.min(e.maxHp, e.hp + math.round(regen))
    end

    -- Second Wind (天赋): HP < 35% maxHp 时回复
    local secondWindPct = (meta and meta.secondWindPctPerSec) or 0
    if secondWindPct > 0 and e.hp > 0 and e.hp < e.maxHp * SECOND_WIND_THRESHOLD then
        local heal = math.min(math.round(e.maxHp * secondWindPct * 2), e.maxHp - e.hp)
        if heal > 0 then
            e.hp = e.hp + heal
            table.insert(events, { type = "heal", targetId = e.id, amount = heal })
        end
    end

    -- Food/Drink 独立 tick (hpPer2s / manaPer2s)
    for _, slot in ipairs({ "eating", "drinking" }) do
        local c = e[slot]
        if not c then goto continue_slot end

        local healed = 0
        if (c.hpPer2s or 0) > 0 and e.hp < e.maxHp then
            healed = math.min(math.round(c.hpPer2s), e.maxHp - e.hp)
            e.hp = e.hp + healed
        end
        if (c.manaPer2s or 0) > 0 and e.resourceType == "mana" then
            e.resource = math.min(e.maxResource, e.resource + c.manaPer2s)
        end
        c.ticksElapsed = (c.ticksElapsed or 0) + 1
        if healed > 0 then
            table.insert(events, { type = "heal", targetId = e.id, amount = healed, source = c.kind })
        end
        c.remaining = (c.remaining or 0) - 2
        if c.remaining <= 0 then e[slot] = nil end

        ::continue_slot::
    end

    return events
end

--- 玩家施法或造成伤害时重置五秒规则 (TS: fiveSecondRule = 0)
function M.resetFiveSecondRule(e)
    if e then
        e.fiveSecondRule = 0
    end
end

--- 每个 tick 递增战斗计时器 (TS auras.ts updateTimers:159-200)
--- fiveSecondRule/combatTimer 无条件递增; gcd/药水冷却钳制到 0
function M.updateTimers(e, dt)
    if not e then return end
    e.fiveSecondRule = (e.fiveSecondRule or 0) + dt
    e.combatTimer = (e.combatTimer or 0) + dt
    e.gcdRemaining = math.max(0, (e.gcdRemaining or 0) - dt)
    e.potionCdRemaining = math.max(0, (e.potionCdRemaining or 0) - dt)
    e.firebottleCdRemaining = math.max(0, (e.firebottleCdRemaining or 0) - dt)
end

--- 进入战斗 (TS enterCombat: 双方 combatTimer = 0, inCombat = true)
function M.enterCombat(a, b)
    if a then
        a.combatTimer = 0
        a.inCombat = true
    end
    if b then
        b.combatTimer = 0
        b.inCombat = true
    end
end

return M
