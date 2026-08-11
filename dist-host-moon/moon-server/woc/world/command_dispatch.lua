-- World of ClaudeCraft — Command Dispatch
-- 以客户端 src/world_api.ts COMMAND_NAMES 为准的命令分发。
-- 每个客户端命令名/参数字段必须与 online.ts 发送面一致 (客户端不变, 协议为硬约束)。
-- 需要真实系统未实现处, 先返回 ok=false 并给玩家一条 log, 绝不静默丢弃。

local M = {}

-- 数值参数安全转换 (TS dispatch 都先 type-check)
local function n(v) return (type(v) == "number" and v) or (type(v) == "string" and tonumber(v)) or nil end
local function s(v) return (type(v) == "string" and v) or nil end

-- 解析目标 id (优先 msg.id, 回退 msg.target / msg.pid 数字)
local function targetIdOf(cmd)
    return n(cmd.id) or n(cmd.target) or n(cmd.pid)
end

-- 未实现回退: 发一条 log, 返回 false (调用方负责 commandOutcome)
local function notImplemented(ctx, pid, name)
    ctx.noteEvents({ { type = "log", text = name .. " is not implemented yet.", pid = pid } })
    return false
end

-- 所有逻辑返回 (ok, detail); 有 rid 的命令由调用方统一应答 commandOutcome

-- 取玩家 meta (安全)
local function metaOf(ctx, pid)
    return ctx.players[pid]
end

local H = {}

-- ============ 战斗 ============
function H.cast(ctx, pid, cmd)
    local e = ctx.entities[pid]
    if not e or e.dead then return false end
    local abilityId = s(cmd.ability)
    if not abilityId then return false end
    local ability = ctx.abilities.ABILITIES[abilityId]
    if not ability then
        ctx.noteEvents({ { type = "log", text = "Unknown ability: " .. abilityId, pid = pid } })
        return false
    end
    if ctx.castSys.isOnCooldown(e, ability) then
        ctx.noteEvents({ { type = "log", text = "Ability is on cooldown", pid = pid } })
        return false
    end
    local target = nil
    local tId = n(cmd.target)
    if tId then target = ctx.entities[tId] end
    if not target then target = ctx.findNearestEnemy(e) end
    if not target and ability.effects and ability.effects[1] then
        local et = ability.effects[1].target
        if et == "self" then target = e
        elseif et == "enemy" or et == "single" then target = ctx.findNearestEnemy(e) end
    end
    if ability.requiresTarget and target and target ~= e then
        local maxRange = (ability.range and ability.range > 0) and ability.range or ctx.config.MELEE_RANGE
        local dx = e.pos.x - target.pos.x
        local dz = e.pos.z - target.pos.z
        if math.sqrt(dx * dx + dz * dz) > maxRange + 2 then
            ctx.noteEvents({ { type = "log", text = "Out of range.", pid = pid } })
            return false
        end
    end
    local ok, ct = ctx.castSys.startCast(e, ability, target)
    if not ok then
        ctx.noteEvents({ { type = "log", text = "Cannot cast " .. abilityId, pid = pid } })
        return false
    end
    if ct == 0 then
        if ability.school and ability.school ~= "physical" and target and target ~= e then
            if ctx.spellResist.isSpellResisted(e.level, target.level, e.hitBonus or 0) then
                ctx.noteEvents({ { type = "log", text = "Resisted!", pid = pid } })
                return true
            end
        end
        if ability.effects then
            for _, ef in ipairs(ability.effects) do
                if ef.mechanic then
                    local dur = ctx.ccDr.applyDiminishingReturns(target.id, ability.id, ef.mechanic, ef.duration or 0, ctx.simTime)
                    if dur <= 0 then
                        ctx.noteEvents({ { type = "log", text = "Target immune! (DR)", pid = pid } })
                        return false
                    end
                    ef.duration = dur
                end
            end
        end
        local evs = ctx.fxDispatch.execute(e, target, ability, ctx.entities, ctx.simTime)
        ctx.noteEvents(evs)
        for _, ev in ipairs(evs) do
            if ev.type == "combat_damage" and e.resourceType == "rage" then
                e.resource = math.min(e.maxResource, e.resource + ctx.rage.rageFromDealing(ev.hp or 0, e.level))
            end
        end
        ctx.setProcs.applySetProcs(e, target, "on_spell_cast", ctx.simTime)
        if target and ctx.spirit.checkDeath(target) then
            ctx.noteEvents({ { type = "death", pid = target.id } })
        end
    end
    return true
end

function H.castSlot(ctx, pid, cmd)
    local e = ctx.entities[pid]
    if not e or e.dead then return false end
    local slot = n(cmd.slot)
    if not slot then return false end
    -- 按热键槽释放: 从保存的热键布局解析能力 id (无布局时按职业习得顺序回退)
    local meta = ctx.players[pid]
    local abilityId = nil
    if meta and meta.hotbarLayout and meta.hotbarLayout[slot] then
        abilityId = meta.hotbarLayout[slot]
    else
        local cls = (meta and meta.class) or (e.templateId) or "warrior"
        local order = {}
        for id, ab in pairs(ctx.abilities.ABILITIES) do
            if ab.class == cls and (ab.learnLevel or 1) <= (e.level or 1) then
                table.insert(order, { id = id, lv = ab.learnLevel or 99 })
            end
        end
        table.sort(order, function(a, b) return a.lv < b.lv end)
        local i = order[slot]
        if i then abilityId = i.id end
    end
    if not abilityId then
        ctx.noteEvents({ { type = "log", text = "Empty action slot", pid = pid } })
        return false
    end
    return H.cast(ctx, pid, { cmd = "cast", ability = abilityId })
end

function H.castAt(ctx, pid, cmd)
    -- 地面目标施法: 服务端钳制射程
    local e = ctx.entities[pid]
    local abilityId = s(cmd.ability)
    if not e or e.dead or not abilityId then return false end
    local ability = ctx.abilities.ABILITIES[abilityId]
    if not ability then
        ctx.noteEvents({ { type = "log", text = "Unknown ability: " .. abilityId, pid = pid } })
        return false
    end
    if ctx.castSys.isOnCooldown(e, ability) then return false end
    local x, z = n(cmd.x), n(cmd.z)
    if not x or not z then return false end
    local dx, dz = x - e.pos.x, z - e.pos.z
    local range = (ability.range and ability.range > 0) and ability.range or 10
    local d = math.sqrt(dx * dx + dz * dz)
    if d > range then
        dx, dz = dx / d * range, dz / d * range
        x, z = e.pos.x + dx, e.pos.z + dz
    end
    -- 地面目标: 站桩施法, 命中时用目标点找最近敌人 (简化, 无独立 startCastAt)
    if ctx.castSys.startCastAt then
        ctx.castSys.startCastAt(e, ability, x, z)
    else
        local target = ctx.findNearestEnemy(e)
        ctx.castSys.startCast(e, ability, target)
    end
    return true
end

