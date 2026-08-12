-- Sproto Protocol Helpers
-- Loads schema at module init, provides pack/unpack for WS wire frames
local sp = require("sproto")
local core = require("sproto.core")

local M = {}

local schema_text = nil
local sproto_inst = nil

-- Load schema text from proto/schema.sproto
local function loadSchema()
    local f = io.open("proto/schema.sproto", "r")
    if not f then f = io.open("woc/proto/schema.sproto", "r") end
    if not f then
        print("[Sproto] schema.sproto not found")
        return false
    end
    schema_text = f:read("*a")
    f:close()
    return true
end

function M.init()
    if sproto_inst then return true end
    if not loadSchema() then return false end
    local ok, err = pcall(function()
        sproto_inst = sp.parse(schema_text)
    end)
    if not ok then
        print("[Sproto] parse failed: " .. tostring(err))
        return false
    end
    print("[Sproto] Schema loaded: Snapshot/Events/Hello/Social/Error/CommandOutcome/GbankLog")
    return true
end

--- Pack a Lua table into binary string for WS transmission
--- @param typename string  e.g. "SnapFrame"
--- @param tbl table        Lua table matching the schema
--- @return string|nil      binary payload, or nil on error
function M.pack(typename, tbl)
    if not sproto_inst then return nil end
    local ok, result = pcall(function()
        return sproto_inst:encode(typename, tbl)
    end)
    if not ok then
        print("[Sproto] pack " .. typename .. " failed: " .. tostring(result))
        return nil
    end
    return result
end

--- Unpack a binary string into a Lua table
--- @param typename string
--- @param bin string       binary payload
--- @return table|nil
function M.unpack(typename, bin)
    if not sproto_inst then return nil end
    local ok, result = pcall(function()
        -- Prepend typename tag byte for dispatch
        -- Sproto decode needs the right type; we use a single-byte type prefix
        return sproto_inst:decode(typename, bin)
    end)
    if not ok then return nil end
    return result
end

--- Frame type tag → typename mapping (1-byte prefix for WS frames)
local TYPE_TAGS = {
    [0x01] = "SnapFrame",
    [0x02] = "EventsFrame",
    [0x03] = "HelloFrame",
    [0x04] = "SocialFrame",
    [0x05] = "ErrorFrame",
    [0x06] = "CommandOutcomeFrame",
    [0x07] = "GbankLogFrame",
}
local TYPE_NAMES = {
    SnapFrame = "\x01",
    EventsFrame = "\x02",
    HelloFrame = "\x03",
    SocialFrame = "\x04",
    ErrorFrame = "\x05",
    CommandOutcomeFrame = "\x06",
    GbankLogFrame = "\x07",
}

--- Pack with type tag prefix (full WS frame: 1 byte type + sproto binary)
function M.packFrame(typename, tbl)
    local bin = M.pack(typename, tbl)
    if not bin then return nil end
    return (TYPE_NAMES[typename] or "\x00") .. bin
end

--- Detect frame type from 1-byte prefix and unpack
--- @return typename, table
function M.unpackFrame(bin)
    if not sproto_inst or #bin < 1 then return nil end
    local tag = string.byte(bin, 1)
    local typename = TYPE_TAGS[tag]
    if not typename then return nil end
    local tbl = M.unpack(typename, string.sub(bin, 2))
    return typename, tbl
end

return M
