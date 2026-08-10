-- World of ClaudeCraft — Door/Portal Triggers
-- 对应原项目 src/sim/instances/dungeons.ts door triggers + sim.ts updateDoorTriggers
-- 玩家靠近 dungeon doorPos 时触发进入

local config = require("config")
local M = {}

local DOOR_TRIGGER_RADIUS = 6

-- 缓存 dungeon 门位置: { {id, name, doorPos{x,z}, entry{x,z}} }
local doors = {}

--- 从 proto/dungeons.json 加载门 (world 启动时调用)
function M.loadDoors()
    doors = {}
    local ok, proto = pcall(function() return require("proto.load") end)
    if not ok then return end
    proto.load()
    local dungeons = proto.getDungeons and proto.getDungeons() or proto.dungeons
    if not dungeons then return end
    for id, dg in pairs(dungeons) do
        if dg.doorPos then
            table.insert(doors, {
                id = id,
                name = dg.name or id,
                doorPos = dg.doorPos,
                entry = dg.entry or { x = 0, z = -2 },
                exitOffset = dg.exitOffset or { x = 0, z = -6 },
            })
        end
    end
    print(string.format("[Doors] Loaded %d dungeon doors", #doors))
end

--- 玩家经过门时触发 (TS updateDoorTriggers)
--- @return table 事件列表
function M.checkPlayerDoors(e, entities, players, simTime)
    if not e or e.kind ~= "player" then return {} end
    if e.dead then return {} end
    if e.dungeonId then return {} end  -- 已在副本内

    local events = {}
    for _, door in ipairs(doors) do
        local dx = e.pos.x - door.doorPos.x
        local dz = e.pos.z - door.doorPos.z
        local distSq = dx * dx + dz * dz
        if distSq <= DOOR_TRIGGER_RADIUS * DOOR_TRIGGER_RADIUS then
            -- 进入副本
            e.dungeonId = door.id
            e.oldPos = { x = e.pos.x, y = e.pos.y, z = e.pos.z }
            e.pos.x = door.entry.x
            e.pos.z = door.entry.z
            -- 注册副本内部碰撞体 (TS dungeon_layout)
            local interior = M._interiorForDungeon(door.id)
            if interior then
                require("world.dungeon_colliders").registerInterior(interior, door.entry.x, door.entry.z)
            end
            table.insert(events, {
                type = "enter_dungeon",
                pid = e.id,
                dungeonId = door.id,
                name = door.name,
            })
            print(string.format("[Door] pid=%d entered %s", e.id, door.id))
            break
        end
    end
    return events
end

--- 离开副本 (TS: 出口偏移)
function M.exitDungeon(e)
    if not e.dungeonId then return {} end
    local door
    for _, d in ipairs(doors) do
        if d.id == e.dungeonId then door = d; break end
    end
    if not door then e.dungeonId = nil; return {} end
    -- 清除实例内碰撞体
    require("world.dungeon_colliders").clearInterior()
    e.pos.x = door.doorPos.x + (door.exitOffset.x or 0)
    e.pos.z = door.doorPos.z + (door.exitOffset.z or 0)
    e.dungeonId = nil
    return {{ type = "leave_dungeon", pid = e.id }}
end

--- 副本 → interior 类型 (TS DungeonDef.interior)
function M._interiorForDungeon(dungeonId)
    local ok, proto = pcall(function() return require("proto.load") end)
    if not ok then return nil end
    local dg = proto.getDungeon(dungeonId)
    return dg and dg.interior or nil
end

return M
