# Moon 自托管压测复盘（2000 / 5000 bot 大乱斗）

一次性报告，记录 2026-08-18 针对安装版自托管 Moon 服务端
（`World of ClaudeCraft-Moon.exe`）的压测战役、由此驱动的 gate 扩容工作，以及分层根因分析。
历史记录，非现状依据。

## TL;DR 结论

| 问题 | 结论 |
|---|---|
| 服务端能否承载 **2000** 并发战斗玩家？ | **能** —— 2000/2000 接入、0 失败、稳定 2 小时、gate 负载约 40% |
| 服务端能否承载 **5000** 并发战斗玩家？ | **连接能、数据面能、仿真是上限** —— 5000/5000 接入并保持；快照帧缩小 ~100-300x（750KB → ~3KB），Hz 从 ~0.2 提到 ~2.7；剩余上限是 ~3000 人同屏战斗时的 world 仿真 CPU |
| 历次 ~950-1000 的"入场墙"真凶是什么？ | **同机压测客户端单进程饱和**（一个 Node 进程），不是服务端 |
| 5000 扎堆时 750KB 快照帧的成因？ | **跨分片 ghost 的 FULL 记录无上限**（每条 ~5KB），不是本地实体 delta 路径 |
| ghost 修好后快照 Hz 仍塌到 ~1 的成因？ | **空间迁移把新玩家全部合并到出生点分片**（单分片峰值 ~4950 人），不是仿真逻辑或战斗 |
| 20Hz 配置（commit `8b750d45b`）后低负载能多高？ | 40 bot 低负载 ~16Hz、静态 ~8Hz、5000 全程 best ~13.4Hz（原 10Hz 配置只有 6.6） |

## 交付内容（commit `f28e9f04e`）

- **Gate 加固（P0）** —— `moon-server/woc/gate/init.lua`
  - 快照帧率上限 `SNAP_SEND_HZ`（默认 10Hz，后调 20Hz）+ 负载自适应降级
    `SNAP_SEND_HZ_DEGRADED`（5Hz），由 keepalive 清扫迟到驱动（`recoverStreak`，修复永久锁降级 bug）。
  - 保活收割：2 轮无 pong 防护（`noPongStreak`）后才收割；`skippedSnaps >= GATE_STALLED_SKIP_REAP`
    只切日志标签（`Stalled reap` / `Keepalive reap`），不控制断开。
  - 会话拆除器（`detachSession` + 宽限期 `sessionsByChar` 清理）+ 每 10s 写 `log/gate-metrics.log` 的 `[GateMetric]`。
- **多 Gate（P1）** —— `main.lua`、`gate/init.lua`、`world/init.lua`
  - `GATE_COUNT` 个 gate 服务（`gate_0..N`），各自独立线程与端口（HTTP `port+2k`、WS `wsPort+2k`）。
  - pid 空间 = `gateIndex * GATE_PID_STRIDE + seq`（`STRIDE=100_000_000`），保持 `pid % worldShards`
    轮询分片且不与 world 实体 id 冲突。
  - world 按 `gateOf(pid)` 路由、快照按 gate 拆分下发；跨 gate resume 用活跃租约探针
    （`getCharacterLease`）+ `queryPlayerGate`。
- **WS 直连** —— `launcher_moon.mjs`、`src/net/online.ts`
  - `/api/status` 返回 `wsPorts`；浏览器直连 gate WS 端口，把 Node 代理从数百 MB/s 数据路径上移走，
    代理只剩静态 + `/api`；gate WS 端口加防火墙放行。
- **压测工具** —— `scripts/big_battle_load.mjs`
  - 渐进加人、移动 + 战斗模拟、逐观察者快照指标、`WS_PORTS` 直连、多进程支持。

## 快照优化（P2，commit `a72c3fd9f`）

把扎堆帧从 ~750KB 压到 ~3KB、快照 Hz 在 5000 人时从 ~0.2 提到 ~2.7（best 均值），全程无客户端协议改动
（wire 仍是 JSON full/lite/keep）。

- **Ghost LITE + 预算**（`snapshot.lua`、`ghost.lua`、`grid.lua`）—— 750KB 帧的真凶：跨分片 ghost 是
  FULL 记录、无上限、一变就整包重发。现在首见 FULL、变化 LITE、否则 keep，并纳入 `MAX_VISIBLE` 预算，
  按 pid 旋转取序（免排序）。`queryGhosts` 加 `maxCount` 上限，扎堆时不再每个观察者扫全量 ghost（~4845 个）。
- **帧级分频**（`world/init.lua`）—— 活跃玩家（战斗/移动）每 `SNAP_ACTIVE_DIVISOR` tick 造帧，静止每
  `SNAP_IDLE_DIVISOR` tick 造帧；idle→active 立即补帧，战斗反馈不等 idle 节拍。战斗事件走独立通道。
- **战斗优先级**（`snapshot.lua`）—— 目标/攻击者先拿预算，扎堆裁剪不会丢掉当前战斗对象。
- `ghost.serialize` 同时产出 `full` + `lite` 两条 wire。

