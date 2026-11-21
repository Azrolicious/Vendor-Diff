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
-- Fixture: a small auction house. The browse scan is derived from these
-- live listings by the mock, exactly as the server would summarise them.
---------------------------------------------------------------------------
local LINEN, SWORD, JUNK, SLOW, BIDONLY, MINE, IGNORED = 2589, 100, 200, 300, 400, 500, 600
local FILLER_BASE = 10000

local function NewMarket(opts)
  opts = opts or {}
  local w = Mock.NewWorld(opts)
  w:AddItem({ id = LINEN, name = "Linen Cloth", sellPrice = 13, classID = 7, stack = 20 })
  w:AddItem({ id = SWORD, name = "Rusty Sword", sellPrice = 5000, classID = 2, ilvl = 30, quality = 2 })
  w:AddItem({ id = JUNK, name = "Unsellable Thing", sellPrice = 0 })
  w:AddItem({ id = SLOW, name = "Slow Loader", sellPrice = 1000, availableAt = w.now + 3 })
  w:AddItem({ id = BIDONLY, name = "Bid Only", sellPrice = 100, classID = 2 })
  w:AddItem({ id = MINE, name = "My Own Thing", sellPrice = 100 })
  w:AddItem({ id = IGNORED, name = "Ignored Thing", sellPrice = 100 })

  -- Commodities: cheapest first. Linen: 20 below vendor (13c), 5 above.
  w.commodities[LINEN] = { { unitPrice = 10, quantity = 20 }, { unitPrice = 20, quantity = 5 } }
  w.commodities[SLOW] = { { unitPrice = 250, quantity = 2 } }
  w.commodities[JUNK] = { { unitPrice = 1, quantity = 1 } }           -- vendor 0: never a deal
  w.commodities[MINE] = { { unitPrice = 10, quantity = 1, numOwnerItems = 1 } } -- only our own
  w.commodities[IGNORED] = { { unitPrice = 10, quantity = 1 } }
  -- Items: one sword below vendor (5000), one above. A bid-only auction.
  w.itemAuctions[SWORD] = { { auctionID = 501, buyout = 3000, ilvl = 30 }, { auctionID = 502, buyout = 6000, ilvl = 30 } }
  w.itemAuctions[BIDONLY] = { { auctionID = 601, bid = 5, ilvl = 10 } }

  w.fillerItem = FILLER_BASE + 1
  for i = 1, math.max(1, opts.fillers or 3000) do -- plenty of items that are not deals
    local id = FILLER_BASE + i
    w:AddItem({ id = id, name = "Filler " .. i, sellPrice = 50 })
    w.commodities[id] = { { unitPrice = 100, quantity = 1 } }
  end
  return w
end

local function Boot(w, savedDB)
  if savedDB then w.env.VendorDiffDB = savedDB end
  return w:LoadAddon()
end

local function ScanDone(w, ns, keepIgnored)
  if not keepIgnored then ns.db.ignore[IGNORED] = true end
  if not ns.ahOpen then w:OpenAH() end
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

local ALL_DEALS = "100:30,300,400:10,500,2589" -- by per-unit profit: 2000, 750, 95, 90, 3

