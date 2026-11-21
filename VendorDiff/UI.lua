-- The Vendor Diff window.
local _, ns = ...

local UI = {}
ns.UI = UI

local WIDTH, HEIGHT = 640, 500
local ROW_HEIGHT = 20
local NUM_ROWS = 14
local SIDE = 16
local SCROLLBAR_WIDTH = 18
local LIST_TOP = -118

local COLUMNS = {
  { key = "name",     title = "Item",      width = 252, justify = "LEFT" },
  { key = "quantity", title = "Qty",       width = 60,  justify = "RIGHT" },
  { key = "price",    title = "Price ea",  width = 96,  justify = "RIGHT" },
  { key = "vendor",   title = "Vendor ea", width = 96,  justify = "RIGHT" },
  { key = "profit",   title = "Profit",    width = 100, justify = "RIGHT" },
}
local LIST_WIDTH = 0
for _, col in ipairs(COLUMNS) do LIST_WIDTH = LIST_WIDTH + col.width end

local BACKDROP = {
  bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
  edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
  tile = true, tileSize = 32, edgeSize = 32,
  insets = { left = 11, right = 12, top = 12, bottom = 11 },
}
local LIST_BACKDROP = {
  bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
  edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
  tile = true, tileSize = 16, edgeSize = 12,
  insets = { left = 3, right = 3, top = 3, bottom = 3 },
}

local offset = 0 -- index of the first visible row minus one

---------------------------------------------------------------------------
-- Construction
---------------------------------------------------------------------------
local function CreateText(parent, template, justify)
  local fs = parent:CreateFontString(nil, "OVERLAY", template or "GameFontHighlightSmall")
  fs:SetJustifyH(justify or "LEFT")
  fs:SetWordWrap(false)
  return fs
end

local function SavePosition(frame)
  local point, _, relPoint, x, y = frame:GetPoint(1)
  ns.db.position = { point, relPoint, x, y }
end

function UI:ApplyPosition()
  local f = self.frame
  f:ClearAllPoints()
  local pos = ns.db and ns.db.position
  if pos then
    f:SetPoint(pos[1], UIParent, pos[2], pos[3], pos[4])
    return
  end
  if AuctionHouseFrame and AuctionHouseFrame:IsShown() then
    f:SetPoint("TOPLEFT", AuctionHouseFrame, "TOPRIGHT", 4, 0)
  else
    f:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
  end
end

function UI:ResetPosition()
  if self.frame then self:ApplyPosition() end
end

