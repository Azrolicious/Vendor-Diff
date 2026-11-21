-- Auction House backend for WoW Forever, which uses the retail-style
-- C_AuctionHouse API (12.1.5 API set, client 1.60.1).
--
-- Restrictions (from Blizzard's generated API docs for the forever branch):
-- PlaceBid and StartCommoditiesPurchase require a hardware event, so both are
-- only ever called from a button click (see Buyer:OnClick).
--
-- Scanning uses a "summary" browse query rather than ReplicateItems: an empty
-- browse query returns every item on the Auction House with its lowest unit
-- buyout, in pages, and isn't limited to once per 15 minutes. GoldScout (MIT)
-- documents this approach for Forever, along with the Sell tab quirk below.
local _, ns = ...

local C_AuctionHouse = C_AuctionHouse
if not (C_AuctionHouse and C_AuctionHouse.SendBrowseQuery) then return end

local M = {
  name = "modern",
  firstIndex = 1,
  gearPriceByLink = false, -- browse results carry no link; the live search re-checks with real links
}
ns.backend = M

local SEARCH_TIMEOUT = 10
local PURCHASE_TIMEOUT = 5
local PAGE_TIMEOUT = 20
local MAX_RESULT_PAGES = 5

local SORT_PRICE = (Enum and Enum.AuctionHouseSortOrder and Enum.AuctionHouseSortOrder.Price) or 0
local SEARCH_SORTS = { { sortOrder = SORT_PRICE, reverseSort = false } }
local SUMMARY_QUERY = { searchString = "", sorts = {}, filters = {}, itemClassFilters = {} }

---------------------------------------------------------------------------
-- Blizzard's Sell tab re-checks its Post button whenever an Auction House
-- request goes out and errors while its item has no deposit yet, so we hold
-- requests while a Sell tab is visible.
---------------------------------------------------------------------------
local sellFrames

function M:SellTabOpen()
  local ah = AuctionHouseFrame
  if not ah then return false end
  if not sellFrames then
    sellFrames = {}
    for _, key in ipairs({ "ItemSellFrame", "CommoditiesSellFrame" }) do
      if type(ah[key]) == "table" then sellFrames[#sellFrames + 1] = ah[key] end
    end
    if #sellFrames == 0 and ah.GetChildren then
      for _, child in ipairs({ ah:GetChildren() }) do
        if type(child.CanPostItem) == "function" then sellFrames[#sellFrames + 1] = child end
      end
    end
  end
  for _, frame in ipairs(sellFrames) do
    if frame:IsVisible() then return true end
  end
  return false
end

---------------------------------------------------------------------------
-- Throttle: the AH only accepts a query when its message system is ready.
---------------------------------------------------------------------------
local queued
local queueTicker

local function RunQueued()
  if not queued then return end
  if not ns.ahOpen then
    queued = nil
  elseif M:SellTabOpen() then
    if not M.sellPauseSaid then
      M.sellPauseSaid = true
      local msg = "Paused while the Auction House Sell tab is open."
      if ns.Scan.running then
        ns.Scan.statusText = msg
        ns.Fire("SCAN_STATUS", msg)
      else
        ns.Buyer.message = msg
        ns.Fire("BUYER_CHANGED")
      end
    end
    return
  elseif not C_AuctionHouse.IsThrottledMessageSystemReady() then
    return
  end
  local fn = queued
  queued = nil
  M.sellPauseSaid = false
  if queueTicker then queueTicker:Cancel() queueTicker = nil end
  if fn then fn() end
end

local function WhenReady(fn)
  queued = fn
  RunQueued()
  if queued and not queueTicker then
    -- AUCTION_HOUSE_THROTTLED_SYSTEM_READY normally wakes us; poll as a fallback
    -- (and to notice when the Sell tab closes).
    queueTicker = C_Timer.NewTicker(0.25, RunQueued)
  end
end

ns.On("AUCTION_HOUSE_THROTTLED_SYSTEM_READY", RunQueued)

---------------------------------------------------------------------------
-- Summary scan (empty browse query, paged)
---------------------------------------------------------------------------
function M:CanFullScan()
  return true
end

-- cb(success, err) once every page has arrived; onProgress(pages, items) per page.
function M:RequestFullScan(cb, onProgress)
  self:CancelAll()
  local scan = { cb = cb, onProgress = onProgress, pages = 0, seen = 0 }
  self.summary = scan
  self.browse = {}
  self.partial = false
  self:RequestPage(scan, "first", function() C_AuctionHouse.SendBrowseQuery(SUMMARY_QUERY) end)
end

function M:RequestPage(scan, kind, send)
  WhenReady(function()
    if self.summary ~= scan then return end
    scan.waiting = kind
    if scan.timer then scan.timer:Cancel() end
    scan.timer = C_Timer.NewTimer(PAGE_TIMEOUT, function()
      if self.summary ~= scan then return end
      if #self.browse > 0 then
        -- Keep what arrived; the scan is just incomplete.
        self.partial = true
        self:CompleteFullScanRequest(true)
      else
        self:CompleteFullScanRequest(false, "the Auction House stopped responding; try again.")
      end
    end)
    send()
  end)
end

function M:CompleteFullScanRequest(success, err)
  local scan = self.summary
  if not scan then return end
  self.summary = nil
  if scan.timer then scan.timer:Cancel() end
  scan.cb(success, err)
end

-- Browse results are cumulative, so only a longer list means a new page.
local function OnBrowseResults()
  local scan = M.summary
  if not (scan and scan.waiting) then return end
  local all = C_AuctionHouse.GetBrowseResults() or {}
  if scan.waiting == "more" and #all <= scan.seen then return end
  scan.waiting = nil
  scan.seen = #all
  scan.pages = scan.pages + 1
  M.browse = all
  if scan.onProgress then scan.onProgress(scan.pages, #all) end
  if C_AuctionHouse.HasFullBrowseResults() then
    M:CompleteFullScanRequest(true)
  else
    M:RequestPage(scan, "more", function() C_AuctionHouse.RequestMoreBrowseResults() end)
  end
end

ns.On("AUCTION_HOUSE_BROWSE_RESULTS_UPDATED", OnBrowseResults)
ns.On("AUCTION_HOUSE_BROWSE_RESULTS_ADDED", OnBrowseResults)
ns.On("AUCTION_HOUSE_BROWSE_FAILURE", function()
  local scan = M.summary
  if scan and scan.waiting then
    M:CompleteFullScanRequest(false, "the Auction House refused the request; try again in a moment.")
  end
end)

-- Scan.lua reads the snapshot through these. Each entry is one item key with
-- its lowest unit price, so we report it as a single unit at that price.
function M:GetCount()
  return #self.browse
end

function M:ReadEntry(i)
  local r = self.browse[i]
  if not (r and r.itemKey) then return nil end
  return r.itemKey.itemID, 1, r.minPrice
end

function M:GetEntryLink()
  return nil
end

function M:DescribeEntry(i, itemID)
  local r = self.browse[i]
  local name, link, quality, _, _, _, _, _, _, texture = ns.GetItemInfo(itemID)
  if not name then return nil end
  local itemKey = r.itemKey
  local key = tostring(itemID)
  local itemLevel = (itemKey.itemLevel or 0) > 0 and itemKey.itemLevel or nil
  if itemLevel then key = key .. ":" .. itemLevel end
  if (itemKey.itemSuffix or 0) > 0 then key = key .. ":s" .. itemKey.itemSuffix end
  return key, {
    itemID = itemID,
    name = name,
    link = link,
    texture = texture,
    quality = quality,
    itemLevel = itemLevel,
    itemKey = itemKey,
    listed = r.totalQuantity,
    estimate = true,
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
  if self.summary and self.summary.timer then self.summary.timer:Cancel() end
  self.summary = nil
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
  -- The browse scan gives us the exact item key; otherwise build one.
  s.itemKey = cand.itemKey or C_AuctionHouse.MakeItemKey(cand.itemID, cand.itemLevel or 0, 0, 0)
  self.search = s
  self:SendSearch(s)
end

function M:SendSearch(s)
  WhenReady(function()
    if self.search ~= s then return end
    -- Start the timeout only once the query really goes out (it may have
    -- waited for the throttle or the Sell tab).
    if s.timer then s.timer:Cancel() end
    s.timer = C_Timer.NewTimer(SEARCH_TIMEOUT, function()
      if self.search == s then self:FinishSearch(s, nil, "the search timed out.") end
    end)
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
  if M.summary then M:CompleteFullScanRequest(false, "the Auction House was closed.") end
  M:CancelAll()
end)
