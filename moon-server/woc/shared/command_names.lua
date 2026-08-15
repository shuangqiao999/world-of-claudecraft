-- World of ClaudeCraft — 命令名称枚举
-- 对应原项目 src/world_api.ts:COMMAND_NAMES
-- 每个命令名是唯一的字符串 token，客户端通过 {t:"cmd", cmd:"<name>", ...} 发送

local M = {}

M.COMMAND_NAMES = {
    -- 战斗
    "castSlot", "castAt", "cast", "cancel_aura", "releaseEmpowered",
    "attack", "stopattack", "stopAutoAttackOnTargetSwitch",

    -- 目标选择
    "target", "tab", "tabFriendly", "targetNearestFriendly",

    -- 交互
    "interact", "loot", "autoloot", "harvestCorpse", "lootRoll", "pickup",

    -- 任务
    "accept", "turnin", "abandon", "qlinkaccept",

    -- 物品/装备
    "equip", "inv_move", "unequip_item", "use", "discard",
    "equip_bag", "unequip_bag",

    -- 商店
    "buy", "sell", "buyback", "sell_all_junk",

    -- 银行
    "bank_deposit", "bank_withdraw", "bank_buy_slots",

    -- 公会银行
    "guild_bank_deposit_gold", "guild_bank_withdraw_gold",
    "guild_bank_deposit", "guild_bank_withdraw", "guild_bank_buy_slots",
    "guild_bank_log",

    -- 外观
    "change_skin", "unequip_mech_chroma", "claim_event_skin",
    "change_weapon_skin", "stow_weapon", "set_helm",

    -- 聊天/表情
    "chat", "emote",

    -- 组队
    "pinvite", "paccept", "pdecline", "pleave", "pkick", "ppromote",
    "praid", "punraid", "pmoveRaid",
    "setLootMaster", "masterAssign", "setMarker", "clearMarker",
    "readyrespond",

    -- 宠物
    "pet_abandon", "pet_rename", "pet_revive", "pet_attack",
    "pet_water_jet", "pet_taunt", "pet_auto_taunt",
    "pet_auto_water_jet", "pet_feed", "pet_heal", "pet_mode",

    -- 交易
    "trade_req", "trade_accept", "trade_offer", "trade_confirm",
    "trade_cancel",

    -- 决斗
    "duel_req", "duel_accept", "duel_decline",

    -- 社交
    "friend_add", "friend_remove",
    "block_add", "block_remove",
    "ignore_add", "ignore_remove",

    -- 公会
    "guild_create", "guild_invite", "guild_accept", "guild_decline",
    "guild_leave", "guild_kick", "guild_promote", "guild_demote",
    "guild_transfer", "guild_disband",
    "guild_event_create", "guild_event_remove", "guild_set_motd",

    -- 竞技场
    "arena_queue", "arena_leave", "arena_augment",

    -- 卡片
    "card_queue_join", "card_queue_leave", "play_card", "card_forfeit",

    -- 声望
    "prestige",

    -- 天赋
    "applyTalents", "respec", "setSpec",
    "saveLoadout", "switchLoadout", "deleteLoadout",
    "selectTalentRow",

    -- 拍卖行
    "market_search", "market_list", "market_list_instance",
    "market_buy", "market_cancel", "market_collect",

    -- 邮件
    "mail_send", "mail_take", "mail_delete", "mail_read",

    -- 副本
    "enter_dungeon", "leave_dungeon", "set_dungeon_difficulty",
    "heroic_buy",

    -- deep学习
    "enter_delve", "leave_delve", "delve_interact",
    "companion_upgrade", "delve_buy",
    "lockpick_engage", "lockpick_action", "lockpick_abort",
    "collect_delve_chest_loot", "delve_rite_choose",

    -- 专业
    "harvest_node", "craft_item", "place_mobile_station",
    "train_recipe", "slot_tool_effect", "recharge_tool_effect",
    "disenchant_item", "apply_enchant", "salvage_item", "unbind_item",
    "open_commission_order", "cancel_commission_order",
    "accept_commission_order", "deliver_commission_order",

    -- 坐骑
    "mount_toggle", "mount_train_begin", "mount_train_answer",
    "mount_train_abort", "mount_race_start", "mount_race_cancel",
    "learn_riding",

    -- 寻地下城
    "df_roles", "df_queue", "df_queue_leave", "df_proposal",
    "df_list_create", "df_list_close", "df_apply", "df_apply_cancel",
    "df_app_respond",

    -- Vale Cup
    "vcup_queue", "vcup_leave", "vcup_role", "vcup_ready",
    "vcup_bet", "vcup_practice",

    -- Rift
    "rift_upgrade_item", "rift_enchant_item", "rift_socket_gem",

    -- 成就
    "deed_set_title",

    -- 移动/通用
    "release", "resurrect_corpse", "resurrect_healer",
    "resurrect_respond", "unstuck",

    -- 战场
    "bg_queue", "bg_leave", "bg_flag",

    -- 杂项
    "telemetry", "challengeResponse", "set_town_focus",
    "save_hotbar_layout",

    -- 开发命令 (gated by ALLOW_DEV_COMMANDS)
    "dev_level", "dev_teleport", "dev_give", "dev_target", "dev_ranged",
    "dev_complete_quest", "dev_complete_all_quests",
    "dev_bg_start", "dev_profiler_invulnerable",
}

-- 构建快速查找 set
M.IS_COMMAND = {}
for _, name in ipairs(M.COMMAND_NAMES) do
    M.IS_COMMAND[name] = true
end

return M
