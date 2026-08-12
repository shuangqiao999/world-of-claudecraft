-- World of ClaudeCraft — Gather Node Spawner
-- 从 proto/gather_nodes.json 生成采集节点实体 (TS: {type, pos, level, tier})
-- 额外程序化生成植被 (水果/花朵/草药), 使野外植被更茂密

local M = {}

local spawned = false

-- 程序化植被类型 (按权重分布)
local VEGETATION = {
    { type = "herb", weight = 35 },
    { type = "flower", weight = 30 },
    { type = "fruit", weight = 20 },
    { type = "mushroom", weight = 15 },
}

--- 程序化生成额外植被 (散布在出生点周边 ±48yd)
local function spawnVegetation(entities, gridModule, entityNewFn, allocIdFn, count)
    local rng = require("world.simrng")
    local spawnedCount = 0
    for i = 1, (count or 120) do
        -- 加权选择类型
        local total = 0
        for _, v in ipairs(VEGETATION) do total = total + v.weight end
        local roll = rng.randint(1, total)
        local chosen = VEGETATION[1].type
        local acc = 0
        for _, v in ipairs(VEGETATION) do
            acc = acc + v.weight
            if roll <= acc then chosen = v.type; break end
        end
        local x = rng.randfloat(-48, 48)
        local z = rng.randfloat(-48, 48)
        local tier = rng.randint(1, 3)
        local eid = allocIdFn()
        local e = entityNewFn(eid, "node", chosen, chosen, 1, { x = x, y = 0, z = z })
        e.nodeType = chosen
        e.nodeTier = tier
        e.hostile = false
        entities[eid] = e
        if gridModule then gridModule.insert(e) end
        spawnedCount = spawnedCount + 1
    end
    return spawnedCount
end

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

    -- 程序化植被 (更茂密)
    local vegCount = spawnVegetation(entities, gridModule, entityNewFn, allocIdFn, 150)

    spawned = true
    print(string.format("[GatherNode] Spawned %d proto nodes + %d vegetation", count, vegCount))
end

--- 重置
function M.reset()
    spawned = false
end

return M