---------------------------------------------------------------------------
-- Tests
---------------------------------------------------------------------------
test("money formatting and parsing", function()
  local ns = Boot(NewMarket({ fillers = 1 }))
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

test("summary scan finds the items listed below vendor price", function()
  local w = NewMarket()
  local ns = Boot(w)
  local progressEvents = 0
  ns.Listen("SCAN_PROGRESS", function() progressEvents = progressEvents + 1 end)
  ScanDone(w, ns)

  eq(count(w.calls.SendBrowseQuery), 1, "one browse query")
  ok(count(w.calls.RequestMoreBrowseResults) >= 6, "paged through every result page")
  ok(progressEvents >= 3, "processing was split across several frames (" .. progressEvents .. ")")
  eq(Keys(ns), ALL_DEALS, "candidates sorted by profit")

  local sword = ns.Results:Get("100:30")
  ok(sword.estimate, "scan rows are estimates until searched")
  eq(sword.unitPrice, 3000, "sword lowest price")
  eq(sword.unitVendor, 5000, "sword vendor price")
  eq(sword.profit, 2000, "sword per-unit profit")
  eq(sword.itemKey.itemLevel, 30, "keeps the exact item key")
  eq(ns.Results:Get("300").profit, 750, "slow-loading item found after retry")
  eq(ns.Results:Get("2589").unitPrice, 10, "linen lowest price")
  ok(not ns.Results:Get("200"), "unsellable item ignored")
  ok(not ns.Results:Get("600"), "ignore list respected")
  ok(w:ChatContains("Scan complete"), "completion message")
  eq(#w.hwViolations, 0, "no restricted calls outside clicks")
  eq(w.sellTabViolations, 0, "no requests while the Sell tab was open")
end)

test("you can scan again straight away", function()
  local w = NewMarket({ fillers = 10 })
  local ns = Boot(w)
  ScanDone(w, ns)
  ScanDone(w, ns)
  eq(count(w.calls.SendBrowseQuery), 2, "second scan ran")
  eq(Keys(ns), ALL_DEALS, "same results")
end)

test("buy flow: item, commodity with confirm, sold-out skips, price rise", function()
  local w = NewMarket()
  local ns = Boot(w)
  ScanDone(w, ns)
  local buy = ns.UI.buyButton
  eq(buy:GetText(), "Start", "button before selecting")

  -- Start: selects the best deal and searches it live with the exact item key.
  w:Click(buy)
  w:Advance(1)
  eq(ns.Buyer.target.key, "100:30", "top deal selected")
  local lastSearch = w.calls.SendSearchQuery[#w.calls.SendSearchQuery][1]
  eq(lastSearch.itemID, SWORD, "searched the sword")
  eq(lastSearch.itemLevel, 30, "with its item key")
  eq(ns.Buyer.state, "READY", "ready to buy")
  eq(buy:GetText(), "Buy", "button label")
  local sword = ns.Results:Get("100:30")
  ok(not sword.estimate, "row now shows live numbers")
  eq(sword.quantity, 1, "one sword below vendor")

  -- Buy the sword.
  local money = w.money
  w:Click(buy)
  eq(w.calls.PlaceBid[1][1], 501, "bought the cheap auction")
  eq(w.calls.PlaceBid[1][2], 3000, "at its buyout")
  w:Advance(2)
  eq(w.money, money - 3000, "gold spent")
  eq(ns.Buyer.session.purchases, 1, "purchase recorded")
  ok(w:ChatContains("Bought 1x"), "purchase message")
  ok(not ns.Results:Get("100:30"), "sold-out sword removed")

  -- Commodity: quote, then confirm.
  eq(ns.Buyer.target.key, "300", "advanced to next deal")
  eq(ns.Buyer.state, "READY", "commodity ready")
  w:Click(buy)
  eq(w.calls.StartCommoditiesPurchase[1][1], SLOW, "quote requested")
  eq(w.calls.StartCommoditiesPurchase[1][2], 2, "for all units below vendor price")
  eq(w.calls.StartCommoditiesPurchase[1][3], 250, "with the expected unit price, like Blizzard's UI")
  w:Advance(1)
  eq(ns.Buyer.state, "CONFIRM", "waiting for confirmation")
  eq(buy:GetText(), "Confirm", "confirm label")
  w:Click(buy)
  eq(count(w.calls.ConfirmCommoditiesPurchase), 1, "confirmed")
  w:Advance(4)
  eq(ns.Buyer.session.purchases, 2, "second purchase recorded")
  eq(ns.Buyer.session.spent, 3500, "total spent")

  -- The bid-only item and our own listing looked like deals in the summary
  -- but have nothing buyable: both are skipped without a click.
  ok(not ns.Results:Get("400:10"), "bid-only item skipped")
  ok(not ns.Results:Get("500"), "own listing skipped")
  eq(ns.Buyer.target.key, "2589", "advanced to linen")
  eq(ns.Results:Get("2589").quantity, 20, "live quantity below vendor")
  eq(ns.Results:Get("2589").profit, 60, "live total profit")

  -- Linen: the price rises between search and quote, so we must not confirm.
  w.priceBump = function() w.commodities[LINEN][1].unitPrice = 14 end
  w:Click(buy)
  w:Advance(2)
  ok(count(w.calls.CancelCommoditiesPurchase) >= 1, "quote cancelled")
  eq(count(w.calls.ConfirmCommoditiesPurchase), 1, "no confirm on a bad quote")
  eq(#ns.Results:GetSorted(), 0, "nothing left")
  eq(ns.Buyer.target, nil, "buyer idle")
  ok(ns.Buyer.message:find("No more deals"), "told the user we're done")
  eq(#w.hwViolations, 0, "no restricted calls outside clicks")
  eq(w.sellTabViolations, 0, "no requests while the Sell tab was open")
end)

test("sold-out candidates explain why they were skipped", function()
  local w = NewMarket({ fillers = 10 })
  local ns = Boot(w)
  ScanDone(w, ns)
  ns.Buyer:Select("400:10")
  w:Advance(3)
  eq(ns.Buyer.target.key, "2589", "moved past both unbuyable items")
  eq(ns.Buyer.state, "READY", "and searched the next one")
  ok(ns.Buyer.message:find("Nothing below vendor price left"), "explained the skip")
end)

test("purchases never happen without a click", function()
  local w = NewMarket({ fillers = 10 })
  local ns = Boot(w)
  ScanDone(w, ns)
  w:Click(ns.UI.buyButton) -- Start
  w:Advance(1)
  eq(ns.Buyer.state, "READY", "ready")
  -- A buggy addon path calling OnClick from a timer would be blocked by the client.
  ns.Buyer:OnClick()
  eq(#w.hwViolations, 1, "mock blocked PlaceBid outside a hardware event")
  eq(w.money, 1000000, "nothing bought")
  w:Advance(8)
  ok(ns.Buyer.message:find("Not bought"), "the failure is shown, not swallowed")
end)

test("a purchase the client silently blocks is reported, not retried quietly", function()
  local w = NewMarket({ fillers = 10 })
  local ns = Boot(w)
  ScanDone(w, ns)
  w.placeBidMode = "blocked"
  w:Click(ns.UI.buyButton) -- Start
  w:Advance(1)
  local money = w.money
  w:Click(ns.UI.buyButton) -- Buy
  eq(count(w.calls.PlaceBid), 1, "PlaceBid was called from the click")
  w:Advance(8)
  eq(w.money, money, "no gold spent")
  eq(ns.Buyer.session.purchases, 0, "not counted as a purchase")
  eq(ns.Buyer.state, "READY", "listing offered again")
  ok(ns.Buyer.message:find("^Not bought: the server never confirmed the purchase"), "status line says it failed")
  ok(w:ChatContains("was not bought"), "failure printed in chat")
  ok(w:ChatContains("PlaceBid%(auction 501, 30s%); Auction House ready: true; addon restrictions active: none"),
    "trace shows the call and the restriction state")
  ok(w:ChatContains("ADDON_ACTION_BLOCKED%(VendorDiff, C_AuctionHouse.PlaceBid%(%)%)"), "trace shows the block")
end)

test("a Lua error inside PlaceBid surfaces and the failure is still reported", function()
  local w = NewMarket({ fillers = 10 })
  local ns = Boot(w)
  ScanDone(w, ns)
  w.placeBidMode = "error"
  w:Click(ns.UI.buyButton)
  w:Advance(1)
  -- PlaceBid is called directly (not through pcall), so its error reaches the
  -- game's error display like any other Lua error.
  ok(not pcall(w.Click, w, ns.UI.buyButton), "Lua error is not swallowed")
  w:Advance(8)
  ok(ns.Buyer.message:find("^Not bought: the server never confirmed"), "status line reports the failure")
end)

test("buy mode 'blizzard' buys through Blizzard's own buyout dialog", function()
  local w = NewMarket({ fillers = 10 })
  local ns = Boot(w)
  ScanDone(w, ns)
  w.env.SlashCmdList.VENDORDIFF("buymode blizzard")
  eq(ns.db.buyMode, "blizzard", "mode saved")
  w.placeBidMode = "blocked" -- addon calls are refused; Blizzard's dialog isn't
  w:Click(ns.UI.buyButton) -- Start
  w:Advance(1)
  local money = w.money
  w:Click(ns.UI.buyButton) -- Buy
  eq(count(w.calls.PlaceBid), 0, "Vendor Diff didn't bid itself")
  eq(w.calls.StaticPopup_Show[1][1], "BUYOUT_AUCTION", "Blizzard's dialog shown")
  eq(w.calls.StaticPopup_Show[1][2].auctionID, 501, "for the right auction")
  eq(w.calls.StaticPopup_Show[1][2].buyout, 3000, "at its buyout")
  ok(ns.Buyer.message:find("Click Accept"), "tells the player what to do")
  w:Advance(2)
  eq(ns.Buyer.state, "BUYING", "waits for the player")
  w:AcceptPopup()
  w:Advance(2)
  eq(w.money, money - 3000, "bought")
  eq(ns.Buyer.session.purchases, 1, "purchase recorded")
  eq(#w.hwViolations, 0, "nothing blocked")
end)

test("closing Blizzard's buyout dialog is reported as not bought", function()
  local w = NewMarket({ fillers = 10 })
  local ns = Boot(w)
  ScanDone(w, ns)
  ns.db.buyMode = "blizzard"
  w:Click(ns.UI.buyButton)
  w:Advance(1)
  w:Click(ns.UI.buyButton)
  w:Advance(1)
  w:CancelPopup()
  w:Advance(6)
  eq(ns.Buyer.state, "READY", "listing offered again")
  ok(ns.Buyer.message:find("closed without a purchase"), "says the dialog was closed")
end)

test("buying waits until the Auction House isn't busy", function()
  local w = NewMarket({ fillers = 10 })
  local ns = Boot(w)
  ScanDone(w, ns)
  w:Click(ns.UI.buyButton)
  w:Advance(1)
  w.throttleReady = false
  w:Click(ns.UI.buyButton)
  eq(count(w.calls.PlaceBid), 0, "nothing sent while busy")
  ok(ns.Buyer.message:find("still busy"), "explains why")
  w.throttleReady = true
  w:Click(ns.UI.buyButton)
  eq(count(w.calls.PlaceBid), 1, "sent once ready")
end)

test("debug mode prints the trace live", function()
  local w = NewMarket({ fillers = 10 })
  local ns = Boot(w)
  w.env.SlashCmdList.VENDORDIFF("debug")
  eq(ns.db.debug, true, "debug on")
  ScanDone(w, ns)
  w:Click(ns.UI.buyButton)
  w:Advance(1)
  w:Click(ns.UI.buyButton)
  w:Advance(2)
  ok(w:ChatContains("debug:.*PlaceBid"), "call printed")
  ok(w:ChatContains("debug:.*AUCTION_HOUSE_PURCHASE_COMPLETED%(501%)"), "events printed")
  ok(w:ChatContains("Bought 1x"), "and it still bought")
end)

test("not enough gold", function()
  local w = NewMarket({ fillers = 10, money = 1000 })
  local ns = Boot(w)
  ScanDone(w, ns)
  w:Click(ns.UI.buyButton)
  w:Advance(1)
  w:Click(ns.UI.buyButton)
  eq(count(w.calls.PlaceBid), 0, "no bid without gold")
  ok(ns.Buyer.message:find("Not enough gold"), "explains why")
end)

test("commodity quantity is trimmed to what we can afford", function()
  local w = NewMarket({ fillers = 10, money = 300 })
  local ns = Boot(w)
  ScanDone(w, ns)
  ns.Buyer:Select("300")
  w:Advance(1)
  w:Click(ns.UI.buyButton)
  eq(w.calls.StartCommoditiesPurchase[1][2], 1, "only one unit affordable")
end)

test("requests wait while Blizzard's Sell tab is open", function()
  local w = NewMarket({ fillers = 10 })
  local ns = Boot(w)
  ns.db.ignore[IGNORED] = true
  w:OpenAH()
  local sellTab = w.env.AuctionHouseFrame.CommoditiesSellFrame
  sellTab:Show()
  w:Click(ns.UI.scanButton)
  w:Advance(3)
  eq(count(w.calls.SendBrowseQuery), 0, "scan held")
  ok(ns.Scan.statusText:find("Sell tab"), "says why")
  sellTab:Hide()
  w:Advance(15)
  ok(not ns.Scan.running, "scan finished after leaving the Sell tab")
  eq(Keys(ns), ALL_DEALS, "results")

  sellTab:Show()
  w:Click(ns.UI.buyButton)
  w:Advance(1)
  ok(ns.Buyer.message:find("Leave the Auction House Sell tab"), "buying blocked with a reason")
  eq(ns.Buyer.target, nil, "nothing searched")
  eq(w.sellTabViolations, 0, "never sent a request with the Sell tab open")
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

test("the interaction manager event also opens the window", function()
  local w = NewMarket({ fillers = 10 })
  local ns = Boot(w)
  local opened = 0
  ns.Listen("AH_OPENED", function() opened = opened + 1 end)
  w:Fire("PLAYER_INTERACTION_MANAGER_FRAME_SHOW", 21)
  w:Fire("AUCTION_HOUSE_SHOW") -- same visit reported twice
  w:Advance(0.1)
  eq(opened, 1, "opened once")
  ok(ns.ahOpen and ns.UI.frame:IsShown(), "window shown")
  w:Fire("PLAYER_INTERACTION_MANAGER_FRAME_SHOW", 5) -- some other NPC window: ignored
  w:Fire("PLAYER_INTERACTION_MANAGER_FRAME_HIDE", 21)
  w:Advance(0.1)
  ok(not ns.ahOpen, "closed")
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

test("browse failure is reported", function()
  local w = NewMarket({ fillers = 10 })
  local ns = Boot(w)
  w.browseFail = true
  w:OpenAH()
  w:Click(ns.UI.scanButton)
  w:Advance(2)
  ok(not ns.Scan.running, "scan stopped")
  ok(w:ChatContains("refused the request"), "failure message")
  ok(ns.UI.scanButton:IsEnabled(), "can try again")
end)

test("a stalled scan keeps the pages it got", function()
  local w = NewMarket()
  local ns = Boot(w)
  w.browseStallAfter = 2
  w:OpenAH()
  w:Click(ns.UI.scanButton)
  w:Advance(10)
  ok(ns.Scan.running, "still waiting for the third page")
  w:Advance(30)
  ok(not ns.Scan.running, "finished after the page timeout")
  ok(w:ChatContains("stopped responding partway"), "warns the scan is incomplete")
  ok(#ns.Results:GetSorted() > 0, "kept results from the first pages")
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
  eq(Keys(ns), ALL_DEALS, "all deals back")
end)

test("right-click hides, ctrl+right-click ignores", function()
  local w = NewMarket({ fillers = 10 })
  local ns = Boot(w)
  ScanDone(w, ns)
  local rows = ns.UI.rows
  eq(rows[1].candidate.key, "100:30", "first row")
  w:Click(rows[1], "RightButton")
  eq(Keys(ns), "300,400:10,500,2589", "hidden")
  eq(ns.db.ignore[SWORD], nil, "not ignored permanently")
  w:Click(rows[2], "RightButton", { ctrl = true })
  eq(Keys(ns), "300,500,2589", "bid-only item gone")
  eq(ns.db.ignore[BIDONLY], true, "ignored permanently")
  w:Click(rows[1])
  w:Advance(1)
  eq(ns.Buyer.target.key, "300", "left click selects")
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
  local ns = Boot(w, { minProfit = 500, lastFullScan = { old = 1 } })
  eq(ns.db.minProfit, 500, "kept saved value")
  ok(type(ns.db.ignore) == "table", "filled missing table")
  eq(ns.db.autoOpen, true, "filled missing default")

  local w2 = NewMarket({ fillers = 10 })
  local ns2 = Boot(w2) -- Forever bug: SavedVariables may not load at all
  eq(ns2.db.minProfit, 1, "defaults when nothing was saved")
end)

---------------------------------------------------------------------------
-- Selling what Vendor Diff bought
---------------------------------------------------------------------------
-- Pretend Vendor Diff bought `count` of an item (as SettlePurchase records it).
local function Bought(w, ns, itemID, count, ilvl)
  local sell = w.items[itemID].sellPrice
  ns.Ledger:Add(itemID, w:ItemLink(itemID, ilvl), w.items[itemID].name, count, count * (sell - 2), count * sell)
end

local function LedgerCount(ns, key)
  local e = ns.charDB.ledger[key]
  return e and e.count or 0
end

test("purchases are recorded to be sold later", function()
  local w = NewMarket({ fillers = 10 })
  local ns = Boot(w)
  ScanDone(w, ns)
  w:Click(ns.UI.buyButton) -- Start: sword
  w:Advance(1)
  w:Click(ns.UI.buyButton) -- buy sword
  w:Advance(2)
  w:Click(ns.UI.buyButton) -- quote Slow Loader
  w:Advance(1)
  w:Click(ns.UI.buyButton) -- confirm
  w:Advance(4)
  eq(LedgerCount(ns, "100:30"), 1, "sword recorded with its item level")
  eq(LedgerCount(ns, "300"), 2, "commodity recorded")
  eq(ns.charDB.ledger["300"].cost, 500, "what we paid")
  eq(ns.charDB.ledger["300"].vendor, 2000, "what the vendor pays")
  ok(w:ChatContains("sold at the next vendor"), "tells the player what happens next")
end)

test("a vendor gets exactly the bought amount, splitting a mixed stack", function()
  local w = NewMarket({ fillers = 1 })
  local ns = Boot(w)
  Bought(w, ns, LINEN, 18)
  w:PutInBags(LINEN, 5)        -- 5 of your own...
  w:CollectMail(LINEN, 18)     -- ...topped up to 20 by the mail, plus a stack of 3
  eq(w.bags[0].slots[1].count, 20, "mixed stack of 20")
  local money = w.money
  w:OpenMerchant()
  w:Advance(5)
  eq(w:BagCount(LINEN), 5, "your own 5 are kept")
  eq(w.money, money + 18 * 13, "sold 18 at the vendor price")
  eq(count(w.calls.SplitContainerItem), 1, "one stack had to be split")
  eq(ns.charDB.ledger["2589"], nil, "record cleared once sold")
  ok(w:ChatContains("Sold 18x"), "sale reported")
  eq(w.usedOutsideMerchant + w.attachedToMail, 0, "nothing used or mailed by mistake")
  eq(w.cursor, nil, "nothing left on the cursor")
end)

test("items you get later are never sold", function()
  local w = NewMarket({ fillers = 1 })
  local ns = Boot(w)
  Bought(w, ns, LINEN, 4)
  w:CollectMail(LINEN, 4)
  w:OpenMerchant()
  w:Advance(3)
  w:CloseMerchant()
  eq(w:BagCount(LINEN), 0, "bought ones sold")
  w:PutInBags(LINEN, 10) -- farmed later
  local sales = count(w.calls.UseContainerItem)
  w:OpenMerchant()
  w:Advance(3)
  eq(count(w.calls.UseContainerItem), sales, "nothing sold on the second visit")
  eq(w:BagCount(LINEN), 10, "farmed cloth kept")
end)

test("your own copies aren't sold while the bought ones are still in the mailbox", function()
  local w = NewMarket({ fillers = 1 })
  local ns = Boot(w)
  Bought(w, ns, LINEN, 5)
  w:PutInBags(LINEN, 5) -- your own, farmed
  w:OpenMerchant()
  w:Advance(3)
  eq(count(w.calls.UseContainerItem), 0, "your own linen isn't sold in their place")
  eq(LedgerCount(ns, "2589"), 5, "still tracked")
  w:CloseMerchant()
  w:CollectMail(LINEN, 5)
  w:OpenMerchant()
  w:Advance(3)
  eq(w:BagCount(LINEN), 5, "exactly the 5 bought were sold")
  eq(LedgerCount(ns, "2589"), 0, "record cleared")
end)

test("only what was actually collected from the mailbox counts", function()
  local w = NewMarket({ fillers = 1 })
  local ns = Boot(w)
  Bought(w, ns, LINEN, 18)
  w:OpenMail()
  w:TakeMail(LINEN, 6)  -- took one letter
  w:CloseMail()
  w:PutInBags(LINEN, 4) -- looted later, not from the mail
  w:OpenMerchant()
  w:Advance(3)
  eq(w:BagCount(LINEN), 4, "sold the 6 collected, kept the 4 looted")
  eq(LedgerCount(ns, "2589"), 12, "12 still waiting in the mailbox")
  eq(ns.charDB.ledger["2589"].arrived, 0, "none of those collected yet")
end)

test("never sells while the mailbox, bank or Auction House is open", function()
  local w = NewMarket({ fillers = 1 })
  local ns = Boot(w)
  Bought(w, ns, LINEN, 5)
  w:OpenMail()
  w:TakeMail(LINEN, 5)
  w:OpenMerchant() -- mailbox still open
  w:Advance(3)
  eq(count(w.calls.UseContainerItem), 0, "no sale with the mailbox open")
  eq(w.attachedToMail, 0, "nothing attached to mail")
  eq(LedgerCount(ns, "2589"), 5, "still tracked")
  w:CloseMail()
  w:CloseMerchant()
  w:OpenMerchant()
  w:Advance(3)
  eq(w:BagCount(LINEN), 0, "sold once only the vendor is open")
end)

test("gear is matched by item level", function()
  local w = NewMarket({ fillers = 1 })
  local ns = Boot(w)
  Bought(w, ns, SWORD, 1, 30)
  w:PutInBags(SWORD, 1, 25) -- your own, lower item level
  w:CollectMail(SWORD, 1, 30) -- the one Vendor Diff bought
  w:OpenMerchant()
  w:Advance(3)
  eq(w:BagCount(SWORD, 30), 0, "bought sword sold")
  eq(w:BagCount(SWORD, 25), 1, "your own sword kept")
end)

test("if the game blocks auto-selling, a Sell button takes over", function()
  local w = NewMarket({ fillers = 1 })
  local ns = Boot(w)
  w.sellNeedsClick = true
  Bought(w, ns, LINEN, 5)
  w:CollectMail(LINEN, 5)
  w:OpenMerchant()
  w:Advance(3)
  eq(w:BagCount(LINEN), 5, "nothing sold")
  eq(LedgerCount(ns, "2589"), 5, "record kept when the sale was blocked")
  ok(w:ChatContains("blocked automatic selling"), "explains")
  local button = w.env.VendorDiffSellButton
  ok(button and button:IsShown(), "button shown")
  eq(button:GetText(), "Sell Vendor Diff items (5)", "with the count")
  w:Click(button)
  w:Advance(3)
  eq(w:BagCount(LINEN), 0, "sold with a click")
  eq(LedgerCount(ns, "2589"), 0, "record cleared")
  ok(not button:IsShown(), "button hidden when nothing is left")
end)

test("with auto-sell off, the Sell button and /vd sell do it", function()
  local w = NewMarket({ fillers = 1 })
  local ns = Boot(w)
  w.env.SlashCmdList.VENDORDIFF("autosell")
  eq(ns.db.autoSell, false, "auto-sell off")
  Bought(w, ns, LINEN, 3)
  w:CollectMail(LINEN, 3)
  w:OpenMerchant()
  w:Advance(3)
  eq(w:BagCount(LINEN), 3, "not sold automatically")
  ok(w.env.VendorDiffSellButton:IsShown(), "button offered")
  w.env.SlashCmdList.VENDORDIFF("sell")
  w:Advance(3)
  eq(w:BagCount(LINEN), 0, "/vd sell sold them")
end)

test("a mixed stack with no free bag slot is left alone and reported", function()
  local w = NewMarket({ fillers = 1 })
  local ns = Boot(w)
  Bought(w, ns, LINEN, 18)
  w:PutInBags(LINEN, 2)    -- 2 of your own
  w:CollectMail(LINEN, 18) -- stacks onto them: one stack of 20
  w:FillBags()
  w:OpenMerchant()
  w:Advance(5)
  eq(w:BagCount(LINEN), 20, "your 2 were not sold along with them")
  eq(LedgerCount(ns, "2589"), 18, "still tracked")
  ok(w:ChatContains("needs a free bag slot"), "explains how to fix it")
end)

test("/vd pending lists records and /vd forget drops them", function()
  local w = NewMarket({ fillers = 1 })
  local ns = Boot(w)
  local slash = w.env.SlashCmdList.VENDORDIFF
  slash("pending")
  ok(w:ChatContains("Nothing bought through Vendor Diff"), "empty list")
  Bought(w, ns, LINEN, 18)
  Bought(w, ns, SLOW, 2)
  w:CollectMail(LINEN, 6)
  slash("pending")
  ok(w:ChatContains("18x .*Linen Cloth.*%(6 ready to sell, 12 still in the mailbox%)"),
    "lists linen with what's collected and what's still in the mail")
  slash("forget 2589")
  eq(ns.charDB.ledger["2589"], nil, "linen forgotten")
  eq(LedgerCount(ns, "300"), 2, "others kept")
  slash("forget all")
  eq(next(ns.charDB.ledger), nil, "all forgotten")
end)

test("records older than 30 days are dropped", function()
  local w = NewMarket({ fillers = 1 })
  w.env.VendorDiffCharDB = { ledger = {
    ["2589"] = { itemID = LINEN, name = "Linen Cloth", count = 5, cost = 50, vendor = 65, boughtAt = 1000 - 31 * 86400 },
    ["300"] = { itemID = SLOW, name = "Slow Loader", count = 1, cost = 250, vendor = 1000, boughtAt = 1000 - 86400 },
  } }
  local ns = Boot(w)
  eq(ns.charDB.ledger["2589"], nil, "old record dropped")
  eq(LedgerCount(ns, "300"), 1, "recent record kept")
  ok(w:ChatContains("Stopped tracking 5x"), "says so")
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
