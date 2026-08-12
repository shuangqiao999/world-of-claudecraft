-- World of ClaudeCraft — Wire Frame Builders (Sproto → JSON fallback)
-- All builders produce Sproto binary by default; fall back to JSON if Sproto not available.

local json = require("json")
local M = {}

-- Lazy-loaded sproto handle (avoids Lua 5.4/5.5 version mismatch at import time)
local _spack = nil
local function getSpack()
    if _spack ~= nil then return _spack end
    local ok, mod = pcall(require, "shared.sproto_helpers")
    if ok then _spack = mod
    else _spack = false end
    return _spack
end

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

--- 判断是否使用 Sproto (配置开关 + 初始化状态)
local _sprotoOk = nil
local function useSproto()
    if _sprotoOk ~= nil then return _sprotoOk end
    if not require("config").SPROTO_ENABLED then
        _sprotoOk = false; return false
    end
    local s = getSpack()
    if not s or not s.packFrame then
        _sprotoOk = false; return false
    end
    local ok = s.packFrame("ErrorFrame", { error = "probe" })
    _sprotoOk = (ok ~= nil)
    return _sprotoOk
end

-- ===== Hello Frame =====
function M.buildHelloFrame(pid, seed, name, cls, realm, softWords, chatMutedUntil)
    if useSproto() then
        return getSpack().packFrame("HelloFrame", { pid = pid, seed = seed, name = name, cls = cls, realm = realm, level = 1, skin = 0 })
    end
    return json.encode({ t = "hello", pid = pid, seed = seed, name = name, cls = cls, realm = realm, softWords = softWords or {}, chatMutedUntil = chatMutedUntil })
end

-- ===== Error Frame =====
function M.buildErrorFrame(errorLiteral)
    if useSproto() then
        return getSpack().packFrame("ErrorFrame", { error = errorLiteral })
    end
    return '{"t":"error","error":' .. M.safeEncode(errorLiteral) .. '}'
end

-- ===== Command Outcome Frame =====
function M.buildCommandOutcomeFrame(rid, ok)
    if useSproto() then
        return getSpack().packFrame("CommandOutcomeFrame", { rid = rid, ok = ok })
    end
    return json.encode({ t = "commandOutcome", rid = rid, ok = ok })
end

-- ===== Events Frame =====
function M.buildEventsFrame(events)
    if useSproto() then
        return getSpack().packFrame("EventsFrame", { list = events })
    end
    return json.encode({ t = "events", list = events })
end

-- ===== Snap Frame =====
function M.buildSnapFrame(tick, simTime, selfJson, entsArr, keepArr, timerWireVersion)
    if type(selfJson) ~= "string" then selfJson = M.safeEncode(selfJson) end
    if type(entsArr) ~= "table" then entsArr = {} end
    if type(keepArr) ~= "table" then keepArr = {} end
    if useSproto() then
        return getSpack().packFrame("SnapFrame", { tick = tick, time = simTime, tw = timerWireVersion or 0, self = selfJson, ents = entsArr, keep = keepArr })
    end
    local parts = {}
    parts[#parts + 1] = string.format('{"t":"snap","tick":%d,"time":%.2f', tick, M.round2(simTime))
    if timerWireVersion then parts[#parts + 1] = string.format(',"tw":%d', timerWireVersion) end
    parts[#parts + 1] = string.format(',"self":%s', selfJson)
    parts[#parts + 1] = string.format(',"ents":[%s]', table.concat(entsArr, ","))
    if keepArr and #keepArr > 0 then parts[#parts + 1] = string.format(',"keep":[%s]', table.concat(keepArr, ",")) end
    parts[#parts + 1] = "}"
    return table.concat(parts)
end

-- ===== Social Frame =====
function M.buildSocialFrame(data)
    if useSproto() then
        local friends = {}
        if data and data.friends then for _, f in ipairs(data.friends) do table.insert(friends, { id = f.id or 0, name = f.name or "", class = f.class or "", online = f.online or false }) end end
        local guildTbl = nil
        if data and data.guild then
            local g = data.guild; local members = {}
            if g.members then for _, m in ipairs(g.members) do table.insert(members, { id = m.id or 0, name = m.name or "", class = m.class or "", level = m.level or 1, online = m.online or false }) end end
            guildTbl = { id = g.id or 0, name = g.name or "", rank = g.rank or 0, members = members }
        end
        return getSpack().packFrame("SocialFrame", { friends = friends, blocks = data and data.blocks or {}, ignores = data and data.ignores or {}, guild = guildTbl, pendingInvites = data and data.pendingInvites or {} })
    end
    return json.encode({ t = "social", friends = data and data.friends or {}, blocks = data and data.blocks or {}, ignores = data and data.ignores or {}, guild = data and data.guild or nil })
end

-- ===== Censor Frame (仅 JSON) =====
function M.buildCensorFrame(softWords)
    return json.encode({ t = "censor", softWords = softWords })
end

return M
