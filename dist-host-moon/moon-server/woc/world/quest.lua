-- World of ClaudeCraft — Quest System
-- accept, turnin, abandon, 条件跟踪
-- 任务定义从 proto/quests.json 加载 (TS QuestDef 格式)

local M = {}

-- 任务表 (启动时从 proto 填充)
local QUESTS = {}
local questsLoaded = false

--- 从 proto/quests.json 加载任务 (TS QuestDef: giverNpcId/objectives/xpReward/copperReward/itemRewards)
function M.loadFromProto()
    if questsLoaded then return end
    local ok, proto = pcall(function() return require("proto.load") end)
    if not ok then return end
    local quests = proto.questsById
    if not quests then return end

    for qid, q in pairs(quests) do
        if type(q) == "table" and q.id then
            local objectives = {}
            for _, o in ipairs(q.objectives or {}) do
                local entry = { type = o.type, count = o.count or 0 }
                if o.targetMobId then entry.target = o.targetMobId end
                if o.itemId then entry.target = o.itemId end
                if o.type == "collect" and o.itemId then entry.target = o.itemId end
                if not entry.target and o.target then entry.target = o.target end
                table.insert(objectives, entry)
            end
            QUESTS[qid] = {
                id = q.id,
                name = q.name or qid,
                giverNpcId = q.giverNpcId,
                turnInNpcId = q.turnInNpcId,
                minLevel = q.minLevel or 1,
                suggestedPlayers = q.suggestedPlayers or 1,
                requiresQuest = q.requiresQuest,
                description = q.text or "",
                objectives = objectives,
                rewards = {
                    copper = q.copperReward or 0,
                    xp = q.xpReward or 0,
                    items = q.itemRewards or {},
                },
            }
        end
    end
    questsLoaded = true
    print(string.format("[Quest] Loaded %d quests from proto", #QUESTS))
end

--- 初始化玩家任务数据
function M.initQuestData(meta)
    if not meta.qlog then meta.qlog = {} end       -- { questId = { accepted, objectives: {} } }
    if not meta.qdone then meta.qdone = {} end      -- { questId = true }
end

--- 接受任务
function M.acceptQuest(meta, questId)
    M.initQuestData(meta)
    local quest = QUESTS[questId]
    if not quest then return false, "Unknown quest" end
    if meta.qdone[questId] then return false, "Already completed" end
    if meta.qlog[questId] then return false, "Already accepted" end

    local obj = {}
    for _, o in ipairs(quest.objectives) do
        obj[o.type] = { target = o.target, count = 0, required = o.count }
    end

    meta.qlog[questId] = { accepted = os.time(), objectives = obj }
    return true, quest
end

--- 提交任务
function M.turninQuest(meta, questId)
    M.initQuestData(meta)
    local quest = QUESTS[questId]
    local qd = meta.qlog[questId]
    if not quest then return false, "Unknown quest" end
    if not qd then return false, "Not accepted" end

    -- 检查条件
    for _, o in ipairs(quest.objectives) do
        local obj = qd.objectives[o.type]
        local cur = (obj and obj.count) or 0
        if cur < o.count then return false, "Objectives not complete: " .. tostring(cur) .. "/" .. o.count end
    end

    -- 发放奖励 (XP 由 xp.grantXp 处理, 避免双重)
    meta.copper = (meta.copper or 0) + (quest.rewards.copper or 0)
    if quest.rewards.items then
        local inventory = require("world.inventory")
        for _, itm in ipairs(quest.rewards.items) do
            inventory.addItem(meta, itm)
        end
    end

    meta.qlog[questId] = nil
    meta.qdone[questId] = true
    return true, quest.rewards
end

--- 放弃任务
function M.abandonQuest(meta, questId)
    M.initQuestData(meta)
    if meta.qlog[questId] then
        meta.qlog[questId] = nil
        return true
    end
    return false
end

--- 更新任务进度 (击杀 mob)
function M.onKill(meta, mobTemplateId)
    M.initQuestData(meta)
    local updated = {}

    for qid, qd in pairs(meta.qlog) do
        local obj = qd.objectives["kill"]
        if obj and obj.target == mobTemplateId then
            obj.count = math.min(obj.count + 1, obj.required)
            table.insert(updated, { questId = qid, current = obj.count, required = obj.required })
        end
        local objAny = qd.objectives["kill_any"]
        if objAny then
            objAny.count = math.min(objAny.count + 1, objAny.required)
            table.insert(updated, { questId = qid, current = objAny.count, required = objAny.required })
        end
    end

    return updated
end

--- 获取可用任务列表
function M.getAvailableQuests(meta)
    M.initQuestData(meta)
    local available = {}
    for qid, quest in pairs(QUESTS) do
        if not meta.qdone[qid] and not meta.qlog[qid] then
            table.insert(available, quest)
        end
    end
    return available
end

--- 获取任务数据表
function M.getQuestTable()
    return QUESTS
end

return M
