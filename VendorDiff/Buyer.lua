-- Purchase flow: pick a candidate -> live search -> Buy (-> Confirm for
-- commodities) -> re-search -> ... -> next candidate.
--
-- Every actual purchase call happens inside Buyer:OnClick(), which the UI
-- only calls from a button click (Blizzard requires a hardware event).
local _, ns = ...

local Buyer = {
  state = "IDLE",   -- IDLE | SEARCHING | READY | QUOTING | CONFIRM | BUYING | FAILED
  token = 0,        -- bumps whenever we start something new; stale callbacks compare against it
  target = nil,     -- candidate from ns.Results
  offers = nil,     -- live offers for the target, best first
  quote = nil,      -- commodity price quote awaiting confirmation
  message = nil,    -- status line shown in the UI
  chain = 0,        -- automatic advances since the last click
  session = { purchases = 0, spent = 0, value = 0 },
}
ns.Buyer = Buyer

-- Stop auto-advancing after this many sold-out candidates in a row so we
-- don't burn through the whole list without the player watching.
local MAX_AUTO_ADVANCE = 25

local function Changed()
  ns.Fire("BUYER_CHANGED")
end

local function ItemText(cand)
  if not cand then return "?" end
  local name = cand.name or ("item:" .. tostring(cand.itemID))
  if cand.itemLevel then name = name .. " (" .. cand.itemLevel .. ")" end
  return ns.QualityColor(cand.quality) .. name .. "|r"
end
Buyer.ItemText = ItemText

function Buyer:CanAct()
  if not ns.backend then return false, "This client's Auction House isn't supported." end
  if not ns.ahOpen then return false, "Open the Auction House to buy." end
  if ns.Scan.running then return false, "Wait for the scan to finish." end
  if ns.backend:SellTabOpen() then
    -- Blizzard's Sell tab errors if Auction House requests go out while it's open.
    return false, "Leave the Auction House Sell tab first."
  end
  return true
end

-- If money left our bags since the last purchase attempt, record it.
function Buyer:SettlePurchase()
  local p = self.pendingBuy
  if not p then return end
  self.pendingBuy = nil
  local spent = p.moneyBefore - GetMoney()
  if spent <= 0 then return end
  local s = self.session
  s.purchases = s.purchases + 1
  s.spent = s.spent + spent
  s.value = s.value + p.vendor
  ns.Print(("Bought %dx %s for %s (vendors for %s, profit %s)."):format(
    p.quantity, p.link or ItemText(p.cand), ns.FormatMoney(spent),
    ns.FormatMoney(p.vendor), ns.FormatMoney(p.vendor - spent)))
end

function Buyer:Reset(message)
  self:SettlePurchase()
  self.token = self.token + 1
  if ns.backend then ns.backend:CancelAll() end
  self.state = "IDLE"
  self.target = nil
  self.offers = nil
  self.quote = nil
  self.message = message
  Changed()
end

function Buyer:GetTargetKey()
  return self.target and self.target.key
end

-- The user clicked a row.
function Buyer:Select(key)
  self.chain = 0
  self:SetTarget(key)
end

function Buyer:SetTarget(key, note)
  local cand = key and ns.Results:Get(key)
  self:Reset(note)
  if not cand then return end
  self.target = cand
  self.targetIndex = ns.Results:IndexOf(key) or 1
  local ok, why = self:CanAct()
  if not ok then
    self.message = why
    Changed()
    return
  end
  self:Search(note)
end

function Buyer:Search(note)
  local cand = self.target
  if not cand then return end
  self.token = self.token + 1
  local token = self.token
  self.state = "SEARCHING"
  self.offers = nil
  self.quote = nil
  self.note = note -- why we're searching (skip, failed buy...); kept in the next status line
  self.message = (note and (note .. " ") or "") .. "Checking live listings for " .. ItemText(cand) .. "..."
  Changed()
  ns.backend:Search(cand, function(offers, err, live)
    if token ~= self.token then return end
    self:OnSearchResult(cand, offers, err, live)
  end)
end

