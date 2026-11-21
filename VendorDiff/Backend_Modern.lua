-- Auction House backend for WoW Forever, which uses the retail-style
-- C_AuctionHouse API (12.1.5 API set, client 1.60.1).
--
-- Restrictions (from Blizzard's generated API docs for the forever branch):
-- PlaceBid and StartCommoditiesPurchase require a hardware event, so both are
-- only ever called from a button click (see Buyer:OnClick).
local _, ns = ...

local C_AuctionHouse = C_AuctionHouse
if not (C_AuctionHouse and C_AuctionHouse.ReplicateItems) then return end

local M = {
  name = "modern",
  firstIndex = 0,          -- replicate indices are 0-based
  gearPriceByLink = true,  -- read gear sell prices from the exact item link
}
ns.backend = M

local SEARCH_TIMEOUT = 10
local PURCHASE_TIMEOUT = 5
local FULL_SCAN_TIMEOUT = 180 -- Forever mega-realms can have very large auction houses
local MAX_RESULT_PAGES = 5

local SORT_PRICE = (Enum and Enum.AuctionHouseSortOrder and Enum.AuctionHouseSortOrder.Price) or 0
local SEARCH_SORTS = { { sortOrder = SORT_PRICE, reverseSort = false } }

---------------------------------------------------------------------------
-- Throttle: the AH only accepts a query when its message system is ready.
---------------------------------------------------------------------------
local queued
local queueTicker

local function RunQueued()
  if queued and C_AuctionHouse.IsThrottledMessageSystemReady() then
    local fn = queued
    queued = nil
    if queueTicker then queueTicker:Cancel() queueTicker = nil end
    fn()
  end
end

local function WhenReady(fn)
  queued = fn
  if C_AuctionHouse.IsThrottledMessageSystemReady() then
    RunQueued()
  elseif not queueTicker then
    -- AUCTION_HOUSE_THROTTLED_SYSTEM_READY normally wakes us; poll as a fallback.
    queueTicker = C_Timer.NewTicker(0.25, RunQueued)
  end
end

ns.On("AUCTION_HOUSE_THROTTLED_SYSTEM_READY", RunQueued)

---------------------------------------------------------------------------
-- Full scan (ReplicateItems)
---------------------------------------------------------------------------
function M:CanFullScan(force)
  local wait = ns.SecondsUntilFullScan()
  if wait > 0 and not force then
    return false, ("Full scans are limited to one every 15 minutes. Next scan in %d:%02d (shift-click Scan to try anyway).")
      :format(math.floor(wait / 60), wait % 60)
  end
  return true
end

function M:RequestFullScan(cb)
  self.scanCallback = cb
  self.lastReplicateEvent = nil
  if self.scanTimer then self.scanTimer:Cancel() end
  self.scanTimer = C_Timer.NewTimer(FULL_SCAN_TIMEOUT, function()
    self:CompleteFullScanRequest(false,
      "no data from the server. Full scans are limited to one every 15 minutes; try again later.")
  end)
  C_AuctionHouse.ReplicateItems()
end

function M:CompleteFullScanRequest(success, err)
  local cb = self.scanCallback
  self.scanCallback = nil
  if self.scanTimer then self.scanTimer:Cancel() self.scanTimer = nil end
  if cb then cb(success, err) end
end

-- The list can arrive in several updates; wait until it has been quiet briefly.
local function CheckReplicateSettled()
  if not M.scanCallback then return end
  if GetTime() - (M.lastReplicateEvent or 0) >= 0.5 then
    M:CompleteFullScanRequest(true)
  else
    C_Timer.After(0.25, CheckReplicateSettled)
  end
end

ns.On("REPLICATE_ITEM_LIST_UPDATE", function()
  if not M.scanCallback then return end
  local first = M.lastReplicateEvent == nil
  M.lastReplicateEvent = GetTime()
  if first then C_Timer.After(0.5, CheckReplicateSettled) end
end)

function M:GetCount()
  return C_AuctionHouse.GetNumReplicateItems() or 0
end

function M:ReadEntry(i)
  local _, _, count, _, _, _, _, _, _, buyout, _, _, _, _, _, _, itemID = C_AuctionHouse.GetReplicateItemInfo(i)
  return itemID, count, buyout
end

function M:GetEntryLink(i)
  return C_AuctionHouse.GetReplicateItemLink(i)
end

function M:DescribeEntry(i, itemID, isGear, link)
  local name, texture, _, quality, _, _, _, _, _, _, _, _, _, owner = C_AuctionHouse.GetReplicateItemInfo(i)
  if not name or name == "" then return nil end
  if owner and owner ~= "" and owner == UnitName("player") then return false end
  link = link or C_AuctionHouse.GetReplicateItemLink(i)

  local key, itemLevel = tostring(itemID), nil
  if isGear and link then
    -- Gear with different item levels has different item keys on the AH.
    itemLevel = ns.GetDetailedItemLevelInfo(link)
    if itemLevel then key = itemID .. ":" .. itemLevel end
  end
  return key, {
    itemID = itemID,
    name = name,
    link = link,
    texture = texture,
    quality = quality,
    itemLevel = itemLevel,
  }
end

function M:IsScanDataValid()
  return ns.ahOpen
end

---------------------------------------------------------------------------
-- Live search for one candidate
---------------------------------------------------------------------------
function M:CancelAll()
  if self.search and self.search.timer then self.search.timer:Cancel() end
  self.search = nil
  if self.purchase then
    if self.purchase.timer then self.purchase.timer:Cancel() end
    if self.purchase.kind == "commodity" and C_AuctionHouse.CancelCommoditiesPurchase then
      C_AuctionHouse.CancelCommoditiesPurchase()
    end
  end
  self.purchase = nil
  queued = nil
end

function M:Search(cand, cb)
  self:CancelAll()
  local s = {
    cand = cand,
    cb = cb,
    itemID = cand.itemID,
    pages = 0,
    reads = 0,
  }
  s.itemKey = C_AuctionHouse.MakeItemKey(cand.itemID, cand.itemLevel or 0, 0, 0)
  self.search = s
  self:SendSearch(s)
end

function M:SendSearch(s)
  if s.timer then s.timer:Cancel() end
  s.timer = C_Timer.NewTimer(SEARCH_TIMEOUT, function()
    if self.search == s then self:FinishSearch(s, nil, "the search timed out.") end
  end)
  WhenReady(function()
    if self.search ~= s then return end
    C_AuctionHouse.SendSearchQuery(s.itemKey, SEARCH_SORTS, true)
  end)
end

function M:FinishSearch(s, offers, err, liveListings)
  if self.search ~= s then return end
  if s.timer then s.timer:Cancel() end
  self.search = nil
  s.cb(offers, err, liveListings)
end

-- Commodities (stackable trade goods etc.) are bought cheapest-first by
-- quantity, so we build one offer covering every unit below vendor price.
function M:OnCommodityResults(itemID)
  local s = self.search
  if not s or s.itemID ~= itemID then return end

  local unitVendor = ns.GetVendorPrice(itemID)
  if not unitVendor then
    ns.RequestItemData(itemID)
    if s.reads < 5 then
      s.reads = s.reads + 1
      C_Timer.After(0.5, function() self:OnCommodityResults(itemID) end)
    else
      self:FinishSearch(s, nil, "item data not available.")
    end
    return
  end

  local levels, quantity, cost = {}, 0, 0
  local reachedVendorPrice = false
  local n = C_AuctionHouse.GetNumCommoditySearchResults(itemID) or 0
  for i = 1, n do
    local r = C_AuctionHouse.GetCommoditySearchResultInfo(itemID, i)
    if r then
      if r.unitPrice >= unitVendor then
        reachedVendorPrice = true
        break
      end
      local available = r.quantity - (r.numOwnerItems or 0)
      if available > 0 then
        levels[#levels + 1] = { unitPrice = r.unitPrice, quantity = available }
        quantity = quantity + available
        cost = cost + available * r.unitPrice
      end
    end
  end

  if not reachedVendorPrice and n > 0 and s.pages < MAX_RESULT_PAGES
     and not C_AuctionHouse.HasFullCommoditySearchResults(itemID) then
    s.pages = s.pages + 1
    C_AuctionHouse.RequestMoreCommoditySearchResults(itemID)
    return -- COMMODITY_SEARCH_RESULTS_ADDED brings us back here
  end

  local offers, live = {}, {}
  if quantity > 0 then
    offers[1] = {
      kind = "commodity",
      itemID = itemID,
      quantity = quantity,
      cost = cost,
      vendor = quantity * unitVendor,
      unitVendor = unitVendor,
      levels = levels,
    }
    live[1] = { count = quantity, cost = cost, vendor = quantity * unitVendor }
  end
  self:FinishSearch(s, offers, nil, live)
end

local function SameItem(itemKey, itemID)
  return type(itemKey) == "table" and itemKey.itemID == itemID
end

-- Non-commodity items (gear, most uniques) are bought one auction at a time.
function M:OnItemResults(itemKey)
  local s = self.search
  if not s or not SameItem(itemKey, s.itemID) then return end

  local n = C_AuctionHouse.GetNumItemSearchResults(itemKey) or 0
  if n == 0 and (s.itemKey.itemLevel or 0) ~= 0 and not s.triedAnyLevel then
    -- No match for that exact item level; retry with a generic key.
    s.triedAnyLevel = true
    s.itemKey = C_AuctionHouse.MakeItemKey(s.itemID)
    self:SendSearch(s)
    return
  end

  local offers, live = {}, {}
  local missingData, lastWasDeal = false, false
  for i = 1, n do
    local r = C_AuctionHouse.GetItemSearchResultInfo(itemKey, i)
    lastWasDeal = false
    if r and r.buyoutAmount and r.buyoutAmount > 0
       and not r.containsOwnerItem and not r.containsAccountItem then
      local quantity = r.quantity or 1
      local unitVendor = ns.GetVendorPrice(r.itemLink or s.itemID)
      if unitVendor == nil then
        missingData = true
      else
        local vendor = unitVendor * quantity
        if r.buyoutAmount < vendor then
          lastWasDeal = true
          offers[#offers + 1] = {
            kind = "item",
            itemID = s.itemID,
            auctionID = r.auctionID,
            quantity = quantity,
            cost = r.buyoutAmount,
            vendor = vendor,
            link = r.itemLink,
          }
          live[#live + 1] = { count = quantity, cost = r.buyoutAmount, vendor = vendor }
        end
      end
    end
  end

  if missingData and s.reads < 5 then
    s.reads = s.reads + 1
    C_Timer.After(0.5, function() self:OnItemResults(itemKey) end)
    return
  end

  -- Results are sorted by price, so if the last one was still a deal there may be more.
  if lastWasDeal and s.pages < MAX_RESULT_PAGES and not C_AuctionHouse.HasFullItemSearchResults(itemKey) then
    s.pages = s.pages + 1
    C_AuctionHouse.RequestMoreItemSearchResults(itemKey)
    return -- ITEM_SEARCH_RESULTS_ADDED brings us back here
  end

  table.sort(offers, function(a, b) return (a.vendor - a.cost) > (b.vendor - b.cost) end)
  self:FinishSearch(s, offers, nil, live)
end

ns.On("COMMODITY_SEARCH_RESULTS_UPDATED", function(_, itemID) M:OnCommodityResults(itemID) end)
ns.On("COMMODITY_SEARCH_RESULTS_ADDED", function(_, itemID) M:OnCommodityResults(itemID) end)
ns.On("ITEM_SEARCH_RESULTS_UPDATED", function(_, itemKey) M:OnItemResults(itemKey) end)
ns.On("ITEM_SEARCH_RESULTS_ADDED", function(_, itemKey) M:OnItemResults(itemKey) end)

---------------------------------------------------------------------------
-- Purchasing. Buy / ConfirmCommodity must run inside a hardware event (click).
-- A purchase object carries onDone(ok, err); commodity quotes also onQuote.
---------------------------------------------------------------------------
function M:FinishPurchase(p, ok, err)
  if self.purchase ~= p then return end
  if p.timer then p.timer:Cancel() end
  self.purchase = nil
  p.onDone(ok, err)
end

-- When the timer runs out we report (timeoutOk, timeoutErr). For a purchase
-- that means "no confirmation arrived; the follow-up search shows what happened".
local function NewPurchase(p, timeout, timeoutOk, timeoutErr)
  M.purchase = p
  p.timer = C_Timer.NewTimer(timeout, function() M:FinishPurchase(p, timeoutOk, timeoutErr) end)
  return p
end

function M:Buy(offer, onDone)
  NewPurchase({ kind = "item", auctionID = offer.auctionID, onDone = onDone }, PURCHASE_TIMEOUT, true)
  C_AuctionHouse.PlaceBid(offer.auctionID, offer.cost)
end

-- Ask the server for the exact total price of `quantity` units.
-- onQuote(totalPrice, unitPrice) on success; onDone(false, err) if it fails.
function M:QuoteCommodity(offer, quantity, onQuote, onDone)
  NewPurchase({
    kind = "commodity",
    itemID = offer.itemID,
    quantity = quantity,
    quoting = true,
    onQuote = onQuote,
    onDone = onDone,
  }, SEARCH_TIMEOUT, false, "no price quote from the server.")
  C_AuctionHouse.StartCommoditiesPurchase(offer.itemID, quantity)
end

function M:ConfirmCommodity(quote, onDone)
  local p = self.purchase
  if not p or p.kind ~= "commodity" or p.quoting or p.itemID ~= quote.itemID then
    onDone(false, "the price quote expired.")
    return
  end
  p.onDone = onDone
  p.confirming = true
  if p.timer then p.timer:Cancel() end
  p.timer = C_Timer.NewTimer(PURCHASE_TIMEOUT, function() self:FinishPurchase(p, true) end)
  C_AuctionHouse.ConfirmCommoditiesPurchase(quote.itemID, quote.quantity)
end

ns.On("COMMODITY_PRICE_UPDATED", function(_, unitPrice, totalPrice)
  local p = M.purchase
  if not (p and p.kind == "commodity" and p.quoting) then return end
  p.quoting = false
  if p.timer then p.timer:Cancel() end
  -- Hold the quote until the user confirms; the server drops it eventually.
  p.timer = C_Timer.NewTimer(60, function() M:FinishPurchase(p, false, "the price quote expired.") end)
  p.onQuote(totalPrice, unitPrice)
end)

ns.On("COMMODITY_PRICE_UNAVAILABLE", function()
  local p = M.purchase
  if p and p.kind == "commodity" then
    M:FinishPurchase(p, false, "the price is no longer available.")
  end
end)

ns.On("COMMODITY_PURCHASE_SUCCEEDED", function()
  local p = M.purchase
  if p and p.kind == "commodity" and p.confirming then M:FinishPurchase(p, true) end
end)

ns.On("COMMODITY_PURCHASE_FAILED", function()
  local p = M.purchase
  if p and p.kind == "commodity" then M:FinishPurchase(p, false, "the purchase failed.") end
end)

ns.On("AUCTION_HOUSE_PURCHASE_COMPLETED", function(_, auctionID)
  local p = M.purchase
  if p and p.kind == "item" and (auctionID == nil or auctionID == p.auctionID) then
    M:FinishPurchase(p, true)
  end
end)

ns.On("AUCTION_HOUSE_SHOW_ERROR", function()
  local p = M.purchase
  if p and p.kind == "item" then M:FinishPurchase(p, false, "the Auction House reported an error.") end
end)

ns.Listen("AH_CLOSED", function()
  if M.scanCallback then M:CompleteFullScanRequest(false, "the Auction House was closed.") end
  M:CancelAll()
end)
