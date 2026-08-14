# World of ClaudeCraft — Moon Server

基于 [Moon](https://github.com/sniper00/moon) 框架的游戏服务端实现。

## 快速开始

### 1. 编译 Moon

```shell
# 下载 premake5
# https://github.com/premake/premake-core/releases
# 将 premake5.exe 放到项目根目录 E:\gongxiang\moon\

# 生成 VS2022 工程
cd E:\gongxiang\moon
premake5.exe build

# 编译 (使用 VS2022)
msbuild build/moon.sln /p:Configuration=Release

# 或使用 premake5 一键编译运行
premake5.exe run --release woc/main.lua
```

### 2. 配置环境变量

```powershell
# 必需
$env:DATABASE_URL = "postgresql://postgres:postgres@localhost:5433/woc"

# 可选
$env:WOC_REALM = "Claudemoon"
$env:PORT = "8787"
$env:ALLOW_DEV_COMMANDS = "1"
```

### 3. 启动服务器

```shell
# 直接运行
.\moon.exe woc\main.lua

# 或通过 premake5
premake5.exe run --release woc/main.lua
```

### 4. 测试

```shell
# HTTP 健康检查
curl http://localhost:8787/health

# 用户注册
curl -X POST http://localhost:8787/api/register \
  -H "Content-Type: application/json" \
  -d '{"username":"testuser","password":"pass123","email":"test@example.com"}'

# 用户登录 (获取 token)
curl -X POST http://localhost:8787/api/login \
  -H "Content-Type: application/json" \
  -d '{"username":"testuser","password":"pass123"}'

# 获取角色列表
curl http://localhost:8787/api/characters \
  -H "Authorization: Bearer <token>"
```

## 项目结构

```
woc/
├── main.lua                  # 入口 — 创建所有 Service
├── config.lua                # 全局常量
│
├── shared/                   # 跨 Service 共享
│   ├── command_names.lua     # 170+ 命令名
│   ├── json_helpers.lua      # JSON 帧构建
│   ├── message_types.lua     # 消息类型/PTYPE
│   └── password_hash.lua     # 密码哈希 (TODO: scrypt)
│
├── gate/                     # Gate Service
│   └── init.lua              # WebSocket 监听 + 认证 + 消息路由
│
├── world/                    # World Service
│   ├── init.lua              # 核心仿真 + tick 循环
│   ├── entity.lua            # Entity 数据结构 (60+ 字段)
│   ├── rng.lua               # mulberry32 确定性 PRNG
│   ├── combat/               # 战斗系统 (Phase 3)
│   ├── mob/                  # Mob AI (Phase 4)
│   ├── profession/           # 专业 (Phase 6)
│   ├── social/               # 社交子系统 (Phase 5)
│   └── instance/             # 副本/deep学习 (Phase 6)
│
├── social/                   # Social Service
│   └── init.lua              # 好友/公会/组队 (Phase 5)
│
├── market/                   # Market Service
│   └── init.lua              # 拍卖行 (Phase 6)
│
├── mail/                     # Mail Service
│   └── init.lua              # 邮件 (Phase 6)
│
├── db/                       # DB Service (唯一数据库入口, 连接池+事务)
│   ├── init.lua              # PostgreSQL 连接池 + 心跳重连 + Schema + 事务
│   ├── account.lua           # 账号 CRUD
│   ├── auth.lua              # Token 管理
│   ├── character.lua         # 角色 CRUD + Lease + 全局唯一
│   └── world_state.lua       # 世界状态 (market/mail)
│
├── gate/                     # Gateway (HTTP API + WebSocket, 统一端口)
│   └── init.lua              # 路由 + WS 认证 (经 DB Service, 无直连 PG)
│
└── proto/                    # 静态内容数据表
    └── load.lua              # 从 JSON 加载数据表
```

> HTTP API 与 WebSocket 由 Gate Service 统一提供；数据库访问一律经
> `db` service 的 `moon.call` 路由（连接池 + 参数化/安全 SQL + 事务），
> 不再有服务直连 PostgreSQL。

## 已知限制 / TODO

| 项目 | 说明 | 计划 |
|------|------|------|
| **scrypt** | 密码哈希使用 SHA-256 占位 | 需要在 Moon lcrypt 中添加 scrypt 支持 |
| **TOTP 2FA** | 两步验证未实现 | Phase 1 |
| **Turnstile** | Cloudflare 人机验证未集成 | Phase 1 |
| **快照系统** | Delta 编码 + 兴趣裁剪骨架 | Phase 2 |
| **HTTP 异步响应** | 路由处理器使用 moon.async 暂未完全验证 | Phase 0 自测 |
| **`bit32` 兼容** | Lua 5.4 已移除 bit32，RNG 已改用原生位运算符 | ✓ 已修复 |
