-- World of ClaudeCraft — Mob Lifecycle
-- 出生/死亡/刷新/掉落/社交仇恨 (确定性 RNG)
-- 对应原项目 src/sim/mob/lifecycle.ts + camps.json 分带刷新

local simrng = require("world.simrng")
local M = {}

local spawnData = {}
local campsLoaded = false

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
function M.loadCampsFromProto()
    if campsLoaded then return end
    local ok, proto = pcall(function() return require("proto.load") end)
    if not ok then return end
    local camps = proto.getCamps()
    if not camps then return end

    local count = 0
    for _, camp in ipairs(camps) do
        if camp.mobId and camp.center then
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
                lastRespawn = 0,
                level = camp.level or 1,
            }
            count = count + 1
        end
    end
    campsLoaded = true
    print(string.format("[Mob] Loaded %d spawn camps from proto", count))
end

--- 尝试刷新 mob (tick 检查, 使用确定性 RNG)
function M.checkRespawn(entities, worldInitFn, gridModule, currentTime)
    local spawned = {}

    for key, sd in pairs(spawnData) do
        if sd.count < sd.max and (currentTime - sd.lastRespawn) >= sd.respawnTime then
            -- 营地: 在半径内随机 (TS camp spawn)
            local cx = sd.positions[1].x
            local cz = sd.positions[1].z
            local r = sd.radius or 3
            local ang = simrng.randfloat(0, math.pi * 2)
            local dist = simrng.randfloat(0, r)
            local newPos = {
                x = cx + math.cos(ang) * dist,
                y = 0,
                z = cz + math.sin(ang) * dist,
            }

            local mob = worldInitFn(sd.templateId, sd.templateId, sd.level or 1, newPos)

            if mob then
                sd.count = sd.count + 1
                sd.lastRespawn = currentTime
                table.insert(spawned, mob)
            end
        end
    end

    return spawned
end

--- 记录 mob 死亡
function M.onMobDeath(mobId, entities)
    for key, sd in pairs(spawnData) do
        if sd.count > 0 then
            sd.count = math.max(0, sd.count - 1)
        end
    end
end

--- 获取掉落列表 (确定性 RNG)
function M.getLoot(mob)
    local loot = {}
    local level = mob.level or 1

    local copper = simrng.randint(level * 2, level * 8)
    table.insert(loot, { type = "copper", amount = copper })

    if simrng.random() < 0.3 then
        table.insert(loot, { type = "item", name = "Wolf Pelt", count = 1 })
    end

    return loot
end

--- 社交仇恨: mob 被杀时通知周围 mob
function M.socialAggro(deadMobId, killerId, entities, aiModule)
    local deadMob = entities[deadMobId]
    if not deadMob then return end

    local aggroRange = 25
    local aggroRangeSq = aggroRange * aggroRange

    for id, other in pairs(entities) do
        if other.kind == "mob" and id ~= deadMobId and not other.dead then
            local dx = deadMob.pos.x - other.pos.x
            local dz = deadMob.pos.z - other.pos.z
            if dx * dx + dz * dz <= aggroRangeSq then
                aiModule.setSocialAggro(id, killerId)
            end
        end
    end
end

return M