function Buyer:OnSearchResult(cand, offers, err, live)
  self:SettlePurchase()
  if not offers then
    self.state = "FAILED"
    self.message = "Search failed: " .. (err or "unknown error")
    Changed()
    return
  end
  if live then
    ns.Results:SetLiveListings(cand.key, live)
  end

  local minProfit = ns.db.minProfit
  local good = {}
  for _, o in ipairs(offers) do
    if o.vendor - o.cost >= minProfit then good[#good + 1] = o end
  end
  if #good == 0 then
    self:Advance(cand, "Nothing below vendor price left for " .. ItemText(cand) .. ".")
    return
  end

  self.offers = good
  self.state = "READY"
  local o = good[1]
  local remaining = #good > 1 and (" (%d listings)"):format(#good) or ""
  self.message = (self.note and (self.note .. " ") or "") .. ("Next: %dx %s for %s, vendors for %s, profit %s%s."):format(
    o.quantity, ItemText(cand), ns.FormatMoney(o.cost), ns.FormatMoney(o.vendor),
    ns.FormatMoney(o.vendor - o.cost), remaining)
  Changed()
end

-- Drop `cand` and move on to whatever now sits at its position in the list.
function Buyer:Advance(cand, message)
  local index = self.targetIndex or ns.Results:IndexOf(cand.key) or 1
  self.chain = self.chain + 1
  self.target = nil -- so the RESULTS_CHANGED listener doesn't reset us mid-advance
  ns.Results:Remove(cand.key)

  local sorted = ns.Results:GetSorted()
  local nextCand = sorted[math.min(index, #sorted)]
  if not nextCand then
    self:Reset(message .. " No more deals; scan again later.")
    return
  end
  if self.chain >= MAX_AUTO_ADVANCE then
    self:Reset(message .. " Paused; click Start to keep going.")
    return
  end
  self:SetTarget(nextCand.key, message)
end

function Buyer:Skip()
  local cand = self.target
  if not cand then return end
  self.chain = 0
  self:Advance(cand, "Skipped " .. ItemText(cand) .. ".")
end

-- Buy as many units as we can afford, cheapest first.
local function AffordableCommodity(offer, money)
  local quantity, cost = 0, 0
  for _, level in ipairs(offer.levels) do
    local canAfford = math.floor((money - cost) / level.unitPrice)
    local take = math.min(level.quantity, canAfford)
    if take <= 0 then break end
    quantity = quantity + take
    cost = cost + take * level.unitPrice
    if take < level.quantity then break end
  end
  return quantity, cost
end

function Buyer:BuyCurrent()
  local cand = self.target
  local offer = self.offers and self.offers[1]
  if not (cand and offer) then return end
  local money = GetMoney()
  local token = self.token

  if offer.kind == "commodity" then
    local quantity = AffordableCommodity(offer, money)
    if quantity == 0 then
      self.message = "Not enough gold to buy any " .. ItemText(cand) .. "."
      Changed()
      return
    end
    self.state = "QUOTING"
    self.message = ("Getting the exact price for %dx %s..."):format(quantity, ItemText(cand))
    Changed()
    local vendor = quantity * offer.unitVendor
    ns.backend:QuoteCommodity(offer, quantity, function(total)
      if token ~= self.token then return end
      if not total or total + ns.db.minProfit > vendor then
        ns.backend:CancelAll()
        self:Search(("Price went up to %s; no longer below vendor."):format(ns.FormatMoney(total or 0)))
        return
      end
      self.quote = { itemID = offer.itemID, quantity = quantity, total = total, vendor = vendor }
      self.state = "CONFIRM"
      self.message = ("Confirm: %dx %s for %s, vendors for %s, profit %s."):format(
        quantity, ItemText(cand), ns.FormatMoney(total), ns.FormatMoney(vendor), ns.FormatMoney(vendor - total))
      Changed()
    end, function(_, err)
      if token ~= self.token then return end
      self:Search(err and ("Not bought: " .. err) or nil)
    end)
    return
  end

  if money < offer.cost then
    self.message = "Not enough gold for that listing (" .. ns.FormatMoney(offer.cost) .. ")."
    Changed()
    return
  end
  self.state = "BUYING"
  self.message = ("Buying %dx %s for %s..."):format(offer.quantity, ItemText(cand), ns.FormatMoney(offer.cost))
  self.pendingBuy = {
    cand = cand, link = offer.link, quantity = offer.quantity,
    vendor = offer.vendor, moneyBefore = money,
  }
  Changed()
  ns.backend:Buy(offer, function(ok, err)
    if token ~= self.token then return end
    self:Search((not ok and err) and ("Not bought: " .. err) or nil)
  end)
end

function Buyer:ConfirmQuote()
  local cand, q = self.target, self.quote
  if not (cand and q) then return end
  local money = GetMoney()
  if money < q.total then
    self.message = "Not enough gold (" .. ns.FormatMoney(q.total) .. " needed)."
    Changed()
    return
  end
  local token = self.token
  self.state = "BUYING"
  self.message = ("Buying %dx %s for %s..."):format(q.quantity, ItemText(cand), ns.FormatMoney(q.total))
  self.pendingBuy = { cand = cand, link = cand.link, quantity = q.quantity, vendor = q.vendor, moneyBefore = money }
  Changed()
  ns.backend:ConfirmCommodity(q, function(ok, err)
    if token ~= self.token then return end
    self:Search((not ok and err) and ("Not bought: " .. err) or nil)
  end)
end

-- The main button. MUST only be called from a hardware event (a click or /click).
function Buyer:OnClick()
  local ok, why = self:CanAct()
  if not ok then
    self.message = why
    Changed()
    return
  end
  self.chain = 0
  local state = self.state
  if state == "IDLE" or state == "FAILED" then
    if self.target and ns.Results:Get(self.target.key) then
      self:Search()
    else
      local first = ns.Results:GetSorted()[1]
      if first then self:SetTarget(first.key) end
    end
  elseif state == "READY" then
    self:BuyCurrent()
  elseif state == "CONFIRM" then
    self:ConfirmQuote()
  end
end

-- Label and enabled state for the main button.
function Buyer:GetAction()
  if not ns.ahOpen then return "Buy", false end
  if ns.Scan.running then return "Scanning...", false end
  local state = self.state
  if state == "IDLE" then
    if #ns.Results:GetSorted() == 0 then return "Buy", false end
    return self.target and "Search" or "Start", true
  elseif state == "SEARCHING" then
    return "Searching...", false
  elseif state == "READY" then
    return "Buy", true
  elseif state == "QUOTING" then
    return "Getting price...", false
  elseif state == "CONFIRM" then
    return "Confirm", true
  elseif state == "BUYING" then
    return "Buying...", false
  elseif state == "FAILED" then
    return "Retry", true
  end
  return "Buy", false
end

ns.Listen("AH_CLOSED", function()
  Buyer:Reset("Open the Auction House to buy.")
end)

ns.Listen("RESULTS_CHANGED", function()
  -- Target removed from elsewhere (ignore list, new scan): stop working on it.
  if Buyer.target and not ns.Results:Get(Buyer.target.key) then
    Buyer:Reset()
  end
end)
