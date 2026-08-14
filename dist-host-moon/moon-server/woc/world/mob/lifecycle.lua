-- World of ClaudeCraft — Mob Lifecycle
-- 出生/死亡/刷新/掉落/社交仇恨 (确定性 RNG)
-- 对应原项目 src/sim/mob/lifecycle.ts + camps.json 分带刷新

local simrng = require("world.simrng")
local terrain = require("world.terrain")
local config = require("config")
local M = {}

local spawnData = {}
local campsLoaded = false

-- 内存泄漏诊断计数
local respawnedCount = 0
local deathCount = 0

function M.registerSpawn(zone, templateId, maxCount, respawnSeconds, positions)
    local key = zone .. ":" .. templateId
    spawnData[key] = {
        templateId = templateId,
        count = 0,
        max = maxCount,
        respawnTime = respawnSeconds,
        positions = positions or {{ x = 0, y = 0, z = 0 }},
        lastRespawn = 0,
    }
end

--- 从 proto/camps.json 加载刷新营地 (TS Camps: {mobId, center, radius, count})
-- 空间分片: 只加载本分片 region 内的营地 (region 按营地 center 判定)
function M.loadCampsFromProto(shardId)
    if campsLoaded then return end
    local ok, proto = pcall(function() return require("proto.load") end)
    if not ok then return end
    local camps = proto.getCamps()
    if not camps then return end

    local count = 0
    for _, camp in ipairs(camps) do
        if camp.mobId and camp.center then
            local rx, rz = config.regionOf(camp.center.x or 0, camp.center.z or 0)
            if config.regionToShard(rx, rz) ~= shardId then
                goto continue_camp
            end
            local key = "camp:" .. (count + 1)
            spawnData[key] = {
                templateId = camp.mobId,
                count = 0,
                max = camp.count or 1,
                respawnTime = 15,
                positions = { {
                    x = camp.center.x or 0,
                    z = camp.center.z or 0,
                } },
                radius = camp.radius or 10,
                lastRespawn = -(camp.respawnTime or 15),
                level = camp.level or 1,
            }
            count = count + 1
        end
        ::continue_camp::
    end
    campsLoaded = true
    print(string.format("[Mob] Shard %d: loaded %d spawn camps (region-filtered)", shardId or 0, count))
end

--- 世界启动时一次性填充全部营地 mob (忽略 respawnTime, 确保世界立即有 mob)
function M.fillInitialMobs(entities, worldInitFn, gridModule)
    local spawned = {}
    for key, sd in pairs(spawnData) do
        for _ = 1, sd.max do
            local cx = sd.positions[1].x
            local cz = sd.positions[1].z
            local r = sd.radius or 8
            local ang = simrng.randfloat(0, math.pi * 2)
            local dist = simrng.randfloat(0, r)
            local newPos = { x = cx + math.cos(ang) * dist, y = terrain.placementHeight(cx + math.cos(ang) * dist, cz + math.sin(ang) * dist), z = cz + math.sin(ang) * dist }
            local mob = worldInitFn(sd.templateId, sd.templateId, M._spawnLevel(sd.templateId, sd.level), newPos)
            if mob then
                sd.count = sd.count + 1
                sd.lastRespawn = 0
                table.insert(spawned, mob)
            end
        end
    end
    return spawned
end

--- 尝试刷新 mob (tick 检查, 使用确定性 RNG)
-- 每 tick 最多生成 5 个营地, 避免启动时 207 营地同时创建 700 mob
local MAX_SPAWNS_PER_TICK = 5
local spawnsThisTick = 0

function M.checkRespawn(entities, worldInitFn, gridModule, currentTime)
    local spawned = {}
    spawnsThisTick = 0

    for key, sd in pairs(spawnData) do
        if spawnsThisTick >= MAX_SPAWNS_PER_TICK then break end
        if sd.count < sd.max and (currentTime - sd.lastRespawn) >= sd.respawnTime then
            local cx = sd.positions[1].x
            local cz = sd.positions[1].z
            local r = sd.radius or 3
            local ang = simrng.randfloat(0, math.pi * 2)
            local dist = simrng.randfloat(0, r)
            local newPos = {
                x = cx + math.cos(ang) * dist,
                y = terrain.placementHeight(cx + math.cos(ang) * dist, cz + math.sin(ang) * dist),
                z = cz + math.sin(ang) * dist,
            }
            local mob = worldInitFn(sd.templateId, sd.templateId, M._spawnLevel(sd.templateId, sd.level), newPos)
            if mob then
                sd.count = sd.count + 1
                sd.lastRespawn = currentTime
                respawnedCount = respawnedCount + 1
                table.insert(spawned, mob)
                spawnsThisTick = spawnsThisTick + 1
            end
        end
    end

    return spawned
end

--- 记录 mob 死亡 (按模板 ID 匹配, 只减对应营地计数)
function M.onMobDeath(mobId, entities)
    local mob = entities and entities[mobId]
    if not mob then return end
    deathCount = deathCount + 1
    local tid = mob.templateId
    if not tid then return end
    for key, sd in pairs(spawnData) do
        if sd.templateId == tid and sd.count > 0 then
            sd.count = sd.count - 1
            return
        end
    end
end

--- 从 mobs.json minLevel/maxLevel 随机出生等级 (TS camp spawn)
function M._spawnLevel(templateId, campLevel)
    if campLevel and campLevel > 1 then return campLevel end
    local ok, proto = pcall(function() return require("proto.load") end)
    if ok then
        local tpl = proto.getMob(templateId)
        if tpl and tpl.minLevel then
            local min = tpl.minLevel or 1
            local max = tpl.maxLevel or min
            if max > min then return simrng.randint(min, max) end
            return min
        end
    end
    return campLevel or 1
end

--- 获取掉落列表 (确定性 RNG; 从 proto/mobs.json 模板 loot 数组)
function M.getLoot(mob)
    local loot = {}
    local level = mob.level or 1

    local copper = simrng.randint(level * 2, level * 8)
    table.insert(loot, { type = "copper", amount = copper })

    -- 模板掉落 (TS: mob template loot 数组)
    local tpl = nil
    local ok, proto = pcall(function() return require("proto.load") end)
    if ok then tpl = proto.getMob(mob.templateId) end
    local templateLoot = tpl and tpl.loot or nil
    if templateLoot and type(templateLoot) == "table" then
        for _, entry in ipairs(templateLoot) do
            local chance = entry.chance or 0.5
            if simrng.random() < chance then
                table.insert(loot, {
                    type = "item",
                    itemId = entry.itemId or entry.id,
                    name = entry.name or entry.itemId or "Loot",
                    count = entry.count or 1,
                    rollGroup = entry.rollGroup,
                })
            end
        end
    end

    return loot
end

--- 社交仇恨: 反击式世界下禁用 — 被动怪不再因附近同类被杀而主动围攻玩家
function M.socialAggro(deadMobId, killerId, entities, aiModule)
    return
end

--- 统计生成/死亡计数 (内存诊断)
function M.stats()
    return respawnedCount, deathCount
end

return M
