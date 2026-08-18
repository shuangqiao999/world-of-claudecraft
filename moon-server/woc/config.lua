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
-- WS 保活 (对齐 TS server/game.ts WS_KEEPALIVE_PING_MS): 每 30s ping 一次,
-- 上一轮未收到 pong (浏览器自动应答) 即视为黑洞连接并回收, 防止死 socket 累积到拒连
M.WS_KEEPALIVE_PING_MS = 30000
-- 清扫迟到阈值 (对齐 server/keepalive_sweep.ts KEEPALIVE_STALL_FACTOR):
-- 事件循环卡顿导致的迟到清扫不得误踢, 只重新 ping
M.WS_KEEPALIVE_STALL_FACTOR = 1.5
-- 快照下发帧率上限 (gate 层发送节流): world 分片按 20Hz 逐玩家造帧,
-- gate 按此上限下发, 降低单线程 wsWrite 负载。客户端是 delta 合并模型, 跳帧安全。
-- 注: 20Hz 输入 + 非 20Hz 上限会因对齐假象降速 (15Hz 上限实际只发 ~10Hz)。
-- 设为 20 = gate 与 world tick 自然对齐, 下发速度 = world 造帧速度 (低负载满 20Hz,
-- 高负载由 world 造帧天然限速); 事件循环卡顿仍由 SNAP_SEND_HZ_DEGRADED=5 保护。
M.SNAP_SEND_HZ = 20
-- 事件循环卡顿 (keepalive 清扫迟到) 时自动降级到的帧率
M.SNAP_SEND_HZ_DEGRADED = 5
-- Gate P0.3 僵连接回收：连续跳过快照帧数阈值（仅用于日志分级, 不控制断开）
M.GATE_STALLED_SKIP_REAP = 60
-- 多 gate 分片 (P1): gate 实例数 (每个 gate 独立 HTTP/WS 端口 + 独立线程, 分摊 wsWrite)
M.GATE_COUNT = 2
-- 每个 gate 的 pid 取值步长: pid = gateIndex * stride + 本地计数。
-- 必须避开 world 实体 id (shardId*1000000+seq, 最大约 32M) → 100M 起步无冲突;
-- 且 stride % worldShardCount == 0 (100M % 32 == 0), 保证 pid%shards 仍是轮询分片。
M.GATE_PID_STRIDE = 100000000
M.getGateCount = function()
    local n = tonumber(os.getenv("WOC_GATE_COUNT"))
    if n and n >= 1 then return n end
    return M.GATE_COUNT
end

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
M.MAX_VISIBLE_ENTITIES = 25

-- 距离分级更新频率 (仿 TS game.ts FULL/HALF/QUARTER_RATE):
-- 名称牌范围(45yd)内全速, 70yd 内半速, 更远 1/4 速, 降低远处实体广播成本。
-- 观察者的目标 + 正在攻击观察者的实体始终全速 (战斗反馈不能降频)。
M.FULL_RATE_RADIUS_SQ = 45 * 45
M.HALF_RATE_RADIUS_SQ = 70 * 70
M.HALF_RATE_DIVISOR = 2
M.QUARTER_RATE_DIVISOR = 4
-- 快照帧级分频 (P2b): 活跃玩家(战斗/移动)每 N tick 造一帧, 静止玩家每 M tick 造一帧。
-- world 造帧在迁移修复后有余量: active 每 tick 造帧 (低负载由 gate 15Hz 上限截断,
-- 高负载下 tick 速率即造帧速率, 不再被 divisor 减半); idle 每 2 tick (10Hz) 满足静态 ≥7-8Hz。
-- 客户端位置插值兜底视觉平滑, 战斗事件走独立通道不受影响。
M.SNAP_ACTIVE_DIVISOR = 1
M.SNAP_IDLE_DIVISOR = 2

