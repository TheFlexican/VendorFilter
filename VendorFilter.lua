--[[
VendorFilter
-------------
Adds a dynamic filter dropdown to the Merchant frame and a custom scrollable view of items
when a filter is active. Restores Blizzard’s grid when “All” is selected.

Architecture:
- Event frame (VF) listens for MERCHANT_SHOW / MERCHANT_UPDATE and rebuilds filters & list.
- Dynamic dropdown options computed from current vendor items (INVTYPE_* types).
- Overlay (FauxScrollFrame) shows filtered items with prices, currencies, availability, and Buy button.
- Buy button uses BuyMerchantItem directly (safe for extended costs, quantity=1) and supports Shift for stacks on gold-only purchases.

Junior dev tips:
- Avoid calling Blizzard helpers that expect their internal frames (e.g., MerchantFrame_ConfirmExtendedItemCost)
  from custom overlays. Drive purchases with BuyMerchantItem instead.
- To add new filters (e.g., by quality), extend BuildFilteredList() to check those attributes and
  ComputeAvailableFilters() to add labels.
]]

local ADDON_NAME = ...
local VF = CreateFrame("Frame", ADDON_NAME)

-- Saved vars
VendorFilterDB = VendorFilterDB or {}

VF.dynamicFilters = nil

--- Get current filter key ("ALL" or INVTYPE_*)
-- @return string
local function GetFilter()
  return VendorFilterDB.filter or "ALL"
end

--- Set current filter key
-- @param key string
local function SetFilter(key)
  VendorFilterDB.filter = key
end

-- Safe localized labels/fallbacks
local L = {
  BUY = (_G and _G.BUY) or "Buy",
  SOLD_OUT = (_G and _G.SOLD_OUT) or "Sold Out",
  AVAILABLE = (_G and _G.AVAILABLE) or "Available: %d",
  NOT_ENOUGH = "Insufficient currency",
}

--- Color a string red (safe across clients)
-- @param text string
-- @return string
local function ColorRed(text)
  if type(RED_FONT_COLOR) == "table" and RED_FONT_COLOR.WrapTextInColorCode then
    return RED_FONT_COLOR:WrapTextInColorCode(text)
  end
  return "|cffff2020" .. tostring(text) .. "|r"
end

--- Color a string green (safe across clients)
-- @param text string
-- @return string
local function ColorGreen(text)
  if type(GREEN_FONT_COLOR) == "table" and GREEN_FONT_COLOR.WrapTextInColorCode then
    return GREEN_FONT_COLOR:WrapTextInColorCode(text)
  end
  return "|cff20ff20" .. tostring(text) .. "|r"
end

--- Convert the current filter key to a user-facing label
-- @return string
local function GetFilterLabel()
  local key = GetFilter()
  if key == "ALL" then return "All" end
  -- Friendly label overrides
  if key == "INVTYPE_NON_EQUIP_IGNORE" then return "Misc (Currency/Satchels)" end
  if VF and VF.dynamicFilters then
    for _, f in ipairs(VF.dynamicFilters) do
      if f.key == key then return f.label end
    end
  end
  return _G[key] or key
end

--- Get the item equip location (INVTYPE_*) from an item link
-- Uses GetItemInfoInstant when available, falls back to GetItemInfo
-- @param itemLink string|nil
-- @return string|nil
local function GetEquipLocFromLink(itemLink)
  if not itemLink then return nil end
  -- prefer GetItemInfoInstant if available
  local ok, equipLoc
  if type(C_Item) == "table" and type(C_Item.GetItemInfoInstant) == "function" then
    local _, _, _, _, _, _, _, _, loc = C_Item.GetItemInfoInstant(itemLink)
    equipLoc = loc
  end
  if not equipLoc then
    local _, _, _, _, _, _, _, _, invType = GetItemInfo(itemLink)
    equipLoc = invType
  end
  return equipLoc
end

--- Convert INVTYPE_* to a localized label with overrides
-- @param loc string
-- @return string|nil
local function EquipLocToLabel(loc)
  if not loc or loc == "" then return nil end
  if loc == "INVTYPE_NON_EQUIP_IGNORE" then return "Misc (Currency/Satchels)" end
  return _G[loc] or loc
end

