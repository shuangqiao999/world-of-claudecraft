-- World of ClaudeCraft — Rift System (Infernal Citadel)
-- 裂隙传送门/下降/楼层门/Heroic Mark 奖励/世界传送门调度器
-- 对应原项目 src/sim/rift/portals.ts + src/sim/rift/runs.ts

local simrng = require("world.simrng")
local config = require("config")
local deeds = require("world.deeds")
local M = {}

-- 裂隙等级 (C/B/A/S)
local RIFT_TIERS = { "C", "B", "A", "S" }
local RIFT_PORTAL_COOLDOWN = 600  -- 10 分钟刷新间隔

-- 传送门状态
local portals = {}  -- { id, pos, tier, active, nextSpawn, floorCount }
local activeRifts = {} -- { entityId, target = {pid, floor, drops} }

--- 初始化世界传送门
function M.initWorldPortals()
    portals = {}
    local positions = {
        { x = -35, z = -35 },
        { x = -35, z = 35 },
        { x = 35, z = -35 },
        { x = 35, z = 35 },
    }

    for i, pos in ipairs(positions) do
        local tierIdx = simrng.randint(1, #RIFT_TIERS)
        table.insert(portals, {
            id = "rift_portal_" .. i,
            pos = pos,
            tier = RIFT_TIERS[tierIdx],
            active = true,
            floorCount = simrng.randint(3, 6),
            nextSpawn = 0,
        })
    end
end

--- 更新裂隙 (每个 tick)
function M.update(simTime, entities, players, dt)
    local events = {}

    -- 传送门刷新
    for _, portal in ipairs(portals) do
        if not portal.active and simTime >= portal.nextSpawn then
            portal.active = true
            local tierIdx = simrng.randint(1, #RIFT_TIERS)
            portal.tier = RIFT_TIERS[tierIdx]
            portal.floorCount = simrng.randint(3, 6)
            table.insert(events, {
                type = "rift_portal_spawned",
                portalId = portal.id,
                tier = portal.tier,
                pos = portal.pos,
            })
        end
    end

    -- 活跃裂隙的进度检查
    for pid, rift in pairs(activeRifts) do
        local player = entities[pid]
        if not player or player.dead then
            table.insert(events, { type = "rift_failed", pid = pid })
            activeRifts[pid] = nil
        else
            -- 检查是否完成当前楼层
            -- (简化: 时间到了就完成)
            rift.floorTimer = (rift.floorTimer or 30) - dt
            if rift.floorTimer <= 0 then
                rift.currentFloor = (rift.currentFloor or 1) + 1
                if rift.currentFloor > rift.maxFloors then
                    -- 完成全部楼层
                    local rewards = M._generateRewards(rift.tier)
                    table.insert(events, {
                        type = "rift_completed",
                        pid = pid,
                        tier = rift.tier,
                        rewards = rewards,
                    })
                    deeds.onRiftComplete(pid)
                    activeRifts[pid] = nil
                else
                    rift.floorTimer = 30
                    table.insert(events, {
                        type = "rift_floor_progress",
                        pid = pid,
                        floor = rift.currentFloor,
                        maxFloors = rift.maxFloors,
                    })
                end
            end
        end
    end

    return events
end

--- 进入裂隙
function M.enterRift(pid, portalId, entities)
    local portal
    for _, p in ipairs(portals) do
        if p.id == portalId and p.active then
            portal = p; break
        end
    end
    if not portal then return false, "Portal not available" end
    local player = entities[pid]
    if not player or player.dead then return false, "Cannot enter" end
    if player.level < 20 then return false, "Requires level 20" end

    -- 传送玩家到裂隙空间
    player.riftTier = portal.tier
    player.riftSliding = true
    player.oldPos = { x = player.pos.x, y = player.pos.y, z = player.pos.z }

    activeRifts[pid] = {
        pid = pid,
        tier = portal.tier,
        maxFloors = portal.floorCount,
        currentFloor = 1,
        floorTimer = 30,
        drops = {},
    }

    -- 停用传送门
    portal.active = false
    portal.nextSpawn = simTime + RIFT_PORTAL_COOLDOWN

    return true, portal.tier
end

--- 离开裂隙
function M.leaveRift(pid, entities)
    local player = entities[pid]
    if not player then return end
    if player.riftSliding then
        player.riftSliding = false
        if player.oldPos then
            player.pos.x = player.oldPos.x
            player.pos.z = player.oldPos.z
            player.oldPos = nil
        end
    end
    activeRifts[pid] = nil
end

--- 生成裂隙奖励
function M._generateRewards(tier)
    local rewards = {}
    local tierMultiplier = { C = 1, B = 2, A = 3, S = 5 }
    local mult = tierMultiplier[tier] or 1

    local copper = simrng.randint(100, 500) * mult
    table.insert(rewards, { type = "copper", amount = copper })

    -- Heroic Marks (A/S tier)
    if tier == "A" or tier == "S" then
        local marks = tier == "S" and 3 or 1
        table.insert(rewards, { type = "heroic_mark", amount = marks })
    end

    return rewards
end

--- 获取传送门状态 (用于快照)
function M.getPortals()
    return portals
end

return M
