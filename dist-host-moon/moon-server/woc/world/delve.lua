-- World of ClaudeCraft — Delve System
-- 深入探索: 房间谜题、同伴AI、开锁
-- 对应原项目 src/sim/delves/runs.ts + src/sim/delves/companion.ts
-- Delve 定义从 proto/delves.json 加载

local simrng = require("world.simrng")
local deeds = require("world.deeds")
local M = {}

-- Delve 定义 (从 proto 填充)
local DELVES = {}
local delvesLoaded = false

function M.loadFromProto()
    if delvesLoaded then return end
    local ok, proto = pcall(function() return require("proto.load") end)
    if not ok then return end
    local raw = proto.delves
    if not raw then return end
    for id, dg in pairs(raw) do
        DELVES[id] = {
            id = id,
            name = dg.name or id,
            minLevel = dg.minLevel or 7,
            maxPlayers = dg.maxPlayers or 2,
            suggestedPlayers = dg.suggestedPlayers or 2,
            modules = dg.modules or {},
            moduleCount = dg.moduleCount or { 3, 3 },
            totalRooms = (dg.moduleCount and dg.moduleCount[1]) or 3,
            finaleModuleId = dg.finaleModuleId,
            bosses = dg.bosses or {},
            objective = dg.objective or "kill_boss",
            boardNpcId = dg.boardNpcId,
            autoCompanionId = dg.autoCompanionId,
            rewardMultiplier = 1.5,
        }
    end
    delvesLoaded = true
    local n = 0; for _ in pairs(DELVES) do n = n + 1 end
    print(string.format("[Delve] Loaded %d delves from proto", n))
end

-- 活跃的 Delve 实例: { readonly = {pid, currentRoom, roomTimer, companionHp} }
local activeDelves = {}

--- 进入 Delve
function M.enterDelve(pid, delveId, entities)
    local delve = DELVES[delveId]
    if not delve then return false, "Delve not found" end
    local player = entities[pid]
    if not player or player.dead then return false, "Cannot enter" end
    if player.level < delve.minLevel then return false, "Level too low" end

    activeDelves[pid] = {
        pid = pid,
        delveId = delveId,
        currentRoom = 1,
        roomTimer = 120,         -- 每个房间 2 分钟限制
        companionHp = 100,       -- 同伴 HP
        companionMaxHp = 100,
        lockpicksRemaining = 3,
        puzzlesSolved = 0,
        bossPhase = 0,
        inProgress = true,
        rewards = {},
    }

    player.dungeonId = "delve_" .. delveId
    player.oldPos = { x = player.pos.x, y = player.pos.y, z = player.pos.z }
    return true, delve.name
end

--- 离开 Delve
function M.leaveDelve(pid, entities)
    local player = entities[pid]
    if not player then return end
    if player.oldPos then
        player.pos.x = player.oldPos.x
        player.pos.z = player.oldPos.z
        player.oldPos = nil
    end
    player.dungeonId = nil
    activeDelves[pid] = nil
end

--- 更新 Delve (每个 tick)
function M.update(simTime, entities, players, dt)
    local events = {}

    for pid, delve in pairs(activeDelves) do
        if not delve.inProgress then goto continue_delve end
        local player = entities[pid]
        if not player or player.dead then
            table.insert(events, { type = "delve_failed", pid = pid, reason = "death" })
            activeDelves[pid] = nil
            goto continue_delve
        end

        -- 房间计时器
        delve.roomTimer = delve.roomTimer - dt
        if delve.roomTimer <= 0 then
            table.insert(events, { type = "delve_failed", pid = pid, reason = "timeout" })
            activeDelves[pid] = nil
            goto continue_delve
        end

        -- 同伴更新
        M._updateCompanion(delve, dt, events, pid)

        ::continue_delve::
    end

    return events
end

--- 尝试开锁 (消耗 lockpick)
function M.attemptLockpick(pid)
    local delve = activeDelves[pid]
    if not delve then return false, "Not in a delve" end
    if delve.lockpicksRemaining <= 0 then return false, "No lockpicks remaining" end

    delve.lockpicksRemaining = delve.lockpicksRemaining - 1

    local success = simrng.random() < 0.6  -- 60% 成功率
    if success then
        delve.puzzlesSolved = delve.puzzlesSolved + 1
    end
    return success, delve.lockpicksRemaining
end

--- 推进到下一个房间
function M.advanceRoom(pid)
    local delve = activeDelves[pid]
    if not delve then return false end

    local totalRooms = DELVES[delve.delveId].totalRooms
    if delve.currentRoom >= totalRooms then
        -- 完成所有房间
        M._completeDelve(delve)
        return true, "complete"
    end

    delve.currentRoom = delve.currentRoom + 1
    delve.roomTimer = 120  -- 重置计时器

    -- Boss 房间
    if delve.currentRoom == totalRooms then
        delve.bossPhase = 1
        return true, "boss"
    end

    return true, "room_" .. delve.currentRoom
end

--- 完成 Delve
function M._completeDelve(delve)
    delve.inProgress = false
    deeds.onDelveComplete(delve.pid)
    local tierMult = DELVES[delve.delveId].rewardMultiplier

    local copper = simrng.randint(200, 800) * tierMult
    table.insert(delve.rewards, { type = "copper", amount = copper })

    if simrng.random() < 0.4 then
        table.insert(delve.rewards, { type = "item", name = "Drowned Relic", count = 1 })
    end
