# 人群角色渲染：Instancing 与硬件蒙皮（设计稿）

状态：**设计待实施** —— 2026-08 客户端性能改造（降低卡顿感）的 Phase 4。本稿记录方案、风险与验收，
不擅自改渲染管线（three.js 版本钉死 + `onBeforeCompile` 着色器补丁，见 `src/render/CLAUDE.md`）。

背景：Phase 1-3 已落地（增量视图候选守卫 `renderer.ts`；冻结远骨架跳过地形/水面派生 `renderer.ts:9680-9800`；
人群 LOD 收紧 `crowd_lod.ts` soft 14→10 / min_scale 0.6→0.5 / 压力 0.8→0.6）。人群的剩余每帧成本是
**每具可见蒙皮骨架的 AnimationMixer 骨骼矩阵更新**与**每具独立 mesh 的绘制调用**。

## 现状（事实）

- 每具角色 = 独立 `THREE.Group` + SkeletonUtils 克隆的 `CharacterVisual` + 各自 `AnimationMixer`
  （`renderer.ts:7009`、`visual.ts:670/1956`）；已用 LOD 带 + 动画节奏 + 冻结远网格缓解，但**不共享绘制**。
- 动画节奏 `animCadenceFrames`（`crowd_lod.ts:236`）：近带每帧、中带每 2-4 帧、动画远带每 4-6 帧、
  冻结带每 6 帧 keep-warm —— "采样 clip + 重建骨骼矩阵是随人群线性增长的每帧成本"
  （`renderer.ts:10120-10121` 注释）。
- 冻结远网格：`setFar`（`visual.ts:1289`）切到单次绘制的静止 mesh，每具各持一份。
- 仓库约束：`package.json` 三.js 版本钉死；`renderer.ts` 的材质用 `onBeforeCompile` 补丁，`Material.clone()`
  会丢补丁（用 `material_clone_hooks.ts`）；不得每帧 `new THREE.*`。

## 方案 A：冻结远人群 Instancing（首选，低风险）

把"冻结带"里**同一视觉键（visual key）**的远骨架合并到共享的 `THREE.InstancedMesh`：

- 每个 visual key 一个共享的静止几何 + 材质（复用 `surfaceMat`），实例矩阵 = 各远骨架的世界变换。
- 每帧只更新实例矩阵（一次 `setMatrixAt` 批量），一次 `renderObject` 画完整个远人群。
- 生命周期：远带进入/离开时增删实例；复用 `visualPoolKeyFor`（`renderer.ts:7229`）决定分组。
- 冻结带 keep-warm 的 mixer 不再需要（静止 mesh 不驱动），进一步省掉该带每 6 帧的矩阵更新。
- 视觉差异：远人群从"每具一个静止模型"变"一个实例化的共享模型"——几何/材质相同，外观一致，仅
  transform 不同，玩家无法分辨。

### 风险
- 远带切换点（`showsStaticFarMesh`）的进入/退出时序：需在 `sync()` 的 LOD 计划后、实体循环前统一
  收集团，避免帧内增删抖动。
- 三.js 版本钉死：`InstancedMesh` 是稳定 API，补丁着色器不影响它（实例用同一材质），风险集中在
  共享材质的 `onBeforeCompile` 正确性——走 `surfaceMat` 而非 clone。
- 中带/动画远带（仍走骨架）不受影响。

## 方案 B：骨架 GPU 蒙皮（硬件蒙皮，高收益高成本）

把中带/动画远带的骨骼矩阵更新从 CPU 移到 GPU：

- 每帧把当前骨架姿态写入一张 bone-texture（`BonesTexture`），顶点着色器按实例采样蒙皮，
  替代 CPU 端 `AnimationMixer.update` + 每骨骼矩阵上传。
- 三.js 版本钉死 + 着色器补丁：bone-texture 蒙皮需要改每个角色材质的顶点着色器（在
  `onBeforeCompile` 上拼自定义 skin 逻辑），与现有 rim/水/草地等补丁叠加，风险最高；且 `AnimationMixer`
  与 `SkinnedMesh` 的混合语义要整体重接。

### 风险
- 最大：与既有 `onBeforeCompile` 补丁冲突、KEEP/实例混合、shadow pass 也要走同一 bone-texture。
- 建议独立分支验证，接入前先跑 `perf:baseline` + `visual_tour` 截图比对。

## 验收

1. `perf:crowd`（`scripts/crowd_fps_bench.mjs`）在 crowd-80+ 相对 Phase 3 基线再提升（目标 ≥10% 1% low）。
2. 冻结远人群渲染无可见变化（`visual_tour.mjs` 截图，无闪烁/跳变）。
3. 动画近带/中带（玩家可操作对象）不被实例化/降频（`animatesEveryFrame` 豁免保持不变）。
4. 全测试套件绿（`crowd_lod`、`render_budget`、`view_create_retry`、`bandwidth`）。
5. 无每帧 `new THREE.*` 分配（`alloc_probe` 稳定）。

## 实施顺序建议

1. 方案 A：冻结远人群 InstancedMesh（本轮 Phase 3 的延续，风险可控）。
2. 方案 B：GPU 蒙皮（独立里程碑，先 bone-texture 原型 + 视觉回归）。
3. 接入前在**有浏览器的环境**跑 `perf:baseline` 与 `visual_tour`（当前机器无 Chrome/Edge，需另行准备）。
