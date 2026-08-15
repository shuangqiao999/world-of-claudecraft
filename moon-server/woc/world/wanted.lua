-- World of ClaudeCraft — Notoriety / Wanted (GTA 通缉值)
-- 攻击/击杀平民 NPC 或其他玩家会累积通缉值; 通缉期间城市 NPC (路人) 敌视并围殴玩家。
-- 通缉值随时间缓慢衰减, 死亡不清零 (GTA: 通缉会持续一段时间)。

local M = {}

M.MAX_WANTED = 5
local WANTED_DECAY_SECONDS = 60      -- 每 60 秒衰减 1 级
local WANTED_AGGRO_RADIUS_SQ = 40 * 40  -- 城市 NPC 围殴通缉玩家的感知范围

--- 加通缉值 (击杀平民/玩家)
function M.addWanted(meta, amount)
    if not meta then return end
    meta.wantedLevel = math.min(M.MAX_WANTED, (meta.wantedLevel or 0) + (amount or 1))
end

--- 周期衰减 (每 tick 按 DT 折算)
function M.decayWanted(meta, dt)
    if meta and meta.wantedLevel and meta.wantedLevel > 0 then
        meta.wantedLevel = meta.wantedLevel - (dt or 0) / WANTED_DECAY_SECONDS
        if meta.wantedLevel <= 0 then meta.wantedLevel = 0 end
    end
end

--- 是否被通缉
function M.isWanted(meta)
    return meta ~= nil and (meta.wantedLevel or 0) > 0
end

--- 城市 NPC 围殴通缉玩家的感知范围平方
function M.aggroRadiusSq()
    return WANTED_AGGRO_RADIUS_SQ
end

return M
