-- World of ClaudeCraft — Mail Service

local moon = require("moon")

local M = {}

local mailboxes = {}  -- pid → { mails[] }

moon.dispatch("lua", function(sender, session, msg)
    if type(msg) ~= "table" then return end
    local op = msg.op
    if op == "send" then moon.response("lua", sender, session, M.sendMail(msg.from, msg.to, msg.text, msg.item, msg.copper))
    elseif op == "take" then moon.response("lua", sender, session, M.takeItem(msg.pid, msg.mailId))
    elseif op == "delete" then moon.response("lua", sender, session, M.deleteMail(msg.pid, msg.mailId))
    elseif op == "read" then moon.response("lua", sender, session, M.readMail(msg.pid, msg.mailId))
    elseif op == "list" then moon.response("lua", sender, session, M.listInbox(msg.pid))
    end
end)

function M._getInbox(pid)
    if not mailboxes[pid] then mailboxes[pid] = {} end
    return mailboxes[pid]
end

function M.sendMail(fromPid, toPid, text, item, copper)
    local inbox = M._getInbox(toPid)
    local mailId = #inbox + 1
    inbox[mailId] = {
        id = mailId, from = fromPid, text = text or "", item = item,
        copper = copper or 0, read = false, taken = false, createdAt = os.time(),
    }
    return true, mailId
end

function M.listInbox(pid)
    return M._getInbox(pid)
end

function M.readMail(pid, mailId)
    local inbox = M._getInbox(pid)
    if inbox[mailId] then inbox[mailId].read = true; return inbox[mailId] end
    return nil
end

function M.takeItem(pid, mailId)
    local inbox = M._getInbox(pid)
    local mail = inbox[mailId]
    if not mail or mail.taken then return false end
    mail.taken = true
    return true, mail
end

function M.deleteMail(pid, mailId)
    local inbox = M._getInbox(pid)
    inbox[mailId] = nil
    return true
end

print("[Mail] Service ready")
