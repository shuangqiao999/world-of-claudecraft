-- World of ClaudeCraft — DB Service: World State CRUD
-- 修复: 之前用 $1/$2 占位符但 M.query 只处理 %s → "no parameter $1" 报错

local json = require("json")

local M = {}

function M.register(dbMod)
    local q = dbMod.query
    local qOne = dbMod.queryOne

    dbMod:register("loadWorldState", function(key)
        local row = qOne("SELECT data FROM world_state WHERE key=%s", key)
        if not row then return nil end
        local ok, decoded = pcall(json.decode, row.data)
        if ok then return decoded end
        return nil
    end)

    dbMod:register("saveWorldState", function(key, dataTable)
        local dataJson = json.encode(dataTable)
        q("INSERT INTO world_state (key, data, updated_at) VALUES (%s, %s::jsonb, now()) ON CONFLICT (key) DO UPDATE SET data = EXCLUDED.data, updated_at = now()",
          key, dataJson)
        return true
    end)
end

return M
