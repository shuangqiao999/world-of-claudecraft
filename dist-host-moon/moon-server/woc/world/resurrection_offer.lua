-- World of ClaudeCraft — Resurrection Offers + Sickness
-- 复活提议: 被法术复活时接受/拒绝
-- 对应原项目 src/sim/spirit.ts resurrectionOffer + src/sim/resurrection.ts

local M = {}

local OFFER_TIMEOUT = 60  -- 60 秒超时
local SICKNESS_DURATION = 600  -- 10 分钟复活虚弱

-- 活跃的复活提议: { targetPid = { casterPid, expiry } }
local offers = {}

--- 发起复活提议
function M.offerResurrection(casterPid, targetPid)
    if offers[targetPid] then return false end  -- 已有一个有效提议

    offers[targetPid] = {
        casterPid = casterPid,
        expiry = OFFER_TIMEOUT,
    }
    return true
end

--- 接受复活提议
function M.acceptResurrection(targetPid, entities, spiritModule)
    local offer = offers[targetPid]
    if not offer or offer.expiry <= 0 then return false end

    local target = entities[targetPid]
    if not target or not target.dead then return false end

    -- 执行复活
    target.dead = false
    target.ghost = false
    target.hp = math.max(1, math.floor(target.maxHp * 0.35 + 0.5))
    target.resource = target.maxResource * 0.1

    -- 施加复活虚弱
    if not target.auras then target.auras = {} end
    target.auras["resurrection_sickness"] = {
        id = "resurrection_sickness",
        name = "Resurrection Sickness",
        duration = SICKNESS_DURATION,
        remaining = SICKNESS_DURATION,
        kind = "buff_allstats_pct",
        value = -0.75,  -- 全属性减少 75%
        isDebuff = true,
    }

    offers[targetPid] = nil
    return true
end

--- 拒绝复活提议
function M.declineResurrection(targetPid)
    offers[targetPid] = nil
end

--- 更新复活提议 (每个 tick)
function M.update(dt)
    local events = {}
    local toRemove = {}

    for targetPid, offer in pairs(offers) do
        offer.expiry = offer.expiry - dt
        if offer.expiry <= 0 then
            toRemove[targetPid] = true
        end
    end

    for pid, _ in pairs(toRemove) do
        offers[pid] = nil
    end

    return events
end

return M
