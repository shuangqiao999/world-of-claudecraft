-- World of ClaudeCraft — Mount System
-- 坐骑: 施法/过渡/速度增加
-- 对应原项目 src/sim/sim.ts mount transition logic + content/mounts.ts
-- 坐骑数据从 proto/mounts.json 加载 (moveSpeedPct: 加速分数)

local config = require("config")
local M = {}

local MOUNT_CAST_TIME = 3.0       -- 3 秒施法

-- 可用坐骑 (从 proto 填充)
local MOUNTS = {}
local mountsLoaded = false

--- 从 proto/mounts.json 加载 (TS MountDef: key/name/rarity/moveSpeedPct)
function M.loadFromProto()
    if mountsLoaded then return end
    local ok, proto = pcall(function() return require("proto.load") end)
    if not ok then return end
    local mounts = proto.getMounts()
    if not mounts then return end
    for id, def in pairs(mounts) do
        MOUNTS[id] = {
            id = id,
            name = def.name or id,
            rarity = def.rarity or "common",
            moveSpeedPct = def.moveSpeedPct or 0.6,
            speedMult = 1 + (def.moveSpeedPct or 0.6),
        }
    end
    mountsLoaded = true
    print(string.format("[Mount] Loaded %d mounts from proto", #MOUNTS))
end

--- 坐骑移动速度分数 (TS mountMoveSpeedPct: 加法分数)
function M.mountMoveSpeedPct(mountKey)
    local mount = MOUNTS[mountKey]
    return mount and mount.moveSpeedPct or 0
end

--- 开始召唤坐骑
function M.startMount(e, mountId)
    if e.dead or e.ghost then return false end
    if e.mountCastKey then return false end  -- 已在施法
    if e.mountKey then return false end       -- 已在骑乘

    local mount = MOUNTS[mountId]
    if not mount then return false end
    if not e.ridingTrained then return false end  -- TS: 骑术训练门槛

    e.mountCastKey = mountId
    e.mountCastRemaining = MOUNT_CAST_TIME
    return true
end

--- 取消召唤坐骑
function M.cancelMount(e)
    e.mountCastKey = nil
    e.mountCastRemaining = nil
end

--- 下马
function M.dismount(e)
    e.mountKey = nil
    e.moveSpeed = config.RUN_SPEED
end

--- 更新坐骑过渡 (每个 tick)
function M.update(e, dt, isSwimming)
    -- 坐骑施法
    if e.mountCastKey and e.mountCastRemaining then
        e.mountCastRemaining = e.mountCastRemaining - dt
        if e.mountCastRemaining <= 0 then
            local mountId = e.mountCastKey
            local mount = MOUNTS[mountId]
            e.mountCastKey = nil
            e.mountCastRemaining = nil
            if mount then
                e.mountKey = mountId
                e.moveSpeed = config.RUN_SPEED * mount.speedMult
            end
        end
    end

    -- 游泳/战斗时下马
    if e.mountKey and (isSwimming or e.inCombat) then
        M.dismount(e)
    end
end

--- 获取可用坐骑
function M.getAvailable(e)
    local available = {}
    for id, mount in pairs(MOUNTS) do
        if e.ridingTrained then
            table.insert(available, mount)
        end
    end
    return available
end

return M
