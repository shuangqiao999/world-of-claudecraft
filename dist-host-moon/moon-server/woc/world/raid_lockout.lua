-- World of ClaudeCraft — Raid Lockout System
-- 团队副本锁定: 每周重置, Boss 击杀记录
-- 对应原项目 src/sim/instances/difficulty.ts (部份)

local M = {}

-- 团队副本 ID 列表
local RAID_DUNGEONS = { "nythraxis_lair" }

-- 锁定状态: { characterId = { dungeonId = lockedUntilTimestamp } }
local lockouts = {}

local RAID_RESET_HOURS = 7 * 24  -- 每周

--- 检查是否被锁定
function M.isLocked(characterId, dungeonId)
    local charLock = lockouts[characterId]
    if not charLock then return false end
    local lock = charLock[dungeonId]
    if not lock then return false end
    return lock > os.time()
end

--- 锁定 (击杀 Boss 后)
function M.lock(characterId, dungeonId)
    if not lockouts[characterId] then
        lockouts[characterId] = {}
    end
    lockouts[characterId][dungeonId] = os.time() + RAID_RESET_HOURS * 3600
end

--- 解锁 (手动 /raid reset)
function M.unlock(characterId, dungeonId)
    if not lockouts[characterId] then return end
    lockouts[characterId][dungeonId] = nil
end

--- 解锁所有
function M.unlockAll(characterId)
    lockouts[characterId] = nil
end

--- 获取剩余锁定时间 (小时)
function M.getRemaining(characterId, dungeonId)
    local charLock = lockouts[characterId]
    if not charLock then return 0 end
    local lock = charLock[dungeonId]
    if not lock then return 0 end
    local remaining = math.max(0, lock - os.time())
    return math.floor(remaining / 3600 + 0.5)
end

return M
