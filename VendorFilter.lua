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

-- ============================================================
-- Spec Filter Data
-- Armor subClassIDs (locale-safe, matches C_Item.GetItemInfoInstant classID=4)
-- ============================================================
local CLOTH    = 1
local LEATHER  = 2
local MAIL     = 3
local PLATE    = 4
local ITEM_CLASS_ARMOR = 4

--- All playable class/spec definitions with the armor type each spec wears.
-- armorType = itemSubClassID: 1=Cloth, 2=Leather, 3=Mail, 4=Plate
local SPEC_DATA = {
  -- Warrior
  { key="WARRIOR_ARMS",     label="Arms Warrior",          class="Warrior",      armorType=PLATE   },
  { key="WARRIOR_FURY",     label="Fury Warrior",          class="Warrior",      armorType=PLATE   },
  { key="WARRIOR_PROT",     label="Protection Warrior",    class="Warrior",      armorType=PLATE   },
  -- Paladin
  { key="PALADIN_HOLY",     label="Holy Paladin",          class="Paladin",      armorType=PLATE   },
  { key="PALADIN_PROT",     label="Protection Paladin",    class="Paladin",      armorType=PLATE   },
  { key="PALADIN_RET",      label="Retribution Paladin",   class="Paladin",      armorType=PLATE   },
  -- Hunter
  { key="HUNTER_BM",        label="Beast Mastery Hunter",  class="Hunter",       armorType=MAIL    },
  { key="HUNTER_MM",        label="Marksmanship Hunter",   class="Hunter",       armorType=MAIL    },
  { key="HUNTER_SV",        label="Survival Hunter",       class="Hunter",       armorType=MAIL    },
  -- Rogue
  { key="ROGUE_ASSA",       label="Assassination Rogue",   class="Rogue",        armorType=LEATHER },
  { key="ROGUE_COMBAT",     label="Combat Rogue",          class="Rogue",        armorType=LEATHER },
  { key="ROGUE_SUB",        label="Subtlety Rogue",        class="Rogue",        armorType=LEATHER },
  -- Priest
  { key="PRIEST_DISC",      label="Discipline Priest",     class="Priest",       armorType=CLOTH   },
  { key="PRIEST_HOLY",      label="Holy Priest",           class="Priest",       armorType=CLOTH   },
  { key="PRIEST_SHADOW",    label="Shadow Priest",         class="Priest",       armorType=CLOTH   },
  -- Death Knight (WotLK+)
  { key="DK_BLOOD",         label="Blood Death Knight",    class="Death Knight", armorType=PLATE   },
  { key="DK_FROST",         label="Frost Death Knight",    class="Death Knight", armorType=PLATE   },
  { key="DK_UNHOLY",        label="Unholy Death Knight",   class="Death Knight", armorType=PLATE   },
  -- Shaman
  { key="SHAMAN_ELE",       label="Elemental Shaman",      class="Shaman",       armorType=MAIL    },
  { key="SHAMAN_ENH",       label="Enhancement Shaman",    class="Shaman",       armorType=MAIL    },
  { key="SHAMAN_RESTO",     label="Restoration Shaman",    class="Shaman",       armorType=MAIL    },
  -- Mage
  { key="MAGE_ARCANE",      label="Arcane Mage",           class="Mage",         armorType=CLOTH   },
  { key="MAGE_FIRE",        label="Fire Mage",             class="Mage",         armorType=CLOTH   },
  { key="MAGE_FROST",       label="Frost Mage",            class="Mage",         armorType=CLOTH   },
  -- Warlock
  { key="WARLOCK_AFFLICT",  label="Affliction Warlock",    class="Warlock",      armorType=CLOTH   },
  { key="WARLOCK_DEMO",     label="Demonology Warlock",    class="Warlock",      armorType=CLOTH   },
  { key="WARLOCK_DESTRO",   label="Destruction Warlock",   class="Warlock",      armorType=CLOTH   },
  -- Monk (MoP+)
  { key="MONK_BREW",        label="Brewmaster Monk",       class="Monk",         armorType=LEATHER },
  { key="MONK_MW",          label="Mistweaver Monk",       class="Monk",         armorType=LEATHER },
  { key="MONK_WW",          label="Windwalker Monk",       class="Monk",         armorType=LEATHER },
  -- Druid
  { key="DRUID_BALANCE",    label="Balance Druid",         class="Druid",        armorType=LEATHER },
  { key="DRUID_FERAL",      label="Feral Druid",           class="Druid",        armorType=LEATHER },
  { key="DRUID_GUARDIAN",   label="Guardian Druid",        class="Druid",        armorType=LEATHER },
  { key="DRUID_RESTO",      label="Restoration Druid",     class="Druid",        armorType=LEATHER },
}
-- Fast lookup by key
local SPEC_BY_KEY = {}
for _, s in ipairs(SPEC_DATA) do SPEC_BY_KEY[s.key] = s end

