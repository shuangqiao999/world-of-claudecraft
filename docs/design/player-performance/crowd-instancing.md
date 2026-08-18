# 人群角色渲染：Instancing 与硬件蒙皮（设计稿）

状态：**方案 A 实施中（Phase 4）** —— 2026-08 客户端性能改造（降低卡顿感）。本稿记录方案、风险与验收，
不擅自改渲染管线（three.js 版本钉死 + `onBeforeCompile` 着色器补丁，见 `src/render/CLAUDE.md`）。

背景：Phase 1-3 已落地（增量视图候选守卫 `renderer.ts`；冻结远骨架跳过地形/水面派生 `renderer.ts:9680-9800`；
人群 LOD 收紧 `crowd_lod.ts` soft 14→10 / min_scale 0.6→0.5 / 压力 0.8→0.6）。人群的剩余每帧成本是
**每具可见蒙皮骨架的 AnimationMixer 骨骼矩阵更新**与**每具独立 mesh 的绘制调用**。

## 现状（事实）

- 每具角色 = 独立 `THREE.Group` + SkeletonUtils 克隆的 `CharacterVisual` + 各自 `AnimationMixer`
  （`createView`、`visual.ts:670`）；已用 LOD 带 + 动画节奏 + 冻结远网格缓解，但**不共享绘制**。
- 动画节奏 `animCadenceFrames`（`crowd_lod.ts:236`）：近带每帧、中带每 2-4 帧、动画远带每 4-6 帧、
  冻结带每 6 帧 keep-warm —— "采样 clip + 重建骨骼矩阵是随人群线性增长的每帧成本"
  （`renderer.ts:10120-10121` 注释）。
- 冻结远网格：`setFar`（`visual.ts:1289`）切到单次绘制的静止 mesh。**几何已按 visual key 共享**
  （`prepareVisual` 烘焙 `idleGeo`），**材质按 (tint|skin|tier) 在 `matCache` 去重**
  （`tintedMaterial`，`assets.ts:1659`）；逐具各持一份 mesh + 材质引用。
- 冻结带实体每 6 帧 tick mixer 保持 warm，供回归动画带时 pose 连续；隐藏期继续演化。
- 冻结带实体同时用 `shadowProxy`（`visual.ts:617-622`）在 shadow pass 画静止轮廓。
- 远 mesh 携带**逐具材质状态**：ghost/stealth 透明度、aura glow、shadowform/moonkin/metamorph 染色、
  rune tint、soul rend（`applyVisualMaterials`，`visual.ts:1379-1386`）。
- 仓库约束：`package.json` 三.js 版本钉死；`renderer.ts` 的材质用 `onBeforeCompile` 补丁，`Material.clone()`
  会丢补丁（用 `material_clone_hooks.ts`）；不得每帧 `new THREE.*`。

## 方案 A：冻结远人群 Instancing（首选，已确定）

把"冻结带"里**同一 pool key** 的远骨架合并到共享的 `THREE.InstancedMesh`。几何（`idleGeo`）与材质
（`tintedFarMaterials` 的 matCache 去重结果）本就共享，这次把**绘制调用**与**每 6 帧的 keep-warm mixer
矩阵更新**也共享掉。

### 分组键与材质

- **分组键 = `visualPoolKeyFor` 返回值**（`mob:template:color:scale` / `npc:template:skin:color:scale`，
  `renderer.ts:4751`）。组内 color/skin 同构，`tintedFarMaterials` 的结果**直接共享**（同一数组对象），
  **不换 `surfaceMat`** —— `surfaceMat` 不覆盖皮肤图集/armor dye/worn 细节，换它会改远带外观。
- 材质来源：首个成员的 `visual.farMeshSharedMaterials`（`this.farMaterials` 只读 getter）。同组其余成员
  由 `matCache` 去重保证同一对象；reconcile 用**材质恒等**做运行时保险：成员材质 ≠ 组材质时回退逐具路径。

### 豁免谓词（信息泄露的根除）

