-- Remembers what Vendor Diff bought (per character) and sells exactly that
-- many to the next vendor you open. Items you get any other way are never
-- sold: a record only counts units that arrived in the bags while the
-- mailbox was open (where Auction House purchases are delivered), it never
-- sells more than that, and the record is removed as it is sold.
local _, ns = ...

local Ledger = {
  merchantOpen = false,
  selling = nil, -- the sell pass in progress
}
ns.Ledger = Ledger

local EXPIRE_DAYS = 30   -- auction mail is deleted after 30 days; drop stale records too
local SELL_DELAY = 0.3   -- let the vendor window finish opening first
local SETTLE_DELAY = 1.0 -- after the last sale, before counting what actually sold
local SPLIT_WAIT = 0.25  -- polling interval while a split stack lands
local SPLIT_TRIES = 12

local C_Container = C_Container

local function DB()
  return ns.charDB and ns.charDB.ledger or {}
end

local function LastBag()
  -- Backpack is 0; the equipped bags follow (plus a reagent bag on clients that have one).
  return rawget(_G, "NUM_TOTAL_EQUIPPED_BAG_SLOTS") or rawget(_G, "NUM_BAG_SLOTS") or 4
end

-- Calls fn(bag, slot, info) for every occupied bag slot; stops if fn returns true.
local function ForEachBagItem(fn)
  for bag = 0, LastBag() do
    for slot = 1, C_Container.GetContainerNumSlots(bag) or 0 do
      local info = C_Container.GetContainerItemInfo(bag, slot)
      if info and info.itemID and fn(bag, slot, info) then return end
    end
  end
end

-- An empty slot in an ordinary bag (not a herb/mining/etc. bag).
local function FindFreeSlot()
  for bag = 0, LastBag() do
    local free, family = C_Container.GetContainerNumFreeSlots(bag)
    if free and free > 0 and (family == nil or family == 0) then
      for slot = 1, C_Container.GetContainerNumSlots(bag) or 0 do
        if not C_Container.GetContainerItemInfo(bag, slot) then return bag, slot end
      end
    end
  end
end

---------------------------------------------------------------------------
-- Records
---------------------------------------------------------------------------
-- Gear is tracked by item level too, so selling a bought item-level-30 sword
-- never sells the item-level-25 one you looted.
local function GearLevel(itemID, link)
  if link and ns.IsGear(itemID) then
    return ns.GetDetailedItemLevelInfo(link)
  end
end

local function KeyFor(itemID, itemLevel)
  return itemLevel and (itemID .. ":" .. itemLevel) or tostring(itemID)
end

function Ledger:Add(itemID, link, name, quantity, cost, vendor)
  if not (itemID and quantity and quantity > 0) then return end
  local itemLevel = GearLevel(itemID, link)
  local key = KeyFor(itemID, itemLevel)
  local db = DB()
  local e = db[key]
  if not e then
    e = { itemID = itemID, itemLevel = itemLevel, link = link, name = name, count = 0, cost = 0, vendor = 0 }
    db[key] = e
  end
  e.count = e.count + quantity
  e.arrived = e.arrived or 0 -- units taken from the mailbox so far
  e.cost = e.cost + (cost or 0)
  e.vendor = e.vendor + (vendor or 0)
  e.boughtAt = time()
  ns.Fire("LEDGER_CHANGED")
end

-- Which record (if any) a bag item belongs to.
function Ledger:Match(info)
  local db = DB()
  local key = tostring(info.itemID)
  if db[key] then return key, db[key] end
  local level = GearLevel(info.itemID, info.hyperlink)
  if level then
    key = KeyFor(info.itemID, level)
    if db[key] then return key, db[key] end
  end
end

function Ledger:ForgetItem(itemID)
  local n = 0
  for key, e in pairs(DB()) do
    if e.itemID == itemID then
      DB()[key] = nil
      n = n + 1
    end
  end
  if n > 0 then ns.Fire("LEDGER_CHANGED") end
  return n
end

function Ledger:Clear()
  wipe(DB())
  ns.Fire("LEDGER_CHANGED")
end

function Ledger:Expire()
  local cutoff = time() - EXPIRE_DAYS * 86400
  for key, e in pairs(DB()) do
    if (e.boughtAt or 0) < cutoff then
      ns.Print(("Stopped tracking %dx %s: bought more than %d days ago."):format(
        e.count, e.link or e.name or ("item " .. e.itemID), EXPIRE_DAYS))
      DB()[key] = nil
    end
  end