--- Get current spec filter key
-- @return string
local function GetSpecFilter()
  return VendorFilterDB.specFilter or "ALL"
end

--- Set current spec filter key
-- @param key string
local function SetSpecFilter(key)
  VendorFilterDB.specFilter = key
end

--- Convert spec filter key to user-facing label
-- @return string
local function GetSpecFilterLabel()
  local key = GetSpecFilter()
  if key == "ALL" then return "All Specs" end
  local s = SPEC_BY_KEY[key]
  return s and s.label or key
end

--- Return the itemClassID and itemSubClassID for an item link (locale-safe).
-- Uses C_Item.GetItemInfoInstant when available; falls back to subType string matching (enUS).
-- @param itemLink string|nil
-- @return number|nil classID, number|nil subClassID
local function GetItemClassSubClass(itemLink)
  if not itemLink then return nil, nil end
  if C_Item and C_Item.GetItemInfoInstant then
    local _, _, _, _, _, classID, subClassID = C_Item.GetItemInfoInstant(itemLink)
    return classID, subClassID
  end
  -- TBC fallback: parse localized strings (enUS)
  local _, _, _, _, _, itemType, itemSubType = GetItemInfo(itemLink)
  if itemType == "Armor" then
    if itemSubType == "Cloth"   then return 4, 1 end
    if itemSubType == "Leather" then return 4, 2 end
    if itemSubType == "Mail"    then return 4, 3 end
    if itemSubType == "Plate"   then return 4, 4 end
    return 4, 0  -- Shield, Misc armor, etc.
  end
  if itemType == "Weapon" then return 2, nil end
  return nil, nil
end

--- Check whether a merchant item passes the active spec filter.
-- Only Cloth/Leather/Mail/Plate armor is filtered; weapons, jewelry,
-- trinkets, cloaks, shields, and other non-armor items always pass.
-- @param itemLink string|nil
-- @return boolean
function VF:ItemPassesSpecFilter(itemLink)
  local specKey = GetSpecFilter()
  if specKey == "ALL" then return true end
  local spec = SPEC_BY_KEY[specKey]
  if not spec then return true end
  local classID, subClassID = GetItemClassSubClass(itemLink)
  if classID ~= ITEM_CLASS_ARMOR then return true end   -- weapons, jewelry, etc.
  if not subClassID or subClassID == 0 then return true end  -- shields, librams, misc armor
  return subClassID == spec.armorType
end

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
--- Build the filtered list of merchant item indices according to current slot and spec filters
function VF:BuildFilteredList()
  local numItems = GetMerchantNumItems() or 0
  local slotAll = GetFilter() == "ALL"
  local specAll = GetSpecFilter() == "ALL"
  local allOff  = slotAll and specAll
  local matching = {}
  for i = 1, numItems do
    local link = GetMerchantItemLink(i)
    if allOff or (self:ItemPasses(link) and self:ItemPassesSpecFilter(link)) then
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
  overlay:SetPoint("TOPLEFT", MerchantFrame, "TOPLEFT", 22, -90)
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

    -- Handle row clicks for chat linking (Shift) and dressing room preview (Ctrl)
    row:SetScript("OnClick", function(self, mouseButton)
      local vIdx = row.vendorIndex
      if not vIdx then return end
      local link = GetMerchantItemLink(vIdx)
      if not link then return end

      -- Shift-click: insert item link into chat
      if IsModifiedClick("CHATLINK") then
        if ChatEdit_InsertLink then
          ChatEdit_InsertLink(link)
        elseif ChatFrameEditBox and ChatFrameEditBox:IsShown() then
          ChatFrameEditBox:Insert(link)
        end
        return
      end

      -- Ctrl-click: open dressing room preview
      if IsModifiedClick("DRESSUP") then
        if DressUpItemLink then
          DressUpItemLink(link)
        elseif DressUpLink then
          DressUpLink(link)
        end
        return
      end
    end)

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
  if GetFilter() == "ALL" and GetSpecFilter() == "ALL" then
    self:HideOverlay()
  else
    self:ShowOverlay()
  end
  -- update dropdown labels if present
  if self.dropdown then
    UIDropDownMenu_SetText(self.dropdown, "Filter: " .. GetFilterLabel())
  end
  if self.specDropdown then
    UIDropDownMenu_SetText(self.specDropdown, "Spec: " .. GetSpecFilterLabel())
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