end

--- 同伴更新
function M._updateCompanion(delve, dt, events, pid)
    delve.companionHp = math.max(0, delve.companionHp + 0.5 * dt)  -- 缓慢恢复

    -- 同伴帮助战斗: 如果在 Boss 阶段，每秒造成伤害
    if delve.bossPhase > 0 then
        delve.companionAttackTimer = (delve.companionAttackTimer or 0) + dt
        if delve.companionAttackTimer >= 2.0 then
            delve.companionAttackTimer = 0
            table.insert(events, {
                type = "delve_companion_attack",
                pid = pid,
                dmg = 5 + delve.currentRoom * 3,
            })
        end
    end
end

--- 获取 Delve 状态
function M.getDelveState(pid)
    return activeDelves[pid]
end

--- 同伴升级
function M.companionUpgrade(pid, companionId)
    local delve = activeDelves[pid]
    if not delve then return false, "Not in a delve" end
    if (delves[pid] and delves[pid].companionRank or 0) >= 3 then return false, "Max rank" end
    local cost = ((delves[pid] and delves[pid].companionRank or 0) + 1) * 50
    delve.companionRank = (delves[pid] and delves[pid].companionRank or 0) + 1
    delve.companionMaxHp = 100 + (delve.companionRank or 1) * 20
    delve.companionHp = math.min(delve.companionHp + 30, delve.companionMaxHp)
    return true, delve.companionRank
end

--- Delve 商店购买
function M.delveBuyShopItem(pid, delveId, itemId)
    local delve = activeDelves[pid]
    if not delve then return false, "Not in a delve" end
    local shopItems = {
        health_potion = { cost = 50, effect = function() delve.companionHp = math.min(delve.companionMaxHp, delve.companionHp + 40) end },
        extra_lockpick = { cost = 30, effect = function() delve.lockpicksRemaining = (delve.lockpicksRemaining or 0) + 1 end },
        time_extend = { cost = 40, effect = function() delve.roomTimer = delve.roomTimer + 60 end },
    }
    local si = shopItems[itemId]
    if not si then return false, "Unknown shop item" end
    si.effect()
    return true, itemId
end

--- 开锁会话开始 (带前置)
function M.lockpickEngage(pid, objectId, ante)
    local delve = activeDelves[pid]
    if not delve then return false, "Not in a delve" end
    if delve.lockpicksRemaining <= 0 then return false, "No lockpicks" end
    delve.lockpickSession = {
        objectId = objectId,
        ante = ante or 1,
        progress = 0,
        maxProgress = 3,
        sid = "lp_" .. pid .. "_" .. os.time(),
    }
    return true, delve.lockpickSession
end

--- 开锁行动
function M.lockpickAction(pid, sid, action)
    local delve = activeDelves[pid]
    if not delve or not delve.lockpickSession then return false, "No session" end
    if delve.lockpickSession.sid ~= sid then return false, "Session mismatch" end
    if simrng.random() < 0.55 then
        delve.lockpickSession.progress = delve.lockpickSession.progress + 1
        if delve.lockpickSession.progress >= delve.lockpickSession.maxProgress then
            delve.puzzlesSolved = (delve.puzzlesSolved or 0) + 1
            delve.lockpicksRemaining = (delve.lockpicksRemaining or 1) - 1
            delve.lockpickSession = nil
            return true, "opened"
        end
        return true, "progress"
    end
    delve.lockpickSession.progress = math.max(0, delve.lockpickSession.progress - 1)
    if delve.lockpickSession.progress <= -2 then
        delve.lockpicksRemaining = (delve.lockpicksRemaining or 1) - 1
        delve.lockpickSession = nil
        return false, "broken"
    end
    return false, "fail"
end

--- 放弃开锁
function M.lockpickAbort(pid, sid)
    local delve = activeDelves[pid]
    if not delve or not delve.lockpickSession then return false end
    delve.lockpicksRemaining = (delve.lockpicksRemaining or 1) - 1
    delve.lockpickSession = nil
    return true
end

--- 收集宝箱战利品
function M.collectDelveChestLoot(pid)
    local delve = activeDelves[pid]
    if not delve then return false, "Not in a delve" end
    if delve.currentRoom < 3 then return false, "No chest yet" end
    local loot = { copper = simrng.randint(100, 400) }
    if simrng.random() < 0.35 then loot.item = "Delver's Keepsake" end
    table.insert(delve.rewards, { type = "copper", amount = loot.copper })
    if loot.item then table.insert(delve.rewards, { type = "item", name = loot.item, count = 1 }) end
    return true, loot
end

--- 选择仪式
function M.delveRiteChoose(pid, intensity)
    local delve = activeDelves[pid]
    if not delve then return false, "Not in a delve" end
    local rites = { easy = 1.0, medium = 1.3, hard = 1.6 }
    if not rites[intensity] then return false, "Invalid intensity" end
    delve.riteIntensity = intensity
    delve.roomTimer = delve.roomTimer * (intensity == "hard" and 0.7 or intensity == "medium" and 0.85 or 1.0)
    return true, intensity
end

return M