function H.releaseEmpowered(ctx, pid, cmd)
    local e = ctx.entities[pid]
    if not e then return false end
    local abilityId = s(cmd.ability)
    if not abilityId then return false end
    if ctx.empower then
        local ok = ctx.empower.releaseEmpowered and ctx.empower.releaseEmpowered(e, abilityId)
        if ok == nil then return true end
        return ok
    end
    return true
end

function H.cancel_aura(ctx, pid, cmd)
    local e = ctx.entities[pid]
    if not e then return false end
    local auraId = s(cmd.aura) or s(cmd.auraId)
    if auraId then ctx.aura.removeAura(e, auraId) end
    return true
end

function H.attack(ctx, pid, cmd)
    local e = ctx.entities[pid]
    if not e or e.dead then return false end
    local nearest = ctx.findNearestEnemy(e)
    if nearest then e.targetId = nearest.id end
    ctx.autoAttack.startAutoAttack(e, nearest)
    return true
end

function H.stopattack(ctx, pid, cmd)
    local e = ctx.entities[pid]
    if e then ctx.autoAttack.stopAutoAttack(e) end
    return true
end

function H.stopAutoAttackOnTargetSwitch(ctx, pid, cmd)
    local meta = ctx.players[pid]
    if meta then meta.stopAutoAttackOnTargetSwitch = cmd.enabled == true end
    return true
end

-- ============ 目标选择 ============
function H.target(ctx, pid, cmd)
    local e = ctx.entities[pid]
    if not e then return false end
    local id = n(cmd.id)
    if id and ctx.entities[id] then e.targetId = id else e.targetId = nil end
    return true
end

function H.tab(ctx, pid, cmd)
    local e = ctx.entities[pid]
    if not e then return false end
    local nearest = ctx.findNearestEnemy(e)
    if nearest then e.targetId = nearest.id end
    return true
end

function H.targetNearest(ctx, pid, cmd) return H.tab(ctx, pid, cmd) end

function H.targetNearestFriendly(ctx, pid, cmd)
    local e = ctx.entities[pid]
    if not e then return false end
    local best, bestD = nil, math.huge
    for id, other in pairs(ctx.entities) do
        if other.kind == "player" and other.id ~= pid and not other.dead then
            local dx, dz = other.pos.x - e.pos.x, other.pos.z - e.pos.z
            local d = dx * dx + dz * dz
            if d < bestD then best, bestD = other, d end
        end
    end
    if best then e.targetId = best.id end
    return true
end

function H.tabFriendly(ctx, pid, cmd) return H.targetNearestFriendly(ctx, pid, cmd) end

