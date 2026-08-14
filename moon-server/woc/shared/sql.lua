-- World of ClaudeCraft — Safe SQL Builder
-- 用 gsub 令牌替换替代 string.format 构建 SQL:
--   %s → 单引号转义字符串 (注入安全)
--   %d → 严格整数 (tonumber 校验, 拒绝非数字)
--   %f → 严格浮点
-- 关键: 替换值内的 % 不会被 string.format 二次解释 (数据含 % 不再破坏 SQL)
-- 修复: string.format 的 %s 值注入 %b/%o 等格式符导致 SQL 损坏

local M = {}

--- 字符串转义 (PG 标准 conforming strings: '' 即可)
local function esc(v)
    if v == nil then return "NULL" end
    return "'" .. string.gsub(tostring(v), "'", "''") .. "'"
end

--- 安全 SQL 格式化: 仅处理 %s/%d/%f, 其余原样
function M.fmt(fmt, ...)
    local args = { ... }
    local i = 0
    local sql = string.gsub(fmt, "%%[sdf]", function(m)
        i = i + 1
        local v = args[i]
        if v == nil then
            return "NULL"
        end
        if m == "%d" then
            local n = tonumber(v)
            if n == nil then
                error(string.format("SQL %%%s: non-numeric value: %s", m, tostring(v)))
            end
            return tostring(n)
        elseif m == "%f" then
            local n = tonumber(v)
            if n == nil then
                error(string.format("SQL %%%s: non-numeric value: %s", m, tostring(v)))
            end
            return tostring(n)
        end
        return esc(v)
    end)
    return sql
end

--- 转义单个值 (供手写 SQL 使用)
function M.esc(v)
    return esc(v)
end

return M
