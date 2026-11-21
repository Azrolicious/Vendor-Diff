-- Run from the repository root:  lua5.1 tests/run_tests.lua
local HERE = debug.getinfo(1, "S").source:match("^@(.-)[^/]*$") or "./"
package.path = HERE .. "?.lua;" .. package.path
local Mock = require("wowmock")

---------------------------------------------------------------------------
-- Tiny test framework
---------------------------------------------------------------------------
local tests = {}
local function test(name, fn) tests[#tests + 1] = { name = name, fn = fn } end

local function fail(msg, level) error(msg, (level or 1) + 1) end
local function ok(cond, msg) if not cond then fail("expected: " .. (msg or "condition"), 2) end end
local function eq(actual, expected, msg)
  if actual ~= expected then
    fail(("%s: expected %s, got %s"):format(msg or "value", tostring(expected), tostring(actual)), 2)
  end
end
local function count(list) return list and #list or 0 end

---------------------------------------------------------------------------
-- Fixture: a small auction house
---------------------------------------------------------------------------
local LINEN, SWORD, JUNK, SLOW, BIDONLY, MINE, IGNORED, FILLER = 2589, 100, 200, 300, 400, 500, 600, 700

local function NewMarket(opts)
  opts = opts or {}
  local w = Mock.NewWorld(opts)
  w:AddItem({ id = LINEN, name = "Linen Cloth", sellPrice = 13, classID = 7, stack = 200 })
  w:AddItem({ id = SWORD, name = "Rusty Sword", sellPrice = 5000, classID = 2, ilvl = 30, quality = 2 })
  w:AddItem({ id = JUNK, name = "Unsellable Thing", sellPrice = 0 })
  w:AddItem({ id = SLOW, name = "Slow Loader", sellPrice = 1000, availableAt = w.now + 3 })
  w:AddItem({ id = BIDONLY, name = "Bid Only", sellPrice = 100 })
  w:AddItem({ id = MINE, name = "My Own Thing", sellPrice = 100 })
  w:AddItem({ id = IGNORED, name = "Ignored Thing", sellPrice = 100 })
  w:AddItem({ id = FILLER, name = "Filler", sellPrice = 50 })

  local r = w.replicate
  r[#r + 1] = { itemID = LINEN, count = 20, buyout = 200 }   -- deal: vendor 260
  r[#r + 1] = { itemID = LINEN, count = 5, buyout = 100 }    -- vendor 65: no
  r[#r + 1] = { itemID = SWORD, count = 1, buyout = 3000, ilvl = 30 } -- deal: vendor 5000
  r[#r + 1] = { itemID = SWORD, count = 1, buyout = 6000, ilvl = 30 } -- no
  r[#r + 1] = { itemID = JUNK, count = 1, buyout = 1 }       -- vendor 0: never
  r[#r + 1] = { itemID = SLOW, count = 2, buyout = 500 }     -- deal once item data loads
  r[#r + 1] = { itemID = BIDONLY, count = 1, buyout = 0 }    -- no buyout
  r[#r + 1] = { itemID = MINE, count = 1, buyout = 10, owner = "Tester" } -- our own
  r[#r + 1] = { itemID = IGNORED, count = 1, buyout = 10 }   -- on the ignore list
  for _ = 1, (opts.fillers or 3000) do
    r[#r + 1] = { itemID = FILLER, count = 1, buyout = 100 }
  end

  w.commodities[LINEN] = { { unitPrice = 10, quantity = 20 }, { unitPrice = 20, quantity = 5 } }
  w.commodities[SLOW] = { { unitPrice = 250, quantity = 2 } }
  w.itemAuctions[SWORD] = { { auctionID = 501, buyout = 3000, ilvl = 30 }, { auctionID = 502, buyout = 6000, ilvl = 30 } }
  return w
end

local function Boot(w, savedDB)
  if savedDB then w.env.VendorDiffDB = savedDB end
  local ns = w:LoadAddon()
  return ns
end

local function ScanDone(w, ns, keepIgnored)
  if not keepIgnored then ns.db.ignore[IGNORED] = true end
  w:OpenAH()
  ok(ns.UI.frame and ns.UI.frame:IsShown(), "window opens with the Auction House")
  ok(w:Click(ns.UI.scanButton), "scan button clickable")
  w:Advance(15)
  ok(not ns.Scan.running, "scan finished")
end

local function Keys(ns)
  local keys = {}
  for i, c in ipairs(ns.Results:GetSorted()) do keys[i] = c.key end
  return table.concat(keys, ",")
end

---------------------------------------------------------------------------
-- Tests
---------------------------------------------------------------------------
test("money formatting and parsing", function()
  local ns = Boot(NewMarket())
  eq(ns.FormatMoneyPlain(12345), "1g 23s 45c", "plain")
  eq(ns.FormatMoneyPlain(0), "0c", "zero")
  eq(ns.ParseMoney("1g 20s 5c"), 12005, "g s c")
  eq(ns.ParseMoney("50s"), 5000, "silver")
  eq(ns.ParseMoney("75"), 75, "bare copper")
  eq(ns.ParseMoney("2G5S"), 20500, "case/spacing")
  eq(ns.ParseMoney("abc"), nil, "garbage")
  eq(ns.ParseMoney("5x"), nil, "unknown unit")
  ok(ns.FormatMoney(123456789):find("12,345"), "thousands separator")
end)

test("full scan finds exactly the below-vendor listings", function()
  local w = NewMarket()
  local ns = Boot(w)
  ns.db.ignore[IGNORED] = true
  local progressEvents = 0
  ns.Listen("SCAN_PROGRESS", function() progressEvents = progressEvents + 1 end)
  ScanDone(w, ns)

  eq(count(w.calls.ReplicateItems), 1, "ReplicateItems calls")
  ok(progressEvents >= 3, "scan was split across several frames (" .. progressEvents .. ")")
  eq(Keys(ns), "100:30,300,2589", "candidates sorted by profit")
  local sword = ns.Results:Get("100:30")
  eq(sword.profit, 2000, "sword profit")
  eq(sword.itemLevel, 30, "sword item level")
  local slow = ns.Results:Get("300")
  eq(slow.profit, 1500, "slow-loading item found after retry")
  local linen = ns.Results:Get("2589")
  eq(linen.quantity, 20, "linen quantity")
  eq(linen.cost, 200, "linen cost")
  eq(linen.vendor, 260, "linen vendor value")
  ok(w:ChatContains("Scan complete"), "completion message")
  eq(#w.hwViolations, 0, "no restricted calls outside clicks")
end)

test("buy flow: item auction, then commodity with confirm, then price rise", function()
  local w = NewMarket()
  local ns = Boot(w)
  ScanDone(w, ns)
  local buy = ns.UI.buyButton
  eq(buy:GetText(), "Start", "button before selecting")

  -- Start: selects the best deal and searches it live.
  w:Click(buy)
  w:Advance(1)
  eq(ns.Buyer.target.key, "100:30", "top deal selected")
  local lastSearch = w.calls.SendSearchQuery[#w.calls.SendSearchQuery][1]
  eq(lastSearch.itemID, SWORD, "searched the sword")
  eq(lastSearch.itemLevel, 30, "with its item level")
  eq(ns.Buyer.state, "READY", "ready to buy")
  eq(buy:GetText(), "Buy", "button label")

  -- Buy the sword auction.
  local money = w.money
  w:Click(buy)
  eq(w.calls.PlaceBid[1][1], 501, "bought the cheap auction")
  eq(w.calls.PlaceBid[1][2], 3000, "at its buyout")
  w:Advance(2)
  eq(w.money, money - 3000, "gold spent")
  eq(ns.Buyer.session.purchases, 1, "purchase recorded")
  ok(w:ChatContains("Bought 1x"), "purchase message")
  ok(not ns.Results:Get("100:30"), "sold-out sword removed")

  -- Auto-advanced to the commodity.
  eq(ns.Buyer.target.key, "300", "advanced to next deal")
  eq(ns.Buyer.state, "READY", "commodity ready")
  w:Click(buy)
  eq(w.calls.StartCommoditiesPurchase[1][1], SLOW, "quote requested")
  eq(w.calls.StartCommoditiesPurchase[1][2], 2, "for all units below vendor price")
  w:Advance(1)
  eq(ns.Buyer.state, "CONFIRM", "waiting for confirmation")
  eq(buy:GetText(), "Confirm", "confirm label")
  w:Click(buy)
  eq(count(w.calls.ConfirmCommoditiesPurchase), 1, "confirmed")
  w:Advance(2)
  eq(ns.Buyer.session.purchases, 2, "second purchase recorded")
  eq(ns.Buyer.session.spent, 3500, "total spent")

  -- Linen: the price rises between search and quote, so we must not confirm.
  eq(ns.Buyer.target.key, "2589", "advanced to linen")
  w.priceBump = function() w.commodities[LINEN][1].unitPrice = 14 end
  w:Click(buy)
  w:Advance(2)
  ok(count(w.calls.CancelCommoditiesPurchase) >= 1, "quote cancelled")
  eq(count(w.calls.ConfirmCommoditiesPurchase), 1, "no confirm on a bad quote")
  eq(#ns.Results:GetSorted(), 0, "nothing left")
  eq(ns.Buyer.target, nil, "buyer idle")
  ok(ns.Buyer.message:find("No more deals"), "told the user we're done")
  eq(#w.hwViolations, 0, "no restricted calls outside clicks")
end)

test("sold-out candidates are skipped automatically", function()
  local w = NewMarket({ fillers = 10 })
  local ns = Boot(w)
  ScanDone(w, ns, true) -- item 600 is a deal in the scan but has no live listings
  eq(Keys(ns), "100:30,300,600,2589", "600 found by the scan")
  ns.Buyer:Select("600")
  w:Advance(2)
  ok(not ns.Results:Get("600"), "sold-out item dropped")
  eq(ns.Buyer.target.key, "2589", "moved on to the next deal")
  eq(ns.Buyer.state, "READY", "and searched it")
  ok(ns.Buyer.message:find("Nothing below vendor price left"), "explained the skip")
end)

test("purchases never happen without a click", function()
  local w = NewMarket()
  local ns = Boot(w)
  ScanDone(w, ns)
  w:Click(ns.UI.buyButton) -- Start
  w:Advance(1)
  eq(ns.Buyer.state, "READY", "ready")
  -- A buggy addon path calling OnClick from a timer would be blocked by the client.
  local okCall = pcall(function() ns.Buyer:OnClick() end)
  ok(not okCall, "mock blocks PlaceBid outside a hardware event")
  eq(#w.hwViolations, 1, "violation recorded")
end)

test("not enough gold", function()
  local w = NewMarket({ money = 1000 })
  local ns = Boot(w)
  ScanDone(w, ns)
  w:Click(ns.UI.buyButton)
  w:Advance(1)
  w:Click(ns.UI.buyButton)
  eq(count(w.calls.PlaceBid), 0, "no bid without gold")
  ok(ns.Buyer.message:find("Not enough gold"), "explains why")
end)

test("commodity quantity is trimmed to what we can afford", function()
  local w = NewMarket({ money = 300 })
  local ns = Boot(w)
  ScanDone(w, ns)
  ns.Buyer:Select("300")
  w:Advance(1)
  w:Click(ns.UI.buyButton)
  eq(w.calls.StartCommoditiesPurchase[1][2], 1, "only one unit affordable")
end)

test("full-scan cooldown, and shift-click override", function()
  local w = NewMarket({ fillers = 10 })
  local ns = Boot(w)
  ScanDone(w, ns)
  w:Click(ns.UI.scanButton)
  w:Advance(5)
  eq(count(w.calls.ReplicateItems), 1, "second scan blocked")
  ok(ns.Scan.statusText:find("15 minutes"), "cooldown explained")
  w:Click(ns.UI.scanButton, "LeftButton", { shift = true })
  w:Advance(15)
  eq(count(w.calls.ReplicateItems), 2, "shift-click forces a scan")
end)

test("search waits for the AH throttle", function()
  local w = NewMarket({ fillers = 10 })
  local ns = Boot(w)
  ScanDone(w, ns)
  local before = count(w.calls.SendSearchQuery)
  w.throttleReady = false
  ns.Buyer:Select("2589")
  w:Advance(1)
  eq(count(w.calls.SendSearchQuery), before, "query held while throttled")
  w.throttleReady = true
  w:Fire("AUCTION_HOUSE_THROTTLED_SYSTEM_READY")
  eq(count(w.calls.SendSearchQuery), before + 1, "query sent when ready")
  w:Advance(1)
  eq(ns.Buyer.state, "READY", "results arrived")
end)

test("closing the AH mid-scan aborts cleanly", function()
  local w = NewMarket()
  local ns = Boot(w)
  w:OpenAH()
  w:Click(ns.UI.scanButton)
  w:Advance(0.5)
  w:CloseAH()
  w:Advance(5)
  ok(not ns.Scan.running, "scan stopped")
  ok(w:ChatContains("Scan failed: the Auction House was closed"), "abort message")
  ok(not ns.UI.frame:IsShown(), "window hides with the AH")
end)

test("gear search falls back to any item level", function()
  local w = NewMarket({ fillers = 10 })
  -- The AH lists the sword under a different item level than the link says.
  w.itemAuctions[SWORD] = { { auctionID = 777, buyout = 3000, ilvl = 31 } }
  local ns = Boot(w)
  ScanDone(w, ns)
  ns.Buyer:Select("100:30")
  w:Advance(2)
  local q = w.calls.SendSearchQuery
  eq(q[#q - 1][1].itemLevel, 30, "first try with exact item level")
  eq(q[#q][1].itemLevel, 0, "then any item level")
  eq(ns.Buyer.state, "READY", "found it")
  eq(ns.Buyer.offers[1].auctionID, 777, "right auction")
end)

test("purchase completes even without AUCTION_HOUSE_PURCHASE_COMPLETED", function()
  local w = NewMarket({ fillers = 10, withoutEvents = { "AUCTION_HOUSE_PURCHASE_COMPLETED" } })
  local ns = Boot(w) -- must load without erroring on the unknown event
  ScanDone(w, ns)
  w:Click(ns.UI.buyButton)
  w:Advance(1)
  w:Click(ns.UI.buyButton)
  eq(count(w.calls.PlaceBid), 1, "bid placed")
  w:Advance(1)
  eq(ns.Buyer.state, "BUYING", "still waiting for confirmation")
  w:Advance(6)
  eq(ns.Buyer.session.purchases, 1, "timeout fallback re-searched and recorded the buy")
end)

test("min profit filter from the edit box", function()
  local w = NewMarket({ fillers = 10 })
  local ns = Boot(w)
  ScanDone(w, ns)
  local box = ns.UI.minProfitBox
  box:SetText("16s")
  box._scripts.OnEnterPressed(box)
  eq(ns.db.minProfit, 1600, "saved")
  eq(Keys(ns), "100:30", "only the 20s deal remains")
  box:SetText("nonsense")
  box._scripts.OnEnterPressed(box)
  eq(ns.db.minProfit, 1600, "bad input ignored")
  eq(box:GetText(), "16s", "box shows the real value")
  box:SetText("1")
  box._scripts.OnEnterPressed(box)
  eq(Keys(ns), "100:30,300,2589", "all deals back")
end)

test("right-click hides, ctrl+right-click ignores", function()
  local w = NewMarket({ fillers = 10 })
  local ns = Boot(w)
  ScanDone(w, ns)
  local rows = ns.UI.rows
  eq(rows[1].candidate.key, "100:30", "first row")
  w:Click(rows[1], "RightButton")
  eq(Keys(ns), "300,2589", "hidden")
  eq(ns.db.ignore[SWORD], nil, "not ignored permanently")
  w:Click(rows[2], "RightButton", { ctrl = true })
  eq(Keys(ns), "300", "linen gone")
  eq(ns.db.ignore[LINEN], true, "linen ignored permanently")
  -- left click selects and searches
  w:Click(rows[1])
  w:Advance(1)
  eq(ns.Buyer.target.key, "300", "selected")
  ok(rows[1].selected:IsShown(), "selection highlighted")
end)

test("slash commands", function()
  local w = NewMarket({ fillers = 10 })
  local ns = Boot(w)
  local slash = w.env.SlashCmdList.VENDORDIFF
  eq(w.env.SLASH_VENDORDIFF2, "/vd", "short alias")
  slash("minprofit 50s")
  eq(ns.db.minProfit, 5000, "minprofit")
  slash("minprofit 0")
  eq(ns.db.minProfit, 5000, "rejects zero")
  slash("ignore " .. w:ItemLink(LINEN))
  eq(ns.db.ignore[LINEN], true, "ignore by link")
  slash("unignore all")
  eq(next(ns.db.ignore), nil, "unignore all")
  slash("help")
  ok(w:ChatContains("/vd scan"), "help text")
  slash("")
  ok(ns.UI.frame:IsShown(), "toggle opens")
  slash("")
  ok(not ns.UI.frame:IsShown(), "toggle closes")
end)

test("saved settings merge with defaults (and missing SavedVariables are fine)", function()
  local w = NewMarket({ fillers = 10 })
  local ns = Boot(w, { minProfit = 500 })
  eq(ns.db.minProfit, 500, "kept saved value")
  ok(type(ns.db.ignore) == "table", "filled missing table")
  eq(ns.db.autoOpen, true, "filled missing default")

  local w2 = NewMarket({ fillers = 10 })
  local ns2 = Boot(w2) -- Forever beta bug: SavedVariables may not load at all
  eq(ns2.db.minProfit, 1, "defaults when nothing was saved")
end)

---------------------------------------------------------------------------
-- Run
---------------------------------------------------------------------------
local failed = 0
for _, t in ipairs(tests) do
  local okRun, err = xpcall(t.fn, debug.traceback)
  if okRun then
    print("PASS  " .. t.name)
  else
    failed = failed + 1
    print("FAIL  " .. t.name .. "\n      " .. tostring(err):gsub("\n", "\n      "))
  end
end
print(("\n%d/%d passed"):format(#tests - failed, #tests))
os.exit(failed == 0 and 0 or 1)
