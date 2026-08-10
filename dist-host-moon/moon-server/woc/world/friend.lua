-- World of ClaudeCraft — Friend + Block System
-- friend_add, friend_remove, block_add, block_remove, ignore_add, ignore_remove

local M = {}

--- 初始化社交数据
function M.initSocialData(meta)
    if not meta.friends then meta.friends = {} end
    if not meta.blocked then meta.blocked = {} end
    if not meta.ignored then meta.ignored = {} end
end

--- 添加好友
function M.addFriend(meta, targetPid, targetName)
    M.initSocialData(meta)
    meta.friends[targetPid] = targetName
end

--- 删除好友
function M.removeFriend(meta, targetPid)
    if meta.friends then meta.friends[targetPid] = nil end
end

--- 添加黑名单
function M.blockPlayer(meta, targetPid)
    M.initSocialData(meta)
    meta.blocked[targetPid] = true
end

--- 移除黑名单
function M.unblockPlayer(meta, targetPid)
    if meta.blocked then meta.blocked[targetPid] = nil end
end

--- 添加忽略
function M.ignorePlayer(meta, targetPid)
    M.initSocialData(meta)
    meta.ignored[targetPid] = true
end

--- 移除忽略
function M.unignorePlayer(meta, targetPid)
    if meta.ignored then meta.ignored[targetPid] = nil end
end

return M
