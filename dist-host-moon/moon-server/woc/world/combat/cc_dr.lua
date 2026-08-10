-- World of ClaudeCraft — CC Diminishing Returns (独立分类)
-- 经典 Era stun DR 不是同一个桶。不同类别独立衰减。
-- 对应原项目 src/sim/stun_dr.ts

local M = {}

-- DR 分类: 每类有独立的计数器 (full → 50% → 25% → 免疫)
local DR_CATEGORIES = {
    -- 潜行起手晕 (互不干扰后续控制晕)
    openerStun = { abilityIds = { ["cheap_shot"] = true, ["pounce"] = true }, resetSeconds = 18 },
    -- 主动控制晕 (Kidney Shot, HoJ, Bash, Charge)
    controlledStun = {
        abilityIds = {
            ["kidney_shot"] = true, ["hammer_of_justice"] = true,
            ["bash"] = true, ["charge"] = true, ["bear_charge"] = true,
            ["faultline"] = true,
        },
        resetSeconds = 18,
    },
    -- 随机触发晕 (proc-style, 默认)
    randomStun = { abilityIds = {}, resetSeconds = 18 },

    -- 其他控制类型 (独立 DR)
    root = { abilityIds = {}, resetSeconds = 15, genericMechanic = "root" },
    fear = { abilityIds = {}, resetSeconds = 15, genericMechanic = "fear" },
    disorient = { abilityIds = {}, resetSeconds = 15, genericMechanic = "disorient" },
    silence = { abilityIds = {}, resetSeconds = 15, genericMechanic = "silence" },
    disarm = { abilityIds = {}, resetSeconds = 15, genericMechanic = "disarm" },
}

-- DR 缩减表: 第1次=全效, 第2次=50%, 第3次=25%, 第4次=免疫
local DR_REDUCTION = { 1.0, 0.5, 0.25, 0.0 }

-- 按目标存储 DR 状态: { targetId = { categoryName = { count, resetTime } } }
local drState = {}

--- 根据技能ID确定DR分类
function M.getDrCategory(abilityId, mechanic)
    for catName, cat in pairs(DR_CATEGORIES) do
        if cat.abilityIds and cat.abilityIds[abilityId] then
            return catName
        end
        if cat.genericMechanic and cat.genericMechanic == mechanic then
            return catName
        end
    end
    -- 如果是 stun mechanic 但不在特定列表里, 分到 randomStun
    if mechanic == "stun" then return "randomStun" end
    -- 其他 mechanic 匹配 category
    for catName, cat in pairs(DR_CATEGORIES) do
        if cat.genericMechanic == mechanic then
            return catName
        end
    end
    return nil  -- 无 DR 的分类 (如 snare)
end

--- 检查 DR 并返回修改后的持续时间
function M.applyDiminishingReturns(targetId, abilityId, mechanic, duration, simTime)
    if not targetId then return duration end

    local catName = M.getDrCategory(abilityId, mechanic)
    if not catName then return duration end

    local cat = DR_CATEGORIES[catName]
    if not cat then return duration end

    if not drState[targetId] then drState[targetId] = {} end
    if not drState[targetId][catName] then
        drState[targetId][catName] = { count = 0, resetTime = 0 }
    end

    local state = drState[targetId][catName]

    -- simTime 驱动的重置
    if simTime and state.resetTime > 0 and simTime >= state.resetTime then
        state.count = 0
        state.resetTime = 0
    end

    state.count = state.count + 1
    if simTime then state.resetTime = simTime + (cat.resetSeconds or 15) end

    if state.count > #DR_REDUCTION then return 0 end  -- 完全免疫

    local reduction = DR_REDUCTION[state.count]
    return math.max(0, duration * reduction)
end

--- 清理目标 DR 状态 (玩家离开时)
function M.cleanupDrState(targetId)
    drState[targetId] = nil
end

return M
