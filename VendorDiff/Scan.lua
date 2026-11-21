-- Full-scan processor. The backend (Backend_Modern.lua) supplies the raw
-- auction data; this file decides which listings are below vendor price.
--
-- Backend contract:
--   backend.firstIndex            0 or 1
--   backend.gearPriceByLink       true if gear vendor price should come from the item link
--   backend:CanFullScan(force)    -> ok, reason
--   backend:RequestFullScan(cb)   cb(success, err) once data is available
--   backend:GetCount()            number of entries available right now
--   backend:ReadEntry(i)          -> itemID, count, buyout (cheap, called for every auction)
--   backend:GetEntryLink(i)       -> item link
--   backend:DescribeEntry(i, itemID, isGear, link)
--                                 -> key, info  | nil (data not loaded yet) | false (skip, e.g. own auction)
--   backend:IsScanDataValid()     -> false if the data was replaced mid-scan
local _, ns = ...

local Scan = {
  running = false,
  token = 0,
  progress = 0,
  total = 0,
}
ns.Scan = Scan

local FRAME_BUDGET_MS = 12   -- work per frame before yielding
local RETRY_DELAY = 1.5      -- seconds between passes over entries whose item data was missing
local MAX_RETRY_PASSES = 20
local MAX_STALLED_PASSES = 4 -- give up after this many passes with no progress

local function Status(text)
  Scan.statusText = text
  ns.Fire("SCAN_STATUS", text)
end

function Scan:Start(force)
  if self.running then
    ns.Print("A scan is already running.")
    return
  end
  if not ns.ahOpen then
    Status("Open the Auction House to scan.")
    ns.Print("Open the Auction House first.")
    return
  end
  local backend = ns.backend
  if not backend then
    ns.Print("This game client has no Auction House API Vendor Diff understands.")
    return
  end
  local ok, reason = backend:CanFullScan(force)
  if not ok then
    Status(reason)
    ns.Print(reason)
    return
  end

  ns.Buyer:Reset()
  ns.Results:Clear()
  self.running = true
  self.token = self.token + 1
  self.progress, self.total = 0, 0
  ns.db.lastFullScan[ns.RealmKey()] = time()
  Status("Requesting a full scan from the server...")
  ns.Fire("SCAN_STARTED")

  local token = self.token
  backend:RequestFullScan(function(success, err)
    if token ~= self.token or not self.running then return end
    if not success then
      self:Finish(false, err)
    else
      self:BeginProcessing()
    end
  end)
end

function Scan:Abort(reason)
  if self.running then
    self:Finish(false, reason)
  end
end

function Scan:BeginProcessing()
  local backend = ns.backend
  self.nextIndex = backend.firstIndex
  self.pending = {}
  self.gearCache = {}
  self.checked = 0
  self.deals = 0
  self.retryPass = 0
  self.stalled = 0
  self.startedAt = GetTime()
  Status("Processing auctions...")
  self:ProcessChunk(self.token)
end

-- Returns true when the entry is fully handled, false if it must be retried
-- because item data wasn't available yet.
function Scan:ProcessEntry(i)
  local backend = ns.backend
  local itemID, count, buyout = backend:ReadEntry(i)
  if not itemID then return false end
  if not buyout or buyout <= 0 or not count or count <= 0 then return true end -- bid-only
  if ns.db.ignore[itemID] then return true end

  local isGear = self.gearCache[itemID]
  if isGear == nil then
    isGear = ns.IsGear(itemID) and true or false
    self.gearCache[itemID] = isGear
  end

  local unitPrice, link
  if isGear and backend.gearPriceByLink then
    link = backend:GetEntryLink(i)
    if not link then return false end
    unitPrice = ns.GetVendorPrice(link)
  else
    unitPrice = ns.GetVendorPrice(itemID)
  end
  if unitPrice == nil then
    ns.RequestItemData(itemID)
    return false
  end

  local vendor = unitPrice * count
  if buyout >= vendor then return true end

  local key, info = backend:DescribeEntry(i, itemID, isGear, link)
  if key == nil then
    ns.RequestItemData(itemID)
    return false
  end
  if key == false then return true end -- e.g. our own auction

  ns.Results:AddListing(key, info, count, buyout, vendor)
  self.deals = self.deals + 1
  return true
