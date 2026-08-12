-- World of ClaudeCraft — JSON 编码辅助函数
-- 对应原项目 server/game.ts 中的 round2, wireEntity 等辅助函数

local json = require("json")
local fmt = require("fmt")
local spack = require("shared.sproto_helpers")

local M = {}

--- 浮点数保留两位小数
function M.round2(n)
    if type(n) ~= "number" then return n end
    return math.floor(n * 100 + 0.5) / 100
end

--- 安全 JSON 编码 (捕获错误)
function M.safeEncode(t)
    local ok, result = pcall(json.encode, t)
    if ok then return result end
    return "null"
end

--- 安全 JSON 解码 (捕获错误)
function M.safeDecode(s)
    if type(s) ~= "string" or #s == 0 then return nil end
    local ok, result = pcall(json.decode, s)
    if ok then return result end
    return nil
end

--- 构建 hello 帧 (Sproto binary)
function M.buildHelloFrame(pid, seed, name, cls, realm, softWords, chatMutedUntil)
    -- softWords/chatMutedUntil unused in current code paths, retained for compatibility
    return spack.packFrame("HelloFrame", {
        pid = pid, seed = seed, name = name, cls = cls, realm = realm,
        level = 1, skin = 0,
    })
end

--- 构建错误帧 (Sproto binary)
function M.buildErrorFrame(errorLiteral)
    return spack.packFrame("ErrorFrame", { error = errorLiteral })
end

--- 构建 commandOutcome 帧 (Sproto binary)
function M.buildCommandOutcomeFrame(rid, ok)
    return spack.packFrame("CommandOutcomeFrame", { rid = rid, ok = ok })
end

--- 构建 events 帧 (Sproto binary)
function M.buildEventsFrame(events)
    return spack.packFrame("EventsFrame", { list = events })
end

--- 构建 snap 帧 (Sproto binary — self/ents 作为 JSON 字符串嵌入)
function M.buildSnapFrame(tick, simTime, selfJson, entsArr, keepArr, timerWireVersion)
    if type(selfJson) ~= "string" then selfJson = M.safeEncode(selfJson) end
    if type(entsArr) ~= "table" then entsArr = {} end
    if type(keepArr) ~= "table" then keepArr = {} end
    return spack.packFrame("SnapFrame", {
        tick = tick,
        time = simTime,
        tw = timerWireVersion or 0,
        self = selfJson,
        ents = entsArr,
        keep = keepArr,
    })
end

--- 构建 social 帧 (Sproto binary)
function M.buildSocialFrame(data)
    local friends = {}
    if data and data.friends then
        for _, f in ipairs(data.friends) do
            table.insert(friends, {
                id = f.id or 0, name = f.name or "", class = f.class or "", online = f.online or false,
            })
        end
    end
    local guildTbl = nil
    if data and data.guild then
        local g = data.guild
        local members = {}
        if g.members then
            for _, m in ipairs(g.members) do
                table.insert(members, {
                    id = m.id or 0, name = m.name or "", class = m.class or "",
                    level = m.level or 1, online = m.online or false,
                })
            end
        end
        guildTbl = { id = g.id or 0, name = g.name or "", rank = g.rank or 0, members = members }
    end
    return spack.packFrame("SocialFrame", {
        friends = friends,
        blocks = data and data.blocks or {},
        ignores = data and data.ignores or {},
        guild = guildTbl,
        pendingInvites = data and data.pendingInvites or {},
    })
end

--- 构建 censor 帧 JSON
function M.buildCensorFrame(softWords)
    return json.encode({
        t = "censor",
        softWords = softWords,
    })
end

return M