5000 扎堆实测（10 x 500，10 分钟）：帧 p50 ~3KB（原 30-65KB，p95 ~760-840KB）、gate 流量 ~20MB/s（原 ~240MB/s）、
快照 Hz best-mean ~2.65（原 ~0.2）。剩余上限是 world 仿真 CPU —— 每分片每 tick 跑 ~156 个活跃玩家的
移动 + 战斗 + 快照构建 —— 不再是快照数据面。

## 方法论（重要教训）

客户端与服务端同机。**单个 Node 压测进程在接收数百 MB/s 快照的同时，最多只能维持 ~950-1000 条 WS 连接**——
新连接的 `hello` 被数据洪流堵在事件循环里，30s 超时判失败，这就是历次单进程运行反复出现的"入场墙"。

有效测量需把 bot 拆到多个 Node 进程（每个 ~500 连接）。5000-bot 用 10 x 500。

复现：

```bash
# 前置: 安装版服务端运行中; DATABASE_URL 指向自托管 PG
export SERVER_URL=http://localhost:8787
export WS_PORTS=8789,8791          # 直连 gate WS 端口 (绕过代理)
# 2000 bot, 2h: 4 进程 x 500
BOTS=500 DURATION_MS=7200000 OBSERVERS=6 COMBAT_RATIO=0.6 node scripts/big_battle_load.mjs &
# 重复 x4
# 5000 bot, 10 min: 10 进程 x 500
BOTS=500 DURATION_MS=600000 OBSERVERS=6 COMBAT_RATIO=0.6 node scripts/big_battle_load.mjs &  # x10
```

服务端真实指标在 `moon-server/woc/log/gate-metrics.log` 的 `[GateMetric]`：
`[GateMetric] t=.. sessions=.. sends=.. bytes=.. skip=.. reap=.. interval=.. delayStreak=..`

## 结果

### 2000-bot 战斗，2 小时持续（4 x 500，双 gate，WS 直连）

| 指标 | 值 |
|---|---|
| 接入 | **2000/2000，0 失败** |
| 连接保持 | **2000/2000 满 2 小时**（reap=0）|
| 快照 Hz/玩家 | best 19.3，稳定 ~6-10（当时 10Hz 上限）|
| 快照体积 | p50 ~46-53 KB（P2 之前）|
| gate 负载 | ~1000 会话/gate，~2500 sends/s，~120MB/s，`delayStreak=0` |

### 5000-bot 战斗，10 分钟持续（10 x 500，双 gate，WS 直连）——优化前基线

| 指标 | 值 |
|---|---|
| 接入 | **5000/5000，0 失败** |
| 连接保持 | **5000/5000 满 10 分钟，0 收割，health 探测 0 失败** |
| gate 负载 | 2500 会话/gate，`delayStreak=0`，`reap=0` |
| 快照 Hz/玩家 | **~0.1-0.3** |
| 快照间隔 | p50 ~2.5s，p95 8-11s，max ~22s |
| 快照体积 | p50 ~30-65KB，**p95 ~760-840KB，max ~1.38MB** |

## 分层根因（实验证实）

1. **Node 启动器代理** —— 不是墙。WS 直连后单客户端入场墙没变；代理 `health` 失败只在单测试客户端饱和时出现。
2. **Gate Lua 线程** —— 不是墙。2000-5000 会话时双 gate 只跑到 40-50% 容量，全程 `delayStreak=0`。
3. **压测客户端（同机）** —— 历次 ~950-1000 入场墙的真源。bot 拆多进程后 2000、5000 都 0 失败。
4. **world 分片快照构建** —— 5000 扎堆上限曾经是**无上限的跨分片 ghost FULL 记录**：玩家按 pid 分布但空间扎堆，
   每个玩家 AOI 内 ~155 条 ghost FULL（~5KB/条）一变就重发。本地实体 delta 路径已被 `MAX_VISIBLE` 封顶，
   不是问题。ghost LITE + 预算 + 查询上限之后，帧数据面不再是瓶颈；剩余成本是每分片每 tick ~156 个活跃玩家的仿真。

## world 分片 CPU：空间迁移是炸弹（commit `871356332`）

快照数据面修好后，Phase-0 剖面对生产开放的 `log/world-diag.log` 显示分片 tick 仍 ~300ms、快照 Hz ~1.2。剖面结论明确：

- 48 分片里**只有 2-4 个有玩家**（W0 最终 ~4950），其余空转。`combat` 每 10s 仅 5ms、玩家子系统循环 ~700ms，
  但 **`bcastBuild` 每 10s ~6100ms** —— 单分片给 ~2000 人造帧。
- 根因：**空间玩家迁移**把每个玩家重新安置到其所在 region 的分片。整个测试（以及每个新角色）都在单一出生区，
  于是所有人合并到那一个分片。

修复（迁移保留为功能，检测不再因微小扰动触发）：
- 迁移评估每 `MIGRATE_CHECK_INTERVAL_TICKS`（1s）一次；仅对离开提交点超过 `MIGRATE_MIN_TRAVEL`（50yd）的玩家；
  仅跨过 region 边界后；需连续稳定 `MIGRATE_STABLE_SECONDS`（2s）；迁移后 `MIGRATE_COOLDOWN_SECONDS`（15s）冷却。
