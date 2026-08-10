-- World of ClaudeCraft — Spirit (Death) System
-- 对应原项目 src/sim/spirit.ts
-- 死亡、鬼魂、复活、灵魂医者、复活虚弱

local M = {}

-- 常量 (对齐 TS)
local CORPSE_REZ_RANGE = 35
local RES_HP_FRACTION = 0.5
local RES_HEALER_HP_FRACTION = 0.2
local SICKNESS_DURATION = 600  -- 10 分钟

--- 检查实体是否死亡
function M.checkDeath(e)
    if not e.dead and e.hp <= 0 then
        e.dead = true
        e.hp = 0
        return true
    end
    return false
end

--- 释放灵魂 (进入鬼魂状态)
function M.releaseSpirit(e)
    if not e.dead then return end
    e.ghost = true
end

--- 施加复活虚弱 (TS applyResurrectionSickness: 全属性 -75%)
function M.applyResurrectionSickness(target)
    if not target.auras then target.auras = {} end
    target.auras["resurrection_sickness"] = {
        id = "resurrection_sickness",
        name = "Resurrection Sickness",
        duration = SICKNESS_DURATION,
        remaining = SICKNESS_DURATION,
        kind = "buff_allstats_pct",
        value = -0.75,
        isDebuff = true,
    }
end

--- 跑尸复活 (TS: CORPSE_REZ_RANGE = 35, RES_HP_FRACTION = 0.5)
function M.resurrectCorpse(e, corpsePos)
    if not e.dead or not e.ghost then return false end
    local dx = e.pos.x - (corpsePos.x or e.pos.x)
    local dz = e.pos.z - (corpsePos.z or e.pos.z)
    local distSq = dx * dx + dz * dz
    if distSq > CORPSE_REZ_RANGE * CORPSE_REZ_RANGE then return false end
    e.dead = false
    e.ghost = false
    e.hp = math.floor(e.maxHp * RES_HP_FRACTION)
    e.resource = math.floor(e.maxResource * 0.35)
    return true
end

--- 治疗者复活 (TS: RES_HEALER_HP_FRACTION = 0.2)
function M.resurrectHealer(target)
    if not target.dead then return end
    target.dead = false
    target.ghost = false
    target.hp = math.floor(target.maxHp * RES_HEALER_HP_FRACTION)
    target.resource = math.floor(target.maxResource * 0.35)
end

--- 灵魂医者复活 (满血复活, 虚弱 debuff)
function M.resurrectSpiritHealer(target)
    if not target.dead then return end
    target.dead = false
    target.ghost = false
    target.hp = target.maxHp
    target.resource = target.maxResource
    M.applyResurrectionSickness(target)
    return true
end

--- 通用复活 (TS reviveAt): 指定位置 + HP 比例 + 可选虚弱
function M.reviveAt(e, pos, hpFrac, applySickness)
    e.dead = false
    e.ghost = false
    e.pos.x = pos.x or e.pos.x
    e.pos.y = pos.y or e.pos.y
    e.pos.z = pos.z or e.pos.z
    e.hp = math.max(1, math.floor(e.maxHp * (hpFrac or RES_HP_FRACTION)))
    e.resource = math.floor(e.maxResource * 0.35)
    if applySickness then
        M.applyResurrectionSickness(e)
    end
    return true
end

return M
