-- World of ClaudeCraft — Nature's Fury
-- 对应原项目 src/sim/sim.ts tickNaturesFury
-- 月翼小队暴击脉冲 (德鲁伊天赋): 队伍暴击时给全队爆发

local M = {}

local NATURES_FURY_CD_TICKS = 40  -- 2s 内置冷却 (20Hz)

--- 每玩家 tick
function M.tickNaturesFury(e, meta, tickCount, partyModule)
    if not e or e.kind ~= "player" then return {} end
    -- 需天赋支持 (buff_natures_fury)
    local hasTalent = false
    for _, a in pairs(e.auras or {}) do
        if a.kind == "natures_fury" then hasTalent = true break end
    end
    if not hasTalent then return {} end

    -- 冷却检查
    if not e._naturesFuryCd then e._naturesFuryCd = 0 end
    e._naturesFuryCd = e._naturesFuryCd - 1
    if e._naturesFuryCd > 0 then return {} end

    -- 队友暴击时脉冲 (简化: 每 CD 给队伍一次爆发)
    local events = {}
    e._naturesFuryCd = NATURES_FURY_CD_TICKS
    local party = { e.id }
    if partyModule and partyModule.getMembers then
        local members = partyModule.getMembers(e.id)
        if members and #members > 0 then party = members end
    end
    for _, pid in ipairs(party) do
        table.insert(events, { type = "natures_fury", pid = pid, sourceId = e.id })
    end
    return events
end

return M