-- Spec dropdown menu builder
--- Build the spec filter dropdown entries (all classes/specs with class headers)
-- @param frame Frame
-- @param level number
local function BuildSpecMenu(frame, level)
  if not level then level = 1 end
  local info = UIDropDownMenu_CreateInfo()
  -- "All Specs" entry at top
  wipe(info)
  info.text        = "All Specs"
  info.arg1        = "ALL"
  info.func        = function(_, key)
    SetSpecFilter(key)
    if MerchantFrame then MerchantFrame.page = 1 end
    VF:Refresh()
    CloseDropDownMenus()
  end
  info.checked     = (GetSpecFilter() == "ALL")
  UIDropDownMenu_AddButton(info, level)
  -- Class headers with specs beneath
  local lastClass = nil
  for _, spec in ipairs(SPEC_DATA) do
    if spec.class ~= lastClass then
      lastClass = spec.class
      wipe(info)
      info.text          = spec.class
      info.isTitle       = true
      info.notCheckable  = true
      UIDropDownMenu_AddButton(info, level)
    end
    wipe(info)
    info.text  = "  " .. spec.label
    info.arg1  = spec.key
    info.func  = function(_, key)
      SetSpecFilter(key)
      if MerchantFrame then MerchantFrame.page = 1 end
      VF:Refresh()
      CloseDropDownMenus()
    end
    info.checked = (GetSpecFilter() == spec.key)
    UIDropDownMenu_AddButton(info, level)
  end
end

-- Event handling
VF:SetScript("OnEvent", function(self, event, ...)
  if event == "ADDON_LOADED" then
    local addon = ...
    if addon == ADDON_NAME then
      VendorFilterDB.filter     = VendorFilterDB.filter     or "ALL"
      VendorFilterDB.specFilter = VendorFilterDB.specFilter or "ALL"
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
--- Attach dropdowns to MerchantFrame and initialize overlay (once)
function VF:AttachUI()
  if self.dropdown then return end
  if not MerchantFrame then return end

  -- Slot filter dropdown (row 1)
  local dd = CreateFrame("Frame", "VendorFilter_Dropdown", MerchantFrame, "UIDropDownMenuTemplate")
  dd:SetPoint("TOPLEFT", MerchantFrame, "TOPLEFT", 70, -34)
  UIDropDownMenu_SetWidth(dd, 150)
  UIDropDownMenu_SetText(dd, "Filter: " .. GetFilterLabel())
  UIDropDownMenu_Initialize(dd, function(frame, level) BuildMenu(frame, level) end)
  dd:SetScript("OnShow", function() UIDropDownMenu_SetText(dd, "Filter: " .. GetFilterLabel()) end)
  self.dropdown = dd

  -- Spec filter dropdown (row 2, stacked below slot dropdown)
  local specDD = CreateFrame("Frame", "VendorFilter_SpecDropdown", MerchantFrame, "UIDropDownMenuTemplate")
  specDD:SetPoint("TOPLEFT", MerchantFrame, "TOPLEFT", 70, -56)
  UIDropDownMenu_SetWidth(specDD, 150)
  UIDropDownMenu_SetText(specDD, "Spec: " .. GetSpecFilterLabel())
  UIDropDownMenu_Initialize(specDD, function(frame, level) BuildSpecMenu(frame, level) end)
  specDD:SetScript("OnShow", function() UIDropDownMenu_SetText(specDD, "Spec: " .. GetSpecFilterLabel()) end)
  self.specDropdown = specDD

  self:CreateOverlay()
end
