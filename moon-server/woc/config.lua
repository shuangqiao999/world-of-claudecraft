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

-- 空间索引: 默认纯 Lua 螺旋网格 (queryRadius 无排序 + 最近优先提前停止, 更快)。
-- C++ aoi 的 query 只返回矩形且无序, 需在 Lua 侧 table.sort 才能补圆距/最近优先,
-- 密集场景反而更慢。设 WOC_AOI_GRID=1 可显式启用 C++ aoi 索引做 A/B 对比。
M.USE_AOI_GRID = os.getenv("WOC_AOI_GRID") == "1"

----------------------------------------
-- 空间分片 (Spatial Sharding)
----------------------------------------
-- 固定网格 region 尺寸 (yd): 270 = 2x AOI 半径 135, 边界 ghost 条带正好 135yd
M.REGION_SIZE = 270
-- ghost 边界同步间隔 (tick): 每 K tick 同步一次边界实体到相邻分片, 客户端插值平滑
M.GHOST_SYNC_INTERVAL_TICKS = 5

-- 实体迁移状态 (Phase 3 预留; 一期不上迁移, 但预留枚举避免后期改结构)
M.MIGRATE_NONE = 0
M.MIGRATE_INBOUND = 1
M.MIGRATE_OUTBOUND = 2

--- region 坐标 (整数格, floor; 负坐标正确)
function M.regionOf(x, z)
    return math.floor(x / M.REGION_SIZE), math.floor(z / M.REGION_SIZE)
end

--- region -> 分片 (确定性整数散列; 打散相邻 region 均衡负载, 避免热点)
function M.regionToShard(rx, rz)
    local n = M.getWorldShards()
    local h = (rx * 2654435761 + rz * 40503) % n
    if h < 0 then h = h + n end
    return h
end

-- 8 邻居偏移 (ghost 同步用)
M.REGION_NEIGHBORS = {
    { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 },
    { 1, 1 }, { 1, -1 }, { -1, 1 }, { -1, -1 },
}

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

--- 检测 CPU 逻辑核数 (缓存; 优先 NUMBER_OF_PROCESSORS 全机总数, moon.cpu() 降为兜底)
-- 注意: moon.cpu() 走 GetSystemInfo().dwNumberOfProcessors, Windows 上返回当前处理器组内的核数;
-- 96 逻辑核 (>64) 会被切成 2 个处理器组, 组内只报 ~32, 导致分片数偏小。NUMBER_OF_PROCESSORS 才是全机总数。
local cachedCpuCount = nil
function M.getCpuCount()
    if cachedCpuCount then return cachedCpuCount end
    local n = nil
    -- WOC_CPU_COUNT 显式覆盖 (部署时兜底)
    n = tonumber(os.getenv("WOC_CPU_COUNT"))
    if not n or n < 1 then
        n = tonumber(os.getenv("NUMBER_OF_PROCESSORS"))
    end
    if not n or n < 1 then
        local ok, mcpu = pcall(function() return require("moon").cpu() end)
        if ok and type(mcpu) == "number" and mcpu > 0 then n = mcpu end
    end
    if not n or n < 1 then
        local f = io.open("/proc/cpuinfo", "r")
        if f then
            local count = 0
            for line in f:lines() do
                if line:match("^processor%s") then count = count + 1 end
            end
            f:close()
            if count > 0 then n = count end
        end
    end
    if not n or n < 1 then n = 4 end
    n = math.max(1, math.min(n, 256))
    cachedCpuCount = n
    return n
end

--- 世界分片数 (自适应: 核心数的一半, 至少 1, 至多 32; 缓存保证各服务 VM 一致)
local cachedShards = nil
function M.getWorldShards()
    if cachedShards then return cachedShards end
    -- 显式覆盖用 WOC_SHARDS (区别于启动器写入的 WOC_WORLD_SHARDS: 后者按处理器组内核数算, 在 >64 核机上偏小)
    local n = tonumber(os.getenv("WOC_SHARDS"))
    if n and n >= 1 then
        cachedShards = n
        return n
    end
    local shards = math.floor(M.getCpuCount() / 2)
    if shards < 1 then shards = 1 end
    if shards > 32 then shards = 32 end
    cachedShards = shards
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
    -- 开发阶段持续启用 dev 命令 (dev_level/dev_teleport/dev_give/dev_target 等), 后续测试常驻。
    -- 上线前需改回 os.getenv("ALLOW_DEV_COMMANDS") == "1" 门控。
    return true
end

M.isProduction = function()
    return os.getenv("NODE_ENV") == "production"
end

return M
