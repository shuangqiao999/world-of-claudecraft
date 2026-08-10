-- World of ClaudeCraft — Gather Node Spawner
-- 从 proto/gather_nodes.json 生成采集节点实体 (TS: {type, pos, level, tier})

local M = {}

local spawned = false

--- 生成全部采集节点实体 (world 启动时调用一次)
--- @param entities table
--- @param gridModule table
--- @param entityNewFn function
--- @param allocIdFn function
function M.spawnAll(entities, gridModule, entityNewFn, allocIdFn)
    if spawned then return end
    local ok, proto = pcall(function() return require("proto.load") end)
    if not ok then return end
    local nodes = proto.getGatherNodes()
    if not nodes then return end

    local count = 0
    for _, node in ipairs(nodes) do
        if node.pos then
            local eid = allocIdFn()
            local e = entityNewFn(eid, "node", node.type or "herb", node.type or "Gathering Node", node.level or 1, {
                x = node.pos.x or 0, y = 0, z = node.pos.z or 0,
            })
            e.nodeType = node.type or "herb"
            e.nodeTier = node.tier or 1
            e.nodeZoneId = node.zoneId
            e.hostile = false
            entities[eid] = e
            if gridModule then gridModule.insert(e) end
            count = count + 1
        end
    end
    spawned = true
    print(string.format("[GatherNode] Spawned %d nodes", count))
end

--- 重置
function M.reset()
    spawned = false
end

return M