- 出生/静止玩家永不迁移 → 均匀分布在 pid 分片。真正长途旅行的玩家仍迁到其 region 分片（正确的空间行为），
  边界 + 冷却两道门消除振荡重迁。
- 顺带修复：`_migrateCooldown` 原本从未赋值；`playerMigrate` 发送 `cls = meta.cls`（恒 nil，迁移丢职业）→ `meta.class`。
- `H.interact` 现在可对话 ghost NPC：`interact` 转发给归属分片，`M.npcLines` 本地与跨片共用。

5000 扎堆实测（迁移开启 + smart 检测）：分片数 2 → **48/48**；快照 Hz ~1.2 → **峰值 3.8、全程 best ~6.6**；
5000/5000 保持；3 个热分片（W8/W9/W47，~60-75% bcastBuild）承接真正走远跨界的 bot。
纯容量基线（`WOC_DISABLE_MIGRATION=1`）更平缓 ~6.3Hz；迁移保持生产默认。

## 快照下发速率对齐 world tick（commit `8b750d45b`）

迁移修复后 world 有余量。原 10Hz gate 上限下，2000/5000 的全程 best 只有 ~6.6Hz。把 `SNAP_SEND_HZ` 提到 15
实测只有 ~8Hz —— **对齐假象**：20Hz 输入 + 0.067s 间隔的按墙钟节流实际每 2 帧发 1 帧（~10Hz）。

改为 **`SNAP_SEND_HZ = 20`**（与 world tick 自然对齐）+ `SNAP_ACTIVE_DIVISOR = 1`（活跃玩家每 tick 造帧）+
`SNAP_IDLE_DIVISOR = 2`（静止 10Hz）。下发速度 = world 造帧速度，gate 不再人为限速；事件循环卡顿仍由
`SNAP_SEND_HZ_DEGRADED=5` 保护。

验证（20Hz 配置）：
- 40 bot 低负载：gap p50 **62.9ms（~16Hz）**（原 8Hz）
- 静态 100 bot：**8.13Hz**（≥7-8Hz 达标）
- 5000 压测：5000/5000 全在线，全程 **best 13.42Hz**、gap 82.5ms（~12Hz）（原 6.6）
- 2 gate 在 20Hz 下依旧 `delayStreak=0`，余量充足

## 结论

- 服务端在完整扩容栈（双 gate、WS 直连、帧率上限、保活收割、smart 迁移）下**接受并保持 5000 并发玩家**，
  快照数据面交付 ~3KB 帧（缩小 100-300x）。
- **5000 人挤一个地理点战斗**：smart 迁移下 ~4-7Hz（best ~13.4），残余成本是承接走远 bot 的几个热分片 +
  每分片 ~100 战斗者的仿真。
- 计划中的现实验收场景（静态 5000 ≥7-8Hz、~1000 战斗者 ≥5Hz）在本轮快照上限调参后已满足静态一项，战斗一项待复测。
- 剩余事项：现实场景复测、二进制 wire（空间分片内部可见性已实现，见下节）。

## Region 内部内容实体可见性修复（方案 A，commit `fb5089bfd`）

Smart 迁移保留性能收益后暴露的架构缺陷：玩家逻辑分片 ≠ 所在 region 归属分片时，region 内部的
NPC/mob/采集节点/可拾取物不做边界 ghost 同步，异 region 玩家看到"鬼城"。已按方案 A（区域级 ghost 同步）修复：

- **presence 数据层**：`region_remote_map` + 每 4 tick 降采样上报，玩家处于异 region 时通知归属分片
  （进入/换区/离开三态），登出/迁移/宽限清理钩子清 presence。
- **内部 ghost 分发**：`syncRegionInternalGhosts` 按 15 tick 节奏推送 owned region 内容实体
  （排除玩家，`_wireVer` 缓存零重编码，256 上限截断），接收端 `ghostByRegion` 按 region 替换，
  与边界 135yd ghostSync 独立共存。
- **交互全链路**：`H.interact` 支持 ghost node/object；新增 `vendorForward/nodeForward/lootForward`
  三个跨片事务通道（owner 校验 -> reply -> 本分片应用），沿用 `forwardInteract` 模式。

验证：出生点 0 实体 -> 8 NPC + 17 节点可见、interact 返回任务行；5000 压测 48/48 分片、
快照 Hz best ~13.05（修复前基线 13.42）——功能达成、性能无退化。

## 待办

- [ ] 迁移修复 + 20Hz 调参后复测验收场景：5000 静态与 ~1000 战斗者（调 COMBAT_RATIO），期望 ≥7-8Hz 与 ≥5Hz。
- [ ] 二进制 wire 帧（JSON 字符串 key 约占帧体积 40%）—— 客户端 + 服务端协议级改动，延期。
- [ ] 分布出生点的（真实感）5000-bot 运行，区分"扎堆 AOI 密度"与"绝对世界容量"。
- [ ] 异机压测（bot 放第二台机器），彻底消除同机客户端测量上限。