-- Try Blizzard refresh variants safely
--- Safely refresh the Blizzard Merchant UI using whatever functions are available
local function SafeMerchantRefresh()
  if type(MerchantFrame_UpdateMerchantInfo) == "function" then
    MerchantFrame_UpdateMerchantInfo()
  elseif type(MerchantFrame_Update) == "function" then
    MerchantFrame_Update()
  end
  if type(MerchantFrame_UpdateCurrencies) == "function" then
    MerchantFrame_UpdateCurrencies()
  end
end

-- Returns true if the item matches current filter
--- Check whether a merchant item passes the current filter
-- @param itemLink string|nil
-- @return boolean
function VF:ItemPasses(itemLink)
  local filter = GetFilter()
  if filter == "ALL" then return true end
  local equipLoc = GetEquipLocFromLink(itemLink)
  if not equipLoc then
    -- If item not cached yet, don't exclude it; keep it visible to avoid empty lists
    return true
  end
  return equipLoc == filter
end

-- Recompute filtered vendor indices
--- Build the filtered list of merchant item indices according to current filter
function VF:BuildFilteredList()
  local numItems = GetMerchantNumItems() or 0
  local filter = GetFilter()
  local showAll = filter == "ALL"
  local matching = {}
  for i = 1, numItems do
    local link = GetMerchantItemLink(i)
    if showAll or self:ItemPasses(link) then
      matching[#matching + 1] = i
    end
  end
  self._matching = matching
end

-- Build dynamic list of available filters from merchant items
--- Compute the dynamic set of available filter entries from current merchant items
function VF:ComputeAvailableFilters()
  local numItems = GetMerchantNumItems() or 0
  local counts = {}
  for i = 1, numItems do
    local link = GetMerchantItemLink(i)
    local loc = GetEquipLocFromLink(link)
    if loc and type(loc) == "string" and loc ~= "" then
      counts[loc] = (counts[loc] or 0) + 1
    end
  end
  local list = {}
  for loc, cnt in pairs(counts) do
    local label
    if loc == "INVTYPE_NON_EQUIP_IGNORE" then
      label = "Misc (Currency/Satchels)"
    else
      label = _G[loc] or loc
    end
    list[#list+1] = { key = loc, label = label, count = cnt }
  end
  table.sort(list, function(a,b) return tostring(a.label) < tostring(b.label) end)
  -- inject All at top
  table.insert(list, 1, { key = "ALL", label = "All", count = numItems })
  self.dynamicFilters = list

  -- Ensure current filter exists; otherwise revert to ALL
  local current = GetFilter()
  if current ~= "ALL" then
    local exists = false
    for _, f in ipairs(list) do if f.key == current then exists = true; break end end
    if not exists then SetFilter("ALL") end
  end
end

-- Create our overlay list using FauxScrollFrame (Classic compatible)
--- Create the overlay scrollable list for filtered items (once)
function VF:CreateOverlay()
  if self.overlay then return end
  if not MerchantFrame then return end

  local overlay = CreateFrame("Frame", "VendorFilterOverlay", MerchantFrame)
  overlay:SetPoint("TOPLEFT", MerchantFrame, "TOPLEFT", 22, -72)
  overlay:SetPoint("BOTTOMRIGHT", MerchantFrame, "BOTTOMRIGHT", -30, 86)

  local ROW_HEIGHT = 36
  overlay.ROW_HEIGHT = ROW_HEIGHT

  -- Scroll frame
  local scroll = CreateFrame("ScrollFrame", nil, overlay, "FauxScrollFrameTemplate")
  scroll:SetPoint("TOPLEFT", overlay, "TOPLEFT", 0, -2)
  scroll:SetPoint("BOTTOMRIGHT", overlay, "BOTTOMRIGHT", -26, 0)
  overlay.scroll = scroll

  -- Create row widgets
  overlay.rows = {}
  local function CreateRow(parent, index)
    local row = CreateFrame("Button", nil, parent)
    row:SetHeight(ROW_HEIGHT)
    row:SetPoint("LEFT", parent, "LEFT", 0, 0)
    row:SetPoint("RIGHT", parent, "RIGHT", -26, 0)
    if index == 1 then
      row:SetPoint("TOP", parent, "TOP", 0, 0)
    else
      row:SetPoint("TOP", parent.rows[index-1], "BOTTOM", 0, 0)
    end

    row.icon = row:CreateTexture(nil, "ARTWORK")
    row.icon:SetSize(32, 32)
    row.icon:SetPoint("LEFT", row, "LEFT", 2, 0)

  row.name = row:CreateFontString(nil, "ARTWORK", "GameFontNormal")
  row.name:SetPoint("LEFT", row.icon, "RIGHT", 8, 8)
  row.name:SetJustifyH("LEFT")
  row.name:SetWordWrap(false)

  row.sub = row:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
  row.sub:SetPoint("LEFT", row.icon, "RIGHT", 8, -8)
  row.sub:SetJustifyH("LEFT")
  row.sub:SetWordWrap(false)

  row.price = row:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
  row.price:SetJustifyH("RIGHT")

  row.buy = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
    row.buy:SetSize(60, 22)
    row.buy:SetPoint("RIGHT", row, "RIGHT", -4, 0)
  row.buy:SetText(L.BUY)
  row.price:SetPoint("RIGHT", row.buy, "LEFT", -6, 0)
  -- Constrain name/sub to price left to avoid overlap
  row.name:SetPoint("RIGHT", row.price, "LEFT", -8, 0)
  row.sub:SetPoint("RIGHT", row.price, "LEFT", -8, 0)

    row:SetScript("OnEnter", function() if row.vendorIndex then GameTooltip:SetOwner(row, "ANCHOR_RIGHT"); GameTooltip:SetMerchantItem(row.vendorIndex); GameTooltip:Show() end end)
    row:SetScript("OnLeave", function() GameTooltip:Hide() end)

    row.buy:SetScript("OnClick", function(self, mouseButton)
      local vIdx = row.vendorIndex
      if not vIdx then return end
      local qty = 1
      local _, _, _, _, _, _, extendedCost = GetMerchantItemInfo(vIdx)
      -- For extended-cost items, force quantity 1 (stack buys typically not supported)
      if not extendedCost then
        local getMax = _G.GetMerchantItemMaxStack
        if IsModifiedClick("SPLITSTACK") and type(getMax) == "function" then
          local maxStack = getMax(vIdx) or 1
          if maxStack > 1 then qty = maxStack end
        end
      end
      BuyMerchantItem(vIdx, qty)
    end)

    parent.rows[index] = row
    return row
  end

  -- Determine number of rows that fit
  local height = overlay:GetHeight() or 300
  local numRows = math.max(8, math.floor(height / ROW_HEIGHT))
  for i = 1, numRows do CreateRow(overlay, i) end
  overlay.numRows = numRows

  -- Update function
  overlay.Update = function()
    local list = VF._matching or {}
    local total = #list
    local offset = FauxScrollFrame_GetOffset(scroll)
    FauxScrollFrame_Update(scroll, total, overlay.numRows, ROW_HEIGHT)

    for i = 1, overlay.numRows do
      local row = overlay.rows[i]
      local idx = i + offset
      local vendorIndex = list[idx]
      if vendorIndex then
        local name, texture, price, stack, numAvailable, isUsable, extendedCost = GetMerchantItemInfo(vendorIndex)
        local link = GetMerchantItemLink(vendorIndex)
        local _, _, itemQuality, itemLevel, _, _, _, _, invType = GetItemInfo(link or "")
        row.vendorIndex = vendorIndex
        row.icon:SetTexture(texture or "Interface\\Icons\\INV_Misc_QuestionMark")
        if itemQuality and ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[itemQuality] then
          local c = ITEM_QUALITY_COLORS[itemQuality]
          row.name:SetText((c.hex or "")..(name or UNKNOWN).."|r")
        else
          row.name:SetText(name or UNKNOWN)
        end
        local subLeft = {}
        if stack and stack > 1 then table.insert(subLeft, string.format("x%d", stack)) end
    if numAvailable and numAvailable >= 0 then
          if numAvailable == 0 then
      table.insert(subLeft, ColorRed(L.SOLD_OUT))
          else
      table.insert(subLeft, string.format(L.AVAILABLE, numAvailable))
          end
        end
  if invType then table.insert(subLeft, EquipLocToLabel(invType)) end
        row.sub:SetText(table.concat(subLeft, "  "))
        -- Affordability check and cost text with colorization
        local moneyOK = (not price or price == 0 or (GetMoney and GetMoney() >= price))
        local extOK = true
        local parts = {}
        if price and price > 0 then
          local coinTxt = GetCoinTextureString(price)
          table.insert(parts, moneyOK and coinTxt or ColorRed(coinTxt))
        end
        if extendedCost then
          local costCount = GetMerchantItemCostInfo(vendorIndex) or 0
          for ci = 1, costCount do
            local tex, reqAmount, link, nameOrNil = GetMerchantItemCostItem(vendorIndex, ci)
            local icon = tex and ("|T"..tex..":16:16:0:0|t ") or ""
            local have = 0
            local isCurrency = link and link:find("currency:(%d+)")
            local isItem = link and link:find("item:(%d+)")
            if isCurrency then
              local id = tonumber(link:match("currency:(%d+)"))
              if id then
                if C_CurrencyInfo and C_CurrencyInfo.GetCurrencyInfo then
                  local info = C_CurrencyInfo.GetCurrencyInfo(id)
                  have = (info and (info.quantity or info.quantityEarned or info.quantityEarnedThisWeek)) or 0
                elseif GetCurrencyInfo then
                  local _, amt = GetCurrencyInfo(id)
                  have = amt or 0
                end
              end
            elseif isItem then
              local id = tonumber(link:match("item:(%d+)"))
              if id and GetItemCount then
                have = GetItemCount(id, false) or 0
              end
            end
            local need = reqAmount or 0
            local ok = have >= need and need > 0
            if not ok then extOK = false end
            local amtTxt = string.format("%d/%d", have, need)
            table.insert(parts, (ok and ColorGreen(icon .. amtTxt)) or ColorRed(icon .. amtTxt))
          end
        end
        row.price:SetText(table.concat(parts, "  +  "))

        -- Enable/disable buy button for availability and affordability
        local affordable = moneyOK and extOK and (not numAvailable or numAvailable ~= 0)
        row.affordable = affordable
        if affordable then row.buy:Enable() else row.buy:Disable() end

        -- Tooltip on buy: show detailed costs
        row.buy:SetScript("OnEnter", function()
          local vIdx = row.vendorIndex
          if not vIdx then return end
          local n2, _, price2, _, _, _, ext2 = GetMerchantItemInfo(vIdx)
          GameTooltip:SetOwner(row.buy, "ANCHOR_RIGHT")
          GameTooltip:SetText(L.BUY .. ": " .. (n2 or ""))
          if price2 and price2 > 0 then
            local moneyOK2 = (GetMoney and GetMoney() >= price2)
            local coinTxt = GetCoinTextureString(price2)
            GameTooltip:AddLine(moneyOK2 and coinTxt or ColorRed(coinTxt))
          end
          if ext2 then
            local costCount = GetMerchantItemCostInfo(vIdx) or 0
            for ci = 1, costCount do
              local tex, amount, link, nameOrNil = GetMerchantItemCostItem(vIdx, ci)
              local n = nameOrNil or (link and link:match("%[(.+)%]")) or ""
              local icon = tex and ("|T"..tex..":16:16:0:0|t ") or ""
              local have = 0
              local id = link and (link:match("currency:(%d+)") or link:match("item:(%d+)"))
              id = id and tonumber(id)
              if id and link:find("currency:") then
                if C_CurrencyInfo and C_CurrencyInfo.GetCurrencyInfo then
                  local info = C_CurrencyInfo.GetCurrencyInfo(id)
                  have = (info and info.quantity) or 0
                elseif GetCurrencyInfo then
                  local _, amt = GetCurrencyInfo(id)
                  have = amt or 0
                end
              elseif id and link:find("item:") and GetItemCount then
                have = GetItemCount(id, false) or 0
              end
              local ok = (have or 0) >= (amount or 0)
              local lineTxt = string.format("%s%s %s", icon, n, ok and ColorGreen(string.format("%d/%d", have, amount or 0)) or ColorRed(string.format("%d/%d", have, amount or 0)))
              GameTooltip:AddLine(lineTxt, 0.9, 0.9, 0.9)
            end
          end
          GameTooltip:Show()
        end)
        row.buy:SetScript("OnLeave", function() GameTooltip:Hide() end)
        row:Show()
      else
        row.vendorIndex = nil
        row:Hide()
      end
    end
  end

  scroll:SetScript("OnVerticalScroll", function(_, delta)
    FauxScrollFrame_OnVerticalScroll(scroll, delta, ROW_HEIGHT, overlay.Update)
  end)

  overlay:Hide()
  self.overlay = overlay
end

--- Hide Blizzard’s grid and show our filtered overlay
function VF:ShowOverlay()
  if not self.overlay then self:CreateOverlay() end
  if not self.overlay then return end
  -- Hide Blizzard item grid and paging
  local perPage = MERCHANT_ITEMS_PER_PAGE or 10
  for i = 1, perPage do
    local b = _G["MerchantItem"..i]
    if b then b:Hide() end
  end
  if MerchantPrevPageButton then MerchantPrevPageButton:Hide() end
  if MerchantNextPageButton then MerchantNextPageButton:Hide() end
  if MerchantPageText then MerchantPageText:Hide() end
  self.overlay:Show()
  self.overlay.Update()
end

--- Hide our overlay and restore Blizzard’s grid
function VF:HideOverlay()
  if self.overlay then self.overlay:Hide() end
  -- Show Blizzard item grid and paging back
  local perPage = MERCHANT_ITEMS_PER_PAGE or 10
  for i = 1, perPage do
    local b = _G["MerchantItem"..i]
    if b then b:Show() end
  end
  SafeMerchantRefresh()
  if MerchantPrevPageButton then MerchantPrevPageButton:Show() end
  if MerchantNextPageButton then MerchantNextPageButton:Show() end
  if MerchantPageText then MerchantPageText:Show() end
end

-- Main refresh entry
--- Refresh visible merchant UI based on current filter and vendor contents
function VF:Refresh()
  if not MerchantFrame or not MerchantFrame:IsShown() then return end
  self:BuildFilteredList()
  if GetFilter() == "ALL" then
    self:HideOverlay()
  else
    self:ShowOverlay()
  end
  -- update dropdown label if present
  if self.dropdown then
  UIDropDownMenu_SetText(self.dropdown, "Filter: " .. GetFilterLabel())
  end
end

-- Dropdown menu
--- Build the dropdown menu entries dynamically
-- @param frame Frame
-- @param level number
local function BuildMenu(frame, level)
  if not level then level = 1 end
  local info = UIDropDownMenu_CreateInfo()
  -- Recompute filters if missing
  if not VF.dynamicFilters then VF:ComputeAvailableFilters() end
  for _, f in ipairs(VF.dynamicFilters or {}) do
    wipe(info)
    info.text = f.label
    info.arg1 = f.key
    info.func = function(_, key)
      SetFilter(key)
  if MerchantFrame then MerchantFrame.page = 1 end
      VF:Refresh()
      CloseDropDownMenus()
    end
    info.checked = (GetFilter() == f.key)
    UIDropDownMenu_AddButton(info, level)
  end
end

-- Event handling
VF:SetScript("OnEvent", function(self, event, ...)
  if event == "ADDON_LOADED" then
    local addon = ...
    if addon == ADDON_NAME then
      VendorFilterDB.filter = VendorFilterDB.filter or "ALL"
    end
  elseif event == "MERCHANT_SHOW" or event == "MERCHANT_UPDATE" then
    if event == "MERCHANT_SHOW" then
      self:AttachUI()
    end
  self:ComputeAvailableFilters()
    self:Refresh()
  end
end)

VF:RegisterEvent("ADDON_LOADED")
VF:RegisterEvent("MERCHANT_SHOW")
VF:RegisterEvent("MERCHANT_UPDATE")

-- Create the dropdown and attach to MerchantFrame
--- Attach dropdown to MerchantFrame and initialize overlay (once)
function VF:AttachUI()
  if self.dropdown then return end
  if not MerchantFrame then return end

  local dd = CreateFrame("Frame", "VendorFilter_Dropdown", MerchantFrame, "UIDropDownMenuTemplate")
  dd:SetPoint("TOPLEFT", MerchantFrame, "TOPLEFT", 70, -34)
  UIDropDownMenu_SetWidth(dd, 150)
  UIDropDownMenu_SetText(dd, "Filter: " .. GetFilterLabel())
  UIDropDownMenu_Initialize(dd, function(frame, level) BuildMenu(frame, level) end)
  dd:SetScript("OnShow", function() UIDropDownMenu_SetText(dd, "Filter: " .. GetFilterLabel()) end)
  self.dropdown = dd

  self:CreateOverlay()
end
