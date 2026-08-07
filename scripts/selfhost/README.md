# 自托管打包（Windows 局域网服务器）

把 World of ClaudeCraft 的权威服务器 + 前端 + 便携版 PostgreSQL 打包成一个
`WorldOfClaudeCraft-Server-Setup.exe` 安装包。安装后双击
`WorldOfClaudeCraft.exe`，同一局域网设备通过 `http://<本机IP>:8787`
注册账号、创建角色、联机游玩。

## 产物

| 产物 | 说明 |
|---|---|
| `dist-host/WorldOfClaudeCraft.exe` | Node SEA 单文件启动器（内嵌 `launcher.mjs`） |
| `dist-host/WorldOfClaudeCraft-Server-Setup.exe` | NSIS 安装器（lzma 压缩，约 500 MB） |
| `dist-host/dist/` | 构建好的前端（服务器静态服务它） |
| `dist-host/dist-server/` | esbuild 打包的权威服务器 |
| `dist-host/postgres/` | 便携版 PostgreSQL 16（zonky 预编译二进制） |
| `dist-host/node.exe` | Node 运行时（跑服务器） |

启动器行为：
1. 首次运行自动 `initdb` 到数据目录、启动 PostgreSQL（仅监听 127.0.0.1:5433）。
2. 生成 `.env`（随机 POSTGRES_PASSWORD），启动权威服务器（监听全部网卡 :8787）。
3. 添加 Windows 防火墙放行规则（TCP 8787，需管理员）。
4. 打印局域网访问地址。关闭窗口即优雅停机。

数据目录：安装目录可写时（便携模式）为安装目录下的 `data/` 和 `.env`；
安装到 Program Files 等只读目录时，自动落到 `%LOCALAPPDATA%\World of ClaudeCraft`。

## 构建步骤

前置：已 `pnpm install`，且 Node 可用。

```bash
# 1. 构建前端 + 服务器（产物进入 dist/ 和 dist-server/）
npm run build
npm run build:server

# 2. 准备便携版 PostgreSQL（一次性）
#    下载 zonky windows-x64 二进制，解压为 postgres-src/ 根目录含 bin/ share/ lib/
#    npm 包：@embedded-postgres/windows-x64（版本对应 PG 版本号，如 16.14.0-beta.17）

# 3. 组装 payload + 编译安装器（需本机安装 NSIS 3.x）
npm run host:installer
```

分步：
- `npm run host:package`：仅组装 `dist-host/` payload，不编译安装器。
- `npm run host:installer`：组装 payload 并调用 NSIS 编译安装器（lzma 压缩约 7 分钟）。

## 安装与使用

1. 双击 `WorldOfClaudeCraft-Server-Setup.exe`，选择安装目录，完成安装。
2. 开始菜单或桌面运行 "World of ClaudeCraft Server"。
3. 看到 `server is UP` 和控制台列出的 `lan: http://<本机IP>:8787`。
4. 其他设备在同一局域网内打开该网址，注册账号并创建角色进入世界。
5. 停机：关闭启动器窗口（postgres 优雅快速停机）或在窗口里按 Ctrl+C
   （先保存游戏服务，再 `pg_ctl stop -m fast`）。关闭窗口最多丢失最近一次
   30 秒自动存档之间的内存态。

## 安全说明

- 默认不启用 `ALLOW_DEV_COMMANDS`（作弊命令）。
- PostgreSQL 只绑定 127.0.0.1，不对外暴露。
- 面向局域网信任模型：对公网开放需自行加 TLS 反向代理与 `PUBLIC_ORIGIN`。
- `.env` 和 `data/` 含数据库密码，勿分享给他人。

## 排障

- `data/postgres.log`：PostgreSQL 日志（在数据目录下）。
- 启动器窗口内的输出即服务器日志。
- 端口占用：`WOC_GAME_PORT=8899`（或其他值）环境变量可换端口，
  启动器会把它写进 `.env` 的 `PORT`。