function UI:Build()
  if self.frame then return end

  local f = CreateFrame("Frame", "VendorDiffFrame", UIParent, "BackdropTemplate")
  self.frame = f
  f:SetSize(WIDTH, HEIGHT)
  f:SetBackdrop(BACKDROP)
  f:SetFrameStrata("HIGH")
  f:SetToplevel(true)
  f:SetClampedToScreen(true)
  f:EnableMouse(true)
  f:SetMovable(true)
  if f.SetDontSavePosition then f:SetDontSavePosition(true) end
  f:RegisterForDrag("LeftButton")
  f:SetScript("OnDragStart", f.StartMoving)
  f:SetScript("OnDragStop", function(frame)
    frame:StopMovingOrSizing()
    SavePosition(frame)
  end)
  f:SetScript("OnShow", function() UI:Refresh() end)
  f:Hide()
  tinsert(UISpecialFrames, "VendorDiffFrame") -- close with Escape

  local title = CreateText(f, "GameFontNormalLarge", "CENTER")
  title:SetPoint("TOP", f, "TOP", 0, -18)
  title:SetText("Vendor Diff")

  local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
  close:SetPoint("TOPRIGHT", f, "TOPRIGHT", -6, -6)

  -- Scan button + scan status
  local scan = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
  scan:SetSize(110, 22)
  scan:SetPoint("TOPLEFT", f, "TOPLEFT", SIDE + 2, -44)
  scan:SetText("Scan")
  scan:SetScript("OnClick", function() ns.Scan:Start() end)
  scan:SetScript("OnEnter", function(btn)
    GameTooltip:SetOwner(btn, "ANCHOR_TOP")
    GameTooltip:SetText("Scan the Auction House")
    GameTooltip:AddLine("Reads the lowest price of every item on the Auction House and lists those "
      .. "below the vendor sell price. You can scan as often as you like.", 1, 1, 1, true)
    GameTooltip:AddLine("Quantities and total profit fill in when you select an item.", 1, 1, 1, true)
    GameTooltip:Show()
  end)
  scan:SetScript("OnLeave", GameTooltip_Hide)
  self.scanButton = scan

  local scanStatus = CreateText(f, "GameFontHighlightSmall")
  scanStatus:SetPoint("LEFT", scan, "RIGHT", 10, 0)
  scanStatus:SetWidth(WIDTH - 110 - SIDE * 2 - 24)
  self.scanStatus = scanStatus

  -- Min profit
  local mpLabel = CreateText(f, "GameFontNormalSmall")
  mpLabel:SetPoint("TOPLEFT", scan, "BOTTOMLEFT", 0, -12)
  mpLabel:SetText("Min profit per listing:")

  local mp = CreateFrame("EditBox", nil, f, "InputBoxTemplate")
  mp:SetSize(80, 20)
  mp:SetPoint("LEFT", mpLabel, "RIGHT", 10, 0)
  mp:SetAutoFocus(false)
  mp:SetMaxLetters(20)
  local function ApplyMinProfit(box)
    local amount = ns.ParseMoney(box:GetText())
    if amount and amount >= 1 then
      ns.db.minProfit = amount
      ns.Fire("SETTINGS_CHANGED")
    end
    box:SetText(ns.FormatMoneyPlain(ns.db.minProfit))
    box:ClearFocus()
  end
  mp:SetScript("OnEnterPressed", ApplyMinProfit)
  mp:SetScript("OnEditFocusLost", function(box)
    box:SetText(ns.FormatMoneyPlain(ns.db.minProfit))
  end)
  mp:SetScript("OnEscapePressed", function(box) box:ClearFocus() end)
  mp:SetScript("OnEnter", function(box)
    GameTooltip:SetOwner(box, "ANCHOR_TOP")
    GameTooltip:SetText("Minimum profit")
    GameTooltip:AddLine("Hide listings that beat the vendor price by less than this. Examples: 50s, 1g 20s, 75c. Press Enter to apply.", 1, 1, 1, true)
    GameTooltip:Show()
  end)
  mp:SetScript("OnLeave", GameTooltip_Hide)
  self.minProfitBox = mp

  local totals = CreateText(f, "GameFontHighlightSmall", "RIGHT")
  totals:SetPoint("LEFT", mp, "RIGHT", 10, 0)
  totals:SetWidth(WIDTH - SIDE * 2 - 260)
  self.totals = totals

  -- List area
  local list = CreateFrame("Frame", nil, f, "BackdropTemplate")
  list:SetPoint("TOPLEFT", f, "TOPLEFT", SIDE, LIST_TOP + 22)
  list:SetSize(LIST_WIDTH + SCROLLBAR_WIDTH + 10, NUM_ROWS * ROW_HEIGHT + 30)
  list:SetBackdrop(LIST_BACKDROP)
  list:SetBackdropColor(0, 0, 0, 0.6)
  list:EnableMouseWheel(true)
  list:SetScript("OnMouseWheel", function(_, delta)
    UI.scrollBar:SetValue(UI.scrollBar:GetValue() - delta * 3)
  end)
  self.list = list

  -- Column headers (click to sort)
  self.headers = {}
  local x = 4
  for _, col in ipairs(COLUMNS) do
    local h = CreateFrame("Button", nil, list)
    h:SetSize(col.width, 18)
    h:SetPoint("TOPLEFT", list, "TOPLEFT", x, -4)
    local text = CreateText(h, "GameFontNormalSmall", col.justify)
    text:SetPoint("LEFT", h, "LEFT", 4, 0)
    text:SetPoint("RIGHT", h, "RIGHT", -4, 0)
    text:SetText(col.title)
    h.text = text
    local arrow = h:CreateTexture(nil, "OVERLAY")
    arrow:SetTexture("Interface\\Buttons\\UI-SortArrow")
    arrow:SetSize(9, 8)
    arrow:SetPoint("LEFT", h, "LEFT", 0, 0) -- repositioned in RefreshHeaders
    arrow:Hide()
    h.arrow = arrow
    h.col = col
    h:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
    h:SetScript("OnClick", function() ns.Results:SetSort(col.key) end)
    self.headers[#self.headers + 1] = h
    x = x + col.width
  end

  -- Rows
  self.rows = {}
  for i = 1, NUM_ROWS do
    local row = CreateFrame("Button", nil, list)
    row:SetSize(LIST_WIDTH, ROW_HEIGHT)
    row:SetPoint("TOPLEFT", list, "TOPLEFT", 4, -24 - (i - 1) * ROW_HEIGHT)
    row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")

    local sel = row:CreateTexture(nil, "BACKGROUND")
    sel:SetAllPoints(row)
    sel:SetColorTexture(1, 0.82, 0, 0.18)
    sel:Hide()
    row.selected = sel

    local icon = row:CreateTexture(nil, "ARTWORK")
    icon:SetSize(ROW_HEIGHT - 2, ROW_HEIGHT - 2)
    icon:SetPoint("LEFT", row, "LEFT", 2, 0)
    row.icon = icon

    row.cells = {}
    local cx = 0
    for c, col in ipairs(COLUMNS) do
      local fs = CreateText(row, "GameFontHighlightSmall", col.justify)
      if c == 1 then
        fs:SetPoint("LEFT", row, "LEFT", ROW_HEIGHT + 4, 0)
        fs:SetWidth(col.width - ROW_HEIGHT - 8)
      else
        fs:SetPoint("LEFT", row, "LEFT", cx + 4, 0)
        fs:SetWidth(col.width - 8)
      end
      row.cells[c] = fs
      cx = cx + col.width
    end

    row:SetScript("OnClick", function(btn, mouseButton) UI:OnRowClick(btn, mouseButton) end)
    row:SetScript("OnEnter", function(btn) UI:OnRowEnter(btn) end)
    row:SetScript("OnLeave", GameTooltip_Hide)
    self.rows[i] = row
  end

  local empty = CreateText(list, "GameFontDisable", "CENTER")
  empty:SetPoint("CENTER", list, "CENTER", 0, 0)
  empty:SetWidth(LIST_WIDTH - 40)
  empty:SetWordWrap(true)
  self.emptyText = empty

  -- Scroll bar
  local bar = CreateFrame("Slider", nil, list, "BackdropTemplate")
  bar:SetOrientation("VERTICAL")
  bar:SetPoint("TOPRIGHT", list, "TOPRIGHT", -4, -24)
  bar:SetPoint("BOTTOMRIGHT", list, "BOTTOMRIGHT", -4, 6)
  bar:SetWidth(SCROLLBAR_WIDTH - 2)
  bar:SetBackdrop({
    bgFile = "Interface\\Buttons\\UI-SliderBar-Background",
    edgeFile = "Interface\\Buttons\\UI-SliderBar-Border",
    tile = true, tileSize = 8, edgeSize = 8,
    insets = { left = 3, right = 3, top = 6, bottom = 6 },
  })
  bar:SetThumbTexture("Interface\\Buttons\\UI-ScrollBar-Knob")
  bar:SetMinMaxValues(0, 0)
  bar:SetValueStep(1)
  if bar.SetObeyStepOnDrag then bar:SetObeyStepOnDrag(true) end
  bar:SetValue(0)
  bar:SetScript("OnValueChanged", function(_, value)
    local newOffset = math.floor(value + 0.5)
    if newOffset ~= offset then
      offset = newOffset
      UI:RefreshRows()
    end
  end)
  self.scrollBar = bar

  -- Bottom: purchase status, session totals, buttons
  local buyStatus = CreateText(f, "GameFontHighlight")
  buyStatus:SetPoint("TOPLEFT", list, "BOTTOMLEFT", 4, -8)
  buyStatus:SetSize(WIDTH - SIDE * 2 - 12, 30)
  buyStatus:SetWordWrap(true)
  buyStatus:SetJustifyV("TOP")
  self.buyStatus = buyStatus

  local buy = CreateFrame("Button", "VendorDiffBuyButton", f, "UIPanelButtonTemplate")
  buy:SetSize(150, 26)
  buy:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -SIDE - 2, 16)
  buy:SetScript("OnClick", function() ns.Buyer:OnClick() end)
  buy:SetScript("OnEnter", function(btn)
    GameTooltip:SetOwner(btn, "ANCHOR_TOP")
    GameTooltip:SetText("Buy")
    GameTooltip:AddLine("Each click buys the next listing shown above. Commodities take two clicks: Buy fetches the exact price, Confirm buys.", 1, 1, 1, true)
    GameTooltip:Show()
  end)
  buy:SetScript("OnLeave", GameTooltip_Hide)
  self.buyButton = buy

  local skip = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
  skip:SetSize(80, 26)
  skip:SetPoint("RIGHT", buy, "LEFT", -6, 0)
  skip:SetText("Skip")
  skip:SetScript("OnClick", function() ns.Buyer:Skip() end)
  self.skipButton = skip

  local session = CreateText(f, "GameFontNormalSmall")
  session:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", SIDE + 4, 34)
  session:SetWidth(WIDTH - SIDE * 2 - 250)
  self.sessionText = session

  local hint = CreateText(f, "GameFontDisableSmall")
  hint:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", SIDE + 4, 20)
  hint:SetWidth(WIDTH - SIDE * 2 - 250)
  hint:SetText("Right-click: hide  |  Ctrl+Right-click: always ignore  |  Shift-click: link")
  self.hintText = hint

  self:ApplyPosition()