-- 连接限流: 每秒最多放行的新 join 数 (login 风暴保护, 防止瞬间压垮 world 快照广播 + DB 连接池)。
-- 0 = 不限。WOC_JOIN_RATE_LIMIT 可覆盖。
M.JOIN_RATE_LIMIT = tonumber(os.getenv("WOC_JOIN_RATE_LIMIT")) or 150

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
-- 空间迁移开关 (默认开, WOC_DISABLE_MIGRATION=1 可关): 玩家跨过区域边界且稳定停留后
-- 迁到所在 region 的分片, 保证空间一致性 (本地 NPC/战斗)。检测做边界穿越+稳定窗口,
-- 避免"出生点全体合并"与"边界抖动反复重迁"两类性能炸弹。
M.ENABLE_PLAYER_MIGRATION = os.getenv("WOC_DISABLE_MIGRATION") ~= "1"
-- 迁移检测间隔 (tick): 每 20 tick (1s) 评估一次, 不做每 tick region 哈希
M.MIGRATE_CHECK_INTERVAL_TICKS = 20
-- 稳定停留窗口 (秒): 跨入异区域分片后需连续停留这么久才迁移 (防边界抖动)
M.MIGRATE_STABLE_SECONDS = 2
-- 迁移冷却 (秒): 迁移后该时长内不再重迁 (防来回振荡)
M.MIGRATE_COOLDOWN_SECONDS = 15
-- 迁移最小旅行距离 (码): 玩家需离开上次"提交位置"超过此距离才评估迁移。
-- 出生点/原地轻微位移绝不触发迁移 (消除"微小位置扰动触发完整迁移流程"的性能炸弹)。
M.MIGRATE_MIN_TRAVEL = 50
M.MIGRATE_MIN_TRAVEL_SQ = 50 * 50

-- Region 内部内容实体 ghost 同步 (方案 A): 玩家处于异分片 region 内部时,
-- 由该 region 归属分片把内部静态内容实体 (NPC/mob/采集节点/可拾取物) 推送到玩家所在分片。
-- 开关: WOC_ENABLE_REGION_INTERNAL_GHOST=0 可关 (关闭恢复修复前行为)。
M.ENABLE_REGION_INTERNAL_GHOST = os.getenv("WOC_ENABLE_REGION_INTERNAL_GHOST") ~= "0"
-- world 分片逐阶段诊断 (TickDiag/PhaseDiag/[World]), 默认关 (零开销);
-- WOC_ENABLE_WORLD_DIAG=1 开启, 输出到 log/world-diag.log。
M.ENABLE_WORLD_DIAG = os.getenv("WOC_ENABLE_WORLD_DIAG") == "1"
-- 内部 ghost 同步间隔倍率: 普通边界 ghost 间隔 (GHOST_SYNC_INTERVAL_TICKS=5) x 该值
M.GHOST_REGION_INTERNAL_MULT = 3
-- 单个 region 推送给单个远端分片的内部 ghost 最大数量 (截断 + 告警)
M.MAX_REGION_INTERNAL_GHOST = 256
-- presence 降采样间隔 (tick): 每 4 tick 扫一次本分片玩家, 更新 region_remote_map
M.REGION_REMOTE_SCAN_INTERVAL_TICKS = 4

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
-- Leash / 追击
----------------------------------------
M.LEASH_DISTANCE = 45
M.LEASH_DISTANCE_SQ = 2025
-- GTA 追击: 怪物基准最大追击距离 (距仇恨原点/spawn 超过即放弃追杀回巡逻)
M.MONSTER_MAX_CHASE_DIST = 120
-- 随机提前放弃系数下限: 单场追击上限在 [0.7, 1.0] * MAX 区间随机判定 (逃不逃得掉看运气)
M.MONSTER_CHASE_RANDOM_MIN = 0.7
-- PVP 总开关 (全局关闭用于测试)
M.ENABLE_PLAYER_PVP = true
-- PvP 金币掉落配置: 被 PvP 击杀时, 死者身上铜币按比例转入击杀者钱包
M.PVP_COPPER_DROP_RATE = 0.10    -- 掉落比例 10%
M.PVP_COPPER_SAFE_MIN = 500      -- 保护阈值: 身上铜币 ≤500 则一分钱不掉落

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
    if shards > 64 then shards = 64 end
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
    -- 生产模式: dev 命令 (dev_level/dev_teleport/dev_give/dev_target 等) 仅在
    -- 显式设置 ALLOW_DEV_COMMANDS=1 时启用 (默认关闭)。
    return os.getenv("ALLOW_DEV_COMMANDS") == "1"
end

M.isProduction = function()
    return os.getenv("NODE_ENV") == "production"
end

return M
