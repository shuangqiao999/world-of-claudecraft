# Moon 空间分片：pid 分片玩家的 region 内部可见性

状态：**已实现（方案 A 区域级 ghost 同步）** —— 原始规格在 5000-bot 压测战役中产出
（测量背景见 `docs/moon-server-load-test-retrospective.md`）。方案 A 已落地并验证，记录如下；
若需回退，配置 `ENABLE_REGION_INTERNAL_GHOST=false`（`WOC_ENABLE_REGION_INTERNAL_GHOST=0`）即可。

## 问题

在 smart 玩家迁移下（玩家留在其 `pid % shardCount` 分片，除非真正长途旅行进入新 region），
一个站在**异分片拥有**的 region 内部的玩家，看不到也无法与那 region 的**内部**实体交互——
NPC、mob、采集节点、可拾取物体。

成因链：

1. 每个 world 分片只生成/拥有其所属 region 的静态内容（NPC 经 `npc_spawn.lua`、营地 mob、节点），
   判定为 `regionToShard(regionOf(pos)) == shardId`（`moon-server/woc/world/npc_spawn.lua:56-59`）。
2. 跨分片可见依赖 `ghostSync`，它只序列化**离 region 边界 135yd 内**的实体，且只发给相邻 region 的拥有分片。
   region 内部的实体从不被同步。
3. 站在 shard X 拥有的 region 内部的 pid 分片 Y 玩家，因此在那里看到空世界
   （探针复现：1 级角色在出生点看到零实体）。
4. `interact` 已经能把 ghost NPC 转发到归属分片（`command_dispatch.lua` `H.interact` ->
   `forwardInteract` -> `interactForward`），但那只对**靠近边界且被同步**的 NPC 有效；内部 NPC 连 ghost 都不是。

这是**空间模型限制**，不是迁移改动的回归：凡是迁移让玩家留在 pid 分片、而玩家身处异 region 时都会出现。
旧行为（无条件迁移）"能用"只是因为它把所有玩家合并到 region 分片——而那正是 smart 迁移修复掉的性能炸弹。

## 需求

在保留 5000-bot 负载分布（48/48 分片、~6Hz+）的前提下，选取一个自洽的方案（见下），
让玩家能看到并与其所在 region 的世界交互。

### 方案 A —— 区域级 ghost 同步（推荐方向）

扩展 ghost 同步：对玩家当前所在 region，把该 region（及其 8 邻域）的**内容实体**即使位于内部
也作为 ghost 下发。

- 范围：把内部内容实体广播给拥有该 region 的分片（或给该 region 内所有有玩家的分片），不只是边界邻居。
- 成本控制：内部 ghost 是静态 NPC/mob/节点——变化稀少，可按低节奏同步（如 `GHOST_SYNC_INTERVAL_TICKS` x N），
  交付后走既有 ghost FULL/LITE/keep 路径，不进每 tick 热路径。
- 交互（对话/商店/任务/采集/拾取）走既有 ghost 转发（`interactForward`、`nodeForward`、`lootForward`）。
- 玩家间可见性已被既有边界 ghost 同步 + 战斗转发覆盖；只有**内容**需要区域级扩展。

### 方案 B —— 出生点分布

给新角色一组散布在不同 region（不同分片拥有）的起始出生点，让迁移自然地把他们分配到各分片。

- 比方案 A 便宜，且彻底消除单 region 热点；但是内容/玩法改动（多个出生城镇），且不解决
  **旅行进入异 region 内部**时的底层不可见问题。

### 方案 C —— 玩家按 region 分片拥有（出生即迁移）

玩家 join 时立即迁到其 region 分片（旧行为），但对**后续**旅行保留 smart 检测门，使出生热点可控。
只有在该 region 出生人口有上限时才可行；会重新引入拥挤单出生点的合并问题。

## 验收标准

1. 1 级角色在出生城镇能看到城镇 NPC，并成功 `interact`（对话/任务/商店）——内部 NPC 不再返回
   "Nothing to interact with."。
