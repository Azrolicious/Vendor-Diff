-- Holds the deals found by a scan, grouped per item, and keeps a sorted view.
local _, ns = ...

local Results = {
  byKey = {},     -- key -> candidate
  sorted = {},    -- visible candidates, sorted
  sortKey = "profit",
  sortAscending = false,
  dirty = false,
}
ns.Results = Results

--[[ A candidate looks like:
{
  key = "123" | "123:ilvl",
  itemID, name, link, texture, quality,
  itemLevel,     -- gear: item level used to build the search item key
  listings = { {count=, cost=, vendor=}, ... },  -- every listing below vendor price
  -- derived from listings that pass the min-profit filter:
  auctions, quantity, cost, vendor, profit,
  live = true when listings came from a live search rather than the full scan
}
]]

function Results:Clear()
  wipe(self.byKey)
  wipe(self.sorted)
  self.dirty = false
  ns.Fire("RESULTS_CHANGED")
end

-- Record one listing. `info` is only read when the candidate is new.
function Results:AddListing(key, info, count, cost, vendor)
  local c = self.byKey[key]
  if not c then
    c = {
      key = key,
      itemID = info.itemID,
      name = info.name,
      link = info.link,
      texture = info.texture,
      quality = info.quality,
      itemLevel = info.itemLevel,
      listings = {},
    }
    self.byKey[key] = c
  end
  local l = c.listings
  l[#l + 1] = { count = count, cost = cost, vendor = vendor }
  self.dirty = true
end

-- Replace the scan data for a candidate with what a live search found.
function Results:SetLiveListings(key, listings)
  local c = self.byKey[key]
  if not c then return end
  c.listings = listings
  c.live = true
  self.dirty = true
  self:Rebuild()
end

function Results:Remove(key)
  if self.byKey[key] then
    self.byKey[key] = nil
    self.dirty = true
    self:Rebuild()
  end
end

function Results:RemoveItemID(itemID)
  local changed = false
  for key, c in pairs(self.byKey) do
    if c.itemID == itemID then
      self.byKey[key] = nil
      changed = true
    end
  end
  if changed then
    self.dirty = true
    self:Rebuild()
  end
end

function Results:Get(key)
  return self.byKey[key]
end

local SORTERS = {
  name = function(c) return c.name or "" end,
  auctions = function(c) return c.auctions end,
  quantity = function(c) return c.quantity end,
  cost = function(c) return c.cost end,
  vendor = function(c) return c.vendor end,
  profit = function(c) return c.profit end,
}

function Results:SetSort(sortKey)
  if not SORTERS[sortKey] then return end
  if self.sortKey == sortKey then
    self.sortAscending = not self.sortAscending
  else
    self.sortKey = sortKey
    -- Text sorts A-Z first, numbers biggest first.
    self.sortAscending = (sortKey == "name")
  end
  self.dirty = true
  self:Rebuild()
end

-- Recompute per-candidate totals from listings that pass the min-profit
-- filter, then re-sort. Fires RESULTS_CHANGED.
function Results:Rebuild()
  local minProfit = (ns.db and ns.db.minProfit) or 1
  local ignore = ns.db and ns.db.ignore or {}
  wipe(self.sorted)
  for _, c in pairs(self.byKey) do
    local auctions, quantity, cost, vendor = 0, 0, 0, 0
    if not ignore[c.itemID] then
      for _, l in ipairs(c.listings) do
        if l.vendor - l.cost >= minProfit then
          auctions = auctions + 1
          quantity = quantity + l.count
          cost = cost + l.cost
          vendor = vendor + l.vendor
        end
      end
    end
    c.auctions, c.quantity, c.cost, c.vendor = auctions, quantity, cost, vendor
    c.profit = vendor - cost
    if auctions > 0 then
      self.sorted[#self.sorted + 1] = c
    end
  end

  local getter = SORTERS[self.sortKey]
  local asc = self.sortAscending
  table.sort(self.sorted, function(a, b)
    local va, vb = getter(a), getter(b)
    if va ~= vb then
      if asc then return va < vb else return va > vb end
    end
    return a.key < b.key -- stable tie-break
  end)
  self.dirty = false
  ns.Fire("RESULTS_CHANGED")
end

function Results:RebuildIfDirty()
  if self.dirty then self:Rebuild() end
end

function Results:GetSorted()
  return self.sorted
end

function Results:IndexOf(key)
  for i, c in ipairs(self.sorted) do
    if c.key == key then return i end
  end
  return nil
end

function Results:Totals()
  local profit, cost = 0, 0
  for _, c in ipairs(self.sorted) do
    profit = profit + c.profit
    cost = cost + c.cost
  end
  return #self.sorted, profit, cost
end

ns.Listen("SETTINGS_CHANGED", function() Results:Rebuild() end)
