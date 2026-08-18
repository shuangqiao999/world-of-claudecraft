# Moon 空间分片：pid 分片玩家的 region 内部可见性

状态：**待开发 / 未实现** —— 在 5000-bot 压测战役中产出的后续修复规格（测量背景见
`docs/moon-server-load-test-retrospective.md`）。开工前先读那份复盘。

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

## 参考点（开工前重新核对代码）

- 玩家出生：`moon-server/woc/world/init.lua` `createPlayerEntity`（pos = 0,0）与 `joinPlayer`。
- NPC 按 region 归属：`moon-server/woc/world/npc_spawn.lua` spawnAll。
- ghost 同步边界规则与节奏：`moon-server/woc/world/init.lua` `ghostSync`；`config.GHOST_SYNC_INTERVAL_TICKS`。
- ghost 预算 + LITE 路径：`moon-server/woc/world/snapshot.lua`（P2a ghost 循环）。
- 交互转发：`moon-server/woc/world/command_dispatch.lua` `H.interact`、`M.npcLines`；
  `moon-server/woc/world/init.lua` `forwardInteract` / `interactForward`。
- 迁移门：`moon-server/woc/world/init.lua` 迁移检测与 `migratePlayerOut`；`config.MIGRATE_*`。