end

---------------------------------------------------------------------------
-- Row interaction
---------------------------------------------------------------------------
function UI:OnRowClick(row, mouseButton)
  local cand = row.candidate
  if not cand then return end
  if mouseButton == "RightButton" then
    if IsControlKeyDown() then
      ns.db.ignore[cand.itemID] = true
      ns.Print(("Ignoring %s. Undo with /vd unignore %d"):format(cand.link or ns.Buyer.ItemText(cand), cand.itemID))
    end
    if ns.Buyer:GetTargetKey() == cand.key then
      ns.Buyer:Skip()
    end
    if IsControlKeyDown() then
      ns.Results:RemoveItemID(cand.itemID)
    else
      ns.Results:Remove(cand.key)
    end
    return
  end
  if IsModifiedClick() and cand.link and HandleModifiedItemClick(cand.link) then
    return
  end
  ns.Buyer:Select(cand.key)
end

function UI:OnRowEnter(row)
  local cand = row.candidate
  if not cand then return end
  GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
  if cand.link then
    GameTooltip:SetHyperlink(cand.link)
  else
    GameTooltip:SetItemByID(cand.itemID)
  end
  GameTooltip:AddLine(" ")
  local function Line(label, value, r, g, b)
    GameTooltip:AddDoubleLine(label, value, 1, 0.82, 0, r or 1, g or 1, b or 1)
  end
  if cand.estimate then
    Line("Lowest price:", ns.FormatMoney(cand.unitPrice) .. " each")
    Line("Vendor price:", ns.FormatMoney(cand.unitVendor) .. " each")
    Line("Profit:", "at least " .. ns.FormatMoney(cand.profit), 0.2, 1, 0.2)
    if cand.listed then Line("Listed in total:", cand.listed) end
    GameTooltip:AddLine("Click to check how many are below vendor price.", 0.6, 0.8, 1, true)
  else
    Line("Below vendor price:", ("%d listings, %d units"):format(cand.auctions, cand.quantity))
    Line("Buyout total:", ns.FormatMoney(cand.cost))
    Line("Vendor value:", ns.FormatMoney(cand.vendor))
    Line("Profit:", ns.FormatMoney(cand.profit), 0.2, 1, 0.2)
  end
  GameTooltip:Show()