end

-- How many units of each record are in the bags right now.
function Ledger:CountInBags()
  local counts = {}
  if not next(DB()) then return counts end
  ForEachBagItem(function(_, _, info)
    local key = self:Match(info)
    if key then counts[key] = (counts[key] or 0) + (info.stackCount or 1) end
  end)
  return counts
end

-- Units of a record that can be sold now: bought, collected from the
-- mailbox, and still in the bags.
local function Sellable(e, inBags)
  return math.min(e.count, e.arrived or 0, inBags or 0)
end

function Ledger:SellableCount()
  local inBags, total = self:CountInBags(), 0
  for key, e in pairs(DB()) do
    total = total + Sellable(e, inBags[key])
  end
  return total
end

---------------------------------------------------------------------------
-- Mailbox: count what arrives in the bags while it's open
---------------------------------------------------------------------------
function Ledger:MailOpened()
  if self.mailBaseline then return end
  self.mailBaseline = self:CountInBags()
end

-- Called on every bag update while the mailbox is open, and when it closes.
-- Increases are deliveries; decreases (e.g. attaching items to a letter)
-- just move the baseline.
function Ledger:UpdateArrivals()
  local baseline = self.mailBaseline
  if not baseline then return end
  local now = self:CountInBags()
  local changed = false
  for key, e in pairs(DB()) do
    local gained = (now[key] or 0) - (baseline[key] or 0)
    if gained > 0 and (e.arrived or 0) < e.count then
      e.arrived = math.min(e.count, (e.arrived or 0) + gained)
      changed = true
    end
  end
  self.mailBaseline = now
  if changed then ns.Fire("LEDGER_CHANGED") end
end

function Ledger:MailClosed()
  if not self.mailBaseline then return end
  self:UpdateArrivals()
  self.mailBaseline = nil
end

local function Ago(t)
  local days = math.floor((time() - (t or time())) / 86400)
  if days <= 0 then return "today" end
  return days == 1 and "1 day ago" or (days .. " days ago")
end

