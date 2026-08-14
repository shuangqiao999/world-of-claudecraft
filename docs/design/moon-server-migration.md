# Moon 适配 World of ClaudeCraft 服务端 — 完整迁移设计

> **状态**: 设计阶段  
> **目标**: 用 [Moon](https://github.com/sniper00/moon) 框架完全替代原 Node.js/TypeScript 服务端，客户端零改动  
> **预计总工期**: 10–16 周（取决于开发者数量）

---

## 目录

1. [目标与不变量](#1-目标与不变量)
2. [项目对比总结](#2-项目对比总结)
3. [架构设计](#3-架构设计)
4. [目录结构](#4-目录结构)
5. [通信协议适配](#5-通信协议适配)
6. [认证流程](#6-认证流程)
7. [数据库与持久化](#7-数据库与持久化)
8. [游戏逻辑 Lua 重写范围](#8-游戏逻辑-lua-重写范围)
9. [关键配置常量](#9-关键配置常量)
10. [实施阶段](#10-实施阶段)
11. [关键技术风险与缓解](#11-关键技术风险与缓解)
12. [开放问题](#12-开放问题)
13. [附录](#13-附录)

---

## 1. 目标与不变量

### 目标

用 Moon 框架（C++ 核心 + Lua 游戏逻辑）重写 World of ClaudeCraft 的服务端，完全替换现有的 Node.js/TypeScript 服务器。

### 硬性不变量

| 不变量 | 详情 |
|--------|------|
| **客户端零改动** | 协议格式、端口号、字段名、消息类型全部照旧 |
| **WebSocket + JSON** | 传输层不变，端口 **8787** |
| **20Hz tick** | 仿真步长 50ms (`DT = 1/20`) |
| **确定性仿真** | 相同的种子产生相同的世界状态 |
| **PostgreSQL 兼容** | 直接复用原 `characters`、`accounts`、`auth_tokens` 等表结构 |

---

## 2. 项目对比总结

### 2.1 原项目（World of ClaudeCraft）

| 维度 | 详情 |
|------|------|
| **语言** | TypeScript (Node.js) |
| **架构** | 单体进程 — 一个 `GameServer` 掌管 `Sim` + 网络 + 持久化 |
| **传输** | `ws` 库做 WebSocket，JSON 序列化 |
| **端口** | 8787（HTTP + WS 同一端口） |
| **仿真** | `src/sim/` 确定性仿真，同代码在浏览器/RL 中也运行 |
| **数据库** | PostgreSQL，角色状态存为单个 JSONB 列 |
| **游戏逻辑** | ~20,000+ 行 TypeScript，170+ 命令类型 |
| **快照系统** | Delta 编码 + 兴趣裁剪 + Worker 线程并行 |
| **认证** | scrypt 密码哈希 + 64-hex Bearer Token |

### 2.2 Moon 框架

| 维度 | 详情 |
|------|------|
| **语言** | C++23 核心 + Lua 5.4 游戏逻辑 |
| **架构** | Actor 模型 — 单进程多线程，每个线程上运行多个 Lua VM (Service) |
| **通信** | Service 间消息传递 (`PTYPE_LUA`)；外部支持 TCP/UDP/KCP/WebSocket/HTTP |
| **传输协议** | MoonSocket (2-byte 长度前缀二进制) + WebSocket + HTTP |
| **数据库** | 内置 async 驱动 (Redis / PostgreSQL / MySQL / MongoDB) |
| **网络库** | ASIO (standalone) |
| **其他** | 协程定时器、热重载、Recast/Detour 寻路、protobuf、yyjson |

### 2.3 关键适配点

| 原项目 | Moon 适配方式 | 难度 |
|--------|-------------|------|
| WebSocket + JSON | Moon 原生 `PTYPE_SOCKET_WS` + `yyjson` | 低 |
| HTTP REST (auth) | Moon 内置 HTTP 服务器 | 低 |
| PostgreSQL | Moon `moon.db.pg` 驱动 | 低 |
| TypeScript 游戏逻辑 | Lua 逐系统重写 | 极高 |
| 快照 Delta 编码 | Lua 实现相同逻辑 | 高 |
| 兴趣裁剪 (grid query) | 用 Lua table 实现空间网格 | 中 |
| 消息速率限制 | Lua 实现 token bucket | 低 |
| 确定性 RNG (mulberry32) | Lua 实现相同 PRNG | 低 |

---

## 3. 架构设计

### 3.1 Service 拓扑图

```
                          ┌──────────────────┐
                          │   HTTP Auth       │  POST /api/login
                          │   Service (:8787) │  POST /api/register
                          └────────┬─────────┘  GET /api/characters
                                   │
                                   │ 返回 Bearer Token (64-hex)
                                   ▼
 ┌──────────────┐   WebSocket     ┌──────────────────┐   PTYPE_LUA    ┌──────────────────┐
 │   Browser    │ ◄─── JSON ────► │      Gate        │ ◄────────────► │     World        │
 │   Client     │    :8787/ws     │    Service        │               │    Service        │
 └──────────────┘                 │                   │               │                   │
                                  │ sessions[fd] → {  │               │ entities[id] → {}│
                                  │   pid, accountId, │               │ players[id] → {} │
                                  │   characterId,    │               │ 20Hz tick loop    │
                                  │   name, cls,      │               │ combat, ai, quest │
                                  │   lastSent,       │               │ inventory, talent │
                                  │   seenEntities,   │               └────────┬─────────┘
                                  │   inputSeq,       │                        │
                                  │   linkdeadTimer   │               PTYPE_LUA │
                                  │ }                 │                        │
                                  └────────┬──────────┘               ┌───────┴─────────┐
                                           │                          │                 │
                                  PTYPE_LUA│                 PTYPE_LUA│        PTYPE_LUA│
                                           ▼                          ▼                 ▼
                                  ┌──────────────────┐  ┌──────────────────┐  ┌──────────────────┐
                                  │     Social       │  │    Market        │  │      Mail        │
                                  │     Service      │  │    Service       │  │     Service      │
                                  │                  │  │                  │  │                  │
                                  │ friendships      │  │ listings[]       │  │ inbox[]          │
                                  │ guilds           │  │ search index     │  │ delivery queue    │
                                  │ parties          │  └────────┬─────────┘  └────────┬─────────┘
                                  │ ignores/blocks   │           │                     │
                                  └────────┬─────────┘           │                     │
                                           │                     │                     │
                                  PTYPE_LUA│            PTYPE_LUA│            PTYPE_LUA│
                                           ▼                     ▼                     ▼
                                  ┌──────────────────────────────────────────────────────────┐
                                  │                        DB Service                         │
                                  │                                                                   │
                                  │  PostgreSQL: accounts, characters, world_state, auth_tokens,     │
                                  │  character_leases, friendships, guilds, chat_logs, etc.          │
                                  │                                                                   │
                                  │  Autosave: 30s interval | LeaveSave: atomic transaction         │
                                  └──────────────────────────────────────────────────────────────────┘
```

### 3.2 Service 详细职责

#### Gate Service (`woc/gate/init.lua`)

- **连接管理**: 监听 8787 端口 WebSocket，维护 `fd → session` 映射
- **认证握手**: 解析首个帧 `{t:"auth-world-5"}`, 验证 token, 查询角色, 获取 lease
- **消息路由**: 按 `msg.t` 分发到对应处理函数
- **频率限制**: Token bucket — movement lane (120rps)/command lane (120rps)/chat lane
- **快照广播**: 每个 tick 后向所有已连接的 fd 发送 snap 帧
- **事件帧**: 将 World service 产生的事件列表组装为 `{t:"events"}` 帧发送
- **错误处理**: 发送 `{t:"error"}` 帧并关闭连接
- **Linkdead**: 断线后保持 session 5 分钟，允许重连恢复

**内部状态**:
```lua
-- sessions: table<fd, Session>
Session = {
    fd,               -- WebSocket fd
    ws,               -- 连接对象
    pid,              -- 玩家实体 id
    accountId,
    accountCosmetics,
    characterId,
    name,
    cls,
    chatMutedUntil,
    chatStrikes,
    blockedIds,       -- Set<characterId>
    ignoredIds,       -- Set<characterId>
    initialHotbarLayout,
    spectating,       -- false | pid
    lastSnap,
    snapSentAt,
    lastInputSeq,
    lastSent,         -- 上次发送的 self 扩展字段值（delta 比较用）
    seenEntities,     -- 已发送过 full record 的 entity id set
    lastInputAt,
    leaseNonce,
    awaitingPong,
    jailReason,
    jailed,
    botTrackingContext,
    -- 30+ more fields...
}
```

#### World Service (`woc/world/init.lua`)

- **主循环**: 20Hz tick (`moon.timeout` 每 50ms 一次)
- **实体管理**: 创建/查询/更新/删除所有游戏实体（玩家/NPC/物品/宠物/节点）
- **战斗系统**: 伤害/治疗/施法/GCD/冷却/光环/CC/自动攻击
- **Mob AI**: 仇恨/索敌/技能使用/移动/刷新
- **移动**: 输入处理 + 物理碰撞（swept sphere）
- **任务**: 接受/完成/放弃/追踪/条件检查
- **天赋**: 分配/切换/配置保存
- **物品系统**: 背包/装备/使用/商店/银行
- **交易/决斗/竞技场/战场/副本/deep学习**
- **专业**: 采集/制造/附魔/分解
- **宠物/坐骑/成就**
- **角色序列化**: `serializeCharacter(pid) → table → JSONB`
- **快照构建**: 为每个玩家生成 `self` + `ents` + `keep` + `rings` 数据

**内部状态**:
```lua
-- entities: table<id, Entity>
-- players: table<id, PlayerMeta>
-- space grid: 空间索引用于兴趣查询
-- zone instances: 副本/deep学习实例
```

#### Social Service (`woc/social/init.lua`)

- 好友/黑名单/屏蔽 CRUD
- 公会创建/加入/退出/晋升/降级/解散
- 组队邀请/接受/踢人/升职/转团队
- 公会银行 (通过 World service 操作实际物品，Social service 管理权限)
- 聊天记录持久化

#### Market Service (`woc/market/init.lua`)

- 拍卖行搜索/上架/下架/购买/收款
- 价格排序和分页
- 与 DB service 通信进行世界状态持久化

#### Mail Service (`woc/mail/init.lua`)

- 邮件发送/收取/删除/已读标记
- 金币/物品附件传输
- 30天自动删除

#### DB Service (`woc/db/init.lua`)

- PostgreSQL 连接池管理
- 所有 SQL 封装为 Lua 函数
- 角色状态 save/load（JSONB 序列化/反序列化）
- Lease 管理（获取/心跳/释放）
- 世界状态（market/mail/rifts）的读写

#### HTTP Auth Service (`woc/http/init.lua`)

- `POST /api/register` — scrypt 密码哈希 + 插入 accounts
- `POST /api/login` — 密码验证 + 生成 64-hex token + TOTP 2FA
- `GET /api/characters` — 查询账户的角色列表
- `GET /api/realms` — 服务器目录
- `GET /api/status` — 在线人数/上限
- `GET /api/leaderboard` — 排行榜
- Turnstile (Cloudflare) 验证（通过 HTTP 调用外部 API）

---

## 4. 目录结构

```
moon/
├── woc/                                    # World of ClaudeCraft 游戏逻辑
│   ├── main.lua                            # 入口文件：创建 service，返回 __init__ 配置
│   ├── config.lua                          # 全局常量定义
│   │
│   ├── gate/                               # Gate Service (WS 连接管理 + 消息路由)
│   │   ├── init.lua                        # service 入口：socket 监听、消息 dispatch
│   │   ├── auth.lua                        # 握手认证逻辑
│   │   ├── session.lua                     # 会话生命周期 (创建/销毁/查找)
│   │   ├── rate_limit.lua                 # Token bucket 频率限制
│   │   └── broadcast.lua                  # 快照/事件帧广播
│   │
│   ├── world/                              # World Service (核心仿真)
│   │   ├── init.lua                        # 主文件：API dispatch, tick 循环
│   │   ├── entity.lua                      # 实体 CRUD
│   │   ├── player.lua                      # 玩家登录/登出/序列化
│   │   ├── movement.lua                    # 移动输入 + 碰撞检测
│   │   ├── grid.lua                        # 空间网格（兴趣查询）
│   │   ├── rng.lua                         # mulberry32 确定性 PRNG
│   │   │
│   │   ├── combat/                         # 战斗系统
│   │   │   ├── damage.lua                  # 伤害公式（近战/远程/法系）
│   │   │   ├── heal.lua                    # 治疗公式
│   │   │   ├── cast.lua                    # 施法/GCD/冷却/资源消耗
│   │   │   ├── aura.lua                    # Buff/Debuff/CC 生命周期
│   │   │   ├── auto_attack.lua             # 自动攻击 swing timer
│   │   │   ├── effect_dispatch.lua         # 技能效果分发
│   │   │   ├── equip_procs.lua             # 装备触发效果
│   │   │   └── cc.lua                      # 移动限制/晕眩/定身
│   │   │
│   │   ├── mob/                            # Mob 系统
│   │   │   ├── ai.lua                      # 行动树/索敌逻辑
│   │   │   ├── targeting.lua               # 仇恨表 + 目标选择
│   │   │   ├── combat_profile.lua          # 技能表/战斗配置
│   │   │   ├── locomotion.lua              # 移动路径/巡逻
│   │   │   ├── social_aggro.lua            # 社交仇恨（同伴呼救）
│   │   │   ├── lifecycle.lua               # 刷新/死亡/掉落
│   │   │   └── threat.lua                  # 仇恨表操作
│   │   │
│   │   ├── inventory.lua                   # 背包/物品实例
│   │   ├── equipment.lua                   # 装备系统
│   │   ├── bank.lua                        # 个人银行
│   │   ├── vendor.lua                      # NPC 商店 buy/sell/buyback
│   │   ├── quest.lua                       # 任务系统（接受/完成/放弃/条件）
│   │   ├── talent.lua                      # 天赋/loadout
│   │   ├── prestige.lua                    # 声望等级
│   │   │
│   │   ├── profession/                     # 专业系统
│   │   │   ├── gathering.lua               # 采集（挖矿/采草/剥皮）
│   │   │   ├── crafting.lua                # 制造
│   │   │   ├── enchanting.lua              # 附魔
│   │   │   ├── salvaging.lua               # 分解
│   │   │   ├── disenchant.lua              # 拆解
│   │   │   └── commission.lua              # 佣金订单
│   │   │
│   │   ├── pet.lua                         # 宠物系统（捉/养/指令/模式）
│   │   ├── mount.lua                       # 坐骑/骑术/赛马
│   │   ├── deed.lua                        # 成就/头衔
│   │   ├── spirit.lua                      # 死亡/鬼魂/复活
│   │   │
│   │   ├── social/                         # 社交子系统（与 Social service 交互）
│   │   │   ├── trade.lua                   # 交易
│   │   │   ├── duel.lua                    # 决斗
│   │   │   ├── arena.lua                   # 竞技场
│   │   │   ├── battleground.lua            # 战场/CTF
│   │   │   ├── dungeon_finder.lua          # 寻找地下城
│   │   │   └── vale_cup.lua                # Vale Cup (Boarball)
│   │   │
│   │   ├── instance/                       # 实例系统
│   │   │   ├── dungeon.lua                 # 副本（进入/离开/难度）
│   │   │   └── delve.lua                   # deep学习（选层/祝福/同伴/锁开锁）
│   │   │
│   │   ├── chat.lua                        # 聊天分发 + 脏词过滤
│   │   ├── world_boss.lua                  # 世界 Boss
│   │   ├── rift.lua                        # Rift 传送门/升级/附魔/插宝石
│   │   ├── dev_commands.lua                # 开发命令（受 ALLOW_DEV_COMMANDS 控制）
│   │   │
│   │   └── snapshot.lua                    # 快照构建器（entity → 快照 JSON）
│   │
│   ├── social/                             # Social Service
│   │   ├── init.lua
│   │   ├── friend.lua
│   │   ├── block.lua
│   │   ├── guild.lua
│   │   ├── party.lua
│   │   └── guild_bank.lua
│   │
│   ├── market/                             # Market Service
│   │   └── init.lua                        # 拍卖行全部逻辑
│   │
│   ├── mail/                               # Mail Service
│   │   └── init.lua                        # 邮件全部逻辑
│   │
│   ├── db/                                 # DB Service
│   │   ├── init.lua
│   │   ├── account.lua                     # 账号 CRUD
│   │   ├── auth.lua                        # Token 管理
│   │   ├── character.lua                   # 角色 save/load/lease
│   │   ├── world_state.lua                 # 世界状态（market/mail/rifts）
│   │   └── social_db.lua                   # 好友/公会/黑名单
│   │
│   ├── http/                               # HTTP Auth Service
│   │   ├── init.lua                        # HTTP 路由注册
│   │   ├── routes_auth.lua                 # /api/login, /api/register
│   │   ├── routes_characters.lua           # /api/characters
│   │   └── routes_misc.lua                 # /api/status, /api/realms, etc.
│   │
│   ├── proto/                              # 静态内容数据表
│   │   ├── load.lua                        # 加载所有数据表
│   │   ├── abilities.lua                   # 9 职业 × 所有技能
│   │   ├── items.lua                       # 所有物品定义
│   │   ├── classes.lua                     # 职业基础属性
│   │   ├── zones.lua                       # 区域/子区域
│   │   ├── dungeons.lua                    # 副本定义
│   │   ├── delves.lua                      # deep学习定义
│   │   ├── quests.lua                      # 所有任务定义
│   │   ├── recipes.lua                     # 制造配方
│   │   ├── enchants.lua                    # 附魔定义
│   │   ├── talents.lua                     # 9 职业天赋树
│   │   ├── mobs.lua                        # Mob 模板数据
│   │   ├── deeds.lua                       # 成就定义
│   │   ├── nodes.lua                       # 采集节点
│   │   └── mounts.lua                      # 坐骑定义
│   │
│   └── shared/                             # 跨 Service 共享定义
│       ├── command_names.lua               # COMMAND_NAMES 枚举（170+ 命令）
│       ├── message_types.lua               # PTYPE 常量、事件类型枚举
│       └── json_helpers.lua                # JSON 编码辅助函数
│
├── lualib/                                 # Moon 标准 Lua 库（不动）
├── service/                                # Moon 标准 service（不动）
└── third/                                  # Moon 第三方库（不动）
```

---

## 5. 通信协议适配

### 5.1 WebSocket 层

Moon 原生支持 WebSocket (`moon.PTYPE_SOCKET_WS`)，可以直接接收客户端的 JSON 消息。

```lua
-- gate/init.lua
local socket = require("moon.socket")
local json = require("moon.json")
local auth = require("gate.auth")
local cmd = require("gate.command_router")
local input_handler = require("gate.input_handler")

local M = {}

function M.on_accept(fd, addr)
    -- 客户端已建立 WebSocket 连接，等待首帧认证
    print(string.format("[Gate] WS accepted fd=%d from %s", fd, addr))
end

function M.on_message(fd, raw)
    local ok, msg = pcall(json.decode, raw)
    if not ok then
        socket.write(fd, json.encode({ t = "error", error = "bad auth message" }))
        socket.close(fd)
        return
    end

    local t = msg.t

    if t == "auth-world-5" then
        auth.handle_auth(fd, msg)
    elseif t == "input" then
        input_handler.handle(fd, msg)
    elseif t == "cmd" then
        cmd.handle(fd, msg)
    elseif t == "logout" then
        auth.handle_logout(fd)
    else
        -- 未知消息类型，视为协议异常
        socket.write(fd, json.encode({ t = "error", error = "authentication required" }))
        socket.close(fd)
    end
end

function M.on_close(fd)
    local session = session_manager.get(fd)
    if session then
        auth.handle_disconnect(fd, session)
    end
end

function M.init()
    socket.listen("0.0.0.0", 8787, moon.PTYPE_SOCKET_WS)
    print("[Gate] Listening on 0.0.0.0:8787 (WebSocket)")
end

return M
```

### 5.2 完整消息协议

#### 5.2.1 Client → Server 消息

| `t` 字段 | 其他字段 | 频率 | 说明 |
|----------|---------|------|------|
| `auth-world-5` | `token`, `character`, `clientSeed`, `timerWire` | 首次 | 认证帧 |
| `input` | `seq`, `mi:{f,b,tl,tr,sl,sr,j,dv,sf,ss?}`, `facing?` | ~20 Hz | 移动输入 |
| `cmd` | `cmd:"<commandName>"`, 各命令参数... | 不定 | 游戏命令 |
| `logout` | — | 偶尔 | 主动登出 |

**input 消息完整格式**:
```json
{
    "t": "input",
    "seq": 847,
    "mi": {
        "f": 1,    // forward
        "b": 0,    // back
        "tl": 0,   // turnLeft
        "tr": 0,   // turnRight
        "sl": 0,   // strafeLeft
        "sr": 0,   // strafeRight
        "j": 1,    // jump
        "dv": 0,   // dive
        "sf": 0,   // surface
        "ss": 1.5  // swimSteer (optional, 仅非 1 时包含)
    },
    "facing": 1.570796   // 鼠标视角弧度 (optional, 仅非 null 时包含)
}
```

#### 5.2.2 Server → Client 消息

| `t` 字段 | 结构 | 频率 | 说明 |
|----------|------|------|------|
| `hello` | `{t:"hello", pid, seed, name, cls, realm, softWords, chatMutedUntil}` | 登录时 | 欢迎帧 |
| `snap` | `{t:"snap", tick, time, tw, self, ents, keep?, rings?, hourglasses?}` | ~20 Hz | 世界快照 |
| `events` | `{t:"events", list:[...]}` | 有事件时 | 游戏事件 |
| `social` | `{t:"social", ...}` | ~1 Hz | 社交状态 |
| `commandOutcome` | `{t:"commandOutcome", rid, ok}` | 命令回应 | 命令成功/失败 |
| `error` | `{t:"error", error:"<literal>"}` | 拒绝时 | 致命错误 |
| `censor` | `{t:"censor", softWords:[...]}` | 更新时 | 脏词列表更新 |

### 5.3 快照（snap）格式 — 完整规范

这是协议中最复杂的部分，必须与客户端解析逻辑完全兼容。

**`self` 字段** — 总是包含：

| 字段 | 类型 | 说明 |
|------|------|------|
| `id` | int | Entity id |
| `k` | string | Kind: "player"/"mob"/"object"/"pet"/"node" |
| `tid` | string | Template id |
| `nm` | string | Name |
| `lv` | int | Level |
| `x, y, z` | float | Position |
| `f` | float | Facing radians |
| `hp` | int | Current HP |
| `mhp` | int | Max HP |
| `res` | float | Current resource |
| `mres` | int | Max resource |
| `rtype` | string | Resource type |
| `xp` | int | Experience |
| `lxp` | int | Lifetime XP |
| `rxp` | int | Rested XP |
| `prk` | int | Prestige rank |
| `copper` | int | Currency |
| `gcd` | float | GCD remaining |
| `pcd` | float | Potion CD remaining |
| `fcd` | float | Firebottle CD remaining |
| `swing` | float | Swing timer |
| `combo` | int | Combo points |
| `target` | int\|null | Target entity id |
| `auto` | boolean | Auto attack |
| `queued` | boolean | Queued on swing |
| `ap` | int | Attack power |
| `sp` | int | Spell power |
| `sh` | float | Spell haste |
| `crit` | float | Crit chance |
| `dodge` | float | Dodge chance |
| `blk` | float | Block chance |
| `bval` | int | Block value |
| `crat` | int | Crit rating |
| `hrat` | int | Haste rating |
| `hirat` | int | Hit rating |
| `eat` | {remaining}\|null | Eating state |
| `drk` | {remaining}\|null | Drinking state |
| `ccast` | {r,rem,tot}\|null | Craft cast state |
| `opUntil` | 0\|1 | Overpower available |
| `opRem` | float | Overpower remaining |
| `ack` | int | Last acknowledged server input seq |
| `ddiff` | string | Dungeon difficulty |

**`self` Delta-guarded 扩展字段** (仅在变化时发送)：

| 字段 | 控制 | 内容 |
|------|------|------|
| `cds` | timerWire | Cooldowns |
| `auras` | timerWire | Active auras (buff/debuff list) |
| `stats` | change | Aggregated secondary stats |
| `inv` | heavy | Inventory (all slots) |
| `bags` | heavy | Bag slots |
| `equip` | heavy | Equipped items |
| `einst` | heavy | Equipment instances (signer/enchant/rolled) |
| `cosmetics` | heavy | Skins/mech chromas |
| `qlog` | heavy | Quest log |
| `qdone` | heavy | Completed quests |
| `milestones` | heavy | Quest milestones |
| `deeds` | heavy | Earned deeds |
| `dstats` | heavy | Deed statistics |
| `tal` | heavy | Talent allocation + loadouts |
| `mntOwn` | heavy | Owned mounts |
| `buyback` | heavy | Vendor buyback |
| `party` | change | Party info |
| `marks` | change | Party marks |
| `trade` | change | Trade state |
| `duel` | change | Duel state |
| `cardDuel` | change | Card duel |
| `honor` | change | Honor |
| `lhonor` | change | Lifetime honor |
| `arena` | cadence | Arena rating/wins/losses |
| `bg` | cadence | Battleground state |
| `vcup` | cadence | Vale Cup state |
| `df` | cadence | Dungeon Finder state |
| `market` | cadence | Market notifications |
| `mail` | cadence | Mail notifications |
| `bank` | cadence | Personal bank |
| `guildBank` | cadence | Guild bank |
| `drun` | change | Delve run state |
| `dcompanion` | change | Delve companion |
| `dmarks` | change | Delve marks |
| `dcomp` | change | Companion upgrades |
| `dclears` | change | Delve clears |
| `delveDaily` | change | Delve daily |
| `prof` | change | Profession skills |
| `cprof` | change | Current profession |
| `mst` | change | Mobile station |
| `corder` | change | Commission orders |
| `denc` | change | Disenchants pending |
| `ench` | change | Enchants |
| `salv` | change | Salvage |
| `tfocus` | change | Town focus |
| `gprof` | change | Guild professions |
| `tslot` | change | Tool slot |
| `mntRtd` | change | Mount training fee paid |
| `mntLesson` | change | Mount lesson progress |
| `mntRace` | change | Mount race state |
| `renown` | change | Renown |
| `atitle` | change | Active title |
| `lockouts` | change | Instance lockouts |
| `corpse` | change | Corpse position |
| `hbl` | heavy | Hotbar layout |
| `sport` | change | Social position |
| `weapon` | change | Weapon stats |
| `mktU` | change | Market uncollected count |
| `mailU` | change | Unread mail count |
| `lroll` | change | Loot roll |
| `lrollg` | change | Loot roll group |
| `mloot` | change | Master loot |

**`ents` 记录类型**：

Full record（首次或身份变化时）：
```json
{"id":42,"k":"player","tid":"warrior","nm":"Arthas","lv":20,"x":100.5,"y":0,"z":200.3,"f":1.57,"hp":500,"mhp":500,...}
```

Lite record（后续更新）：
```json
{"id":42,"x":101.0,"y":0,"z":200.5,"f":1.60,"hp":495,"mhp":500}
```

**Entity `dynamicFields`**（lite record 总是包含的字段）：
`x`, `y`, `z`, `f`, `hp`, `mhp`, `dead`, `gh`, `loot`, `h`(hostile), `ak`(afk), `rtype`, `res`, `mres`, `cast`(castingAbility), `castRem`, `castTot`, `chan`, `mcr`(mountCastRemaining), `mck`(mountCastKey), `sit`, `sld`(riftSliding), `cl`(climb pct), `ws`(weaponStowed), `hh`(helmHidden), `aggro`, `ft`(forcedTarget), `ftm`, `tgt`(targetId), `tap`(tappedById), `hcb`, `ffa`, `own`(ownerId), `emo`(overheadEmote), `emoSeq`, `pm`(petMode), `pt`(petTaunt), `pa`(petAutoTaunt), `pw`(petAutoWaterJet), `rp`(rangedPower), `thr`(threat list), `auras`, `lootList`, `sk`(skin), `mnt`(mountKey), `mh`(mainhandItemId), `oh`(offhandItemId), `wsk`(weaponSkinId), `eq`(equippedItems), `eqi`(equippedInstances), `ht`(holderTier), `hb`(holderBalance), `dt`(discordTier), `dav`(discordAvatar), `dnm`(discordName), `dj`(discordJoined), `dr`(discordRole), `dvt`(devTier), `dvc`(devMergedPrs), `dgl`(githubLogin), `ai`, `slk`(streamerLinks), `gd`(guild), `title`, `dgn`(dungeonId), `rt`(riftTier), `obj`(objectItemId), `sc`(scale), `c`(color), `cat`(skinCatalog)

**`keep`** — 不活跃实体 id 列表：
```json
"keep": [5, 12, 88, 143]
```

**`rings` / `hourglasses`** — 范围警告：
```json
"rings": [{"id":"uuid","x":100,"z":200,"r":5,"i":2,"dur":3,"rem":1.5}]
```

### 5.4 兴趣裁剪 (Interest Management)

| 实体类型 | 进入距离 | 离开距离 |
|---------|---------|---------|
| 玩家 (Player) | 90 yd | 100 yd |
| 宠物 (Pet) | 90 yd | 100 yd |
| NPC / Mob / Object | 120 yd | 130 yd |
| 战场队友 | 300 yd | 320 yd |

实现方式：空间网格 (Spatial Grid)，每个 cell 记录其中实体列表。查询时遍历以锚点为中心的 3×3 cells，按距离过滤。

### 5.5 快照组装伪代码

```lua
-- world/snapshot.lua
function SnapshotBuilder:build_forSession(session, tick, simTime)
    local pid = session.pid
    local anchor = self:resolveAnchor(session)
    local anchorPos = anchor.pos

    -- 1. 查询可视实体
    local candidates = self.grid:queryRadius(anchorPos.x, anchorPos.z, INTEREST_QUERY_RADIUS)
    local visible = {}
    for _, e in ipairs(candidates) do
        local isPlayerOrPet = (e.kind == "player" or e.kind == "pet")
        local limitSq = isPlayerOrPet and INTEREST_DROP_RADIUS_SQ or NPC_DROP_RADIUS_SQ
        local dx = e.pos.x - anchorPos.x
        local dz = e.pos.z - anchorPos.z
        local distSq = dx*dx + dz*dz
        if distSq <= limitSq and self:isVisibleTo(session, e) then
            table.insert(visible, e)
        end
    end

    -- 2. 构建 ents 和 keep
    local ents = {}
    local keep = {}
    for _, e in ipairs(visible) do
        if not session.seenEntities[e.id] then
            -- Full record (首次看到)
            session.seenEntities[e.id] = self:identityHash(e)
            table.insert(ents, self:fullRecord(e))
        else
            local idHash = self:identityHash(e)
            if idHash ~= session.seenEntities[e.id] then
                -- Identity changed, resend full
                session.seenEntities[e.id] = idHash
                table.insert(ents, self:fullRecord(e))
            else
                local dyn = self:dynamicFields(e)
                if self:hasDynChanged(session.lastDyn[e.id], dyn) then
                    session.lastDyn[e.id] = dyn
                    table.insert(ents, self:liteRecord(e, dyn))
                else
                    table.insert(keep, e.id)
                end
            end
        end
    end

    -- 3. 构建 self
    local selfJson = self:buildSelf(session)

    -- 4. 组装帧
    local frame = string.format(
        '{"t":"snap","tick":%d,"time":%.2f,"tw":%d,"self":%s,"ents":[%s]%s%s%s}',
        tick, simTime, STABLE_TIMER_WIRE_VERSION,
        selfJson,
        table.concat(ents, ","),
        #keep > 0 and string.format(',"keep":[%s]', table.concat(keep, ",")) or "",
        "" -- rings/hourglasses TBD
    )

    return frame
end
```

---

## 6. 认证流程

### 6.1 整体流程

```
┌──────────┐                    ┌──────────┐                    ┌──────────┐
│  Client  │                    │   Moon   │                    │ PostgreSQL│
└────┬─────┘                    └────┬─────┘                    └────┬─────┘
     │                               │                               │
     │ POST /api/login               │                               │
     │ {username,password,turnstile}  │                               │
     │ ──────────────────────────────►                               │
     │                               │ verifyPassword(scrypt)        │
     │                               │ ─────────────────────────────► accounts
     │                               │ ◄─ password_hash              │
     │                               │                               │
     │                               │ INSERT auth_tokens            │
     │                               │ ─────────────────────────────► auth_tokens
     │                               │                               │
     │ ◄── { token: "<64-hex>" } ─── │                               │
     │                               │                               │
     │                               │                               │
     │ GET /api/characters           │                               │
     │ Authorization: Bearer <tok>   │                               │
     │ ──────────────────────────────►                               │
     │                               │ verifyToken()                 │
     │                               │ SELECT characters             │
     │                               │ ─────────────────────────────► characters
     │                               │ ◄─ [id,name,class,level,...]  │
     │ ◄── [{name:"A",cls:"w",...}] │                                │
     │                               │                               │
     │                               │                               │
     │ WS /ws 连接                   │                               │
     │ ──────────────────────────────►                               │
     │                               │                               │
     │ {t:"auth-world-5",           │                               │
     │  token,character,             │                               │
     │  clientSeed:"",timerWire:2}   │                               │
     │ ──────────────────────────────►                               │
     │                               │ verifyToken                   │
     │                               │ ◄── account (id,scope,isAdmin)│
     │                               │ moderationStatus              │
     │                               │ ◄── suspended_until,banned_at │
     │                               │ getCharacter                  │
     │                               │ ◄── character row             │
     │                               │ acquireLease (90s TTL)        │
     │                               │ ─────────────────────────────► character_leases
     │                               │                               │
     │                               │ World.joinPlayer()            │
     │                               │   → 从 state JSONB 重建角色    │
     │                               │                               │
     │ ◄── {t:"hello",              │                               │
     │      pid,seed,name,cls,       │                               │
     │      realm,softWords,         │                               │
     │      chatMutedUntil}          │                               │
     │                               │                               │
     │ ◄── {t:"snap",tick,time,...}  │  (20 Hz 从此开始)              │
     │
```

### 6.2 Token 格式与密码

- **Token**: `randomBytes(32).toString('hex')` → 64 字符十六进制字符串
- **密码哈希**: scrypt (N=16384, r=8, p=1, keyLen=64)，存储格式为 `"salt_hex:key_hex"`
- **TOTP 2FA**: 标准 6 位数字 TOTP，原项目存储在 `accounts.totp_secret`

Moon 的 `lcrypt` 库可能需要检查是否支持 scrypt。如果不支持，需要：
- 在 Moon C++ 侧添加 scrypt 绑定
- 或使用 Moon 的 `lualib-src` 机制注册新 C 函数

### 6.3 拒绝错误码

所有拒绝都发送 `{t:"error", error:"<literal>"}` 然后关闭连接：

| error literal | 触发条件 |
|---------------|---------|
| `bad auth message` | JSON 解析失败 |
| `authentication required` | 首帧不是 `auth-world-X` |
| `incompatible world version` | `auth-world-X` 的 X 不等于当前版本 |
| `not authenticated` | Token 无效或 scope 不是 "full" |
| `no such character` | 角色不属于该账户或不存在 |
| `character already in world` | 重复登录或 lease 冲突 |
| `realm is full` | 在线人数超过 `MAX_PLAYERS_PER_REALM` (5000) |
| `too many connections from your network` | 单 IP 连接数超过限制 |
| `authentication timed out` | 10 秒内未收到认证帧 |
| `This character must be renamed before entering the world.` | force_rename 标记 |

---

## 7. 数据库与持久化

### 7.1 复用原 PostgreSQL Schema

Moon 将直接复用原项目的 Postgres 数据库和表结构。关键表：

```sql
-- 核心表（不变）
accounts(id, username, password_hash, banned_at, suspended_until,
         chat_muted_until, chat_strikes, is_admin, admin_roles,
         cosmetics, email, ...)

auth_tokens(token PRIMARY KEY, account_id, scope, expires_at, created_at)

characters(id, account_id, name UNIQUE, class, realm,
           level, state JSONB,      ← 核心！所有角色数据存在这里
           hotbar_layout JSONB, is_gm, force_rename,
           created_at, updated_at, last_login)

character_leases(character_id PRIMARY KEY, realm, holder, nonce,
                 acquired_at, heartbeat_at, expires_at, account_id)

-- 世界状态（key-value）
world_state(key PRIMARY KEY, data JSONB, updated_at)
  -- key: "market:<realm>", "mail:<realm>", "rifts:<realm>"

-- 社交
friendships(character_id, friend_id, created_at, UNIQUE)
blocks(character_id, blocked_id, UNIQUE)
ignores(character_id, ignored_id, UNIQUE)
guilds(id SERIAL PRIMARY KEY, name, realm, ...)
guild_members(guild_id, character_id, rank, ...)
guild_banks(guild_id, data JSONB, updated_at)

-- 其他
chat_logs, play_sessions, account_moderation_actions,
player_reports, character_deeds, bank_ledger, ...
```

### 7.2 角色状态序列化

`characters.state` 是 JSONB 列，包含角色全部运行时状态。Moon 的 Lua 端需要实现与 TypeScript 完全兼容的序列化/反序列化。

**序列化输出格式** (Lua table → json.encode → JSONB)：
```lua
-- 示例：serializeCharacter(pid) 的输出结构
{
    contentRevision = 42,     -- CURRENT_CHARACTER_CONTENT_REVISION
    level = 20,
    xp = 45000,
    lifetimeXp = 90000,
    honor = 150,
    prestigeRank = 0,
    restedXp = 2500,
    copper = 123456,
    pos = { x = 100.5, y = 0, z = 200.3 },
    facing = 1.5708,
    dead = false,
    ghost = false,
    hp = 500,
    resource = 80,
    totalPlayedSeconds = 3600,
    professionSkills = { ... },
    knownRecipes = { ... },
    equipment = { ... },
    equipmentInstance = { ... },
    inventory = { ... },
    bags = { ... },
    bank = { inventory = { ... }, purchasedSlots = 0, bonusSlots = 0 },
    questLog = { ... },
    questsDone = { ... },
    questMilestones = { ... },
    talents = { ... },
    loadouts = { ... },
    deeds = { ... },
    deedStats = { ... },
    activeTitle = nil,
    renown = 0,
    arena = { ... },
    bg = { ... },
    cooldowns = { ... },
    nodeHarvestCooldowns = { ... },
    skin = nil,
    skinCatalog = "class",
    -- ... 更多字段
}
```

**反序列化** (JSONB → json.decode → Lua table → Entity 重建)：
```lua
function PlayerManager:restoreFromState(pid, state)
    local player = self.entities[pid]
    if not state then return end  -- 新角色，使用默认值

    player.level = math.max(1, math.min(MAX_LEVEL, state.level))
    player.facing = state.facing or 0
    player.pos = state.pos or START_POS
    -- ... 逐字段恢复
end
```

### 7.3 Lease 机制

防止同一角色被多个进程/服务实例重复加载：

```lua
-- db/character.lua
function CharacterDB.acquireLease(characterId, accountId, realm, holder, nonce)
    -- holder = 进程/实例唯一标识 (如 "moon-server-01")
    -- nonce = 每次登录随机 UUID
    local rows = conn:query([[
        INSERT INTO character_leases (character_id, account_id, realm, holder, nonce, expires_at)
        VALUES ($1, $2, $3, $4, $5, now() + interval '90 seconds')
        ON CONFLICT (character_id) DO UPDATE
        SET holder = $4, nonce = $5, account_id = $2,
            acquired_at = now(), heartbeat_at = now(),
            expires_at = now() + interval '90 seconds'
        WHERE character_leases.holder = $4  -- 只更新自己持有的
           OR character_leases.expires_at < now()  -- 或已过期的
        RETURNING character_id
    ]], characterId, accountId, realm, holder, nonce)
    return #rows > 0
end

function CharacterDB.heartbeatLeases(holder)
    conn:query([[
        UPDATE character_leases SET heartbeat_at = now()
        WHERE holder = $1
    ]], holder)
end

function CharacterDB.releaseLease(characterId, nonce, holder)
    conn:query([[
        DELETE FROM character_leases
        WHERE character_id = $1 AND holder = $2 AND nonce = $3
    ]], characterId, holder, nonce)
end
```

### 7.4 保存周期

```lua
-- world/init.lua — tick loop 中的保存逻辑
local saveTimer = 0
local AUTOSAVE_SECONDS = 30

function World:tick(dt)
    -- ... 游戏逻辑 ...

    -- 定期保存
    saveTimer = saveTimer + dt
    if saveTimer >= AUTOSAVE_SECONDS then
        saveTimer = 0
        moon.async(function()
            self:saveAll()
        end)
    end
end

function World:saveAll()
    for pid, meta in pairs(self.players) do
        local state = self:serializeCharacter(pid)
        db.saveCharacter(pid, meta.level, state, meta.leaseNonce)
    end
    db.saveWorldState("market:" .. REALM, self.market:serialize())
    db.saveWorldState("mail:" .. REALM, self.mail:serialize())
end

-- 角色离开时的事务保存
function World:saveOnLeave(pid)
    local state = self:serializeCharacter(pid)
    local marketState = self.market:serialize()
    local mailState = self.mail:serialize()
    -- 在单个事务中完成
    db.saveAll(pid, state, marketState, mailState, meta.leaseNonce)
end
```

---

## 8. 游戏逻辑 Lua 重写范围

### 8.1 重写清单

按复杂度和依赖排序：

| 模块 | 原文件 | 约行数 | 优先级 | 复杂度 | Lua 实现要点 |
|------|--------|--------|--------|--------|-------------|
| **内容数据表** | `src/sim/content/*.ts` | ~2,000 | Phase 0 | 低 | 编写导出脚本 `scripts/export_content.mjs`，从 TS 源输出 JSON，Lua 端加载为 table |
| **RNG** | `src/sim/rng.ts` | ~50 | Phase 0 | 低 | 实现 `mulberry32(seed)` 函数，确保与原 TS 逐位一致 |
| **实体管理** | `src/sim/sim.ts` (部分) | ~500 | Phase 1 | 中 | Entity 数据结构用 Lua table 表示，空间网格用 2D array |
| **角色登录/序列化** | `src/sim/sim.ts` (部分) | ~800 | Phase 1 | 高 | 从 JSONB state 重建完整角色状态（装备/背包/任务/天赋等） |
| **输入处理** | `server/game.ts` + `move_input.ts` | ~150 | Phase 2 | 低 | 解析 input JSON，按位掩码映射移动方向 |
| **移动+碰撞** | `src/sim/player_motion.ts` + `physics/` | ~900 | Phase 2 | 高 | Swept sphere 碰撞检测、跳板逻辑、游泳 |
| **聊天** | `src/sim/social/chat.ts` | ~400 | Phase 2 | 中 | Channel 路由、脏词过滤、slash 命令、GM 频道 |
| **快照构建** | `server/game.ts` + `server/snapshot.ts` | ~1,500 | Phase 2 | 高 | Delta 编码、兴趣裁剪、字段映射（见第 5.3 节） |
| **伤害计算** | `src/sim/combat/damage.ts` | ~800 | Phase 3 | 高 | 物理/法系/远程伤害公式、暴击/格挡/护甲减免 |
| **治疗** | `src/sim/combat/heal.ts` | ~200 | Phase 3 | 中 | 治疗量 = 基础值 × (1 + spellPower × 系数) × 暴击 |
| **施法系统** | `src/sim/combat/casting_lifecycle.ts` | ~600 | Phase 3 | 高 | GCD(1.5s)、cast time、channeling、pushback、interrupt |
| **光环(Buff/Debuff)** | `src/sim/combat/auras.ts` | ~1,000 | Phase 3 | 极高 | Tick 机制、stack 叠加、dispel 分类、refresh 规则 |
| **CC控制** | `src/sim/combat/cc.ts` | ~300 | Phase 3 | 中 | Stun/Root/Fear/Silence 到期检查、diminishing returns |
| **自动攻击** | `src/sim/combat/auto_attack.ts` | ~300 | Phase 3 | 中 | Swing timer、武器速度、双持 |
| **技能效果分发** | `src/sim/combat/effect_dispatch.ts` | ~500 | Phase 3 | 高 | 瞬时/投射物/AoE/连击/槽位释放 |
| **装备触发** | `src/sim/combat/equip_procs.ts` + `set_procs.ts` | ~500 | Phase 3 | 中 | OnHit/OnCrit/OnCast 触发器 |
| **Mob 索敌** | `src/sim/mob/targeting.ts` | ~300 | Phase 4 | 高 | 仇恨排序、最近敌、最低HP、最高威胁 |
| **Mob AI/技能** | `src/sim/mob/combat_profile.ts` | ~500 | Phase 4 | 中 | 技能使用优先级、CD管理、阶段过渡 |
| **Mob 移动** | `src/sim/mob/locomotion.ts` | ~200 | Phase 4 | 低 | Patrol/Chase/Return/Leash |
| **Mob 仇恨** | `src/sim/mob/threat.ts` | ~200 | Phase 4 | 中 | 伤害仇恨、治疗仇恨、嘲讽/降仇技能 |
| **Mob 生命周期** | `src/sim/mob/lifecycle.ts` | ~300 | Phase 4 | 中 | 死亡掉落、respawn timer、尸体消失 |
| **社交仇恨** | `src/sim/mob/social_aggro.ts` | ~200 | Phase 4 | 中 | 同组/同区域同伴呼救 |
| **死亡/灵魂** | `src/sim/spirit.ts` | ~300 | Phase 3 | 低 | 死亡状态、鬼魂移动、复活、灵魂医者 |
| **背包/物品** | `src/sim/inventory/` | ~500 | Phase 5 | 中 | 物品实例(signer/enchant/rolled)、bag slot 管理 |
| **装备** | `src/sim/equip.ts` (推断) | ~300 | Phase 5 | 中 | Slot 限制、切换、武器类型限制 |
| **商店** | `vendor buy/sell/buyback` | ~200 | Phase 5 | 低 | NPC 商品表、价格计算 |
| **任务系统** | `src/sim/quests/` | ~800 | Phase 5 | 中 | 条件检查(kill/loot/collect/interact/level)、选择奖励 |
| **天赋** | `src/sim/progression/talents.ts` | ~500 | Phase 5 | 中 | 点数分配、效果应用、loadout 保存/切换 |
| **声望** | `src/sim/prestige.ts` | ~150 | Phase 5 | 低 | 等级/奖励/传承 |
| **交易** | `src/sim/social/trade.ts` | ~300 | Phase 5 | 中 | 双确认机制、物品+金币交换 |
| **组队/团队** | `src/sim/social/party.ts` | ~400 | Phase 5 | 中 | 邀请/踢人/升职/转团队/loot规则 |
| **宠物** | `src/sim/pet/` | ~600 | Phase 5 | 中 | 捕捉/喂养/指令/模式/AI |
| **Rift** | `rift_upgrade/enchant/socket` | ~300 | Phase 5 | 低 | 物品升级/附魔选择/宝石插槽 |
| **拍卖行** | `src/sim/market.ts` | ~500 | Phase 6 | 中 | 搜索/排序/分页/上架费/deposit |
| **邮件** | `src/sim/mail/post_office.ts` | ~300 | Phase 6 | 低 | 发送/附件/30天过期 |
| **银行** | `src/sim/bank.ts` | ~300 | Phase 5 | 低 | 存取/购买格子 |
| **公会银行** | `src/sim/guild_bank.ts` | ~300 | Phase 6 | 低 | 存取/金币/权限 |
| **专业-采集** | `src/sim/professions/gathering.ts` | ~300 | Phase 6 | 中 | 节点交互/工具/CD |
| **专业-制造** | `src/sim/professions/crafting.ts` | ~400 | Phase 6 | 高 | 配方检查/批量/佣金/移动工作站 |
| **专业-附魔** | `src/sim/professions/enchanting.ts` | ~300 | Phase 6 | 中 | 选择附魔/应用到装备 |
| **专业-分解** | `src/sim/professions/salvaging.ts` | ~200 | Phase 6 | 低 | 产出表随机 |
| **专业-拆解** | `src/sim/professions/disenchant.ts` | ~150 | Phase 6 | 低 | 装备变材料 |
| **专业-佣金** | commission orders | ~300 | Phase 6 | 中 | 下订单/接单/交付 |
| **副本** | `src/sim/instances/dungeons.ts` | ~500 | Phase 6 | 高 | 进入/离开/难度/锁定期/reset |
| **deep学习** | `src/sim/delves/runs.ts` | ~400 | Phase 6 | 高 | 选层/祝福/同伴/锁开锁/仪式/宝箱 |
| **竞技场** | `src/sim/social/arena.ts` | ~500 | Phase 6 | 高 | 匹配队列/Elo评分/1v1+2v2+3v3 |
| **战场/CTF** | `src/sim/social/battleground.ts` | ~400 | Phase 6 | 高 | 排队/匹配/夺旗/计时 |
| **Vale Cup** | `src/sim/social/vale_cup.ts` | ~300 | Phase 6 | 中 | Boarball运动/位置/技能 |
| **寻地下城** | `src/sim/social/dungeon_finder.ts` | ~400 | Phase 6 | 中 | 角色选择/匹配/提案/接受 |
| **成就** | `src/sim/deeds.ts` | ~300 | Phase 6 | 低 | 解锁条件检查/头衔 |
| **坐骑/赛马** | `src/sim/mount.ts` | ~300 | Phase 6 | 中 | 切换/训练/比赛 |
| **World Boss** | `src/sim/world_boss.ts` | ~300 | Phase 6 | 中 | 定时刷新/阶段机制 |
| **好友/黑名单** | Social service | ~400 | Phase 6 | 低 | CRUD + 在线状态 |

### 8.2 内容数据表自动导出脚本

`scripts/export_content.mjs` (Node.js 脚本，在原项目仓库运行)：

```javascript
// 从 TypeScript 源文件提取静态数据表，输出 JSON 文件供 Lua 加载
import { writeFileSync, mkdirSync } from 'fs';

// 1. 加载内容模块
import { ABILITIES_BY_CLASS } from '../src/sim/content/abilities.js';
import { ALL_ITEMS } from '../src/sim/content/items.js';
import { ALL_QUESTS } from '../src/sim/content/quests.js';
import { ALL_RECIPES } from '../src/sim/content/recipes.js';
import { TALENT_TREES } from '../src/sim/content/talents.js';
// ... 等等

const outDir = './moon-data/';
mkdirSync(outDir, { recursive: true });

writeFileSync(outDir + 'abilities.json', JSON.stringify(ABILITIES_BY_CLASS));
writeFileSync(outDir + 'items.json', JSON.stringify(ALL_ITEMS));
writeFileSync(outDir + 'quests.json', JSON.stringify(ALL_QUESTS));
writeFileSync(outDir + 'recipes.json', JSON.stringify(ALL_RECIPES));
writeFileSync(outDir + 'talents.json', JSON.stringify(TALENT_TREES));
// ...

console.log('Content data exported to ./moon-data/');
```

Lua 端加载：
```lua
-- proto/load.lua
local json = require("moon.json")
local fs = require("moon.fs")

local M = {}

function M.load()
    M.abilities = json.decode(fs.readfile("woc/proto/abilities.json"))
    M.items = json.decode(fs.readfile("woc/proto/items.json"))
    M.quests = json.decode(fs.readfile("woc/proto/quests.json"))
    M.recipes = json.decode(fs.readfile("woc/proto/recipes.json"))
    M.talents = json.decode(fs.readfile("woc/proto/talents.json"))
    -- 构建快速查找索引
    M.itemsById = {}
    for _, item in ipairs(M.items) do
        M.itemsById[item.id] = item
    end
    -- ... 同理其他数据表
end

return M
```

---

## 9. 关键配置常量

在 `woc/config.lua` 中定义：

```lua
-- woc/config.lua
local M = {}

-- 网络
M.DEFAULT_PORT = 8787
M.WS_MAX_PAYLOAD = 16384  -- 16 KiB
M.AUTH_TIMEOUT_MS = 10000

-- 仿真
M.TICK_RATE = 20
M.DT = 1 / 20  -- 0.05 秒
M.GCD = 1.5    -- 全局冷却
M.RUN_SPEED = 7  -- yards/second
M.MELEE_RANGE = 5
M.MELEE_RANGE_SQ = 25
M.SWEPT_SPHERE_RADIUS = 0.4

-- 兴趣裁剪
M.INTEREST_RADIUS = 90
M.INTEREST_DROP_RADIUS = 100
M.INTEREST_DROP_RADIUS_SQ = 10000
M.NPC_INTEREST_RADIUS = 120
M.NPC_DROP_RADIUS = 130
M.NPC_DROP_RADIUS_SQ = 16900
M.BG_MATCH_INTEREST_RADIUS = 300
M.BG_MATCH_DROP_RADIUS = 320
M.INTEREST_QUERY_RADIUS = 135  -- 查询比最大 drop 多一点

-- 玩家限制
M.MAX_PLAYERS_PER_REALM = 5000
M.MAX_WS_PER_IP_HARD = 20

-- 保存
M.AUTOSAVE_SECONDS = 30  -- 每 30 秒全量保存
M.SAVE_CONCURRENCY = 4   -- 最多 4 个并发保存

-- 断线
M.LINKDEAD_GRACE_MS = 300000  -- 5 分钟断线保持

-- 输入频率
M.INPUT_SEND_TIMER_INTERVAL_MS = 50
M.MSG_RATE_REFILL_PER_SECOND = 120
M.MSG_RATE_BURST = 180

-- Leash
M.LEASH_DISTANCE = 45
M.LEASH_DISTANCE_SQ = 2025

-- 等级
M.MAX_LEVEL = 20  -- 或者更高，取决于内容版本

-- 稳定版本号
M.ONLINE_WORLD_LAYOUT_VERSION = 5
M.STABLE_TIMER_WIRE_VERSION = 2
M.ONLINE_WORLD_AUTH_TYPE = "auth-world-5"

-- 世界种子 (从原项目提取，必须一致)
M.WORLD_SEED = 0  -- TODO: 从原项目 src/sim/world_seed.ts 复制

-- 服务器标识
M.REALM = "Claudemoon"  -- 或从环境变量读取
M.PROCESS_LEASE_HOLDER = "moon-server"  -- 用于 character_leases

return M
```

---

## 10. 实施阶段

### Phase 0 — 基础设施 (目标: 1–2 周)

**目标**: Moon 可编译、可运行、PostgreSQL 可连接、HTTP 认证可工作

- [ ] **0.1** 确认 Moon 编译通过（Windows/Linux）
- [ ] **0.2** 创建 `woc/` 完整目录结构
- [ ] **0.3** 创建 `woc/main.lua` 入口文件
  ```lua
  -- 创建 4 个 worker 线程，注册所有 service
  local conf = {
      thread = 4,
      path = "./?.lua;./?/init.lua",
      loglevel = "DEBUG",
  }
  -- 创建 services
  moon.new_service { name = "gate", file = "woc/gate/init.lua", unique = true }
  moon.new_service { name = "world", file = "woc/world/init.lua", unique = true }
  moon.new_service { name = "social", file = "woc/social/init.lua", unique = true }
  moon.new_service { name = "db", file = "woc/db/init.lua", unique = true }
  moon.new_service { name = "market", file = "woc/market/init.lua", unique = true }
  moon.new_service { name = "mail", file = "woc/mail/init.lua", unique = true }
  ```
- [ ] **0.4** 配置 PostgreSQL 连接 (`woc/db/init.lua`)
- [ ] **0.5** 实现 HTTP Auth Service — 路由注册骨架
  - `POST /api/login` — scrypt 验证 + 生成 token
  - `POST /api/register` — scrypt 哈希 + 插入账户
  - `GET /api/characters` — 查询角色列表
  - `GET /api/realms` — 返回 realm 目录
  - `GET /api/status` — 返回在线人数
- [ ] **0.6** 实现 db service 基础函数（account CRUD, auth token 管理）
- [ ] **0.7** 编写 `scripts/export_content.mjs` 脚本，导出原 TS 内容数据表为 JSON
- [ ] **0.8** 实现 `woc/proto/load.lua` 和数据加载
- [ ] **0.9** 实现 `mulberry32` RNG (确保与原 TS 输出一致)

**验证**: `POST /api/register` → 返回 token → `POST /api/login` → 返回 token → `GET /api/characters` → 返回角色列表

---

### Phase 1 — 认证 + 登录/登出 (目标: 1–2 周)

**目标**: 客户端能通过 WebSocket 登录并接收 hello 帧

- [ ] **1.1** Gate Service: 监听 WebSocket 8787
- [ ] **1.2** 实现 `on_message` 解析和消息类型分派
- [ ] **1.3** 实现 `handle_auth` — 完整认证流程
  - 验证 `t == "auth-world-5"`
  - 验证 token (db service)
  - 检查 moderation 状态
  - 加载角色数据
  - 获取 lease
  - 调用 World.joinPlayer()
- [ ] **1.4** 实现 `hello` 响应帧组装
- [ ] **1.5** World Service: 骨架 — API dispatch 接口
- [ ] **1.6** World Service: Entity 数据结构定义 (`entity.lua`)
- [ ] **1.7** World Service: `joinPlayer` — 从 JSONB state 重建角色
- [ ] **1.8** World Service: `leavePlayer` — 保存状态 + 释放 lease
- [ ] **1.9** 实现 `logout` 消息处理
- [ ] **1.10** 实现 `error` 拒绝帧 (`{t:"error", error:"..."}`)
- [ ] **1.11** 实现 linkdead 保持 — 断线后 5 分钟 session 存活
- [ ] **1.12** 实现消息速率限制 (token bucket 模型)
- [ ] **1.13** 实现 session 管理 (创建/查找/销毁)
- [ ] **1.14** 实现角色序列化 `serializeCharacter()` (基础字段：level, pos, hp, copper)
- [ ] **1.15** 实现角色保存到 Postgres

**验证**: 客户端连接 WS → 收到 hello → 断线重连 5 分钟内恢复 → logout → 状态正确持久化

---

### Phase 2 — 移动 + 聊天 + 基础快照 (目标: 1–2 周)

**目标**: 客户端能走动、看到其他玩家、聊天

- [ ] **2.1** 实现 input 消息解析 (`{t:"input", mi:{f,b,...}, facing}`)
- [ ] **2.2** 实现基础移动系统 — 方向键 + 速度 × dt × 方向向量
- [ ] **2.3** 实现 swept sphere 碰撞检测 (玩家与障碍物)
- [ ] **2.4** 实现空间网格 `grid.lua` — 用于兴趣查询
- [ ] **2.5** 实现快照构建器 – self 基础字段
- [ ] **2.6** 实现快照构建器 – ents 列表 (full/lite record)
- [ ] **2.7** 实现快照构建器 – keep 数组
- [ ] **2.8** 实现兴趣裁剪 (distance-based visibility)
- [ ] **2.9** 实现 Delta 编码 (lastSent / seenEntities 跟踪)
- [ ] **2.10** 实现 20Hz tick 循环 (`moon.timeout` 每 50ms)
- [ ] **2.11** 快照广播 — 每个 tick 后向所有 fd 发送 snap 帧
- [ ] **2.12** 实现聊天: channel 路由 (say/yell/general/party/guild/whisper/world/lfg/officer)
- [ ] **2.13** 实现聊天脏词过滤
- [ ] **2.14** 实现 emotes (`/wave`, `/dance` 等)

**验证**: 客户端走动/跳跃 → 在世界中看到其他玩家移动 → 聊天消息可见 → 输入无卡顿

---

### Phase 3 — 战斗系统 (目标: 2–3 周)

**目标**: 能打怪、放技能、死亡、复活

- [ ] **3.1** 实现伤害公式
  - 物理伤害 = baseDmg × (1 + AP/14 × weaponSpeed) × armorMitigation
  - 法术伤害 = baseDmg × (1 + SP × coefficient)
  - 暴击 = 150% 基础 (可被天赋/buff 修改)
  - 格挡 = 减少固定值
  - 闪避/招架/未命中
- [ ] **3.2** 实现治疗公式
- [ ] **3.3** 实现施法系统
  - GCD (1.5s, 受 spellHaste 影响)
  - Cast time (受 spellHaste 影响)
  - Channeling
  - Pushback (受伤害时施法延迟)
  - Interrupt
  - Empowered release
- [ ] **3.4** 实现技能效果分发
  - 瞬时效果 (Instant)
  - 投射物 (Projectile — 延迟到达)
  - AoE (圆形/锥形/链式)
  - 弹跳 (Chain)
  - 引导 (Channel)
- [ ] **3.5** 实现 Buff/Debuff 系统
  - 生命周期: apply → tick → refresh → expire → dispel
  - Stack 叠加
  - Dispel 分类 (Magic/Curse/Poison/Disease/Physical)
  - Diminishing returns (CC递减)
- [ ] **3.6** 实现自动攻击 (swing timer / 双持)
- [ ] **3.7** 实现 CC 系统 (Stun/Root/Fear/Silence/Disorient/Snare)
- [ ] **3.8** 实现 Target/Nearest-Target/Tab-Target
- [ ] **3.9** 实现 castSlot / castAt / cast 三条命令
- [ ] **3.10** 实现技能冷却系统 (cooldowns 序列化到 snapshot)
- [ ] **3.11** 实现死亡/灵魂状态
- [ ] **3.12** 实现灵魂医者复活 / 跑尸复活
- [ ] **3.13** 实现装备触发效果 (OnHit/OnCrit/OnCast)
- [ ] **3.14** 实现 combat log 事件生成 (发送到 gate service → events 帧)

**验证**: 能打怪 → 技能正确施放 → 伤害数字正确 → 怪死亡掉落 → 玩家死亡可复活

---

### Phase 4 — Mob AI (目标: 1 周)

**目标**: Mob 有完整的 AI 行为（巡逻→发现→战斗→死亡→重生）

- [ ] **4.1** 实现仇恨表 (threat table per mob)
- [ ] **4.2** 实现索敌逻辑
  - 社交仇恨 (同组/同伴呼救)
  - 距离仇恨 (最近优先)
  - 生命值仇恨 (最低 HP 优先)
  - 治疗仇恨 (按治疗量比例)
- [ ] **4.3** 实现 Mob 技能配置表
- [ ] **4.4** 实现 Mob 技能使用 AI (优先级/CD/阶段)
- [ ] **4.5** 实现移动 AI (巡逻/追击/返回/牵引范围)
- [ ] **4.6** 实现 Mob 刷新系统 (respawn timer)
- [ ] **4.7** 实现 Mob 掉落系统 (loot table)
- [ ] **4.8** 实现 World Boss 定时刷新

**验证**: Mob 在区域巡逻 → 接近后进入战斗 → 使用技能 → 死亡刷新 → 同伴呼救生效

---

### Phase 5 — 核心 RPG 系统 (目标: 2–3 周)

**目标**: 完整的 MMO 角色养成循环 (装备/任务/天赋/组队/交易)

- [ ] **5.1** 背包系统 (inv_move / bag 管理 / 物品实例)
- [ ] **5.2** 装备系统 (equip / unequip / slot 限制)
- [ ] **5.3** NPC 商店 (buy / sell / buyback / sell_all_junk)
- [ ] **5.4** 物品使用 (use / discard / consume)
- [ ] **5.5** 银行系统 (bank_deposit / bank_withdraw / bank_buy_slots)
- [ ] **5.6** 任务系统 (accept / turnin / abandon / 条件跟踪)
- [ ] **5.7** 天赋系统 (applyTalents / respec / setSpec / loadouts)
- [ ] **5.8** 声望系统 (prestige / 等级/ 传承)
- [ ] **5.9** 组队/团队系统 (pinvite/paccept/pleave/pkick/praid)
- [ ] **5.10** 交易系统 (trade_req/accept/offer/confirm)
- [ ] **5.11** 决斗系统 (duel_req/accept)
- [ ] **5.12** 宠物系统 (捕捉/喂养/指令/模式/AI)
- [ ] **5.13** Rift 系统 (升级/附魔选择/宝石插槽)
- [ ] **5.14** 物品开锁 (lockpick_engage/action)
- [ ] **5.15** 卡片决斗 (card_queue/play/forfeit)
- [ ] **5.16** 外观系统 (change_skin / weapon_skin / helm)

**验证**: 完整的 MMO 基础循环 → 打怪升级 → 装备变强 → 任务奖励 → 组队下副本

---

### Phase 6 — 高级系统 (目标: 2–3 周)

**目标**: 拍卖行、邮件、专业、副本、PvP、公会等

- [ ] **6.1** 拍卖行 (market_search/list/buy/cancel/collect)
- [ ] **6.2** 邮件系统 (mail_send/take/delete/read)
- [ ] **6.3** 公会 (guild_create/invite/accept/leave/kick/promote/disband)
- [ ] **6.4** 公会银行 (guild_bank_deposit/withdraw/buy_slots)
- [ ] **6.5** 专业-采集 (harvest_node / 工具 CD)
- [ ] **6.6** 专业-制造 (craft_item / 批量 / 移动工作站)
- [ ] **6.7** 专业-附魔 (apply_enchant / disenchant_item)
- [ ] **6.8** 专业-分解 (salvage_item / unbind_item)
- [ ] **6.9** 专业-佣金订单 (commission open/accept/deliver)
- [ ] **6.10** 副本 (enter_dungeon/leave_dungeon/set_difficulty/reset)
- [ ] **6.11** deep学习 (enter_delve/leave_delve/祝福/同伴/锁开锁/仪式)
- [ ] **6.12** 竞技场 (arena_queue/leave/augment / 1v1+2v2+3v3)
- [ ] **6.13** 战场 CTF (bg_queue/leave/flag)
- [ ] **6.14** Vale Cup (Boarball — vcup_queue/role/ready)
- [ ] **6.15** 寻地下城 (df_roles/queue/proposal/apply)
- [ ] **6.16** 成就系统 (deeds / 头衔)
- [ ] **6.17** 坐骑系统 (mount_toggle/train/race/learn_riding)
- [ ] **6.18** 好友/黑名单/屏蔽 (friend_add/remove, block_add/remove)
- [ ] **6.19** 反作弊/审核 (botDetector / jail / mute / kick)
- [ ] **6.20** 社交帧 (social / socialpos 帧广播)
- [ ] **6.21** 聊天记录持久化 (chat_logs)
- [ ] **6.22** 事件帧广播 (events frame — loot/deed/error)
- [ ] **6.23** Zone 实例化 — 多个副本/deep学习 并行处理
- [ ] **6.24** 跨 Zone 路由 (dungeon 入口/离开 在多个 world instance 间切换)

**验证**: 接近完整游戏体验 → 拍卖行买卖 → 发邮件 → 副本通关 → PvP 战斗

---

### Phase 7 — 打磨与性能 (目标: 1–2 周)

**目标**: 性能达标，稳定性可靠

- [ ] **7.1** 快照 worker 线程并行化 (如果单线程性能不足)
- [ ] **7.2** 性能基准测试 — 对比原 Node.js 服务端
  - Tick 耗时 (每 tick CPU 时间)
  - 内存占用 (100+ 玩家在线)
  - 快照广播延迟
- [ ] **7.3** 多玩家压测 (100–500 同时在线)
- [ ] **7.4** 断线重连测试 (网络波动/服务器重启)
- [ ] **7.5** 防刷/反作弊微调 (rate limit 参数)
- [ ] **7.6** 完整客户端兼容性测试
  - 所有 170+ 命令都能正常处理
  - 所有 snapshot 字段齐全
- [ ] **7.7** 持久化往返测试 (TS serialize → Lua deserialize → Lua serialize → diff)
- [ ] **7.8** RNG 确定性测试 (相同种子 → 相同世界状态)
- [ ] **7.9** 配置文件添加 (环境变量/命令行参数)

**验证**: 所有 Phase 6 的功能在 100+ 玩家在线时无卡顿、无内存泄漏

---

### Phase 8 — 部署与监控 (目标: 1 周)

**目标**: 生产环境可用

- [ ] **8.1** Docker 镜像构建
- [ ] **8.2** 健康检查端点
- [ ] **8.3** 日志轮转配置
- [ ] **8.4** 优雅关闭 (SIGINT/SIGTERM 处理)
- [ ] **8.5** 热重载脚本 (Moon 原生 hotfix)
- [ ] **8.6** 运维文档/启动脚本

---

## 11. 关键技术风险与缓解

| 风险 | 严重性 | 影响 | 缓解措施 |
|------|--------|------|---------|
| **Lua 执行速度不如 V8** | 中 | 战斗/物理计算可能成为瓶颈 | Moon C++ 核心接管所有网络 I/O；游戏逻辑在 Lua 中运行，必要时用 Moon 多线程并行 zone 处理 |
| **yyjson 与 Node.js JSON 不一致** | 高 | 字段顺序差异导致 delta 编码误判；float 精度差异导致客户端预测不同步 | 写往返测试：TS serialize → Lua deserialize/modify → Lua serialize → TS compare。用 `round2()` 统一浮点数格式 |
| **mulberry32 RNG 必须是 bit-exact** | 高 | 不同 RNG 导致完全不同的世界状态和掉落 | 在 Lua 中逐行复现 TS 的 mulberry32，使用 32-bit 整数运算。写确定性测试 |
| **scrypt 库可用性** | 中 | Moon 的 lcrypt 可能不支持 scrypt | 检查 lcrypt 支持范围。若不支持，用 Moon 的 C 扩展机制（`lualib-src/`）添加 scrypt |
| **物理碰撞算法差异** | 中 | 服务器位置与客户端预测不一致，产生 rubber-banding | 确保 SWEPT_SPHERE_RADIUS 和碰撞检测逻辑与原 TS 逐位一致 |
| **内容数据表更新同步** | 低 | 原项目内容更新后 Moon 数据过时 | 将导出脚本加入 CI pipeline，内容表变更时自动重新生成 Lua 数据文件 |
| **客户端协议版本更新** | 中 | 未来 `ONLINE_WORLD_LAYOUT_VERSION` 变更需同步更新 Moon | 在 `woc/config.lua` 中集中管理版本常量。协议变更时先更新 Moon，再更新客户端 |
| **Moon 多线程数据一致性** | 低 | Actor 模型确保消息隔离，但 shared state (market/mail/guild) 需要 lock | 使用 Postgres advisory lock (如原项目) 或 Moon 的 sharetable 服务 |
| **开发体验差异** | 低 | Lua 缺少 TypeScript 的类型检查，调试较困难 | 编写单元测试 + 集成测试；使用 Moon 内置的 debug service |
| **热重载与状态迁移** | 低 | hotfix 后旧服务状态可能不兼容新代码 | 使用内容修订号 (`CURRENT_CHARACTER_CONTENT_REVISION`)，序列化时标记版本 |

---

## 12. 开放问题

这些问题需要在实施开始前与团队确认：

### 12.1 数据迁移

**Q: 是复用现有 Postgres 数据库还是从零开始？**

- 如果复用：`accounts`、`characters`、`world_state` 表数据直接使用，用户无缝迁移
- 如果从零：所有用户需重新注册和创建角色

**建议**: 复用现有数据库，这样可以做 A/B 测试（一半玩家用旧服务器，一半用 Moon）

### 12.2 认证 Token 兼容

**Q: scrypt 哈希验证在 Moon 中如何实现？**

- Moon 的 `lcrypt` 模块需要检查是否支持 scrypt
- 如果不支持，方案 A：在 Moon C++ 侧添加 scrypt 绑定
- 方案 B：用 Moon 的 HTTP client 调用外部 auth 微服务（更简单但引入额外依赖）

### 12.3 Turnstile (Cloudflare)

**Q: 注册时的 Turnstile 验证如何处理？**

- Moon 内置 HTTP 客户端可以调用 Cloudflare Turnstile API
- `POST https://challenges.cloudflare.com/turnstile/v0/siteverify`

### 12.4 声音/特效

**Q: 是否需要处理音效/特效？**

- 不需要。Moon 服务端只负责游戏逻辑和状态同步
- 所有渲染/音效由客户端处理

### 12.5 移动端/桌面端

**Q: 是否支持移动端和桌面端客户端？**

- Moon 服务端对客户端平台无感知 — 只要协议兼容，任何客户端都可以连接
- 目前客户端使用 WebSocket + JSON，Moon 完全支持

### 12.6 DNS / 负载均衡

**Q: 生产环境如何做负载均衡？**

- Moon 内置 cluster 支持多节点部署
- Gate service 可以水平扩展（多个 Gate + 一个 World）
- 或者使用 Nginx 等反向代理转发 WebSocket 到多个 Moon 实例

### 12.7 可测试性策略

**Q: 如何验证每个 Phase 的功能正确性？**

- 每个 Phase 完成后连接真实客户端测试
- 使用原项目的 TypeScript 测试套件交叉验证（如果测试的接口在 Moon 中重现）
- 写针对 Lua 模块的单元测试（Moon 支持简单的测试框架）

---

## 13. 附录

### 13.1 原项目关键文件清单

| 文件 | 行数(约) | 用途 |
|------|---------|------|
| `server/main.ts` | 3,406 | 入口点：配置加载、Schema 创建、GameServer 构造和启动 |
| `server/game.ts` | ~11,000 | 核心服务器：tick 循环、dispatch、snapshot、save |
| `server/ws_auth.ts` | ~500 | WebSocket 认证握手 |
| `server/db.ts` | ~4,500 | 数据库 schema + 所有 SQL 操作 |
| `server/msg_rate_limit.ts` | ~200 | 消息频率限制 (token bucket) |
| `server/linkdead.ts` | ~100 | 断线保持 |
| `server/event_frame.ts` | ~50 | 事件帧序列化 |
| `server/social_db.ts` | ~800 | 好友/公会/黑名单 SQL |
| `src/sim/sim.ts` | ~12,000 | 仿真核心：所有游戏系统协调器 |
| `src/sim/combat/` | ~3,000 | 战斗系统 (damage, heal, auras, cast, cc, auto_attack) |
| `src/sim/mob/` | ~2,000 | Mob 系统 (AI, targeting, combat, locomotion, lifecycle) |
| `src/sim/player_motion.ts` | ~500 | 玩家移动 |
| `src/sim/physics/` | ~400 | 碰撞检测 |
| `src/sim/inventory/` | ~500 | 背包/物品 |
| `src/sim/quests/` | ~800 | 任务系统 |
| `src/sim/professions/` | ~1,500 | 专业系统 |
| `src/sim/social/` | ~3,000 | 社交系统 (party, trade, duel, arena, bg, df, vcup) |
| `src/sim/content/` | ~3,000 | 静态数据表 (可脚本导出) |
| `src/world_api.ts` | ~500 | 公共 API 接口 + COMMAND_NAMES |
| `src/net/online.ts` | ~5,400 | 客户端网络层 (参考协议实现) |
| `src/net/input_send_cadence.ts` | ~100 | 输入发送节奏 |

### 13.2 命令名称完整列表

以下 170+ 命令名来自 `src/world_api.ts:COMMAND_NAMES`：

```
castSlot, castAt, cast, cancel_aura, target, tab, targetNearest, tabFriendly,
targetNearestFriendly, attack, stopattack, interact, loot, harvestCorpse,
lootRoll, pickup, accept, turnin, abandon, qlinkaccept, equip, inv_move,
unequip_item, use, discard, buy, sell, buyback, sell_all_junk, harvest_node,
craft_item, place_mobile_station, change_skin, unequip_mech_chroma,
claim_event_skin, change_weapon_skin, release, challengeResponse, chat, emote,
pinvite, paccept, pdecline, pleave, pkick, ppromote, praid, punraid,
pmoveRaid, setLootMaster, masterAssign, setMarker, clearMarker, readyrespond,
pet_abandon, pet_rename, pet_revive, pet_attack, pet_water_jet, pet_taunt,
pet_auto_taunt, pet_auto_water_jet, pet_feed, pet_heal, pet_mode, trade_req,
trade_accept, trade_offer, trade_confirm, trade_cancel, duel_req, duel_accept,
duel_decline, friend_add, friend_remove, block_add, block_remove,
social_refresh, guild_create, guild_invite, guild_accept, guild_decline,
guild_leave, guild_kick, guild_promote, guild_demote, guild_transfer,
guild_disband, arena_queue, arena_leave, arena_augment, card_queue_join,
card_queue_leave, play_card, card_forfeit, prestige, applyTalents, respec,
setSpec, saveLoadout, switchLoadout, deleteLoadout, market_search,
market_list, market_list_instance, market_buy, market_cancel, market_collect,
dev_level, dev_teleport, dev_give, dev_complete_quest, dev_complete_all_quests,
enter_crypt, enter_dungeon, leave_crypt, leave_dungeon, enter_delve,
leave_delve, delve_interact, companion_upgrade, delve_buy, lockpick_engage,
lockpick_action, lockpick_abort, collect_delve_chest_loot, delve_rite_choose,
telemetry, equip_bag, unequip_bag, mail_send, mail_take, mail_delete,
mail_read, guild_event_create, guild_event_remove, autoloot, resurrect_corpse,
resurrect_healer, bank_deposit, bank_withdraw, bank_buy_slots,
set_town_focus, set_dungeon_difficulty, heroic_buy, vcup_queue, vcup_leave,
vcup_role, vcup_ready, vcup_bet, vcup_practice, mount_toggle,
mount_train_begin, mount_train_answer, mount_train_abort, mount_race_start,
mount_race_cancel, learn_riding, releaseEmpowered, df_roles, df_queue,
df_queue_leave, df_proposal, df_list_create, df_list_close, df_apply,
df_apply_cancel, df_app_respond, rift_upgrade_item, rift_enchant_item,
rift_socket_gem, deed_set_title, ignore_add, ignore_remove, stow_weapon,
unstuck, selectTalentRow, resurrect_respond, train_recipe, slot_tool_effect,
recharge_tool_effect, save_hotbar_layout, disenchant_item, apply_enchant,
salvage_item, unbind_item, guild_set_motd, open_commission_order,
cancel_commission_order, accept_commission_order, deliver_commission_order,
stopAutoAttackOnTargetSwitch, bg_queue, bg_leave, bg_flag,
dev_bg_start, dev_profiler_invulnerable, guild_bank_deposit_gold,
guild_bank_withdraw_gold, guild_bank_deposit, guild_bank_withdraw,
guild_bank_buy_slots, guild_bank_log, set_helm
```

### 13.3 消息完整 JSON 示例

**Client → Server: Auth**
```json
{"t":"auth-world-5","token":"a1b2c3d4e5f6...64hex...","character":42,"clientSeed":"","timerWire":2}
```

**Server → Client: Hello**
```json
{"t":"hello","pid":99,"seed":123456789,"name":"Arthas","cls":"warrior","realm":"Claudemoon","softWords":["heck"],"chatMutedUntil":null}
```

**Client → Server: Input**
```json
{"t":"input","seq":1047,"mi":{"f":1,"b":0,"tl":0,"tr":0,"sl":0,"sr":0,"j":0,"dv":0,"sf":0},"facing":2.094}
```

**Client → Server: Command (castSlot)**
```json
{"t":"cmd","cmd":"castSlot",0}
```

**Client → Server: Command (cast)**
```json
{"t":"cmd","cmd":"cast","ability":"fireball","target":73}
```

**Client → Server: Command (chat)**
```json
{"t":"cmd","cmd":"chat","text":"hello world"}
```

**Server → Client: Snap (简化版，真实帧有更多字段)**
```json
{"t":"snap","tick":5100,"time":255.00,"tw":2,"self":{"id":99,"k":"player","tid":"warrior","nm":"Arthas","lv":15,"x":100.5,"y":0.0,"z":200.3,"f":2.09,"hp":450,"mhp":500,"res":80,"mres":100,"rtype":"rage","xp":15000,"lxp":35000,"rxp":2000,"prk":0,"copper":12345,"gcd":0.00,"pcd":0.0,"fcd":0.0,"swing":1.2,"combo":2,"target":73,"auto":true,"queued":false,"ap":200,"sp":50,"sh":0.05,"crit":5.0,"dodge":3.5,"blk":2.0,"bval":30,"crat":50,"hrat":25,"hirat":10,"eat":null,"drk":null,"ccast":null,"opUntil":0,"opRem":0,"ack":1047,"ddiff":"normal"},"ents":[{"id":73,"k":"mob","tid":"wolf","nm":"Wolf","lv":12,"x":103.0,"y":0,"z":201.0,"f":5.0,"hp":180,"mhp":250,"hostile":1}],"keep":[5,12,88]}
```

**Server → Client: Events**
```json
{"t":"events","list":[{"type":"log","text":"Arthas hits Wolf for 45 damage.","color":"#ffd100"},{"type":"loot","text":"Looted: Wolf Pelt"}]}
```

**Server → Client: Error**
```json
{"t":"error","error":"character already in world"}
```

### 13.4 Moon 关键 API 参考

| API | 用途 |
|-----|------|
| `moon.new_service({name, file, unique, threadid})` | 创建新 service |
| `moon.send(ptype, receiver, data)` | 单向发送消息 |
| `moon.call(ptype, receiver, data)` | 请求-响应 (协程挂起) |
| `moon.response(ptype, sender, session, data)` | 响应请求 |
| `moon.dispatch(ptype, callback)` | 注册消息处理函数 |
| `moon.timeout(ms, callback)` | 单次定时器 |
| `moon.async(func)` | 在新协程中执行异步函数 |
| `moon.sleep(ms)` | 协程休眠 |
| `moon.quit()` | 优雅退出 |
| `moon.shutdown(callback)` | 注册退出回调 |
| `socket.listen(host, port, ptype)` | 启动网络监听 |
| `socket.write(fd, data)` | 发送数据到 fd |
| `socket.close(fd)` | 关闭连接 |
| `json.encode(table)` | Lua table → JSON 字符串 |
| `json.decode(string)` | JSON 字符串 → Lua table |
| `pg.query(sql, ...)` | PostgreSQL 查询 |

### 13.5 参考资源

- [Moon GitHub](https://github.com/sniper00/moon) — C++ 游戏服务器框架
- [Moon 文档](https://github.com/sniper00/moon/tree/master/docs) — 架构、网络、API 参考
- 原项目主要代码路径:
  - `server/main.ts` — 服务器入口
  - `server/game.ts` — 核心游戏服务器 (tick/dispatch/snapshot)
  - `server/ws_auth.ts` — WebSocket 认证
  - `server/db.ts` — PostgreSQL schema + 操作
  - `src/sim/` — 确定性仿真 (所有游戏逻辑)
  - `src/world_api.ts` — 公共 API + COMMAND_NAMES
  - `src/net/online.ts` — 客户端网络层 (参考协议实现)

---

> **最后修订**: 2026-08-09  
> **版本**: v1.0  
> **下一步**: 确认 [开放问题](#12-开放问题) 后启动 Phase 0 实施