-- ============ 交互 ============
function H.interact(ctx, pid, cmd)
    local e = ctx.entities[pid]
    if not e or e.dead then return false end
    -- 附近最近可交互 NPC / 节点 / 可 loot 尸体
    local best, bestD = nil, math.huge
    for id, other in pairs(ctx.entities) do
        if other.id ~= pid then
            local dx, dz = other.pos.x - e.pos.x, other.pos.z - e.pos.z
            local d = dx * dx + dz * dz
            if d < bestD and d <= 36 then
                local interactive = (other.kind == "npc" and (next(other.questIds or {}) or #(other.vendorItems or {}) > 0 or other.banker or other.cardMaster or other.greeting))
                    or (other.kind == "node")
                    or (other.kind == "object" and other.lootable)
                if interactive then best, bestD = other, d end
            end
        end
    end
    if not best then
        ctx.noteEvents({ { type = "log", text = "Nothing to interact with.", pid = pid } })
        return false
    end
    if best.kind == "npc" then
        local lines = {}
        if best.greeting and #best.greeting > 0 then table.insert(lines, best.greeting) end
        local nQuests = 0
        for _, qid in ipairs(best.questIds or {}) do
            local qd = ctx.quest.getQuestTable()[qid]
            if qd then
                local meta = ctx.players[pid]
                if meta and not meta.qdone[qid] and not meta.qlog[qid] then
                    table.insert(lines, qd.name .. " (accept: /accept)")
                    nQuests = nQuests + 1
                end
            end
        end
        if nQuests == 0 and #(best.vendorItems or {}) > 0 then
            table.insert(lines, "Merchant — use buy/sell.")
        end
        if #lines == 0 then table.insert(lines, (best.name or "NPC") .. " has nothing for you.") end
        for _, ln in ipairs(lines) do
            ctx.noteEvents({ { type = "log", text = ln, pid = pid } })
        end
        return true
    end
    if best.kind == "node" then
        return H.harvest_node(ctx, pid, { node = best.templateId or "herb" })
    end
    if best.kind == "object" and best.lootable then
        return H.loot(ctx, pid, { id = best.id })
    end
    return false
end

function H.loot(ctx, pid, cmd)
    local e = ctx.entities[pid]
    if not e then return false end
    local id = n(cmd.id)
    if not id then return false end
    local corpse = ctx.entities[id]
    if not corpse or not corpse.dead then return false end
    local loot = corpse.loot
    if not loot or #loot == 0 then return false end
    local meta = ctx.players[pid]
    local got = 0
    if meta then
        for _, it in ipairs(loot) do
            local invItem = ctx.inventory.createItem(it.id, it.name or it.id, it.kind or "misc", it)
            if ctx.inventory.addItem(meta, invItem) then got = got + 1 end
        end
    end
    corpse.loot = nil
    corpse.lootable = false
    corpse.dead = false
    if got > 0 then
        ctx.noteEvents({ { type = "loot", pid = pid, item = { count = got } } })
        return true
    end
    return false
end

function H.autoloot(ctx, pid, cmd) return H.loot(ctx, pid, cmd) end

function H.harvestCorpse(ctx, pid, cmd)
    -- 采集尸体材料 (剥皮等): 简化等同 loot
    return H.loot(ctx, pid, cmd)
end

function H.pickup(ctx, pid, cmd)
    local e = ctx.entities[pid]
    if not e then return false end
    local id = n(cmd.id)
    if not id then return false end
    local obj = ctx.entities[id]
    if not obj or not obj.lootable or not obj.objectItemId then return false end
    local meta = ctx.players[pid]
    if meta then
        local itemDef = ctx.protoGet and ctx.protoGet(obj.objectItemId)
        local invItem = ctx.inventory.createItem(obj.objectItemId, (itemDef and itemDef.name) or obj.objectItemId, "misc", itemDef)
        if ctx.inventory.addItem(meta, invItem) then
            obj.lootable = false
            obj.respawnTimer = 60
            return true
        end
    end
    return false
end

function H.lootRoll(ctx, pid, cmd)
    local ok = ctx.lootRoll.rollLoot(s(cmd.rollId), pid)
    if ok then return true end
    return notImplemented(ctx, pid, "lootRoll")
end

-- ============ 任务 ============
function H.accept(ctx, pid, cmd)
    local qid = s(cmd.quest)
    if not qid then return false end
    local meta = ctx.players[pid]
    local ok, result = ctx.quest.acceptQuest(meta, qid)
    ctx.noteEvents({ { type = "log", text = ok and ("Accepted: " .. (result.name or "")) or (result or "Failed"), pid = pid } })
    return ok
end

function H.turnin(ctx, pid, cmd)
    local qid = s(cmd.quest)
    if not qid then return false end
    local meta = ctx.players[pid]
    local ok, result = ctx.quest.turninQuest(meta, qid)
    if ok then
        ctx.noteEvents({ { type = "log", text = "Quest complete! +" .. (result.copper or 0) .. " copper", pid = pid } })
        local e = ctx.entities[pid]
        if result.xp and result.xp > 0 and meta and e then
            local xpEvents = ctx.xp.grantXp(result.xp, meta, e, nil, ctx.playerStats.recalcPlayerStats, function(m, ent)
                ctx.talent.recomputeForLevel(m, ent, m.class or ent.templateId)
            end)
            for _, xev in ipairs(xpEvents) do ctx.noteEvents({ xev }) end
        end
        return true
    end
    ctx.noteEvents({ { type = "log", text = (result or "Failed"), pid = pid } })
    return false
end

function H.abandon(ctx, pid, cmd)
    local qid = s(cmd.quest)
    if qid then ctx.quest.abandonQuest(ctx.players[pid], qid) end
    return true
end

function H.qlinkaccept(ctx, pid, cmd)
    local qid = s(cmd.quest)
    if qid then ctx.quest.acceptQuest(ctx.players[pid], qid) end
    return true
end

-- ============ 背包 / 装备 ============
function H.inv_move(ctx, pid, cmd)
    ctx.inventory.invMove(ctx.players[pid], n(cmd.from) or 0, n(cmd.to) or 0)
    return true
end

function H.equip(ctx, pid, cmd)
    local meta = ctx.players[pid]
    local e = ctx.entities[pid]
    if not meta or not e then return false end
    -- 客户端发 item (物品 id) 而非 slot; 从背包查找持有该 id 的槽位
    local itemId = s(cmd.item)
    local slot = n(cmd.slot)
    if itemId and not slot then
        for i, it in pairs(meta.inventory or {}) do
            if it.id == itemId then slot = tonumber(i) break end
        end
    end
    if not slot then return false end
    -- 未指定装备槽位时按物品定义 slot 推断 (客户端 equip{item} 不带 equipSlot)
    local equipSlot = s(cmd.equipSlot) or ""
    if equipSlot == "" then
        local it = meta.inventory[slot]
        if it then equipSlot = s(it.slot) or "" end
    end
    local ok, msg = ctx.inventory.equipItem(meta, e, slot, equipSlot)
    if ok then ctx.playerStats.recalcPlayerStats(e, meta.class, meta.equipment, nil, nil) end
    ctx.noteEvents({ { type = "log", text = ok and "Equipped" or (msg or "Failed"), pid = pid } })
    return ok
end

function H.unequip_item(ctx, pid, cmd)
    local meta = ctx.players[pid]
    local e = ctx.entities[pid]
    if not meta or not e then return false end
    local slot = s(cmd.slot)
    if not slot then return false end
    ctx.inventory.unequipItem(meta, e, slot)
    ctx.playerStats.recalcPlayerStats(e, meta.class, meta.equipment, nil, nil)
    return true
end

function H.use(ctx, pid, cmd)
    local meta = ctx.players[pid]
    local e = ctx.entities[pid]
    if not meta or not e then return false end
    local itemId = s(cmd.item)
    local slot = n(cmd.slot)
    if itemId and not slot then
        for i, it in pairs(meta.inventory or {}) do
            if it.id == itemId then slot = tonumber(i) break end
        end
    end
    if not slot then return false end
    ctx.inventory.useItem(meta, e, slot)
    return true
end

function H.discard(ctx, pid, cmd)
    local meta = ctx.players[pid]
    if not meta then return false end
    local itemId = s(cmd.item)
    local slot = n(cmd.slot)
    if itemId and not slot then
        for i, it in pairs(meta.inventory or {}) do
            if it.id == itemId then slot = tonumber(i) break end
        end
    end
    if not slot then return false end
    ctx.inventory.discardItem(meta, slot)
    return true
end

function H.equip_bag(ctx, pid, cmd)
    local meta = ctx.players[pid]
    if not meta then return false end
    local itemId = s(cmd.item)
    local socket = n(cmd.socket)
    if itemId then
        for i, it in pairs(meta.inventory or {}) do
            if it.id == itemId then
                local slot = tonumber(i)
                local ok, msg = ctx.inventory.equipItem(meta, ctx.entities[pid], slot, "bag" .. (socket or 1))
                return ok
            end
        end
    end
    return notImplemented(ctx, pid, "equip_bag")
end

function H.unequip_bag(ctx, pid, cmd)
    local socket = n(cmd.socket)
    if socket then
        ctx.inventory.unequipItem(ctx.players[pid], ctx.entities[pid], "bag" .. socket)
        return true
    end
    return false
end

-- ============ 商店 ============
function H.buy(ctx, pid, cmd)
    local meta = ctx.players[pid]
    local e = ctx.entities[pid]
    if not meta or not e then return false end
    local itemId = s(cmd.item)
    if not itemId then return false end
    -- 找 6 码内 NPC 专属库存
    local npcStock = nil
    for _, other in pairs(ctx.entities) do
        if other.kind == "npc" and next(other.vendorItems or {}) then
            local dx, dz = other.pos.x - e.pos.x, other.pos.z - e.pos.z
            if dx * dx + dz * dz <= 36 then npcStock = other.vendorItems break end
        end
    end
    local ok, result = ctx.vendor.buyItem(meta, e, itemId, npcStock)
    ctx.noteEvents({ { type = "log", text = ok and ("Bought " .. ((result and result.name) or "")) or (result or "Failed"), pid = pid } })
    return ok
end

function H.sell(ctx, pid, cmd)
    local meta = ctx.players[pid]
    if not meta then return false end
    local itemId = s(cmd.item)
    local slot = n(cmd.slot)
    if itemId and not slot then
        for i, it in pairs(meta.inventory or {}) do
            if it.id == itemId then slot = tonumber(i) break end
        end
    end
    if not slot then return false end
    local ok, result = ctx.vendor.sellItem(meta, slot)
    ctx.noteEvents({ { type = "log", text = ok and ("Sold for " .. ((result and result.price) or 0)) or (result or "Failed"), pid = pid } })
    return ok
end

function H.sell_all_junk(ctx, pid, cmd)
    local total = ctx.vendor.sellAllJunk(ctx.players[pid])
    ctx.noteEvents({ { type = "log", text = "Sold junk for " .. total .. " copper", pid = pid } })
    return true
end

function H.buyback(ctx, pid, cmd)
    return notImplemented(ctx, pid, "buyback")
end

-- ============ 采集 / 制造 ============
function H.harvest_node(ctx, pid, cmd)
    local meta = ctx.players[pid]
    local e = ctx.entities[pid]
    if not meta or not e then return false end
    local nodeId = s(cmd.node)
    -- 解析为节点类型: proto gather node templateId → 资源类型
    local nodeType = nodeId
    if ctx.nodeTypeFor and nodeId then nodeType = ctx.nodeTypeFor(nodeId) or nodeId end
    local ok, result = ctx.profession.harvestNode(meta, e, nodeType or "herb")
    ctx.noteEvents({ { type = "log", text = ok and ("Harvested " .. ((result and result.item) or "")) or (result or "Failed"), pid = pid } })
    return ok
end

function H.craft_item(ctx, pid, cmd)
    local meta = ctx.players[pid]
    if not meta then return false end
    local recipeId = s(cmd.recipe)
    if not recipeId then return false end
    local ok, result = ctx.profession.craftItem(meta, recipeId)
    ctx.noteEvents({ { type = "log", text = ok and ("Crafted " .. ((result and result.name) or "")) or (result or "Failed"), pid = pid } })
    return ok
end

function H.place_mobile_station(ctx, pid, cmd)
    return notImplemented(ctx, pid, "place_mobile_station")
end

-- ============ 专业 (扩展占位) ============
function H.train_recipe(ctx, pid, cmd) return notImplemented(ctx, pid, "train_recipe") end
function H.slot_tool_effect(ctx, pid, cmd) return notImplemented(ctx, pid, "slot_tool_effect") end
function H.recharge_tool_effect(ctx, pid, cmd) return notImplemented(ctx, pid, "recharge_tool_effect") end
function H.disenchant_item(ctx, pid, cmd) return notImplemented(ctx, pid, "disenchant_item") end
function H.apply_enchant(ctx, pid, cmd) return notImplemented(ctx, pid, "apply_enchant") end
function H.salvage_item(ctx, pid, cmd) return notImplemented(ctx, pid, "salvage_item") end
function H.unbind_item(ctx, pid, cmd) return notImplemented(ctx, pid, "unbind_item") end
function H.open_commission_order(ctx, pid, cmd) return notImplemented(ctx, pid, "open_commission_order") end
function H.cancel_commission_order(ctx, pid, cmd) return notImplemented(ctx, pid, "cancel_commission_order") end
function H.accept_commission_order(ctx, pid, cmd) return notImplemented(ctx, pid, "accept_commission_order") end
function H.deliver_commission_order(ctx, pid, cmd) return notImplemented(ctx, pid, "deliver_commission_order") end

-- ============ 外观 ============
function H.change_skin(ctx, pid, cmd)
    local e = ctx.entities[pid]
    if e then e.skin = n(cmd.skin); if cmd.catalog then e.skinCatalog = s(cmd.catalog) end end
    return true
end
function H.claim_event_skin(ctx, pid, cmd)
    local e = ctx.entities[pid]
    if e then e.skin = n(cmd.skin) end
    return true
end
function H.change_weapon_skin(ctx, pid, cmd)
    local e = ctx.entities[pid]
    if e then e.weaponSkinId = s(cmd.skin) or n(cmd.skin) end
    return true
end
function H.unequip_mech_chroma(ctx, pid, cmd)
    local e = ctx.entities[pid]
    if e then e.skin = nil end
    return true
end
function H.stow_weapon(ctx, pid, cmd)
    local e = ctx.entities[pid]
    if e then e.weaponStowed = not (e.weaponStowed or false) end
    return true
end
function H.set_helm(ctx, pid, cmd)
    local e = ctx.entities[pid]
    if e then e.helmHidden = cmd.hidden == true end
    return true
end
function H.save_hotbar_layout(ctx, pid, cmd)
    local meta = ctx.players[pid]
    if meta and type(cmd.layout) == "table" then meta.hotbarLayout = cmd.layout end
    return true
end

-- ============ 聊天 / 表情 ============
function H.chat(ctx, pid, cmd)
    local text = s(cmd.text)
    if not text then return false end
    ctx.noteEvents(ctx.chat.processMessage(ctx.entities, ctx.players, pid, text, s(cmd.channel) or "say", s(cmd.target)))
    return true
end
function H.emote(ctx, pid, cmd)
    ctx.chat.processEmote(ctx.entities, ctx.players, pid, s(cmd.emote))
    return true
end

-- ============ 组队 ============
function H.pinvite(ctx, pid, cmd)
    local ok = ctx.partyMod.invite(pid, n(cmd.id) or 0, ctx.entities)
    return ok or notImplemented(ctx, pid, "pinvite")
end
function H.paccept(ctx, pid, cmd)
    local ok = ctx.partyMod.accept(pid)
    return ok or notImplemented(ctx, pid, "paccept")
end
function H.pdecline(ctx, pid, cmd) return notImplemented(ctx, pid, "pdecline") end
function H.pleave(ctx, pid, cmd)
    local ok = ctx.partyMod.leave(pid)
    return ok or notImplemented(ctx, pid, "pleave")
end
function H.pkick(ctx, pid, cmd)
    local ok = ctx.partyMod.kick(pid, n(cmd.id) or 0)
    return ok or notImplemented(ctx, pid, "pkick")
end
function H.ppromote(ctx, pid, cmd)
    local ok = ctx.partyMod.promote and ctx.partyMod.promote(pid, n(cmd.id) or 0)
    return ok or notImplemented(ctx, pid, "ppromote")
end
function H.praid(ctx, pid, cmd)
    local ok = ctx.partyMod.toRaid and ctx.partyMod.toRaid(pid)
    return ok or notImplemented(ctx, pid, "praid")
end
function H.punraid(ctx, pid, cmd)
    local ok = ctx.partyMod.toParty and ctx.partyMod.toParty(pid)
    return ok or notImplemented(ctx, pid, "punraid")
end
function H.pmoveRaid(ctx, pid, cmd) return notImplemented(ctx, pid, "pmoveRaid") end
function H.readyrespond(ctx, pid, cmd)
    ctx.readyCheck.respond(pid, cmd.ready == true)
    return true
end
function H.setLootMaster(ctx, pid, cmd) return notImplemented(ctx, pid, "setLootMaster") end
function H.masterAssign(ctx, pid, cmd) return notImplemented(ctx, pid, "masterAssign") end
function H.setMarker(ctx, pid, cmd)
    local e = ctx.entities[pid]
    if e then
        e.markerId = n(cmd.marker)
        e.markerEntityId = n(cmd.id)
    end
    return true
end
function H.clearMarker(ctx, pid, cmd)
    local e = ctx.entities[pid]
    if e then e.markerId = nil end
    return true
end

-- ============ 交易 ============
function H.trade_req(ctx, pid, cmd)
    local ok = ctx.tradeMod.requestTrade(pid, n(cmd.id) or 0, ctx.entities, ctx.players)
    return ok or notImplemented(ctx, pid, "trade_req")
end
function H.trade_accept(ctx, pid, cmd)
    local tid = ctx.tradeMod.tradeIdOf and ctx.tradeMod.tradeIdOf(pid)
    if tid then return ctx.tradeMod.acceptTrade(pid, tid) end
    return notImplemented(ctx, pid, "trade_accept")
end
function H.trade_offer(ctx, pid, cmd)
    -- items: [{itemId,count}]; copper: 数量
    local tid = ctx.tradeMod.tradeIdOf and ctx.tradeMod.tradeIdOf(pid)
    if not tid then return notImplemented(ctx, pid, "trade_offer") end
    local copper = n(cmd.copper) or 0
    local okC = ctx.tradeMod.offerCopper and ctx.tradeMod.offerCopper(pid, tid, copper, ctx.players[pid])
    local okI = true
    if type(cmd.items) == "table" then
        local meta = ctx.players[pid]
        for _, it in ipairs(cmd.items) do
            local itemId = s(it.itemId) or s(it.item)
            if itemId then
                for slot, invIt in pairs(meta.inventory or {}) do
                    if invIt.id == itemId then
                        ctx.tradeMod.offerItem(pid, tid, tonumber(slot), meta)
                        break
                    end
                end
            end
        end
    end
    return (okC ~= false) and okI
end
function H.trade_confirm(ctx, pid, cmd)
    local tid = ctx.tradeMod.tradeIdOf and ctx.tradeMod.tradeIdOf(pid)
    if tid then return ctx.tradeMod.confirmTrade(pid, tid) end
    return notImplemented(ctx, pid, "trade_confirm")
end
function H.trade_cancel(ctx, pid, cmd)
    local tid = ctx.tradeMod.tradeIdOf and ctx.tradeMod.tradeIdOf(pid)
    if tid then return ctx.tradeMod.cancelTrade(tid) end
    return notImplemented(ctx, pid, "trade_cancel")
end

-- ============ 决斗 ============
function H.duel_req(ctx, pid, cmd)
    local ok = ctx.duelMod.requestDuel(pid, n(cmd.id) or 0, ctx.entities)
    return ok or notImplemented(ctx, pid, "duel_req")
end
function H.duel_accept(ctx, pid, cmd)
    local ok = ctx.duelMod.acceptDuel(pid, s(cmd.duelId) or "")
    return ok or notImplemented(ctx, pid, "duel_accept")
end
function H.duel_decline(ctx, pid, cmd)
    local ok = ctx.duelMod.declineDuel and ctx.duelMod.declineDuel(s(cmd.duelId) or "")
    return ok or notImplemented(ctx, pid, "duel_decline")
end

-- ============ 好友 / 黑名单 / 忽略 (按名字) ============
local function socialBy(ctx, pid, op, cmd)
    local name = s(cmd.name)
    if not name then return notImplemented(ctx, pid, op) end
    -- 解析名字 → pid → characterId
    local targetPid = nil
    for otherPid, meta in pairs(ctx.players) do
        if (meta.name or "") == name then targetPid = otherPid break end
    end
    ctx.socialCmd(pid, op, targetPid, name)
    return true
end
function H.friend_add(ctx, pid, cmd) return socialBy(ctx, pid, "friend_add", cmd) end
function H.friend_remove(ctx, pid, cmd) return socialBy(ctx, pid, "friend_remove", cmd) end
function H.block_add(ctx, pid, cmd) return socialBy(ctx, pid, "block_add", cmd) end
function H.block_remove(ctx, pid, cmd) return socialBy(ctx, pid, "block_remove", cmd) end
function H.ignore_add(ctx, pid, cmd) return socialBy(ctx, pid, "ignore_add", cmd) end
function H.ignore_remove(ctx, pid, cmd) return socialBy(ctx, pid, "ignore_remove", cmd) end

-- ============ 公会 ============
function H.guild_create(ctx, pid, cmd)
    ctx.socialCmd(pid, "guild_create", nil, s(cmd.name))
    return true
end
function H.guild_invite(ctx, pid, cmd) return socialBy(ctx, pid, "guild_invite", cmd) end
function H.guild_accept(ctx, pid, cmd)
    return notImplemented(ctx, pid, "guild_accept")
end
function H.guild_decline(ctx, pid, cmd)
    return notImplemented(ctx, pid, "guild_decline")
end
function H.guild_leave(ctx, pid, cmd)
    ctx.socialCmd(pid, "guild_leave")
    return true
end
function H.guild_kick(ctx, pid, cmd) return socialBy(ctx, pid, "guild_kick", cmd) end
function H.guild_promote(ctx, pid, cmd) return socialBy(ctx, pid, "guild_promote", cmd) end
function H.guild_demote(ctx, pid, cmd) return socialBy(ctx, pid, "guild_demote", cmd) end
function H.guild_transfer(ctx, pid, cmd) return socialBy(ctx, pid, "guild_transfer", cmd) end
function H.guild_disband(ctx, pid, cmd)
    return notImplemented(ctx, pid, "guild_disband")
end
function H.guild_event_create(ctx, pid, cmd) return notImplemented(ctx, pid, "guild_event_create") end
function H.guild_event_remove(ctx, pid, cmd) return notImplemented(ctx, pid, "guild_event_remove") end
function H.guild_set_motd(ctx, pid, cmd)
    ctx.socialCmd(pid, "guild_set_motd", nil, s(cmd.text))
    return true
end

-- ============ 竞技场 / 战场 ============
function H.arena_queue(ctx, pid, cmd)
    local teamId = ctx.arena.createTeam(pid, 0)
    if teamId then
        ctx.arena.queueTeam(teamId, ctx.simTime)
        ctx.noteEvents({ { type = "log", text = "Joined arena queue", pid = pid } })
        return true
    end
    return false
end
function H.arena_leave(ctx, pid, cmd) return notImplemented(ctx, pid, "arena_leave") end
function H.arena_augment(ctx, pid, cmd) return notImplemented(ctx, pid, "arena_augment") end

function H.bg_queue(ctx, pid, cmd)
    ctx.battleground.queuePlayer(pid, ctx.simTime)
    ctx.noteEvents({ { type = "log", text = "Joined battleground queue", pid = pid } })
    return true
end
function H.bg_leave(ctx, pid, cmd)
    ctx.battleground.leaveQueue(pid)
    return true
end
function H.bg_flag(ctx, pid, cmd)
    ctx.battleground.captureFlag(pid)
    return true
end

-- ============ 地下城查找器 ============
function H.df_roles(ctx, pid, cmd)
    local meta = ctx.players[pid]
    if meta and type(cmd.roles) == "table" then meta.dfRoles = cmd.roles end
    return true
end
function H.df_queue(ctx, pid, cmd)
    local e = ctx.entities[pid]
    ctx.dungeonFinder.joinQueue(pid, (ctx.players[pid] and ctx.players[pid].dfRoles and ctx.players[pid].dfRoles[1]) or "dps", e.level, ctx.entities)
    ctx.noteEvents({ { type = "log", text = "Joined dungeon finder", pid = pid } })
    return true
end
function H.df_queue_leave(ctx, pid, cmd)
    ctx.dungeonFinder.leaveQueue(pid)
    return true
end
function H.df_proposal(ctx, pid, cmd) return notImplemented(ctx, pid, "df_proposal") end
function H.df_list_create(ctx, pid, cmd) return notImplemented(ctx, pid, "df_list_create") end
function H.df_list_close(ctx, pid, cmd) return notImplemented(ctx, pid, "df_list_close") end
function H.df_apply(ctx, pid, cmd) return notImplemented(ctx, pid, "df_apply") end
function H.df_apply_cancel(ctx, pid, cmd) return notImplemented(ctx, pid, "df_apply_cancel") end
function H.df_app_respond(ctx, pid, cmd) return notImplemented(ctx, pid, "df_app_respond") end

-- ============ 卡牌决斗 ============
function H.card_queue_join(ctx, pid, cmd) return notImplemented(ctx, pid, "card_queue_join") end
function H.card_queue_leave(ctx, pid, cmd) return notImplemented(ctx, pid, "card_queue_leave") end
function H.play_card(ctx, pid, cmd)
    local ok, val = ctx.cardDuel.playCard(pid, n(cmd.value) or 0)
    ctx.noteEvents({ { type = "log", text = ok and ("Played: " .. tostring(val)) or "Failed", pid = pid } })
    return ok
end
function H.card_forfeit(ctx, pid, cmd) return notImplemented(ctx, pid, "card_forfeit") end

-- ============ 拍卖行 ============
function H.market_search(ctx, pid, cmd)
    local meta = ctx.players[pid]
    ctx.marketOp(pid, { op = "search", query = s(cmd.q), limit = 50 }, function(data)
        if data and meta then
            meta.marketInfo = data
        end
    end)
    return true
end
function H.market_list(ctx, pid, cmd)
    local meta = ctx.players[pid]
    if not meta then return false end
    local itemId = s(cmd.item)
    local slot = nil
    for i, it in pairs(meta.inventory or {}) do
        if it.id == itemId then slot = tonumber(i) break end
    end
    if not slot then return false end
    ctx.marketOp(pid, { op = "list_item", pid = pid, item = meta.inventory[slot], price = n(cmd.price) or 0 })
    return true
end
function H.market_list_instance(ctx, pid, cmd) return notImplemented(ctx, pid, "market_list_instance") end
function H.market_buy(ctx, pid, cmd)
    ctx.marketOp(pid, { op = "buy", pid = pid, listingId = n(cmd.id) })
    return true
end
function H.market_cancel(ctx, pid, cmd)
    ctx.marketOp(pid, { op = "cancel", pid = pid, listingId = n(cmd.id) })
    return true
end
function H.market_collect(ctx, pid, cmd)
    ctx.marketOp(pid, { op = "collect", pid = pid })
    return true
end

-- ============ 邮件 ============
function H.mail_send(ctx, pid, cmd)
    local meta = ctx.players[pid]
    if not meta then return false end
    local items = type(cmd.items) == "table" and cmd.items or {}
    local slots = {}
    for _, it in ipairs(items) do
        local itemId = s(it.itemId) or s(it.item)
        if itemId then
            for slot, invIt in pairs(meta.inventory or {}) do
                if invIt.id == itemId then table.insert(slots, tonumber(slot)) break end
            end
        end
    end
    ctx.mailOp(pid, { op = "send", from = meta.characterId, to = s(cmd.to), text = s(cmd.subject) .. "\n" .. (s(cmd.body) or ""), item = slots[1], copper = n(cmd.copper) or 0 })
    return true
end
function H.mail_take(ctx, pid, cmd)
    ctx.mailOp(pid, { op = "take", pid = metaOf(ctx, pid).characterId, mailId = n(cmd.id) })
    return true
end
function H.mail_delete(ctx, pid, cmd)
    ctx.mailOp(pid, { op = "delete", pid = metaOf(ctx, pid).characterId, mailId = n(cmd.id) })
    return true
end
function H.mail_read(ctx, pid, cmd)
    ctx.mailOp(pid, { op = "read", pid = metaOf(ctx, pid).characterId, mailId = n(cmd.id) })
    return true
end

-- ============ 银行 ============
function H.bank_deposit(ctx, pid, cmd)
    local ok = ctx.bank.deposit(ctx.players[pid], n(cmd.slot) or 0)
    return ok or notImplemented(ctx, pid, "bank_deposit")
end
function H.bank_withdraw(ctx, pid, cmd)
    local ok = ctx.bank.withdraw(ctx.players[pid], n(cmd.slot) or 0)
    return ok or notImplemented(ctx, pid, "bank_withdraw")
end
function H.bank_buy_slots(ctx, pid, cmd)
    local ok = ctx.bank.buySlots(ctx.players[pid], n(cmd.count) or 1)
    return ok or notImplemented(ctx, pid, "bank_buy_slots")
end

-- ============ 公会金库 ============
function H.guild_bank_deposit_gold(ctx, pid, cmd)
    ctx.guildBankOp(pid, { op = "deposit_gold", amount = n(cmd.amount) or 0 })
    return true
end
function H.guild_bank_withdraw_gold(ctx, pid, cmd)
    ctx.guildBankOp(pid, { op = "withdraw_gold", amount = n(cmd.amount) or 0 })
    return true
end
function H.guild_bank_deposit(ctx, pid, cmd)
    ctx.guildBankOp(pid, { op = "deposit_item", slot = n(cmd.slot) or 0 })
    return true
end
function H.guild_bank_withdraw(ctx, pid, cmd)
    ctx.guildBankOp(pid, { op = "withdraw_item", slot = n(cmd.slot) or 0 })
    return true
end
function H.guild_bank_buy_slots(ctx, pid, cmd)
    ctx.guildBankOp(pid, { op = "buy_slots" })
    return true
end
function H.guild_bank_log(ctx, pid, cmd)
    return notImplemented(ctx, pid, "guild_bank_log")
end

-- ============ 坐骑 ============
function H.mount_toggle(ctx, pid, cmd)
    local e = ctx.entities[pid]
    if not e then return false end
    if e.mountKey then
        ctx.mount.dismount(e)
        return true
    end
    local meta = ctx.players[pid]
    local owned = (meta and meta.ownedMounts) or {}
    local first = next(owned)
    if not first then first = "valorsteed" end
    return ctx.mount.startMount(e, first)
end
function H.learn_riding(ctx, pid, cmd)
    local meta = ctx.players[pid]
    local e = ctx.entities[pid]
    if meta then meta.ridingTrained = true end
    if e then e.ridingTrained = true end
    ctx.noteEvents({ { type = "log", text = "Riding trained!", pid = pid } })
    return true
end
function H.mount_train_begin(ctx, pid, cmd) return notImplemented(ctx, pid, "mount_train_begin") end
function H.mount_race_start(ctx, pid, cmd) return notImplemented(ctx, pid, "mount_race_start") end
function H.mount_race_cancel(ctx, pid, cmd) return notImplemented(ctx, pid, "mount_race_cancel") end

-- ============ 副本 ============
function H.enter_dungeon(ctx, pid, cmd)
    local dungeonId = s(cmd.dungeon)
    if not dungeonId then return false end
    local ok = ctx.instanceMod.enterDungeon(pid, dungeonId, "normal", ctx.entities)
    if ok then
        ctx.noteEvents({ { type = "log", text = "Entering " .. dungeonId, pid = pid } })
        return true
    end
    return false
end
function H.leave_dungeon(ctx, pid, cmd)
    ctx.instanceMod.leaveInstance(pid)
    local e = ctx.entities[pid]
    if e then
        local exitEvents = ctx.doorTriggers.exitDungeon(e, ctx.entities)
        for _, ev in ipairs(exitEvents) do ctx.noteEvents({ ev }) end
    end
    return true
end
function H.set_dungeon_difficulty(ctx, pid, cmd)
    local diff = s(cmd.difficulty) or "normal"
    ctx.heroicDungeon.setDifficulty("", diff)
    local meta = ctx.players[pid]
    if meta then meta.dungeonDifficulty = diff end
    return true
end
function H.heroic_buy(ctx, pid, cmd)
    local meta = ctx.players[pid]
    local itemId = s(cmd.itemId)
    if not meta or not itemId then return false end
    local ok, result = ctx.heroicDungeon.buyItem(meta.characterId, itemId)
    if ok and result then
        local itemDef = ctx.protoGet and ctx.protoGet(result.itemId)
        local invItem = ctx.inventory.createItem(result.itemId, (result.name or result.itemId), "misc", itemDef or result)
        ctx.inventory.addItem(meta, invItem)
        ctx.noteEvents({ { type = "log", text = "Bought: " .. (result.name or ""), pid = pid } })
        return true
    end
    ctx.noteEvents({ { type = "log", text = (result or "Failed"), pid = pid } })
    return false
end

-- ============ 深入探索 ============
function H.enter_delve(ctx, pid, cmd)
    local delveId = s(cmd.delveId)
    if not delveId then return false end
    local ok, result = ctx.delve.enterDelve(pid, delveId, ctx.entities)
    ctx.noteEvents({ { type = "log", text = ok and ("Entered: " .. tostring(result)) or tostring(result), pid = pid } })
    return ok
end
function H.leave_delve(ctx, pid, cmd)
    ctx.delve.leaveDelve(pid, ctx.entities)
    return true
end
function H.delve_interact(ctx, pid, cmd)
    local ok, rem = ctx.delve.attemptLockpick(pid)
    if ok == nil then return notImplemented(ctx, pid, "delve_interact") end
    ctx.noteEvents({ { type = "log", text = ok and ("Picked! (" .. tostring(rem) .. " left)") or "Failed", pid = pid } })
    return ok
end
function H.companion_upgrade(ctx, pid, cmd) return notImplemented(ctx, pid, "companion_upgrade") end
function H.delve_buy(ctx, pid, cmd) return notImplemented(ctx, pid, "delve_buy") end
function H.lockpick_engage(ctx, pid, cmd) return H.delve_interact(ctx, pid, cmd) end
function H.lockpick_action(ctx, pid, cmd) return notImplemented(ctx, pid, "lockpick_action") end
function H.lockpick_abort(ctx, pid, cmd) return notImplemented(ctx, pid, "lockpick_abort") end
function H.collect_delve_chest_loot(ctx, pid, cmd) return notImplemented(ctx, pid, "collect_delve_chest_loot") end
function H.delve_rite_choose(ctx, pid, cmd) return notImplemented(ctx, pid, "delve_rite_choose") end

-- ============ 天赋 / 声望 ============
function H.prestige(ctx, pid, cmd) return notImplemented(ctx, pid, "prestige") end
function H.applyTalents(ctx, pid, cmd)
    local meta = ctx.players[pid]
    local e = ctx.entities[pid]
    if not meta or not e then return false end
    local tid = nil
    if type(cmd.alloc) == "table" then
        for id in pairs(cmd.alloc) do tid = id break end
    end
    if not tid then return false end
    local ok, result = ctx.talent.applyTalents(meta, e, tid)
    if ok then ctx.playerStats.recalcPlayerStats(e, meta.class, meta.equipment, meta.talentMods, nil) end
    ctx.noteEvents({ { type = "log", text = ok and ("Learned: " .. tostring((result and result.name) or "")) or (result or "Failed"), pid = pid } })
    return ok
end
function H.respec(ctx, pid, cmd)
    local meta = ctx.players[pid]
    local e = ctx.entities[pid]
    if meta and e then ctx.talent.respec(meta, e, e.templateId or "warrior") end
    ctx.noteEvents({ { type = "log", text = "Respecced!", pid = pid } })
    return true
end
function H.setSpec(ctx, pid, cmd)
    local meta = ctx.players[pid]
    if meta then meta.spec = s(cmd.spec) end
    return true
end
function H.selectTalentRow(ctx, pid, cmd) return notImplemented(ctx, pid, "selectTalentRow") end
function H.saveLoadout(ctx, pid, cmd)
    local meta = ctx.players[pid]
    if meta then
        meta.loadouts = meta.loadouts or {}
        table.insert(meta.loadouts, { name = s(cmd.name) or "Loadout", alloc = cmd.alloc })
    end
    return true
end
function H.switchLoadout(ctx, pid, cmd)
    local meta = ctx.players[pid]
    if meta and meta.loadouts and meta.loadouts[n(cmd.index) or 1] then
        local lo = meta.loadouts[n(cmd.index) or 1]
        for id in pairs(lo.alloc or {}) do ctx.talent.applyTalents(meta, ctx.entities[pid], id) end
    end
    return true
end
function H.deleteLoadout(ctx, pid, cmd)
    local meta = ctx.players[pid]
    if meta and meta.loadouts then table.remove(meta.loadouts, n(cmd.index) or 1) end
    return true
end

-- ============ 死亡 / 灵魂 / 杂项 ============
function H.release(ctx, pid, cmd)
    local e = ctx.entities[pid]
    if e and e.dead and not e.ghost then
        ctx.spirit.releaseSpirit(e)
        ctx.noteEvents({ { type = "release_spirit", pid = pid } })
        return true
    end
    return false
end
function H.resurrect_corpse(ctx, pid, cmd)
    local e = ctx.entities[pid]
    if e and e.dead and e.ghost then
        local ok = ctx.spirit.resurrectCorpse(e, e.corpsePos or e.pos)
        if ok then
            ctx.noteEvents({ { type = "resurrect", pid = pid } })
            return true
        end
        ctx.noteEvents({ { type = "log", text = "You are too far from your corpse", pid = pid } })
    end
    return false
end
function H.resurrect_healer(ctx, pid, cmd)
    local e = ctx.entities[pid]
    if e and not e.dead then
        local targetId = n(cmd.target)
        local target = targetId and ctx.entities[targetId]
        if target and target.dead then
            ctx.spirit.resurrectHealer(target)
            ctx.noteEvents({ { type = "resurrect", pid = target.id, sid = pid } })
            return true
        end
    end
    return false
end
function H.resurrect_respond(ctx, pid, cmd)
    if cmd.accept == true then
        ctx.resurrectionOffer.acceptResurrection(pid, ctx.entities, ctx.spirit)
    else
        ctx.resurrectionOffer.declineResurrection(pid)
    end
    return true
end
function H.unstuck(ctx, pid, cmd)
    local ok, msg = ctx.unstuck.startUnstuck(pid, ctx.entities)
    ctx.noteEvents({ { type = "log", text = ok and "Unstuck countdown..." or (msg or "Failed"), pid = pid } })
    return ok
end
function H.set_town_focus(ctx, pid, cmd)
    local meta = ctx.players[pid]
    if meta then meta.townFocus = { allocation = s(cmd.allocation), tier = n(cmd.tier) } end
    return true
end
function H.deed_set_title(ctx, pid, cmd)
    local meta = ctx.players[pid]
    if meta then meta.activeTitle = s(cmd.deedId) end
    return true
end
function H.telemetry(ctx, pid, cmd) return true end
function H.challengeResponse(ctx, pid, cmd) return true end

-- ============ 宠物 ============
function H.pet_abandon(ctx, pid, cmd)
    local e = ctx.entities[pid]
    if e then ctx.petAI.despawnPet(e, ctx.entities, ctx.grid) end
    return true
end
function H.pet_rename(ctx, pid, cmd)
    local meta = ctx.players[pid]
    if meta then meta.petName = s(cmd.name) end
    return true
end
function H.pet_revive(ctx, pid, cmd)
    local e = ctx.entities[pid]
    if e then ctx.petAI.summonPet(e, "wolf", ctx.entities, ctx.grid, ctx.allocId) end
    return true
end
function H.pet_attack(ctx, pid, cmd)
    local e = ctx.entities[pid]
    if e then ctx.petAI.commandAttack(e, n(cmd.id) or n(cmd.target) or 0, ctx.entities) end
    return true
end
function H.pet_taunt(ctx, pid, cmd)
    local e = ctx.entities[pid]
    if e then e.petTauntTimer = 3 end
    return true
end
function H.pet_water_jet(ctx, pid, cmd) return notImplemented(ctx, pid, "pet_water_jet") end
function H.pet_auto_taunt(ctx, pid, cmd)
    local e = ctx.entities[pid]
    if e then e.petAutoTaunt = cmd.enabled == true end
    return true
end
function H.pet_auto_water_jet(ctx, pid, cmd)
    local e = ctx.entities[pid]
    if e then e.petAutoWaterJet = cmd.enabled == true end
    return true
end
function H.pet_feed(ctx, pid, cmd) return notImplemented(ctx, pid, "pet_feed") end
function H.pet_heal(ctx, pid, cmd)
    local e = ctx.entities[pid]
    if e and e.ownerId then
        local pet = ctx.entities[e.ownerId]
        if pet and not pet.dead then pet.hp = math.min(pet.maxHp, pet.hp + math.floor(pet.maxHp * 0.3)) end
    end
    return true
end
function H.pet_mode(ctx, pid, cmd)
    local e = ctx.entities[pid]
    if e then ctx.petAI.setMode(e, s(cmd.mode) or "defensive", ctx.entities) end
    return true
end

-- ============ Vale Cup ============
function H.vcup_queue(ctx, pid, cmd) return notImplemented(ctx, pid, "vcup_queue") end
function H.vcup_leave(ctx, pid, cmd) return notImplemented(ctx, pid, "vcup_leave") end
function H.vcup_role(ctx, pid, cmd) return notImplemented(ctx, pid, "vcup_role") end
function H.vcup_ready(ctx, pid, cmd) return notImplemented(ctx, pid, "vcup_ready") end
function H.vcup_bet(ctx, pid, cmd) return notImplemented(ctx, pid, "vcup_bet") end
function H.vcup_practice(ctx, pid, cmd) return notImplemented(ctx, pid, "vcup_practice") end

-- ============ Rift ============
function H.rift_upgrade_item(ctx, pid, cmd) return notImplemented(ctx, pid, "rift_upgrade_item") end
function H.rift_enchant_item(ctx, pid, cmd) return notImplemented(ctx, pid, "rift_enchant_item") end
function H.rift_socket_gem(ctx, pid, cmd) return notImplemented(ctx, pid, "rift_socket_gem") end

-- ============ Dev 命令 (ALLOW_DEV_COMMANDS 门控) ============
function H.dev_give(ctx, pid, cmd)
    if not ctx.config.getAllowDevCommands() then return false end
    local e = ctx.entities[pid]
    if not e then return false end
    local level = n(cmd.level) or 1
    local pos = { x = e.pos.x + 3, y = 0, z = e.pos.z }
    local mob = ctx.createMobEntity("forest_wolf", "Test Wolf", level, pos)
    ctx.entities[mob.id] = mob
    ctx.grid.insert(mob)
    ctx.noteEvents({ { type = "log", text = "Spawned mob id=" .. mob.id .. " lv=" .. level, pid = pid } })
    return true
end
function H.dev_level(ctx, pid, cmd)
    if not ctx.config.getAllowDevCommands() then return false end
    local meta = ctx.players[pid]
    local e = ctx.entities[pid]
    if not meta or not e then return false end
    local lv = math.min(n(cmd.level) or 1, ctx.config.MAX_LEVEL)
    meta.level = lv
    e.level = lv
    ctx.playerStats.fullVitals(e, meta.class)
    e.hp = e.maxHp
    e.resource = e.maxResource
    ctx.talent.recomputeForLevel(meta, e, meta.class or e.templateId)
    ctx.playerStats.recalcPlayerStats(e, meta.class, meta.equipment, nil, nil)
    ctx.noteEvents({ { type = "log", text = "Level set to " .. lv, pid = pid } })
    return true
end
function H.dev_teleport(ctx, pid, cmd)
    if not ctx.config.getAllowDevCommands() then return false end
    local e = ctx.entities[pid]
    if not e then return false end
    local x, z = n(cmd.x), n(cmd.z)
    if x and z then
        e.pos.x, e.pos.z = x, z
        ctx.grid.update(e)
    end
    return true
end
function H.dev_complete_quest(ctx, pid, cmd)
    if not ctx.config.getAllowDevCommands() then return false end
    local qid = s(cmd.quest)
    if qid then ctx.quest.acceptQuest(ctx.players[pid], qid); ctx.quest.turninQuest(ctx.players[pid], qid) end
    return true
end
function H.dev_complete_all_quests(ctx, pid, cmd)
    if not ctx.config.getAllowDevCommands() then return false end
    for qid in pairs(ctx.quest.getQuestTable()) do
        ctx.quest.acceptQuest(ctx.players[pid], qid)
        ctx.quest.turninQuest(ctx.players[pid], qid)
    end
    return true
end
function H.dev_bg_start(ctx, pid, cmd) return notImplemented(ctx, pid, "dev_bg_start") end
function H.dev_profiler_invulnerable(ctx, pid, cmd)
    local e = ctx.entities[pid]
    if e then e.devGod = true end
    return true
end

-- ============ 分发表 ============
local HANDLERS = {}
for k, fn in pairs(H) do HANDLERS[k] = fn end

--- 统一分发入口: 返回 ok (boolean), 供调用方决定是否应答 commandOutcome
function M.dispatch(ctx, pid, cmd)
    if not pid or not cmd or not cmd.cmd then return false end
    if not ctx.entities[pid] then return false end
    local handler = HANDLERS[cmd.cmd]
    if not handler then
        ctx.noteEvents({ { type = "log", text = "Unknown command: " .. tostring(cmd.cmd), pid = pid } })
        return false
    end
    local ok, ret = pcall(handler, ctx, pid, cmd)
    if not ok then
        ctx.noteEvents({ { type = "log", text = "Command error (" .. tostring(cmd.cmd) .. "): " .. tostring(ret), pid = pid } })
        return false
    end
    return ret == true
end

return M
