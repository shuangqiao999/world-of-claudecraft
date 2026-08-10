-- World of ClaudeCraft — Message Rate Limiting
-- 每个会话的 WS 消息频率限制
-- 对应原项目 server/msg_rate_limit.ts

local config = require("config")
local M = {}

-- 速率限制参数
local REFILL_RATE = 120    -- 每秒恢复 120 tokens
local BURST_SIZE = 180     -- 突发容量 180 messages
local SAMPLE_WINDOW = 5    -- 5 秒窗口

-- 会话速率状态: { pid → { tokens, lastRefill, drops, dropWindowStart } }
local sessions = {}

--- 初始化会话
function M.init(pid)
    sessions[pid] = {
        tokens = BURST_SIZE,
        lastRefill = os.time(),
        drops = 0,
        dropWindowStart = 0,
        kicked = false,
    }
end

--- 清理会话
function M.cleanup(pid)
    sessions[pid] = nil
end

--- 检查并记录一个消息是否允许通过
--- @return boolean 是否允许
function M.allowMessage(pid)
    local s = sessions[pid]
    if not s then
        M.init(pid)
        s = sessions[pid]
    end

    if s.kicked then return false end

    local now = os.time()

    -- 补充 tokens
    local elapsed = now - s.lastRefill
    if elapsed > 0 then
        s.tokens = math.min(BURST_SIZE, s.tokens + elapsed * REFILL_RATE)
        s.lastRefill = now
    end

    -- 检查是否有可用 token
    if s.tokens >= 1 then
        s.tokens = s.tokens - 1
        return true
    end

    -- 拒绝，记录 drop
    s.drops = s.drops + 1

    -- 滑动窗口 drop 计数
    if s.dropWindowStart == 0 then
        s.dropWindowStart = now
    elseif now - s.dropWindowStart > SAMPLE_WINDOW then
        s.drops = 1
        s.dropWindowStart = now
    end

    -- 持续超标则踢出
    if s.drops > BURST_SIZE then
        s.kicked = true
        print(string.format("[RateLimit] KICK pid=%d drops=%d", pid, s.drops))
        return false
    end

    return false
end

--- 检查是否被踢
function M.isKicked(pid)
    local s = sessions[pid]
    return s and s.kicked
end

return M
