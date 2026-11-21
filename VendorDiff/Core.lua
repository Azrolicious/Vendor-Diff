-- Vendor Diff: find Auction House listings priced below the vendor sell price.
local ADDON_NAME, ns = ...

ns.ADDON_NAME = ADDON_NAME
ns.VERSION = "0.2.1"

local DEFAULTS = {
  minProfit = 1,          -- copper; a listing must beat the vendor price by at least this much
  autoOpen = true,        -- open the window when the Auction House opens
  ignore = {},            -- [itemID] = true, never show these
  position = nil,         -- saved window position {point, relPoint, x, y}
  debug = false,          -- print Auction House traffic during purchases
}

---------------------------------------------------------------------------
-- Item API. WoW Forever runs the 12.1.5 API, where the old global item
-- functions (GetItemInfo, GetDetailedItemLevelInfo, ...) were removed.
---------------------------------------------------------------------------
local C_Item = C_Item
ns.GetItemInfo = C_Item.GetItemInfo
ns.GetItemInfoInstant = C_Item.GetItemInfoInstant
ns.GetDetailedItemLevelInfo = C_Item.GetDetailedItemLevelInfo

function ns.RequestItemData(itemID)
  C_Item.RequestLoadItemDataByID(itemID)
end

---------------------------------------------------------------------------
-- Events
---------------------------------------------------------------------------
local eventFrame = CreateFrame("Frame")
local handlers = {}

-- Register a handler. Returns false (instead of erroring) when the client
-- doesn't know the event, so one file can serve several game versions.
function ns.On(event, fn)
  if not handlers[event] then
    local ok = pcall(eventFrame.RegisterEvent, eventFrame, event)
    if not ok then return false end
    handlers[event] = {}
  end
  table.insert(handlers[event], fn)
  return true
end

eventFrame:SetScript("OnEvent", function(_, event, ...)
  local list = handlers[event]
  if not list then return end
  for i = 1, #list do
    list[i](event, ...)
  end
end)

-- Tiny internal message bus so modules don't need to know about each other.
local listeners = {}
function ns.Listen(message, fn)
  listeners[message] = listeners[message] or {}
  table.insert(listeners[message], fn)
end
function ns.Fire(message, ...)
  local list = listeners[message]
  if not list then return end
  for i = 1, #list do
    list[i](...)
  end
end

---------------------------------------------------------------------------
-- Output
---------------------------------------------------------------------------
function ns.Print(...)
  local msg = strjoin(" ", tostringall(...))
  DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99Vendor Diff|r: " .. msg)
end

---------------------------------------------------------------------------
-- Money
---------------------------------------------------------------------------
local GOLD_ICON = "|TInterface\\MoneyFrame\\UI-GoldIcon:0:0:2:0|t"
local SILVER_ICON = "|TInterface\\MoneyFrame\\UI-SilverIcon:0:0:2:0|t"
local COPPER_ICON = "|TInterface\\MoneyFrame\\UI-CopperIcon:0:0:2:0|t"

local function Thousands(n)
  local formatted = tostring(n)
  local changed
  repeat
    formatted, changed = formatted:gsub("^(%d+)(%d%d%d)", "%1,%2")
  until changed == 0
  return formatted
end