end

---------------------------------------------------------------------------
-- Refresh
---------------------------------------------------------------------------
function UI:RefreshHeaders()
  for _, h in ipairs(self.headers) do
    local active = ns.Results.sortKey == h.col.key
    if active then
      h.text:SetTextColor(1, 1, 1)
      h.arrow:ClearAllPoints()
      if h.col.justify == "RIGHT" then
        h.arrow:SetPoint("RIGHT", h, "RIGHT", -6 - h.text:GetStringWidth(), 0)
      else
        h.arrow:SetPoint("LEFT", h, "LEFT", 8 + h.text:GetStringWidth(), 0)
      end
      if ns.Results.sortAscending then
        h.arrow:SetTexCoord(0, 0.5625, 1, 0)
      else
        h.arrow:SetTexCoord(0, 0.5625, 0, 1)
      end
      h.arrow:Show()
    else
      h.text:SetTextColor(1, 0.82, 0)
      h.arrow:Hide()
    end
  end
end

function UI:RefreshRows()
  local data = ns.Results:GetSorted()
  local maxOffset = math.max(0, #data - NUM_ROWS)
  if offset > maxOffset then offset = maxOffset end
  self.scrollBar:SetMinMaxValues(0, maxOffset)
  if math.floor(self.scrollBar:GetValue() + 0.5) ~= offset then
    self.scrollBar:SetValue(offset)
  end
  if maxOffset > 0 then self.scrollBar:Show() else self.scrollBar:Hide() end

  local selectedKey = ns.Buyer:GetTargetKey()
  for i, row in ipairs(self.rows) do
    local cand = data[offset + i]
    row.candidate = cand
    if cand then
      row.icon:SetTexture(cand.texture or "Interface\\Icons\\INV_Misc_QuestionMark")
      local name = cand.name or ("item:" .. cand.itemID)
      if cand.itemLevel then name = name .. " (" .. cand.itemLevel .. ")" end
      row.cells[1]:SetText(ns.QualityColor(cand.quality) .. name .. "|r")
      row.cells[3]:SetText(ns.FormatMoney(cand.unitPrice))
      row.cells[4]:SetText(ns.FormatMoney(cand.unitVendor))
      if cand.estimate then
        -- From the scan we only know the lowest price: show per-unit profit.
        row.cells[2]:SetText("|cff999999?|r")
        row.cells[5]:SetText("|cff33ff33" .. ns.FormatMoney(cand.profit) .. "|r|cff999999 ea|r")
      else
        row.cells[2]:SetText(cand.quantity)
        row.cells[5]:SetText("|cff33ff33" .. ns.FormatMoney(cand.profit) .. "|r")
      end
      if cand.key == selectedKey then row.selected:Show() else row.selected:Hide() end
      row:Show()
    else
      row:Hide()
    end
  end

  if #data == 0 then
    local msg
    if ns.Scan.running then
      msg = "Scanning..."
    elseif not ns.ahOpen then
      msg = "Open the Auction House, then press Scan."
    else
      msg = "No listings below vendor price yet. Press Scan."
    end
    self.emptyText:SetText(msg)
    self.emptyText:Show()
  else
    self.emptyText:Hide()
  end
end

function UI:RefreshTotals()
  local count, profit = ns.Results:Totals()
  if count > 0 then
    self.totals:SetText(("%d items  |  |cff33ff33profit at least %s|r"):format(count, ns.FormatMoney(profit)))
  else
    self.totals:SetText("")
  end
end

function UI:RefreshScan()
  local scanning = ns.Scan.running
  if scanning or not ns.ahOpen then
    self.scanButton:Disable()
  else
    self.scanButton:Enable()
  end
  if scanning and ns.Scan.total > 0 then
    self.scanStatus:SetText(("Checking vendor prices... %d / %d items"):format(ns.Scan.progress, ns.Scan.total))
  else
    local text = ns.Scan.statusText
    if not text then
      if not ns.backend then
        text = "This client's Auction House isn't supported."
      elseif not ns.ahOpen then
        text = "Open the Auction House to scan."
      else
        text = "Ready to scan."
      end
    end
    self.scanStatus:SetText(text)
  end
end

function UI:RefreshBuyer()
  local label, enabled = ns.Buyer:GetAction()
  self.buyButton:SetText(label)
  if enabled then self.buyButton:Enable() else self.buyButton:Disable() end
  if ns.Buyer.target then self.skipButton:Enable() else self.skipButton:Disable() end
  self.buyStatus:SetText(ns.Buyer.message or "")

  local s = ns.Buyer.session
  if s.purchases > 0 then
    self.sessionText:SetText(("Session: %d purchases, spent %s, vendor value %s, |cff33ff33profit %s|r"):format(
      s.purchases, ns.FormatMoney(s.spent), ns.FormatMoney(s.value), ns.FormatMoney(s.value - s.spent)))
  else
    self.sessionText:SetText("")
  end
end

function UI:Refresh()
  if not (self.frame and self.frame:IsShown()) then return end
  self.minProfitBox:SetText(ns.FormatMoneyPlain(ns.db.minProfit))
  self:RefreshHeaders()
  self:RefreshRows()
  self:RefreshTotals()
  self:RefreshScan()
  self:RefreshBuyer()
end

---------------------------------------------------------------------------
-- Show / hide
---------------------------------------------------------------------------
function UI:Show()
  self:Build()
  self.frame:Show()
end

function UI:Hide()
  if self.frame then self.frame:Hide() end
end

function UI:Toggle()
  self:Build()
  if self.frame:IsShown() then self.frame:Hide() else self.frame:Show() end
end

local function IfShown(fn)
  return function(...)
    if UI.frame and UI.frame:IsShown() then fn(UI, ...) end
  end
end

ns.Listen("RESULTS_CHANGED", IfShown(function(self)
  self:RefreshHeaders()
  self:RefreshRows()
  self:RefreshTotals()
end))
ns.Listen("BUYER_CHANGED", IfShown(function(self)
  self:RefreshRows() -- selection highlight
  self:RefreshBuyer()
end))
ns.Listen("SCAN_STATUS", IfShown(UI.RefreshScan))
ns.Listen("SCAN_STARTED", IfShown(UI.Refresh))
ns.Listen("SCAN_FINISHED", IfShown(UI.Refresh))

-- Progress updates come every frame during a scan; only redraw a few times a second.
local lastProgressDraw = 0
ns.Listen("SCAN_PROGRESS", IfShown(function(self)
  local now = GetTime()
  if now - lastProgressDraw > 0.2 then
    lastProgressDraw = now
    self:RefreshScan()
    ns.Results:RebuildIfDirty()
  end
end))

ns.Listen("AH_OPENED", function()
  ns.Scan.statusText = nil
  -- Wait a frame: Blizzard shows its Auction House frame from the same event,
  -- and we want to dock next to it.
  C_Timer.After(0, function()
    if not ns.ahOpen then return end
    if ns.db.autoOpen then
      UI:Build()
      UI:ApplyPosition()
      UI.frame:Show()
    end
    UI:Refresh()
  end)
end)

ns.Listen("AH_CLOSED", function()
  ns.Scan.statusText = nil
  if ns.db.autoOpen then
    UI:Hide()
  else
    UI:Refresh()
  end
end)

