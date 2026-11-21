# Vendor Diff

A **World of Warcraft: Forever** addon that scans the Auction House for listings whose buyout price is **below what a vendor pays** for the item, and lets you buy them for guaranteed profit: buy, then sell to any vendor.

## Install

1. Copy the `VendorDiff` folder (the one containing `VendorDiff.toc`) into your WoW Forever installation's `Interface/AddOns/` folder.
2. **Fully restart the game.** On Forever, `/reload` does not pick up newly added addon folders.
3. Make sure *Vendor Diff* is enabled in the AddOns list on the character screen.

The TOC targets interface `16001` (Forever client 1.60.1). If the AddOns list marks it out of date after a patch, update the `## Interface:` line in `VendorDiff/VendorDiff.toc` to the value from `/dump select(4, GetBuildInfo())`.

## Use

1. Talk to an auctioneer. The Vendor Diff window opens next to the Auction House.
2. Click **Scan**. It reads the lowest price of every item on the Auction House in a few seconds, and you can scan as often as you like. The list fills with every item whose lowest price is below vendor price, sorted by profit.
   - Until you select an item, the scan only knows its *lowest* price, so **Qty** shows `?` and **Profit** is per unit (`ea`).
3. Click **Start** (or click a row). Vendor Diff runs a live search for that item to confirm the listings still exist at that price. The row then fills in the real quantity below vendor price and the total profit.
4. Click **Buy**.
   - **Gear and other non-stacking items** are bought one auction per click.
   - **Commodities** (stackable goods like cloth and herbs) take two clicks. **Buy** asks the server for the exact total price of every unit below vendor price. **Confirm** buys them. If the price has risen above vendor value by then, the purchase is cancelled.
5. When an item is used up, Vendor Diff moves to the next one and searches it automatically. Items that sold out since the scan are skipped.
6. Collect your purchases from the mailbox and sell them to a vendor.

Every purchase needs a click: Blizzard only allows buying from the Auction House in response to a key press or mouse click. Vendor Diff never buys on its own.

### Controls

| Action | Effect |
| --- | --- |
| Left-click row | Select the item and search its live listings |
| Shift-click row | Link the item in chat |
| Right-click row | Hide the item from this scan's results |
| Ctrl+Right-click row | Always ignore the item (`/vd unignore <id>` to undo) |
| Column header | Sort by that column (click again to reverse) |
| **Min profit per listing** | Hide listings that beat vendor price by less than this, e.g. `50s`, `1g 20s` (press Enter) |
| **Skip** | Drop the current item and move to the next |

### Slash commands

```
/vd                     toggle the window
/vd scan                start a full scan
/vd minprofit 50s       set the minimum profit per listing
/vd ignore <link|id>    never show an item
/vd unignore <link|id>  stop ignoring an item  (/vd unignore all clears the list)
/vd autoopen            toggle opening with the Auction House
/vd debug               print what the Auction House reports during searches and purchases
/vd buymode blizzard    buy through Blizzard's own "Buyout this item?" dialog (click Accept there)
/vd buymode direct      Vendor Diff places the bid itself (default)
/vd reset               reset the window position
```

The Buy button is a named frame (`VendorDiffBuyButton`), so a `/click VendorDiffBuyButton` macro bound to a key may work as well. This hasn't been tested on Forever.

## How it works

- **Scan:** sends an empty `C_AuctionHouse.SendBrowseQuery` and pages through the results with `RequestMoreBrowseResults`. This is the "summary" scan GoldScout uses on Forever. It returns every item with its lowest unit buyout, and unlike `ReplicateItems` it isn't limited to once every 15 minutes. Each item's lowest price is compared to its vendor sell price from `C_Item.GetItemInfo`, in small time slices so the game doesn't freeze. Items whose data isn't cached yet are retried for a few seconds.
- **Verify:** before you can buy, a live `C_AuctionHouse.SendSearchQuery` fetches the item's current listings. Only listings that are still below vendor price, and aren't your own, become buyable. The list row updates to the live numbers.
- **Buy:** `C_AuctionHouse.PlaceBid` for items. `StartCommoditiesPurchase` / `ConfirmCommoditiesPurchase` for commodities. After each purchase the item is searched again, so the next click always acts on fresh data.
- **Profit tracking:** a purchase is counted only once the gold actually leaves your bags. The session total appears at the bottom of the window.
- **Failed purchases:** if no gold leaves your bags, the status line says **Not bought** and chat lists everything the game reported for that click: the purchase call, blocked actions, Auction House errors, and dropped or queued requests. Turn on `/vd debug` to see the same information live.

## Caveats

- **Forever may block addon purchases.** On some clicks the Forever client refuses `C_AuctionHouse.PlaceBid` when an addon calls it, firing `ADDON_ACTION_BLOCKED`. Others have seen the same, while some addon purchases go through. If yours are blocked, try `/vd buymode blizzard`: Buy then opens Blizzard's own buyout confirmation, and Blizzard's code places the bid when you click **Accept**. If Blizzard's own Buyout button misbehaves after using that mode, `/reload` resets it.

- **Not yet tested in the live game.** It was built against Blizzard's generated API documentation for the Forever client (build 1.60.1.71037) and tested against a mock of that API (see below). Report anything that behaves oddly.
- **Settings may not persist on some Forever builds.** Some Forever builds write addon SavedVariables but don't load them at the next start. If that affects you, your min-profit setting and ignore list reset at login. Everything else works without saved data.
- **Gear vendor prices** are read from the specific item link. If an item's real sell price differs from what the client reports, the profit shown can be off. Hover a row to see the item's actual tooltip sell price.
- Blizzard's own Auction House window may also react to searches or commodity quotes that Vendor Diff makes. For example, its Buy tab may show the scan's full item list.
- **Sell tab:** while Blizzard's Sell tab is open, Vendor Diff holds its requests and won't buy. That tab throws an error if any Auction House request goes out while it's open. Switch to another tab and scanning carries on.
- An item can look like a deal in the scan when its lowest price is a bid-only auction or your own listing. The live search catches these, and Vendor Diff skips them automatically.
- Profit is vendor value minus buyout. It doesn't account for the trip to the mailbox and vendor.

## Development

The addon is plain Lua 5.1 with no libraries:

| File | Role |
| --- | --- |
| `VendorDiff/Core.lua` | Namespace, events, settings, money and vendor-price helpers, slash commands |
| `VendorDiff/Results.lua` | Deals grouped per item, min-profit filtering, sorting |
| `VendorDiff/Scan.lua` | Time-sliced full-scan processing with retries for uncached items |
| `VendorDiff/Backend_Modern.lua` | `C_AuctionHouse` scan, live search, and purchase calls |
| `VendorDiff/Buyer.lua` | The select, search, buy, confirm, next state machine |
| `VendorDiff/UI.lua` | The window |

Tests run the real addon files against a strict mock of the Forever client API (`tests/wowmock.lua`). The mock simulates the Auction House, slow-loading item data, the query throttle, and timers. It errors on unknown widget methods, unknown events, and any purchase call made outside a simulated click:

```bash
lua5.1 tests/run_tests.lua
```

```bash
luacheck VendorDiff
```

## Credits

The summary-scan approach and the Sell tab workaround follow [GoldScout](https://wowgoldscout.com) by Alkhara (MIT License), which documents how they work on the Forever client. Vendor Diff contains no GoldScout code.
