-- World of ClaudeCraft — Moon Server 主入口
-- 负责创建所有 Service，配置 Moon 运行时
--
-- 启动方式:
--   ./moon woc/main.lua
--
-- 环境变量:
--   WOC_REALM      — Realm 名称 (默认: "Claudemoon")
--   DATABASE_URL   — PostgreSQL 连接串 (默认: postgresql://postgres:postgres@localhost:5433/woc)
--   PORT           — 监听端口 (默认: 8787)
--   ALLOW_DEV_COMMANDS — 启用开发命令 (设为 "1")
--   NODE_ENV       — 环境模式 ("production" 启用生产模式)

----------------------------------------
-- ⚠️ 重要: __init__ 块不能 require moon
-- Moon 先在一个临时 VM 中执行 __init__ 返回配置，
-- 然后将路径等配置应用到正式 VM。因此 require("moon")
-- 必须放在 __init__ 块之后。
----------------------------------------

--- 判断是否为生产环境 (不依赖 moon 模块)
local function isProduction()
    return os.getenv("NODE_ENV") == "production"
end

--- 读取环境变量，带默认值
local function envOr(key, default)
    return os.getenv(key) or default
end

--- 检测 CPU 逻辑核数 (纯 Lua, __init__ 临时 VM 无 package.path 不能 require config/moon)
--- 与 config.getCpuCount 同规则: WOC_CPU_COUNT → NUMBER_OF_PROCESSORS(全机总数) → /proc/cpuinfo → 4
local function cpuCount()
    local n = tonumber(os.getenv("WOC_CPU_COUNT"))
    if not n or n < 1 then n = tonumber(os.getenv("NUMBER_OF_PROCESSORS")) end
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
    return math.max(1, math.min(n, 256))
end

--- 世界分片数 (与 config.getWorldShards 同规则: WOC_SHARDS 覆盖, 否则 floor(cpu/2) 至多 64, 随硬件自适应)
local function worldShards()
    local n = tonumber(os.getenv("WOC_SHARDS"))
    if n and n >= 1 then return n end
    local s = math.floor(cpuCount() / 2)
    if s < 1 then s = 1 end
    if s > 64 then s = 64 end
    return s
end

--- Gate 实例数 (以 config.lua 的 M.GATE_COUNT 为准, 线程数需与之一致; __init__ 临时 VM 无法 require config, 直接解析文件)
local function gateCount()
    local ioLib = io
    if ioLib then
        for _, p in ipairs({ "config.lua", "woc/config.lua", "../woc/config.lua" }) do
            local f = ioLib.open(p, "r")
            if f then
                local s = f:read("*a")
                f:close()
                local n = s and s:match("M%.GATE_COUNT%s*=%s*(%d+)")
                if n and tonumber(n) and tonumber(n) >= 1 then return tonumber(n) end
            end
        end
    end
    return 4
end

----------------------------------------
-- Moon 运行时配置
-- Moon 在启动时创建一个临时 VM，设置 __init__ = true
-- 然后执行此文件，return 的 table 即服务端配置
----------------------------------------
if _G["__init__"] then
    -- 线程数 = 固定服务 5 + 世界分片 + (gate 数-1) (各分片/各 gate 独立线程), 随硬件自适应; WOC_THREADS 可覆盖
    local threads = tonumber(envOr("WOC_THREADS", "")) or (5 + worldShards() + (gateCount() - 1))
    if threads < 5 + worldShards() + (gateCount() - 1) then threads = 5 + worldShards() + (gateCount() - 1) end
    return {
        -- 工作线程数 (自适应: 固定服务 5 + 世界分片)
        thread = threads,

        -- 日志级别: 1=ERROR, 2=WARN, 3=INFO, 4=DEBUG (最低级别只保留 ERROR)
        loglevel = "ERROR",

        -- 启用控制台输出
        enable_stdout = true,

        -- 日志文件
        logfile = "log/woc-server.log",

        -- Lua 内存: 不设上限 (Moon 默认 ssize_t::max), 按实际需求使用内存

        -- Lua 模块搜索路径
        -- Moon 将 CWD 改为此文件所在目录 (woc/)
        -- lualib/ 和 service/ 在父目录下
        -- 必须包含 "lualib/?.lua" 以阻止 Moon 自动添加错误路径
        path = "./?.lua;./?/init.lua"
            .. ";../lualib/?.lua;../lualib/?/init.lua"
            .. ";../service/?.lua",

        -- C 模块搜索路径 (clib/ 在 Moon 根目录下)
        cpath = "../clib/?.dll;../clib/?.so",
    }
end

----------------------------------------
-- 以下是正式服务代码 (此时 package.path 已更新)
----------------------------------------

local moon = require("moon")
local config = require("config")

----------------------------------------
-- 创建所有 Service
----------------------------------------
moon.async(function()
    local realm = config.getRealm()
    local port = config.getPort()

    print("")
    print("========================================")
    print("  World of ClaudeCraft — Moon Server")
    print("========================================")
    print(string.format("  Realm: %s", realm))
    print(string.format("  Port:  %d (HTTP + WS)", port))
    print(string.format("  Dev:   %s", config.getAllowDevCommands() and "ON" or "OFF"))
    print("========================================")
    print("")

    -- 1. DB Service (必须先启动)
    local dbService = moon.new_service({
        name = "db",
        file = "db/init.lua",
        unique = true,
        threadid = 1,
    })
    print(string.format("[Main] DB service created: 0x%X", dbService))

    -- 2. Gate Services (HTTP + WS, 多实例分摊 wsWrite)
    --    每个 gate 独立端口: gate_k HTTP = port+2k, WS = wsPort+2k; 独立线程
    local gateCount = require("config").getGateCount()
    for k = 0, gateCount - 1 do
        local gname = "gate_" .. k
        local sid = moon.new_service({
            name = gname,
            file = "gate/init.lua",
            unique = true,
            threadid = 2 + k,
            gateIndex = k,
            gateCount = gateCount,
        })
        print(string.format("[Main] Gate %s created: 0x%X (thread %d)", gname, sid, 2 + k))
    end

    -- 3. World Services (核心游戏逻辑, 按分片数跨线程并行)
    --    线程布局: 1=db, 2..2+N-1=gate_0..gate_{N-1}, 2+N=social, 3+N=market, 4+N=mail, 5+N..=world shards
    local worldShardCount = require("config").getWorldShards()
    local worldServices = {}
    for i = 0, worldShardCount - 1 do
        local name = "world_" .. i
        local sid = moon.new_service({
            name = name,
            file = "world/init.lua",
            unique = true,
            threadid = 5 + gateCount + i,
            shardId = i,
            shardCount = worldShardCount,
        })
        worldServices[i] = sid
        print(string.format("[Main] World shard %s created: 0x%X (thread %d)", name, sid, 5 + gateCount + i))
    end
    -- 世界分片数查询统一走 config.getWorldShards() (各服务 VM 独立, moon.exports 不跨服务)
    print(string.format("[Main] World shards: %d (adaptive, cpu=%d)", worldShardCount, require("config").getCpuCount()))

    -- 5. Social Service
    local socialService = moon.new_service({
        name = "social",
        file = "social/init.lua",
        unique = true,
        threadid = 2 + gateCount,
    })
    print(string.format("[Main] Social service created: 0x%X", socialService))

    -- 6. Market Service
    local marketService = moon.new_service({
        name = "market",
        file = "market/init.lua",
        unique = true,
        threadid = 3 + gateCount,
    })
    print(string.format("[Main] Market service created: 0x%X", marketService))

    -- 7. Mail Service
    local mailService = moon.new_service({
        name = "mail",
        file = "mail/init.lua",
        unique = true,
        threadid = 4 + gateCount,
    })
    print(string.format("[Main] Mail service created: 0x%X", mailService))

    print("")
    print("[Main] All services started. Server is running.")
    print("[Main] Press Ctrl+C to stop.")
end)

----------------------------------------
-- 优雅关闭
----------------------------------------
moon.shutdown(function()
    print("[Main] Shutting down...")
    local services = { "mail", "market", "social", "db" }
    -- gate 实例
    for k = 0, (require("config").getGateCount() - 1) do
        table.insert(services, "gate_" .. k)
    end
    -- 世界分片
    for i = 0, (require("config").getWorldShards() - 1) do
        table.insert(services, "world_" .. i)
    end
    for _, name in ipairs(services) do
        local sid = moon.queryservice(name)
        if sid then
            print(string.format("[Main] Stopping %s (0x%X)...", name, sid))
            moon.kill(sid)
        end
    end
    moon.quit()
end)