function Ledger:PrintPending()
  local list = {}
  for _, e in pairs(DB()) do list[#list + 1] = e end
  if #list == 0 then
    ns.Print("Nothing bought through Vendor Diff is waiting to be sold.")
    return
  end
  table.sort(list, function(a, b) return (a.boughtAt or 0) < (b.boughtAt or 0) end)
  local inBags = self:CountInBags()
  ns.Print("Waiting to be sold to a vendor:")
  for _, e in ipairs(list) do
    local ready = Sellable(e, inBags[KeyFor(e.itemID, e.itemLevel)])
    local inMail = e.count - (e.arrived or 0)
    ns.Print(("  %dx %s, bought %s for %s, vendors for %s (%d ready to sell%s)"):format(
      e.count, e.link or e.name or ("item " .. e.itemID), Ago(e.boughtAt),
      ns.FormatMoney(e.cost), ns.FormatMoney(e.vendor), ready,
      inMail > 0 and (", %d still in the mailbox"):format(inMail) or ""))
  end
end

---------------------------------------------------------------------------
-- Selling
---------------------------------------------------------------------------
-- UseContainerItem sells only while a vendor is open; with the mailbox,
-- bank, trade or Auction House open it would attach, deposit or use the
-- item instead, so all of those must be closed.
local BLOCKING_FRAMES = { "MailFrame", "SendMailFrame", "BankFrame", "TradeFrame", "AuctionHouseFrame" }

function Ledger:CanSellNow()
  if not self.merchantOpen then return false, "Open a vendor first." end
  local merchant = rawget(_G, "MerchantFrame")
  if not (merchant and merchant:IsShown()) then return false, "Open a vendor first." end
  for _, name in ipairs(BLOCKING_FRAMES) do
    local f = rawget(_G, name) -- not every client has every one of these
    if f and f.IsShown and f:IsShown() then
      return false, "Close the other windows (mail, bank, trade, Auction House) first."
    end
  end
  return true
end

-- reason: "auto" (vendor opened), "button" or "command".
function Ledger:SellPending(reason)
  if self.selling then return end
  if not next(DB()) then
    if reason ~= "auto" then ns.Print("Nothing bought through Vendor Diff is waiting to be sold.") end
    return
  end
  local ok, why = self:CanSellNow()
  if not ok then
    if reason ~= "auto" then ns.Print(why) end
    return
  end

  local before = self:CountInBags()
  local want, any = {}, false
  for key, e in pairs(DB()) do
    want[key] = Sellable(e, before[key])
    if want[key] > 0 then any = true end
  end
  if not any then
    if reason ~= "auto" then
      ns.Print("Nothing Vendor Diff bought has been collected from the mailbox yet.")
    end
    return
  end

  local pass = {
    before = before,
    intended = {},
    splits = {},
    blocked = false,
    noSpace = 0,
  }
  for key, n in pairs(want) do pass.intended[key] = n end
  self.selling = pass

  -- Smallest stacks first, so a mixed stack (bought + your own) is only
  -- split when the plain stacks don't cover the bought amount.
  local stacks = {}
  ForEachBagItem(function(bag, slot, info)
    local key = self:Match(info)
    if key and want[key] > 0 and not info.isLocked and not info.hasNoValue then
      stacks[#stacks + 1] = { bag = bag, slot = slot, key = key, count = info.stackCount or 1, itemID = info.itemID }
    end
  end)
  table.sort(stacks, function(a, b) return a.count < b.count end)

  for _, s in ipairs(stacks) do
    local need = want[s.key]
    if need > 0 then
      if s.count <= need then
        C_Container.UseContainerItem(s.bag, s.slot)
        if pass.blocked then break end
        want[s.key] = need - s.count
      else
        pass.splits[#pass.splits + 1] = { bag = s.bag, slot = s.slot, amount = need, itemID = s.itemID }
        want[s.key] = 0
      end
    end
  end

  if pass.blocked then
    pass.splits = {}
  end
  self:NextSplit(pass)
end

-- Split `amount` off a mixed stack into an empty slot, then sell that.
function Ledger:NextSplit(pass)
  if self.selling ~= pass then return end
  local job = table.remove(pass.splits, 1)
  if not job then
    C_Timer.After(SETTLE_DELAY, function() self:FinishPass(pass) end)
    return
  end
  if not self:CanSellNow() then
    pass.splits = {}
    C_Timer.After(SETTLE_DELAY, function() self:FinishPass(pass) end)
    return
  end
  local source = C_Container.GetContainerItemInfo(job.bag, job.slot)
  local freeBag, freeSlot = FindFreeSlot()
  if not (source and source.itemID == job.itemID and not source.isLocked and source.stackCount > job.amount) then
    return self:NextSplit(pass) -- the stack changed; skip it
  end
  if not freeBag then
    pass.noSpace = pass.noSpace + job.amount
    return self:NextSplit(pass)
  end

  C_Container.SplitContainerItem(job.bag, job.slot, job.amount)
  C_Container.PickupContainerItem(freeBag, freeSlot)
  if CursorHasItem and CursorHasItem() then
    ClearCursor() -- couldn't place it; put it back
    pass.noSpace = pass.noSpace + job.amount
    return self:NextSplit(pass)
  end

  local tries = 0
  local function SellSplit()
    if self.selling ~= pass then return end
    local placed = C_Container.GetContainerItemInfo(freeBag, freeSlot)
    if placed and placed.itemID == job.itemID and not placed.isLocked then
      if placed.stackCount == job.amount and self:CanSellNow() then
        C_Container.UseContainerItem(freeBag, freeSlot)
      end
      return self:NextSplit(pass)
    end
    tries = tries + 1
    if tries >= SPLIT_TRIES then return self:NextSplit(pass) end
    C_Timer.After(SPLIT_WAIT, SellSplit)
  end
  C_Timer.After(SPLIT_WAIT, SellSplit)
end

-- Count what actually left the bags and update the records from that, so a
-- blocked or failed sale never removes anything from the ledger.
function Ledger:FinishPass(pass)
  if self.selling ~= pass then return end
  self.selling = nil
  local after = self:CountInBags()
  local db = DB()
  local soldUnits, revenue, paid = 0, 0, 0
  for key, intended in pairs(pass.intended) do
    local e = db[key]
    local sold = math.max(0, math.min(intended, (pass.before[key] or 0) - (after[key] or 0)))
    if e and sold > 0 then
      local share = sold / e.count
      local cost, vendor = e.cost * share, e.vendor * share
      ns.Print(("Sold %dx %s for %s (paid %s, profit %s)."):format(
        sold, e.link or e.name or ("item " .. e.itemID), ns.FormatMoney(vendor),
        ns.FormatMoney(cost), ns.FormatMoney(vendor - cost)))
      soldUnits, revenue, paid = soldUnits + sold, revenue + vendor, paid + cost
      e.count = e.count - sold
      e.arrived = math.max(0, (e.arrived or 0) - sold)
      e.cost = e.cost - cost
      e.vendor = e.vendor - vendor
      if e.count <= 0 then db[key] = nil end
    end
  end
  if soldUnits > 0 then
    local s = ns.Buyer.session
    s.soldUnits = (s.soldUnits or 0) + soldUnits
    s.soldFor = (s.soldFor or 0) + revenue
    s.soldCost = (s.soldCost or 0) + paid
  end
  if pass.noSpace > 0 then
    ns.Print(("Couldn't sell %d more: they're stacked with items you didn't buy, and splitting the stack "
      .. "needs a free bag slot. Free one up and use /vd sell."):format(pass.noSpace))
  end
  if pass.blocked then
    self.autoBlocked = true
    ns.Print("The game blocked automatic selling. Click the \"Sell Vendor Diff items\" button under the vendor window.")
  end
  ns.Fire("LEDGER_CHANGED")
end

---------------------------------------------------------------------------
-- Sell button under the vendor window (when auto-sell is off or blocked)
---------------------------------------------------------------------------
function Ledger:UpdateButton()
  local merchant = rawget(_G, "MerchantFrame")
  if not merchant then return end
  if not self.button then
    local b = CreateFrame("Button", "VendorDiffSellButton", merchant, "UIPanelButtonTemplate")
    b:SetSize(190, 22)
    b:SetPoint("TOPRIGHT", merchant, "BOTTOMRIGHT", 0, -2)
    b:SetScript("OnClick", function() Ledger:SellPending("button") end)
    self.button = b
  end
  local count = self.merchantOpen and self:SellableCount() or 0
  if count > 0 and (not ns.db.autoSell or self.autoBlocked) then
    self.button:SetText(("Sell Vendor Diff items (%d)"):format(count))
    self.button:Show()
  else
    self.button:Hide()
  end
end

---------------------------------------------------------------------------
-- Events
---------------------------------------------------------------------------
local function MerchantOpened()
  if Ledger.merchantOpen then return end
  Ledger.merchantOpen = true
  C_Timer.After(SELL_DELAY, function()
    if not Ledger.merchantOpen then return end
    if ns.db.autoSell and not Ledger.autoBlocked then
      Ledger:SellPending("auto")
    end
    Ledger:UpdateButton()
  end)
end

local function MerchantClosed()
  if not Ledger.merchantOpen then return end
  Ledger.merchantOpen = false
  if Ledger.button then Ledger.button:Hide() end
end

ns.On("MERCHANT_SHOW", MerchantOpened)
ns.On("MERCHANT_CLOSED", MerchantClosed)

local function IsMerchant(kind)
  local types = Enum and Enum.PlayerInteractionType
  return types ~= nil and types.Merchant ~= nil and kind == types.Merchant
end
local function IsMailbox(kind)
  local types = Enum and Enum.PlayerInteractionType
  return types ~= nil and types.MailInfo ~= nil and kind == types.MailInfo
end

ns.On("PLAYER_INTERACTION_MANAGER_FRAME_SHOW", function(_, kind)
  if IsMerchant(kind) then
    MerchantOpened()
  elseif IsMailbox(kind) then
    Ledger:MailOpened()
  end
end)
ns.On("PLAYER_INTERACTION_MANAGER_FRAME_HIDE", function(_, kind)
  if IsMerchant(kind) then
    MerchantClosed()
  elseif IsMailbox(kind) then
    Ledger:MailClosed()
  end
end)

ns.On("MAIL_SHOW", function() Ledger:MailOpened() end)
ns.On("MAIL_CLOSED", function() Ledger:MailClosed() end)
ns.On("BAG_UPDATE_DELAYED", function() Ledger:UpdateArrivals() end)

-- A sale the client refuses fires this synchronously inside UseContainerItem.
ns.On("ADDON_ACTION_BLOCKED", function()
  if Ledger.selling then Ledger.selling.blocked = true end
end)

ns.Listen("LEDGER_CHANGED", function()
  if Ledger.merchantOpen then Ledger:UpdateButton() end
end)

ns.Listen("DB_READY", function()
  Ledger:Expire()
end)
