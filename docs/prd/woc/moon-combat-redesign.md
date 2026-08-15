# Moon 服务端 — GTA 式开放世界战斗重设计（协议契约）

服务端（`moon-server/woc/`）已完成 GTA 式战斗重设计的核心逻辑。本文是**服务端 ↔ 客户端
协议契约**：客户端（`src/`，TypeScript）尚未接入，需按下列契约补齐 wire 命令与快照字段。

## 玩家战斗状态机

玩家实体新增 `combatState` 字段，取值（快照 `self.cst` 下发）：

| 值 | 含义 |
|---|---|
| `idle` | 空闲 |
| `auto_fight` | 自动战斗（打怪物/平民 NPC） |
| `pvp_fight` | 玩家对战（需手动确认） |
| `fleeing` | 逃跑（只停我方输出，**不免伤**，怪物仍追击） |
| `dead` | 死亡 |

## 客户端需新增的 wire 命令

### `pvp_attack`（新增，加入 `COMMAND_NAMES`，append-only）

- 参数：`{ cmd: 'pvp_attack', id: <targetPid> }`（也接受 `target`/`pid` 字段）。
- 语义：对当前选中的玩家目标**手动二次确认开 PVP**。双方进入 `pvp_fight`。
- 服务端门控：`config.ENABLE_PLAYER_PVP == false` 时拒绝（log "Player PvP is disabled."）。
- 跨分片目标（ghost）的同意转发暂未实现（后续 Phase）。

### `target`（语义变更，不新增）

- `{ cmd: 'target', id }` 现在按目标类型分流：
  - **mob / pedestrian NPC** → 立即 `enterAutoFight`（选怪即自动攻击；空手 `mainhandItemId == nil` 时只选中不攻击）。
  - **player / 友好 NPC** → 仅选中（`combatState = idle`），客户端应弹出交互菜单（私聊 / 加好友 / 攻击），**不自动开战**。
- `id == null` 或目标无效 → 清空目标回 `idle`。

### `stopattack`（语义变更）

- 现进入 `fleeing`（停输出 + 清目标，不免伤），用于「点击地面逃跑」。

### `attack`（语义变更）

- 目标解析优先级：显式 `id` > 当前选中 `targetId` > 最近敌人；不再无条件打最近。
- 玩家目标不会触发自动攻击（走 `pvp_attack`）。

## 客户端需新增的快照字段

`snap.self` 新增 `cst`（字符串，取值见上表）、`wanted`（数字，通缉值 0-5）。客户端应据此渲染逃跑 / 战斗状态与通缉星标（未知字段可忽略，不破坏现有解析）。

## 服务端已实现的规则（客户端无需实现，仅展示语义）

1. **怪物追击**：每场追击随机上限 `[0.7, 1.0] × MONSTER_MAX_CHASE_DIST(120)`，超过即放弃追杀清仇恨回巡逻。
2. **仇恨扩散**：击杀怪物时，周边同阵营敌对怪围殴击杀者（社交仇恨）。
3. **PVP 伤害门控**：`dealDamage` 中玩家对玩家伤害需双方 `pvp_fight` 或决斗链接，否则 0（自由世界不再默认互攻）。
4. **跨分片 PVP 同意**：`pvp_attack` 指向 ghost 玩家时，经 `pvpConsent` 消息转发归属分片标记被攻击方 `pvp_fight`。
5. **通缉/恶名**：击杀平民 NPC 或其他玩家累积通缉值（`wantedLevel` 0-5，60s/级衰减）；通缉期间城市路人 NPC 变敌对围殴玩家。
6. **异常兜底**：目标死亡/消失/迁移 → 回 `idle`；断线重连清自动战斗状态；死亡 → `dead`。
