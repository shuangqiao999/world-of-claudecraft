-- World of ClaudeCraft — Chat System
-- 聊天分发、脏词过滤、频道管理

local config = require("config")

local M = {}

-- 简单脏词列表 (Phase 2 基础版，后续可扩展)
local BAD_WORDS = {
    "fuck", "shit", "ass", "bitch", "damn", "crap",
}
for _, w in ipairs(BAD_WORDS) do
    BAD_WORDS[w] = true
end

-- 脏词过滤 (简单替换)
local function filterBadWords(text)
    local filtered = text:lower()
    for word, _ in pairs(BAD_WORDS) do
        if type(word) == "string" then
            filtered = string.gsub(filtered, word, string.rep("*", #word))
        end
    end
    return filtered
end

--- 聊天频道定义
local CHANNELS = {
    say     = { name = "say",     range = 40,   rangeSq = 1600 },
    yell    = { name = "yell",    range = 300,  rangeSq = 90000 },
    party   = { name = "party",   range = math.huge },
    guild   = { name = "guild",   range = math.huge },
    world   = { name = "world",   range = math.huge },
    general = { name = "general", range = 200,  rangeSq = 40000 },
    whisper = { name = "whisper", range = math.huge },
    officer = { name = "officer", range = math.huge },
    lfg     = { name = "lfg",     range = math.huge },
}

--- 处理聊天消息
--- @param entities table 全局实体
--- @param players table 玩家元数据
--- @param senderPid number 发送者 PID
--- @param text string 消息文本
--- @param channel string 频道 (默认 "say")
--- @param target string|nil whisper 目标名
--- @return table 事件列表
function M.processMessage(entities, players, senderPid, text, channel, target)
    if not text or #text == 0 then return {} end
    if #text > 500 then text = string.sub(text, 1, 500) end

    local ch = channel or "say"
    local sender = entities[senderPid]
    local senderMeta = players[senderPid]
    if not sender or not senderMeta then return {} end

    local chanConfig = CHANNELS[ch]
    if not chanConfig then
        ch = "say"
        chanConfig = CHANNELS["say"]
    end

    -- 脏词过滤
    local filtered = filterBadWords(text)

    -- 构建事件
    local events = {}
    local senderName = senderMeta.name or sender.name or "Unknown"
    local senderCls = senderMeta.class or "unknown"

    if ch == "whisper" and target then
        -- Whisper: 发送给特定玩家
        for pid, meta in pairs(players) do
            if string.lower(meta.name or "") == string.lower(target) then
                table.insert(events, {
                    type = "chat",
                    channel = "whisper",
                    from = senderName,
                    fromPid = senderPid,
                    text = filtered,
                    toPid = pid,
                })
                return events
            end
        end
        -- Target not found
        table.insert(events, {
            type = "log",
            text = string.format("%s is not online.", target),
            pid = senderPid,
        })
        return events
    end

    -- 范围聊天 (say, yell, general)
    if chanConfig.rangeSq then
        for pid, otherE in pairs(entities) do
            if otherE.kind == "player" and pid ~= senderPid then
                local dx = sender.pos.x - otherE.pos.x
                local dz = sender.pos.z - otherE.pos.z
                local distSq = dx * dx + dz * dz
                if distSq <= chanConfig.rangeSq then
                    table.insert(events, {
                        type = "chat",
                        channel = ch,
                        from = senderName,
                        fromPid = senderPid,
                        text = filtered,
                        toPid = pid,
                    })
                end
            end
        end
    else
        -- 全局频道: 发送给所有玩家
        for pid, _ in pairs(players) do
            if pid ~= senderPid then
                table.insert(events, {
                    type = "chat",
                    channel = ch,
                    from = senderName,
                    fromPid = senderPid,
                    text = filtered,
                    toPid = pid,
                })
            end
        end
    end

    -- 自己的消息也要回显
    table.insert(events, {
        type = "chat",
        channel = ch,
        from = senderName,
        fromPid = senderPid,
        text = filtered,
        toPid = senderPid,
    })

    return events
end

--- 处理 emotes
function M.processEmote(entities, players, senderPid, emoteId)
    local sender = entities[senderPid]
    if not sender then return end

    -- 设置头顶表情
    sender.overheadEmoteId = emoteId
    sender.overheadEmoteSeq = (sender.overheadEmoteSeq or 0) + 1
end

return M
