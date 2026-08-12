-- World of ClaudeCraft — Entity 数据结构
-- 定义游戏中所有实体的属性和操作
-- 对应原项目 src/sim/types.ts + src/sim/entity.ts baseEntity
-- 与 TS Entity 接口逐字段对齐

local config = require("config")

local M = {}

--- 实体原型
local Entity = {}
Entity.__index = Entity

--- 创建新实体 (baseEntity 等效)
function Entity.new(id, kind, templateId, name, level, pos)
    return setmetatable({
        -- 基础身份
        id = id,
        kind = kind,              -- "player" | "mob" | "npc" | "object" | "pet" | "node"
        templateId = templateId,  -- 模板 ID (如 "warrior", "wolf")
        name = name or "",
        level = level or 1,

        -- 位置和朝向
        pos = pos or M.defaultPos(),
        prevPos = { x = pos.x, y = pos.y, z = pos.z },
        facing = 0,
        prevFacing = 0,

        -- 速度 (物理)
        vx = 0, vy = 0, vz = 0,
        onGround = true,
        jumping = false,
        fallStartY = pos.y,

        -- 游泳 / 呼吸
        swimStroke = 0,
        swimDiving = false,
        fatigueTicks = 0,
        breathUsedTicks = 0,
        drownTicks = 0,

        -- 生命值
        hp = 100,
        maxHp = 100,

        -- 资源 (Mana/Rage/Energy/Focus/Runic)
        resource = 0,
        maxResource = 0,
        resourceType = nil,

        -- 核心属性 (Stats)
        stats = {
            str = 0, agi = 0, sta = 0, int = 0, spi = 0,
            armor = 0, pvpOffense = 0, pvpDefense = 0,
        },

        -- 武器
        weapon = { min = 1, max = 2, speed = 2 },
        offhandWeapon = nil,
        dualWielding = false,
        titansGrip = false,

        -- 战斗属性
        attackPower = 0,
        rangedPower = 0,
        spellPower = 0,
        meleeHaste = 0,
        rangedHaste = 0,
        spellHaste = 0,
        setProcs = {},
        critChance = 0.05,
        sharedCritBonus = 0,
        critRating = 0,
        hasteRating = 0,
        hitRating = 0,
        hitBonus = 0,
        critDmgSpellBonus = 0,
        critDmgPhysBonus = 0,
        critDmgHealBonus = 0,
        dodgeChance = 0.05,
        blockChance = 0,
        blockValue = 0,
        castPushbackReduction = 0,
        knockbackResistance = 0,
        ccDurationReduction = 0,

        -- 移动速度
        moveSpeed = 7,
        hostile = false,

        -- 状态
        dead = false,
        ghost = false,
        lootable = false,
        afk = false,
        gm = false,
        devGod = false,

        -- 战斗状态
        inCombat = false,
        combatTimer = 99,
        fiveSecondRule = 99,

        -- 目标
        targetId = nil,
        castTargetId = nil,
        castAim = nil,
        aggroTargetId = nil,
        forcedTargetId = nil,
        forcedTargetTimer = 0,
        shuffleTargetTimer = 0,

        -- 施法
        castingAbility = nil,
        castRemaining = 0,
        castTotal = 0,
        channeling = false,
        channelTickTimer = 0,
        channelTickEvery = 0,
        channelTicksLeft = 0,

        -- GCD / 冷却
        gcdRemaining = 0,
        potionCdRemaining = 0,
        potionCooldownUntil = -1,
        firebottleCdRemaining = 0,
        cooldowns = {},

        -- 队列施法
        queuedOnSwing = nil,
        queuedCastAbility = nil,
        queuedCastAim = nil,

        -- 连击点
        comboPoints = 0,
        comboUntil = -1,
        overpowerUntil = -1,

        -- 自动攻击
        swingTimer = 0,
        offhandSwingTimer = 0,
        autoAttack = false,

        -- 冲锋
        chargeTargetId = nil,
        chargeTimeLeft = 0,
        chargePath = {},

        -- 跟随
        followTargetId = nil,

        -- 姿态
        sitting = false,
        eating = nil,              -- { remaining }
        drinking = nil,            -- { remaining }

        -- 光环
        auras = {},
        stealthed = false,
        ccDr = {},

        -- 坐骑
        mountKey = nil,
        mountCastRemaining = 0,
        mountCastKey = nil,

        -- 外观
        weaponStowed = false,
        helmHidden = false,
        skin = nil,
        skinCatalog = "class",
        mainhandItemId = nil,
        offhandItemId = nil,
        weaponSkinId = nil,
        weaponSkinLoadout = {},
        equippedItems = {},
        equippedInstances = {},

        -- 宠物
        petMode = "defensive",
        petTauntTimer = 0,
        petAutoTaunt = false,
        petAutoWaterJet = false,
        petPath = {},

        -- Mob AI 状态
        aiState = "idle",
        tappedById = nil,
        pulseTimer = 0,
        stompTimer = 0,
        bigCastTimer = 0,
        deathZoneCastTimer = 0,
        deathZoneStrikeTimer = 0,
        infernoTimer = 0,
        infernoRemaining = 0,
        infernoPulsesFired = 0,
        infernoGatesFired = 0,
        yelledEngage = false,
        stoneskinTimer = 0,
        terrifyTimer = 0,
        aoeSlowTimer = 0,
        loudYellTimer = 0,
        loudYellIndex = 0,
        detonateTimer = 9999,
        mendTimer = 0,
        wardTimer = 0,
        channelTimer = 0,
        channelRamp = 0,
        rallyTimer = 0,
        warcryTimer = 0,
        firedSummons = 0,
        summonedIds = {},
        summonedAdd = false,
        enraged = false,
        healedThisPull = false,

        -- Mob 仇恨
        threat = {},

        -- Mob 脱离
        evadeStall = 0,
        chaseStall = 0,
        evadeEpoch = 0,
        combatExitHoldUntil = 0,
        chainPullInbound = false,
        fleeTimer = 0,
        fleeReturnTimer = 0,
        hasFled = false,

        -- Mob 漫游
        wanderTarget = nil,
        wanderTimer = 0,

        -- 主人信息 (宠物/召唤物)
        ownerId = nil,
        petOwnerHpBonus = 0,
        petPathCooldown = 0,

        -- 出生/尸体
        spawnPos = nil,
        leashAnchor = nil,
        respawnTimer = 0,
        corpseTimer = 0,
        lootFfaTimer = 9999,
        harvestClaimedBy = nil,
        loot = nil,
        xpValue = 0,
        corpsePos = nil,
        corpseInstanceId = nil,

        -- 任务/商店
        questIds = {},
        vendorItems = {},
        objectItemId = nil,

        -- 副本
        dungeonId = nil,

        -- 缩放/颜色
        scale = 1,
        color = 0xffffff,

        -- 采集/制造施法状态
        gatherCastNodeId = "",
        gatherCastToolRarity = "",
        gatherCastEffectConfirmed = false,
        craftCastRecipeId = "",
        craftCastCommission = false,
        craftCastBatchRemaining = 0,
        craftCastBatchTotal = 0,
        enchantCastItemId = "",
        enchantCastEquipSlot = "",
        enchantCastEnchantId = "",
        toolRechargeCastProfessionId = "",

        -- 钓鱼
        fishBiteAtTick = 0,
        fishReelDeadlineTick = 0,
        fishCastZoneId = "",

        -- 其他
        savedMana = 0,

        -- 公会/头衔
        guild = nil,
        title = nil,

        -- 头顶图标
        overheadEmoteId = nil,
        overheadEmoteSeq = 0,
        overheadEmoteUntil = 0,

        -- 特殊标记 (持有者/Discord/dev)
        holderTier = nil,
        holderBalance = nil,
        discordTier = nil,
        discordAvatar = nil,
        discordName = nil,
        discordJoined = nil,
        discordRole = nil,
        devTier = nil,
        devMergedPrs = nil,
        githubLogin = nil,
        aiAccount = false,
        streamerLinks = nil,
    }, Entity)
end

--- 默认出生位置
function M.defaultPos()
    return { x = 0, y = 0, z = 0 }
end

--- 计算两个实体之间的平方距离
function Entity.distanceSq(e1, e2)
    local dx = e1.pos.x - e2.pos.x
    local dz = e1.pos.z - e2.pos.z
    return dx * dx + dz * dz
end

--- 计算实体到点的平方距离
function Entity.distanceToPointSq(e, px, pz)
    local dx = e.pos.x - px
    local dz = e.pos.z - pz
    return dx * dx + dz * dz
end

-- 导出构造函数
M.new = Entity.new

return M