2. 走进异 region 内部的玩家能看到该 region 的 mob/NPC/节点，并能采集/拾取/战斗（服务端跨片解析）。
3. 5000-bot 扎堆压测保持 >= 48/48 分片、快照 Hz >= 5（即修复不得重新引入迁移合并）。
4. 无快照帧回归：内部 ghost 走 FULL/LITE/keep delta 路径，不进每 tick 热构建。

## 已实现（方案 A）

- **数据层**：`region_remote_map`（regionKey -> 远端分片集合）。每 `REGION_REMOTE_SCAN_INTERVAL_TICKS`
  （4）tick 扫本分片玩家，玩家处于异 region 时向该 region 归属分片发 `regionPresence`（进入/换区/离开三态），
  登出/迁移/宽限清理经 `leavePlayer`/`cleanupPlayerLocal` 钩子清 presence。
- **ghostSync 扩展**：`syncRegionInternalGhosts` 按 `GHOST_SYNC_INTERVAL_TICKS * GHOST_REGION_INTERNAL_MULT`
  （15）tick 节奏，收集 owned region 内容实体（NPC/mob/节点/可拾取物/尸体，**排除玩家**），
  `ghost.serialize` 复用 `_wireVer` 缓存免重编码，`MAX_REGION_INTERNAL_GHOST`（256）截断告警，
  推送 `regionInternalGhost` 到远端分片；对离开的远端发空列表清陈旧 ghost。
  原有边界 135yd ghostSync 逻辑完整保留，两套共存。
- **接收端**：`ghostByRegion[src][regionKey]` 全量替换，与 `ghostByShard` 独立，进入 `ghostEntities`/grid，
  快照 P2a 预算渲染、`H.interact` 扫描、战斗 `combatForward` 天然生效。
- **交互全链路**：`H.interact` ghost 分支扩展至 node/object；新增三个跨片事务通道
  `vendorForward/vendorStockReply`（商店）、`nodeForward/nodeReply`（采集）、
  `lootForward/lootReply`（拾取）——均沿用 `forwardInteract` 的 forward -> owner 校验 -> reply -> 本分片应用模式，
  不改 `command_dispatch` 核心。
- **配置**：`ENABLE_REGION_INTERNAL_GHOST`（总开关）、`GHOST_REGION_INTERNAL_MULT=3`、
  `MAX_REGION_INTERNAL_GHOST=256`、`REGION_REMOTE_SCAN_INTERVAL_TICKS=4`（`config.lua`，环境可覆盖，重启生效；
  sharetable 热更列为后续独立基础设施项）。

### 验证结果

- 功能：出生点 0 实体 -> 8 NPC + 17 节点可见；`interact` 返回任务行（Scourge's End accept）；
  跨片购买链路执行（vendorForward reply 返回）。
- 性能（5000 压测，内部 ghost ON）：5000/5000 接入保持、48/48 分片均衡、快照 Hz best ~13.05、
  gap p50 ~82.7ms —— 与修复前基线（13.42/82.5）一致，无退化。

## 参考点（重新核对代码）

- 玩家出生：`moon-server/woc/world/init.lua` `createPlayerEntity`（pos = 0,0）与 `joinPlayer`。
- NPC 按 region 归属：`moon-server/woc/world/npc_spawn.lua` spawnAll。
- ghost 同步边界规则与节奏：`moon-server/woc/world/init.lua` `ghostSync`；`config.GHOST_SYNC_INTERVAL_TICKS`。
- ghost 预算 + LITE 路径：`moon-server/woc/world/snapshot.lua`（P2a ghost 循环）。
- 交互转发：`moon-server/woc/world/command_dispatch.lua` `H.interact`、`M.npcLines`；
  `moon-server/woc/world/init.lua` `forwardInteract` / `interactForward`。
- 迁移门：`moon-server/woc/world/init.lua` 迁移检测与 `migratePlayerOut`；`config.MIGRATE_*`。