function ns.FormatMoney(copper)
  copper = math.floor((copper or 0) + 0.5)
  local sign = ""
  if copper < 0 then
    sign = "-"
    copper = -copper
  end
  local g = math.floor(copper / 10000)
  local s = math.floor(copper / 100) % 100
  local c = copper % 100
  local parts = {}
  if g > 0 then parts[#parts + 1] = Thousands(g) .. GOLD_ICON end
  if s > 0 then parts[#parts + 1] = s .. SILVER_ICON end
  if c > 0 or #parts == 0 then parts[#parts + 1] = c .. COPPER_ICON end
  return sign .. table.concat(parts, " ")
end

-- Plain-text version for chat and edit boxes, e.g. "1g 20s 5c".
function ns.FormatMoneyPlain(copper)
  copper = math.floor((copper or 0) + 0.5)
  local g = math.floor(copper / 10000)
  local s = math.floor(copper / 100) % 100
  local c = copper % 100
  local parts = {}
  if g > 0 then parts[#parts + 1] = g .. "g" end
  if s > 0 then parts[#parts + 1] = s .. "s" end
  if c > 0 or #parts == 0 then parts[#parts + 1] = c .. "c" end
  return table.concat(parts, " ")
end

-- Accepts "1g 20s 5c", "1g20s", "50s", "75c" or a bare number (copper).
function ns.ParseMoney(text)
  if type(text) == "number" then return math.floor(text) end
  if type(text) ~= "string" then return nil end
  text = text:lower():gsub(",", "")
  if text:match("^%s*(%d+)%s*$") then
    return tonumber(text:match("^%s*(%d+)%s*$"))
  end
  local total, matched = 0, false
  for amount, unit in text:gmatch("(%d+)%s*([gsc])") do
    amount = tonumber(amount)
    matched = true
    if unit == "g" then
      total = total + amount * 10000
    elseif unit == "s" then
      total = total + amount * 100
    else
      total = total + amount
    end
  end
  -- Reject anything that had stray characters we didn't understand.
  local leftover = text:gsub("(%d+)%s*([gsc])", ""):gsub("%s+", "")
  if not matched or leftover ~= "" then return nil end
  return total
end

---------------------------------------------------------------------------
-- Vendor prices
---------------------------------------------------------------------------
-- Per-session cache. Keyed by itemID, or by item link for gear whose
-- sell price can depend on the specific item (bonus IDs on the link).
local vendorCache = {}

-- Returns the per-unit vendor sell price in copper, or nil if the item
-- isn't in the client cache yet (call again after it loads).
function ns.GetVendorPrice(item)
  local cached = vendorCache[item]
  if cached ~= nil then return cached end
  local sellPrice = select(11, ns.GetItemInfo(item))
  if sellPrice == nil then return nil end
  vendorCache[item] = sellPrice
  return sellPrice
end

local CLASS_WEAPON = (Enum and Enum.ItemClass and Enum.ItemClass.Weapon) or 2
local CLASS_ARMOR = (Enum and Enum.ItemClass and Enum.ItemClass.Armor) or 4

function ns.IsGear(itemID)
  local classID = select(6, ns.GetItemInfoInstant(itemID))
  return classID == CLASS_WEAPON or classID == CLASS_ARMOR
end

---------------------------------------------------------------------------
-- Misc helpers
---------------------------------------------------------------------------
function ns.QualityColor(quality)
  local c = ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[quality or 1]
  if c and c.hex then return c.hex end
  local hex = select(4, C_Item.GetItemQualityColor(quality or 1))
  return hex and ("|c" .. hex) or "|cffffffff"
end

ns.ahOpen = false

---------------------------------------------------------------------------
-- Init / AH open & close
---------------------------------------------------------------------------
ns.On("ADDON_LOADED", function(_, name)
  if name ~= ADDON_NAME then return end
  VendorDiffDB = VendorDiffDB or {}
  for k, v in pairs(DEFAULTS) do
    if VendorDiffDB[k] == nil then
      if type(v) == "table" then
        VendorDiffDB[k] = {}
      else
        VendorDiffDB[k] = v
      end
    end
  end
  ns.db = VendorDiffDB
  ns.Fire("DB_READY")
end)

local function AuctionHouseOpened()
  if ns.ahOpen then return end -- both events below can report the same visit
  ns.ahOpen = true
  ns.Fire("AH_OPENED")
end

local function AuctionHouseClosed()
  if not ns.ahOpen then return end
  ns.ahOpen = false
  ns.Fire("AH_CLOSED")
end

ns.On("AUCTION_HOUSE_SHOW", AuctionHouseOpened)
ns.On("AUCTION_HOUSE_CLOSED", AuctionHouseClosed)

-- The 12.x UI also reports the auctioneer through the interaction manager.
local function IsAuctioneer(kind)
  local types = Enum and Enum.PlayerInteractionType
  return types ~= nil and types.Auctioneer ~= nil and kind == types.Auctioneer
end
ns.On("PLAYER_INTERACTION_MANAGER_FRAME_SHOW", function(_, kind)
  if IsAuctioneer(kind) then AuctionHouseOpened() end
end)
ns.On("PLAYER_INTERACTION_MANAGER_FRAME_HIDE", function(_, kind)
  if IsAuctioneer(kind) then AuctionHouseClosed() end
end)

---------------------------------------------------------------------------
-- Slash commands
---------------------------------------------------------------------------
local function ItemIDFromArg(arg)
  if not arg or arg == "" then return nil end
  local id = tonumber(arg) or tonumber(arg:match("item:(%d+)"))
  return id
end

local HELP = {
  "/vd - toggle the window",
  "/vd scan - start a full Auction House scan",
  "/vd minprofit <amount> - e.g. /vd minprofit 50s (current: %s)",
  "/vd ignore <item link or ID> - never show an item",
  "/vd unignore <item link or ID|all> - stop ignoring",
  "/vd autoopen - toggle opening with the Auction House",
  "/vd debug - toggle printing what the Auction House reports during searches and purchases",
  "/vd reset - reset the window position",
}

SLASH_VENDORDIFF1 = "/vendordiff"
SLASH_VENDORDIFF2 = "/vd"
SlashCmdList.VENDORDIFF = function(input)
  input = input or ""
  local cmd, rest = input:match("^%s*(%S*)%s*(.-)%s*$")
  cmd = (cmd or ""):lower()

  if cmd == "" then
    ns.UI:Toggle()
  elseif cmd == "scan" then
    ns.Scan:Start()
  elseif cmd == "minprofit" then
    local amount = ns.ParseMoney(rest)
    if not amount or amount < 1 then
      ns.Print("Usage: /vd minprofit 50s  (must be at least 1c)")
      return
    end
    ns.db.minProfit = amount
    ns.Print("Minimum profit set to " .. ns.FormatMoney(amount))
    ns.Fire("SETTINGS_CHANGED")
  elseif cmd == "ignore" then
    local id = ItemIDFromArg(rest)
    if not id then ns.Print("Usage: /vd ignore <item link or ID>") return end
    ns.db.ignore[id] = true
    ns.Results:RemoveItemID(id)
    ns.Print("Ignoring item " .. id .. ".")
  elseif cmd == "unignore" then
    if rest:lower() == "all" then
      wipe(ns.db.ignore)
      ns.Print("Ignore list cleared.")
      return
    end
    local id = ItemIDFromArg(rest)
    if not id then ns.Print("Usage: /vd unignore <item link or ID|all>") return end
    ns.db.ignore[id] = nil
    ns.Print("No longer ignoring item " .. id .. ". Rescan to see it.")
  elseif cmd == "debug" then
    ns.db.debug = not ns.db.debug
    ns.Print("Debug output: " .. (ns.db.debug and "on" or "off"))
  elseif cmd == "autoopen" then
    ns.db.autoOpen = not ns.db.autoOpen
    ns.Print("Open with Auction House: " .. (ns.db.autoOpen and "on" or "off"))
  elseif cmd == "reset" then
    ns.db.position = nil
    ns.UI:ResetPosition()
    ns.Print("Window position reset.")
  else
    for _, line in ipairs(HELP) do
      ns.Print(line:format(ns.FormatMoneyPlain(ns.db.minProfit)))
    end
  end
end
