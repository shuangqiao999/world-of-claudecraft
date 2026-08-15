-- World of ClaudeCraft — Player Combat State Machine (GTA 开放世界手感)
-- 玩家端战斗状态: IDLE / AUTO_FIGHT / PVP_FIGHT / FLEEING / DEAD
-- 关键语义: FLEEING 只停止我方输出, 不免伤 (怪物/敌人仍可追击并造成伤害)。
-- 状态挂在实体 e.combatState 上; 自动攻击开关仍由 auto_attack 管理 (此处协调两者)。

local autoAttack = require("world.combat.auto_attack")

local M = {}

M.STATE = {
    IDLE = "idle",
    AUTO_FIGHT = "auto_fight",
    PVP_FIGHT = "pvp_fight",
    FLEEING = "fleeing",
    DEAD = "dead",
}

--- 初始化 (joinPlayer 时调用)
function M.init(e)
    if not e.combatState then e.combatState = M.STATE.IDLE end
end

--- 是否持械 (GTA: 空手不自动攻击, 只靠近)
--- e.weapon 恒有拳头默认值, 故用主手装备 id (mainhandItemId) 判定是否真正持械
function M.hasWeapon(e)
    return e.mainhandItemId ~= nil
end

--- 仅选中目标 (不改变战斗状态)
function M.select(e, target)
    e.targetId = target and target.id or nil
end

--- 进入自动战斗 (选中怪物/平民NPC 即开打); 玩家目标/空手均只选中不攻击
--- @return boolean 是否真正进入 AUTO_FIGHT
function M.enterAutoFight(e, target)
    if e.dead then return false end
    if target and target.kind == "player" then
        -- 玩家目标不走自动攻击 (PVP 需手动 pvp_attack 二次确认)
        M.select(e, target)
        autoAttack.stopAutoAttack(e)
        e.combatState = M.STATE.IDLE
        return false
    end
    M.select(e, target)
    if not M.hasWeapon(e) then
        -- 空手: 只选中不自动攻击 (GTA: 靠近但不打)
        e.combatState = M.STATE.IDLE
        autoAttack.stopAutoAttack(e)
        return false
    end
    e.combatState = M.STATE.AUTO_FIGHT
    autoAttack.startAutoAttack(e, target)
    return true
end

--- 进入 PVP 战斗 (需手动二次确认; PVP 无自动攻击, 由玩家主动输出)
function M.enterPvpFight(e, target)
    if e.dead then return false end
    M.select(e, target)
    e.combatState = M.STATE.PVP_FIGHT
    return true
end

--- 被攻击方标记进入 PVP (不改变其目标/自动攻击, 仅标记可互伤)
function M.flagPvp(e)
    if not e.dead then
        e.combatState = M.STATE.PVP_FIGHT
    end
end

--- 逃跑 (点地面/主动停手): 停我方输出 + 清目标, 不免伤
function M.flee(e)
    e.combatState = M.STATE.FLEEING
    autoAttack.stopAutoAttack(e)
    e.targetId = nil
end

--- 回到空闲
function M.idle(e)
    e.combatState = M.STATE.IDLE
    autoAttack.stopAutoAttack(e)
    e.targetId = nil
end

--- 死亡
function M.die(e)
    e.combatState = M.STATE.DEAD
    autoAttack.stopAutoAttack(e)
    e.targetId = nil
end

return M
