-- World of ClaudeCraft — Dungeon Finder
-- 自动角色队列 + 领导者预组队伍面板
-- 对应原项目 src/sim/social/dungeon_finder.ts

local simrng = require("world.simrng")
local config = require("config")
local M = {}

-- 地下城列表
local DUNGEON_LIST = {
    { id = "deadmines", name = "The Deadmines", minLevel = 8, maxLevel = 12, roles = {tank=1, healer=1, dps=3} },
    { id = "shadowfang", name = "Shadowfang Keep", minLevel = 12, maxLevel = 16, roles = {tank=1, healer=1, dps=3} },
    { id = "scarlet_halls", name = "Scarlet Halls", minLevel = 15, maxLevel = 20, roles = {tank=1, healer=1, dps=3} },
}

-- 角色类型
local ROLE = { TANK = "tank", HEALER = "healer", DPS = "dps" }

-- 队列: { pid, class, role, level, queueTime }
local queue = {}
-- 预组队伍: { leaderPid, members = {pid, ...}, roles = {tank=pid, ...} }
local premadeGroups = {}
-- 已组建的组: { dungeonId, members, ready }
local formedGroups = {}

--- 加入队列
function M.joinQueue(pid, role, level, entities)
    local player = entities[pid]
    if not player then return false end

    -- 检查是否已在队列
    for _, entry in ipairs(queue) do
        if entry.pid == pid then return false end
    end

    table.insert(queue, {
        pid = pid,
        role = role or ROLE.DPS,
        level = level or player.level,
        queueTime = 0,
    })
    return true
end

--- 离开队列
function M.leaveQueue(pid)
    for i, entry in ipairs(queue) do
        if entry.pid == pid then
            table.remove(queue, i)
            return true
        end
    end
    return false
end

--- 创建预组队伍
function M.createPremade(leaderPid, dungeonId, entities)
    premadeGroups[leaderPid] = {
        leaderPid = leaderPid,
        dungeonId = dungeonId,
        members = { leaderPid },
        roles = { tank = nil, healer = nil, dps = {} },
    }
    return true
end

--- 加入预组
function M.joinPremade(leaderPid, pid, role)
    local group = premadeGroups[leaderPid]
    if not group then return false end
    if #group.members >= 5 then return false end

    table.insert(group.members, pid)
    if role == ROLE.TANK then group.roles.tank = pid
    elseif role == ROLE.HEALER then group.roles.healer = pid
    else table.insert(group.roles.dps, pid) end
    return true
end

--- 解散预组
function M.disbandPremade(leaderPid)
    premadeGroups[leaderPid] = nil
end

--- 更新地下城查找器 (每个 tick)
function M.update(simTime, entities, dt)
    local events = {}

    -- 预组满员检查
    for leaderPid, group in pairs(premadeGroups) do
        if group.roles.tank and group.roles.healer and #group.roles.dps >= 3 then
            local dungeonId = group.dungeonId
            formedGroups[dungeonId .. "_" .. simTime] = {
                dungeonId = dungeonId,
                members = group.members,
                ready = false,
                readyCount = 0,
            }
            table.insert(events, {
                type = "dungeon_finder_group_ready",
                dungeonId = dungeonId,
                members = group.members,
            })
            premadeGroups[leaderPid] = nil
        end
    end

    -- 队列匹配
    if #queue >= 5 then
        local tank, healer, dps = nil, nil, {}
        for _, entry in ipairs(queue) do
            if entry.role == ROLE.TANK and not tank then tank = entry
            elseif entry.role == ROLE.HEALER and not healer then healer = entry
            elseif entry.role == ROLE.DPS and #dps < 3 then
                table.insert(dps, entry)
            end
        end

        if tank and healer and #dps >= 3 then
            local members = { tank.pid, healer.pid }
            for _, d in ipairs(dps) do table.insert(members, d.pid) end

            -- 选择地下城
            local avgLevel = 0
            for _, pid in ipairs(members) do
                local p = entities[pid]
                if p then avgLevel = avgLevel + p.level end
            end
            avgLevel = avgLevel / #members

            local dungeonId
            for _, dg in ipairs(DUNGEON_LIST) do
                if avgLevel >= dg.minLevel and avgLevel <= dg.maxLevel then
                    dungeonId = dg.id; break
                end
            end
            if dungeonId then
                formedGroups[dungeonId .. "_" .. simTime] = {
                    dungeonId = dungeonId,
                    members = members,
                    ready = false,
                    readyCount = 0,
                }
                table.insert(events, {
                    type = "dungeon_finder_group_ready",
                    dungeonId = dungeonId,
                    members = members,
                })

                -- 从队列移除
                local toRemove = { tank.pid, healer.pid }
                for _, d in ipairs(dps) do table.insert(toRemove, d.pid) end
                local newQueue = {}
                for _, e in ipairs(queue) do
                    local keep = true
                    for _, rid in ipairs(toRemove) do
                        if e.pid == rid then keep = false end
                    end
                    if keep then table.insert(newQueue, e) end
                end
                queue = newQueue
            end
        end
    end

    return events
end

return M
