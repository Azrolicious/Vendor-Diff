-- A small, strict mock of the parts of the WoW: Forever client API (12.1.5 API
-- set, retail-style Auction House) that Vendor Diff uses.
-- Each World is an isolated environment: the addon's files are loaded with
-- setfenv so several scenarios can run in one Lua process.
--
-- Strictness is the point: unknown widget methods, SetBackdrop without
-- BackdropTemplate, unknown events, and purchases outside a hardware event
-- all raise errors, the way the real client would misbehave or block.

local Mock = {}

-- The addon lives next to this tests/ directory.
local HERE = debug.getinfo(1, "S").source:match("^@(.-)[^/]*$") or "./"
local ADDON_DIR = HERE .. "../VendorDiff"

local function copy(t)
  local r = {}
  for k, v in pairs(t) do r[k] = v end
  return r
end

---------------------------------------------------------------------------
-- Widgets
---------------------------------------------------------------------------
local COMMON = {
  "SetSize", "SetWidth", "SetHeight", "GetWidth", "GetHeight", "SetPoint", "ClearAllPoints",
  "GetPoint", "SetAllPoints", "Show", "Hide", "IsShown", "IsVisible", "SetShown",
}
local FRAME = {
  "SetScript", "GetScript", "CreateFontString", "CreateTexture", "RegisterEvent", "UnregisterEvent",
  "SetFrameStrata", "SetToplevel", "SetClampedToScreen", "EnableMouse", "SetMovable",
  "SetDontSavePosition", "RegisterForDrag", "StartMoving", "StopMovingOrSizing", "EnableMouseWheel",
}
local BUTTON = { "SetText", "GetText", "Enable", "Disable", "IsEnabled", "SetHighlightTexture", "RegisterForClicks" }
local EDITBOX = { "SetText", "GetText", "SetAutoFocus", "SetMaxLetters", "ClearFocus", "SetFocus" }
local SLIDER = {
  "SetOrientation", "SetThumbTexture", "SetMinMaxValues", "GetMinMaxValues", "SetValueStep",
  "SetObeyStepOnDrag", "SetValue", "GetValue",
}
local FONTSTRING = {
  "SetJustifyH", "SetJustifyV", "SetWordWrap", "SetText", "GetText", "SetTextColor", "GetStringWidth",
}
local TEXTURE = { "SetTexture", "SetColorTexture", "SetTexCoord" }
local BACKDROP = { "SetBackdrop", "SetBackdropColor", "SetBackdropBorderColor" }

local function methodSet(...)
  local set = {}
  for _, list in ipairs({ ... }) do
    for _, name in ipairs(list) do set[name] = true end
  end
  return set
end

local ALLOWED = {
  Frame = methodSet(COMMON, FRAME),
  Button = methodSet(COMMON, FRAME, BUTTON),
  EditBox = methodSet(COMMON, FRAME, EDITBOX),
  Slider = methodSet(COMMON, FRAME, SLIDER),
  FontString = methodSet(COMMON, FONTSTRING),
  Texture = methodSet(COMMON, TEXTURE),
}

local KNOWN_TEMPLATES = {
  BackdropTemplate = true,
  UIPanelButtonTemplate = true,
  UIPanelCloseButton = true,
  InputBoxTemplate = true,
}

local Widget = {}

function Widget.new(world, kind, name, parent, template)
  local w = {
    _world = world, _kind = kind, _name = name, _parent = parent,
    _shown = true, _enabled = true, _scripts = {}, _text = nil,
    _width = 100, _height = 20, _value = 0, _min = 0, _max = 0, _points = {},
  }
  local allowed = copy(ALLOWED[kind] or error("unknown widget type " .. tostring(kind)))
  if template then
    for t in template:gmatch("[^,%s]+") do
      if not KNOWN_TEMPLATES[t] then error("unknown template " .. t, 3) end
      if t == "BackdropTemplate" then
        for _, m in ipairs(BACKDROP) do allowed[m] = true end
      end
    end
  end
  w._allowed = allowed
  return setmetatable(w, Widget)
end

Widget.__index = function(self, key)
  if type(key) == "string" and key:sub(1, 1) == "_" then return nil end -- unset internal field
  local impl = rawget(Widget, key)
  if rawget(self, "_allowed")[key] then
    return impl or function() end
  end
  error(("%s has no method '%s'"):format(rawget(self, "_kind"), tostring(key)), 2)
