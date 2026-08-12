-- World of ClaudeCraft — 帧构建辅助 (纯 JSON)
-- 对应原项目 server/game.ts 中的 round2, wireEntity 等辅助函数

local json = require("json")

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

--- 构建 hello 帧 JSON
function M.buildHelloFrame(pid, seed, name, cls, realm, softWords, chatMutedUntil)
    return json.encode({
        t = "hello",
        pid = pid,
        seed = seed,
        name = name,
        cls = cls,
        realm = realm,
        softWords = softWords or {},
        chatMutedUntil = chatMutedUntil,
    })
end

--- 构建错误帧 JSON
function M.buildErrorFrame(errorLiteral)
    return json.encode({
        t = "error",
        error = errorLiteral,
    })
end

--- 构建 commandOutcome 帧 JSON
function M.buildCommandOutcomeFrame(rid, ok)
    return json.encode({
        t = "commandOutcome",
        rid = rid,
        ok = ok,
    })
end

--- 构建 events 帧 JSON (单次编码, 避免逐事件 encode 拼接)
function M.buildEventsFrame(events)
    return json.encode({
        t = "events",
        list = events,
    })
end

--- 构建 snap 帧 JSON (string.format 拼接)
--- 注意: selfJson / entsArr / keepArr 为已编码 JSON 片段, 必须嵌入而非再编码
function M.buildSnapFrame(tick, simTime, selfJson, entsArr, keepArr, timerWireVersion)
    local parts = {}
    parts[#parts + 1] = string.format('{"t":"snap","tick":%d,"time":%.2f', tick, M.round2(simTime))
    if timerWireVersion then
        parts[#parts + 1] = string.format(',"tw":%d', timerWireVersion)
    end
    if type(selfJson) ~= "string" then selfJson = M.safeEncode(selfJson) end
    parts[#parts + 1] = string.format(',"self":%s', selfJson)
    if type(entsArr) ~= "table" then entsArr = {} end
    parts[#parts + 1] = string.format(',"ents":[%s]', table.concat(entsArr, ","))
    if keepArr and #keepArr > 0 then
        parts[#parts + 1] = string.format(',"keep":[%s]', table.concat(keepArr, ","))
    end
    parts[#parts + 1] = "}"
    return table.concat(parts)
end

--- 构建 social 帧 JSON (客户端在线读取顶层 friends/blocks/ignores/guild)
function M.buildSocialFrame(data)
    return json.encode({
        t = "social",
        friends = data and data.friends or {},
        blocks = data and data.blocks or {},
        ignores = data and data.ignores or {},
        guild = data and data.guild or nil,
    })
end

--- 构建 censor 帧 JSON
function M.buildCensorFrame(softWords)
    return json.encode({ t = "censor", softWords = softWords })
end

return M
