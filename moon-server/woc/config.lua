-- World of ClaudeCraft — 全局配置常量
-- 对应原项目 server/http/config.ts + src/sim/types.ts
local M = {}

-- Lua 标准库不提供 math.round (Lua 5.4 无此函数); 提供兼容 polyfill
if not math.round then
    math.round = function(x) return math.floor(x + 0.5) end
end

----------------------------------------
-- 网络
----------------------------------------
M.DEFAULT_PORT = 8787
M.WS_MAX_PAYLOAD = 16384
M.AUTH_TIMEOUT_MS = 10000

----------------------------------------
-- 仿真
----------------------------------------
-- 20Hz tick, DT = 1/20 (与客户端 src/sim/types.ts TICK_RATE=20 对齐)
M.TICK_RATE = 20
M.DT = 1 / 20
M.GCD = 1.5
M.RUN_SPEED = 7
M.MELEE_RANGE = 5
M.MELEE_RANGE_SQ = 25
M.SWEPT_SPHERE_RADIUS = 0.4

----------------------------------------
-- 世界种子 (与客户端 src/sim/world_seed.ts WORLD_SEED 一致)
----------------------------------------
M.WORLD_SEED = 20061
-- 预计算高度表偏移 (0 = 使用 heightmap terrain 值, 不再加额外偏移)
M.TERRAIN_Y_OFFSET = 0

----------------------------------------
-- 兴趣裁剪 (Interest Management)
----------------------------------------
M.INTEREST_RADIUS = 90
M.INTEREST_DROP_RADIUS = 100
M.INTEREST_DROP_RADIUS_SQ = 10000
M.NPC_INTEREST_RADIUS = 120
M.NPC_DROP_RADIUS = 130
M.NPC_DROP_RADIUS_SQ = 16900
M.BG_MATCH_INTEREST_RADIUS = 300
M.BG_MATCH_DROP_RADIUS = 320
M.INTEREST_QUERY_RADIUS = 135
-- AOI 上限: 每玩家每 tick 最多广播的可见实体数 (按距离升序保留最近 N 个),
-- 掐死 O(n²) 聚集场景 (城镇枢纽/世界Boss/PvP活动)
M.MAX_VISIBLE_ENTITIES = 40

-- 距离分级更新频率 (仿 TS game.ts FULL/HALF/QUARTER_RATE):
-- 名称牌范围(55yd)内全速, 80yd 内半速, 更远 1/4 速, 降低远处实体广播成本。
-- 观察者的目标 + 正在攻击观察者的实体始终全速 (战斗反馈不能降频)。
M.FULL_RATE_RADIUS_SQ = 55 * 55
M.HALF_RATE_RADIUS_SQ = 80 * 80
M.HALF_RATE_DIVISOR = 2
M.QUARTER_RATE_DIVISOR = 4

----------------------------------------
-- 玩家限制
----------------------------------------
M.MAX_PLAYERS_PER_REALM = 5000
M.MAX_WS_PER_IP_HARD = 20

----------------------------------------
-- 保存
----------------------------------------
M.AUTOSAVE_SECONDS = 30
M.SAVE_CONCURRENCY = 4

----------------------------------------
-- 断线
----------------------------------------
M.LINKDEAD_GRACE_MS = 300000

----------------------------------------
-- 输入频率
----------------------------------------
M.INPUT_SEND_TIMER_INTERVAL_MS = 50
M.MSG_RATE_REFILL_PER_SECOND = 120
M.MSG_RATE_BURST = 180

----------------------------------------
-- Leash
----------------------------------------
M.LEASH_DISTANCE = 45
M.LEASH_DISTANCE_SQ = 2025

----------------------------------------
-- 等级
----------------------------------------
M.MAX_LEVEL = 20

----------------------------------------
-- 稳定版本号
----------------------------------------
M.ONLINE_WORLD_LAYOUT_VERSION = 5
M.STABLE_TIMER_WIRE_VERSION = 2
M.ONLINE_WORLD_AUTH_TYPE = "auth-world-5"

----------------------------------------
-- 账号
----------------------------------------
M.MIN_USERNAME_LENGTH = 3
M.MAX_USERNAME_LENGTH = 24
M.MIN_PASSWORD_LENGTH = 6
M.MAX_PASSWORD_LENGTH = 128
M.AUTH_TOKEN_TTL_HOURS = 24 * 7

----------------------------------------
-- Lease
----------------------------------------
M.LEASE_TTL_SECONDS = 90

----------------------------------------
-- 密码哈希 (scrypt)
----------------------------------------
M.SCRYPT_N = 16384
M.SCRYPT_R = 8
M.SCRYPT_P = 1
M.SCRYPT_KEYLEN = 64
M.SCRYPT_SALT_LEN = 16

----------------------------------------
-- 运行时 (从环境变量读取)
----------------------------------------
M.getRealm = function()
    return os.getenv("WOC_REALM") or "Claudemoon"
end

M.getDatabaseUrl = function()
    return os.getenv("DATABASE_URL") or "postgres://eastbrook:e20182a19889fa1a33e8593b66f0c042bf8d3c1de3554a01@127.0.0.1:5433/postgres"
end

M.getDbPoolSize = function()
    local n = tonumber(os.getenv("DB_POOL_SIZE")) or tonumber(os.getenv("DB_POOL_MAX_CLIENTS"))
    if n and n >= 1 then return n end
    -- 自适应: 按 CPU 核数扩池, 覆盖 5000 人登录/自动保存的峰值并发
    local p = math.max(8, math.min(M.getCpuCount() * 4, 64))
    return p
end

--- 检测 CPU 逻辑核数 (纯 Lua, 无 moon 依赖, __init__ 阶段可用)
function M.getCpuCount()
    local n = tonumber(os.getenv("NUMBER_OF_PROCESSORS"))
    if n and n > 0 then return n end
    local f = io.open("/proc/cpuinfo", "r")
    if f then
        local count = 0
        for line in f:lines() do
            if line:match("^processor%s") then count = count + 1 end
        end
        f:close()
        if count > 0 then return count end
    end
    return 4
end

--- 世界分片数 (自适应: 核心数的一半, 至少 1, 至多 32)
--- 每分片完整复制世界(NPC/怪/路人+高度表), 分片越多内存/世界逻辑开销越大。
--- 分片是静态玩家分片 (pid % N), 跨分片不可见 (压测够用; 真跨分片可见需空间分片+AOI迁移)。
function M.getWorldShards()
    local n = tonumber(os.getenv("WOC_WORLD_SHARDS"))
    if n and n >= 1 then return n end
    local shards = math.floor(M.getCpuCount() / 2)
    if shards < 1 then shards = 1 end
    if shards > 32 then shards = 32 end
    return shards
end

--- 总工作线程数 (5 个固定服务 db/gate/social/market/mail + 世界分片; WOC_THREADS 可覆盖)
function M.getThreadCount()
    local n = tonumber(os.getenv("WOC_THREADS"))
    if n and n >= 1 then return n end
    return 5 + M.getWorldShards()
end

M.getPort = function()
    return tonumber(os.getenv("PORT") or tostring(M.DEFAULT_PORT))
end

M.getAllowDevCommands = function()
    return os.getenv("ALLOW_DEV_COMMANDS") == "1"
end

M.isProduction = function()
    return os.getenv("NODE_ENV") == "production"
end

return M