远 mesh 不是"外观一致"的：`applyVisualMaterials` 会替换 farMesh 材质做 ghost/aura/tint。共享材质后这些
逐具效果会丢——其中**潜行是信息泄露**（冻结带里 `stealthGhost` 从半透明变全不透明，违反"不得泄露隐藏
信息"）。因此 `CharacterVisual.farStateActive` 为真（`ghosted || shadowform || moonkin || metamorph ||
soulRend || auraGlowIntensity > 0.01 || runeTint !== null`）的实体**不参与 instancing**，保留现有逐具
远 mesh 路径（含 keep-warm）。这类实体稀少，收益损失可忽略。

### 实例矩阵

- **矩阵源 = `farMesh.matrixWorld`**（保留隐藏 farMesh 作矩阵载体）。`updateMatrixWorld(true)` 逐帧刷新
  子树（group 位置/朝向/scale + poseWrap 泳姿 + farMesh 尸体侧倒 `visual.ts:810-819`），读取其 elements。
- **对比写入**：写 16 浮点前与旧值比较，任一变化才置 `needsUpdate`（稳态人群零 GPU 上传）。
- 远离人群矩阵每帧重算（每组 ≈ 数百次矩阵乘），相比被移除的 mixer 成本可忽略。

### 阴影迁移

- 共享 InstancedMesh `castShadow = true`，取代组内全部逐具 `shadowProxy` 的阴影绘制。
- 冻结带实体经 `setInstancedFar(true)` 隐藏 `shadowProxy`；实体循环的 `setProxyShadow` 按
  `visual.isInstanceFar` 门控，避免逐具/实例双画。
- 附带效果：实例化实体在 proxy 带之外也获得阴影（远距离投影，外观差异可忽略、GPU 成本仍是一次
  instanced draw）。交接口（`shadowRangeSq`/`staticRangeSq`）无空洞。

### keep-warm

- **实例化实体 `animate` 恒 false**：mixer 不再采样/重建骨骼矩阵（回归动画带时从进带瞬间续走，比
  keep-warm 演化后更连续）；`update(dt, s, false)` 仍跑便宜分支以维持 farMesh 局部姿态（尸体侧倒）。
- **豁免实体保留每 6 帧 keep-warm**，与今日行为一致。

### 生命周期（触点同步）

- `createView`：视图初始化 `crowdInstanceFar = false`。
- 实体循环：`setFar` 同处计算 `v.crowdInstanceFar = drawFar && poolKey && !farStateActive`。
- `syncCrowdInstances()`：实体循环后、`matrixWorldAutoUpdate` 门控后统一 reconcile（成员增删、矩阵写入、
  `mesh.count` 收敛、`needsUpdate` 提交）。成员资格每帧重算（含 `group.visible` 守卫，剔除被 cull 的视图）。
- `removeView` / `takePooledVisual`：摘实例 + `setInstancedFar(false)` 复位，池化视觉干净复用。
- InstancedMesh **容量只增不减**（倍增预留，溢出时重建并拷贝矩阵），空组按 idle 帧数延迟回收，避免边界抖动。

### 风险

- 远带切换点进入/退出时序：统一在 reconcile 收集团，成员资格从稳定输入（`isFar`/`visible`/`poolKey`/
  `farStateActive`）单点重算，无帧内增删抖动。
- 三.js 版本钉死：`InstancedMesh` 是稳定 API；补丁着色器不影响实例路径（实例复用同一 `tintedFarMaterials`，
  rim/detail/armor-dye 图层已按既有管线组合）。
- 中带/动画远带（仍走骨架）不受影响。
- 材质恒等回退：皮肤/图集换绑等罕见场景让成员回退逐具路径，安全但不实例化。

## 方案 B：骨架 GPU 蒙皮（硬件蒙皮，高收益高成本，独立里程碑）

> 框架修正：three 0.165 的 `SkinnedMesh` **已在用 bone texture**（本仓 `skin_gpu_layout.ts` 就在做
> bone-texture 裁剪）。CPU 成本不是"逐骨骼上传"，而是 **JS 端 mixer 采样 + 矩阵计算**。方案 B 真正要做的是
> **共享一张烘焙 clip 姿势纹理 + 实例相位**（GPU 顶点动画），需要重写 clip/blend/one-shot/剪鞘中转整条
> 状态机，比"写入 bone-texture 替代上传"的表述工作量大一个量级。

- 每帧把当前骨架姿态写入一张 bone-texture（`BonesTexture`），顶点着色器按实例采样蒙皮，
  替代 CPU 端 `AnimationMixer.update` + 骨骼矩阵计算。
- 三.js 版本钉死 + 着色器补丁：bone-texture 蒙皮需要改每个角色材质的顶点着色器（在
  `onBeforeCompile` 上拼自定义 skin 逻辑），与现有 rim/水/草地等补丁叠加，风险最高；且 `AnimationMixer`
  与 `SkinnedMesh` 的混合语义要整体重接。

### 风险
- 最大：与既有 `onBeforeCompile` 补丁冲突、KEEP/实例混合、shadow pass 也要走同一 bone-texture。
- 建议独立分支验证，接入前先跑 `perf:baseline` + `visual_tour` 截图比对。

## 验收

1. `perf:crowd`（`scripts/crowd_fps_bench.mjs`）在 crowd-80+ 相对 Phase 3 基线再提升（目标 ≥10% 1% low）。
2. 冻结远人群渲染无可见变化（`visual_tour.mjs` 截图，无闪烁/跳变；潜行/glow/tint 实体保持逐具处理）。
3. 动画近带/中带（玩家可操作对象）不被实例化/降频（`animatesEveryFrame` 豁免保持不变）。
4. 全测试套件绿（`crowd_lod`、`render_budget`、`view_create_retry`、`bandwidth`）+
   **新增 `crowd_instance_plan`**（豁免谓词、分组归属、slot 增删/复用、矩阵对比写入、确定性）。
5. 无每帧 `new THREE.*` 分配（`alloc_probe` 稳定）。

## 实施顺序建议

1. 方案 A：冻结远人群 InstancedMesh（本轮 Phase 4，延续 Phase 3，风险可控）。已完成：
   纯 core `crowd_instance_plan.ts` + 测试 + `RENDER_PURE_CORES`；renderer 画家（分组/矩阵/生命周期/
   阴影/keep-warm）；`visual.ts` 豁免 getter + `setInstancedFar`。
2. 方案 B：GPU 蒙皮（独立里程碑，先 bone-texture 原型 + 视觉回归）。
3. 接入前在**有浏览器的环境**跑 `perf:baseline` 与 `visual_tour`（当前机器无 Chrome/Edge，需另行准备）。