end

function Widget:SetSize(w, h) self._width, self._height = w, h end
function Widget:SetWidth(w) self._width = w end
function Widget:SetHeight(h) self._height = h end
function Widget:GetWidth() return self._width end
function Widget:GetHeight() return self._height end
function Widget:SetPoint(point, rel, relPoint, x, y)
  assert(type(point) == "string", "SetPoint needs a point name")
  self._points[#self._points + 1] = { point, rel, relPoint, x, y }
end
function Widget:ClearAllPoints() self._points = {} end
function Widget:GetPoint(i)
  local p = self._points[i or 1]
  if p then return p[1], p[2], p[3] or p[1], p[4] or 0, p[5] or 0 end
end
function Widget:Show()
  local was = self._shown
  self._shown = true
  if not was and self._scripts.OnShow then self._scripts.OnShow(self) end
end
function Widget:Hide()
  local was = self._shown
  self._shown = false
  if was and self._scripts.OnHide then self._scripts.OnHide(self) end
end
function Widget:IsShown()
  if not self._shown then return false end
  local p = self._parent
  while p do
    if not p._shown then return false end
    p = p._parent
  end
  return true
end
function Widget:IsVisible() return self:IsShown() end
function Widget:SetShown(v) if v then self:Show() else self:Hide() end end
function Widget:SetScript(name, fn) self._scripts[name] = fn end
function Widget:GetScript(name) return self._scripts[name] end
function Widget:CreateFontString() return Widget.new(self._world, "FontString", nil, self) end
function Widget:CreateTexture() return Widget.new(self._world, "Texture", nil, self) end
function Widget:SetText(t) self._text = t ~= nil and tostring(t) or nil end
function Widget:GetText() return self._text end
function Widget:GetStringWidth() return self._text and #self._text * 6 or 0 end
function Widget:Enable() self._enabled = true end
function Widget:Disable() self._enabled = false end
function Widget:IsEnabled() return self._enabled end
function Widget:SetMinMaxValues(a, b) self._min, self._max = a, b; self:SetValue(self._value) end
function Widget:GetMinMaxValues() return self._min, self._max end
function Widget:SetValue(v)
  v = math.max(self._min, math.min(self._max, v))
  local changed = v ~= self._value
  self._value = v
  if changed and self._scripts.OnValueChanged then self._scripts.OnValueChanged(self, v) end
end
function Widget:GetValue() return self._value end
function Widget:RegisterEvent(event)
  local world = self._world
  if not world.knownEvents[event] then
    error("Attempt to register unknown event \"" .. event .. "\"", 2)
  end
  world.eventFrames[event] = world.eventFrames[event] or {}
  table.insert(world.eventFrames[event], self)
end

---------------------------------------------------------------------------
-- World
---------------------------------------------------------------------------
local MODERN_EVENTS = {
  "ADDON_LOADED", "AUCTION_HOUSE_SHOW", "AUCTION_HOUSE_CLOSED", "GET_ITEM_INFO_RECEIVED",
  "UI_ERROR_MESSAGE", "AUCTION_HOUSE_THROTTLED_SYSTEM_READY",
  "AUCTION_HOUSE_BROWSE_RESULTS_UPDATED", "AUCTION_HOUSE_BROWSE_RESULTS_ADDED", "AUCTION_HOUSE_BROWSE_FAILURE",
  "PLAYER_INTERACTION_MANAGER_FRAME_SHOW", "PLAYER_INTERACTION_MANAGER_FRAME_HIDE",
  "COMMODITY_SEARCH_RESULTS_UPDATED", "COMMODITY_SEARCH_RESULTS_ADDED", "ITEM_SEARCH_RESULTS_UPDATED",
  "ITEM_SEARCH_RESULTS_ADDED", "COMMODITY_PRICE_UPDATED", "COMMODITY_PRICE_UNAVAILABLE",
  "COMMODITY_PURCHASE_SUCCEEDED", "COMMODITY_PURCHASE_FAILED", "AUCTION_HOUSE_PURCHASE_COMPLETED",
  "AUCTION_HOUSE_SHOW_ERROR",
}

local World = {}
World.__index = World

-- opts.withoutEvents = { "EVENT", ... } simulates a client lacking an event.
function Mock.NewWorld(opts)
  opts = opts or {}
  local world = setmetatable({
    now = 1000,
    profileMs = 0,
    profileStep = 4, -- ms per debugprofilestop() call; forces scans to span several frames
    timers = {},
    timerSeq = 0,
    eventFrames = {},
    knownEvents = {},
    chat = {},
    money = opts.money or 1000000,
    hardware = false,
    hwViolations = {},
    calls = {},
    items = {},
    shift = false, ctrl = false,
    playerName = "Tester",
  }, World)
  for _, e in ipairs(MODERN_EVENTS) do
    world.knownEvents[e] = true
  end
  for _, e in ipairs(opts.withoutEvents or {}) do world.knownEvents[e] = nil end
  world:BuildEnv()
  return world
end

function World:Call(name, ...)
  local list = self.calls[name] or {}
  self.calls[name] = list
  list[#list + 1] = { ... }
end

function World:RequireHardware(name)
  if not self.hardware then
    table.insert(self.hwViolations, name)
    error(name .. " called outside a hardware event", 3)
  end
end

-- Timers ------------------------------------------------------------------
function World:AddTimer(delay, fn, interval, iterations)
  self.timerSeq = self.timerSeq + 1
  -- Nothing runs sooner than the next frame (1/60 s), like the real client.
  local t = { at = self.now + math.max(delay or 0, 1 / 60), fn = fn, seq = self.timerSeq, interval = interval,
              left = iterations, cancelled = false }
  t.handle = {
    Cancel = function() t.cancelled = true end,
    IsCancelled = function() return t.cancelled end,
  }
  table.insert(self.timers, t)
  return t.handle
end

-- Advance the clock, running timers in order. "Next frame" timers (delay 0)
-- run on the next 1/60s tick, like OnUpdate-driven timers in the client.
function World:Advance(seconds)
  local target = self.now + seconds
  local frame = 1 / 60
  while true do
    local nextT
    for _, t in ipairs(self.timers) do
      if not t.cancelled and (not nextT or t.at < nextT.at or (t.at == nextT.at and t.seq < nextT.seq)) then
        nextT = t
      end
    end
    if not nextT or nextT.at > target then break end
    self.now = math.max(self.now, nextT.at)
    -- timers scheduled for "now" fire on the next frame
    if nextT.at <= self.now then
      if nextT.interval then
        nextT.at = self.now + math.max(nextT.interval, frame)
        if nextT.left then
          nextT.left = nextT.left - 1
          if nextT.left <= 0 then nextT.cancelled = true end
        end
      else
        nextT.cancelled = true
      end
      nextT.fn(nextT.handle)
    end
    -- drop finished timers
    local keep = {}
    for _, t in ipairs(self.timers) do if not t.cancelled then keep[#keep + 1] = t end end
    self.timers = keep
  end
  self.now = target
end

-- Events ------------------------------------------------------------------
function World:Fire(event, ...)
  assert(self.knownEvents[event], "test fired unknown event " .. event)
  for _, frame in ipairs(self.eventFrames[event] or {}) do
    local fn = frame._scripts.OnEvent
    if fn then fn(frame, event, ...) end
  end
end

function World:FireLater(delay, event, ...)
  local args = { n = select("#", ...), ... }
  self:AddTimer(delay, function() self:Fire(event, unpack(args, 1, args.n)) end)
end

-- Simulated player input --------------------------------------------------
function World:Click(button, mouseButton, mods)
  assert(button, "Click: no button")
  if not button._enabled then return false end
  mods = mods or {}
  self.shift, self.ctrl = mods.shift or false, mods.ctrl or false
  self.hardware = true
  local ok, err = pcall(button._scripts.OnClick, button, mouseButton or "LeftButton")
  self.hardware = false
  self.shift, self.ctrl = false, false
  if not ok then error(err, 2) end
  return true
end

function World:ChatContains(pattern)
  for _, line in ipairs(self.chat) do
    if line:find(pattern) then return true end
  end
  return false
end

-- Items -------------------------------------------------------------------
-- def = { id, name, quality, sellPrice, classID, ilvl, stack, availableAt }
function World:AddItem(def)
  def.quality = def.quality or 1
  def.classID = def.classID or 7
  def.ilvl = def.ilvl or 1
  def.availableAt = def.availableAt or 0
  def.texture = def.texture or ("icon" .. def.id)
  self.items[def.id] = def
  return def
end

function World:ItemLink(id, ilvl)
  local d = self.items[id]
  return ("|cffffffff|Hitem:%d::::::::%d:::::|h[%s]|h|r"):format(id, ilvl or d.ilvl, d.name)
end

local function ItemIDFrom(item)
  if type(item) == "number" then return item end
  return tonumber(tostring(item):match("item:(%d+)"))
end

---------------------------------------------------------------------------
-- Environment construction
---------------------------------------------------------------------------
function World:BuildEnv()
  local world = self
  local env = {}
  self.env = env
  -- Names that may legitimately be nil (SavedVariables before first save).
  world.declared = {}
  setmetatable(env, { __index = function(_, k)
    if world.declared[k] then return nil end
    error("addon read undefined global '" .. tostring(k) .. "'", 2)
  end })

  -- Lua standard library
  for _, name in ipairs({ "assert", "error", "ipairs", "next", "pairs", "pcall", "print", "rawget",
    "rawset", "select", "setmetatable", "getmetatable", "tonumber", "tostring", "type", "unpack",
    "xpcall", "math", "string", "table", "coroutine" }) do
    rawset(env, name, _G[name])
  end
  env._G = env

  -- WoW Lua extras
  env.wipe = function(t) for k in pairs(t) do t[k] = nil end return t end
  env.tinsert = table.insert
  env.strjoin = function(sep, ...) return table.concat({ ... }, sep) end
  env.tostringall = function(...)
    local r = {}
    for i = 1, select("#", ...) do r[i] = tostring((select(i, ...))) end
    return unpack(r, 1, select("#", ...))
  end
  env.time = function() return math.floor(world.now) end
  env.GetTime = function() return world.now end
  env.debugprofilestop = function()
    world.profileMs = world.profileMs + world.profileStep
    return world.profileMs
  end
  env.hooksecurefunc = function(name, fn)
    local orig = env[name]
    assert(type(orig) == "function", "hooksecurefunc on missing " .. name)
    rawset(env, name, function(...)
      local r = { orig(...) }
      fn(...)
      return unpack(r)
    end)
  end

  -- Timers
  env.C_Timer = {
    After = function(delay, fn) world:AddTimer(delay, function() fn() end) end,
    NewTimer = function(delay, fn) return world:AddTimer(delay, fn) end,
    NewTicker = function(interval, fn, iterations) return world:AddTimer(interval, fn, interval, iterations) end,
  }

  -- Frames
  env.CreateFrame = function(kind, name, parent, template)
    local w = Widget.new(world, kind, name, parent, template)
    if name then rawset(env, name, w) end
    if template and template:find("UIPanelCloseButton") then
      w._scripts.OnClick = function(btn) if btn._parent then btn._parent:Hide() end end
    end
    return w
  end
  env.UIParent = Widget.new(world, "Frame", "UIParent")
  env.UISpecialFrames = {}
  env.DEFAULT_CHAT_FRAME = { AddMessage = function(_, msg) table.insert(world.chat, msg) end }
  env.SlashCmdList = {}
  env.GameTooltip = setmetatable({}, { __index = function() return function() end end })
  env.GameTooltip_Hide = function() end
  env.HandleModifiedItemClick = function() return world.shift end
  env.IsModifiedClick = function() return world.shift or world.ctrl end
  env.IsShiftKeyDown = function() return world.shift end
  env.IsControlKeyDown = function() return world.ctrl end
  env.UnitName = function() return world.playerName end
  env.GetRealmName = function() return "TestRealm" end
  env.GetMoney = function() return world.money end
  env.Enum = {
    AuctionHouseSortOrder = { Price = 0 },
    ItemClass = { Weapon = 2, Armor = 4 },
    PlayerInteractionType = { Auctioneer = 21 },
  }
  env.ITEM_QUALITY_COLORS = {}
  for q = 0, 8 do env.ITEM_QUALITY_COLORS[q] = { hex = "|cffq" .. q } end

  -- Items
  local function GetItemInfo(item)
    local id = ItemIDFrom(item)
    local d = id and world.items[id]
    if not d then return nil end
    if world.now < d.availableAt then
      world:Call("ItemDataRequested", id)
      return nil
    end
    local ilvl = tonumber(tostring(item):match("item:%d+::::::::(%d+)")) or d.ilvl
    local sell = d.sellPrice
    if d.sellPriceByIlvl and type(item) == "string" then sell = d.sellPriceByIlvl[ilvl] or sell end
    return d.name, world:ItemLink(id, ilvl), d.quality, ilvl, 1, "Type", "SubType", d.stack or 1, "",
      d.texture, sell, d.classID, 0
  end
  local function GetItemInfoInstant(item)
    local id = ItemIDFrom(item)
    local d = world.items[id]
    if not d then return nil end
    return id, "Type", "SubType", "", d.texture, d.classID, 0
  end
  local function GetDetailedItemLevelInfo(link)
    return tonumber(tostring(link):match("item:%d+::::::::(%d+)"))
  end
  env.C_Item = {
    GetItemInfo = GetItemInfo,
    GetItemInfoInstant = GetItemInfoInstant,
    GetDetailedItemLevelInfo = GetDetailedItemLevelInfo,
    RequestLoadItemDataByID = function(id) world:Call("RequestLoadItemDataByID", id) end,
  }

  self:BuildModernAH()
end

---------------------------------------------------------------------------
-- Modern AH (C_AuctionHouse)
---------------------------------------------------------------------------
-- world.commodities[itemID]: array of { unitPrice, quantity, numOwnerItems }
-- world.itemAuctions[itemID]: array of { auctionID, buyout (nil = bid only), bid, quantity, ilvl, own }
-- The browse ("summary") scan is derived from the same data, so scan and live
-- search always agree, like on the real server.
function World:BuildModernAH()
  local world, env = self, self.env
  world.commodities = {}
  world.itemAuctions = {}
  world.throttleReady = true
  world.searchDelay = 0.2
  world.browsePageSize = 500
  world.browseFail = false     -- reply with AUCTION_HOUSE_BROWSE_FAILURE
  world.browseStallAfter = nil -- stop answering after this many pages
  world.sellTabViolations = 0  -- AH requests sent while Blizzard's Sell tab was visible
  local ah = Widget.new(world, "Frame", "AuctionHouseFrame")
  rawset(ah, "ItemSellFrame", Widget.new(world, "Frame", nil, ah))
  rawset(ah, "CommoditiesSellFrame", Widget.new(world, "Frame", nil, ah))
  ah.ItemSellFrame:Hide()
  ah.CommoditiesSellFrame:Hide()
  rawset(env, "AuctionHouseFrame", ah)

  local function sentRequest()
    if ah.ItemSellFrame:IsVisible() or ah.CommoditiesSellFrame:IsVisible() then
      world.sellTabViolations = world.sellTabViolations + 1
    end
  end

  local function isCommodity(id) return world.commodities[id] ~= nil end
  local function sortedCommodity(id)
    local list = world.commodities[id] or {}
    table.sort(list, function(a, b) return a.unitPrice < b.unitPrice end)
    return list
  end
  local function matchingItems(itemKey)
    local res = {}
    for _, a in ipairs(world.itemAuctions[itemKey.itemID] or {}) do
      if (itemKey.itemLevel or 0) == 0 or a.ilvl == itemKey.itemLevel then res[#res + 1] = a end
    end
    table.sort(res, function(a, b) return (a.buyout or math.huge) < (b.buyout or math.huge) end)
    return res
  end

  local function buildBrowse()
    local all = {}
    for id, list in pairs(world.commodities) do
      local minPrice, qty, own
      for _, r in ipairs(list) do
        if not minPrice or r.unitPrice < minPrice then minPrice = r.unitPrice end
        qty = (qty or 0) + r.quantity
        own = own or (r.numOwnerItems or 0) > 0
      end
      if minPrice then
        all[#all + 1] = { itemKey = { itemID = id, itemLevel = 0, itemSuffix = 0, battlePetSpeciesID = 0 },
                          minPrice = minPrice, totalQuantity = qty, containsOwnerItem = own or false }
      end
    end
    for id, list in pairs(world.itemAuctions) do
      local byIlvl = {}
      for _, a in ipairs(list) do
        local lvl = a.ilvl or 0
        local e = byIlvl[lvl] or { qty = 0 }
        byIlvl[lvl] = e
        -- Pessimistic model: a bid-only auction reports its bid as the price.
        local price = a.buyout or a.bid
        if not e.minPrice or price < e.minPrice then e.minPrice = price end
        e.qty = e.qty + (a.quantity or 1)
      end
      for lvl, e in pairs(byIlvl) do
        all[#all + 1] = { itemKey = { itemID = id, itemLevel = lvl, itemSuffix = 0, battlePetSpeciesID = 0 },
                          minPrice = e.minPrice, totalQuantity = e.qty, containsOwnerItem = false }
      end
    end
    table.sort(all, function(a, b)
      if a.itemKey.itemID ~= b.itemKey.itemID then return a.itemKey.itemID < b.itemKey.itemID end
      return a.itemKey.itemLevel < b.itemKey.itemLevel
    end)
    return all
  end

  local function deliverPage(event)
    world.browsePages = world.browsePages + 1
    if world.browseStallAfter and world.browsePages > world.browseStallAfter then return end
    local from = #world.browseShown + 1
    for i = from, math.min(#world.browseAll, from + world.browsePageSize - 1) do
      world.browseShown[#world.browseShown + 1] = world.browseAll[i]
    end
    world:FireLater(0.3, event)
  end

  local AH = {}
  env.C_AuctionHouse = AH
  function AH.SendBrowseQuery(query)
    assert(world.throttleReady, "SendBrowseQuery while throttled")
    assert(type(query) == "table" and query.searchString == "" and type(query.sorts) == "table",
      "bad browse query")
    sentRequest()
    world:Call("SendBrowseQuery", query)
    if world.browseFail then
      world:FireLater(0.3, "AUCTION_HOUSE_BROWSE_FAILURE")
      return
    end
    world.browseAll, world.browseShown, world.browsePages = buildBrowse(), {}, 0
    deliverPage("AUCTION_HOUSE_BROWSE_RESULTS_UPDATED")
  end
  function AH.RequestMoreBrowseResults()
    assert(world.throttleReady, "RequestMoreBrowseResults while throttled")
    sentRequest()
    world:Call("RequestMoreBrowseResults")
    deliverPage("AUCTION_HOUSE_BROWSE_RESULTS_ADDED")
  end
  function AH.HasFullBrowseResults()
    return world.browseShown ~= nil and #world.browseShown >= #world.browseAll
  end
  function AH.GetBrowseResults()
    local copyList = {}
    for i, r in ipairs(world.browseShown or {}) do copyList[i] = r end
    return copyList
  end
  function AH.MakeItemKey(itemID, itemLevel, itemSuffix, species)
    return { itemID = itemID, itemLevel = itemLevel or 0, itemSuffix = itemSuffix or 0, battlePetSpeciesID = species or 0 }
  end
  function AH.IsThrottledMessageSystemReady() return world.throttleReady end
  function AH.SendSearchQuery(itemKey, sorts, separateOwnerItems)
    assert(world.throttleReady, "SendSearchQuery while throttled")
    sentRequest()
    assert(type(sorts) == "table" and separateOwnerItems ~= nil, "bad SendSearchQuery args")
    world:Call("SendSearchQuery", itemKey)
    if isCommodity(itemKey.itemID) then
      world:FireLater(world.searchDelay, "COMMODITY_SEARCH_RESULTS_UPDATED", itemKey.itemID)
    else
      world:FireLater(world.searchDelay, "ITEM_SEARCH_RESULTS_UPDATED", copy(itemKey))
    end
  end
  function AH.GetNumCommoditySearchResults(id) return #sortedCommodity(id) end
  function AH.GetCommoditySearchResultInfo(id, i)
    local r = sortedCommodity(id)[i]
    if not r then return nil end
    return { itemID = id, unitPrice = r.unitPrice, quantity = r.quantity, numOwnerItems = r.numOwnerItems or 0,
             auctionID = i, containsOwnerItem = (r.numOwnerItems or 0) > 0 }
  end
  function AH.HasFullCommoditySearchResults() return true end
  function AH.RequestMoreCommoditySearchResults() end
  function AH.GetNumItemSearchResults(itemKey) return #matchingItems(itemKey) end
  function AH.GetItemSearchResultInfo(itemKey, i)
    local a = matchingItems(itemKey)[i]
    if not a then return nil end
    return { itemKey = itemKey, auctionID = a.auctionID, quantity = a.quantity or 1, buyoutAmount = a.buyout,
             itemLink = world:ItemLink(itemKey.itemID, a.ilvl), containsOwnerItem = a.own or false,
             containsAccountItem = false }
  end
  function AH.HasFullItemSearchResults() return true end
  function AH.RequestMoreItemSearchResults() end

  local function commodityQuote(id, quantity)
    local total, left, unit = 0, quantity, 0
    for _, r in ipairs(sortedCommodity(id)) do
      local avail = r.quantity - (r.numOwnerItems or 0)
      local take = math.min(avail, left)
      total = total + take * r.unitPrice
      left = left - take
      unit = r.unitPrice
      if left == 0 then break end
    end
    return left == 0 and total or nil, unit
  end

  function AH.StartCommoditiesPurchase(id, quantity)
    world:RequireHardware("StartCommoditiesPurchase") -- HasRestrictions in the Forever API docs
    sentRequest()
    world:Call("StartCommoditiesPurchase", id, quantity)
    world.quote = { itemID = id, quantity = quantity }
    if world.priceBump then
      world.priceBump()
      world.priceBump = nil
    end
    local total, unit = commodityQuote(id, quantity)
    if total then
      world:FireLater(0.2, "COMMODITY_PRICE_UPDATED", unit, total)
    else
      world:FireLater(0.2, "COMMODITY_PRICE_UNAVAILABLE")
    end
  end
  function AH.CancelCommoditiesPurchase()
    world:Call("CancelCommoditiesPurchase")
    world.quote = nil
  end
  function AH.ConfirmCommoditiesPurchase(id, quantity)
    world:RequireHardware("ConfirmCommoditiesPurchase")
    sentRequest()
    world:Call("ConfirmCommoditiesPurchase", id, quantity)
    local total = commodityQuote(id, quantity)
    if not total or total > world.money then
      world:FireLater(0.2, "COMMODITY_PURCHASE_FAILED")
      return
    end
    world.money = world.money - total
    local left = quantity
    for _, r in ipairs(sortedCommodity(id)) do
      local avail = r.quantity - (r.numOwnerItems or 0)
      local take = math.min(avail, left)
      r.quantity = r.quantity - take
      left = left - take
      if left == 0 then break end
    end
    local keep = {}
    for _, r in ipairs(world.commodities[id]) do if r.quantity > 0 then keep[#keep + 1] = r end end
    world.commodities[id] = keep
    world:FireLater(0.2, "COMMODITY_PURCHASE_SUCCEEDED")
  end
  function AH.PlaceBid(auctionID, amount)
    world:RequireHardware("PlaceBid") -- HasRestrictions in the Forever API docs
    sentRequest()
    world:Call("PlaceBid", auctionID, amount)
    for id, list in pairs(world.itemAuctions) do
      for i, a in ipairs(list) do
        if a.auctionID == auctionID then
          assert(amount == a.buyout, "PlaceBid amount mismatch")
          world.money = world.money - amount
          table.remove(list, i)
          if world.knownEvents.AUCTION_HOUSE_PURCHASE_COMPLETED then
            world:FireLater(0.2, "AUCTION_HOUSE_PURCHASE_COMPLETED", auctionID)
          end
          return
        end
      end
      local _ = id
    end
    world:FireLater(0.2, "AUCTION_HOUSE_SHOW_ERROR", 1)
  end
end

---------------------------------------------------------------------------
-- Loading the addon
---------------------------------------------------------------------------
function World:LoadAddon()
  local toc = assert(io.open(ADDON_DIR .. "/VendorDiff.toc")):read("*a")
  self.ns = {}
  for names in toc:gmatch("## SavedVariables[%w]*:%s*([^\r\n]+)") do
    for name in names:gmatch("[%w_]+") do self.declared[name] = true end
  end
  for line in toc:gmatch("[^\r\n]+") do
    if not line:match("^%s*#") and line:match("%.lua%s*$") then
      local path = ADDON_DIR .. "/" .. line:gsub("%s+$", "")
      local chunk = assert(loadfile(path))
      setfenv(chunk, self.env)
      chunk("VendorDiff", self.ns)
    end
  end
  self:Fire("ADDON_LOADED", "VendorDiff")
  return self.ns
end

function World:OpenAH()
  self:Fire("AUCTION_HOUSE_SHOW")
  self:Advance(0.05)
end

function World:CloseAH()
  self:Fire("AUCTION_HOUSE_CLOSED")
  self:Advance(0.05)
end

return Mock
