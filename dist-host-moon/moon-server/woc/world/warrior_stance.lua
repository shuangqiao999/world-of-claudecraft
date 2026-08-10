-- World of ClaudeCraft — Warrior Stance Management
-- 战士起始自带 Battle Stance，stun/root 中可切 Berserker，Defensive 也是可切换
-- 对应原项目 src/sim/sim.ts ensureWarriorStance

local M = {}

local BATTLE_STANCE_AURA_ID = "battle_stance"
local BERSERKER_STANCE_AURA_ID = "berserker_stance"
local DEFENSIVE_STANCE_AURA_ID = "defensive_stance"

--- 确保战士至少有一个姿态光环 (默认 Battle Stance)
--- @param e Entity
--- @param meta PlayerMeta
function M.ensureWarriorStance(e, meta)
    if not e or e.templateId ~= "warrior" then return end
    if not e.auras then e.auras = {} end

    local hasBattle = e.auras[BATTLE_STANCE_AURA_ID]
    local hasBerserker = e.auras[BERSERKER_STANCE_AURA_ID]
    local hasDefensive = e.auras[DEFENSIVE_STANCE_AURA_ID]

    if not hasBattle and not hasBerserker and not hasDefensive then
        -- 默认 Battle Stance
        e.auras[BATTLE_STANCE_AURA_ID] = {
            id = BATTLE_STANCE_AURA_ID,
            name = "Battle Stance",
            duration = -1, remaining = -1,
            kind = "stance_battle",
            value = 0,
            isDebuff = false,
        }
    end
end

return M
