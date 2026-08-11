-- World of ClaudeCraft — 消息类型常量
-- 对应原项目 moon.core PTYPE + 自定义事件类型

local M = {}

-- Moon 内部 PTYPE (来自 src/moon/core/config.hpp)
M.PTYPE_SYSTEM = 1
M.PTYPE_TEXT = 2
M.PTYPE_LUA = 3
M.PTYPE_ERROR = 4
M.PTYPE_DEBUG = 5
M.PTYPE_SHUTDOWN = 6
M.PTYPE_TIMER = 7
M.PTYPE_SOCKET_TCP = 8
M.PTYPE_SOCKET_UDP = 9
M.PTYPE_SOCKET_WS = 10
M.PTYPE_SOCKET_MOON = 11
M.PTYPE_INTEGER = 12
M.PTYPE_LOG = 13

-- 拒绝错误字面量
M.WS_AUTH_ERROR = {
    badAuthMessage = "bad auth message",
    authRequired = "authentication required",
    notAuthenticated = "not authenticated",
    noSuchCharacter = "no such character",
    alreadyInWorld = "character already in world",
    realmFull = "realm is full",
    tooManyConnections = "too many connections from your network",
    forceRename = "This character must be renamed before entering the world.",
    authTimedOut = "authentication timed out",
    incompatibleWorldLayout = "incompatible world version",
}

-- 事件类型
M.EVENT_TYPE = {
    CHAT = "chat",
    LOG = "log",
    ERROR = "error",
    LOOT = "loot",
    GUILD_RENAMED = "guildRenamed",
    UNSTUCK_BLOCKED = "unstuck",
}

-- 聊天频道
M.CHAT_CHANNEL = {
    SAY = "say",
    YELL = "yell",
    GENERAL = "general",
    PARTY = "party",
    GUILD = "guild",
    OFFICER = "officer",
    WORLD = "world",
    LFG = "lfg",
    WHISPER = "whisper",
    SYSTEM = "system",
}

return M