end

function Scan:ProcessChunk(token)
  if token ~= self.token or not self.running then return end
  local backend = ns.backend
  if not backend:IsScanDataValid() then
    self:Finish(false, "The scan data was replaced before it was processed. Avoid searching the Auction House during a scan.")
    return
  end

  local started = debugprofilestop()
  local first = backend.firstIndex
  local last = first + backend:GetCount() - 1 -- re-read: data can still be arriving
  local i = self.nextIndex
  local pending = self.pending
  while i <= last do
    if not self:ProcessEntry(i) then
      pending[#pending + 1] = i
    end
    self.checked = self.checked + 1
    i = i + 1
    if i % 250 == 0 and debugprofilestop() - started > FRAME_BUDGET_MS then
      break
    end
  end
  self.nextIndex = i
  self.progress, self.total = i - first, last - first + 1
  ns.Fire("SCAN_PROGRESS", self.progress, self.total)

  if i <= last then
    C_Timer.After(0, function() self:ProcessChunk(token) end)
  else
    ns.Results:Rebuild()
    self:ScheduleRetry(token)
  end
end

function Scan:ScheduleRetry(token)
  if #self.pending == 0 then
    self:Finish(true)
    return
  end
  if self.retryPass >= MAX_RETRY_PASSES or self.stalled >= MAX_STALLED_PASSES then
    self:Finish(true)
    return
  end
  Status(("Waiting for item data (%d auctions)..."):format(#self.pending))
  C_Timer.After(RETRY_DELAY, function() self:RetryChunk(token, 1, {}) end)
end

-- One pass over self.pending, time-sliced. Entries that still fail go to `still`.
function Scan:RetryChunk(token, pos, still)
  if token ~= self.token or not self.running then return end
  if not ns.backend:IsScanDataValid() then
    self:Finish(false, "The scan data was replaced before it was processed.")
    return
  end
  local started = debugprofilestop()
  local pending = self.pending
  while pos <= #pending do
    local i = pending[pos]
    if not self:ProcessEntry(i) then
      still[#still + 1] = i
    end
    pos = pos + 1
    if pos % 250 == 0 and debugprofilestop() - started > FRAME_BUDGET_MS then
      break
    end
  end
  if pos <= #pending then
    C_Timer.After(0, function() self:RetryChunk(token, pos, still) end)
    return
  end

  self.retryPass = self.retryPass + 1
  if #still >= #pending then
    self.stalled = self.stalled + 1
  else
    self.stalled = 0
  end
  self.pending = still
  ns.Results:Rebuild()
  self:ScheduleRetry(token)
end

function Scan:Finish(success, err)
  self.running = false
  self.token = self.token + 1
  ns.Results:Rebuild()
  if success then
    local count, profit = ns.Results:Totals()
    local skipped = self.pending and #self.pending or 0
    local msg = ("Scan complete: %d auctions checked, %d items below vendor price (%s potential profit)."):format(
      self.checked or 0, count, ns.FormatMoney(profit))
    if skipped > 0 then
      msg = msg .. (" %d auctions skipped (item data never loaded)."):format(skipped)
    end
    Status(msg)
    ns.Print(msg)
  else
    local msg = "Scan failed: " .. (err or "unknown error")
    Status(msg)
    ns.Print(msg)
  end
  self.pending = nil
  self.gearCache = nil
  ns.Fire("SCAN_FINISHED", success)
end

ns.Listen("AH_CLOSED", function()
  Scan:Abort("the Auction House was closed.")
end)
