# World of ClaudeCraft — Moon Server

基于 [Moon](https://github.com/sniper00/moon) C++ 游戏服务器框架 + Lua 5.4 的 MMO 服务端实现。

## 目录结构

```
moon-server/
├── bin/          # moon.exe 编译好的二进制
├── woc/          # World of ClaudeCraft 游戏逻辑 (Lua)
│   ├── main.lua       # 入口: 创建所有 Service
│   ├── config.lua     # 全局常量
│   ├── shared/        # 共享模块 (命令名/JSON/消息类型)
│   ├── gate/          # Gate Service — WebSocket + 认证
│   ├── world/         # World Service — 核心仿真
│   │   ├── combat/    #   战斗系统 (伤害/治疗/施法/光环)
│   │   ├── mob/       #   Mob AI (仇恨/索敌/行为树)
│   │   ├── profession/ #   专业 (采集/制造)
│   │   ├── social/    #   社交 (组队/交易/决斗)
│   │   └── instance/  #   副本
│   ├── db/            # DB Service — PostgreSQL
│   ├── http/          # HTTP Auth Service — REST API
│   ├── social/        # Social Service — 好友/公会
│   ├── market/        # Market Service — 拍卖行
│   ├── mail/          # Mail Service — 邮件
│   └── proto/         # 内容数据表 (JSON)
├── lualib/       # Moon 标准库
├── service/      # Moon 标准 service
├── src/          # Moon C++ 核心源码
├── third/        # 第三方库 (lua, lcrypt, etc.)
├── premake5.lua  # 编译配置
├── start.cmd     # 启动脚本 (生产)
└── start_dev.cmd # 启动脚本 (开发, 启用 dev 命令)
```

## 快速开始

```cmd
cd moon-server
start.cmd
```

## API 端点

| 方法 | 端点 | 说明 |
|------|------|------|
| POST | `http://localhost:8080/api/register` | 用户注册 |
| POST | `http://localhost:8080/api/login` | 用户登录 |
| GET  | `http://localhost:8080/api/characters` | 角色列表 |
| POST | `http://localhost:8080/api/characters/create` | 创建角色 |
| GET  | `http://localhost:8080/api/realms` | Realm 目录 |
| GET  | `http://localhost:8080/api/status` | 在线状态 |
| GET  | `http://localhost:8080/health` | 健康检查 |

## WebSocket 协议

```
ws://localhost:8787/

Client → Server:
  {"t":"auth-world-5","token":"...","character":1,"clientSeed":"","timerWire":2}
  {"t":"input","seq":1,"mi":{"f":1,b:0,...},"facing":1.5}
  {"t":"cmd","cmd":"chat","text":"Hello"}

Server → Client:
  {"t":"hello","pid":1001,"name":"Arthas","cls":"warrior","realm":"..."}
  {"t":"snap","tick":100,"self":{...},"ents":[...]}
  {"t":"events","list":[...]}
```

## 环境变量

| 变量 | 默认值 | 说明 |
|------|--------|------|
| `WOC_REALM` | Claudemoon | Realm 名称 |
| `DATABASE_URL` | postgres://...@localhost:5433/postgres | PG 连接串 |
| `PORT` | 8787 | WS 端口 |
| `WOC_THREADS` | 4 | 工作线程数 |
| `ALLOW_DEV_COMMANDS` | 0 | 启用开发命令 |

## 重新编译

```cmd
premake5.exe vs2022
msbuild target\Server.sln /p:Configuration=Release
copy target\release\moon.exe bin\
```

## 自托管安装包打包

### 前置条件

- Node.js 24+
- NSIS 3.x（安装到默认路径 `C:\Program Files (x86)\NSIS`）
- `npm run build` 已执行（`dist/` 存在）
- `postgres-src/` 已解压（Windows x64 便携版 PostgreSQL 16，含 `bin/postgres.exe`）
- `moon-server/` 源目录已与 `dist-host-moon/moon-server/` 同步（见下方同步步骤）

### 同步 moon-server 源

打包脚本从项目根 `moon-server/` 复制到 `dist-host-moon/moon-server/`。
如果日常开发在 `dist-host-moon/moon-server/` 中进行，需先将修改同步回源目录：

```cmd
robocopy "dist-host-moon/moon-server/woc" "moon-server/woc" /MIR /NJH /NJS /NDL /NP
robocopy "dist-host-moon/moon-server/lualib" "moon-server/lualib" /MIR /NJH /NJS /NDL /NP
robocopy "dist-host-moon/moon-server/service" "moon-server/service" /MIR /NJH /NJS /NDL /NP
robocopy "dist-host-moon/moon-server/clib" "moon-server/clib" /MIR /NJH /NJS /NDL /NP
```

### 运行打包

在项目根目录执行：

```cmd
node scripts/selfhost/package_host_moon.mjs
```

打包流程：清空 `dist-host-moon/` → 复制 `dist/`（前端）→ 复制 `moon-server/` → 复制 `postgres-src/` → 构建 Node SEA 启动器 → 完成。

### 构建 NSIS 安装包

带上 `--installer` 参数：

```cmd
node scripts/selfhost/package_host_moon.mjs --installer
```

输出文件：

| 文件 | 大小 | 说明 |
|------|------|------|
| `dist-host-moon/WorldOfClaudeCraft-Moon.exe` | ~87 MB | 独立启动器，直接双击运行 |
| `dist-host-moon/WorldOfClaudeCraft-Moon-Server-Setup.exe` | ~517 MB | NSIS 安装包，分发用 |

### 安装包内容

```
安装目录/
├── WorldOfClaudeCraft-Moon.exe     # Node SEA 启动器
├── moon-server/                    # Moon 游戏服务端
│   ├── bin/moon.exe
│   ├── woc/                        # 游戏逻辑
│   ├── lualib/                     # Moon 标准库
│   ├── service/                    # Moon 服务
│   └── clib/                       # C 运行库 (rust.dll, math3d.dll)
├── dist/                           # 网页前端资源
└── postgres/                       # 便携式 PostgreSQL 16
```

### 启动流程（用户视角）

1. 运行安装包 → 安装到 `C:\Program Files\World of ClaudeCraft Server (Moon)\`
2. 双击桌面快捷方式
3. 启动器自动完成：
   - 首次初始化 PostgreSQL 数据目录（`%LOCALAPPDATA%\World of ClaudeCraft\data\`）
   - 生成随机数据库密码，写入 `.env`
   - 启动 PostgreSQL（端口 5433）
   - 启动 Moon 游戏服务端（端口 8788）
   - 启动 HTTP/WS 代理（端口 8787，转发到 Moon）
   - 浏览器打开 `http://localhost:8787`
4. 注册账号 → 创建角色 → 开始游戏

### 卸载

通过 Windows "添加/删除程序" 正常卸载，或运行安装目录下的 `Uninstall.exe`。

卸载会删除：安装目录、开始菜单快捷方式、注册表项。**数据目录**（`%LOCALAPPDATA%\World of ClaudeCraft`）不会被删除，重装后可恢复角色数据。

## 系统状态

| 系统 | 状态 | 文件数 |
|------|------|--------|
| HTTP Auth | ✅ | 1 |
| Gate (WS) | ✅ | 1 |
| World (仿真) | ✅ | 1 |
| 战斗系统 | ✅ | 8 |
| Mob AI | ✅ | 5 |
| 背包/装备 | ✅ | 1 |
| 商店/任务/天赋 | ✅ | 3 |
| 社交(组队/交易/决斗/好友) | ✅ | 4 |
| 银行/工会/专业/副本 | ✅ | 4 |
| 拍卖行/邮件 | ✅ | 2 |
| DB + 持久化 | ✅ | 4 |
| 跨模块(共享/配置/快照) | ✅ | 4 |
| **总计** | | **54** |
