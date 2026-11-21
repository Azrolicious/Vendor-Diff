-- luacheck config for the Vendor Diff WoW: Forever addon (Lua 5.1, 12.1.5 API).
std = "lua51"
max_line_length = 160
self = false -- backend methods share an interface; not all use self
exclude_files = { "tests/**" }

-- Globals the addon defines.
globals = {
  "VendorDiffDB",
  "SLASH_VENDORDIFF1",
  "SLASH_VENDORDIFF2",
  "SlashCmdList",
  "UISpecialFrames",
}

-- WoW API the addon reads.
read_globals = {
  "AuctionHouseFrame", "C_AuctionHouse", "C_Item", "C_Timer", "CreateFrame",
  "DEFAULT_CHAT_FRAME", "Enum", "GameTooltip", "GameTooltip_Hide", "GetMoney",
  "GetTime", "HandleModifiedItemClick", "ITEM_QUALITY_COLORS",
  "IsControlKeyDown", "IsModifiedClick", "UIParent", "UnitName",
  "debugprofilestop", "strjoin", "tinsert", "tostringall", "wipe",
}
