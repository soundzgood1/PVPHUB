local _, PVPHUB = ...

-- Shared named font object used as the template for ALL data rows and column
-- headers. Updating this one object instantly changes every FontString that
-- uses "PVPHUBDataFont" as its template — no UpdateContent rebuild needed for
-- font-family changes. Font size changes still need a rebuild for layout.
PVPHUB.dataFont = CreateFont("PVPHUBDataFont")
PVPHUB.dataFont:SetFont("Fonts\\FRIZQT__.TTF", 12, "OUTLINE")
PVPHUB.dataFont:SetShadowColor(0, 0, 0, 0.7)
PVPHUB.dataFont:SetShadowOffset(1, -1)

-- Resolve a font name from the DB to its file path.
-- Always reads PVPHUB_SETTINGS so there is one source of truth.
local PVPHUB_BUILTIN_FONTS = {
    ["Friz Quadrata TT"] = "Fonts\\FRIZQT__.TTF",
    ["Arial Narrow"]     = "Fonts\\ARIALN.TTF",
    ["Morpheus"]         = "Fonts\\MORPHEUS.TTF",
    ["Skurri"]           = "Fonts\\skurri.ttf",
}
local function PVPHUB_ResolveFontPath(name)
    name = name or (PVPHUB_SETTINGS and PVPHUB_SETTINGS.selectedFont) or "Friz Quadrata TT"
    -- 1. PVPHUB bundled fonts (guaranteed to exist once files are in media/fonts/)
    if PVPHUB.bundledFonts and PVPHUB.bundledFontBase then
        for _, entry in ipairs(PVPHUB.bundledFonts) do
            if entry[1] == name then return PVPHUB.bundledFontBase .. entry[2] end
        end
    end
    -- 2. LibSharedMedia — read the raw hash table directly rather than using
    --    LSM:Fetch.  LSM:Fetch honours any global override set by font-manager
    --    addons (e.g. Fontmancer) which would silently return the wrong font.
    --    LSM:HashTable bypasses that override and always returns the real path.
    if LibStub then
        local LSM = LibStub("LibSharedMedia-3.0", true)
        if LSM and LSM.HashTable then
            local fontTable = LSM:HashTable("font")
            if fontTable and fontTable[name] then return fontTable[name] end
        end
    end
    -- 3. WoW built-in fonts
    return PVPHUB_BUILTIN_FONTS[name]
        or PVPHUB_BUILTIN_FONTS[(PVPHUB_SETTINGS and PVPHUB_SETTINGS.selectedFont) or "Friz Quadrata TT"]
        or "Fonts\\FRIZQT__.TTF"
end

-- Safe SetFont: applies a font with graceful fallback.
-- Sets IsFontmancerPreview = true before each call so Fontmancer's global
-- metatable hook (hooksecurefunc on FontString.SetFont) skips this instance.
-- Because StoreOriginals is never called for skipped instances, Fontmancer's
-- UpdateAllStoredInstances also never touches these FontStrings.
local function SafeSetFont(fontString, path, size, flags)
    if not fontString then return end
    path = path or PVPHUB_ResolveFontPath()
    fontString.IsFontmancerPreview = true   -- exempt from Fontmancer's hook
    local ok, result = pcall(function() return fontString:SetFont(path, size or 12, flags or "OUTLINE") end)
    if not (ok and result) then
        fontString:SetFont("Fonts\\FRIZQT__.TTF", size or 12, flags or "OUTLINE")
    end
end

-- Global registry of every FontString that should track the Appearance-tab
-- font selection: main window rows/headers, Settings/Stats tab chrome, hover
-- tooltips, the Queue Timer window — everything except Streamer Mode, which
-- keeps its own independent font setting (compactMode.selectedFont in
-- modules/compact.lua). Plain SetFont calls only apply once at creation, so
-- anything long-lived (pooled tooltip rows, settings labels built once when
-- a tab first opens) would otherwise keep whatever font was selected at the
-- time it was created. RegisterTrackedFont applies the current font
-- immediately and remembers the FontString so PVPHUB:RefreshTrackedFonts()
-- (called from ApplyFontChanges when the user picks a new font) can push the
-- change to it live.
PVPHUB._trackedFontStrings = PVPHUB._trackedFontStrings or {}
local function RegisterTrackedFont(fontString, size, flags)
    if not fontString then return fontString end
    size = size or 12
    flags = flags or "OUTLINE"
    table.insert(PVPHUB._trackedFontStrings, { fs = fontString, size = size, flags = flags })
    SafeSetFont(fontString, PVPHUB_ResolveFontPath(), size, flags)
    return fontString
end
PVPHUB._RegisterTrackedFont = RegisterTrackedFont
PVPHUB._ResolveFontPath = PVPHUB_ResolveFontPath
PVPHUB._SafeSetFont = SafeSetFont

function PVPHUB:RefreshTrackedFonts()
    local path = PVPHUB_ResolveFontPath()
    for _, entry in ipairs(PVPHUB._trackedFontStrings) do
        if entry.fs then
            SafeSetFont(entry.fs, path, entry.size, entry.flags)
        end
    end
end

-- Scrollable font picker used in both main-window settings panels.
-- Uses UIDropDownMenuTemplate + ApplyModernDropdownStyling for the button so it
-- looks identical to the Theme/Sort dropdowns, but replaces the click handler
-- with a custom scrollable popup instead of WoW's built-in dropdown list.
-- Returns the wrapper frame (for anchoring the next element below it).
local _fontPickerSeq = 0
function PVPHUB_CreateFontPicker(parent, anchorTo, anchorPoint, xOff, yOff, maxHeight, getSelected, onSelect, getFontList)
    _fontPickerSeq = _fontPickerSeq + 1
    local frameName = "PVPHUBFontPicker" .. _fontPickerSeq
    local rowH  = 22
    local width = 200
    local items = getFontList()

    -- UIDropDownMenuTemplate gives us the exact same visual shell as Theme/Sort.
    local wrapper = CreateFrame("Frame", frameName, parent, "UIDropDownMenuTemplate")
    wrapper:SetPoint("TOPLEFT", anchorTo, anchorPoint, xOff, yOff)
    UIDropDownMenu_SetWidth(wrapper, width - 32)
    UIDropDownMenu_SetText(wrapper, getSelected())
    -- Empty initializer so WoW never opens its own popup for this frame.
    UIDropDownMenu_Initialize(wrapper, function() end)
    -- ApplyModernDropdownStyling is a local defined later in this file; callers
    -- must apply it themselves after PVPHUB_CreateFontPicker returns.

    -- Hijack the toggle button so it opens our scrollable popup instead.
    local toggleBtn = wrapper.Button or _G[frameName .. "Button"]

    -- Click-catcher
    local catcher = CreateFrame("Frame", nil, UIParent)
    catcher:SetAllPoints(UIParent); catcher:EnableMouse(true)
    catcher:SetFrameStrata("FULLSCREEN_DIALOG"); catcher:SetFrameLevel(199); catcher:Hide()

    -- Popup
    local totalH = #items * rowH
    local popupH = maxHeight and math.min(totalH, maxHeight) or totalH
    local popup  = CreateFrame("Frame", nil, UIParent)
    popup:SetSize(width, popupH)
    popup:SetFrameStrata("FULLSCREEN_DIALOG"); popup:SetFrameLevel(200)
    popup:SetPoint("TOPLEFT", wrapper, "BOTTOMLEFT", 22, -2); popup:Hide()
    local popBg = popup:CreateTexture(nil, "BACKGROUND"); popBg:SetAllPoints()
    popBg:SetColorTexture(0.08, 0.08, 0.12, 0.97)
    local popBorderT = popup:CreateTexture(nil, "BORDER"); popBorderT:SetAllPoints()
    popBorderT:SetColorTexture(0.30, 0.30, 0.40, 0.8)
    local popInner = popup:CreateTexture(nil, "ARTWORK"); popInner:SetAllPoints()
    popInner:SetColorTexture(0.08, 0.08, 0.12, 0.97)
    popInner:SetPoint("TOPLEFT", 1, -1); popInner:SetPoint("BOTTOMRIGHT", -1, 1)

    -- Scroll support
    local rowParent
    if maxHeight and totalH > maxHeight then
        local sf = CreateFrame("ScrollFrame", nil, popup)
        sf:SetPoint("TOPLEFT", 1, -1); sf:SetPoint("BOTTOMRIGHT", -1, 1)
        sf:EnableMouseWheel(true)
        local sc = CreateFrame("Frame", nil, sf)
        sc:SetSize(width - 2, totalH)
        sf:SetScrollChild(sc)
        sf:SetScript("OnMouseWheel", function(self, delta)
            local cur = self:GetVerticalScroll()
            local max = self:GetVerticalScrollRange()
            self:SetVerticalScroll(math.max(0, math.min(cur - delta * rowH * 3, max)))
        end)
        rowParent = sc

        -- Gradient + arrow indicators on the popup (OVERLAY so they render above rows)
        local BG = {0.08, 0.08, 0.12}

        local fadeTop = popup:CreateTexture(nil, "OVERLAY")
        fadeTop:SetPoint("TOPLEFT",  popup, "TOPLEFT",  1, -1)
        fadeTop:SetPoint("TOPRIGHT", popup, "TOPRIGHT", -1, -1)
        fadeTop:SetHeight(28)
        fadeTop:SetTexture("Interface\\Buttons\\WHITE8x8")
        fadeTop:SetGradient("VERTICAL",
            CreateColor(BG[1], BG[2], BG[3], 0.92),
            CreateColor(BG[1], BG[2], BG[3], 0))
        fadeTop:Hide()

        -- Atlas texture rotated 180° = up arrow (same atlas the dropdown button uses)
        local arrowTop = popup:CreateTexture(nil, "OVERLAY")
        arrowTop:SetSize(10, 10)
        arrowTop:SetAtlas("auctionhouse-ui-sortarrow")
        arrowTop:SetRotation(math.pi)
        arrowTop:SetPoint("TOPRIGHT", popup, "TOPRIGHT", -6, -6)
        arrowTop:SetVertexColor(0.55, 0.70, 1.0, 0.90)
        arrowTop:Hide()

        local fadeBot = popup:CreateTexture(nil, "OVERLAY")
        fadeBot:SetPoint("BOTTOMLEFT",  popup, "BOTTOMLEFT",  1, 1)
        fadeBot:SetPoint("BOTTOMRIGHT", popup, "BOTTOMRIGHT", -1, 1)
        fadeBot:SetHeight(28)
        fadeBot:SetTexture("Interface\\Buttons\\WHITE8x8")
        fadeBot:SetGradient("VERTICAL",
            CreateColor(BG[1], BG[2], BG[3], 0),
            CreateColor(BG[1], BG[2], BG[3], 0.92))

        local arrowBot = popup:CreateTexture(nil, "OVERLAY")
        arrowBot:SetSize(10, 10)
        arrowBot:SetAtlas("auctionhouse-ui-sortarrow")
        arrowBot:SetPoint("BOTTOMRIGHT", popup, "BOTTOMRIGHT", -6, 6)
        arrowBot:SetVertexColor(0.55, 0.70, 1.0, 0.90)

        local function updateIndicators()
            local cur = sf:GetVerticalScroll()
            local max = sf:GetVerticalScrollRange()
            fadeTop:SetShown(cur > 1)
            arrowTop:SetShown(cur > 1)
            fadeBot:SetShown(cur < max - 1)
            arrowBot:SetShown(cur < max - 1)
        end
        sf:SetScript("OnVerticalScroll", function() updateIndicators() end)
        -- Store so the merged OnShow below can call it
        popup._updateIndicators = updateIndicators
        popup._scrollFrame      = sf
    else
        rowParent = popup
    end

    -- Hover preview panel
    local previewFrame = CreateFrame("Frame", nil, UIParent)
    previewFrame:SetSize(220, 52)
    previewFrame:SetFrameStrata("FULLSCREEN_DIALOG")
    previewFrame:SetFrameLevel(202)
    previewFrame:Hide()
    local pvBg = previewFrame:CreateTexture(nil, "BACKGROUND")
    pvBg:SetAllPoints(); pvBg:SetColorTexture(0.05, 0.03, 0.10, 0.95)
    local pvBorder = previewFrame:CreateTexture(nil, "BORDER")
    pvBorder:SetPoint("TOPLEFT", -1, 1); pvBorder:SetPoint("BOTTOMRIGHT", 1, -1)
    pvBorder:SetColorTexture(0.4, 0.2, 0.6, 1)
    local pvLabel = previewFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    pvLabel:SetPoint("TOP", previewFrame, "TOP", 0, -6)
    pvLabel:SetTextColor(0.6, 0.6, 0.6); pvLabel:SetText("Preview")
    local pvText = previewFrame:CreateFontString(nil, "OVERLAY")
    pvText:SetPoint("CENTER", previewFrame, "CENTER", 0, -5)
    SafeSetFont(pvText, PVPHUB_ResolveFontPath(), 18, "")
    pvText:SetTextColor(1, 1, 1); pvText:SetText("AaBbCc 123")

    -- Rows
    local rows = {}
    for i, name in ipairs(items) do
        local row = CreateFrame("Button", nil, rowParent)
        row:SetSize(width, rowH)
        row:SetPoint("TOPLEFT", rowParent, "TOPLEFT", 0, -(i - 1) * rowH)
        local rbg = row:CreateTexture(nil, "BACKGROUND"); rbg:SetAllPoints()
        rbg:SetColorTexture(0, 0, 0, 0)
        local rhl = row:CreateTexture(nil, "HIGHLIGHT"); rhl:SetAllPoints()
        rhl:SetColorTexture(0.20, 0.60, 1.0, 0.13)
        local rtxt = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        rtxt:SetPoint("LEFT", row, "LEFT", 8, 0); rtxt:SetJustifyH("LEFT")
        rtxt:SetText(name)
        -- render the font name in its own typeface
        SafeSetFont(rtxt, PVPHUB_ResolveFontPath(name), 12, "")
        row.fontName = name; row.rbg = rbg
        row:SetScript("OnClick", function()
            UIDropDownMenu_SetText(wrapper, name)
            for _, r in ipairs(rows) do r.rbg:SetColorTexture(0, 0, 0, 0) end
            rbg:SetColorTexture(0.20, 0.60, 1.0, 0.18)
            popup:Hide(); catcher:Hide()
            onSelect(name)
        end)
        row:SetScript("OnEnter", function()
            SafeSetFont(pvText, PVPHUB_ResolveFontPath(name), 18, "")
            previewFrame:ClearAllPoints()
            previewFrame:SetPoint("LEFT", popup, "RIGHT", 6, 0)
            previewFrame:Show()
        end)
        row:SetScript("OnLeave", function() previewFrame:Hide() end)
        rows[i] = row
    end

    local function refreshHighlight()
        local cur = getSelected()
        for _, r in ipairs(rows) do
            r.rbg:SetColorTexture(r.fontName == cur and 0.20 or 0, r.fontName == cur and 0.60 or 0, r.fontName == cur and 1.0 or 0, r.fontName == cur and 0.18 or 0)
        end
    end

    catcher:SetScript("OnMouseDown", function() popup:Hide(); catcher:Hide() end)
    popup:SetScript("OnShow", function()
        refreshHighlight()
        catcher:Show()
        if popup._scrollFrame then
            local cur = getSelected()
            local selIdx = 0
            for i, item in ipairs(items) do if item == cur then selIdx = i break end end
            local sf = popup._scrollFrame
            local centred = (selIdx - 1) * rowH - (popupH / 2) + (rowH / 2)
            sf:SetVerticalScroll(math.max(0, math.min(centred, sf:GetVerticalScrollRange())))
        end
        if popup._updateIndicators then popup._updateIndicators() end
    end)
    popup:SetScript("OnHide", function() catcher:Hide(); previewFrame:Hide() end)

    if toggleBtn then
        toggleBtn:SetScript("OnClick", function()
            if popup:IsShown() then popup:Hide() else UIDropDownMenu_SetText(wrapper, getSelected()); popup:Show() end
        end)
    end

    return wrapper
end

-- Helper to ensure compactMode settings are always initialized
function PVPHUB:EnsureCompactModeDefaults()
    PVPHUB_SETTINGS.compactMode = PVPHUB_SETTINGS.compactMode or {}
    local cm = PVPHUB_SETTINGS.compactMode
    if cm.hideBackground == nil then cm.hideBackground = false end
    if cm.hideInPvP == nil then cm.hideInPvP = false end
    if cm.hideServerNames == nil then cm.hideServerNames = false end
    if cm.selectedFont == nil then cm.selectedFont = "Friz Quadrata TT" end
    if cm.backgroundColor == nil then cm.backgroundColor = {0.1, 0.1, 0.1, 0.8} end -- Default dark background
    if cm.showRatings == nil then
        cm.showRatings = { rating2v2 = true, rating3v3 = true, ratingShuffle = true, ratingBlitz = true, ratingRBG = false }
    end
    if cm.showRatings.ratingRBG == nil then
        cm.showRatings.ratingRBG = false
    end
    if cm.selectedChars == nil then cm.selectedChars = {} end
    -- pinnedSpecs[charKey] = { [specID] = true, ... } — which specs to show as
    -- their own row (each across every enabled bracket column). selectedChars
    -- only applies to characters with no rated spec yet (shown as one combined
    -- row that just follows whichever spec is currently active); once a
    -- character has earned a rating in any spec, it "graduates" to being
    -- controlled entirely through pinnedSpecs instead, so its rating keeps
    -- showing no matter what spec is currently active — see
    -- PromoteToMultiSpecIfNeeded in compact.lua.
    if cm.pinnedSpecs == nil then cm.pinnedSpecs = {} end
    -- promotedMultiSpec[charKey] = true once a character has graduated, so the
    -- one-time hand-off from selectedChars to pinnedSpecs never re-fires (e.g.
    -- after the user manually unticks every pin, leaving it at zero rows).
    if cm.promotedMultiSpec == nil then cm.promotedMultiSpec = {} end
end

-- Debug mode flag (can be enabled by users for troubleshooting)
local PVPHUB_DEBUG = false

-- Enhance GameTooltip background opacity (safer version without global hooks)
local function EnhanceTooltipOpacity()
    if GameTooltip then
        -- Use pcall to prevent any errors from affecting other systems
        pcall(function()
            -- Modern WoW uses NineSlice for tooltip backgrounds
            if GameTooltip.NineSlice then
                -- Set the background to full opacity
                if GameTooltip.NineSlice.Center then
                    GameTooltip.NineSlice.Center:SetAlpha(1.0)
                end
                -- Set all border pieces to full opacity
                local borderPieces = {"TopLeftCorner", "TopRightCorner", "BottomLeftCorner", "BottomRightCorner", 
                                    "TopEdge", "BottomEdge", "LeftEdge", "RightEdge"}
                for _, piece in pairs(borderPieces) do
                    if GameTooltip.NineSlice[piece] then
                        GameTooltip.NineSlice[piece]:SetAlpha(1.0)
                    end
                end
                GameTooltip.NineSlice:SetAlpha(1.0)
            end
            
            -- Try legacy backdrop method for older systems
            if GameTooltip.SetBackdropColor then
                GameTooltip:SetBackdropColor(0, 0, 0, 1.0)
            end
            if GameTooltip.SetBackdropBorderColor then
                GameTooltip:SetBackdropBorderColor(1, 1, 1, 1.0)
            end
            
            -- Set overall tooltip alpha
            GameTooltip:SetAlpha(1.0)
        end)
    end
end

-- PVPHUB tooltip ownership flag — set true before GameTooltip:Show() in PVPHUB
-- handlers, cleared in OnLeave scripts. Used by EnhanceTooltipOpacity so it only
-- ever touches tooltips that PVPHUB explicitly owns.
PVPHUB._ownsTooltip = false

-- Safe tooltip enhancement function that only applies to PVPHUB-owned tooltips
local function SafeEnhanceTooltip()
    if PVPHUB._ownsTooltip and GameTooltip:IsShown() then
        EnhanceTooltipOpacity()
    end
end

-- Safe wrapper for showing PVPHUB tooltips with opacity enhancement
local function ShowPVPHUBTooltip()
    PVPHUB._ownsTooltip = true
    GameTooltip:Show()
    -- Apply our enhancement after a small delay to let the frame draw
    C_Timer.After(0.01, function()
        SafeEnhanceTooltip()
    end)
end

-- Helper function for debug/warning messages
local function DebugPrint(message, forceShow)
    if PVPHUB_DEBUG or forceShow then
        print("|cffff0000[PVPHUB]|r " .. message)
    end
end

-- Helper function for PVPHUB print messages that respects user settings
local function PVPHubPrint(message)
    if not PVPHUB_SETTINGS.disablePrintMessages then
        print(message)
    end
end

-- Helper function to format timestamps into actual date/time
local function FormatTimestamp(timestamp)
    if not timestamp then return "" end
    
    local dateTable = date("*t", timestamp)
    
    -- Get user preference (EU or US)
    local dateFormat = PVPHUB_SETTINGS.dateFormat or "EU"
    
    if dateFormat == "US" then
        -- US format: MM.DD.YY
        return string.format("%02d.%02d.%02d", 
            dateTable.month,
            dateTable.day,
            dateTable.year % 100)
    else
        -- EU format: DD.MM.YY (default)
        return string.format("%02d.%02d.%02d", 
            dateTable.day,
            dateTable.month,
            dateTable.year % 100)
    end
end

-- Refreshes both main and compact windows if they exist and are currently visible
local function PVPHUB_RefreshUI()
    if PVPHUB.window and PVPHUB.window:IsShown() and PVPHUB.window.UpdateContent then
        PVPHUB.window:UpdateContent()
    end
    if PVPHUB.compactWindow and PVPHUB.compactWindow:IsShown() and PVPHUB.UpdateCompactWindow then
        PVPHUB:UpdateCompactWindow()
    end
end

-- Detect whether the player is inside a PvP instance (battleground or arena),
-- including the preparation phase before the match starts — hiding during prep
-- is intentional.  Mirrors Blizzard's instance type conventions:
--   instanceType == "pvp"   — battleground (fires on zone-in, covers prep)
--   instanceType == "arena" — arena (fires on zone-in, covers prep)
-- C_PvP.IsMatchActive() is kept as a secondary safety net for the narrow window
-- during loading screen transitions where IsInInstance() may not have updated yet.
local function IsInActivePvP()
    -- Primary: instance type is set the moment the player zones in, so this
    -- correctly catches both the preparation phase and the active match.
    local inInstance, instanceType = IsInInstance()
    if inInstance and (instanceType == "pvp" or instanceType == "arena") then
        return true
    end

    -- Secondary safety net: catches active matches during loading transitions
    -- where IsInInstance() hasn't updated yet.
    if C_PvP.IsMatchActive and C_PvP.IsMatchActive() then
        return true
    end

    return false
end


-- Constants and Configuration

-- Currency IDs for automatic cap detection and color coding
-- When Blizzard introduces seasonal caps (like on August 12th), these currencies
-- will automatically detect their new caps and apply the same color progression as Honor
local CURRENCY_IDS = {
    honor = 1792,
    conquest = 1602,
    bloodytokens = 2123, -- Bloody Tokens currency ID
}



local BLOODSTONE_ITEM_ID = 253307  -- Updated for Midnight expansion (Infused Heliotrope)

-- Class icon paths for row rendering (circular class badge icons)
local CLASS_ICON_PATHS = {
    DEATHKNIGHT = "Interface\\Icons\\ClassIcon_DeathKnight",
    DEMONHUNTER = "Interface\\Icons\\ClassIcon_DemonHunter",
    DRUID       = "Interface\\Icons\\ClassIcon_Druid",
    EVOKER      = "Interface\\Icons\\ClassIcon_Evoker",
    HUNTER      = "Interface\\Icons\\ClassIcon_Hunter",
    MAGE        = "Interface\\Icons\\ClassIcon_Mage",
    MONK        = "Interface\\Icons\\ClassIcon_Monk",
    PALADIN     = "Interface\\Icons\\ClassIcon_Paladin",
    PRIEST      = "Interface\\Icons\\ClassIcon_Priest",
    ROGUE       = "Interface\\Icons\\ClassIcon_Rogue",
    SHAMAN      = "Interface\\Icons\\ClassIcon_Shaman",
    WARLOCK     = "Interface\\Icons\\ClassIcon_Warlock",
    WARRIOR     = "Interface\\Icons\\ClassIcon_Warrior",
}

-- Color themes for the UI
local COLOR_THEMES = {
    BLUE = {
        WINDOW_BG = {0.05, 0.08, 0.12, 0.95},
        WINDOW_BORDER = {0.2, 0.3, 0.5, 1},
        WINDOW_GLOW = {0.1, 0.2, 0.4, 0.3},
        TITLE_COLOR = {0.4, 0.6, 1, 1},
        SCALE_BUTTON_BG = {0.2, 0.3, 0.5, 0.8},
        SCALE_BUTTON_SELECTED = {0.4, 0.6, 1, 1},
        SCALE_BUTTON_HOVER = {0.3, 0.4, 0.7, 1},
        HEADER_COLOR = {1, 0.85, 0.9, 1},
        SUMMARY_TEXT = {1, 0.8, 0.9, 0.9},
        CURRENT_CHAR_BG = {0.2, 0.4, 0.6, 0.12},
        CURRENT_CHAR_BORDER = {0.4, 0.6, 0.8, 0.6},
        SELECTED_CHAR_BG = {0.2, 0.4, 1, 0.15},
        ALTERNATING_ROW_BG = {0.15, 0.2, 0.3, 0.35},
        HOVER_BG = {1, 1, 1, 0.12},
        COMPACT_BG = {0.05, 0.08, 0.12, 0.3},
        COMPACT_BORDER = {0.2, 0.3, 0.5, 0.4},
        SETTINGS_BG = {0.1, 0.12, 0.15, 0.95},
        SETTINGS_BORDER = {0.3, 0.35, 0.4, 1},
        ACCENT_LINE = {0.4, 0.6, 1, 0.6},
        HEADER_LINE = {0.3, 0.5, 0.8, 0.5},
        SUMMARY_LINE = {0.2, 0.4, 0.7, 0.4},
        TAB_ACTIVE_BG = {0.2, 0.3, 0.5, 0.9},
        TAB_ACTIVE_BORDER = {1, 0.9, 0.4, 1}, -- Light yellow for active tab
        TAB_INACTIVE_BG = {0.1, 0.15, 0.25, 0.85},
        TAB_INACTIVE_BORDER = {0.2, 0.3, 0.5, 0.8},
        TAB_HOVER_BG = {0.15, 0.25, 0.4, 0.8}
    },
    RED = {
        WINDOW_BG = {0.08, 0.05, 0.05, 0.95},
        WINDOW_BORDER = {0.35, 0.2, 0.25, 1},
        WINDOW_GLOW = {0.4, 0.1, 0.2, 0.3},
        TITLE_COLOR = {1, 0.29, 0.29, 1},
        SCALE_BUTTON_BG = {0.35, 0.2, 0.25, 0.8},
        SCALE_BUTTON_SELECTED = {1, 0.4, 0.6, 1},
        SCALE_BUTTON_HOVER = {0.6, 0.3, 0.4, 1},
        HEADER_COLOR = {1, 0.85, 0.9, 1},
        SUMMARY_TEXT = {1, 0.8, 0.9, 0.9},
        CURRENT_CHAR_BG = {0.4, 0.2, 0.2, 0.12},
        CURRENT_CHAR_BORDER = {0.7, 0.4, 0.4, 0.6},
        SELECTED_CHAR_BG = {1, 0.2, 0.4, 0.15},
        ALTERNATING_ROW_BG = {0.3, 0.15, 0.15, 0.35},
        HOVER_BG = {1, 1, 1, 0.12},
        COMPACT_BG = {0.08, 0.05, 0.05, 0.3},
        COMPACT_BORDER = {0.35, 0.2, 0.25, 0.4},
        SETTINGS_BG = {0.12, 0.1, 0.1, 0.95},
        SETTINGS_BORDER = {0.35, 0.3, 0.3, 1},
        ACCENT_LINE = {0.8, 0.3, 0.5, 0.6},
        HEADER_LINE = {0.5, 0.2, 0.3, 0.5},
        SUMMARY_LINE = {0.6, 0.2, 0.3, 0.4},
        TAB_ACTIVE_BG = {0.35, 0.2, 0.25, 0.9},
        TAB_ACTIVE_BORDER = {1, 0.9, 0.4, 1}, -- Light yellow for active tab
        TAB_INACTIVE_BG = {0.2, 0.1, 0.15, 0.85},
        TAB_INACTIVE_BORDER = {0.35, 0.2, 0.25, 0.8},
        TAB_HOVER_BG = {0.3, 0.15, 0.2, 0.8}
    },
    DARK = {
        WINDOW_BG = {0.02, 0.02, 0.02, 0.95},
        WINDOW_BORDER = {0.15, 0.15, 0.15, 1},
        WINDOW_GLOW = {0.1, 0.1, 0.1, 0.3},
        TITLE_COLOR = {0.9, 0.9, 0.9, 1},
        SCALE_BUTTON_BG = {0.15, 0.15, 0.15, 0.8},
        SCALE_BUTTON_SELECTED = {0.4, 0.4, 0.4, 1},
        SCALE_BUTTON_HOVER = {0.25, 0.25, 0.25, 1},
        HEADER_COLOR = {0.8, 0.8, 0.8, 1},
        SUMMARY_TEXT = {0.7, 0.7, 0.7, 0.9},
        CURRENT_CHAR_BG = {0.35, 0.35, 0.35, 0.25},
        CURRENT_CHAR_BORDER = {0.6, 0.6, 0.6, 0.8},
        SELECTED_CHAR_BG = {0.3, 0.3, 0.3, 0.15},
        ALTERNATING_ROW_BG = {0.18, 0.18, 0.18, 0.4},
        HOVER_BG = {1, 1, 1, 0.12},
        COMPACT_BG = {0.02, 0.02, 0.02, 0.3},
        COMPACT_BORDER = {0.15, 0.15, 0.15, 0.4},
        SETTINGS_BG = {0.05, 0.05, 0.05, 0.95},
        SETTINGS_BORDER = {0.2, 0.2, 0.2, 1},
        ACCENT_LINE = {0.4, 0.4, 0.4, 0.6},
        HEADER_LINE = {0.3, 0.3, 0.3, 0.5},
        SUMMARY_LINE = {0.25, 0.25, 0.25, 0.4},
        TAB_ACTIVE_BG = {0.3, 0.3, 0.3, 0.9},
        TAB_ACTIVE_BORDER = {1, 0.9, 0.4, 1}, -- Light yellow for active tab
        TAB_INACTIVE_BG = {0.1, 0.1, 0.1, 0.85},
        TAB_INACTIVE_BORDER = {0.25, 0.25, 0.25, 0.8},
        TAB_HOVER_BG = {0.2, 0.2, 0.2, 0.8}
    },
    MIDNIGHT = {
        WINDOW_BG = {0.05, 0.02, 0.12, 0.95},
        WINDOW_BORDER = {0.3, 0.15, 0.4, 1},
        WINDOW_GLOW = {0.4, 0.2, 0.6, 0.3},
        TITLE_COLOR = {0.8, 0.6, 1, 1},
        SCALE_BUTTON_BG = {0.2, 0.1, 0.3, 0.8},
        SCALE_BUTTON_SELECTED = {0.6, 0.4, 0.8, 1},
        SCALE_BUTTON_HOVER = {0.4, 0.25, 0.5, 1},
        HEADER_COLOR = {0.9, 0.8, 1, 1},
        SUMMARY_TEXT = {0.8, 0.7, 0.9, 0.9},
        CURRENT_CHAR_BG = {0.3, 0.15, 0.4, 0.12},
        CURRENT_CHAR_BORDER = {0.6, 0.4, 0.8, 0.6},
        SELECTED_CHAR_BG = {0.4, 0.2, 0.6, 0.15},
        ALTERNATING_ROW_BG = {0.2, 0.12, 0.25, 0.35},
        HOVER_BG = {1, 1, 1, 0.12},
        COMPACT_BG = {0.05, 0.02, 0.12, 0.3},
        COMPACT_BORDER = {0.3, 0.15, 0.4, 0.4},
        SETTINGS_BG = {0.08, 0.03, 0.15, 0.95},
        SETTINGS_BORDER = {0.35, 0.2, 0.45, 1},
        ACCENT_LINE = {0.7, 0.4, 0.9, 0.6},
        HEADER_LINE = {0.5, 0.3, 0.7, 0.5},
        SUMMARY_LINE = {0.4, 0.2, 0.6, 0.4},
        TAB_ACTIVE_BG = {0.3, 0.15, 0.4, 0.9},
        TAB_ACTIVE_BORDER = {1, 0.9, 0.4, 1}, -- Light yellow for active tab
        TAB_INACTIVE_BG = {0.15, 0.08, 0.2, 0.85},
        TAB_INACTIVE_BORDER = {0.3, 0.15, 0.4, 0.8},
        TAB_HOVER_BG = {0.25, 0.12, 0.3, 0.8}
    },
    AURORA = {
        -- Dark glass + indigo/violet accent, inspired by pvp.cx's UI.
        -- WINDOW_BG_TOP gives the window a top-to-bottom gradient (lighter
        -- indigo fading into near-black) instead of a flat fill.
        WINDOW_BG = {0.035, 0.035, 0.06, 0.95},
        WINDOW_BG_TOP = {0.16, 0.13, 0.32, 0.95},
        WINDOW_BORDER = {0.3, 0.28, 0.55, 1},
        WINDOW_GLOW = {0.45, 0.35, 0.95, 0.3},
        TITLE_COLOR = {0.64, 0.56, 1, 1},
        SCALE_BUTTON_BG = {0.2, 0.18, 0.42, 0.8},
        SCALE_BUTTON_SELECTED = {0.42, 0.38, 0.98, 1},
        SCALE_BUTTON_HOVER = {0.32, 0.28, 0.68, 1},
        HEADER_COLOR = {0.75, 0.76, 0.88, 1},
        SUMMARY_TEXT = {0.68, 0.7, 0.85, 0.9},
        CURRENT_CHAR_BG = {0.35, 0.32, 0.85, 0.12},
        CURRENT_CHAR_BORDER = {0.5, 0.45, 0.95, 0.6},
        SELECTED_CHAR_BG = {0.4, 0.35, 0.95, 0.15},
        ALTERNATING_ROW_BG = {0.1, 0.1, 0.16, 0.35},
        HOVER_BG = {1, 1, 1, 0.08},
        COMPACT_BG = {0.035, 0.035, 0.06, 0.3},
        COMPACT_BORDER = {0.3, 0.28, 0.55, 0.4},
        SETTINGS_BG = {0.06, 0.06, 0.1, 0.95},
        SETTINGS_BORDER = {0.32, 0.3, 0.58, 1},
        ACCENT_LINE = {0.45, 0.4, 0.98, 0.6},
        HEADER_LINE = {0.4, 0.36, 0.85, 0.5},
        SUMMARY_LINE = {0.32, 0.28, 0.68, 0.4},
        TAB_ACTIVE_BG = {0.3, 0.27, 0.72, 0.9},
        TAB_ACTIVE_BORDER = {0.55, 0.5, 1, 1},
        TAB_INACTIVE_BG = {0.12, 0.12, 0.18, 0.85},
        TAB_INACTIVE_BORDER = {0.25, 0.24, 0.4, 0.8},
        TAB_HOVER_BG = {0.2, 0.19, 0.38, 0.8}
    },
}


local UI_CONSTANTS = {
    WINDOW_WIDTH = 1020,
    WINDOW_HEIGHT = 400,  -- Changed to match settings baseline for consistency
    BASE_ROW_HEIGHT = 24,  -- Base row height for default font size (12px)
    CONTENT_WIDTH = 950,
    COLUMN_WIDTHS = {
        character = 210,
        standard = 85
    },
    COLORS = {} -- Will be set by GetCurrentTheme()
}
-- Expose to the global environment so themes.lua can read UI_CONSTANTS.COLORS
_G.UI_CONSTANTS = UI_CONSTANTS

-- Function to calculate dynamic row height based on font size
local function GetDynamicRowHeight()
    local baseRowHeight = UI_CONSTANTS.BASE_ROW_HEIGHT
    local dynamicHeight = baseRowHeight
    
    return dynamicHeight
end

-- Function to calculate optimal window size based on screen resolution and content
local function CalculateOptimalWindowSize()
    local screenHeight = UIParent:GetHeight()
    local screenWidth = UIParent:GetWidth()
    
    -- Calculate content-based height if we have character data
    local contentHeight = 0
    if PVPHUB_DB then
        local characterCount = 0
        for _ in pairs(PVPHUB_DB) do
            characterCount = characterCount + 1
        end
        
        -- Calculate height based on actual content
        local headerHeight = 120  -- Header area with buttons
        local footerHeight = 60   -- Footer area 
        local dynamicRowHeight = GetDynamicRowHeight()
        local characterRowsHeight = characterCount * dynamicRowHeight
        contentHeight = headerHeight + characterRowsHeight + footerHeight
    end
    
    -- Calculate optimal height using a comfortable minimum
    local settingsBaselineHeight = 420
    local minHeight = settingsBaselineHeight
    local maxHeight = math.min(600, screenHeight * 0.60) -- Activate scrolling sooner
    local optimalHeight
    
    if contentHeight > 0 then
        -- Use content-based height, but never smaller than settings baseline
        optimalHeight = math.min(maxHeight, math.max(minHeight, contentHeight))
    else
        -- Fallback for fresh install: use settings baseline
        optimalHeight = minHeight
    end
    
    -- Calculate optimal width (keep existing width logic but ensure it fits screen)
    local minWidth = 800 -- Minimum usable width
    local maxWidth = math.min(1400, screenWidth * 0.85) -- Max 85% of screen width
    local optimalWidth = math.min(maxWidth, math.max(minWidth, UI_CONSTANTS.WINDOW_WIDTH))
    
    return optimalWidth, optimalHeight
end

-- Function to adjust existing window size to fit current screen resolution
local function AdjustWindowToScreen(window)
    if not window then return end
    
    local screenHeight = UIParent:GetHeight()
    local screenWidth = UIParent:GetWidth()
    local currentWidth = window:GetWidth()
    local currentHeight = window:GetHeight()
    
    -- Ensure window doesn't exceed screen bounds (with some margin)
    local maxAllowedWidth = screenWidth * 0.9
    local maxAllowedHeight = screenHeight * 0.85
    
    local newWidth = math.min(currentWidth, maxAllowedWidth)
    local newHeight = math.min(currentHeight, maxAllowedHeight)
    
    -- Only resize if necessary
    if newWidth ~= currentWidth or newHeight ~= currentHeight then
        window:SetSize(newWidth, newHeight)
        -- Save the new height to settings
        if PVPHUB_SETTINGS.windowSize then
            PVPHUB_SETTINGS.windowSize.height = newHeight
        end
    end
end


local PVPHUB_CONSTANTS = {
    COMPACT_WINDOW = {
        BASE_WIDTH = 135, -- Width for character name column
        COLUMN_WIDTH = 80, -- Width per rating column
        ROW_HEIGHT = 20,
        MIN_WIDTH = 260, -- Minimum window width (must be wide enough so the sort-dropdown
                         -- chevron never overlaps the scale label in the toolbar)
    }
}


-- (Legacy rating tier system - removed as it's no longer used)
-- Keeping this comment for reference in case it's needed in the future


local CURRENCY_TIER_COLORS = {
    {threshold = 0.95, color = "|cffff0000"},
    {threshold = 0.8, color = "|cffff8000"},
    {threshold = 0.6, color = "|cffffff00"},
    {threshold = 0.4, color = "|cff80ff00"},
    {threshold = 0, color = "|cff00ff00"}
}


local COLUMN_HEADERS = {
    { text = "Character",                                                              key = "character",    minWidth = 210 },
    { text = "|T1455894:14|t Honor",                                                  key = "honor",        minWidth = 85  },
    { text = "|T1523630:14|t Conquest",                                               key = "conquest",     minWidth = 100 },
    { text = "|T134128:14|t Helio",                                                   key = "bloodstones",  minWidth = 80  },
    { text = "|T4638431:14|t Tokens",                                                 key = "bloodytokens", minWidth = 85  },
    { text = "|TInterface\\Icons\\achievement_arena_2v2_1:14|t 2v2",                  key = "rating2v2",    minWidth = 80  },
    { text = "|TInterface\\Icons\\achievement_arena_3v3_1:14|t 3v3",                  key = "rating3v3",    minWidth = 80  },
    { text = "|TInterface\\Icons\\ability_dualwield:14|t Shuffle",                    key = "ratingShuffle",minWidth = 90  },
    { text = "|TInterface\\Icons\\achievement_bg_killxenemies_generalsroom:14|t Blitz",key = "ratingBlitz", minWidth = 85  },
    { text = "|TInterface\\Icons\\achievement_pvp_a_15:14|t RBG",                     key = "ratingRBG",    minWidth = 75  },
}

-- Returns COLUMN_HEADERS arranged per the user's custom drag-and-drop order
-- (PVPHUB_SETTINGS.columnOrder, an array of column keys), if any. "character"
-- is always forced first (it's the fixed identifier column — see ReorderColumn,
-- which refuses to move it). Any key present in COLUMN_HEADERS but missing
-- from a saved columnOrder (e.g. a column shipped after the user already
-- customized their order) is appended at the end in its natural
-- COLUMN_HEADERS position, so a stale saved order never silently drops a
-- column. Every render loop that currently walks COLUMN_HEADERS directly
-- should walk this instead so header order and row-data order can't drift
-- apart (see the allValues/values lookup in UpdateContent).
local function GetOrderedColumnHeaders()
    local byKey = {}
    for _, header in ipairs(COLUMN_HEADERS) do
        byKey[header.key] = header
    end

    local ordered = {}
    if byKey.character then
        table.insert(ordered, byKey.character)
    end

    local placed = { character = true }
    local savedOrder = PVPHUB_SETTINGS and PVPHUB_SETTINGS.columnOrder
    if savedOrder then
        for _, key in ipairs(savedOrder) do
            local header = byKey[key]
            if header and not placed[key] then
                table.insert(ordered, header)
                placed[key] = true
            end
        end
    end

    -- Append anything not covered by the saved order (first run, or a
    -- newly-added column key) in COLUMN_HEADERS' own natural order.
    for _, header in ipairs(COLUMN_HEADERS) do
        if not placed[header.key] then
            table.insert(ordered, header)
            placed[header.key] = true
        end
    end

    return ordered
end


local PVP_BRACKETS = {
    { id = 1, key = "rating2v2" },
    { id = 2, key = "rating3v3" },
    { id = 4, key = "ratingRBG" },
    { id = 7, key = "ratingShuffle" },
    { id = 9, key = "ratingBlitz" },
}

-- MMR Bracket mapping (based on MMRTracker)
local MMR_BRACKETS = {
    [0] = "2v2",     -- 2v2 Arena
    [1] = "3v3",     -- 3v3 Arena  
    [3] = "rbg",     -- Rated Battlegrounds
    [6] = "shuffle", -- Solo Shuffle
    [8] = "blitz"    -- Blitz
}

-- Mapping our PVPHUB keys to MMR bracket IDs
local PVPHUB_TO_MMR_BRACKET = {
    rating2v2 = 0,
    rating3v3 = 1,
    ratingRBG = 3,
    ratingShuffle = 6,
    ratingBlitz = 8
}


local DISPLAY_NAMES = {
    honor = "Honor",
    conquest = "Conquest",
    bloodstones = "Heliotrope",
    bloodytokens = "Tokens",
    rating2v2 = "2v2",
    rating3v3 = "3v3",
    ratingShuffle = "Shuffle",
    ratingBlitz = "Blitz",
    ratingRBG = "RBG",
}


-- Spec info cache — GetSpecializationInfoByID is pure: same specID always returns
-- the same data within a session. WoW has ~40 specs so memory cost is negligible.
local _specInfoCache = {}
local function GetCachedSpecInfo(specID)
    if not specID or specID == 0 then return nil end
    if not _specInfoCache[specID] then
        local id, name, _, icon, _, classFile = GetSpecializationInfoByID(specID)
        if id then
            _specInfoCache[specID] = { id = id, name = name, icon = icon, classFile = classFile }
        end
    end
    return _specInfoCache[specID]
end

-- Pre-lobby Solo Shuffle snapshot helpers.
-- The played/won counts are persisted to PVPHUB_DB so a crash or DC mid-lobby
-- can still compute round W/L on reconnect instead of silently showing 0/0.
local function SavePreLobbySnapshot(charKey, played, won)
    if not charKey or not PVPHUB_DB or not PVPHUB_DB[charKey] then return end
    PVPHUB_DB[charKey].shufflePreLobbySnap = { played = played, won = won, timestamp = GetServerTime() }
end

local function ClearPreLobbySnapshot(charKey)
    if charKey and PVPHUB_DB and PVPHUB_DB[charKey] then
        PVPHUB_DB[charKey].shufflePreLobbySnap = nil
    end
end

-- Returns played, won — reads in-memory first, falls back to DB snapshot.
-- Snapshots older than 4 hours are discarded (stale from a previous session's lobby).
local function GetPreLobbySnapshot(charKey)
    local played = PVPHUB._shufflePreLobbyPlayed
    local won    = PVPHUB._shufflePreLobbyWon
    if played == nil or won == nil then
        local snap = charKey and PVPHUB_DB and PVPHUB_DB[charKey]
                     and PVPHUB_DB[charKey].shufflePreLobbySnap
        if snap and snap.timestamp and (GetServerTime() - snap.timestamp) < 14400 then
            played = snap.played
            won    = snap.won
        end
    end
    return played, won
end

-- Currency cap cache — maxQuantity is static within a session (caps don't change mid-play).
-- false is the sentinel for "checked and no cap", preventing repeated lookups for uncapped currencies.
local _currencyCapCache = {}
local function GetCachedCurrencyCap(currencyID)
    if not currencyID then return 0 end
    if _currencyCapCache[currencyID] == nil then
        local info = C_CurrencyInfo.GetCurrencyInfo(currencyID)
        _currencyCapCache[currencyID] = (info and info.maxQuantity and info.maxQuantity > 0)
                                        and info.maxQuantity or false
    end
    return _currencyCapCache[currencyID] or 0
end

-- Data Protection and Backup System
local _lastBackupTime = 0
local _BACKUP_INTERVAL = 300  -- at most once every 5 minutes

-- Recursive deep copy, no depth limit. The old inline copy only went 3
-- levels deep (char -> field -> k2 -> k3), so anything nested deeper (e.g.
-- per-spec MMR history under mmrData) was assigned by reference: later
-- mutations to the "live" table silently corrupted the "backup" too.
local function DeepCopyTable(t)
    local copy = {}
    for k, v in pairs(t) do
        copy[k] = (type(v) == "table") and DeepCopyTable(v) or v
    end
    return copy
end

local function CreateDataBackup()
    local now = GetTime()
    if now - _lastBackupTime < _BACKUP_INTERVAL then return end
    _lastBackupTime = now

    if not PVPHUB_DB or type(PVPHUB_DB) ~= "table" then
        return
    end
    
    local charCount = 0
    for _ in pairs(PVPHUB_DB) do 
        charCount = charCount + 1 
    end
    
    if charCount > 0 then
        PVPHUB_DB_BACKUP = PVPHUB_DB_BACKUP or {}
        -- Keep last 3 backups to prevent memory bloat
        PVPHUB_DB_BACKUP[3] = PVPHUB_DB_BACKUP[2]
        PVPHUB_DB_BACKUP[2] = PVPHUB_DB_BACKUP[1]
        PVPHUB_DB_BACKUP[1] = {}
        
        -- Deep copy current data (unbounded depth — see DeepCopyTable)
        for char, data in pairs(PVPHUB_DB) do
            if type(data) == "table" then
                PVPHUB_DB_BACKUP[1][char] = DeepCopyTable(data)
            end
        end
        -- Backup created silently (no chat message to avoid spam)
    end
end

local function ValidateAndRestoreData()
    -- Check if main database is corrupted
    if not PVPHUB_DB or type(PVPHUB_DB) ~= "table" then
        -- Silent: Main database corrupted, attempting restoration
        
        -- Try to restore from backup
        if PVPHUB_DB_BACKUP and PVPHUB_DB_BACKUP[1] and type(PVPHUB_DB_BACKUP[1]) == "table" then
            local charCount = 0
            for _ in pairs(PVPHUB_DB_BACKUP[1]) do charCount = charCount + 1 end
            if charCount > 0 then
                PVPHUB_DB = {}
                for char, data in pairs(PVPHUB_DB_BACKUP[1]) do
                    if type(data) == "table" then
                        PVPHUB_DB[char] = {}
                        for k, v in pairs(data) do
                            PVPHUB_DB[char][k] = v
                        end
                    end
                end
                -- Silent: Data successfully restored from backup
                return true
            end
        end
        
        -- Initialize empty database if no backup available
        PVPHUB_DB = {}
        -- Silent: No backup available, initialized empty database
        return false
    end

    return true
end

-- Single canonical list of what "this character's season-scoped PvP data"
-- means, used by every place that clears it: the automatic season-boundary
-- detection in UpdateCurrencyData AND the manual "Start Fresh" button. Before
-- this existed, each site kept its own ad-hoc field list and they drifted out
-- of sync — the button once forgot the legacy rating fields, and the
-- automatic path was (and, absent this fix, would still be) missing those
-- plus mmrHistory/lastKnownMMR/mmrData too. rating2v2/rating3v3/ratingRBG/
-- ratingShuffle/ratingBlitz are the "legacy flat" fields every rating display
-- in the addon actually reads (see pvp_tracking.lua's header comment) —
-- bracketStats is the richer structure, but leaving the flat fields alone
-- meant a character you hadn't logged into since the reset kept showing (and
-- counting as "has a rating" for) last season's numbers.
local function ClearCharacterSeasonData(data)
    if type(data) ~= "table" then return end
    data.conquestWeeklyData     = nil
    data.bloodytokensWeeklyData = nil
    data.bracketStats           = nil
    data.wlData                 = nil
    data.mmrHistory             = nil
    data.lastKnownMMR           = nil
    data.mmrData                = nil
    data.rating2v2              = nil
    data.rating3v3              = nil
    data.ratingRBG              = nil
    data.ratingShuffle          = nil
    data.ratingBlitz            = nil
end

-- Global Variables with Protection
PVPHUB_DB_BACKUP = PVPHUB_DB_BACKUP or {}
ValidateAndRestoreData() -- Validate data on load
PVPHUB_IGNORED = PVPHUB_IGNORED or {}
-- Guard against a corrupted SavedVariables entry (crash mid-write, manual WTF
-- edit, etc.). Unlike PVPHUB_DB there is no backup to restore from, so the
-- safest recovery is to drop the corrupted value and fall through to defaults
-- below — losing settings is far better than every PVPHUB_SETTINGS.x access
-- for the rest of the file throwing "attempt to index a boolean/string/number".
if PVPHUB_SETTINGS ~= nil and type(PVPHUB_SETTINGS) ~= "table" then
    PVPHUB_SETTINGS = nil
end
PVPHUB_SETTINGS = PVPHUB_SETTINGS or {
    visibleColumns = {
        character = true,
        honor = true,
        conquest = true,
        bloodstones = true,
        bloodytokens = true,
        rating2v2 = true,
        rating3v3 = true,
        ratingShuffle = true,
        ratingBlitz = true,
        ratingRBG = true
    },
    hiddenCharacters = {}, -- List of character keys that should be hidden
    compactMode = {
        enabled = false,
        selectedChars = {},
        showRatings = {
            rating2v2 = true,
            rating3v3 = true,
            ratingShuffle = true,
            ratingBlitz = false,
            ratingRBG = false
        },
        hideBackground = false
    },
    colorTheme = "BLUE",
    welcomeShown = false,
    lastSeenVersion = nil,
    windowScale = 1.0,
    compactWindowScale = 1.0,
    minimap = {
        hide = false,
        minimapPos = 220,  -- Default position angle around minimap
        radius = 80        -- Default distance from minimap center
    },
    selectedFont = "Friz Quadrata TT",
    mainWindow = {
        hideServerNames = false,
        hideNoRatings = false,
        hideWelcomeMessage = false,
        roundedFrame = true,
        showGlow = true,
    },
    honorWarnings = {},  -- Track which characters have been warned about 14k honor
    characterGroups = {
        groups = {
            {name = "No Group", characters = {}, collapsed = false, isDefault = true}
        },
        enabled = false
    }
}



PVPHUB.selectedChar = nil
PVPHUB.frame = CreateFrame("Frame")
PVPHUB.RefreshUI = PVPHUB_RefreshUI

-- Hidden Characters Management
-- Hash set for O(1) lookups; kept in sync with PVPHUB_SETTINGS.hiddenCharacters
local hiddenCharSet = {}

local function RebuildHiddenSet()
    hiddenCharSet = {}
    if PVPHUB_SETTINGS.hiddenCharacters then
        for _, charKey in ipairs(PVPHUB_SETTINGS.hiddenCharacters) do
            hiddenCharSet[charKey] = true
        end
    end
end

local function IsCharacterHidden(charKey)
    return hiddenCharSet[charKey] == true
end

-- True if this character's last recorded activity predates the most-recently
-- detected PvP season boundary (stamped in UpdateCurrencyData). There is no
-- way to query another character's currency/PvP data without logging into
-- it, so a character that hasn't logged in since the season changed is still
-- carrying last season's snapshot - callers use this to dim/flag that
-- instead of presenting it as current. A character with no recorded activity
-- at all has nothing stale to show (this covers both a character PVPHUB has
-- never tracked, and one whose first-ever update hasn't stamped lastSeen
-- yet) - it's just untracked, not "last season's". If no season boundary has
-- been detected yet this install, no character is considered stale either.
local function IsCharacterStaleThisSeason(charKey)
    local data = PVPHUB_DB and PVPHUB_DB[charKey]
    if not data or not data.lastSeen then return false end
    local seasonStart = PVPHUB_SETTINGS and PVPHUB_SETTINGS.seasonStartTimestamp
    if not seasonStart then return false end
    return data.lastSeen < seasonStart
end

local function HideCharacter(charKey)
    if not PVPHUB_SETTINGS.hiddenCharacters then
        PVPHUB_SETTINGS.hiddenCharacters = {}
    end
    
    -- Don't add if already hidden
    if not IsCharacterHidden(charKey) then
        table.insert(PVPHUB_SETTINGS.hiddenCharacters, charKey)
        hiddenCharSet[charKey] = true
        
        -- Get character data for class color
        local charData = PVPHUB_DB[charKey] or {}
        local class = charData.class or "PRIEST"
        local color = RAID_CLASS_COLORS[class] or NORMAL_FONT_COLOR
        local classColorStr = color.colorStr or "ffffffff"
        
        PVPHubPrint("|cff00ff00[PVPHUB]|r Character |c" .. classColorStr .. charKey .. "|r has been hidden.")
        
        -- Force immediate UI refresh
        if PVPHUB.window and PVPHUB.window.UpdateContent then
            PVPHUB.window:UpdateContent()
        end
        if PVPHUB.compactWindow and PVPHUB.UpdateCompactWindow then
            PVPHUB:UpdateCompactWindow()
        end
        
        -- Update hidden characters window if it's open
        if PVPHUB.hiddenCharsWindow and PVPHUB.hiddenCharsWindow:IsVisible() and PVPHUB.hiddenCharsWindow.UpdateContent then
            PVPHUB.hiddenCharsWindow.UpdateContent()
        elseif PVPHUB.hiddenCharsWindow and PVPHUB.hiddenCharsWindow:IsVisible() then
            -- Debug: Window is visible but UpdateContent function is missing
            print("[DEBUG] Hidden chars window is visible but UpdateContent function not found")
        end
    end
end

local function UnhideCharacter(charKey)
    if not PVPHUB_SETTINGS.hiddenCharacters then
        return false
    end
    
    for i, hiddenChar in ipairs(PVPHUB_SETTINGS.hiddenCharacters) do
        if hiddenChar == charKey then
            table.remove(PVPHUB_SETTINGS.hiddenCharacters, i)
            hiddenCharSet[charKey] = nil
            
            -- Get character data for class color
            local charData = PVPHUB_DB[charKey] or {}
            local class = charData.class or "PRIEST"
            local color = RAID_CLASS_COLORS[class] or NORMAL_FONT_COLOR
            local classColorStr = color.colorStr or "ffffffff"
            
            PVPHubPrint("|cff00ff00[PVPHUB]|r Character |c" .. classColorStr .. charKey .. "|r is now visible again.")
            
            -- Force immediate UI refresh
            if PVPHUB.window and PVPHUB.window.UpdateContent then
                PVPHUB.window:UpdateContent()
            end
            if PVPHUB.compactWindow and PVPHUB.UpdateCompactWindow then
                PVPHUB:UpdateCompactWindow()
            end
            
            -- Update hidden characters window if it's open
            if PVPHUB.hiddenCharsWindow and PVPHUB.hiddenCharsWindow:IsVisible() and PVPHUB.hiddenCharsWindow.UpdateContent then
                PVPHUB.hiddenCharsWindow.UpdateContent()
            end
            
            return true
        end
    end
    return false
end

local function GetHiddenCharactersList()
    return PVPHUB_SETTINGS.hiddenCharacters or {}
end

local function GetFullName()
    local name, realm = UnitName("player")
    realm = realm or GetRealmName()
    
    -- Ensure we have valid strings before concatenation
    if not name or name == "" then
        name = "Unknown"
    end
    if not realm or realm == "" then
        realm = "Unknown"
    end
    
    -- Handle potential encoding issues by using string.format for safer concatenation
    local fullName = string.format("%s-%s", name, realm)
    
    -- Additional validation for non-Latin characters
    -- WoW handles Unicode well, but we ensure the result is not empty
    if fullName == "-" or fullName == "" or fullName == "Unknown-Unknown" then
        return nil
    end
    
    return fullName
end

-- Character Groups Helper Functions
local function GetCharacterGroup(charKey)
    if not PVPHUB_SETTINGS.characterGroups or not PVPHUB_SETTINGS.characterGroups.groups then
        return 1 -- Return Ungrouped
    end
    
    for i, group in ipairs(PVPHUB_SETTINGS.characterGroups.groups) do
        for _, char in ipairs(group.characters) do
            if char == charKey then
                return i
            end
        end
    end
    return 1 -- Default to Ungrouped
end

local function MoveCharacterToGroup(charKey, groupIndex)
    if not PVPHUB_SETTINGS.characterGroups or not PVPHUB_SETTINGS.characterGroups.groups then
        return
    end
    
    -- Remove from all groups first
    for _, group in ipairs(PVPHUB_SETTINGS.characterGroups.groups) do
        for j = #group.characters, 1, -1 do
            if group.characters[j] == charKey then
                table.remove(group.characters, j)
            end
        end
    end
    
    -- Add to new group
    if PVPHUB_SETTINGS.characterGroups.groups[groupIndex] then
        table.insert(PVPHUB_SETTINGS.characterGroups.groups[groupIndex].characters, charKey)
    end
end

local function ReorderGroup(fromIndex, toIndex)
    local groups = PVPHUB_SETTINGS.characterGroups and PVPHUB_SETTINGS.characterGroups.groups
    if not groups then return end
    if fromIndex == toIndex then return end
    local fromGroup = groups[fromIndex]
    local toGroup = groups[toIndex]
    if not fromGroup or not toGroup then return end
    if fromGroup.isDefault then return end
    local group = table.remove(groups, fromIndex)
    if toGroup.isDefault then
        -- Dropping on No Group = append to end (last custom group position)
        table.insert(groups, group)
    else
        table.insert(groups, toIndex, group)
    end
    if PVPHUB.window and PVPHUB.window.UpdateContent then
        PVPHUB.window:UpdateContent()
    end
end

local function GetGroupDragGhost()
    if not PVPHUB._groupDragGhost then
        local ghost = CreateFrame("Frame", nil, UIParent)
        ghost:SetFrameStrata("TOOLTIP")
        ghost:Hide()

        -- Background matches the header bar, slightly brighter to show it's "held"
        local bg = ghost:CreateTexture(nil, "BACKGROUND")
        bg:SetAllPoints()
        bg:SetColorTexture(0.18, 0.22, 0.35, 0.92)

        -- Blue highlight border (top + bottom lines)
        local borderTop = ghost:CreateTexture(nil, "BORDER")
        borderTop:SetPoint("TOPLEFT", ghost, "TOPLEFT", 0, 0)
        borderTop:SetPoint("TOPRIGHT", ghost, "TOPRIGHT", 0, 0)
        borderTop:SetHeight(1)
        borderTop:SetColorTexture(0.3, 0.6, 1, 0.9)
        local borderBot = ghost:CreateTexture(nil, "BORDER")
        borderBot:SetPoint("BOTTOMLEFT", ghost, "BOTTOMLEFT", 0, 0)
        borderBot:SetPoint("BOTTOMRIGHT", ghost, "BOTTOMRIGHT", 0, 0)
        borderBot:SetHeight(1)
        borderBot:SetColorTexture(0.3, 0.6, 1, 0.9)

        -- Collapse/expand icon (same position as the real header: LEFT+8)
        local icon = ghost:CreateTexture(nil, "ARTWORK")
        icon:SetSize(16, 16)
        icon:SetPoint("LEFT", ghost, "LEFT", 8, 0)
        ghost.icon = icon

        -- Group name + count (same layout as the real header: icon RIGHT + 6)
        local label = ghost:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        label:SetPoint("LEFT", ghost, "LEFT", 30, 0)
        label:SetPoint("RIGHT", ghost, "RIGHT", -6, 0)
        label:SetJustifyH("LEFT")
        ghost.label = label

        ghost:SetScript("OnUpdate", function(self)
            local x, y = GetCursorPosition()
            local s = UIParent:GetEffectiveScale()
            local h = self:GetHeight()
            self:ClearAllPoints()
            -- Cursor sits at the left icon area, vertically centered on the row
            self:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", x / s - 12, y / s + h / 2)
        end)
        PVPHUB._groupDragGhost = ghost
    end
    return PVPHUB._groupDragGhost
end

-- Reorders a movable Characters-tab data column (see GetOrderedColumnHeaders
-- above). "character" is the fixed identifier column and never moves — the
-- drag handlers wired onto each column's hoverBtn also refuse to start a
-- drag from it in the first place, this is just a second guard.
local function ReorderColumn(fromKey, toKey)
    if not fromKey or not toKey or fromKey == toKey then return end
    if fromKey == "character" or toKey == "character" then return end

    -- Seed columnOrder from the current effective order the first time a
    -- drag happens, so reordering one column doesn't reset the rest back to
    -- COLUMN_HEADERS' natural order.
    if not PVPHUB_SETTINGS.columnOrder then
        local seeded = {}
        for _, header in ipairs(GetOrderedColumnHeaders()) do
            if header.key ~= "character" then
                table.insert(seeded, header.key)
            end
        end
        PVPHUB_SETTINGS.columnOrder = seeded
    end

    local order = PVPHUB_SETTINGS.columnOrder
    local fromIndex, toIndex
    for i, key in ipairs(order) do
        if key == fromKey then fromIndex = i end
        if key == toKey then toIndex = i end
    end
    if not fromIndex or not toIndex then return end

    local key = table.remove(order, fromIndex)
    table.insert(order, toIndex, key)

    if PVPHUB.window and PVPHUB.window.UpdateContent then
        PVPHUB.window:UpdateContent()
    end
end

-- Horizontal counterpart to GetGroupDragGhost — but instead of a small tile
-- that only follows the cursor, this spans the FULL column height (header
-- down to the last row, matching the exact span the existing per-column
-- hover-highlight already uses — see "colHL" in UpdateContent, y=-82 to
-- y=+60 relative to the main window) so it reads as "you're picking up the
-- whole column," not just a floating label chip. Only the LEFT edge tracks
-- the cursor horizontally; the vertical span stays locked to the window's
-- row area regardless of the cursor's Y position, since column reordering
-- is a purely horizontal operation.
--
-- parentWindow is the main PVPHUB window (f) — passed in rather than
-- captured as an upvalue because this function lives at file scope, outside
-- PVPHUB_ToggleMainWindow's closure where f is actually defined. Only the
-- first call's parentWindow matters (the ghost is a singleton and there's
-- only ever one main window per session).
local function GetColumnDragGhost(parentWindow)
    if not PVPHUB._columnDragGhost then
        local ghost = CreateFrame("Frame", nil, UIParent)
        ghost:SetFrameStrata("TOOLTIP")
        ghost:Hide()

        -- Soft tint spanning the whole strip, so the entire column reads as
        -- "selected/being moved" rather than just its header.
        local bg = ghost:CreateTexture(nil, "BACKGROUND")
        bg:SetAllPoints()
        bg:SetColorTexture(0.25, 0.55, 1, 0.16)

        local borderLeft = ghost:CreateTexture(nil, "BORDER")
        borderLeft:SetPoint("TOPLEFT", ghost, "TOPLEFT", 0, 0)
        borderLeft:SetPoint("BOTTOMLEFT", ghost, "BOTTOMLEFT", 0, 0)
        borderLeft:SetWidth(2)
        borderLeft:SetColorTexture(0.3, 0.6, 1, 0.9)
        local borderRight = ghost:CreateTexture(nil, "BORDER")
        borderRight:SetPoint("TOPRIGHT", ghost, "TOPRIGHT", 0, 0)
        borderRight:SetPoint("BOTTOMRIGHT", ghost, "BOTTOMRIGHT", 0, 0)
        borderRight:SetWidth(2)
        borderRight:SetColorTexture(0.3, 0.6, 1, 0.9)

        -- Header-style label chip at the top of the strip, so the column is
        -- still identifiable while shown as a full vertical band.
        local labelBG = ghost:CreateTexture(nil, "ARTWORK")
        labelBG:SetPoint("TOPLEFT", ghost, "TOPLEFT", 0, 0)
        labelBG:SetPoint("TOPRIGHT", ghost, "TOPRIGHT", 0, 0)
        labelBG:SetHeight(26)
        labelBG:SetColorTexture(0.18, 0.22, 0.35, 0.92)

        local label = ghost:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        label:SetPoint("TOP", labelBG, "TOP", 0, -7)
        label:SetJustifyH("CENTER")
        ghost.label = label

        ghost:SetScript("OnUpdate", function(self)
            local cursorX = GetCursorPosition()
            local scale = parentWindow:GetEffectiveScale()
            -- Cursor X converted into parentWindow's own coordinate units
            -- (matches GetLeft()'s unit system), so no UIParent-scale
            -- mixing is needed even if the user has a custom window scale set.
            local offsetX = (cursorX / scale) - (parentWindow:GetLeft() or 0) - (self:GetWidth() / 2)
            self:ClearAllPoints()
            self:SetPoint("TOPLEFT", parentWindow, "TOPLEFT", offsetX, -82)
            self:SetPoint("BOTTOMLEFT", parentWindow, "BOTTOMLEFT", offsetX, 60)
        end)
        PVPHUB._columnDragGhost = ghost
    end
    return PVPHUB._columnDragGhost
end

-- Function to show the group management window
function PVPHUB:ShowGroupManagementWindow()
    if PVPHUB.groupMgmtWindow then
        PVPHUB.groupMgmtWindow:Show()
        PVPHUB.groupMgmtWindow:UpdateContent()
        return
    end
    
    local window = CreateFrame("Frame", "PVPHUBGroupManagementWindow", UIParent, "BackdropTemplate")
    window:SetSize(500, 400)
    window:SetPoint("CENTER")
    window:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        tile = false,
        edgeSize = 2,
        insets = { left = 2, right = 2, top = 2, bottom = 2 }
    })
    local bgColor = UI_CONSTANTS.COLORS.BG_COLOR
    window:SetBackdropColor(bgColor[1], bgColor[2], bgColor[3], 0.95)
    window:SetBackdropBorderColor(unpack(UI_CONSTANTS.COLORS.BORDER_COLOR))
    window:SetFrameStrata("DIALOG")
    window:SetMovable(true)
    window:EnableMouse(true)
    window:RegisterForDrag("LeftButton")
    window:SetClampedToScreen(true)
    
    -- Title
    local title = window:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOP", 0, -15)
    title:SetText("|TInterface\\Icons\\INV_Misc_GroupLooking:20|t Manage Character Groups")
    title:SetTextColor(unpack(UI_CONSTANTS.COLORS.ACCENT_COLOR))
    
    -- Drag to move
    window:SetScript("OnDragStart", window.StartMoving)
    window:SetScript("OnDragStop", window.StopMovingOrSizing)
    
    -- Close button
    local closeBtn = CreateFrame("Button", nil, window, "UIPanelCloseButton")
    closeBtn:SetPoint("TOPRIGHT", -5, -5)
    closeBtn:SetScript("OnClick", function() window:Hide() end)
    
    -- Enable/Disable grouping checkbox
    local enableCheckbox = CreateFrame("CheckButton", nil, window, "UICheckButtonTemplate")
    enableCheckbox:SetPoint("TOPLEFT", 20, -50)
    enableCheckbox:SetSize(24, 24)
    enableCheckbox.Text = enableCheckbox:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    enableCheckbox.Text:SetPoint("LEFT", enableCheckbox, "RIGHT", 5, 0)
    enableCheckbox.Text:SetText("Enable Character Grouping")
    enableCheckbox:SetChecked(PVPHUB_SETTINGS.characterGroups.enabled or false)
    enableCheckbox:SetScript("OnClick", function(self)
        PVPHUB_SETTINGS.characterGroups.enabled = self:GetChecked()
        if PVPHUB.window and PVPHUB.window.UpdateContent then
            PVPHUB.window:UpdateContent()
        end
        window:UpdateContent()
    end)
    
    -- Scroll frame for groups
    local scrollFrame = CreateFrame("ScrollFrame", nil, window, "UIPanelScrollFrameTemplate")
    scrollFrame:SetPoint("TOPLEFT", 20, -85)
    scrollFrame:SetPoint("BOTTOMRIGHT", -40, 80)
    
    local scrollChild = CreateFrame("Frame", nil, scrollFrame)
    scrollChild:SetSize(440, 1)
    scrollFrame:SetScrollChild(scrollChild)
    window.scrollChild = scrollChild
    
    -- Add Group button
    local addGroupBtn = CreateFrame("Button", nil, window, "UIPanelButtonTemplate")
    addGroupBtn:SetSize(120, 25)
    addGroupBtn:SetPoint("BOTTOMLEFT", 20, 45)
    addGroupBtn:SetText(CreateAtlasMarkup("editmode-new-layout-plus", 12, 12) .. " Add Group")
    addGroupBtn:SetScript("OnClick", function()
        StaticPopup_Show("PVPHUB_ADD_GROUP")
    end)

    -- Close button at bottom
    local bottomCloseBtn = CreateFrame("Button", nil, window, "UIPanelButtonTemplate")
    bottomCloseBtn:SetSize(100, 25)
    bottomCloseBtn:SetPoint("BOTTOMRIGHT", -20, 45)
    bottomCloseBtn:SetText("Close")
    bottomCloseBtn:SetScript("OnClick", function() window:Hide() end)

    -- Info text
    local infoText = window:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    infoText:SetPoint("BOTTOM", 0, 15)
    infoText:SetText("Drag characters between groups in the main window")
    infoText:SetTextColor(0.7, 0.7, 0.7, 1)
    
    -- Update content function
    function window:UpdateContent()
        -- Clear existing content
        local children = {scrollChild:GetChildren()}
        for _, child in ipairs(children) do
            child:Hide()
            child:SetParent(nil)
        end
        
        local yOffset = -10
        local groups = PVPHUB_SETTINGS.characterGroups.groups or {}
        
        for i, group in ipairs(groups) do
            -- Group frame
            local groupFrame = CreateFrame("Frame", nil, scrollChild, "BackdropTemplate")
            groupFrame:SetPoint("TOPLEFT", 10, yOffset)
            groupFrame:SetSize(400, 60)
            groupFrame:SetBackdrop({
                bgFile = "Interface\\Buttons\\WHITE8x8",
                edgeFile = "Interface\\Buttons\\WHITE8x8",
                tile = false,
                edgeSize = 1,
                insets = { left = 1, right = 1, top = 1, bottom = 1 }
            })
            groupFrame:SetBackdropColor(0.2, 0.2, 0.2, 0.5)
            groupFrame:SetBackdropBorderColor(0.5, 0.5, 0.5, 1)
            
            -- Group name
            local nameText = groupFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
            nameText:SetPoint("TOPLEFT", 10, -10)
            nameText:SetText(group.name)
            nameText:SetTextColor(unpack(UI_CONSTANTS.COLORS.ACCENT_COLOR))
            
            -- Character count
            local countText = groupFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
            countText:SetPoint("TOPLEFT", 10, -32)
            countText:SetText(string.format("%d character(s)", #group.characters))
            countText:SetTextColor(0.8, 0.8, 0.8, 1)
            
            -- Can't delete Ungrouped or if it's the only group
            if not group.isDefault and #groups > 1 then
                -- Rename button
                local renameBtn = CreateFrame("Button", nil, groupFrame, "UIPanelButtonTemplate")
                renameBtn:SetSize(70, 22)
                renameBtn:SetPoint("TOPRIGHT", -90, -8)
                renameBtn:SetText("Rename")
                renameBtn:SetScript("OnClick", function()
                    PVPHUB._renameGroupCtx = { groupIndex = i, groupName = group.name }
                    StaticPopup_Show("PVPHUB_RENAME_GROUP")
                end)
                -- Delete button
                local deleteBtn = CreateFrame("Button", nil, groupFrame, "UIPanelButtonTemplate")
                deleteBtn:SetSize(70, 22)
                deleteBtn:SetPoint("TOPRIGHT", -10, -8)
                deleteBtn:SetText("Delete")
                deleteBtn:SetScript("OnClick", function()
                    PVPHUB._deleteGroupCtx = { groupIndex = i }
                    StaticPopupDialogs["PVPHUB_DELETE_GROUP"].text = "Delete group '" .. group.name .. "'?\n\nCharacters will be moved to Ungrouped."
                    StaticPopup_Show("PVPHUB_DELETE_GROUP")
                end)
            end
            
            yOffset = yOffset - 70
        end
        
        scrollChild:SetHeight(math.abs(yOffset) + 20)
    end
    
    window:UpdateContent()
    PVPHUB.groupMgmtWindow = window
end



-- Function to show the hidden characters management window
local function ShowHiddenCharactersWindow()
    if PVPHUB.hiddenCharsWindow then
        PVPHUB.hiddenCharsWindow:Show()
        PVPHUB.hiddenCharsWindow.UpdateContent()
        return
    end
    
    local window = CreateFrame("Frame", "PVPHUBHiddenCharsWindow", UIParent, "BackdropTemplate")
    window:SetSize(400, 325)
    window:SetPoint("CENTER")
    window:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true,
        tileSize = 16,
        edgeSize = 16,
        insets = { left = 8, right = 8, top = 8, bottom = 8 }
    })
    window:SetBackdropColor(0.1, 0.1, 0.1, 0.9)
    window:SetBackdropBorderColor(0.4, 0.4, 0.4, 1)
    window:SetFrameStrata("DIALOG")
    window:SetMovable(true)
    window:EnableMouse(true)
    window:RegisterForDrag("LeftButton")
    window:SetClampedToScreen(true)
    window:SetScript("OnDragStart", window.StartMoving)
    window:SetScript("OnDragStop", window.StopMovingOrSizing)
    
    -- Title
    local title = window:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOP", window, "TOP", 0, -15)
    title:SetText("Hidden Characters")
    title:SetTextColor(1, 0.8, 0, 1)

    -- Note: hiding a character isn't just a display filter — it also drops
    -- that character out of the Season tab's totals (games played, win rate,
    -- highest rating, etc.), since GetStatsCharacterList skips hidden
    -- characters entirely. Called out here so it's not a surprise later.
    local note = window:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    note:SetPoint("TOP", window, "TOP", 0, -35)
    note:SetWidth(360)
    note:SetJustifyH("CENTER")
    note:SetWordWrap(true)
    note:SetText("Hiding a character also excludes it from the Season tab's totals, not just this list.")
    note:SetTextColor(0.65, 0.65, 0.65, 1)

    -- Close button
    local closeBtn = CreateFrame("Button", nil, window, "UIPanelCloseButton")
    closeBtn:SetPoint("TOPRIGHT", window, "TOPRIGHT", -5, -5)
    closeBtn:SetScript("OnClick", function() window:Hide() end)

    -- Scroll frame
    local scrollFrame = CreateFrame("ScrollFrame", nil, window, "UIPanelScrollFrameTemplate")
    scrollFrame:SetPoint("TOPLEFT", window, "TOPLEFT", 20, -75)
    scrollFrame:SetPoint("BOTTOMRIGHT", window, "BOTTOMRIGHT", -40, 50)
    
    local scrollChild = CreateFrame("Frame", nil, scrollFrame)
    scrollFrame:SetScrollChild(scrollChild)
    scrollChild:SetSize(340, 200)
    
    -- No characters message
    local noCharsMessage = scrollChild:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    noCharsMessage:SetPoint("CENTER", scrollChild, "CENTER", 0, 0)
    noCharsMessage:SetText("No characters are currently hidden.")
    noCharsMessage:SetTextColor(0.7, 0.7, 0.7, 1)
    
    -- Unhide All button
    local unhideAllBtn = CreateFrame("Button", nil, window, "UIPanelButtonTemplate")
    unhideAllBtn:SetSize(120, 25)
    unhideAllBtn:SetPoint("BOTTOMLEFT", window, "BOTTOMLEFT", 20, 15)
    unhideAllBtn:SetText("Unhide All")
    unhideAllBtn:SetScript("OnClick", function()
        PVPHUB_SETTINGS.hiddenCharacters = {}
        hiddenCharSet = {}
        PVPHubPrint("|cff00ff00[PVPHUB]|r All characters are now visible again.")
        
        -- Force immediate UI refresh
        if PVPHUB.window and PVPHUB.window.UpdateContent then
            PVPHUB.window:UpdateContent()
        end
        if PVPHUB.compactWindow and PVPHUB.UpdateCompactWindow then
            PVPHUB:UpdateCompactWindow()
        end
        
        window.UpdateContent()
    end)
    
    -- Unhide Current Character button (special case for when current char is hidden)
    local unhideCurrentBtn = CreateFrame("Button", nil, window, "UIPanelButtonTemplate")
    unhideCurrentBtn:SetSize(160, 25)
    unhideCurrentBtn:SetPoint("BOTTOMRIGHT", window, "BOTTOMRIGHT", -20, 15)
    unhideCurrentBtn:SetText("Unhide Current Character")
    unhideCurrentBtn:SetScript("OnClick", function()
        local currentChar = GetFullName()
        if IsCharacterHidden(currentChar) then
            UnhideCharacter(currentChar)
            window.UpdateContent()
        end
    end)
    -- Close button
    local closeBottomBtn = CreateFrame("Button", nil, window, "UIPanelButtonTemplate")
    closeBottomBtn:SetSize(80, 25)
    closeBottomBtn:SetPoint("BOTTOM", window, "BOTTOM", 0, 15) -- Centered at bottom
    closeBottomBtn:SetText("Close")
    closeBottomBtn:SetScript("OnClick", function() window:Hide() end)
    
    -- Update content function
    function window.UpdateContent()
        -- Clear existing buttons
        if window.unhideButtons then
            for _, btn in ipairs(window.unhideButtons) do
                btn:Hide()
                btn:SetParent(nil)
            end
        end
        window.unhideButtons = {}
        
        local hiddenChars = GetHiddenCharactersList()
        local currentChar = GetFullName()
        local isCurrentCharHidden = IsCharacterHidden(currentChar)
        
        -- Show/hide the "Unhide Current Character" button based on whether current char is hidden
        if isCurrentCharHidden then
            unhideCurrentBtn:Show()
        else
            unhideCurrentBtn:Hide()
        end
        
        if #hiddenChars == 0 then
            noCharsMessage:Show()
            unhideAllBtn:Hide()
            unhideCurrentBtn:Hide()
            scrollChild:SetHeight(200)
            noCharsMessage:SetText("No characters are currently hidden.\n\nRight-click a character row in the\nmain window to hide them.")
            noCharsMessage:SetTextColor(0.6, 0.6, 0.6, 1)
        else
            noCharsMessage:Hide()
            unhideAllBtn:Show()
            
            -- Ensure current character appears in the list if it's hidden
            local displayList = {}
            for _, charKey in ipairs(hiddenChars) do
                table.insert(displayList, charKey)
            end
            
            -- Add current character to display list if it's hidden but not already in the list
            if isCurrentCharHidden then
                local currentCharInList = false
                for _, charKey in ipairs(displayList) do
                    if charKey == currentChar then
                        currentCharInList = true
                        break
                    end
                end
                if not currentCharInList then
                    table.insert(displayList, 1, currentChar) -- Add at the top
                end
            end
            
            local yOffset = 0
            for i, charKey in ipairs(displayList) do
                -- Get character data for class color and spec icon
                local charData = PVPHUB_DB[charKey] or {}
                local class = charData.class or "PRIEST"
                local specID = charData.specID or charData.lastActiveSpecID
                
                -- Get class color
                local color = RAID_CLASS_COLORS[class] or NORMAL_FONT_COLOR
                local classColorStr = color.colorStr or "ffffffff"
                
                -- Get spec icon
                local specIcon = ""
                if specID then
                    local _si = GetCachedSpecInfo(specID)
                    if _si and _si.icon then
                        specIcon = "|T" .. _si.icon .. ":16|t "
                    end
                end
                
                -- Character name with class color and spec icon
                local charText = scrollChild:CreateFontString(nil, "OVERLAY", "GameFontNormal")
                charText:SetPoint("TOPLEFT", scrollChild, "TOPLEFT", 10, -yOffset)
                charText:SetText(specIcon .. "|c" .. classColorStr .. charKey .. "|r")
                
                -- Unhide button
                local unhideBtn = CreateFrame("Button", nil, scrollChild, "UIPanelButtonTemplate")
                unhideBtn:SetSize(70, 22)
                unhideBtn:SetPoint("TOPRIGHT", scrollChild, "TOPRIGHT", -10, -yOffset + 2)
                unhideBtn:SetText("Unhide")
                unhideBtn:SetScript("OnClick", function()
                    UnhideCharacter(charKey)
                    window.UpdateContent()
                end)
                table.insert(window.unhideButtons, charText)
                table.insert(window.unhideButtons, unhideBtn)
                
                yOffset = yOffset + 30
            end
            
            scrollChild:SetHeight(math.max(200, yOffset))
        end
    end
    
    -- Initial content update
    window.UpdateContent()
    
    PVPHUB.hiddenCharsWindow = window
    window:Show()
end

-- Utility Functions
local function GetCurrentTheme()
    local selectedTheme = PVPHUB_SETTINGS.colorTheme or "BLUE"
    
    -- If CLASS theme is selected, generate it dynamically based on player's class
    if selectedTheme == "CLASS" then
        local _, playerClass = UnitClass("player")
        local classColor = RAID_CLASS_COLORS[playerClass]
        
        if classColor then
            local r, g, b = classColor.r, classColor.g, classColor.b
            
            -- Generate a complete theme based on the class color
            return {
                WINDOW_BG = {r * 0.15, g * 0.15, b * 0.15, 0.95},
                WINDOW_BORDER = {r * 0.6, g * 0.6, b * 0.6, 1},
                WINDOW_GLOW = {r * 0.8, g * 0.8, b * 0.8, 0.3},
                TITLE_COLOR = {r * 1.2, g * 1.2, b * 1.2, 1},
                SCALE_BUTTON_BG = {r * 0.4, g * 0.4, b * 0.4, 0.8},
                SCALE_BUTTON_SELECTED = {r, g, b, 1},
                SCALE_BUTTON_HOVER = {r * 0.7, g * 0.7, b * 0.7, 1},
                HEADER_COLOR = {1, 0.85, 0.9, 1},
                SUMMARY_TEXT = {1, 0.8, 0.9, 0.9},
                CURRENT_CHAR_BG = {r * 0.5, g * 0.5, b * 0.5, 0.12},
                CURRENT_CHAR_BORDER = {r * 0.8, g * 0.8, b * 0.8, 0.6},
                SELECTED_CHAR_BG = {r * 0.7, g * 0.7, b * 0.7, 0.15},
                ALTERNATING_ROW_BG = {r * 0.3, g * 0.3, b * 0.3, 0.35},
                HOVER_BG = {1, 1, 1, 0.12},
                COMPACT_BG = {r * 0.15, g * 0.15, b * 0.15, 0.3},
                COMPACT_BORDER = {r * 0.6, g * 0.6, b * 0.6, 0.4},
                SETTINGS_BG = {r * 0.2, g * 0.2, b * 0.2, 0.95},
                SETTINGS_BORDER = {r * 0.65, g * 0.65, b * 0.65, 1},
                ACCENT_LINE = {r * 0.9, g * 0.9, b * 0.9, 0.6},
                HEADER_LINE = {r * 0.7, g * 0.7, b * 0.7, 0.5},
                SUMMARY_LINE = {r * 0.6, g * 0.6, b * 0.6, 0.4},
                TAB_ACTIVE_BG = {r * 0.5, g * 0.5, b * 0.5, 0.9},
                TAB_ACTIVE_BORDER = {r * 1.2, g * 1.2, b * 1.2, 1},
                TAB_INACTIVE_BG = {r * 0.2, g * 0.2, b * 0.2, 0.85},
                TAB_INACTIVE_BORDER = {r * 0.4, g * 0.4, b * 0.4, 0.8},
                TAB_HOVER_BG = {r * 0.35, g * 0.35, b * 0.35, 0.8}
            }
        end
    end
    
    -- Migrate old "UNIVERSE" saved value to the new "MIDNIGHT" key
    if selectedTheme == "UNIVERSE" then
        if PVPHUB_SETTINGS then PVPHUB_SETTINGS.colorTheme = "MIDNIGHT" end
        selectedTheme = "MIDNIGHT"
    end
    -- Migrate removed themes (CUSTOM, GLASS, GREEN) to BLUE
    if selectedTheme == "CUSTOM" or selectedTheme == "GLASS" or selectedTheme == "GREEN" then
        if PVPHUB_SETTINGS then PVPHUB_SETTINGS.colorTheme = "BLUE" end
        selectedTheme = "BLUE"
    end
    return COLOR_THEMES[selectedTheme] or COLOR_THEMES.BLUE
end

-- Sets the window background color/alpha for the active theme. Themes that
-- define WINDOW_BG_TOP (e.g. Aurora) render as a top-to-bottom gradient;
-- all others fall back to the flat WINDOW_BG color, scaled to the same
-- alpha every existing caller already computes for a plain SetVertexColor.
local function ApplyWindowBGColor(frame, alpha)
    if not frame or not frame.bgTex then return end
    local colors = UI_CONSTANTS.COLORS
    local bg = colors.WINDOW_BG
    local top = colors.WINDOW_BG_TOP
    if top then
        local ratio = bg[4] > 0 and (alpha / bg[4]) or 0
        local topAlpha = (top[4] or bg[4]) * ratio
        frame.bgTex:SetGradient("VERTICAL",
            CreateColor(top[1], top[2], top[3], topAlpha),
            CreateColor(bg[1], bg[2], bg[3], alpha))
    else
        frame.bgTex:SetVertexColor(bg[1], bg[2], bg[3], alpha)
    end
end

-- Shows or hides the main window's soft ambient edge glow AND its thin
-- border ring based on the "Window Glow" appearance setting (defaults to
-- on). Both are separate textures (glowLayers = blurred layers, borderTex =
-- the crisp low-opacity outline) but read as one "glow" effect to the user,
-- so one setting controls both.
local function ApplyWindowGlowVisibility(frame)
    if not frame then return end
    local show = not (PVPHUB_SETTINGS.mainWindow and PVPHUB_SETTINGS.mainWindow.showGlow == false)
    if frame.glowLayers then
        for _, tex in ipairs(frame.glowLayers) do
            if show then tex:Show() else tex:Hide() end
        end
    end
    if frame.borderTex then
        if show then frame.borderTex:Show() else frame.borderTex:Hide() end
    end
end

local function ApplyTheme()
    UI_CONSTANTS.COLORS = GetCurrentTheme()
    -- Expose resolved colors on the global PVPHUB table so modules loaded
    -- before core (e.g. queue_timer.lua) can read them without needing
    -- access to the local UI_CONSTANTS or COLOR_THEMES variables.
    PVPHUB.currentColors = UI_CONSTANTS.COLORS
    -- Re-theme queue timer widget if it exists
    if PVPHUB.QueueTimer then
        PVPHUB.QueueTimer:ApplyTheme()
    end
    if PVPHUB.Themes then
        PVPHUB.Themes:UpdateAllWindows()
    end
    -- Re-theme the streamer/compact overlay and its settings window too —
    -- UpdateAllWindows only touches the main window, so without this a theme
    -- change silently didn't apply to either until the next /reload.
    if PVPHUB.RefreshCompactTheme then
        PVPHUB:RefreshCompactTheme()
    end
end

-- Function to apply modern styling to dropdowns
local function RefreshDropdownColors(dropdown)
    if not dropdown or not dropdown._pvpBg then return end
    local colors = (UI_CONSTANTS and UI_CONSTANTS.COLORS) or {}
    local r  = (colors.WINDOW_BG and colors.WINDOW_BG[1] or 0.05) * 1.7
    local g  = (colors.WINDOW_BG and colors.WINDOW_BG[2] or 0.05) * 1.7
    local bv = (colors.WINDOW_BG and colors.WINDOW_BG[3] or 0.08) * 2.0
    dropdown._pvpBg:SetVertexColor(r, g, bv, 0.88)
    if dropdown._pvpBorders then
        local bclr = colors.WINDOW_BORDER or {0.30, 0.30, 0.38, 1}
        local ba = (bclr[4] or 1) * 0.55
        for _, borderTex in ipairs(dropdown._pvpBorders) do
            borderTex:SetVertexColor(bclr[1], bclr[2], bclr[3], ba)
        end
    end
    local text = dropdown.Text or _G[(dropdown:GetName() or "").."Text"]
    if text and colors.HEADER_COLOR then
        text:SetTextColor(unpack(colors.HEADER_COLOR))
    end
end

local function ApplyModernDropdownStyling(dropdown)
    if not dropdown then return end
    -- ElvUI skins all dropdowns itself; let it handle them to avoid conflicts
    if ElvUI then return end

    -- Hide WoW chrome textures (Left/Middle/Right parchment)
    for _, n in ipairs({ "Left", "Middle", "Right" }) do
        local t = dropdown[n] or _G[(dropdown:GetName() or "")..n]
        if t then t:SetAlpha(0) end
    end

    -- Inset constants matching UIDropDownMenu geometry:
    -- Left texture is 25px; bg starts at 22px from frame left so it never bleeds.
    local L, R, T, B = 22, -2, -5, 5

    -- Resize the existing DropDownToggleButton to fill the entire visible area.
    -- It already has the correct OnMouseDown → ToggleDropDownMenu, so the whole
    -- button surface becomes clickable without any extra overlay frame.
    local btn = dropdown.Button or _G[(dropdown:GetName() or "").."Button"]
    if btn and not btn._pvpResized then
        btn._pvpResized = true
        if btn:GetNormalTexture()    then btn:GetNormalTexture():SetAlpha(0)    end
        if btn:GetPushedTexture()    then btn:GetPushedTexture():SetAlpha(0)    end
        if btn:GetHighlightTexture() then btn:GetHighlightTexture():SetAlpha(0) end
        btn:ClearAllPoints()
        btn:SetPoint("TOPLEFT",     dropdown, "TOPLEFT",     L,  T)
        btn:SetPoint("BOTTOMRIGHT", dropdown, "BOTTOMRIGHT", R,  B)
        -- "v" arrow on the right side of the button
        local ar = btn:CreateFontString(nil, "OVERLAY")
        RegisterTrackedFont(ar, 9, "OUTLINE")
        ar:SetPoint("RIGHT", btn, "RIGHT", -6, 0)
        ar:SetTextColor(0.50, 0.50, 0.58)
        ar:SetText(CreateAtlasMarkup("auctionhouse-ui-sortarrow", 8, 8))
        btn._pvpArrow = ar
    end

    -- Flat background + 1 px themed border
    if not dropdown._pvpBg then
        local colors = (UI_CONSTANTS and UI_CONSTANTS.COLORS) or {}
        local bg = dropdown:CreateTexture(nil, "BACKGROUND")
        bg:SetTexture("Interface\\Buttons\\WHITE8x8")
        bg:SetPoint("TOPLEFT",     dropdown, "TOPLEFT",     L, T)
        bg:SetPoint("BOTTOMRIGHT", dropdown, "BOTTOMRIGHT", R, B)
        local r  = (colors.WINDOW_BG and colors.WINDOW_BG[1] or 0.05) * 1.7
        local g  = (colors.WINDOW_BG and colors.WINDOW_BG[2] or 0.05) * 1.7
        local bv = (colors.WINDOW_BG and colors.WINDOW_BG[3] or 0.08) * 2.0
        bg:SetVertexColor(r, g, bv, 0.88)
        dropdown._pvpBg = bg

        local bclr = colors.WINDOW_BORDER or {0.30, 0.30, 0.38, 1}
        local ba = (bclr[4] or 1) * 0.55
        local function mkBorderLine(p1, p2, isH)
            local l = dropdown:CreateTexture(nil, "BORDER")
            l:SetTexture("Interface\\Buttons\\WHITE8x8")
            l:SetVertexColor(bclr[1], bclr[2], bclr[3], ba)
            if isH then l:SetHeight(1) else l:SetWidth(1) end
            return l
        end
        local tl = mkBorderLine("TOPLEFT",    "TOPRIGHT",    true)
        tl:SetPoint("TOPLEFT",    dropdown, "TOPLEFT",    L, T); tl:SetPoint("TOPRIGHT",    dropdown, "TOPRIGHT",    R, T)
        local bl = mkBorderLine("BOTTOMLEFT", "BOTTOMRIGHT", true)
        bl:SetPoint("BOTTOMLEFT", dropdown, "BOTTOMLEFT", L, B); bl:SetPoint("BOTTOMRIGHT", dropdown, "BOTTOMRIGHT", R, B)
        local ll = mkBorderLine("TOPLEFT",    "BOTTOMLEFT",  false)
        ll:SetPoint("TOPLEFT",    dropdown, "TOPLEFT",    L, T); ll:SetPoint("BOTTOMLEFT",  dropdown, "BOTTOMLEFT",  L, B)
        local rl = mkBorderLine("TOPRIGHT",   "BOTTOMRIGHT", false)
        rl:SetPoint("TOPRIGHT",   dropdown, "TOPRIGHT",   R, T); rl:SetPoint("BOTTOMRIGHT", dropdown, "BOTTOMRIGHT", R, B)
        dropdown._pvpBorders = { tl, bl, ll, rl }
    end

    -- Text: left-aligned, repositioned inside the bg (color applied via RefreshDropdownColors)
    local text = dropdown.Text or _G[(dropdown:GetName() or "").."Text"]
    if text and not text._pvpAnchored then
        text._pvpAnchored = true
        text:ClearAllPoints()
        text:SetPoint("LEFT",  dropdown, "LEFT",  L + 5, 0)
        text:SetPoint("RIGHT", dropdown, "RIGHT", R - 16, 0)
        text:SetJustifyH("LEFT")
        RegisterTrackedFont(text, 11, "OUTLINE")
    end

    -- Anchor the popup to align with the visible bg left edge (L=22px from frame)
    -- By default WoW anchors to the Left texture (25px parchment); overriding makes
    -- the menu open flush with the left edge of our flat button background.
    dropdown.relativeTo   = dropdown
    dropdown.point        = "TOPLEFT"
    dropdown.relativePoint = "BOTTOMLEFT"
    dropdown.xOffset      = 22
    dropdown.yOffset      = 0

    -- Apply current theme colors (runs every call so they stay in sync)
    RefreshDropdownColors(dropdown)
end

-- Hook to style dropdown popup menus when they open
local function StyleDropdownMenu(level)
    level = level or 1
    local menuFrame = _G["DropDownList"..level]
    if not menuFrame then return end

    local colors = (UI_CONSTANTS and UI_CONSTANTS.COLORS) or {}
    local bord = colors.WINDOW_BORDER or {0.30, 0.30, 0.38, 1}
    local wb   = colors.WINDOW_BG     or {0.05, 0.05, 0.08, 1}

    -- Hide WoW's native backdrop frames; replace with our own flat one
    if menuFrame.MenuBackdrop then menuFrame.MenuBackdrop:Hide() end
    if menuFrame.Border       then menuFrame.Border:Hide()       end

    if not menuFrame._pvpBackdrop then
        local bd = CreateFrame("Frame", nil, menuFrame, "BackdropTemplate")
        bd:SetPoint("TOPLEFT",     menuFrame, "TOPLEFT",     0, 0)
        bd:SetPoint("BOTTOMRIGHT", menuFrame, "BOTTOMRIGHT", 0, 0)
        bd:SetFrameLevel(menuFrame:GetFrameLevel() + 1)
        bd:SetBackdrop({
            bgFile   = "Interface\\Buttons\\WHITE8x8",
            edgeFile = "Interface\\Buttons\\WHITE8x8",
            tile = false, edgeSize = 1,
            insets = { left = 0, right = 0, top = 0, bottom = 0 }
        })
        menuFrame._pvpBackdrop = bd
    end
    menuFrame._pvpBackdrop:SetBackdropColor(wb[1] * 1.4, wb[2] * 1.4, wb[3] * 1.6, 0.97)
    menuFrame._pvpBackdrop:SetBackdropBorderColor(bord[1], bord[2], bord[3], (bord[4] or 1) * 0.85)
    menuFrame._pvpBackdrop:Show()
end

-- Walks up a dropdown owner's parent chain looking for a PVPHUB-named frame.
-- ToggleDropDownMenu is Blizzard's shared dropdown system (used by every
-- addon and most of the Blizzard UI) and DropDownList<level> is a reused
-- singleton frame, not one per owner — without this check, opening ANY
-- dropdown anywhere (Blizzard's or another addon's) got silently reskinned
-- to PVPHUB's theme colors.
local function IsPVPHUBOwnedFrame(frame)
    local node = frame
    for _ = 1, 20 do -- bounded walk; guards against any pathological parent loop
        if not node then return false end
        local name = node.GetName and node:GetName()
        if name and string.find(name, "^PVPHUB") then return true end
        node = node.GetParent and node:GetParent()
    end
    return false
end

-- Hook into dropdown opening
hooksecurefunc("ToggleDropDownMenu", function(level)
    -- ElvUI skins dropdowns itself; skip our custom styling to avoid conflicts
    if ElvUI then return end
    if not IsPVPHUBOwnedFrame(UIDROPDOWNMENU_OPEN_MENU) then return end
    C_Timer.After(0, function()
        StyleDropdownMenu(level or 1)
    end)
end)

-- Enhanced font setup for better Unicode support
local function SetupUnicodeFriendlyFont(fontString, size, flags)
    if not fontString then return end

    size = size or 12
    flags = flags or "OUTLINE"

    -- Try to use the best available font for Unicode support
    -- FRIZQT__.TTF generally has good Unicode support in WoW
    local fontPath = "Fonts\\FRIZQT__.TTF"
    
    -- For some locales, there might be better font options
    local locale = GetLocale()
    if locale == "zhCN" or locale == "zhTW" then
        -- Chinese locales might prefer different fonts, but FRIZQT__ usually works well
        fontPath = "Fonts\\FRIZQT__.TTF"
    elseif locale == "koKR" then
        -- Korean locale
        fontPath = "Fonts\\FRIZQT__.TTF"
    elseif locale == "ruRU" then
        -- Russian locale
        fontPath = "Fonts\\FRIZQT__.TTF"
    end
    
    fontString:SetFont(fontPath, size, flags)
end

-- Shared scrollbar position/length for the Characters, Season, and Settings
-- tabs, anchored to the main window frame (not each tab's own scroll frame)
-- so all three land in the exact same spot regardless of that tab's own
-- content margins. Values tuned against the Season tab's layout: topY
-- clears its personalized headline text, bottomY/x keep the bar clear of
-- card borders while sitting out in the window's own right-edge margin.
local function PVPHUB_SCROLLBAR_NUDGE(windowFrame)
    return { relativeTo = windowFrame, x = -15, topY = -123, bottomY = 71 }
end

-- Function to apply modern TWW scrollbar styling with theme integration
local function ApplyModernScrollbarStyling(scrollFrame, themeColors, nudge)
    if not scrollFrame or not scrollFrame.ScrollBar then return end

    local scrollBar = scrollFrame.ScrollBar
    local colors = themeColors or UI_CONSTANTS.COLORS

    -- Optional positional nudge, used to give every tab's scrollbar the same
    -- on-screen position/length. nudge.relativeTo lets the anchor be the
    -- main window frame itself (rather than each tab's own scroll frame, which
    -- differs in top/bottom margins per tab), so all three tabs' bars land in
    -- the exact same spot regardless of that tab's own content layout.
    if nudge then
        local anchor = nudge.relativeTo or scrollFrame
        scrollBar:ClearAllPoints()
        scrollBar:SetPoint("TOP", anchor, "TOPRIGHT", nudge.x or 0, nudge.topY or 0)
        scrollBar:SetPoint("BOTTOM", anchor, "BOTTOMRIGHT", nudge.x or 0, nudge.bottomY or 0)
    end
    
    -- TWW ScrollFrameTemplate has different structure - work with the actual elements
    -- Theme-aware track styling (TWW track elements)
    if scrollBar.Track then
        -- TWW track has Begin, Middle, End textures instead of SetColorTexture
        if scrollBar.Track.Begin then
            local bg = colors.WINDOW_BG
            scrollBar.Track.Begin:SetVertexColor(bg[1] * 0.6, bg[2] * 0.6, bg[3] * 0.6, bg[4])
        end
        if scrollBar.Track.Middle then
            local bg = colors.WINDOW_BG
            scrollBar.Track.Middle:SetVertexColor(bg[1] * 0.6, bg[2] * 0.6, bg[3] * 0.6, bg[4])
        end
        if scrollBar.Track.End then
            local bg = colors.WINDOW_BG
            scrollBar.Track.End:SetVertexColor(bg[1] * 0.6, bg[2] * 0.6, bg[3] * 0.6, bg[4])
        end
    end
    
    -- Theme-aware thumb styling (TWW thumb button)
    if scrollBar.Thumb then
        local border = colors.WINDOW_BORDER
        -- TWW thumb is a button with textures
        if scrollBar.Thumb:GetNormalTexture() then
            scrollBar.Thumb:GetNormalTexture():SetVertexColor(border[1] * 0.9, border[2] * 0.9, border[3] * 0.9, 0.9)
        end
        if scrollBar.Thumb:GetHighlightTexture() then
            scrollBar.Thumb:GetHighlightTexture():SetVertexColor(border[1] * 1.2, border[2] * 1.2, border[3] * 1.2, 0.8)
        end
    end
    
    -- Theme-aware scroll buttons (TWW uses Back/Forward instead of ScrollUp/ScrollDown)
    if scrollBar.Back then
        local accent = colors.SCALE_BUTTON_BG
        if scrollBar.Back:GetNormalTexture() then
            scrollBar.Back:GetNormalTexture():SetVertexColor(accent[1], accent[2], accent[3], accent[4])
        end
        if scrollBar.Back:GetHighlightTexture() then
            scrollBar.Back:GetHighlightTexture():SetVertexColor(accent[1] * 1.5, accent[2] * 1.5, accent[3] * 1.5, 0.6)
        end
    end
    if scrollBar.Forward then
        local accent = colors.SCALE_BUTTON_BG
        if scrollBar.Forward:GetNormalTexture() then
            scrollBar.Forward:GetNormalTexture():SetVertexColor(accent[1], accent[2], accent[3], accent[4])
        end
        if scrollBar.Forward:GetHighlightTexture() then
            scrollBar.Forward:GetHighlightTexture():SetVertexColor(accent[1] * 1.5, accent[2] * 1.5, accent[3] * 1.5, 0.6)
        end
    end

    -- Auto-fade: leave the scrollbar in its normal (small, fixed) lane
    -- rather than overlaying content, but fade it to a faint idle state and
    -- back to full opacity on hover/drag, so it's unobtrusive without
    -- covering anything. Guarded so re-styling an already-set-up scrollbar
    -- doesn't stack duplicate OnEnter/OnLeave hooks.
    if not scrollBar._pvphubOverlayApplied then
        scrollBar._pvphubOverlayApplied = true
        scrollFrame:EnableMouse(true) -- ensures OnEnter/OnLeave fire for the fade, regardless of the template's own default
        scrollBar:SetFrameStrata("HIGH")

        local IDLE_ALPHA, ACTIVE_ALPHA = 0.15, 1.0
        scrollBar:SetAlpha(IDLE_ALPHA)

        local fadeOutTimer
        local function FadeIn()
            if fadeOutTimer then fadeOutTimer:Cancel(); fadeOutTimer = nil end
            UIFrameFadeIn(scrollBar, 0.15, scrollBar:GetAlpha(), ACTIVE_ALPHA)
        end
        local function FadeOutSoon()
            if fadeOutTimer then fadeOutTimer:Cancel() end
            fadeOutTimer = C_Timer.NewTimer(0.6, function()
                fadeOutTimer = nil
                -- Dragging the thumb on a bar this thin easily drifts the
                -- cursor a few pixels off its hit-region, firing OnLeave
                -- even though the drag is still active — check the actual
                -- mouse-button state (not just "did the cursor leave") so a
                -- mid-drag OnLeave doesn't fade the bar out from under the
                -- user. Re-check shortly instead of fading while still held.
                if IsMouseButtonDown("LeftButton") then
                    FadeOutSoon()
                    return
                end
                UIFrameFadeOut(scrollBar, 0.4, scrollBar:GetAlpha(), IDLE_ALPHA)
            end)
        end

        scrollFrame:HookScript("OnEnter", FadeIn)
        scrollFrame:HookScript("OnLeave", FadeOutSoon)
        scrollBar:HookScript("OnEnter", FadeIn)
        scrollBar:HookScript("OnLeave", FadeOutSoon)
        -- No OnValueChanged hook: newer clients' ScrollBar (MinimalScrollBar,
        -- event-driven) isn't a Slider and doesn't support that script type
        -- at all — hover/drag on the bar itself (below) already covers
        -- programmatic scroll changes in practice, since the mouse has to be
        -- over the bar or track to drive one.
        if scrollBar.Thumb then
            scrollBar.Thumb:HookScript("OnMouseDown", FadeIn)
            scrollBar.Thumb:HookScript("OnMouseUp", FadeOutSoon)
        end
    end
end

-- ============================================================
-- Reusable collapsible card widget
-- Shared building block for any scrollable settings-style panel (main
-- Settings tab, Stats tab, Streamer Mode settings): a colored gradient
-- header with icon/title/expand-arrow, and a backdrop body with a left
-- accent stripe that shows/hides on click. Extracted so a third caller
-- doesn't need its own near-duplicate copy of this pattern.
--
-- sectionsTable: the caller's own persistence table (e.g.
--   PVPHUB_SETTINGS.settingsSections) — expand/collapse state is stored at
--   sectionsTable[key], so each caller keeps its own persistence key.
-- onToggle: optional callback fired after the click toggles expanded state,
--   for the caller to re-stack its own list of cards (see
--   PVPHUB_RecalcCardPositions below).
-- Returns a sectionData table: { key, header, content, titleText, arrowText,
--   colorRGB, expanded, contentHeight }. The caller builds its own controls
--   as children of sectionData.content, then sets sectionData.contentHeight
--   to the actual height needed before the first reposition pass.
function PVPHUB_CreateCollapsibleCard(parent, sectionsTable, key, title, colorRGB, iconPath, onToggle)
    local expanded = (sectionsTable[key] ~= false)

    local header = CreateFrame("Button", nil, parent, "BackdropTemplate")
    header:SetHeight(28)
    header:SetBackdrop({
        bgFile   = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = false, tileSize = 16, edgeSize = 8,
        insets = {left=2, right=2, top=2, bottom=2},
    })
    header:SetBackdropColor(0, 0, 0, 0)
    header:SetBackdropBorderColor(colorRGB[1]*0.40, colorRGB[2]*0.40, colorRGB[3]*0.40, 0.35)

    local gradTex = header:CreateTexture(nil, "BACKGROUND")
    gradTex:SetAllPoints(header)
    gradTex:SetTexture("Interface\\Buttons\\WHITE8x8")
    local function ApplyGradient(hovered)
        local mul  = hovered and 0.75 or 0.55
        local mul2 = hovered and 0.25 or 0.15
        gradTex:SetGradient("HORIZONTAL",
            CreateColor(colorRGB[1]*mul,  colorRGB[2]*mul,  colorRGB[3]*mul,  hovered and 0.97 or 0.92),
            CreateColor(colorRGB[1]*mul2, colorRGB[2]*mul2, colorRGB[3]*mul2, hovered and 0.70 or 0.60))
    end
    ApplyGradient(false)
    header:SetScript("OnEnter", function() ApplyGradient(true) end)
    header:SetScript("OnLeave", function() ApplyGradient(false) end)

    local iconTex = header:CreateTexture(nil, "OVERLAY")
    iconTex:SetSize(18, 18)
    iconTex:SetPoint("LEFT", header, "LEFT", 8, 0)
    if iconPath then
        iconTex:SetTexture(iconPath)
        iconTex:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        iconTex:SetVertexColor(1, 1, 1, 0.85)
    else
        iconTex:SetAlpha(0)
    end

    local titleText = header:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    titleText:SetPoint("LEFT", iconTex, "RIGHT", 7, 0)
    RegisterTrackedFont(titleText, 13, "OUTLINE")
    titleText:SetText(title)
    titleText:SetTextColor(1, 1, 1, 1)

    local arrowText = header:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    arrowText:SetPoint("LEFT", titleText, "RIGHT", 8, 0)
    RegisterTrackedFont(arrowText, 11, "OUTLINE")
    arrowText:SetText(expanded and CreateAtlasMarkup("auctionhouse-ui-sortarrow", 10, 10) or CreateAtlasMarkup("common-icon-forwardarrow", 8, 13))
    arrowText:SetTextColor(1, 1, 1, 0.65)

    local content = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    content:SetBackdrop({
        bgFile   = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = false, tileSize = 16, edgeSize = 8,
        insets = {left=2, right=2, top=2, bottom=2},
    })
    content:SetBackdropColor(0.11, 0.09, 0.13, 0.72)
    content:SetBackdropBorderColor(colorRGB[1]*0.45, colorRGB[2]*0.45, colorRGB[3]*0.45, 0.55)

    local stripe = content:CreateTexture(nil, "BORDER")
    stripe:SetTexture("Interface\\Buttons\\WHITE8x8")
    stripe:SetVertexColor(colorRGB[1], colorRGB[2], colorRGB[3], 0.85)
    stripe:SetPoint("TOPLEFT",    content, "TOPLEFT",    3, -3)
    stripe:SetPoint("BOTTOMLEFT", content, "BOTTOMLEFT", 3,  3)
    stripe:SetWidth(3)

    local sectionData = {
        key           = key,
        header        = header,
        content       = content,
        titleText     = titleText,
        arrowText     = arrowText,
        colorRGB      = colorRGB,
        expanded      = expanded,
        contentHeight = 100, -- caller overrides once its controls are built
    }

    header:SetScript("OnClick", function()
        sectionData.expanded = not sectionData.expanded
        sectionsTable[key] = sectionData.expanded
        arrowText:SetText(sectionData.expanded and CreateAtlasMarkup("auctionhouse-ui-sortarrow", 10, 10) or CreateAtlasMarkup("common-icon-forwardarrow", 8, 13))
        if onToggle then onToggle() end
    end)

    return sectionData
end

-- Stacks a list of sectionData tables (from PVPHUB_CreateCollapsibleCard)
-- vertically inside parent, starting at startY (default -8). Returns the
-- final yPos (negative), so the caller can size its scroll child or place a
-- footer below the last card.
function PVPHUB_RecalcCardPositions(parent, allSections, startY)
    local yPos = startY or -8
    for _, sec in ipairs(allSections) do
        sec.header:ClearAllPoints()
        sec.header:SetPoint("TOPLEFT",  parent, "TOPLEFT",  8, yPos)
        sec.header:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -8, yPos)
        yPos = yPos - 28

        sec.content:ClearAllPoints()
        sec.content:SetPoint("TOPLEFT",  parent, "TOPLEFT",  8, yPos)
        sec.content:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -8, yPos)

        if sec.expanded then
            sec.content:SetHeight(sec.contentHeight)
            sec.content:Show()
            yPos = yPos - sec.contentHeight
        else
            sec.content:SetHeight(0.01)
            sec.content:Hide()
        end
        yPos = yPos - 5 -- gap between sections
    end
    return yPos
end

-- Function to apply modern TWW button styling with theme integration
local function ApplyModernButtonStyling(button, themeColors, buttonType)
    if not button then return end
    
    local colors = themeColors or UI_CONSTANTS.COLORS
    -- Preserve existing buttonType if not passed explicitly
    buttonType = buttonType or (button.modernStyling and button.modernStyling.buttonType) or "primary"
    
    -- Theme-aware color scheme (always recalculated from current theme)
    local bgColor, hoverColor, clickColor, borderColor
    if buttonType == "primary" then
        bgColor = {colors.WINDOW_BG[1] * 1.2, colors.WINDOW_BG[2] * 1.2, colors.WINDOW_BG[3] * 1.2, 0.9}
        hoverColor = {colors.HEADER_COLOR[1] * 0.5, colors.HEADER_COLOR[2] * 0.5, colors.HEADER_COLOR[3] * 0.5, 0.3}
        clickColor = {colors.HEADER_COLOR[1] * 0.6, colors.HEADER_COLOR[2] * 0.6, colors.HEADER_COLOR[3] * 0.6, 1}
        borderColor = {colors.WINDOW_BORDER[1] * 1.3, colors.WINDOW_BORDER[2] * 1.3, colors.WINDOW_BORDER[3] * 1.3, 1}
    elseif buttonType == "secondary" then
        bgColor = {colors.WINDOW_BG[1] * 0.9, colors.WINDOW_BG[2] * 0.9, colors.WINDOW_BG[3] * 0.9, 0.8}
        hoverColor = {colors.SUMMARY_TEXT[1] * 0.9, colors.SUMMARY_TEXT[2] * 0.9, colors.SUMMARY_TEXT[3] * 0.9, 0.9}
        clickColor = {colors.SUMMARY_TEXT[1] * 0.7, colors.SUMMARY_TEXT[2] * 0.7, colors.SUMMARY_TEXT[3] * 0.7, 1}
        borderColor = {colors.WINDOW_BORDER[1], colors.WINDOW_BORDER[2], colors.WINDOW_BORDER[3], 0.8}
    elseif buttonType == "accent" then
        bgColor = {colors.SCALE_BUTTON_BG[1], colors.SCALE_BUTTON_BG[2], colors.SCALE_BUTTON_BG[3], 0.9}
        hoverColor = {colors.SCALE_BUTTON_BG[1] * 1.3, colors.SCALE_BUTTON_BG[2] * 1.3, colors.SCALE_BUTTON_BG[3] * 1.3, 1}
        clickColor = {colors.SCALE_BUTTON_BG[1] * 0.8, colors.SCALE_BUTTON_BG[2] * 0.8, colors.SCALE_BUTTON_BG[3] * 0.8, 1}
        borderColor = {colors.WINDOW_GLOW[1], colors.WINDOW_GLOW[2], colors.WINDOW_GLOW[3], 1}
    end

    -- First-time setup: create textures and remove WoW template chrome
    if not button.bg then
        button:SetNormalTexture("")
        button:SetHighlightTexture("")
        button:SetPushedTexture("")
        button:SetDisabledTexture("")

        -- Background
        local bg = button:CreateTexture(nil, "BACKGROUND")
        bg:SetAllPoints()
        bg:SetTexture("Interface\\Buttons\\WHITE8x8")
        button.bg = bg

        -- Border
        local border = button:CreateTexture(nil, "BORDER")
        border:SetTexture("Interface\\Buttons\\WHITE8x8")
        border:SetPoint("TOPLEFT", -1, 1)
        border:SetPoint("BOTTOMRIGHT", 1, -1)
        button.border = border

        -- Hover (ADD blend — colour updates just change the tint)
        local hover = button:CreateTexture(nil, "HIGHLIGHT")
        hover:SetAllPoints()
        hover:SetTexture("Interface\\Buttons\\WHITE8x8")
        hover:SetBlendMode("ADD")
        button:SetHighlightTexture(hover)
        button.hoverTex = hover

        -- Click / pushed
        local pushed = button:CreateTexture(nil, "ARTWORK")
        pushed:SetAllPoints()
        pushed:SetTexture("Interface\\Buttons\\WHITE8x8")
        button:SetPushedTexture(pushed)
        button.pushedTex = pushed
    end

    -- Always update vertex colors (works both on first call and theme refresh)
    button.bg:SetVertexColor(unpack(bgColor))
    button.border:SetVertexColor(unpack(borderColor))
    button.hoverTex:SetVertexColor(unpack(hoverColor))
    button.pushedTex:SetVertexColor(unpack(clickColor))

    -- Font (always refresh so text color follows theme)
    local fontString = button:GetFontString()
    if fontString then
        RegisterTrackedFont(fontString, 11, "OUTLINE")
        fontString:SetTextColor(unpack(colors.TITLE_COLOR))
        fontString:SetShadowOffset(1, -1)
        fontString:SetShadowColor(0, 0, 0, 0.8)
    end
    
    -- Store buttonType for theme-refresh calls that don't pass it explicitly
    button.modernStyling = {
        bgColor = bgColor,
        hoverColor = hoverColor,
        clickColor = clickColor,
        borderColor = borderColor,
        buttonType = buttonType
    }

end

-- Function to apply modern TWW checkbox styling with theme integration
local function ApplyModernCheckboxStyling(checkbox, themeColors)
    if not checkbox then return end
    
    local colors = themeColors or UI_CONSTANTS.COLORS
    
    -- Remove old template styling
    checkbox:SetNormalTexture("")
    checkbox:SetHighlightTexture("")
    checkbox:SetPushedTexture("")
    checkbox:SetCheckedTexture("")
    checkbox:SetDisabledTexture("")
    
    -- Remove background and border for cleaner look
    -- No background or border textures created
    
    -- Create hover effect (only on checkbox area)
    local hover = checkbox:CreateTexture(nil, "HIGHLIGHT")
    hover:SetSize(18, 18)
    hover:SetPoint("LEFT", checkbox, "LEFT", 0, 0)
    hover:SetTexture("Interface\\Buttons\\WHITE8x8")
    hover:SetVertexColor(colors.HEADER_COLOR[1] * 0.5, colors.HEADER_COLOR[2] * 0.5, colors.HEADER_COLOR[3] * 0.5, 0.3)
    hover:SetBlendMode("ADD")
    checkbox:SetHighlightTexture(hover)
    
    -- Create strong, visible checkmark using a modern gold/yellow color
    local checkmark = checkbox:CreateTexture(nil, "ARTWORK")
    checkmark:SetTexture("Interface\\Buttons\\UI-CheckBox-Check")
    checkmark:SetPoint("LEFT", checkbox, "LEFT", 1, 0)
    checkmark:SetSize(16, 16)
    -- Use a bright gold/yellow color for better visibility
    checkmark:SetVertexColor(1, 0.85, 0, 1) -- Bright gold color
    checkbox:SetCheckedTexture(checkmark)
    
    -- Adjust text positioning to prevent overlap with icons
    if checkbox.Text then
        checkbox.Text:ClearAllPoints()
        checkbox.Text:SetPoint("LEFT", checkbox, "LEFT", 25, 0)
    end
    
    -- Store styling info for theme updates (simplified since no bg/border)
    checkbox.modernStyling = {
        hoverColor = {colors.HEADER_COLOR[1] * 0.5, colors.HEADER_COLOR[2] * 0.5, colors.HEADER_COLOR[3] * 0.5, 0.3},
        checkColor = {1, 0.85, 0, 1} -- Bright gold color
    }
end

-- Function to update all modern-styled buttons and checkboxes when theme changes
local function UpdateModernButtonAndCheckboxStyling()
    -- Update all modern-styled buttons and checkboxes with new theme colors
    local colors = UI_CONSTANTS.COLORS
    
    -- Main window buttons use stock Blizzard style

    -- Compact settings window
    if PVPHUB.compactSettingsWindow then
        -- Apply button now uses classic styling, so no modern styling updates needed
        if PVPHUB.compactSettingsWindow.charCheckboxes then
            for _, cb in ipairs(PVPHUB.compactSettingsWindow.charCheckboxes) do
                if cb.modernStyling then ApplyModernCheckboxStyling(cb, colors) end
            end
        end
        if PVPHUB.compactSettingsWindow.ratingCheckboxes then
            for _, cb in ipairs(PVPHUB.compactSettingsWindow.ratingCheckboxes) do
                if cb.modernStyling then ApplyModernCheckboxStyling(cb, colors) end
            end
        end
        if PVPHUB.compactSettingsWindow.hideBGCheckbox and PVPHUB.compactSettingsWindow.hideBGCheckbox.modernStyling then
            ApplyModernCheckboxStyling(PVPHUB.compactSettingsWindow.hideBGCheckbox, colors)
        end
        if PVPHUB.compactSettingsWindow.hideInPvPCheckbox and PVPHUB.compactSettingsWindow.hideInPvPCheckbox.modernStyling then
            ApplyModernCheckboxStyling(PVPHUB.compactSettingsWindow.hideInPvPCheckbox, colors)
        end
        if PVPHUB.compactSettingsWindow.hideServerNamesCheckbox and PVPHUB.compactSettingsWindow.hideServerNamesCheckbox.modernStyling then
            ApplyModernCheckboxStyling(PVPHUB.compactSettingsWindow.hideServerNamesCheckbox, colors)
        end
    end
    
    -- Welcome window
    if PVPHUB.welcomeWindow then
        -- Blizzard buttons don't need custom styling, they automatically adapt to themes
        if PVPHUB.welcomeWindow.dontShowCheckbox and PVPHUB.welcomeWindow.dontShowCheckbox.modernStyling then
            ApplyModernCheckboxStyling(PVPHUB.welcomeWindow.dontShowCheckbox, colors)
        end
    end

    -- Refresh all dropdown button colors to match the new theme
    local dropdownsToRefresh = {
        _G["PVPHUBSortDropdown"],
        _G["PVPHUBColumnDropdown"],
        _G["PVPHUBThemeDropdown"],
    }
    if PVPHUB.window then
        if PVPHUB.window.fontDropdown        then table.insert(dropdownsToRefresh, PVPHUB.window.fontDropdown)        end
        if PVPHUB.window.themeDropdown       then table.insert(dropdownsToRefresh, PVPHUB.window.themeDropdown)       end
        if PVPHUB.window.dateFormatDropdown  then table.insert(dropdownsToRefresh, PVPHUB.window.dateFormatDropdown)  end
    end
    for _, dd in ipairs(dropdownsToRefresh) do
        RefreshDropdownColors(dd)
    end

    -- Refresh close button (silver — fixed, not theme-dependent)
    if PVPHUB.window and PVPHUB.window.closeButton then
        local cb = PVPHUB.window.closeButton
        if cb.normalTex    then cb.normalTex:SetVertexColor(0.82, 0.82, 0.88, 1) end
        if cb.pushedTex    then cb.pushedTex:SetVertexColor(0.55, 0.55, 0.60, 1) end
        if cb.highlightTex then cb.highlightTex:SetVertexColor(1, 1, 1, 1) end
    end

    -- Refresh main window action buttons and header row background
    if PVPHUB.window then
    end
end

local function RefreshAllWindows()
    -- Refresh main window if it exists
    if PVPHUB.window then
        -- Update main window colors
        local opacity = PVPHUB_SETTINGS.windowOpacity or 0.95
        if PVPHUB.window.bgTex then
            local c = UI_CONSTANTS.COLORS.WINDOW_BG
            ApplyWindowBGColor(PVPHUB.window, c[4] * opacity)
        end
        if PVPHUB.window.borderTex then
            local b = UI_CONSTANTS.COLORS.WINDOW_BORDER
            PVPHUB.window.borderTex:SetVertexColor(b[1], b[2], b[3], (b[4] or 1) * 0.3)
        end
        if PVPHUB.window.glowLayers then
            local g = UI_CONSTANTS.COLORS.WINDOW_GLOW
            local alphas = {0.25, 0.14, 0.07, 0.03}
            for i, tex in ipairs(PVPHUB.window.glowLayers) do
                tex:SetVertexColor(g[1], g[2], g[3], (alphas[i] or 0.05) * opacity)
            end
        end
        
        -- Update title color
        if PVPHUB.window.title then
            PVPHUB.window.title:SetTextColor(unpack(UI_CONSTANTS.COLORS.TITLE_COLOR))
        end
        
        -- Update scale slider with theme colors
        if PVPHUB.window.scaleSlider then
            -- MinimalSliderTemplate uses built-in styling, just update label color
            if PVPHUB.window.scaleLabel then
                PVPHUB.window.scaleLabel:SetTextColor(unpack(UI_CONSTANTS.COLORS.HEADER_COLOR))
            end
        end
        
        -- Update summary text color
        if PVPHUB.window.summaryText then
            PVPHUB.window.summaryText:SetTextColor(1, 1, 1, 1)
        end
        
        -- Update theme dropdown text
        if PVPHUB.window.themeDropdown then
            local themeNames = { BLUE = "Blue", RED = "Red", DARK = "Dark", MIDNIGHT = "Midnight", AURORA = "Aurora", CLASS = "Class" }
            local currentTheme = PVPHUB_SETTINGS.colorTheme or "RED"
            UIDropDownMenu_SetText(PVPHUB.window.themeDropdown, themeNames[currentTheme] or "Theme")
        end
        
        -- Update decorative lines
        if PVPHUB.window.titleLine then
            PVPHUB.window.titleLine:SetVertexColor(unpack(UI_CONSTANTS.COLORS.ACCENT_LINE))
        end
        
        if PVPHUB.window.summaryTopLine then
            PVPHUB.window.summaryTopLine:SetVertexColor(unpack(UI_CONSTANTS.COLORS.SUMMARY_LINE))
        end
        
        -- Refresh content to update headers and row backgrounds - BUT ONLY if in characters tab
        if PVPHUB.window.UpdateContent and PVPHUB.window.currentTab == "characters" then
            PVPHUB.window:UpdateContent()
        end
        
        -- Apply modern scrollbar styling to main window
        if PVPHUB.window.scrollFrame then
            ApplyModernScrollbarStyling(PVPHUB.window.scrollFrame, UI_CONSTANTS.COLORS)
        end
        
        -- Apply modern scrollbar styling to settings tab
        if PVPHUB.window.settingsScrollFrame then
            ApplyModernScrollbarStyling(PVPHUB.window.settingsScrollFrame, UI_CONSTANTS.COLORS)
        end
    end
    
    -- Refresh compact window if it exists
    if PVPHUB.compactWindow then
        if PVPHUB_SETTINGS.compactMode and PVPHUB_SETTINGS.compactMode.hideBackground then
            PVPHUB.compactWindow:SetBackdropColor(0, 0, 0, 0)
        else
            local color = PVPHUB_SETTINGS.compactMode and PVPHUB_SETTINGS.compactMode.backgroundColor or {unpack(UI_CONSTANTS.COLORS.COMPACT_BG)}
            PVPHUB.compactWindow:SetBackdropColor(color[1], color[2], color[3], color[4] or 0.8)
        end
        -- Update compact scale slider
        if PVPHUB.compactWindow.scaleSlider then
            PVPHUB.compactWindow.scaleLabel:SetTextColor(unpack(UI_CONSTANTS.COLORS.HEADER_COLOR))
        end
        -- Refresh compact window content
        if PVPHUB.UpdateCompactWindow then
            PVPHUB:UpdateCompactWindow()
        end
    end
    
    -- Refresh settings window if it exists
    if PVPHUB.compactSettingsWindow then
        PVPHUB.compactSettingsWindow:SetBackdropColor(unpack(UI_CONSTANTS.COLORS.SETTINGS_BG))
        PVPHUB.compactSettingsWindow:SetBackdropBorderColor(unpack(UI_CONSTANTS.COLORS.SETTINGS_BORDER))
        
        -- Update settings window title
        if PVPHUB.compactSettingsWindow.title then
            PVPHUB.compactSettingsWindow.title:SetTextColor(unpack(UI_CONSTANTS.COLORS.TITLE_COLOR))
        end
        
        -- Apply modern scrollbar styling to settings window
        if PVPHUB.compactSettingsWindow.charScrollFrame then
            ApplyModernScrollbarStyling(PVPHUB.compactSettingsWindow.charScrollFrame, UI_CONSTANTS.COLORS)
        end
    end
    
    -- Update all modern-styled buttons and checkboxes
    UpdateModernButtonAndCheckboxStyling()
end

-- Initialize theme immediately after function definition
ApplyTheme()

-- Enhanced function with custom max length parameter
local function CreateSafeCharacterDisplayWithLength(charKey, isCompactMode, maxDisplayLength)
    if not charKey or charKey == "" then
        return "Unknown Character"
    end
    
    -- Split character name and realm
    local name, realm = strsplit("-", charKey, 2)
    if not name or name == "" then
        return charKey -- Fallback to original if split fails
    end
    
    -- Hide server names based on the appropriate setting for each window type
    local shouldHideServerNames = false
    if isCompactMode then
        -- Compact window uses its own setting
        shouldHideServerNames = PVPHUB_SETTINGS.compactMode and PVPHUB_SETTINGS.compactMode.hideServerNames
    else
        -- Main window uses main window setting
        shouldHideServerNames = PVPHUB_SETTINGS.mainWindow and PVPHUB_SETTINGS.mainWindow.hideServerNames
    end
    
    -- If hiding server names, just return the character name
    if shouldHideServerNames then
        return name
    end
    
    -- If showing server names, truncate the SERVER name if the total length exceeds maxDisplayLength
    if realm and maxDisplayLength and maxDisplayLength > 0 then
        local fullName = string.format("%s-%s", name, realm)
        if string.len(fullName) > maxDisplayLength then
            -- Calculate how much space we have for the realm after keeping the full character name
            local remainingSpace = maxDisplayLength - string.len(name) - 1 -- -1 for the dash
            if remainingSpace > 3 then -- Need at least 3 chars for "xx."
                -- Truncate the realm/server name, not the character name
                if string.utf8len then
                    if string.utf8len(realm) > remainingSpace - 2 then
                        realm = string.utf8sub(realm, 1, remainingSpace - 3) .. "..."
                    end
                else
                    -- Fallback: regular truncation
                    realm = string.sub(realm, 1, remainingSpace - 3) .. "..."
                end
            else
                -- If no space for server name, hide it completely
                return name
            end
        end
    end
    
    -- Return character name with (possibly truncated) server name
    return realm and string.format("%s-%s", name, realm) or name
end

-- Enhanced function to create safe character display names with better Unicode support
local function CreateSafeCharacterDisplay(charKey, isCompactMode)
    -- For compact mode, use more aggressive truncation to prevent line wrapping
    -- For main window, also use reasonable truncation to prevent overlapping
    local maxDisplayLength = isCompactMode and 12 or 18  -- Reduced from 25 to 18 for main window
    return CreateSafeCharacterDisplayWithLength(charKey, isCompactMode, maxDisplayLength)
end

-- Create custom character tooltip frame
local CharacterTooltip = nil

local function CreateCharacterTooltip()
    if CharacterTooltip then
        return CharacterTooltip
    end
    
    CharacterTooltip = CreateFrame("GameTooltip", "PVPHUBCharacterTooltip", UIParent, "GameTooltipTemplate")
    CharacterTooltip:SetFrameStrata("TOOLTIP")
    CharacterTooltip:SetClampedToScreen(true)
    return CharacterTooltip
end

-- Helper function to format numbers with thousand separators (e.g., 6110 -> 6.110)
-- Thousand-separated number string, e.g. 12345 -> "12.345" (period, not comma
-- — matches the EU-style separator used throughout PVPHUB's UI).
local function FormatNumber(num)
    if not num or num == 0 then return "0" end

    local str = tostring(num)
    local result = ""
    local len = string.len(str)

    for i = 1, len do
        local char = string.sub(str, i, i)
        result = result .. char

        -- Add period every 3 digits from the right
        local remaining = len - i
        if remaining > 0 and remaining % 3 == 0 then
            result = result .. "."
        end
    end

    return result
end

-- Function to show character tooltip with detailed information
local function ShowCharacterTooltip(charKey, anchor)
    if not charKey or charKey == "" then
        return
    end
    
    local data = PVPHUB_DB[charKey]
    if not data then
        return
    end
    
    -- Split character name and realm
    local name, realm = strsplit("-", charKey, 2)
    if not name then
        name = charKey
    end
    
    -- Create and use custom tooltip
    local tooltip = CreateCharacterTooltip()
    
    tooltip:SetOwner(anchor, "ANCHOR_CURSOR")
    tooltip:ClearLines()
    
    -- Character name as title with class color
    tooltip:SetText("|cffFFD700Character|r", 1, 1, 1, 1, true)
    
    -- Get class color for character name
    local classColor = "|cffffffff" -- Default white
    if data.class then
        local classColors = {
            DEATHKNIGHT = "|cffc41e3a",
            DEMONHUNTER = "|cffa330c9",
            DRUID = "|cffff7c0a",
            EVOKER = "|cff33937f",
            HUNTER = "|cffaad372",
            MAGE = "|cff3fc7eb",
            MONK = "|cff00ff98",
            PALADIN = "|cfff48cba",
            PRIEST = "|cffffffff",
            ROGUE = "|cfffff468",
            SHAMAN = "|cff0070dd",
            WARLOCK = "|cff8788ee",
            WARRIOR = "|cffc69b6d"
        }
        classColor = classColors[data.class:upper()] or "|cffffffff"
    end
    
    tooltip:AddLine(classColor .. name .. "|r", 1, 1, 1)
    
    -- Realm
    if realm then
        tooltip:AddLine(" ")
        tooltip:AddLine("|cffFFD700Realm:|r", 1, 1, 1)
        tooltip:AddLine(realm, 0.8, 0.8, 1)
    end
    
    -- PVP Item Level only
    tooltip:AddLine(" ")
    local pvpItemLevel = data.pvpItemLevel or 0
    
    if pvpItemLevel > 0 then
        tooltip:AddLine("|cffFFD700PvP Item Level:|r", 1, 1, 1)
        tooltip:AddLine(tostring(pvpItemLevel), 0.8, 1, 0.8)
    else
        tooltip:AddLine("|cffFFD700PvP Item Level:|r", 1, 1, 1)
        tooltip:AddLine("Not available", 0.6, 0.6, 0.6)
    end
    
    -- Gold
    tooltip:AddLine(" ")
    tooltip:AddLine("|cffFFD700Gold:|r", 1, 1, 1)
    local gold = data.gold or 0
    if gold > 0 then
        -- Convert copper to gold/silver/copper and format like Blizzard UI
        local goldAmount = math.floor(gold / 10000)
        local silverAmount = math.floor((gold % 10000) / 100)
        local copperAmount = gold % 100
        
        local goldText = ""
        if goldAmount > 0 then
            goldText = FormatNumber(goldAmount) .. "|TInterface\\MoneyFrame\\UI-GoldIcon:0:0:2:0|t"
            if silverAmount > 0 then
                goldText = goldText .. " " .. FormatNumber(silverAmount) .. "|TInterface\\MoneyFrame\\UI-SilverIcon:0:0:2:0|t"
            end
            if copperAmount > 0 then
                goldText = goldText .. " " .. FormatNumber(copperAmount) .. "|TInterface\\MoneyFrame\\UI-CopperIcon:0:0:2:0|t"
            end
        elseif silverAmount > 0 then
            goldText = FormatNumber(silverAmount) .. "|TInterface\\MoneyFrame\\UI-SilverIcon:0:0:2:0|t"
            if copperAmount > 0 then
                goldText = goldText .. " " .. FormatNumber(copperAmount) .. "|TInterface\\MoneyFrame\\UI-CopperIcon:0:0:2:0|t"
            end
        else
            goldText = FormatNumber(copperAmount) .. "|TInterface\\MoneyFrame\\UI-CopperIcon:0:0:2:0|t"
        end
        
        tooltip:AddLine(goldText, 1, 1, 1)
    else
        tooltip:AddLine("0|TInterface\\MoneyFrame\\UI-CopperIcon:0:0:2:0|t", 0.6, 0.6, 0.6)
    end
    
    -- Last Updated
    tooltip:AddLine(" ")
    tooltip:AddLine("|cffFFD700Last Updated:|r", 1, 1, 1)
    if data.lastSeen then
        local currentTime = GetServerTime()
        local timeDiff = currentTime - data.lastSeen
        local daysDiff = math.floor(timeDiff / (24 * 60 * 60))
        
        local lastSeenText = ""
        local r, g, b = 1, 1, 1 -- Default white
        
        if daysDiff == 0 then
            lastSeenText = "Today"
            r, g, b = 0.2, 1, 0.2 -- Green for recent
        elseif daysDiff == 1 then
            lastSeenText = "Yesterday"
            r, g, b = 0.8, 1, 0.2 -- Yellow-green
        elseif daysDiff < 7 then
            lastSeenText = daysDiff .. " days ago"
            r, g, b = 1, 0.8, 0.2 -- Orange for getting old
        elseif daysDiff < 30 then
            lastSeenText = daysDiff .. " days ago"
            r, g, b = 1, 0.4, 0.2 -- Red-orange for old
        else
            lastSeenText = daysDiff .. " days ago"
            r, g, b = 1, 0.2, 0.2 -- Red for very old
        end
        
        tooltip:AddLine(lastSeenText, r, g, b)
    else
        tooltip:AddLine("Unknown", 0.6, 0.6, 0.6)
    end

    tooltip:Show()
end

-- Function to hide character tooltip
local function HideCharacterTooltip()
    if CharacterTooltip then
        CharacterTooltip:Hide()
    end
end

local function GetRatingColor(rating)
    -- Everything below 1800: white
    if rating < 1800 then
        return "|cffffffff"
    elseif rating < 1950 then
        -- 1800+: green
        return "|cff00ff00"
    elseif rating < 2100 then
        -- 1950+: blue
        return "|cff0070dd"
    elseif rating < 2300 then
        -- 2100+: purple
        return "|cffa335ee"
    elseif rating < 2700 then
        -- 2300+: orange (elite)
        return "|cffff8000"
    else
        -- 2700+: orange (glow effect not natively possible in WoW fontstrings, but you can add a star or special icon)
        -- Optionally, you could add a star icon or similar to indicate glow
        return "|cffff8000" -- |TInterface\\Common\\FavoritesIcon:14|t can be appended for a 'glow' effect
    end
end

-- Function to format numbers with periods as thousand separators (e.g., 15000 -> 15.000)
local function GetCurrencyColor(amount, currencyType, data)
    local currencyID = CURRENCY_IDS[currencyType]
    local cap = nil
    
    -- Handle currencies with automatic cap detection (Honor, Conquest, Bloody Tokens)
    if currencyID then
        local _cap = GetCachedCurrencyCap(currencyID)
        if _cap > 0 then cap = _cap end
    elseif currencyType == "bloodstones" then
        -- Check if heliotrope have a detectable cap via item information
        -- For now, keep the 1000 cap but this could be made dynamic in the future
        cap = 1000
    end
    
    -- Special handling for conquest and bloody tokens - use season maximum for color
    if (currencyType == "conquest" or currencyType == "bloodytokens") and data then
        local weeklyDataKey = currencyType .. "WeeklyData"
        local seasonData = data[weeklyDataKey]
        
        if seasonData and seasonData.seasonMaximum and cap and cap > 0 then
            -- Color based on season maximum progress, not weekly progress
            local seasonPercentage = seasonData.seasonMaximum / cap
            
            -- If season maximum exceeds cap, show red (fully earned)
            if seasonPercentage >= 1.0 then
                return "|cffff0000" -- Red for season cap reached
            end
            
            -- Use season progress for color calculation
            for _, tier in ipairs(CURRENCY_TIER_COLORS) do
                if seasonPercentage >= tier.threshold then
                    return tier.color
                end
            end
        end
    end
    
    -- No cap detected or cap is 0 - use default white color
    if not cap or cap == 0 then
        return "|cffffffff"
    end
    
    -- Apply color based on percentage of cap reached (same system as Honor)
    local percentage = amount / cap
    for _, tier in ipairs(CURRENCY_TIER_COLORS) do
        if percentage >= tier.threshold then
            return tier.color
        end
    end
    return "|cffffffff"
end

-- Returns (currentRating, displaySpecID, specCount, highestRating) for any bracket.
-- bracketKey defaults to "ratingShuffle" for backwards compatibility.
-- Handles both flat numbers (2v2, 3v3, legacy) and per-spec tables (Shuffle, Blitz).
local function GetShuffleDisplayInfo(data, charKey, bracketKey)
    bracketKey = bracketKey or "ratingShuffle"
    local bracketData = data[bracketKey]

    -- Flat number: 2v2/3v3, or legacy format before per-spec storage
    if type(bracketData) == "number" then
        return bracketData, nil, 1, bracketData
    end

    -- Per-spec table: Shuffle and Blitz
    if type(bracketData) == "table" then
        local currentSpecRating = 0
        local highestRating = 0
        local specCount = 0
        local currentSpecID = data.specID or data.lastActiveSpecID
        local highestSpecID = nil
        local displaySpecID = currentSpecID

        for specID, rating in pairs(bracketData) do
            if rating > 0 then
                specCount = specCount + 1
                if rating > highestRating then
                    highestRating = rating
                    highestSpecID = specID
                end
                if specID == currentSpecID then
                    currentSpecRating = rating
                end
            end
        end

        -- Only fall back to the highest spec when the current spec is genuinely
        -- unknown. A known spec with 0 rating means no history yet — keep 0.
        if (not currentSpecID or currentSpecID == 0) and highestRating > 0 then
            currentSpecRating = highestRating
            displaySpecID = highestSpecID
        end

        return currentSpecRating, displaySpecID, specCount, highestRating
    end

    return 0, nil, 0, 0
end

local function CreateCharacterName(entry, isCompactMode, suppressSpecIcon, suppressCurrentIndicator)
    local data = entry.data
    local class = data.class or "PRIEST"
    local color = RAID_CLASS_COLORS[class] or NORMAL_FONT_COLOR
    
    -- Spec icon (suppressed when rendered as a separate texture element in main list)
    local specIcon = ""
    if not suppressSpecIcon and data.specID then
        local _si = GetCachedSpecInfo(data.specID)
        if _si and _si.icon then
            specIcon = "|T" .. _si.icon .. ":14|t "
        end
    end
    
    -- Check for indicators that will add width
    local hasCurrentIndicator = not suppressCurrentIndicator and entry.char == GetFullName()
    local pinnedChar = PVPHUB_SETTINGS.mainWindow and PVPHUB_SETTINGS.mainWindow.pinnedCharacter
    local hasPinIndicator = pinnedChar == entry.char
    
    -- Calculate reduced max length based on icons present
    local iconCount = 0
    if specIcon ~= "" then iconCount = iconCount + 1 end
    if hasCurrentIndicator then iconCount = iconCount + 1 end
    if hasPinIndicator then iconCount = iconCount + 1 end
    
    -- Be more generous with space calculation - icons don't take as much space as we thought
    local baseMaxLength = isCompactMode and 12 or 30  -- Increased to 30 to match wider column
    local adjustedMaxLength = math.max(20, baseMaxLength - (iconCount * 1)) -- Higher minimum of 20 chars
    
    -- Use safe character display for better Unicode handling with adjusted length
    local displayName = CreateSafeCharacterDisplayWithLength(entry.char, isCompactMode, adjustedMaxLength)

    -- Build the icon prefix in a fixed order (spec/class icon, then current-character
    -- dot, then pin icon) so placement stays consistent whether specIcon is rendered
    -- here or suppressed and prepended externally (e.g. compact.lua's pinned-spec rows).
    local prefix = specIcon
    if hasCurrentIndicator then
        prefix = prefix .. "|TInterface\\Common\\Indicator-Green:12|t "
    end
    if hasPinIndicator then
        prefix = prefix .. "|TInterface\\Minimap\\UI-Minimap-ZoomInButton-Up:14|t "
    end

    local coloredName = string.format("%s|c%s%s|r", prefix, color.colorStr or "ffffffff", displayName)

    return coloredName
end

-- Data Update Functions with Protection
local function UpdateCurrencyData()
    local charKey = GetFullName()
    if not charKey or charKey == "" or charKey == "-" then 
        DebugPrint("Invalid character name, skipping data update")
        return 
    end
    
    if PVPHUB_IGNORED[charKey] then return end
    
    -- Ensure database integrity
    if not ValidateAndRestoreData() then
        DebugPrint("Database validation failed during currency update")
    end
    
    -- Create backup before making changes
    CreateDataBackup()

    -- Auto-detect PvP season changes and reset stale seasonal tracking data.
    -- This handles the case where conquest was uncapped (pre-season) and a new
    -- capped season starts - without this the old seasonMaximum would make every
    -- character look "fully capped" on day 1 of the new season.
    local currentSeason = (C_PvP and C_PvP.GetUIDisplaySeason and C_PvP.GetUIDisplaySeason()) or 0

    -- C_PvP.GetUIDisplaySeason() (and the rated-stat totals GetPersonalRatedInfo
    -- returns) can lag behind the actual in-game rollover by a while - Blizzard
    -- sometimes flips the "rated season" flag after the new season's Conquest
    -- cap/curve already went live. So also treat the Conquest cap itself
    -- changing as a season-boundary signal: it's currency-scoped and always
    -- moves immediately when a new season starts, even on days the season-ID
    -- check above misses.
    local conquestCapNow = 0
    do
        local ok, capInfo = pcall(C_CurrencyInfo.GetCurrencyInfo, CURRENCY_IDS.conquest)
        if ok and capInfo and capInfo.maxQuantity and capInfo.maxQuantity > 0 then
            conquestCapNow = capInfo.maxQuantity
        end
    end

    local lastSeason       = PVPHUB_SETTINGS.lastKnownSeasonID or 0
    local lastConquestCap  = PVPHUB_SETTINGS.lastKnownConquestCap or 0
    local seasonChangedByID  = currentSeason > 0 and currentSeason ~= lastSeason
    local seasonChangedByCap = conquestCapNow > 0 and lastConquestCap > 0 and conquestCapNow ~= lastConquestCap

    if seasonChangedByID or seasonChangedByCap then
        DebugPrint(string.format("Season change detected (season %d -> %d, conquest cap %d -> %d)",
            lastSeason, currentSeason, lastConquestCap, conquestCapNow))
        -- Clear all per-character seasonal tracking for every stored toon —
        -- see ClearCharacterSeasonData for the full field list and why it's
        -- centralized. bracketStats/wlData feed the Stats tab's "this
        -- season" totals and are each tagged with the season they were
        -- written under, but that guard only works once fresh,
        -- correctly-tagged data replaces them - wiping them here means an
        -- alt that hasn't logged in yet shows "no data this season" instead
        -- of last season's numbers indefinitely.
        for key, data in pairs(PVPHUB_DB) do
            if type(data) == "table" and key ~= "settings" then
                ClearCharacterSeasonData(data)
            end
        end

        if currentSeason > 0 then
            PVPHUB_SETTINGS.lastKnownSeasonID = currentSeason
        end
        -- Anchor point for IsCharacterStaleThisSeason: any character whose
        -- lastSeen predates this moment hasn't reported in since the season
        -- changed and gets dimmed in the roster until it logs in again.
        PVPHUB_SETTINGS.seasonStartTimestamp = GetServerTime()
        PVPHubPrint("|cffff0000[PVPHUB]|r New PvP season detected! Season tracking data has been automatically reset for all characters.")
    end

    if conquestCapNow > 0 then
        PVPHUB_SETTINGS.lastKnownConquestCap = conquestCapNow
    end

    -- Bootstrap: if a season boundary was already detected and reset under an
    -- older addon version (before seasonStartTimestamp existed), anchor it
    -- now rather than leaving every character permanently un-flaggable.
    if not PVPHUB_SETTINGS.seasonStartTimestamp then
        PVPHUB_SETTINGS.seasonStartTimestamp = GetServerTime()
    end

    PVPHUB_DB[charKey] = PVPHUB_DB[charKey] or {}

    -- Update currencies with error protection
    for currencyType, id in pairs(CURRENCY_IDS) do
        local success, info = pcall(C_CurrencyInfo.GetCurrencyInfo, id)
        if success and info then
            local currentAmount = info.quantity or 0
            local previousAmount = PVPHUB_DB[charKey][currencyType] or 0
            
            -- Special handling for conquest and bloody tokens to track season maximum
            if currencyType == "conquest" or currencyType == "bloodytokens" then
                -- Initialize season tracking if it doesn't exist
                local seasonDataKey = currencyType .. "WeeklyData" -- Keep same key for compatibility
                PVPHUB_DB[charKey][seasonDataKey] = PVPHUB_DB[charKey][seasonDataKey] or {}
                local seasonData = PVPHUB_DB[charKey][seasonDataKey]
                
                -- Initialize season maximum tracking
                if not seasonData.seasonMaximum then
                    -- Debug: Print all available currency info fields
                    DebugPrint("=== " .. currencyType .. " Currency Info Debug ===")
                    DebugPrint("  Current Amount: " .. currentAmount)
                    for k, v in pairs(info) do
                        DebugPrint("  " .. tostring(k) .. ": " .. tostring(v))
                    end
                    DebugPrint("==========================================")
                    
                    -- Calculate season maximum using available Blizzard data
                    local totalEarned = info.totalEarned or 0
                    local weeklyEarned = info.quantityEarnedThisWeek or 0
                    
                    -- The season maximum should be the highest amount ever held
                    -- This is typically: current amount + what was already spent this season
                    local estimatedMaximum = currentAmount
                    
                    -- If we have totalEarned, that represents total earned this season
                    if totalEarned > 0 then
                        estimatedMaximum = math.max(estimatedMaximum, totalEarned)
                        DebugPrint("Using totalEarned (" .. totalEarned .. ") as season maximum base")
                    end
                    
                    -- For conquest/bloody tokens, totalEarned should give us the real season maximum
                    if currencyType == "conquest" or currencyType == "bloodytokens" then
                        if totalEarned > currentAmount then
                            -- This means some was spent, totalEarned is the real maximum reached
                            estimatedMaximum = totalEarned
                            DebugPrint("Detected spending: current=" .. currentAmount .. ", totalEarned=" .. totalEarned .. ", using totalEarned as maximum")
                        else
                            -- No spending yet, current amount is the maximum
                            estimatedMaximum = currentAmount
                            DebugPrint("No spending detected, using current amount as maximum: " .. currentAmount)
                        end
                    end
                    
                    seasonData.seasonMaximum = estimatedMaximum
                    DebugPrint("Setting " .. currencyType .. " season maximum to: " .. estimatedMaximum)
                else
                    -- Update existing season maximum if we have better data
                    local totalEarned = info.totalEarned or 0
                    if totalEarned > (seasonData.seasonMaximum or 0) then
                        seasonData.seasonMaximum = totalEarned
                        DebugPrint("Updated " .. currencyType .. " season maximum to totalEarned: " .. totalEarned)
                    end
                end
                
                -- Track the highest amount ever reached this season
                -- Use totalEarned as the authoritative source for season maximum
                local totalEarned = info.totalEarned or 0
                
                if totalEarned > (seasonData.seasonMaximum or 0) then
                    seasonData.seasonMaximum = totalEarned
                    DebugPrint("Updated " .. currencyType .. " season maximum to: " .. totalEarned .. " (from totalEarned)")
                end
                
                -- Also check current amount in case totalEarned isn't available
                if currentAmount > (seasonData.seasonMaximum or 0) then
                    seasonData.seasonMaximum = currentAmount
                    DebugPrint("Updated " .. currencyType .. " season maximum to: " .. currentAmount .. " (from current amount)")
                end
                
                -- Force recalculation command (can be triggered manually)
                if seasonData.forceRecalculate then
                    seasonData.forceRecalculate = nil  -- Clear the flag
                    local totalEarned = info.totalEarned or 0
                    seasonData.seasonMaximum = math.max(totalEarned, currentAmount)
                    DebugPrint("Force recalculated " .. currencyType .. " season maximum to: " .. seasonData.seasonMaximum)
                end

                -- Sanity clamp: a stored season maximum can never legitimately
                -- exceed the currency's live cap. If it does, it's leftover
                -- from a prior (higher-cap) season that the season-change
                -- check above didn't catch in time (e.g. Blizzard's own
                -- totalEarned/season counters lagging the cap/curve update) -
                -- reset it from the live current amount so the tooltip can't
                -- show an impossible "5679 / 1600".
                if info.maxQuantity and info.maxQuantity > 0 and (seasonData.seasonMaximum or 0) > info.maxQuantity then
                    DebugPrint(currencyType .. " season maximum (" .. seasonData.seasonMaximum .. ") exceeds live cap (" ..
                        info.maxQuantity .. ") - stale prior-season data, resetting to current amount")
                    seasonData.seasonMaximum = currentAmount
                end

                -- For weekly cap detection, we still need to track weekly earnings
                local currentWeek = math.floor(GetServerTime() / (7 * 24 * 60 * 60))
                local weeklyEarned = info.quantityEarnedThisWeek or 0
                
                -- Initialize weekly tracking for cap detection
                if not seasonData.week or seasonData.week ~= currentWeek then
                    -- New week - reset weekly tracking but keep season maximum
                    seasonData.week = currentWeek
                    seasonData.weeklyEarned = 0
                    seasonData.cappedThisWeek = false
                end
                
                -- Use Blizzard's weekly earned data for more accuracy
                seasonData.weeklyEarned = weeklyEarned
                -- Store the weekly cap so alts can display progress even when offline
                if info.maxQuantity and info.maxQuantity > 0 then
                    seasonData.weeklyCapAmount = info.maxQuantity
                end
                
                -- Debug: Show all the values we're working with
                DebugPrint("=== " .. currencyType .. " Weekly Tracking Debug ===")
                DebugPrint("  Current Amount: " .. currentAmount)
                DebugPrint("  Previous Amount: " .. previousAmount) 
                DebugPrint("  Weekly Earned (Blizzard): " .. weeklyEarned)
                DebugPrint("  Total Earned (Blizzard): " .. (info.totalEarned or 0))
                DebugPrint("  Season Maximum: " .. (seasonData.seasonMaximum or 0))
                DebugPrint("  Weekly Cap: " .. (info.maxQuantity or 0))
                DebugPrint("==============================================")
                
                -- Check if weekly cap reached
                if info.maxQuantity and info.maxQuantity > 0 then
                    if weeklyEarned and weeklyEarned >= info.maxQuantity then
                        seasonData.cappedThisWeek = true
                        DebugPrint(currencyType .. " weekly cap reached: " .. weeklyEarned .. "/" .. info.maxQuantity)
                    else
                        seasonData.cappedThisWeek = false
                        DebugPrint(currencyType .. " weekly cap NOT reached: " .. (weeklyEarned or 0) .. "/" .. info.maxQuantity)
                    end
                end
                
                seasonData.lastUpdate = GetServerTime()
            end
            
            PVPHUB_DB[charKey][currencyType] = currentAmount
        else
            DebugPrint("Failed to get " .. currencyType .. " data")
        end
    end

    -- Update heliotrope with error protection
    local success, itemCount = pcall(GetItemCount, BLOODSTONE_ITEM_ID)
    if success then
        PVPHUB_DB[charKey].bloodstones = itemCount or 0
    end

    -- Update character info with error protection
    local specIndex = GetSpecialization()
    if specIndex then
        local success, specID = pcall(GetSpecializationInfo, specIndex)
        -- Guard against specID=0: in Lua 0 is truthy, so an explicit > 0 check is required
        if success and specID and specID > 0 then
            PVPHUB_DB[charKey].specID = specID
            PVPHUB_DB[charKey].lastActiveSpecID = specID
        end
    end

    local _, class = UnitClass("player")
    local race = select(2, UnitRace("player"))
    local gender = UnitSex("player")
    
    if class then PVPHUB_DB[charKey].class = class end
    if race then PVPHUB_DB[charKey].race = race end
    if gender then PVPHUB_DB[charKey].gender = gender end
    
    -- Store original character name for display purposes (helps with non-Latin characters)
    local originalName = UnitName("player")
    if originalName and originalName ~= "" then
        PVPHUB_DB[charKey].displayName = originalName
    end

    PVPHUB.RefreshUI()
end

-- Helper function to store/retrieve last known MMR for each spec
local function UpdateSpecMMRStorage(charKey, pvphubKey, specID, mmrValue)
    if not charKey or not pvphubKey or not specID or not mmrValue then return end
    
    -- Initialize storage
    PVPHUB_DB[charKey] = PVPHUB_DB[charKey] or {}
    PVPHUB_DB[charKey].lastKnownMMR = PVPHUB_DB[charKey].lastKnownMMR or {}
    PVPHUB_DB[charKey].lastKnownMMR[pvphubKey] = PVPHUB_DB[charKey].lastKnownMMR[pvphubKey] or {}
    
    -- Store the last known MMR for this spec
    PVPHUB_DB[charKey].lastKnownMMR[pvphubKey][specID] = {
        mmr = mmrValue,
        timestamp = GetServerTime(),
        specID = specID
    }
end

local function GetLastKnownMMRForSpec(charKey, pvphubKey, specID)
    if not charKey or not pvphubKey or not specID then return nil end
    if not PVPHUB_DB[charKey] or not PVPHUB_DB[charKey].lastKnownMMR then return nil end
    if not PVPHUB_DB[charKey].lastKnownMMR[pvphubKey] then return nil end
    
    return PVPHUB_DB[charKey].lastKnownMMR[pvphubKey][specID]
end

local function GetAllSpecMMRs(charKey, pvphubKey)
    if not charKey or not pvphubKey then return {} end
    if not PVPHUB_DB[charKey] or not PVPHUB_DB[charKey].lastKnownMMR then return {} end
    
    return PVPHUB_DB[charKey].lastKnownMMR[pvphubKey] or {}
end

-- Helper function to get the latest MMR change for a bracket
local function GetLatestMMRChange(charKey, bracketKey, currentSpecID)
    if not PVPHUB_DB[charKey] or not PVPHUB_DB[charKey].mmrHistory or not PVPHUB_DB[charKey].mmrHistory[bracketKey] then
        return nil, nil, nil
    end
    
    local history = PVPHUB_DB[charKey].mmrHistory[bracketKey]
    if #history == 0 then
        return nil, nil, nil
    end
    
    -- For shuffle/blitz, find the most recent match for the current spec
    if bracketKey == "ratingShuffle" or bracketKey == "ratingBlitz" then
        for i = #history, 1, -1 do
            local match = history[i]
            if match.specID == currentSpecID and match.preMatchMMR and match.postMatchMMR then
                return match.preMatchMMR, match.postMatchMMR, match.postMatchMMR - match.preMatchMMR
            end
        end
    else
        -- For arena, just get the most recent match
        local match = history[#history]
        if match and match.preMatchMMR and match.postMatchMMR then
            return match.preMatchMMR, match.postMatchMMR, match.postMatchMMR - match.preMatchMMR
        end
    end
    
    return nil, nil, nil
end

-- MMR Tracking functionality
-- Safely extract a number from a potentially tainted API value.
-- WoW secret numbers are truthy so "val or 0" won't fall back to 0;
-- wrapping in pcall lets us detect and discard them safely.
local function SafeN(val)
    if val == nil then return 0 end
    local ok, result = pcall(function() return val + 0 end)
    return (ok and type(result) == "number") and result or 0
end

local function UpdateMMRData()
    local charKey = GetFullName()
    if not charKey or not PVPHUB_DB[charKey] then 
        return 
    end
    
    -- Initialize MMR tracking if it doesn't exist
    PVPHUB_DB[charKey].mmrData = PVPHUB_DB[charKey].mmrData or {}
    
    -- Get current season
    local currentSeason = C_PvP and C_PvP.GetUIDisplaySeason and C_PvP.GetUIDisplaySeason() or 0
    if currentSeason > 0 then
        PVPHUB_DB[charKey].mmrData.season = currentSeason
    end
    
    -- Get player GUID
    local playerGUID = UnitGUID("player")
    if not playerGUID then return end
    
    -- Use the same API as MMRTracker: GetScoreInfoByPlayerGuid
    local success, scoreInfo = pcall(C_PvP.GetScoreInfoByPlayerGuid, playerGUID)
    if success and scoreInfo then
        -- Get current active bracket
        local bracket = C_PvP.GetActiveMatchBracket and C_PvP.GetActiveMatchBracket()
        if bracket and PVPHUB_TO_MMR_BRACKET then
            -- Get current specialization
            local specIndex = GetSpecialization()
            local currentSpecID = nil
            if specIndex then
                local success_spec, specID = pcall(GetSpecializationInfo, specIndex)
                if success_spec and specID then
                    currentSpecID = specID
                end
            end
            
            -- Find which PVPHUB key matches this bracket
            for pvphubKey, mmrBracketId in pairs(PVPHUB_TO_MMR_BRACKET) do
                if mmrBracketId == bracket then
                    local mmrValue = SafeN(scoreInfo.postmatchMMR) > 0 and SafeN(scoreInfo.postmatchMMR) or SafeN(scoreInfo.prematchMMR)
                    
                    if pvphubKey == "ratingShuffle" or pvphubKey == "ratingBlitz" then
                        -- Store MMR per spec for shuffle/blitz
                        PVPHUB_DB[charKey].mmrData[pvphubKey] = PVPHUB_DB[charKey].mmrData[pvphubKey] or {}
                        if currentSpecID and currentSpecID > 0 then
                            PVPHUB_DB[charKey].mmrData[pvphubKey][currentSpecID] = {
                                mmr = mmrValue,
                                rating = SafeN(scoreInfo.rating),
                                prematchMMR = SafeN(scoreInfo.prematchMMR),
                                postmatchMMR = SafeN(scoreInfo.postmatchMMR),
                                mmrChange = SafeN(scoreInfo.postmatchMMR) - SafeN(scoreInfo.prematchMMR),
                                ratingChange = SafeN(scoreInfo.ratingChange),
                                played = SafeN(scoreInfo.played),
                                won = SafeN(scoreInfo.won),
                                faction = SafeN(scoreInfo.faction),
                                lastUpdate = GetServerTime(),
                                specID = currentSpecID
                            }
                        end
                    else
                        -- Store single MMR for arenas (2v2/3v3).
                        -- The arena API (scoreInfo.prematchMMR / postmatchMMR) always returns 0
                        -- for 2v2/3v3; real team MMR is captured by TrackMMRChange via
                        -- GetBattlefieldTeamInfo. Only write here if we actually have a value
                        -- so we don't overwrite what TrackMMRChange already stored correctly.
                        if mmrValue > 0 then
                            PVPHUB_DB[charKey].mmrData[pvphubKey] = {
                                mmr = mmrValue,
                                rating = SafeN(scoreInfo.rating),
                                prematchMMR = SafeN(scoreInfo.prematchMMR),
                                postmatchMMR = SafeN(scoreInfo.postmatchMMR),
                                mmrChange = SafeN(scoreInfo.postmatchMMR) - SafeN(scoreInfo.prematchMMR),
                                ratingChange = SafeN(scoreInfo.ratingChange),
                                played = SafeN(scoreInfo.played),
                                won = SafeN(scoreInfo.won),
                                faction = SafeN(scoreInfo.faction),
                                lastUpdate = GetServerTime()
                            }
                        end
                    end
                    
                    -- Store MMR for the specific spec if we have a valid spec ID
                    if currentSpecID and mmrValue > 0 then
                        UpdateSpecMMRStorage(charKey, pvphubKey, currentSpecID, mmrValue)
                    end
                    
                    break
                end
            end
        end
    end
end

-- Lazy lookup table: "CLASSTOKEN|SpecName" → specID
-- Built once on first call; covers all specs without hard-coding IDs.
local _pvpSpecLookup = nil
local function GetSpecLookup()
    if _pvpSpecLookup then return _pvpSpecLookup end
    _pvpSpecLookup = {}
    for specID = 60, 1500 do
        local _si = GetCachedSpecInfo(specID)
        if _si and _si.classFile then
            _pvpSpecLookup[_si.classFile .. "|" .. _si.name] = specID
        end
    end
    return _pvpSpecLookup
end

-- Function to track MMR changes after matches (called by PVP_MATCH_COMPLETE)
-- eventWinner: winner value passed from the event payload (avoids GetBattlefieldWinner returning 4294967295)
local function TrackMMRChange(retryCount, eventWinner)
    retryCount = retryCount or 0
    
    local charKey = GetFullName()
    if not charKey or not PVPHUB_DB[charKey] then 
        -- Retry if this is first attempt
        if retryCount < 2 then
            C_Timer.After(1, function() TrackMMRChange(retryCount + 1, eventWinner) end)
        end
        return 
    end
    
    -- Get player GUID for score info
    local playerGUID = UnitGUID("player")
    if not playerGUID then 
        -- Retry if this is first attempt
        if retryCount < 2 then
            C_Timer.After(1, function() TrackMMRChange(retryCount + 1, eventWinner) end)
        end
        return 
    end
    
    -- Get active bracket.  After a fast lobby exit the player may already be in a
    -- new zone; fall back to the bracket snapshotted at PVP_MATCH_COMPLETE time.
    local bracket = (C_PvP.GetActiveMatchBracket and C_PvP.GetActiveMatchBracket())
                    or PVPHUB._lastMatchBracket

    if not bracket or not MMR_BRACKETS[bracket] then
        -- If we have no bracket at all, retrying will never help — give up.
        return
    end
    
    -- Map bracket to our key system
    local pvphubKey = nil
    for key, bracketId in pairs(PVPHUB_TO_MMR_BRACKET) do
        if bracketId == bracket then
            pvphubKey = key
            break
        end
    end
    
    
    if not pvphubKey then 
        return 
    end
    
    -- Get match info using MMRTracker method.
    -- Fall back to the scoreInfo snapshot when the player already left the instance.
    local usingSnapshot = false
    local success, scoreInfo = pcall(C_PvP.GetScoreInfoByPlayerGuid, playerGUID)
    if not success or not scoreInfo then
        if PVPHUB._pendingMatchScoreInfo then
            scoreInfo    = PVPHUB._pendingMatchScoreInfo
            usingSnapshot = true
        elseif PVPHUB._earlyExitScoreInfo then
            -- Late retry after an early-exit (opponent left): the initial call already
            -- consumed _pendingMatchScoreInfo via Guard 2, but saved a copy here so
            -- the PVP_RATED_STATS_UPDATE retry path can still record the match.
            scoreInfo    = PVPHUB._earlyExitScoreInfo
            usingSnapshot = true
        else
            -- Live API unavailable and no snapshot — retry up to twice
            if retryCount < 2 then
                C_Timer.After(1, function() TrackMMRChange(retryCount + 1, eventWinner) end)
            else
                PVPHubPrint("|cffff8800[PVPHUB]|r Match not recorded — score data unavailable (disconnect/reload during match?).")
            end
            return
        end
    end
    -- Snapshot consumed; clear it so a later (normal) call does not reuse stale data.
    -- _pendingMatchRatingChange is NOT cleared here — Guard 2 (below) still needs it.
    PVPHUB._pendingMatchScoreInfo = nil
    
    -- Get current spec ID for this match
    local currentSpecID = PVPHUB_DB[charKey].specID or PVPHUB_DB[charKey].lastActiveSpecID or 0
    
    -- For arena brackets (2v2, 3v3), we track team MMR without changes
    local preMatchMMR = scoreInfo.prematchMMR or 0
    local postMatchMMR = scoreInfo.postmatchMMR or 0
    local currentRating = scoreInfo.rating or 0
    local teamMMR = 0
    local pendingTeammateSpecs = nil   -- filled for arena brackets only
    local pendingOpponentSpecs  = nil   -- filled for arena brackets only

    if bracket == 0 or bracket == 1 then -- 2v2 or 3v3
        -- Set faction for battlefield score (MMRTracker approach)
        if SetBattlefieldScoreFaction then
            pcall(SetBattlefieldScoreFaction, -1)
        end

        -- Get team info: teamName, oldTeamRating, newTeamRating, teamMMR
        local teamOk, teamName, oldTeamRating, newTeamRating, currentTeamMMR = pcall(GetBattlefieldTeamInfo, scoreInfo.faction or 0)
        if not teamOk then currentTeamMMR = nil end
        if currentTeamMMR and currentTeamMMR > 0 then
            teamMMR = currentTeamMMR
            -- For arenas, we track current team MMR without showing changes
            preMatchMMR = teamMMR
            postMatchMMR = teamMMR
            PVPHubPrint(string.format("|cff00ff00[PVPHUB]|r Team MMR: %d (no delta tracking)", teamMMR))

            -- Collect teammate and opponent specs from the post-match scoreboard
            local playerFaction = scoreInfo.faction or 0
            local numScores = GetNumBattlefieldScores and GetNumBattlefieldScores() or 0
            if numScores > 0 then
                local lookup = GetSpecLookup()
                for idx = 0, numScores - 1 do
                    local ok2, s = pcall(C_PvP.GetScoreInfo, idx)
                    -- Skip entries with no classToken (blank placeholder rows)
                    if ok2 and s and s.guid ~= playerGUID and s.classToken then
                        local sID = 0
                        if s.talentSpec and s.classToken then
                            sID = lookup[s.classToken .. "|" .. s.talentSpec] or 0
                        end
                        local entry = { specID = sID, name = s.name or "", classToken = s.classToken }
                        if s.faction == playerFaction then
                            pendingTeammateSpecs = pendingTeammateSpecs or {}
                            table.insert(pendingTeammateSpecs, entry)
                        else
                            pendingOpponentSpecs = pendingOpponentSpecs or {}
                            table.insert(pendingOpponentSpecs, entry)
                        end
                    end
                end
            end
        elseif usingSnapshot then
            -- Player left the lobby before the timer fired; live battlefield APIs
            -- are gone.  Use scoreInfo's own pre/post MMR — teamMMR stays 0.
            -- Spec collection is unavailable but the match result is still valid.
            PVPHubPrint("|cffaaaaaa[PVPHUB]|r Team MMR unavailable (left lobby early); match still recorded.")
        else
            -- Live data not yet available and no snapshot — retry
            if retryCount < 2 then
                C_Timer.After(1, function() TrackMMRChange(retryCount + 1, eventWinner) end)
            end
            return
        end
    end
    
    -- Initialize match history if needed
    PVPHUB_DB[charKey].mmrHistory = PVPHUB_DB[charKey].mmrHistory or {}
    PVPHUB_DB[charKey].mmrHistory[pvphubKey] = PVPHUB_DB[charKey].mmrHistory[pvphubKey] or {}
    
    -- Create match record with proper MMR handling
    if bracket == 0 or bracket == 1 then -- 2v2 or 3v3 arenas
        if teamMMR == 0 then
            -- Retry if this is first attempt
            if retryCount < 2 then
                C_Timer.After(1, function() TrackMMRChange(retryCount + 1, eventWinner) end)
            end
            return
        end
    else
        -- For Solo Shuffle/Blitz: PVP_MATCH_COMPLETE fires after EACH of the 6 rounds,
        -- but rating and MMR only update after the full set completes.
        -- Guard 1: both MMR values are zero → data not ready yet, retry.
        if preMatchMMR == 0 and postMatchMMR == 0 then
            if retryCount < 2 then
                C_Timer.After(1, function() TrackMMRChange(retryCount + 1, eventWinner) end)
            end
            return
        end
        -- Guard 2 (Solo Shuffle only): ratingChange == 0 on an intermediate round (1-5).
        -- C_PvP.IsRatedSoloShuffle() is true only during an active Solo Shuffle set,
        -- so this guard only fires for Shuffle, not Blitz.
        local isSoloShuffle = C_PvP.IsRatedSoloShuffle and C_PvP.IsRatedSoloShuffle()
        -- Prefer the ratingChange captured at PVP_MATCH_COMPLETE time: Blizzard's own UI
        -- reads GetScoreInfoByPlayerGuid with no delay, confirming it is authoritative then.
        -- The live API re-called here at +0.5s can return stale 0 after zone transition.
        local effectiveRatingChange = PVPHUB._pendingMatchRatingChange or (scoreInfo.ratingChange or 0)
        PVPHUB._pendingMatchRatingChange = nil
        if isSoloShuffle and effectiveRatingChange == 0 then
            -- Exception: PVP_RATED_STATS_UPDATE already fired and confirmed this is the
            -- final round (fast path). _shuffleFreshRounds is set with round W/L data.
            -- Don't skip — fall through so the record is created and the data consumed.
            if not PVPHUB._shuffleFreshRounds then
                if PVPHUB._shuffleLobbyActive then
                    -- Lobby is active — this is an intermediate round OR an early exit
                    -- (opponent left before all 6 rounds). Save scoreInfo so that when
                    -- PVP_RATED_STATS_UPDATE fires late and retries TrackMMRChange,
                    -- it can still build the match record even though _pendingMatchScoreInfo
                    -- will already be nil by then.
                    PVPHUB._earlyExitScoreInfo = scoreInfo
                else
                    -- No active lobby: this is a genuine disconnect/reload mid-match.
                    local _snapPlayed = GetPreLobbySnapshot(charKey)
                    if _snapPlayed == nil then
                        PVPHubPrint("|cffff8800[PVPHUB]|r Match not recorded — rating data unavailable (disconnect/reload during match?).")
                    end
                end
                return
            end
        end
    end
    
    local matchData = {
        timestamp = GetServerTime(),
        bracket = bracket,
        bracketName = MMR_BRACKETS[bracket],
        preMatchMMR = preMatchMMR,
        postMatchMMR = postMatchMMR,
        -- Use scoreInfo.mmrChange directly (native API field, added 10.1.0) rather
        -- than recomputing; fall back to manual calculation for older clients.
        mmrChange = SafeN(scoreInfo.mmrChange) ~= 0 and SafeN(scoreInfo.mmrChange) or (postMatchMMR - preMatchMMR),
        rating = scoreInfo.rating or 0,
        ratingChange = scoreInfo.ratingChange or 0,
        -- winner comes from the event payload passed in; avoids GetBattlefieldWinner()
        -- which can return 4294967295 (0xFFFFFFFF) for Shuffle intermediate rounds.
        winner = eventWinner or 0,
        -- playerFaction lets the tooltip determine W/L when ratingChange==0
        -- (e.g. floor-protection loss: CR stays at 0 but the player still lost).
        playerFaction = scoreInfo.faction or 0,
        season = C_PvP.GetUIDisplaySeason and C_PvP.GetUIDisplaySeason() or 0,
        specID = currentSpecID,
        teammateSpecs  = pendingTeammateSpecs,   -- nil for non-arena; {specID, name} list for 2v2/3v3
        opponentSpecs  = pendingOpponentSpecs,    -- nil for non-arena; {specID, name} list for 2v2/3v3
    }
    
    -- Add to history (retained for the whole current season, see below)
    if pvphubKey == "ratingShuffle" and PVPHUB._shuffleRecordedThisLobby then
        return  -- retry and original timer both reached here; only record once
    end
    if pvphubKey == "ratingShuffle" then
        PVPHUB._shuffleRecordedThisLobby = true
        PVPHUB._earlyExitScoreInfo = nil  -- consumed; prevent stale reuse in next lobby
    end
    table.insert(PVPHUB_DB[charKey].mmrHistory[pvphubKey], matchData)
    local history = PVPHUB_DB[charKey].mmrHistory[pvphubKey]
    -- Season-aware retention: entries are appended in chronological order, so any
    -- stale season only ever sits at the front. Drop those instead of capping by
    -- count, so the full current season survives regardless of match volume.
    while history[1] and history[1].season ~= matchData.season do
        table.remove(history, 1)
    end

    -- Live-refresh the Season tab if it's the one currently on screen, so a
    -- match that just finished shows up immediately instead of needing a
    -- tab-switch to force a re-render. Cheap: only fires right after a match
    -- is recorded, and only rebuilds anything if that tab is actually visible.
    if PVPHUB.window and PVPHUB.window:IsShown() and PVPHUB.window.currentTab == "stats"
       and PVPHUB.window.statsFrame and PVPHUB.window.RenderStatsFor then
        PVPHUB.window.RenderStatsFor()
    end

    -- For arena brackets: re-collect specs after a delay in case some entries had
    -- no classToken at record time. Retries up to 3x until expected counts are met.
    -- Expected: 2v2 → 1 teammate + 2 opponents; 3v3 → 2 teammates + 3 opponents
    if bracket == 0 or bracket == 1 then
        local expectedOpps      = (bracket == 0) and 2 or 3
        local expectedTeammates = (bracket == 0) and 1 or 2
        local capturedFaction   = scoreInfo.faction or 0
        local function TryPatchSpecs(attempt)
            local hist = PVPHUB_DB[charKey] and PVPHUB_DB[charKey].mmrHistory
                         and PVPHUB_DB[charKey].mmrHistory[pvphubKey]
            if not hist or #hist == 0 then return end
            local record = hist[#hist]
            if not record.timestamp or (GetServerTime() - record.timestamp) > 90 then return end
            -- MUST reset faction filter to -1 (all) before querying scores.
            -- GetNumBattlefieldScores respects the active faction filter; by the time this
            -- deferred function fires the game may have reset it to show only one team,
            -- causing us to see 0 opponents and never patch the missing dead player.
            if SetBattlefieldScoreFaction then SetBattlefieldScoreFaction(-1) end
            local numScores = GetNumBattlefieldScores and GetNumBattlefieldScores() or 0
            if numScores == 0 then return end
            local lookup = GetSpecLookup()
            local newTeammates, newOpponents = {}, {}
            for idx = 0, numScores - 1 do
                local ok2, s = pcall(C_PvP.GetScoreInfo, idx)
                -- Use GUID prefix to identify real players (not blank placeholder rows).
                -- Do NOT gate on s.classToken here – a player who died early can have a
                -- valid GUID but a nil classToken for several seconds after the match.
                if ok2 and s and s.guid ~= playerGUID
                        and type(s.guid) == "string" and s.guid:sub(1, 7) == "Player-" then
                    local sID = 0
                    if s.talentSpec and s.classToken then
                        sID = lookup[s.classToken .. "|" .. s.talentSpec] or 0
                    end
                    local entry = { specID = sID, name = s.name or "", classToken = s.classToken }
                    if s.faction == capturedFaction then
                        table.insert(newTeammates, entry)
                    else
                        table.insert(newOpponents, entry)
                    end
                end
            end
            if #newTeammates > 0 then record.teammateSpecs = newTeammates end
            if #newOpponents > 0 then record.opponentSpecs = newOpponents end
            -- Retry if counts are still short OR if any slot is still missing its classToken
            -- (can happen for players who died early – their entry stays in the scoreboard
            -- but classToken may be nil until the server finishes populating the data).
            local allFull = true
            for _, e in ipairs(newOpponents) do
                if not e.classToken or e.classToken == "" then allFull = false; break end
            end
            for _, e in ipairs(newTeammates) do
                if not e.classToken or e.classToken == "" then allFull = false; break end
            end
            local stillMissing = (#newOpponents < expectedOpps)
                               or (#newTeammates < expectedTeammates)
                               or not allFull
            if stillMissing and attempt < 3 then
                local delay = attempt == 1 and 2 or 4
                C_Timer.After(delay, function() TryPatchSpecs(attempt + 1) end)
            end
        end
        C_Timer.After(0.8, function() TryPatchSpecs(1) end)
    end
    
    -- For Solo Shuffle: attach per-lobby round W/L to the match record.
    -- Priority order:
    --   1) _shuffleFreshRounds: PVP_RATED_STATS_UPDATE already fired and pre-computed
    --      the delta (fast-server path where the event beats this +0.5s timer).
    --   2) Direct API read: server responded between PVP_MATCH_COMPLETE and now.
    --   3) Deferred: _pendingShuffleRoundCompute was pre-armed at PVP_MATCH_COMPLETE;
    --      PVP_RATED_STATS_UPDATE will patch hist[#hist] when server data arrives.
    if pvphubKey == "ratingShuffle" then
        if PVPHUB._shuffleFreshRounds then
            matchData.roundsWon  = PVPHUB._shuffleFreshRounds.won
            matchData.roundsLost = PVPHUB._shuffleFreshRounds.lost
            PVPHUB._shuffleFreshRounds = nil
            PVPHUB._pendingShuffleRoundCompute = false
            PVPHUB._shuffleLobbyActive = false
            ClearPreLobbySnapshot(charKey)
        else
            local nowPlayed = select(12, GetPersonalRatedInfo(7)) or 0
            local nowWon    = select(13, GetPersonalRatedInfo(7)) or 0
            local preLobbyPlayed, preLobbyWon = GetPreLobbySnapshot(charKey)
            local roundsPlayed = math.max(0, nowPlayed - (preLobbyPlayed or 0))
            local roundsWon    = math.max(0, nowWon    - (preLobbyWon    or 0))
            local roundsLost   = math.max(0, roundsPlayed - roundsWon)
            if roundsPlayed >= 1 and roundsPlayed <= 6 then
                matchData.roundsWon  = roundsWon
                matchData.roundsLost = roundsLost
                PVPHUB._pendingShuffleRoundCompute = false
                PVPHUB._shuffleLobbyActive = false
                ClearPreLobbySnapshot(charKey)
            end
            -- If still out of range, _pendingShuffleRoundCompute stays true (pre-armed
            -- at PVP_MATCH_COMPLETE) and PVP_RATED_STATS_UPDATE patches hist[#hist].
        end
    end
    
    -- Single success message
    PVPHubPrint("|cff00ff00[PVPHUB]|r Match recorded!")
    
    -- Update current MMR data for tooltips - STORE PER SPEC for Solo Shuffle/Blitz
    PVPHUB_DB[charKey].mmrData = PVPHUB_DB[charKey].mmrData or {}
    
    if pvphubKey == "ratingShuffle" or pvphubKey == "ratingBlitz" then
        -- Store MMR per spec (like ratings)
        PVPHUB_DB[charKey].mmrData[pvphubKey] = PVPHUB_DB[charKey].mmrData[pvphubKey] or {}
        if currentSpecID and currentSpecID > 0 then
            PVPHUB_DB[charKey].mmrData[pvphubKey][currentSpecID] = {
                mmr = postMatchMMR,  -- Use postMatchMMR directly instead of scoreInfo
                rating = scoreInfo.rating or 0,
                prematchMMR = preMatchMMR,
                postmatchMMR = postMatchMMR,
                mmrChange = matchData.mmrChange,
                ratingChange = scoreInfo.ratingChange or 0,
                lastUpdate = GetServerTime(),
                specID = currentSpecID
            }
            -- Update lastKnownMMR for tooltip compatibility
            if postMatchMMR and postMatchMMR > 0 then
                UpdateSpecMMRStorage(charKey, pvphubKey, currentSpecID, postMatchMMR)
            end
        end
    else
        -- Store single MMR for arenas (2v2/3v3)
        PVPHUB_DB[charKey].mmrData[pvphubKey] = {
            mmr = postMatchMMR,  -- Use postMatchMMR directly instead of scoreInfo
            rating = scoreInfo.rating or 0,
            prematchMMR = preMatchMMR,
            postmatchMMR = postMatchMMR,
            mmrChange = matchData.mmrChange,
            ratingChange = scoreInfo.ratingChange or 0,
            lastUpdate = GetServerTime(),
            specID = currentSpecID
        }
        -- Update lastKnownMMR for tooltip compatibility
        if currentSpecID and postMatchMMR and postMatchMMR > 0 then
            UpdateSpecMMRStorage(charKey, pvphubKey, currentSpecID, postMatchMMR)
        end
    end
    
    -- Force refresh compact mode display if it's visible
    if PVPHUB_CompactModeFrame and PVPHUB_CompactModeFrame:IsShown() then
        C_Timer.After(0.1, function()
            RefreshCompactModeContent()
        end)
    end
end

-- Helper function to get win/loss statistics for a bracket from Blizzard API
local function GetWinLossStats(charKey, bracketKey, specID)
    local currentCharKey = GetFullName()
    local currentSeason  = (C_PvP and C_PvP.GetUIDisplaySeason and C_PvP.GetUIDisplaySeason()) or 0

    -- ── Helper: read from bracketStats with optional season validation ──────
    local function FromBracketStats(data)
        local bs = data and data.bracketStats and data.bracketStats[bracketKey]
        if not bs then return nil end
        -- Per-spec lookup for Shuffle/Blitz (bracketStats[key] is keyed by specID)
        if specID then
            bs = type(bs) == "table" and bs[specID] or nil
            if not bs then return nil end
        end
        -- Season guard: ignore data from a different PvP season.
        if currentSeason > 0 and bs.season and bs.season ~= currentSeason then
            return nil  -- stale season — caller should return 0,0,0
        end
        local w = bs.won  or 0
        local l = bs.lost or 0
        local t = w + l
        return w, l, t > 0 and (w / t * 100) or 0
    end

    -- ── Helper: read from legacy wlData with optional season validation ─────
    local function FromWLData(data)
        local wd = data and data.wlData and data.wlData[bracketKey]
        if not wd then return nil end
        if currentSeason > 0 and wd.season and wd.season ~= currentSeason then
            return nil  -- stale season
        end
        return wd.wins or 0, wd.losses or 0, wd.winrate or 0
    end

    -- ── Current character ────────────────────────────────────────────────────
    if charKey == currentCharKey then
        -- When the server has confirmed fresh data, bracketStats is authoritative.
        -- pvp_tracking.lua writes bracketStats BEFORE this function is called
        -- (its PVP_RATED_STATS_UPDATE handler fires first, then ours).
        if PVPHUB._pvpCacheReady then
            local w, l, wr = FromBracketStats(PVPHUB_DB[charKey])
            if w then return w, l, wr end
        end

        -- Live API only gives the CURRENT spec's data — skip it for inactive specs.
        if specID then
            local curSpec = PVPHUB_DB[charKey] and (PVPHUB_DB[charKey].specID or PVPHUB_DB[charKey].lastActiveSpecID)
            if specID ~= curSpec then return 0, 0, 0 end
        end

        -- Cache not ready or bracketStats missing — fall back to live API.
        -- This path is used during the brief window before PVP_RATED_STATS_UPDATE
        -- fires; the result is display-only and will be overwritten once cache is ready.
        local bracketConfig = {
            rating2v2    = { apiIndex = 1, winsIndex = 5,  totalIndex = 4  },
            rating3v3    = { apiIndex = 2, winsIndex = 5,  totalIndex = 4  },
            ratingRBG    = { apiIndex = 4, winsIndex = 5,  totalIndex = 4  },
            ratingShuffle = { apiIndex = 7, winsIndex = 13, totalIndex = 12 },
            ratingBlitz  = { apiIndex = 9, winsIndex = 5,  totalIndex = 4  },
        }
        local config = bracketConfig[bracketKey]
        if not config then return 0, 0, 0 end
        local wins  = select(config.winsIndex,  GetPersonalRatedInfo(config.apiIndex)) or 0
        local total = select(config.totalIndex, GetPersonalRatedInfo(config.apiIndex)) or 0
        if total == 0 then return 0, 0, 0 end
        return wins, total - wins, (wins / total) * 100
    end

    -- ── Alt characters ───────────────────────────────────────────────────────
    -- bracketStats is the primary source because it stores the season number.
    -- Fall back to wlData (older format, may lack season field).
    local charData = PVPHUB_DB[charKey]
    if charData then
        local w, l, wr = FromBracketStats(charData)
        if w ~= nil then return w, l, wr end
        w, l, wr = FromWLData(charData)
        if w ~= nil then return w, l, wr end
    end
    return 0, 0, 0
end

-- ============================================================
-- Stats tab data helpers (season recap)
-- Pure read functions over PVPHUB_DB — no side effects, safe to call for any
-- stored character (not just the logged-in one).
-- ============================================================

-- Summarizes one bracket's season performance for a character, collapsing
-- Shuffle/Blitz's per-spec bracketStats tables into a single season total.
-- Returns nil if there's no data (or only stale, prior-season data).
local function GetBracketSeasonSummary(charKey, bracketKey)
    local data = PVPHUB_DB and PVPHUB_DB[charKey]
    local bs = data and data.bracketStats and data.bracketStats[bracketKey]
    if not bs then return nil end
    local currentSeason = (C_PvP and C_PvP.GetUIDisplaySeason and C_PvP.GetUIDisplaySeason()) or 0

    if bracketKey == "ratingShuffle" or bracketKey == "ratingBlitz" then
        local summary, mostRecent, mostRecentTime = nil, nil, -1
        for _, spec in pairs(bs) do
            if type(spec) == "table" and (currentSeason == 0 or not spec.season or spec.season == currentSeason) then
                summary = summary or { played = 0, won = 0, lost = 0, seasonBest = 0 }
                summary.played     = summary.played + (spec.played or 0)
                summary.won        = summary.won + (spec.won or 0)
                summary.lost       = summary.lost + (spec.lost or 0)
                summary.seasonBest = math.max(summary.seasonBest, spec.seasonBest or 0)
                if (spec.lastUpdated or 0) > mostRecentTime then
                    mostRecentTime = spec.lastUpdated or 0
                    mostRecent = spec
                end
            end
        end
        if not summary then return nil end
        summary.rating = mostRecent and mostRecent.rating or 0
        return summary
    end

    if currentSeason > 0 and bs.season and bs.season ~= currentSeason then
        return nil
    end
    return {
        played     = bs.played or 0,
        won        = bs.won or 0,
        lost       = bs.lost or 0,
        seasonBest = bs.seasonBest or 0,
        rating     = bs.rating or 0,
        ranking    = bs.ranking,
    }
end

-- ============================================================
-- PVPHUB Custom Rating Tooltip
-- Replaces GameTooltip for rating card hover tooltips so we
-- get exact 3-column alignment in the match history section.
-- ============================================================

-- Class icon fallback for when spec lookup fails
local _classIconNames = {
    WARRIOR="Warrior", PALADIN="Paladin", HUNTER="Hunter", ROGUE="Rogue",
    PRIEST="Priest", DEATHKNIGHT="DeathKnight", SHAMAN="Shaman", MAGE="Mage",
    WARLOCK="Warlock", MONK="Monk", DRUID="Druid", DEMONHUNTER="DemonHunter",
    EVOKER="Evoker",
}
local function GetSpecOrClassIcon(specID, classToken)
    if specID and specID > 0 then
        local _si = GetCachedSpecInfo(specID)
        if _si and _si.icon then return _si.icon end
    end
    if classToken and _classIconNames[classToken] then
        return "Interface\\Icons\\ClassIcon_" .. _classIconNames[classToken]
    end
end

-- ============================================================
-- Season tab data helpers — file scope (not nested in CreateStatsFrame) so
-- they're available as plain upvalues to the Stats tab's RenderSeasonOverview
-- (built lazily, widgets only).
-- ============================================================

-- Icon paths reused from COLUMN_HEADERS (line ~710) — already proven to
-- render correctly elsewhere in this addon's Characters tab, unlike the
-- guessed paths this card list originally shipped with (Solo Shuffle's
-- in particular didn't exist and rendered blank).
local BRACKET_META = {
    { key = "rating2v2",     label = "2v2 Arena",            color = {0.65, 0.20, 0.20}, icon = "Interface\\Icons\\achievement_arena_2v2_1" },
    { key = "rating3v3",     label = "3v3 Arena",            color = {0.20, 0.45, 0.65}, icon = "Interface\\Icons\\achievement_arena_3v3_1" },
    { key = "ratingRBG",     label = "Rated Battlegrounds",  color = {0.20, 0.55, 0.25}, icon = "Interface\\Icons\\achievement_pvp_a_15" },
    { key = "ratingShuffle", label = "Solo Shuffle",         color = {0.55, 0.30, 0.65}, icon = "Interface\\Icons\\ability_dualwield" },
    { key = "ratingBlitz",   label = "Blitz",                color = {0.65, 0.50, 0.10}, icon = "Interface\\Icons\\achievement_bg_killxenemies_generalsroom" },
}

-- Season title achievements (Legend/Strategist/Gladiator) — mirrors the IDs
-- tracked in modules/pvp_tracking.lua's TITLE_ACHIEVEMENTS. Reuses each
-- title's parent bracket's color/icon so the cards read as a family with
-- the per-bracket cards below them.
-- Render order (left-to-right in the Season tab's tile row): Gladiator,
-- Legend, Strategist.
--
-- reqTemplate is hardcoded rather than read live from GetAchievementInfo's
-- description field: that field is unreliable right after login/reload
-- (WoW doesn't always have it cached until the Blizzard Achievement UI has
-- been opened once this session), so the tooltip would silently show
-- nothing. The template only hardcodes the stable wording ("Win N games
-- while at Elite rank during <season>") — the win count (%d) and season
-- name (%s) are filled in live from tp.required and GetSeasonDisplayName,
-- both of which are already fetched reliably elsewhere in this file.
-- rewardText per title, all confirmed via in-game screenshots. Gladiator's
-- mount ("Galactic Gladiator's Goredrake") is a SEPARATE achievement, not a
-- reward of this one — this one only grants the title — so it's
-- deliberately not mentioned here. Legend/Strategist each grant a pennant
-- + title from their single achievement.
local TITLE_META = {
    { key = "gladiator",  name = "Gladiator",  bracketKey = "rating3v3",     color = {0.20, 0.45, 0.65}, icon = "Interface\\Icons\\achievement_arena_3v3_1",
      reqTemplate = "Win %d 3v3 games while at Elite rank during %s.",
      rewardText  = "Seasonal Character Title: Gladiator" },
    { key = "legend",     name = "Legend",     bracketKey = "ratingShuffle", color = {0.55, 0.30, 0.65}, icon = "Interface\\Icons\\ability_dualwield",
      reqTemplate = "Win %d Rated Solo Shuffle rounds while at Elite rank during %s.",
      rewardText  = "Pennant & Seasonal Character Title" },
    { key = "strategist", name = "Strategist", bracketKey = "ratingBlitz",   color = {0.65, 0.50, 0.10}, icon = "Interface\\Icons\\achievement_bg_killxenemies_generalsroom",
      reqTemplate = "Win %d Rated Battleground Blitz matches while at Elite rank during %s.",
      rewardText  = "Pennant & Seasonal Character Title" },
}

local TITLE_META_BY_BRACKET = {}
for _, m in ipairs(TITLE_META) do TITLE_META_BY_BRACKET[m.bracketKey] = m end

-- Human-readable season name, keyed by the raw ID C_PvP.GetUIDisplaySeason()
-- returns (Blizzard's internal running counter — not the per-expansion
-- season number players see, e.g. "Season 1" of a new expansion). A raw ID
-- with no entry here just displays as "Season <raw id>". This is what keeps
-- the Stats tab from silently relabeling next season's data as this one.
local function GetSeasonDisplayName(rawSeason)
    if not rawSeason or rawSeason <= 0 then return nil end
    local custom = PVPHUB_SETTINGS.seasonLabels and PVPHUB_SETTINGS.seasonLabels[rawSeason]
    return custom or ("Season " .. rawSeason)
end

-- Builds the plain-text requirement line for a title tile/tooltip from its
-- template + the live required count + the live season label. Returns nil
-- if the required count hasn't synced yet (tile/tooltip just omits the line).
local function GetTitleRequirementText(meta, tp)
    if not meta.reqTemplate or not tp or not tp.required or tp.required <= 0 then return nil end
    local rawSeason  = (C_PvP and C_PvP.GetUIDisplaySeason and C_PvP.GetUIDisplaySeason()) or 0
    local seasonName = GetSeasonDisplayName(rawSeason) or "this season"
    return string.format(meta.reqTemplate, tp.required, seasonName)
end

-- True if this character has any rated PvP data recorded for the current
-- season in at least one bracket — used to keep alts that were only ever
-- tracked for currency/gold (or never queued rated PvP at all) out of the
-- Stats tab's character picker.
local function CharacterHasStatsData(charKey)
    for _, meta in ipairs(BRACKET_META) do
        local summary = GetBracketSeasonSummary(charKey, meta.key)
        if summary and (summary.played or 0) > 0 then
            return true
        end
    end
    return false
end

-- Character picker: any stored, non-hidden character that actually has
-- season PvP data (mirrors the Characters tab's own hidden-character
-- filtering for consistency).
local function GetStatsCharacterList()
    local list = {}
    for char, cdata in pairs(PVPHUB_DB) do
        if type(cdata) == "table" and not IsCharacterHidden(char) and CharacterHasStatsData(char) then
            table.insert(list, char)
        end
    end
    local currentChar = GetFullName()
    table.sort(list, function(a, b)
        if a == currentChar then return true end
        if b == currentChar then return false end
        return a < b
    end)
    return list
end

-- Aggregates each season title's progress across every tracked character:
-- if any character already earned it, surface that character + earn date;
-- otherwise surface whichever character is closest, so a multi-alt player
-- instantly knows who to keep queuing on. Returns [titleKey] = {
--   required, current, closestChar,
--   earned, earnedChar, earnedDate ("MM/DD/YYYY")
-- }.
local function BuildTitleProgressData(charList)
    local result = {}
    for _, meta in ipairs(TITLE_META) do
        local entry = { current = 0, required = 0 }
        for _, charKey in ipairs(charList) do
            local tp = PVPHUB_DB[charKey] and PVPHUB_DB[charKey].titleProgress and PVPHUB_DB[charKey].titleProgress[meta.key]
            if tp and tp.required and tp.required > 0 then
                entry.required = tp.required
                if tp.completed and not entry.earned then
                    entry.earned     = true
                    entry.earnedChar = charKey
                    if tp.earnedMonth and tp.earnedDay and tp.earnedYear then
                        -- GetAchievementInfo's year is 2-digit (e.g. 26 for 2026).
                        local fullYear = tp.earnedYear < 100 and (2000 + tp.earnedYear) or tp.earnedYear
                        entry.earnedDate = string.format("%02d/%02d/%04d", tp.earnedMonth, tp.earnedDay, fullYear)
                    end
                elseif not entry.earned and tp.current > entry.current then
                    entry.current     = tp.current
                    entry.closestChar = charKey
                end
            end
        end
        result[meta.key] = entry
    end
    return result
end

-- --------------------------------------------------------------------------
-- Floating title tracker — a small, borderless, movable overlay showing
-- progress for whichever Season Titles the user has ticked "track" on (see
-- the checkbox on each tile in AddTitleProgressTiles). Deliberately kept
-- minimal (no toolbar, no close button, no border) so it reads as a subtle
-- HUD element rather than another window — drag the background to move it.
-- Auto-hides itself when no titles are tracked instead of exposing a
-- separate show/hide control.
-- --------------------------------------------------------------------------
function PVPHUB:UpdateTitleTracker()
    PVPHUB_SETTINGS.trackedTitles = PVPHUB_SETTINGS.trackedTitles or {}
    local tracked = PVPHUB_SETTINGS.trackedTitles

    local activeMetas = {}
    for _, meta in ipairs(TITLE_META) do
        if tracked[meta.key] then table.insert(activeMetas, meta) end
    end

    if #activeMetas == 0 then
        if PVPHUB.titleTracker then PVPHUB.titleTracker:Hide() end
        return
    end

    if not PVPHUB.titleTracker then
        local t = CreateFrame("Frame", "PVPHUBTitleTracker", UIParent, "BackdropTemplate")
        t:SetFrameStrata("MEDIUM")
        t:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8x8", tile = false })
        t:SetBackdropColor(0.05, 0.05, 0.08, 0.55)
        t:SetMovable(true)
        t:EnableMouse(true)
        t:RegisterForDrag("LeftButton")
        t:SetClampedToScreen(true)
        t:SetScript("OnDragStart", t.StartMoving)
        t:SetScript("OnDragStop", function(self)
            self:StopMovingOrSizing()
            local point, _, relativePoint, x, y = self:GetPoint()
            PVPHUB_SETTINGS.titleTrackerPos = { point = point, relativePoint = relativePoint, x = x, y = y }
        end)

        if PVPHUB_SETTINGS.titleTrackerPos then
            local pos = PVPHUB_SETTINGS.titleTrackerPos
            t:SetPoint(pos.point or "CENTER", UIParent, pos.relativePoint or "CENTER", pos.x or 0, pos.y or 250)
        else
            t:SetPoint("CENTER", UIParent, "CENTER", 0, 250)
        end

        t.rowPool = {} -- persistent widgets, updated in place — see below
        PVPHUB.titleTracker = t

        -- Poll while shown instead of relying solely on the SaveTitleProgress
        -- hook: that only fires for the normal live-progress path, so
        -- anything that writes titleProgress a different way (the /pvphub
        -- test dummy data, a DB restore, etc.) would otherwise leave the
        -- overlay showing stale numbers until something else happened to
        -- trigger a rebuild. Rows are pooled (below), so this doesn't create
        -- any new frames/textures on each tick — only Set* calls on widgets
        -- that already exist.
        C_Timer.NewTicker(2, function()
            if PVPHUB.titleTracker and PVPHUB.titleTracker:IsShown() then
                PVPHUB:UpdateTitleTracker()
            end
        end)
    end

    local t = PVPHUB.titleTracker
    local WIDTH, ROW_H, ROW_GAP, PAD = 176, 28, 6, 8
    local overview = BuildTitleProgressData(GetStatsCharacterList())

    for i, meta in ipairs(activeMetas) do
        local tp = overview[meta.key] or { current = 0, required = 0 }
        local row = t.rowPool[i]

        if not row then
            row = CreateFrame("Frame", nil, t)
            row:SetSize(WIDTH - PAD * 2, ROW_H)

            row.icon = row:CreateTexture(nil, "ARTWORK")
            row.icon:SetSize(14, 14)
            row.icon:SetPoint("TOPLEFT", row, "TOPLEFT", 0, 0)
            row.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

            row.label = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            row.label:SetPoint("LEFT", row.icon, "RIGHT", 5, 0)
            RegisterTrackedFont(row.label, 11, "OUTLINE")
            row.label:SetTextColor(0.85, 0.85, 0.85, 1)

            row.value = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            row.value:SetPoint("RIGHT", row, "RIGHT", 0, 0)
            RegisterTrackedFont(row.value, 11, "OUTLINE")

            row.barBG = row:CreateTexture(nil, "ARTWORK")
            row.barBG:SetHeight(3)
            row.barBG:SetPoint("BOTTOMLEFT", row, "BOTTOMLEFT", 0, 0)
            row.barBG:SetPoint("BOTTOMRIGHT", row, "BOTTOMRIGHT", 0, 0)
            row.barBG:SetTexture("Interface\\Buttons\\WHITE8x8")
            row.barBG:SetVertexColor(1, 1, 1, 0.12)

            row.barFill = row:CreateTexture(nil, "ARTWORK", nil, 1)
            row.barFill:SetHeight(3)
            row.barFill:SetPoint("BOTTOMLEFT", row, "BOTTOMLEFT", 0, 0)
            row.barFill:SetTexture("Interface\\Buttons\\WHITE8x8")

            -- Static handlers read row.meta/row.tp/row.progressChar (kept
            -- current below) instead of closing over per-update locals, so
            -- refreshing never has to re-assign a new closure either.
            row:EnableMouse(true)
            row:SetScript("OnEnter", function(self)
                GameTooltip:SetOwner(self, "ANCHOR_TOP")
                GameTooltip:ClearLines()
                GameTooltip:AddLine(self.meta.name, 1, 0.82, 0)
                if self.progressChar then
                    local charData = PVPHUB_DB[self.progressChar]
                    local classColor = charData and RAID_CLASS_COLORS[charData.class]
                    local coloredName = (classColor and classColor.colorStr)
                        and ("|c" .. classColor.colorStr .. self.progressChar .. "|r") or self.progressChar
                    GameTooltip:AddLine((self.tp.earned and "Earned on: " or "Progress on: ") .. coloredName, 0.9, 0.9, 0.9)
                else
                    GameTooltip:AddLine("No progress yet", 0.6, 0.6, 0.6)
                end
                GameTooltip:Show()
            end)
            row:SetScript("OnLeave", function() GameTooltip:Hide() end)

            t.rowPool[i] = row
        end

        row:ClearAllPoints()
        row:SetPoint("TOP", t, "TOP", 0, -PAD - (i - 1) * (ROW_H + ROW_GAP))
        row.icon:SetTexture(meta.icon)
        row.label:SetText(meta.name)
        -- The row shows account-wide best progress (same aggregation as the
        -- Season tab tiles); OnEnter reads these to name WHICH character
        -- it's coming from, rather than cluttering the row itself.
        row.meta, row.tp = meta, tp
        row.progressChar = tp.earned and tp.earnedChar or tp.closestChar

        if tp.earned then
            row.value:SetTextColor(1, 0.82, 0, 1)
            row.value:SetText("Earned!")
            row.barFill:SetWidth(row:GetWidth())
            row.barFill:SetVertexColor(1, 0.82, 0, 0.9)
        else
            local required = (tp.required and tp.required > 0) and tp.required or 1
            local current  = math.min(tp.current or 0, required)
            row.value:SetTextColor(1, 1, 1, 1)
            row.value:SetText(current .. "/" .. ((tp.required and tp.required > 0) and tp.required or "?"))
            local pct = current / required
            row.barFill:SetWidth(math.max(0.5, row:GetWidth() * pct))
            row.barFill:SetVertexColor(meta.color[1], meta.color[2], meta.color[3], 0.95)
        end

        row:Show()
    end

    -- Hide (but keep pooled for reuse) any rows left over from a previously
    -- larger tracked set.
    for i = #activeMetas + 1, #t.rowPool do
        t.rowPool[i]:Hide()
    end

    t:SetSize(WIDTH, PAD * 2 + #activeMetas * ROW_H + (#activeMetas - 1) * ROW_GAP)
    t:Show()
end

-- Pure data computation, no widgets — aggregates every tracked
-- character/bracket into one dashboard-shaped table for the Stats tab's
-- live, current-season render.
local function BuildSeasonOverviewData(charList)
    local totalGames, totalWon, totalLost = 0, 0, 0
    local bracketTotals = {}
    local bestRating, bestRatingChar, bestRatingBracket = 0, nil, nil
    local classRosterCounts = {}   -- [classToken] = # active characters
    local classRosterChars  = {}   -- [classToken] = { charKey, ... }
    local classGameCounts   = {}   -- [classToken] = weighted games played
    local specGameCounts    = {}   -- [specID]     = weighted games played

    for _, charKey in ipairs(charList) do
        local charHadGames = false
        local charData = PVPHUB_DB[charKey]

        for _, meta in ipairs(BRACKET_META) do
            local summary = GetBracketSeasonSummary(charKey, meta.key)
            if summary and (summary.played or 0) > 0 then
                charHadGames = true
                totalGames = totalGames + summary.played
                totalWon   = totalWon + summary.won
                totalLost  = totalLost + summary.lost

                local bt = bracketTotals[meta.key]
                if not bt then
                    bt = { played = 0, won = 0, lost = 0, mostPlayedChar = nil, mostPlayedGames = 0 }
                    bracketTotals[meta.key] = bt
                end
                bt.played = bt.played + summary.played
                bt.won    = bt.won + summary.won
                bt.lost   = bt.lost + summary.lost
                if summary.played > bt.mostPlayedGames then
                    bt.mostPlayedChar  = charKey
                    bt.mostPlayedGames = summary.played
                end

                if summary.seasonBest > bestRating then
                    bestRating        = summary.seasonBest
                    bestRatingChar    = charKey
                    bestRatingBracket = meta.label
                end

                -- Tally games played per spec/class from the raw match log —
                -- bracket-agnostic and accounts for characters who respecced
                -- mid-season, unlike assuming their current spec covers every
                -- game played.
                local history = charData.mmrHistory and charData.mmrHistory[meta.key]
                if history then
                    for _, m in ipairs(history) do
                        local weight = (m.roundsWon and m.roundsLost) and (m.roundsWon + m.roundsLost) or 1
                        if weight > 0 then
                            if charData.class then
                                classGameCounts[charData.class] = (classGameCounts[charData.class] or 0) + weight
                            end
                            if m.specID and m.specID > 0 then
                                specGameCounts[m.specID] = (specGameCounts[m.specID] or 0) + weight
                            end
                        end
                    end
                end
            end
        end

        if charHadGames then
            if charData.class then
                classRosterCounts[charData.class] = (classRosterCounts[charData.class] or 0) + 1
                classRosterChars[charData.class]  = classRosterChars[charData.class] or {}
                table.insert(classRosterChars[charData.class], charKey)
            end
        end
    end

    -- Class roster breakdown — icon + count per class, sorted by count desc,
    -- e.g. [Warrior icon]x2  [Mage icon]x1 --------------
    local classBreakdownIcons = {}
    do
        local parts = {}
        for classToken, count in pairs(classRosterCounts) do
            table.insert(parts, { token = classToken, count = count })
        end
        table.sort(parts, function(a, b)
            if a.count ~= b.count then return a.count > b.count end
            return a.token < b.token
        end)
        for _, part in ipairs(parts) do
            local label = (LOCALIZED_CLASS_NAMES_MALE and LOCALIZED_CLASS_NAMES_MALE[part.token]) or part.token
            table.insert(classBreakdownIcons, {
                icon  = GetSpecOrClassIcon(nil, part.token),
                count = part.count,
                label = label,
                chars = classRosterChars[part.token],
                color = RAID_CLASS_COLORS[part.token],
            })
        end
    end

    -- Most played class / spec by weighted games played ----------------
    local mostPlayedClassStr, mostPlayedClassSub, mostPlayedClassIcon = "—", nil, nil
    do
        local mostPlayedClass, mostPlayedGames = nil, 0
        for classToken, games in pairs(classGameCounts) do
            if games > mostPlayedGames then
                mostPlayedClass, mostPlayedGames = classToken, games
            end
        end
        if mostPlayedClass then
            local label = (LOCALIZED_CLASS_NAMES_MALE and LOCALIZED_CLASS_NAMES_MALE[mostPlayedClass]) or mostPlayedClass
            mostPlayedClassStr  = label
            mostPlayedClassSub  = "(" .. mostPlayedGames .. " games played)"
            mostPlayedClassIcon = GetSpecOrClassIcon(nil, mostPlayedClass)
        end
    end

    local mostPlayedSpecStr, mostPlayedSpecSub, mostPlayedSpecIcon = "—", nil, nil
    do
        local mostPlayedSpec, mostPlayedGames = nil, 0
        for specID, games in pairs(specGameCounts) do
            if games > mostPlayedGames then
                mostPlayedSpec, mostPlayedGames = specID, games
            end
        end
        if mostPlayedSpec then
            local _si = GetCachedSpecInfo(mostPlayedSpec)
            local label = (_si and _si.name) or "Unknown Spec"
            mostPlayedSpecStr  = label
            mostPlayedSpecSub  = "(" .. mostPlayedGames .. " games played)"
            mostPlayedSpecIcon = GetSpecOrClassIcon(mostPlayedSpec, nil)
        end
    end

    -- Favourite bracket — whichever bracket has the most combined games
    -- played across the whole roster.
    local favoriteBracketStr, favoriteBracketSub, favoriteBracketIcon = "—", nil, nil
    do
        local favoriteGames = 0
        for _, meta in ipairs(BRACKET_META) do
            local bt = bracketTotals[meta.key]
            if bt and bt.played > favoriteGames then
                favoriteGames       = bt.played
                favoriteBracketStr  = meta.label
                favoriteBracketSub  = "(" .. bt.played .. " games played)"
                favoriteBracketIcon = meta.icon
            end
        end
    end

    return {
        totalGames = totalGames, totalWon = totalWon, totalLost = totalLost,
        bracketTotals = bracketTotals,
        bestRating = bestRating, bestRatingChar = bestRatingChar, bestRatingBracket = bestRatingBracket,
        charCount = #charList,
        classBreakdownIcons = classBreakdownIcons,
        mostPlayedClassStr = mostPlayedClassStr, mostPlayedClassSub = mostPlayedClassSub, mostPlayedClassIcon = mostPlayedClassIcon,
        mostPlayedSpecStr  = mostPlayedSpecStr,  mostPlayedSpecSub  = mostPlayedSpecSub,  mostPlayedSpecIcon  = mostPlayedSpecIcon,
        favoriteBracketStr = favoriteBracketStr, favoriteBracketSub = favoriteBracketSub, favoriteBracketIcon = favoriteBracketIcon,
        titleProgress = BuildTitleProgressData(charList),
    }
end

-- ── Totals breakdown popup (Honor/Conquest/Gold) ───────────────────────────
-- Custom interactive replacement for the native GameTooltip these summary
-- totals used to use. A character left behind by a realm transfer can't be
-- reliably auto-detected as "the same character" (UnitGUID is realm-scoped,
-- so it changes on a real transfer — see the GUID rename/transfer migration
-- comment near ADDON_LOADED) and it may already be filtered out of the main
-- roster by "Hide Characters with No Ratings" once its ratings are cleared,
-- leaving no row there to right-click Delete Character on. This popup lists
-- every character contributing to a total with a small delete control right
-- on each row, so a stale entry is always reachable from wherever its stale
-- number is visible.
local _totalsPopup
local _totalsPopupRows = {}
local TP_PAD, TP_ROW_H, TP_WIDTH = 12, 20, 260
local ScheduleHideTotalsPopup -- forward declaration; defined below EnsureTotalsPopup, used inside it

local function EnsureTotalsPopup()
    if _totalsPopup then return _totalsPopup end
    local f = CreateFrame("Frame", nil, UIParent, "BackdropTemplate")
    f:SetFrameStrata("TOOLTIP")
    f:SetFrameLevel(800)
    f:SetClampedToScreen(true)
    f:EnableMouse(true)
    f:Hide()
    f:SetBackdrop({
        bgFile   = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 16,
        insets = { left = 4, right = 4, top = 4, bottom = 4 },
    })
    f:SetBackdropColor(0.04, 0.04, 0.09, 0.97)
    f:SetBackdropBorderColor(0.36, 0.36, 0.48, 1.0)

    f.title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    f.title:SetPoint("TOPLEFT", TP_PAD, -10)
    RegisterTrackedFont(f.title, 13, "OUTLINE")

    f.emptyText = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    f.emptyText:SetJustifyH("LEFT")
    f.emptyText:SetTextColor(0.6, 0.6, 0.6, 1)
    RegisterTrackedFont(f.emptyText, 11, "")

    f.hint = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    f.hint:SetJustifyH("LEFT")
    f.hint:SetWordWrap(true)
    f.hint:SetTextColor(0.55, 0.55, 0.55, 1)
    RegisterTrackedFont(f.hint, 10, "")

    f:SetScript("OnLeave", function(self) ScheduleHideTotalsPopup() end)

    _totalsPopup = f
    return f
end

-- Only hide once the mouse has left BOTH the popup itself and whatever
-- button opened it — otherwise moving off the trigger button to reach a
-- delete "x" inside the popup would close it before the click lands. Shared
-- by the popup's own OnLeave and every trigger button's OnLeave.
ScheduleHideTotalsPopup = function()
    C_Timer.After(0.15, function()
        if not _totalsPopup or not _totalsPopup:IsShown() then return end
        local overPopup  = _totalsPopup:IsMouseOver()
        local overButton = _totalsPopup.triggerBtn and _totalsPopup.triggerBtn:IsMouseOver()
        if not overPopup and not overButton then
            _totalsPopup:Hide()
        end
    end)
end

local function GetTotalsPopupRow(n)
    if _totalsPopupRows[n] then return _totalsPopupRows[n] end
    local f = EnsureTotalsPopup()

    local row = CreateFrame("Frame", nil, f)
    row:SetHeight(TP_ROW_H)
    row:SetWidth(TP_WIDTH)

    row.deleteBtn = CreateFrame("Button", nil, row)
    row.deleteBtn:SetSize(16, 16)
    row.deleteBtn:SetPoint("RIGHT", row, "RIGHT", 0, 0)
    row.deleteBtn.text = row.deleteBtn:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    row.deleteBtn.text:SetAllPoints()
    row.deleteBtn.text:SetJustifyH("CENTER")
    row.deleteBtn.text:SetText("|cff888888x|r")
    row.deleteBtn:SetScript("OnEnter", function(self)
        self.text:SetText("|cffff4040x|r")
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText("Remove this character")
        GameTooltip:AddLine("Permanently deletes all PVPHUB data for this character.", 1, 1, 1, true)
        GameTooltip:Show()
    end)
    row.deleteBtn:SetScript("OnLeave", function(self)
        self.text:SetText("|cff888888x|r")
        GameTooltip:Hide()
    end)
    row.deleteBtn:SetScript("OnClick", function(self)
        local charKey = self.charKey
        if not charKey then return end
        if _totalsPopup then _totalsPopup:Hide() end
        PVPHUB._deleteCharCtx = charKey
        StaticPopupDialogs["PVPHUB_DELETE_CHARACTER"].text =
            "Are you sure you want to permanently delete all data for |cff4da6ff" .. charKey .. "|r?\n\nThis action cannot be undone!"
        StaticPopup_Show("PVPHUB_DELETE_CHARACTER")
    end)

    row.name = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    row.name:SetPoint("LEFT", row, "LEFT", 0, 0)
    row.name:SetJustifyH("LEFT")
    row.name:SetWidth(170) -- fixed, so a long realm name can't overlap the value/delete button
    row.name:SetWordWrap(false)
    RegisterTrackedFont(row.name, 12, "")

    row.value = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    row.value:SetPoint("RIGHT", row.deleteBtn, "LEFT", -8, 0)
    row.value:SetJustifyH("RIGHT")
    RegisterTrackedFont(row.value, 12, "")

    _totalsPopupRows[n] = row
    return row
end

-- entries: { { char = charKey, coloredName = "...", value = "..." }, ... },
-- already sorted by the caller.
local function ShowTotalsPopup(triggerBtn, titleText, titleColor, entries)
    local popup = EnsureTotalsPopup()
    popup.triggerBtn = triggerBtn
    popup:ClearAllPoints()
    popup:SetPoint("TOP", triggerBtn, "BOTTOM", 0, -4)

    popup.title:SetText(titleText)
    popup.title:SetTextColor(unpack(titleColor))

    for _, row in ipairs(_totalsPopupRows) do row:Hide() end

    local y = -10 - popup.title:GetStringHeight() - 8

    if #entries == 0 then
        popup.emptyText:ClearAllPoints()
        popup.emptyText:SetPoint("TOPLEFT", TP_PAD, y)
        popup.emptyText:SetText("No data")
        popup.emptyText:Show()
        y = y - popup.emptyText:GetStringHeight() - 8
    else
        popup.emptyText:Hide()
        for i, entry in ipairs(entries) do
            local row = GetTotalsPopupRow(i)
            row:ClearAllPoints()
            row:SetPoint("TOPLEFT", TP_PAD, y)
            row.name:SetText(entry.coloredName)
            row.value:SetText(entry.value)
            -- Entries with no char (e.g. Warband Bank — account-wide, not a
            -- character) get no delete button; there's nothing to delete.
            row.deleteBtn.charKey = entry.char
            row.deleteBtn:SetShown(entry.char ~= nil)
            row:Show()
            y = y - TP_ROW_H
        end
    end

    popup.hint:ClearAllPoints()
    popup.hint:SetPoint("TOPLEFT", TP_PAD, y - 4)
    popup.hint:SetWidth(TP_WIDTH)
    popup.hint:SetText("Click |cffff5555x|r to permanently remove a character (e.g. a stale entry left behind by a realm transfer).")
    y = y - 4 - popup.hint:GetStringHeight()

    popup:SetWidth(TP_WIDTH + TP_PAD * 2)
    popup:SetHeight(-y + 12)
    popup:Show()
end

local _pvpTip     = nil   -- Frame, created lazily
local _pvpTipPool = {}    -- pooled rows: [n] = { icon, c1, c2, c3, c4 }
local _pvpTipUsed = 0     -- rows consumed this render
local _pvpTipY    = 0     -- current Y cursor (pixels from frame top)
local _pvpTipSeps = {}    -- pooled separator textures (kept for compat, no longer used)
local _pvpTipSepN = 0
local _pvpTipBands = {}   -- pooled background band quads (BORDER layer)
local _pvpTipBandN = 0
local _pvpTipSecStartY = 0  -- Y cursor recorded at PvPTipSectionStart()
local _pvpTipSections = {}  -- up to 3 section band textures (BORDER layer, non-pooled)
local _pvpTipSecN = 0

-- Layout constants
local PT_W   = 350   -- total frame width
local PT_PAD = 10    -- horizontal padding
local PT_ROW = 21    -- body row height (spec rows)
local PT_SPC = 5     -- generic spacer height
local PT_TTL = 22    -- title row height
local PT_SUB = 16    -- subtitle row height

-- Spec rows   [icon | name | CR | MMR ]  (values are number-only, color = gold/blue)
local SP_NAME = PT_PAD + 22   -- 32
local SP_CR   = 128
local SP_MMR  = 184

-- Match-history columns  [icon | mmr | w/l | date ]
-- MH_SIDE adds symmetric left/right breathing room so rows don't span the full frame width.
local MH_SIDE = 10             -- extra inset on each side for match-history rows
local MH_COL1 = PT_PAD + MH_SIDE + 22   -- 42  (text start after icon)
local MH_COL2 = 155 + MH_SIDE           -- 165 W/L column start
local MH_COL3 = 230 + MH_SIDE           -- 240 Date column start


local function EnsurePvPTip()
    if _pvpTip then return _pvpTip end
    local f = CreateFrame("Frame", "PVPHUBRatingTooltip", UIParent, "BackdropTemplate")
    f:SetWidth(PT_W)
    f:SetHeight(60)
    f:SetFrameStrata("TOOLTIP")
    f:SetFrameLevel(800)
    f:SetClampedToScreen(true)
    f:Hide()
    f:SetBackdrop({
        bgFile   = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 16,
        insets = { left = 4, right = 4, top = 4, bottom = 4 },
    })
    f:SetBackdropColor(0.04, 0.04, 0.09, 0.97)
    f:SetBackdropBorderColor(0.36, 0.36, 0.48, 1.0)
    _pvpTip = f
    return f
end

local function GetPvPTipRow(n)
    if _pvpTipPool[n] then return _pvpTipPool[n] end
    local f = EnsurePvPTip()

    local icon = f:CreateTexture(nil, "ARTWORK")
    icon:SetSize(18, 18)
    icon:SetTexCoord(0.0625, 0.9375, 0.0625, 0.9375)
    icon:Hide()

    local function MakeFS()
        local fs = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        RegisterTrackedFont(fs, 12, "")
        fs:SetJustifyH("LEFT")
        fs:SetWordWrap(false)
        fs:Hide()
        return fs
    end

    local row = { icon = icon, c1 = MakeFS(), c2 = MakeFS(), c3 = MakeFS(), c4 = MakeFS() }
    _pvpTipPool[n] = row
    return row
end

local function HidePvPTipRowsFrom(n)
    for i = n, #_pvpTipPool do
        local r = _pvpTipPool[i]
        r.icon:Hide()
        r.c1:Hide(); r.c2:Hide(); r.c3:Hide(); r.c4:Hide()
    end
end

-- Draw a full-width row-highlight band that fades in from the left and out to the right.
-- Each call uses two pooled textures (left gradient + right gradient).
local function PvPTipBand(h, r, g, b, a)
    local f = EnsurePvPTip()
    _pvpTipBandN = _pvpTipBandN + 1
    local pair = _pvpTipBands[_pvpTipBandN]
    if not pair then
        local tL = f:CreateTexture(nil, "BORDER")
        tL:SetTexture("Interface\\Buttons\\WHITE8x8")
        local tR = f:CreateTexture(nil, "BORDER")
        tR:SetTexture("Interface\\Buttons\\WHITE8x8")
        pair = { left = tL, right = tR }
        _pvpTipBands[_pvpTipBandN] = pair
    end
    local cFull = CreateColor(r or 1, g or 1, b or 1, a or 0.20)
    local cNone = CreateColor(r or 1, g or 1, b or 1, 0)
    -- 1px inset top+bottom so adjacent rows have a visible gap between bands
    local yTop = _pvpTipY + 1
    local bH   = h - 2
    -- Left half: transparent → solid
    pair.left:SetGradient("HORIZONTAL", cNone, cFull)
    pair.left:ClearAllPoints()
    pair.left:SetPoint("TOPLEFT",  f, "TOPLEFT",  0, -yTop)
    pair.left:SetPoint("TOPRIGHT", f, "TOP",      0, -yTop)
    pair.left:SetHeight(bH)
    pair.left:Show()
    -- Right half: solid → transparent
    pair.right:SetGradient("HORIZONTAL", cFull, cNone)
    pair.right:ClearAllPoints()
    pair.right:SetPoint("TOPLEFT",  f, "TOP",      0, -yTop)
    pair.right:SetPoint("TOPRIGHT", f, "TOPRIGHT", 0, -yTop)
    pair.right:SetHeight(bH)
    pair.right:Show()
end

-- Section gap: plain vertical spacing between sections (no visual band).
local function PvPTipSeparator()
    _pvpTipY = _pvpTipY + 6
end

-- Draw a 1px underline at the current Y position with gradient fade on both ends,
-- then advance 3px. Uses two textures per line: left half fades transparent→solid,
-- right half fades solid→transparent. Pooled as pairs in _pvpTipSeps.
local function PvPTipUnderline(r, g, b, a)
    local f  = EnsurePvPTip()
    r, g, b, a = r or 0.8, g or 0.7, b or 0.1, a or 0.6
    _pvpTipSepN = _pvpTipSepN + 1
    local pair = _pvpTipSeps[_pvpTipSepN]
    if not pair then
        pair = {
            left  = f:CreateTexture(nil, "BORDER"),
            right = f:CreateTexture(nil, "BORDER"),
        }
        pair.left:SetTexture("Interface\\Buttons\\WHITE8x8")
        pair.right:SetTexture("Interface\\Buttons\\WHITE8x8")
        _pvpTipSeps[_pvpTipSepN] = pair
    end
    local cNone = CreateColor(r, g, b, 0)
    local cFull = CreateColor(r, g, b, a)
    pair.left:SetGradient("HORIZONTAL", cNone, cFull)
    pair.right:SetGradient("HORIZONTAL", cFull, cNone)
    pair.left:ClearAllPoints()
    pair.right:ClearAllPoints()
    pair.left:SetPoint("TOPLEFT",  f, "TOPLEFT",  PT_PAD, -_pvpTipY)
    pair.left:SetPoint("TOPRIGHT", f, "TOP",       0,     -_pvpTipY)
    pair.right:SetPoint("TOPLEFT",  f, "TOP",       0,     -_pvpTipY)
    pair.right:SetPoint("TOPRIGHT", f, "TOPRIGHT", -PT_PAD, -_pvpTipY)
    pair.left:SetHeight(1)
    pair.right:SetHeight(1)
    pair.left:Show()
    pair.right:Show()
    _pvpTipY = _pvpTipY + 3
end

-- Section background helpers.
-- Call PvPTipSectionStart() before any content row in the section.
-- Call PvPTipSectionEnd(r,g,b,a) after the last row.
-- Uses BORDER layer (above backdrop) so the tint is actually visible.
-- Section textures are NOT pooled because they need BORDER layer, which
-- cannot be changed after creation, so we keep a small fixed list.
local function PvPTipSectionStart()
    _pvpTipSecStartY = math.max(0, _pvpTipY - 2)
end

local function PvPTipSectionEnd(r, g, b, a)
    local h = (_pvpTipY + 2) - _pvpTipSecStartY
    if h <= 0 then return end
    local f = EnsurePvPTip()
    _pvpTipSecN = _pvpTipSecN + 1
    local tex = _pvpTipSections[_pvpTipSecN]
    if not tex then
        tex = f:CreateTexture(nil, "BORDER")
        tex:SetTexture("Interface\\Buttons\\WHITE8x8")
        _pvpTipSections[_pvpTipSecN] = tex
    end
    tex:SetVertexColor(r or 0.20, g or 0.22, b or 0.30, a or 1)
    tex:ClearAllPoints()
    tex:SetPoint("TOPLEFT",  f, "TOPLEFT",  0, -_pvpTipSecStartY)
    tex:SetPoint("TOPRIGHT", f, "TOPRIGHT", 0, -_pvpTipSecStartY)
    tex:SetHeight(h)
    tex:Show()
end

-- Add one row.
-- iconPath : raw texture path or nil/""
-- c1..c4   : colored text strings ("" or nil = hidden)
-- c1X..c4X : left-edge X of each column (defaults to SP_ values)
-- rowH     : row height (default PT_ROW)
-- large    : c1 uses GameFontNormalLarge instead of GameFontNormal
-- c4, c4X  : optional 4th text column
-- iconX    : optional override for icon left-edge X (default PT_PAD)
local function PvPTipRow(iconPath, c1, c2, c3, c1X, c2X, c3X, rowH, large, c4, c4X, iconX)
    local f = EnsurePvPTip()
    rowH = rowH or PT_ROW
    c1X  = c1X  or SP_NAME
    c2X  = c2X  or SP_CR
    c3X  = c3X  or SP_MMR
    c4X  = c4X  or (PT_W - PT_PAD)
    _pvpTipUsed = _pvpTipUsed + 1
    local row = GetPvPTipRow(_pvpTipUsed)

    if iconPath and iconPath ~= "" then
        row.icon:SetTexture(iconPath)
        row.icon:ClearAllPoints()
        row.icon:SetPoint("TOPLEFT", f, "TOPLEFT", iconX or PT_PAD, -_pvpTipY - 1)
        row.icon:Show()
    else
        row.icon:Hide()
    end

    local function PlaceFS(fs, text, x, maxW, isBig)
        if text and text ~= "" then
            fs:SetFontObject(isBig and "GameFontNormalLarge" or "GameFontNormal")
            fs:SetJustifyH("LEFT")
            fs:ClearAllPoints()
            -- Vertically centre the text within the row height.
            -- GameFontNormal is ~14px; GameFontNormalLarge is ~18px.
            local fontH = isBig and 18 or 14
            local yOff  = math.floor((rowH - fontH) / 2)
            fs:SetPoint("TOPLEFT", f, "TOPLEFT", x, -_pvpTipY - yOff)
            fs:SetWidth(maxW)
            fs:SetText(text)
            fs:Show()
        else
            fs:Hide()
        end
    end
    PlaceFS(row.c1, c1, c1X, c2X - c1X - 4, large)
    PlaceFS(row.c2, c2, c2X, c3X - c2X - 4, false)
    if c4 and c4 ~= "" then
        PlaceFS(row.c3, c3, c3X, c4X - c3X - 4,       false)
        PlaceFS(row.c4, c4, c4X, PT_W - c4X - PT_PAD, false)
    else
        PlaceFS(row.c3, c3, c3X, PT_W - c3X - PT_PAD, false)
        row.c4:Hide()
    end

    _pvpTipY = _pvpTipY + rowH
end

local function PvPTipSpacer(h)
    _pvpTipY = _pvpTipY + (h or PT_SPC)
end

local function PvPTipShow(anchor)
    local f = EnsurePvPTip()
    HidePvPTipRowsFrom(_pvpTipUsed + 1)
    for i = _pvpTipSepN + 1, #_pvpTipSeps do
        if _pvpTipSeps[i] then
            _pvpTipSeps[i].left:Hide()
            _pvpTipSeps[i].right:Hide()
        end
    end
    for i = _pvpTipBandN + 1, #_pvpTipBands do
        if _pvpTipBands[i] then
            _pvpTipBands[i].left:Hide()
            _pvpTipBands[i].right:Hide()
        end
    end
    for i = _pvpTipSecN + 1, #_pvpTipSections do _pvpTipSections[i]:Hide() end
    f:SetHeight(_pvpTipY + PT_PAD)
    f:ClearAllPoints()
    if anchor then
        local aRight  = anchor:GetRight() or 0
        local screenW = GetScreenWidth() / (f:GetEffectiveScale() or 1)
        if aRight + PT_W < screenW then
            f:SetPoint("TOPLEFT",  anchor, "TOPRIGHT",  4, 0)
        else
            f:SetPoint("TOPRIGHT", anchor, "TOPLEFT",  -4, 0)
        end
    else
        local scale = f:GetEffectiveScale() or 1
        local cx, cy = GetCursorPosition()
        cx, cy = cx / scale, cy / scale
        f:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", cx + 14, cy - 14)
    end
    f:Show()
end

local function ResetPvPTip()
    _pvpTipUsed      = 0
    _pvpTipSepN      = 0
    _pvpTipBandN     = 0
    _pvpTipSecN      = 0
    _pvpTipSecStartY = 0
    _pvpTipY         = PT_PAD
end

local function ClosePVPHUBRatingTooltip()
    if _pvpTip then _pvpTip:Hide() end
end

-- ── Main builder: replaces the GameTooltip pattern at every call site ──────
local function ShowPVPHUBRatingTooltip(anchor, charKey, bracketKey, ratingsData)
    if not PVPHUB_DB or not PVPHUB_DB[charKey] then return end
    ResetPvPTip()

    local data          = PVPHUB_DB[charKey]
    local isArena       = (bracketKey == "rating2v2" or bracketKey == "rating3v3")
    local currentSpecID = data.specID or data.lastActiveSpecID

    local BRACKET_LABELS = {
        ratingShuffle = "Solo Shuffle",
        ratingBlitz   = "Blitz BG",
        ratingRBG     = "Rated BG",
        rating2v2     = "2v2 Arena",
        rating3v3     = "3v3 Arena",
    }
    local bracketLabel = BRACKET_LABELS[bracketKey] or bracketKey

    -- Title: class-coloured char name
    local charName   = charKey:match("([^-]+)") or charKey
    local classColor = RAID_CLASS_COLORS[data.class or "WARRIOR"] or NORMAL_FONT_COLOR
    local titleText  = string.format("|cff%02x%02x%02x%s|r",
        math.floor(classColor.r * 255),
        math.floor(classColor.g * 255),
        math.floor(classColor.b * 255),
        charName)
    PvPTipRow(nil, titleText, nil, nil, PT_PAD, PT_W - PT_PAD, PT_W - PT_PAD, PT_TTL, true)
    PvPTipRow(nil, "|cff888888" .. bracketLabel .. "|r", nil, nil, PT_PAD, PT_W - PT_PAD, PT_W - PT_PAD, PT_SUB)

    local hasAnyData = false

    -- ── Season title progress (Legend / Strategist / Gladiator) ────────────
    -- Placed right under the bracket label, with the title's own icon, so
    -- it reads as a headline stat rather than something buried near the
    -- bottom. Win count only, e.g. "Gladiator: 6/50" — the requirement text
    -- only lives on the Season tab's title tiles (see AddTitleProgressTiles).
    local titleMeta = TITLE_META_BY_BRACKET[bracketKey]
    if titleMeta then
        local tp = data.titleProgress and data.titleProgress[titleMeta.key]
        if tp and tp.required and tp.required > 0 then
            hasAnyData = true
            local line
            if tp.completed then
                line = "|cfffff700" .. titleMeta.name .. ":|r |cff40ff40Earned!|r"
            else
                local pct      = tp.current / tp.required
                local numColor = pct >= 0.75 and "|cff40ff40" or (pct >= 0.50 and "|cffffd700" or (pct >= 0.25 and "|cffffa500" or "|cffff4040"))
                line = "|cfffff700" .. titleMeta.name .. ":|r " .. numColor .. tp.current .. "/" .. tp.required .. "|r"
            end
            PvPTipRow(tp.icon or titleMeta.icon, line, nil, nil, SP_NAME, PT_W - PT_PAD, PT_W - PT_PAD)
        end
    end

    PvPTipSeparator()
    PvPTipSpacer(2)
    -- Arena W/L is a single bracket-wide stat; Shuffle/Blitz resolves per-spec below.
    local wins, losses, winrate = 0, 0, 0
    if isArena then
        wins, losses, winrate = GetWinLossStats(charKey, bracketKey)
    end

    if bracketKey == "ratingShuffle" or bracketKey == "ratingBlitz" then
        -- 4-column layout: name | CR | MMR | W/L
        local SH_NAME = SP_NAME
        local SH_CR   = 128
        local SH_MMR  = 184
        local SH_WL   = 240
        PvPTipRow(nil, nil, "|cffffd700CR|r", "|cffffd700MMR|r", SH_NAME, SH_CR, SH_MMR, 14, false, "|cffffd700W/L|r", SH_WL)
        PvPTipUnderline()

        local allSpecMMRs = {}
        if data.mmrHistory and data.mmrHistory[bracketKey] then
            for i = #data.mmrHistory[bracketKey], 1, -1 do
                local m = data.mmrHistory[bracketKey][i]
                if m.specID and m.postMatchMMR and m.postMatchMMR > 0 and not allSpecMMRs[m.specID] then
                    allSpecMMRs[m.specID] = m.postMatchMMR
                end
            end
        end

        -- Also surface specs that have a stored rating but no recorded match history.
        if type(ratingsData) == "table" then
            for specID, rating in pairs(ratingsData) do
                if rating > 0 and not allSpecMMRs[specID] then
                    local lkm = data.lastKnownMMR
                                and data.lastKnownMMR[bracketKey]
                                and data.lastKnownMMR[bracketKey][specID]
                    allSpecMMRs[specID] = (lkm and lkm.mmr and lkm.mmr > 0) and lkm.mmr or 0
                end
            end
        end


        if next(allSpecMMRs) then
            hasAnyData = true
            local specList = {}
            for specID, mmr in pairs(allSpecMMRs) do
                table.insert(specList, { specID = tonumber(specID), mmr = mmr })
            end

            -- Add current spec if unrated (rating=0) and not already listed.
            if currentSpecID and not allSpecMMRs[currentSpecID] then
                if type(ratingsData) == "table" and ratingsData[currentSpecID] ~= nil then
                    table.insert(specList, { specID = currentSpecID, mmr = 0 })
                end
            end

            -- Active spec first; then MMR desc; then CR desc as tiebreak.
            table.sort(specList, function(a, b)
                local aActive = (a.specID == currentSpecID)
                local bActive = (b.specID == currentSpecID)
                if aActive ~= bActive then return aActive end
                if a.mmr ~= b.mmr then return a.mmr > b.mmr end
                local aRating = type(ratingsData) == "table" and (ratingsData[a.specID] or 0) or 0
                local bRating = type(ratingsData) == "table" and (ratingsData[b.specID] or 0) or 0
                return aRating > bRating
            end)

            for _, spec in ipairs(specList) do
                local specName, iconPath = "Unknown", nil
                if spec.specID and spec.specID > 0 then
                    local _si = GetCachedSpecInfo(spec.specID)
                    specName = (_si and _si.name) or specName
                    iconPath = _si and _si.icon
                end
                local specRating = 0
                if type(ratingsData) == "number" then
                    specRating = ratingsData
                elseif type(ratingsData) == "table" and spec.specID then
                    specRating = ratingsData[spec.specID] or 0
                end
                local active = (spec.specID == currentSpecID)
                local nameC  = active and "|cff40ff40" or "|cff777777"
                local crC    = active and "|cffffd700" or "|cff777777"
                local mmrC   = active and "|cff4da6ff" or "|cff555555"
                local crTxt  = specRating > 0 and (crC .. specRating .. "|r")
                               or (active and "|cffffd7000|r" or "")
                local mmrTxt = spec.mmr > 0 and (mmrC .. spec.mmr .. "|r") or ""
                local sw, sl, swr = GetWinLossStats(charKey, bracketKey, spec.specID)
                local wlTxt = ""
                if sw + sl > 0 then
                    local pctCol = swr >= 60 and "|cff40ff40" or (swr >= 55 and "|cffffa500" or "|cffff4040")
                    local cntC   = active and "|cffcccccc" or "|cff555555"
                    local dimPct = active and pctCol or "|cff555555"
                    wlTxt = cntC .. sw .. "-" .. sl .. "|r " .. dimPct .. string.format("(%.1f%%)", swr) .. "|r"
                end
                PvPTipRow(iconPath, nameC .. specName .. "|r", crTxt, mmrTxt,
                          SH_NAME, SH_CR, SH_MMR, nil, false, wlTxt, SH_WL)
            end
        end
    else
        -- Arena brackets (3-column layout: name | CR | MMR)
        PvPTipRow(nil, nil, "|cffffd700CR|r", "|cffffd700MMR|r", SP_NAME, SP_CR, SP_MMR, 14)
        PvPTipUnderline()
        local allSpecMMRs = {}
        if data.mmrHistory and data.mmrHistory[bracketKey] then
            for i = #data.mmrHistory[bracketKey], 1, -1 do
                local m = data.mmrHistory[bracketKey][i]
                if m.specID and m.postMatchMMR and m.postMatchMMR > 0 and not allSpecMMRs[m.specID] then
                    allSpecMMRs[m.specID] = { mmr = m.postMatchMMR }
                end
            end
        end
        if not next(allSpecMMRs) then
            allSpecMMRs = GetAllSpecMMRs(charKey, bracketKey)
        end
        local mmrData = data.mmrData and data.mmrData[bracketKey]
        if mmrData and mmrData.mmr and mmrData.mmr > 0 then
            local cID = mmrData.specID or data.specID or data.lastActiveSpecID
            if cID and not allSpecMMRs[cID] then
                allSpecMMRs[cID] = { mmr = mmrData.mmr }
            end
        end

        if next(allSpecMMRs) then
            hasAnyData = true
            local specList = {}
            for specID, d in pairs(allSpecMMRs) do
                table.insert(specList, { specID = tonumber(specID), mmr = type(d) == "table" and d.mmr or d })
            end
            table.sort(specList, function(a, b) return a.mmr > b.mmr end)

            for _, spec in ipairs(specList) do
                local specName, iconPath = "Unknown", nil
                if spec.specID and spec.specID > 0 then
                    local _si = GetCachedSpecInfo(spec.specID)
                    specName = (_si and _si.name) or specName
                    iconPath = _si and _si.icon
                end
                local specRating = 0
                if type(ratingsData) == "number" then specRating = ratingsData
                elseif type(ratingsData) == "table" and spec.specID then
                    specRating = ratingsData[spec.specID] or 0
                end
                local active = (spec.specID == currentSpecID)
                local nameC  = active and "|cff40ff40" or "|cff777777"
                local crC    = active and "|cffffd700" or "|cff777777"
                local mmrC   = active and "|cff4da6ff" or "|cff555555"
                local crTxt  = specRating > 0 and (crC .. specRating .. "|r")
                               or (active and "|cffffd7000|r" or "")
                local mmrTxt = spec.mmr > 0 and (mmrC .. spec.mmr .. "|r") or ""
                PvPTipRow(iconPath, nameC .. specName .. "|r", crTxt, mmrTxt)
            end
        elseif mmrData and mmrData.mmr and mmrData.mmr > 0 then
            hasAnyData = true
            PvPTipRow(nil, "|cffccccccMMR|r", "|cff4da6ff" .. mmrData.mmr .. "|r", nil)
        end
    end

    -- ── Win / Loss (Arena only — Shuffle/Blitz shows it per-spec in the W/L column) ──
    if isArena and wins + losses > 0 then
        local wrC   = winrate >= 60 and "|cff40ff40" or (winrate >= 55 and "|cffffa500" or "|cffff4040")
        local wlLine = "|cffcccccc" .. wins .. "-" .. losses .. "|r "
                       .. wrC .. string.format("(%.1f%%)|r", winrate)
        PvPTipSpacer(3)
        PvPTipRow("Interface\\Icons\\Achievement_Arena_2v2_7", wlLine, nil, nil,
                  SP_NAME, PT_W - PT_PAD, PT_W - PT_PAD)
    end

    -- ── Match history ───────────────────────────────────────────────────────
    if data.mmrHistory and data.mmrHistory[bracketKey] then
        local history  = data.mmrHistory[bracketKey]
        local numShow  = PVPHUB_SETTINGS.matchHistoryEntries or 1
        local matches  = {}
        for i = math.max(1, #history - numShow + 1), #history do
            table.insert(matches, history[i])
        end

        if #matches > 0 then
            hasAnyData = true
            PvPTipSeparator()
            PvPTipSpacer(4)

            -- Column header (unified: MMR | W/L | Date)
            PvPTipRow(nil,
                "|cffffd700MMR|r", "|cffffd700W/L|r", "|cffffd700Date|r",
                MH_COL1, MH_COL2, MH_COL3)
            PvPTipUnderline()

            for i = #matches, 1, -1 do
                local match = matches[i]
                local iPath = nil
                if match.specID and match.specID > 0 then
                    local _si = GetCachedSpecInfo(match.specID)
                    iPath = _si and _si.icon
                end
                local tText   = match.timestamp and FormatTimestamp(match.timestamp) or ""
                local dateCol = tText ~= "" and ("|cff666666" .. tText .. "|r") or ""

                -- Row highlight with edge fade: green=win, red=loss, grey=draw
                local rowWin, rowLoss, rowDraw = false, false, false
                if not isArena then
                    if match.roundsWon ~= nil and match.roundsLost ~= nil then
                        rowWin  = match.roundsWon  > match.roundsLost
                        rowLoss = match.roundsWon  < match.roundsLost
                        rowDraw = match.roundsWon == match.roundsLost
                    elseif match.ratingChange ~= nil then
                        rowWin  = match.ratingChange > 0
                        rowLoss = match.ratingChange < 0
                    end
                else
                    if match.ratingChange ~= nil then
                        rowWin  = match.ratingChange > 0
                        rowLoss = match.ratingChange < 0
                        -- Floor-protection: ratingChange==0 but the player still lost.
                        -- Use the stored winner/playerFaction to determine the true result.
                        if not rowWin and not rowLoss and match.winner ~= nil and match.playerFaction ~= nil then
                            if match.winner == match.playerFaction then
                                rowWin  = true
                            else
                                rowLoss = true
                            end
                        end
                    end
                end
                if rowWin  then PvPTipBand(PT_ROW, 0.0,  0.55, 0.10, 0.30) end
                if rowLoss then PvPTipBand(PT_ROW, 0.55, 0.04, 0.04, 0.30) end
                if rowDraw then PvPTipBand(PT_ROW, 0.45, 0.45, 0.45, 0.22) end

                if isArena then
                    local mmrAbs    = (match.postMatchMMR and match.postMatchMMR > 0) and ("|cffffffff" .. match.postMatchMMR .. "|r") or "|cff666666?|r"
                    local crCh      = match.ratingChange or 0
                    -- Determine W/L label.  Primary source: ratingChange sign.
                    -- Fallback for ratingChange==0 (floor-protection loss): use winner vs playerFaction.
                    local wlTxt
                    if crCh > 0 then
                        wlTxt = "|cff40ff40W|r"
                    elseif crCh < 0 then
                        wlTxt = "|cffff4040L|r"
                    elseif match.winner ~= nil and match.playerFaction ~= nil then
                        if match.winner == match.playerFaction then
                            wlTxt = "|cff40ff40W|r"
                        else
                            wlTxt = "|cffff4040L|r"
                        end
                    else
                        wlTxt = "|cffaaaaaa-|r"
                    end
                    local dateWhite = tText ~= "" and ("|cffffffff" .. tText .. "|r") or ""
                    PvPTipRow(iPath, mmrAbs, wlTxt, dateWhite, MH_COL1, MH_COL2, MH_COL3, nil, nil, nil, nil, PT_PAD + MH_SIDE)
                else
                    local mCh       = match.mmrChange or 0
                    local mC        = mCh >= 0 and "|cff40ff40" or "|cffff4040"
                    local mS        = mCh >= 0 and "+" or ""
                    local mmrAbs    = (match.postMatchMMR and match.postMatchMMR > 0) and ("|cffffffff" .. match.postMatchMMR .. "|r ") or ""
                    local wlTxt     = ""
                    if match.roundsWon ~= nil and match.roundsLost ~= nil then
                        local rc = match.roundsWon > match.roundsLost and "|cff40ff40"
                                   or (match.roundsWon < match.roundsLost and "|cffff4040" or "|cffaaaaaa")
                        wlTxt = rc .. match.roundsWon .. "-" .. match.roundsLost .. "|r"
                    end
                    local dateWhite = tText ~= "" and ("|cffffffff" .. tText .. "|r") or ""
                    PvPTipRow(iPath,
                        mmrAbs .. mC .. "(" .. mS .. mCh .. ")|r",
                        wlTxt,
                        dateWhite,
                        MH_COL1, MH_COL2, MH_COL3, nil, nil, nil, nil, PT_PAD + MH_SIDE)
                end
            end
        end
    end

    if not hasAnyData then
        PvPTipSpacer(6)
        PvPTipRow(nil, "|cffccccccNo data available|r", nil, "|cff888888Play to track|r",
                  PT_PAD, SP_NAME, SP_MMR)
    end

    PvPTipSpacer(PT_PAD)
    PvPTipShow(anchor)
end

-- Helper function to add MMR information to rating tooltips
local function AddMMRTooltipInfo(charKey, bracketKey, ratingsData)
    if not PVPHUB_DB[charKey] then 
        return 
    end
    
    local isArena = (bracketKey == "rating2v2" or bracketKey == "rating3v3")
    local isRated = (isArena or bracketKey == "ratingShuffle" or bracketKey == "ratingBlitz" or bracketKey == "ratingRBG")
    local currentSpecID = PVPHUB_DB[charKey].specID or PVPHUB_DB[charKey].lastActiveSpecID
    
    -- Modern separator styling
    GameTooltip:AddLine(" ", 1, 1, 1) -- Empty line
    
    -- Determine if we have ratings to show
    local hasRatings = false
    if type(ratingsData) == "number" and ratingsData > 0 then
        hasRatings = true
    elseif type(ratingsData) == "table" and next(ratingsData) then
        hasRatings = true
    end
    
    -- Skip MMR header if we have rating to show CR | MMR combined
    if not (isRated and hasRatings) then
        GameTooltip:AddLine("|cfffff700MMR|r", 1, 1, 1)
    end
    
    local mmrData = PVPHUB_DB[charKey].mmrData and PVPHUB_DB[charKey].mmrData[bracketKey]
    local hasAnyMMR = false
    
    -- Show MMR information
    if bracketKey == "ratingShuffle" or bracketKey == "ratingBlitz" then
        local allSpecMMRs = {}
        
        -- Get the latest MMR for each spec directly from match history
        if PVPHUB_DB[charKey].mmrHistory and PVPHUB_DB[charKey].mmrHistory[bracketKey] then
            local history = PVPHUB_DB[charKey].mmrHistory[bracketKey]
            
            -- Go through history from newest to oldest and get the latest MMR for each spec
            for i = #history, 1, -1 do
                local match = history[i]
                if match.specID and match.postMatchMMR and match.postMatchMMR > 0 then
                    -- Only add if we don't already have this spec (since we're going newest to oldest)
                    if not allSpecMMRs[match.specID] then
                        allSpecMMRs[match.specID] = {
                            mmr = match.postMatchMMR,
                            timestamp = match.timestamp or GetServerTime(),
                            specID = match.specID
                        }
                    end
                end
            end
        end
        
        -- Display the specs if we have any
        if next(allSpecMMRs) then
            hasAnyMMR = true
            
            local specList = {}
            for specID, data in pairs(allSpecMMRs) do
                table.insert(specList, {specID = tonumber(specID), mmr = data.mmr, data = data})
            end
            
            table.sort(specList, function(a, b) return a.mmr > b.mmr end)

            -- If the current spec has no MMR history (e.g. after respeccing) but has a 0-rating
            -- entry stored, inject it into the list so the tooltip shows 0 CR for it.
            if currentSpecID and not allSpecMMRs[currentSpecID] then
                if type(ratingsData) == "table" and ratingsData[currentSpecID] ~= nil then
                    table.insert(specList, {specID = currentSpecID, mmr = 0, data = {}})
                end
            end
            
            for _, spec in ipairs(specList) do
                local mmrColor = "|cff4da6ff"
                local specName = "Unknown"
                local specIcon = ""
                
                if spec.specID and spec.specID > 0 then
                    local _si = GetCachedSpecInfo(spec.specID)
                    if _si then
                        specName = _si.name
                        specIcon = "|T" .. _si.icon .. ":18:18:0:0:64:64:4:60:4:60|t "
                    end
                end
                
                -- For Shuffle/Blitz: show combined CR | MMR if rating provided
                local specRating = 0
                if type(ratingsData) == "number" then
                    specRating = ratingsData
                elseif type(ratingsData) == "table" and spec.specID then
                    specRating = ratingsData[spec.specID] or 0
                end
                
                if specRating > 0 then
                    if spec.specID == currentSpecID then
                        -- Active spec (highlighted in gold/blue)
                        GameTooltip:AddDoubleLine(
                            specIcon .. "|cff40ff40" .. specName .. "|r",
                            "|cffffd700" .. specRating .. " CR|r  |cff4da6ff" .. spec.mmr .. " MMR|r",
                            1, 1, 1, 1, 1, 1
                        )
                    else
                        -- Inactive spec (dimmed)
                        GameTooltip:AddDoubleLine(
                            specIcon .. "|cff777777" .. specName .. "|r",
                            "|cff777777" .. specRating .. " CR|r  |cff555555" .. spec.mmr .. " MMR|r",
                            1, 1, 1, 1, 1, 1
                        )
                    end
                elseif spec.specID == currentSpecID then
                    -- Current spec with 0 CR (respecced, no games played yet in this spec)
                    GameTooltip:AddDoubleLine(
                        specIcon .. "|cff40ff40" .. specName .. "|r",
                        "|cffffd7000 CR|r" .. (spec.mmr > 0 and ("  |cff4da6ff" .. spec.mmr .. " MMR|r") or ""),
                        1, 1, 1, 1, 1, 1
                    )
                else
                    -- MMR only (no CR data available)
                    GameTooltip:AddDoubleLine(
                        specIcon .. "|cff777777" .. specName .. "|r",
                        "|cff4da6ff" .. spec.mmr .. " MMR|r",
                        1, 1, 1, 1, 1, 1
                    )
                end
            end
        end
    else
        -- Arena brackets (2v2, 3v3) - check both match history and lastKnownMMR
        local allSpecMMRs = {}
        
        -- First, try to get MMR from match history (most recent and reliable)
        if PVPHUB_DB[charKey].mmrHistory and PVPHUB_DB[charKey].mmrHistory[bracketKey] then
            local history = PVPHUB_DB[charKey].mmrHistory[bracketKey]
            
            -- Go through history from newest to oldest and get the latest MMR for each spec
            for i = #history, 1, -1 do
                local match = history[i]
                if match.specID and match.postMatchMMR and match.postMatchMMR > 0 then
                    -- Only add if we don't already have this spec (since we're going newest to oldest)
                    if not allSpecMMRs[match.specID] then
                        allSpecMMRs[match.specID] = {
                            mmr = match.postMatchMMR,
                            timestamp = match.timestamp or GetServerTime(),
                            specID = match.specID
                        }
                    end
                end
            end
        end
        
        -- If no match history, fall back to lastKnownMMR system
        if not next(allSpecMMRs) then
            allSpecMMRs = GetAllSpecMMRs(charKey, bracketKey)
        end
        
        -- Add current MMR data if available and not already included
        if mmrData and mmrData.mmr and mmrData.mmr > 0 then
            local currentSpecID = mmrData.specID or PVPHUB_DB[charKey].specID or PVPHUB_DB[charKey].lastActiveSpecID
            if currentSpecID and not allSpecMMRs[currentSpecID] then
                allSpecMMRs[currentSpecID] = {
                    mmr = mmrData.mmr,
                    timestamp = mmrData.lastUpdate or GetServerTime(),
                    specID = currentSpecID
                }
            end
        end
        
        if next(allSpecMMRs) then
            hasAnyMMR = true
            
            local specList = {}
            for specID, data in pairs(allSpecMMRs) do
                table.insert(specList, {specID = tonumber(specID), mmr = data.mmr, data = data})
            end
            
            table.sort(specList, function(a, b) return a.mmr > b.mmr end)
            
            for _, spec in ipairs(specList) do
                local mmrColor = "|cffffffff"
                local specName = "Unknown"
                local specIcon = ""
                
                if spec.specID and spec.specID > 0 then
                    local _si = GetCachedSpecInfo(spec.specID)
                    if _si then
                        specName = _si.name
                        specIcon = "|T" .. _si.icon .. ":18:18:0:0:64:64:4:60:4:60|t "
                    end
                end
                
                -- For arena: show combined CR | MMR on one line
                local specRating = 0
                if type(ratingsData) == "number" then
                    specRating = ratingsData
                elseif type(ratingsData) == "table" and spec.specID then
                    specRating = ratingsData[spec.specID] or 0
                end
                
                if specRating > 0 then
                    if spec.specID == currentSpecID then
                        -- Active spec (highlighted in gold/blue)
                        GameTooltip:AddDoubleLine(
                            specIcon .. "|cff40ff40" .. specName .. "|r",
                            "|cffffd700" .. specRating .. " CR|r  |cff4da6ff" .. spec.mmr .. " MMR|r",
                            1, 1, 1, 1, 1, 1
                        )
                    else
                        -- Inactive spec (dimmed)
                        GameTooltip:AddDoubleLine(
                            specIcon .. "|cff777777" .. specName .. "|r",
                            "|cff777777" .. specRating .. " CR|r  |cff555555" .. spec.mmr .. " MMR|r",
                            1, 1, 1, 1, 1, 1
                        )
                    end
                elseif spec.specID == currentSpecID then
                    -- Current spec with 0 CR (respecced, no games played yet in this spec)
                    GameTooltip:AddDoubleLine(
                        specIcon .. "|cff40ff40" .. specName .. "|r",
                        "|cffffd7000 CR|r" .. (spec.mmr > 0 and ("  |cff4da6ff" .. spec.mmr .. " MMR|r") or ""),
                        1, 1, 1, 1, 1, 1
                    )
                else
                    -- MMR only (no CR data available)
                    GameTooltip:AddDoubleLine(
                        specIcon .. "|cff777777" .. specName .. "|r",
                        "|cff4da6ff" .. spec.mmr .. " MMR|r",
                        1, 1, 1, 1, 1, 1
                    )
                end
            end
        elseif mmrData and mmrData.mmr and mmrData.mmr > 0 then
            -- Fallback to single MMR display
            hasAnyMMR = true
            local mmrColor = "|cff4da6ff"
            local statusText = mmrData.fallback and " |cff888888(estimated)|r" or ""
            
            GameTooltip:AddDoubleLine(
                "|cffccccccMMR|r",
                mmrColor .. mmrData.mmr .. "|r" .. statusText,
                1, 1, 1, 1, 1, 1
            )
        end
    end
    
    -- Add Win/Loss Statistics - Always show for better visibility
    local wins, losses, winrate = GetWinLossStats(charKey, bracketKey)
    GameTooltip:AddLine(" ", 1, 1, 1) -- Empty line for spacing
    
    local winrateColor
    if winrate >= 60 then
        winrateColor = "|cff40ff40"
    elseif winrate >= 55 then
        winrateColor = "|cffffa500"
    else
        winrateColor = "|cffff4040"
    end
    
    -- Single inline line: "27 W / 19 L  (57.0%)"
    GameTooltip:AddLine(
        "|cff40ff40" .. wins .. "|r W / |cffff4040" .. losses .. "|r L  " .. winrateColor .. string.format("(%.1f%%)|r", winrate),
        1, 1, 1
    )
    
    -- Recent MMR changes - show for all brackets (Arena, Shuffle, Blitz)
    if PVPHUB_DB[charKey].mmrHistory and PVPHUB_DB[charKey].mmrHistory[bracketKey] then
        local history = PVPHUB_DB[charKey].mmrHistory[bracketKey]
        local recentMatches = {}
        local isArena = (bracketKey == "rating2v2" or bracketKey == "rating3v3")
        -- Use setting value (default to 1 if not set)
        local matchesToShow = PVPHUB_SETTINGS.matchHistoryEntries or 1
        
        for i = math.max(1, #history - (matchesToShow - 1)), #history do
            table.insert(recentMatches, history[i])
        end
        
        if #recentMatches > 0 then
            hasAnyMMR = true  -- Mark that we found MMR data in history
            GameTooltip:AddLine(" ", 1, 1, 1) -- Spacing
            
            -- Section title
            local historyCount = PVPHUB_SETTINGS.matchHistoryEntries or 1
            if isArena then
                local headerText = historyCount == 1 and "|cfffff700Latest Match|r" or "|cfffff700Latest Matches|r"
                GameTooltip:AddLine(headerText, 1, 1, 1)
            else
                local headerText = historyCount == 1 and "|cfffff700Latest Lobby|r" or "|cfffff700Latest Lobbies|r"
                GameTooltip:AddLine(headerText, 1, 1, 1)
            end
            
            -- Column header row
            if isArena then
                GameTooltip:AddDoubleLine(
                    "|cff555555CR / MMR|r",
                    "|cff555555Date|r",
                    1, 1, 1, 1, 1, 1
                )
            else
                GameTooltip:AddDoubleLine(
                    "|cff555555MMR / CR|r",
                    "|cff555555Rounds  Date|r",
                    1, 1, 1, 1, 1, 1
                )
            end
            
            for i = #recentMatches, 1, -1 do
                local match = recentMatches[i]
                
                -- Get spec icon for this match
                local matchSpecIcon = ""
                if match.specID and match.specID > 0 then
                    local _si = GetCachedSpecInfo(match.specID)
                    if _si and _si.icon then
                        matchSpecIcon = "|T" .. _si.icon .. ":16:16:0:0:64:64:4:60:4:60|t "
                    end
                end
                
                if isArena then
                    -- Arena row: left = [icon] +20 CR  +15 MMR  1870 | right = date
                    if match.postMatchMMR and match.ratingChange then
                        local crColor
                        if match.ratingChange == 0 then
                            crColor = "|cffffffff"
                        elseif match.ratingChange > 0 then
                            crColor = "|cff40ff40"
                        else
                            crColor = "|cffff4040"
                        end
                        local crSign = match.ratingChange >= 0 and "+" or ""
                        local mmrColor = match.mmrChange >= 0 and "|cff40ff40" or "|cffff4040"
                        local mmrSign = match.mmrChange >= 0 and "+" or ""
                        local timeText = match.timestamp and FormatTimestamp(match.timestamp) or ""
                        GameTooltip:AddDoubleLine(
                            matchSpecIcon .. crColor .. crSign .. match.ratingChange .. " CR|r  " .. mmrColor .. mmrSign .. match.mmrChange .. " MMR|r  |cffaaaaaa" .. match.postMatchMMR .. "|r",
                            timeText ~= "" and ("|cff666666" .. timeText .. "|r") or "",
                            1, 1, 1, 1, 1, 1
                        )
                    else
                        local timeText = match.timestamp and FormatTimestamp(match.timestamp) or ""
                        GameTooltip:AddDoubleLine(
                            matchSpecIcon .. "|cffaaaaaa" .. (match.postMatchMMR or match.preMatchMMR or "?") .. " MMR|r",
                            timeText ~= "" and ("|cff666666" .. timeText .. "|r") or "",
                            1, 1, 1, 1, 1, 1
                        )
                    end
                else
                    -- Shuffle/Blitz row: left = [icon] +14 MMR  +8 CR | right = 4-2  date
                    local crChange = match.ratingChange or 0
                    local crColor = crChange > 0 and "|cff40ff40" or (crChange < 0 and "|cffff4040" or "|cffffffff")
                    local crSign = crChange >= 0 and "+" or ""
                    local mmrColor = match.mmrChange >= 0 and "|cff40ff40" or "|cffff4040"
                    local mmrSign = match.mmrChange >= 0 and "+" or ""
                    local timeText = match.timestamp and FormatTimestamp(match.timestamp) or ""
                    -- Right column: rounds score + date
                    local rightCol = ""
                    if match.roundsWon ~= nil and match.roundsLost ~= nil then
                        local roundColor
                        if match.roundsWon > match.roundsLost then
                            roundColor = "|cff40ff40"
                        elseif match.roundsWon < match.roundsLost then
                            roundColor = "|cffff4040"
                        else
                            roundColor = "|cffaaaaaa"   -- 3-3 draw
                        end
                        rightCol = roundColor .. match.roundsWon .. "-" .. match.roundsLost .. "|r"
                        if timeText ~= "" then rightCol = rightCol .. "  |cff666666" .. timeText .. "|r" end
                    elseif timeText ~= "" then
                        rightCol = "|cff666666" .. timeText .. "|r"
                    end
                    -- Left column: MMR delta first (more important), then CR delta, then resulting MMR
                    GameTooltip:AddDoubleLine(
                        matchSpecIcon .. mmrColor .. mmrSign .. match.mmrChange .. " MMR|r  " .. crColor .. crSign .. crChange .. " CR|r  |cffaaaaaa" .. match.postMatchMMR .. "|r",
                        rightCol,
                        1, 1, 1, 1, 1, 1
                    )
                end
            end
        end
    end
    
    -- Show "Play a game" message only if we have no MMR data at all
    if not hasAnyMMR then
        GameTooltip:AddDoubleLine(
            "|cffccccccNo data available|r",
            "|cff888888Play to track|r",
            1, 1, 1, 1, 1, 1
        )
    end
end

-- Exposed for queue_timer.lua: show the full match-history tooltip for a
-- rated bracket by its short display name ("Shuffle", "2v2", etc.).
local QUEUE_BRACKET_KEY_MAP = {
    ["Shuffle"]  = "ratingShuffle",
    ["Blitz BG"] = "ratingBlitz",
    ["Rated BG"] = "ratingRBG",
    ["2v2"]      = "rating2v2",
    ["3v3"]      = "rating3v3",
}
function PVPHUB:ShowQueueBracketTooltip(anchor, displayName)
    local bracketKey = QUEUE_BRACKET_KEY_MAP[displayName]
    if not bracketKey then return end
    local charKey = GetFullName()
    if not charKey or charKey == "" or charKey == "-" then return end
    if not PVPHUB_DB or not PVPHUB_DB[charKey] then return end
    ShowPVPHUBRatingTooltip(anchor, charKey, bracketKey, PVPHUB_DB[charKey][bracketKey])
end

local function RequestRatedInfo()
    if C_PvP.RequestBracketStats then
        C_PvP.RequestBracketStats()
    end
    if C_PvP.RequestSeasonBestInfo then
        C_PvP.RequestSeasonBestInfo()
    end
end

local function UpdatePvPRatings()
    local charKey = GetFullName()
    if not charKey or charKey == "" or charKey == "-" then 
        DebugPrint("Invalid character name, skipping PvP update")
        return 
    end
    
    -- Ensure database integrity
    if not ValidateAndRestoreData() then
        DebugPrint("Database validation failed during PvP update")
    end
    
    PVPHUB_DB[charKey] = PVPHUB_DB[charKey] or {}

    for _, bracket in ipairs(PVP_BRACKETS) do
        local rating = 0
        
        -- Try different API calls for different brackets
        if bracket.key == "ratingShuffle" then
            -- Try multiple Solo Shuffle API calls
            local methods = {
                function() return GetPersonalRatedInfo(7) end,
                function()
                    -- Try to force fresh data by calling RequestBracketStats first
                    if C_PvP.RequestBracketStats then
                        C_PvP.RequestBracketStats()
                    end
                    return GetPersonalRatedInfo(7)
                end
            }
            
            for i, method in ipairs(methods) do
                local success, result = pcall(method)
                if success and result and result > 0 then
                    rating = result
                    break
                end
            end
        elseif bracket.key == "ratingBlitz" then
            -- Try multiple Blitz API calls
            local methods = {
                function() return GetPersonalRatedInfo(9) end,
                function()
                    -- Try to force fresh data by calling RequestBracketStats first
                    if C_PvP.RequestBracketStats then
                        C_PvP.RequestBracketStats()
                    end
                    return GetPersonalRatedInfo(9)
                end,
                function()
                    -- Try to get from PvP frame data if available
                    if PVPRatedFrame and PVPRatedFrame.seasonBest then
                        for _, data in pairs(PVPRatedFrame.seasonBest) do
                            if data.bracket == 9 then
                                return data.rating or 0
                            end
                        end
                    end
                    return 0
                end
            }
            
            for i, method in ipairs(methods) do
                local success, result = pcall(method)
                if success and result and result > 0 then
                    rating = result
                    break
                end
            end
        else
            -- Regular 2v2/3v3 brackets
            local success, result = pcall(GetPersonalRatedInfo, bracket.id)
            if success and result then
                rating = result
            end
        end
        
        rating = rating or 0

        -- Special handling for Solo Shuffle and Blitz to store per-spec
        if bracket.key == "ratingShuffle" or bracket.key == "ratingBlitz" then
            -- Always query the live spec from the API to avoid a race condition where
            -- PLAYER_SPECIALIZATION_CHANGED fires mid-transition and the DB specID still
            -- points to the OLD spec, causing a 0-rating to overwrite the old spec's entry.
            local currentSpecID = nil
            local specIndex = GetSpecialization()
            if specIndex then
                local ok, sid = pcall(GetSpecializationInfo, specIndex)
                if ok and sid and sid > 0 then
                    currentSpecID = sid
                    -- Keep DB in sync while we're here
                    PVPHUB_DB[charKey].specID = sid
                    PVPHUB_DB[charKey].lastActiveSpecID = sid
                end
            end
            -- Fallback to stored value only if the live query failed
            if not currentSpecID then
                currentSpecID = PVPHUB_DB[charKey].specID
            end

            -- Always initialize as table if it doesn't exist or is a number
            if type(PVPHUB_DB[charKey][bracket.key]) ~= "table" then
                PVPHUB_DB[charKey][bracket.key] = {}
            end
            
            -- Store rating for current spec — guard against specID=0 (truthy in Lua but
            -- means "no spec", would create a ghost [0] key causing false multi-spec stars).
            -- Also skip if this fires within 1.5s of a spec change: PVP_RATED_STATS_UPDATE
            -- can arrive immediately with the OLD spec's data still in the client cache,
            -- which would write the stale rating into the new spec's slot.  The 3.5s
            -- fallback timer always runs past this window with a guaranteed-fresh cache.
            -- Only write per-spec rating when _pvpCacheReady is true, meaning
            -- PVP_RATED_STATS_UPDATE has fired and confirmed the cache is fresh
            -- for this character session.  This prevents cross-character cache
            -- contamination (e.g. previous character's rating bleeding in) AND
            -- spec-change stale writes (first PVP_RATED_STATS_UPDATE after spec
            -- switch still has old-spec data; _pvpCacheReady isn't set until the
            -- second fire, which has the correct new-spec data).
            if currentSpecID and currentSpecID > 0 and PVPHUB._pvpCacheReady then
                PVPHUB_DB[charKey][bracket.key][currentSpecID] = rating
            end
        else
            -- Regular brackets (2v2, 3v3) store single rating — same guard:
            -- only write after PVP_RATED_STATS_UPDATE confirms server-fresh data.
            if PVPHUB._pvpCacheReady then
                PVPHUB_DB[charKey][bracket.key] = rating
            end
        end
        
        -- Sync wlData from bracketStats (the authoritative source written by
        -- pvp_tracking.lua).  We only do this when _pvpCacheReady is true so we
        -- never overwrite good saved data with stale/pre-match stats.
        -- Including the season number lets GetWinLossStats detect cross-season
        -- stale data for alt characters on future sessions.
        PVPHUB_DB[charKey].wlData = PVPHUB_DB[charKey].wlData or {}
        if PVPHUB._pvpCacheReady then
            local bs = PVPHUB_DB[charKey].bracketStats
                       and PVPHUB_DB[charKey].bracketStats[bracket.key]
            if bs then
                local w     = bs.won   or 0
                local l     = bs.lost  or 0
                local total = w + l
                PVPHUB_DB[charKey].wlData[bracket.key] = {
                    wins    = w,
                    losses  = l,
                    winrate = total > 0 and (w / total * 100) or 0,
                    season  = bs.season,  -- carry season for cross-season validation
                }
            end
        end
    end

    -- Silently track that we've updated this session (no chat noise)
    if not PVPHUB.lastRatingUpdate or PVPHUB.lastRatingUpdate ~= charKey then
        DebugPrint("PvP ratings updated for " .. charKey)
        PVPHUB.lastRatingUpdate = charKey
    end

    -- Refresh both main and compact windows if they exist
    if PVPHUB.window and PVPHUB.window:IsShown() and PVPHUB.window.UpdateContent then
        PVPHUB.window:UpdateContent()
    end
    if PVPHUB.compactWindow and PVPHUB.UpdateCompactWindow then
        PVPHUB:UpdateCompactWindow()
    end
end

-- Warband Bank gold is account-wide (shared across every character on the
-- account), not per-character like GetMoney() — so unlike data.gold it's
-- stored once in PVPHUB_SETTINGS rather than per charKey in PVPHUB_DB, and
-- added to the Total Gold summary once rather than per character. Guarded
-- against the API not existing (older client, or a future rename) since
-- this hasn't been verified against a live game session.
local function FetchWarbandGold()
    if not C_Bank or not C_Bank.FetchDepositedMoney then return nil end
    if not Enum or not Enum.BankType or not Enum.BankType.Account then return nil end
    local ok, amount = pcall(C_Bank.FetchDepositedMoney, Enum.BankType.Account)
    if ok and type(amount) == "number" then
        return amount
    end
    return nil
end

local function UpdateAllData()
    -- Ensure database integrity before updates
    if not ValidateAndRestoreData() then
        DebugPrint("Database validation failed during full update")
    end
    
    -- Update gold and PvP item level
    local playerName = UnitName("player") or "Unknown"
    local realmName = GetRealmName() or "Unknown"
    local charKey = playerName .. "-" .. realmName
    PVPHUB_DB[charKey] = PVPHUB_DB[charKey] or {}
    
    -- Update last seen timestamp
    PVPHUB_DB[charKey].lastSeen = GetServerTime()

    -- Get gold
    PVPHUB_DB[charKey].gold = GetMoney() or 0

    -- Get Warband Bank gold (account-wide, see FetchWarbandGold)
    local warbandGold = FetchWarbandGold()
    if warbandGold then
        PVPHUB_SETTINGS.warbandGold = warbandGold
    end

    -- Get regular item level
    local avgItemLevel, avgItemLevelEquipped = GetAverageItemLevel()
    PVPHUB_DB[charKey].itemLevel = avgItemLevelEquipped or avgItemLevel or 0
    
    -- Get PvP item level using Blizzard's exact methods
    local pvpItemLevel = 0
    local detectionMethod = "none"
    
    -- Method 1: Use GetAverageItemLevel with PvP context like Blizzard does
    if GetAverageItemLevel then
        local avgEquipped, avgInventory, avgItemLevelPvP = GetAverageItemLevel()
        if avgItemLevelPvP and avgItemLevelPvP > 0 then
            pvpItemLevel = avgItemLevelPvP
            detectionMethod = "GetAverageItemLevel_PvP"
        end
    end
    
    -- Method 2: Try PaperDollFrame's internal PvP calculation
    if pvpItemLevel == 0 and PaperDollFrame_GetEffectiveItemLevel then
        local effectiveIL = PaperDollFrame_GetEffectiveItemLevel()
        if effectiveIL and effectiveIL > 0 and effectiveIL ~= avgItemLevelEquipped then
            pvpItemLevel = effectiveIL
            detectionMethod = "PaperDollFrame_GetEffectiveItemLevel"
        end
    end
    
    -- Method 3: Check if we're in a PvP instance and use C_PvP
    if pvpItemLevel == 0 and C_PvP then
        if C_PvP.GetAverageItemLevel then
            local pvpIL = C_PvP.GetAverageItemLevel()
            if pvpIL and pvpIL > 0 then
                pvpItemLevel = pvpIL
                detectionMethod = "C_PvP.GetAverageItemLevel"
            end
        end
    end
    
    -- Method 4: Access the CharacterStatsPane directly when it's loaded
    if pvpItemLevel == 0 and CharacterStatsPane and CharacterStatsPane.ItemLevelFrame then
        local frame = CharacterStatsPane.ItemLevelFrame
        if frame.pvpItemLevel and frame.pvpItemLevel > 0 then
            pvpItemLevel = frame.pvpItemLevel
            detectionMethod = "CharacterStatsPane.pvpItemLevel"
        end
    end
    
    -- Method 5: Use PvP template scaling (more accurate than fixed +58)
    if pvpItemLevel == 0 and avgItemLevelEquipped and avgItemLevelEquipped > 0 then
        -- Use template scaling based on current season
        local scalingFactor = 1.0884 -- Current season scaling factor
        pvpItemLevel = math.floor(avgItemLevelEquipped * scalingFactor + 0.5)
        detectionMethod = "template_scaling"
    end
    
    -- Round to nearest integer if we got a decimal value
    if pvpItemLevel > 0 then
        pvpItemLevel = math.floor(pvpItemLevel + 0.5)
    end
    
    -- Store both regular and PvP item levels
    PVPHUB_DB[charKey].pvpItemLevel = pvpItemLevel
    
    UpdateCurrencyData()
    C_Timer.After(0.5, UpdatePvPRatings)
    C_Timer.After(1.0, UpdateMMRData) -- Update MMR data after PvP ratings
    PVPHUB.RefreshUI()
end

-- Throttling system to prevent spam updates
local lastUpdateTime = 0
local updateThrottle = 2 -- Minimum 2 seconds between updates
local pendingThrottledUpdate = false

local function ThrottledUpdate()
    local currentTime = GetTime()
    local elapsed = currentTime - lastUpdateTime
    if elapsed < updateThrottle then
        -- Queue one deferred update so the final state is never dropped
        if not pendingThrottledUpdate then
            pendingThrottledUpdate = true
            C_Timer.After(updateThrottle - elapsed, function()
                pendingThrottledUpdate = false
                lastUpdateTime = GetTime()
                UpdateAllData()
            end)
        end
        return
    end
    lastUpdateTime = currentTime
    UpdateAllData()
end

PVPHUB.frame:RegisterEvent("PLAYER_LOGIN")
PVPHUB.frame:RegisterEvent("CURRENCY_DISPLAY_UPDATE")
PVPHUB.frame:RegisterEvent("PLAYER_ENTERING_WORLD")
PVPHUB.frame:RegisterEvent("PVP_RATED_STATS_UPDATE")
PVPHUB.frame:RegisterEvent("BAG_UPDATE_DELAYED")
PVPHUB.frame:RegisterEvent("ADDON_LOADED")
PVPHUB.frame:RegisterEvent("PLAYER_SPECIALIZATION_CHANGED")
PVPHUB.frame:RegisterEvent("PLAYER_MONEY")  -- Fires immediately when gold changes
-- Add PvP-specific events for better arena/BG detection
PVPHUB.frame:RegisterEvent("UPDATE_BATTLEFIELD_STATUS")
PVPHUB.frame:RegisterEvent("PVP_MATCH_ACTIVE")
PVPHUB.frame:RegisterEvent("PVP_MATCH_INACTIVE")
PVPHUB.frame:RegisterEvent("PVP_MATCH_COMPLETE")
PVPHUB.frame:RegisterEvent("UI_SCALE_CHANGED")
-- Add combat events for combat-aware window opening
PVPHUB.frame:RegisterEvent("PLAYER_REGEN_DISABLED")
PVPHUB.frame:RegisterEvent("PLAYER_REGEN_ENABLED")

-- Runs one login-init step in its own pcall so a failure partway through
-- ADDON_LOADED (a bad font file, a malformed SavedVariables entry, etc.)
-- only skips that one step instead of silently aborting every step after it
-- for the rest of the session.
local function SafeInitStep(label, fn)
    local ok, err = pcall(fn)
    if not ok then
        PVPHubPrint("|cffff0000[PVP HUB]|r Startup step \"" .. label .. "\" failed: " .. tostring(err))
    end
end

PVPHUB.frame:HookScript("OnEvent", function(self, event, ...)
    -- Capture the arguments before the pcall
    local args = {...}
    
    -- Protect against addon conflicts and taint issues
    local success, errorMsg = pcall(function()
        if event == "ADDON_LOADED" then
            local addonName = args[1]
            if addonName == "PVPHUB" then
                -- Each step below runs in its own pcall via SafeInitStep so a
                -- failure partway through login init can't silently skip the
                -- rest of initialization for the whole session — only that
                -- one step is skipped, and it's reported in chat.
                SafeInitStep("cleanup test data", function()
                    -- One-time cleanup: remove injected test characters
                    if not PVPHUB_SETTINGS.cleanedTestData_v1 then
                        local testChars = { "Sünde-Silvermoon", "Veryrare-Silvermoon", "Xehanort-Silvermoon" }
                        for _, key in ipairs(testChars) do
                            if PVPHUB_DB then PVPHUB_DB[key] = nil end
                        end
                        PVPHUB_SETTINGS.cleanedTestData_v1 = true
                    end
                end)

                SafeInitStep("validate data integrity", function()
                    -- Validate data integrity on addon load
                    ValidateAndRestoreData()
                end)

                SafeInitStep("DB schema versioning", function()
                    -- DB schema versioning: increment CURRENT_DB_VERSION when the
                    -- character data structure changes between releases.
                    -- Add a migration block (if PVPHUB_DB.__dbVersion < N then ... end)
                    -- before bumping the constant so existing users upgrade cleanly.
                    local CURRENT_DB_VERSION = 4
                    PVPHUB_DB.__dbVersion = PVPHUB_DB.__dbVersion or 0

                    if PVPHUB_DB.__dbVersion < 4 then
                        -- One-time cleanup for anyone who hit the old bug before
                        -- ClearCharacterSeasonData existed: the season-data reset
                        -- (automatic boundary detection or "Start Fresh") used to
                        -- clear bracketStats/wlData/etc. but not the legacy flat
                        -- rating fields (rating2v2/rating3v3/ratingRBG/
                        -- ratingShuffle/ratingBlitz) that the UI actually reads.
                        --
                        -- Earlier versions of this migration (v2, v3) gated on
                        -- "is bracketStats nil", but that signal doesn't survive
                        -- a respec: ratingShuffle/ratingBlitz are stored per spec
                        -- (specID -> rating), and SaveBracketStats only ever
                        -- refreshes the CURRENTLY active spec's slot — a fresh
                        -- game on the new spec repopulates bracketStats entirely,
                        -- masking the fact that the OLD spec's slot in the same
                        -- table is untouched leftover from before the reset.
                        --
                        -- Each bracketStats entry carries its own `season` tag,
                        -- so instead compare per-slot: a legacy value survives
                        -- only if bracketStats has a same-season entry backing
                        -- it specifically (per bracket for 2v2/3v3/RBG, per
                        -- spec for Shuffle/Blitz) — anything else is leftover.
                        local currentSeason = (C_PvP and C_PvP.GetUIDisplaySeason and C_PvP.GetUIDisplaySeason()) or 0
                        if currentSeason > 0 then
                            for charKey, cdata in pairs(PVPHUB_DB) do
                                if type(cdata) == "table" and charKey ~= "settings" then
                                    local bs = cdata.bracketStats

                                    for _, key in ipairs({"rating2v2", "rating3v3", "ratingRBG"}) do
                                        local entry = type(bs) == "table" and bs[key]
                                        local isFresh = type(entry) == "table" and entry.season == currentSeason
                                        if not isFresh then
                                            cdata[key] = nil
                                        end
                                    end

                                    for _, key in ipairs({"ratingShuffle", "ratingBlitz"}) do
                                        local legacy = cdata[key]
                                        if type(legacy) == "table" then
                                            local bsBracket = type(bs) == "table" and bs[key]
                                            for specID in pairs(legacy) do
                                                local entry = type(bsBracket) == "table" and bsBracket[specID]
                                                local isFresh = type(entry) == "table" and entry.season == currentSeason
                                                if not isFresh then
                                                    legacy[specID] = nil
                                                end
                                            end
                                        end
                                    end
                                end
                            end
                        end
                    end

                    PVPHUB_DB.__dbVersion = CURRENT_DB_VERSION
                end)

                SafeInitStep("GUID rename/transfer migration", function()
                    -- GUID-based rename/transfer detection.
                    -- Store the current character's GUID so future sessions can detect
                    -- if the character was renamed or server-transferred between logins.
                    local playerGUID = UnitGUID("player")
                    local charKey = GetFullName()
                    if playerGUID and charKey and charKey ~= "" and charKey ~= "-" then
                        PVPHUB_DB[charKey] = PVPHUB_DB[charKey] or {}
                        PVPHUB_DB[charKey].guid = playerGUID
                        -- Scan for a stale entry under the old name/realm
                        for oldKey, oldData in pairs(PVPHUB_DB) do
                            if oldKey ~= charKey
                               and oldKey ~= "__dbVersion"
                               and type(oldData) == "table"
                               and oldData.guid == playerGUID then
                                -- Merge: copy fields the new key doesn't already have
                                for k, v in pairs(oldData) do
                                    if PVPHUB_DB[charKey][k] == nil then
                                        PVPHUB_DB[charKey][k] = v
                                    end
                                end
                                PVPHUB_DB[oldKey] = nil
                                PVPHubPrint("|cff00ff00[PVPHUB]|r Character data migrated from " .. oldKey .. " to " .. charKey .. ".")
                                break
                            end
                        end
                    end
                end)

                SafeInitStep("rebuild hidden character set", function()
                    -- Build hidden character hash set for O(1) lookups
                    RebuildHiddenSet()
                end)

                SafeInitStep("register bundled fonts", function()
                    -- Initialise the shared data font from saved settings.
                    -- Register PVPHUB's bundled fonts with LibSharedMedia so they always
                    -- appear in the font picker regardless of what other addons are installed.
                    if LibStub then
                        local LSM = LibStub("LibSharedMedia-3.0", true)
                        if LSM then
                            local base = "Interface\\AddOns\\PVPHUB\\media\\fonts\\"
                            local bundled = {
                                { "PVP - Expressway",           "Expressway.ttf"          },
                                { "PVP - Prototype",            "Prototype.ttf"           },
                                { "PVP - Accidental Presidency","AccidentalPresidency.ttf"},
                                { "PVP - Exo 2 Bold",           "Exo2-Bold.ttf"           },
                                { "PVP - Inter Bold",           "Inter-Bold.ttf"          },
                                { "PVP - Oswald Bold",          "Oswald-Bold.ttf"         },
                                { "PVP - Rajdhani SemiBold",    "Rajdhani-SemiBold.ttf"   },
                                { "PVP - Bebas Neue",           "BebasNeue-Regular.ttf"   },
                                { "PVP - Barlow Condensed Bold","BarlowCondensed-Bold.ttf"},
                                { "PVP - Titillium Bold",       "TitilliumWeb-Bold.ttf"   },
                                { "PVP - 2002 Bold",            "2002Bold.ttf"            },
                                { "PVP - Avant Garde",          "AvantGarde.ttf"          },
                            }
                            -- Only register fonts whose TTF files actually exist on disk.
                            -- SetFont returns false (not an error) for missing files, so we
                            -- use a throwaway FontString to validate before registering.
                            local _validationFS = UIParent:CreateFontString(nil, "ARTWORK")
                            local validBundled = {}
                            for _, entry in ipairs(bundled) do
                                local path = base .. entry[2]
                                local ok, result = pcall(function() return _validationFS:SetFont(path, 12) end)
                                if ok and result then
                                    LSM:Register("font", entry[1], path)
                                    table.insert(validBundled, entry)
                                end
                            end
                            _validationFS:Hide()
                            -- Store for GetAvailableFonts / GetFontPath (only valid entries)
                            PVPHUB.bundledFonts = validBundled
                            PVPHUB.bundledFontBase = base
                        end
                    end
                end)

                SafeInitStep("schedule font apply", function()
                    -- Must run after SavedVariables are loaded so selectedFont is ready.
                    -- Deferred by one tick so LSM (OptionalDep) is guaranteed to be fully loaded.
                    C_Timer.After(0, function()
                        local sel  = (PVPHUB_SETTINGS and PVPHUB_SETTINGS.selectedFont) or "Friz Quadrata TT"
                        local size = 12
                        local path
                        if LibStub then
                            local LSM = LibStub("LibSharedMedia-3.0", true)
                            if LSM then
                                local ok, p = pcall(function() return LSM:Fetch("font", sel) end)
                                if ok and p then path = p end
                            end
                        end
                        local _b = {["Friz Quadrata TT"]="Fonts\\FRIZQT__.TTF",["Arial Narrow"]="Fonts\\ARIALN.TTF",["Morpheus"]="Fonts\\MORPHEUS.TTF",["Skurri"]="Fonts\\skurri.ttf"}
                        path = path or _b[sel] or "Fonts\\FRIZQT__.TTF"
                        PVPHUB.currentFontPath = path
                        PVPHUB.dataFont:SetFont(path, size, "OUTLINE")
                    end)
                end)

                SafeInitStep("migrate Ungrouped group name", function()
                    -- Migration: Rename "Ungrouped" to "No Group" in existing saved data
                    if PVPHUB_SETTINGS.characterGroups and PVPHUB_SETTINGS.characterGroups.groups then
                        for _, group in ipairs(PVPHUB_SETTINGS.characterGroups.groups) do
                            if group.name == "Ungrouped" then
                                group.name = "No Group"
                            end
                        end
                    end
                end)

                SafeInitStep("initialize MMR data", function()
                    -- Initialize MMR data
                    UpdateMMRData()
                end)

                SafeInitStep("prewarm spec lookup table", function()
                    -- GetSpecLookup() lazily loops every specID (60-1500) on its
                    -- first call. Left alone, that first call lands inside
                    -- TrackMMRChange right as an arena/BG match ends — the worst
                    -- possible moment for a synchronous API burst. Prewarm it
                    -- here instead, a few seconds after login, well before any
                    -- match could finish.
                    C_Timer.After(5, GetSpecLookup)
                end)

                SafeInitStep("schedule PvP data refresh", function()
                    -- Force refresh PvP data to prevent stale ratings from previous characters
                    C_Timer.After(1, function()
                        if C_PvP.RequestBracketStats then
                            C_PvP.RequestBracketStats()
                        end
                        if C_PvP.RequestSeasonBestInfo then
                            C_PvP.RequestSeasonBestInfo()
                        end
                        -- Refresh the UI after requesting fresh data
                        C_Timer.After(0.5, function()
                            PVPHUB_RefreshUI()
                        end)
                    end)
                end)

                SafeInitStep("clean up dummy character data", function()
                    -- Clean up any dummy/example data from testing
                    if PVPHUB_DB["Shadowmage-Stormrage"] then
                        PVPHUB_DB["Shadowmage-Stormrage"] = nil
                    end
                    if PVPHUB_DB["Holyknight-TichondiusDemoExampleData"] then
                        PVPHUB_DB["Holyknight-TichondiusDemoExampleData"] = nil
                    end
                end)

                SafeInitStep("clean up dummy MMR history", function()
                    -- Clean up any existing dummy MMR history data for current character
                    local charKey = GetFullName()
                    if charKey and PVPHUB_DB[charKey] and PVPHUB_DB[charKey].mmrHistory then
                        -- Check if there are suspicious dummy entries (0 MMR changes)
                        for bracketKey, history in pairs(PVPHUB_DB[charKey].mmrHistory) do
                            local allZeroes = true
                            for _, match in ipairs(history) do
                                if match.mmrChange ~= 0 or match.preMatchMMR ~= 0 or match.postMatchMMR ~= 0 then
                                    allZeroes = false
                                    break
                                end
                            end
                            -- Remove histories that are all dummy/zero data
                            if allZeroes then
                                PVPHUB_DB[charKey].mmrHistory[bracketKey] = {}
                            end
                        end
                    end
                end)

                SafeInitStep("initialize settings defaults", function()
                    -- Initialize settings with protection
                    PVPHUB_SETTINGS = PVPHUB_SETTINGS or {
                        visibleColumns = {
                            character = true,
                            honor = true,
                            conquest = true,
                            bloodstones = true,
                            rating2v2 = true,
                            rating3v3 = true,
                            ratingShuffle = true,
                            ratingBlitz = true,
                            ratingRBG = true,
                            delete = true
                        },
                        compactMode = {
                            enabled = false,
                            selectedChars = {},
                            showRatings = {
                                rating2v2 = true,
                                rating3v3 = true,
                                ratingShuffle = true,
                                ratingBlitz = false,
                                ratingRBG = false
                            }
                        },
                        colorTheme = "BLUE", -- Default theme
                        welcomeShown = false -- Track if welcome popup has been shown
                    }
                    if not PVPHUB_SETTINGS.colorTheme then
                        PVPHUB_SETTINGS.colorTheme = "BLUE"
                    end
                    if not PVPHUB_SETTINGS.mainWindow then
                        PVPHUB_SETTINGS.mainWindow = {}
                    end
                    if PVPHUB_SETTINGS.mainWindow.roundedFrame == nil then
                        PVPHUB_SETTINGS.mainWindow.roundedFrame = true
                    end
                    -- Ensure scale settings exist
                    if not PVPHUB_SETTINGS.windowScale then
                        PVPHUB_SETTINGS.windowScale = 1.0
                    end
                    if not PVPHUB_SETTINGS.compactWindowScale then
                        PVPHUB_SETTINGS.compactWindowScale = 1.0
                    end
                end)

                SafeInitStep("apply theme and refresh windows", function()
                    ApplyTheme()
                    RefreshAllWindows()
                end)

                SafeInitStep("backfill settings defaults for upgrades", function()
                    if not PVPHUB_SETTINGS.compactMode then
                        PVPHUB_SETTINGS.compactMode = {
                            enabled = false,
                            selectedChars = {},
                            showRatings = {
                                rating2v2 = true,
                                rating3v3 = true,
                                ratingShuffle = true,
                                ratingBlitz = false,
                                ratingRBG = false
                            }
                        }
                    end
                    local defaultColumns = {
                        character = true,
                        honor = true,
                        conquest = true,
                        bloodstones = true,
                        rating2v2 = true,
                        rating3v3 = true,
                        ratingShuffle = true,
                        ratingBlitz = true,
                        ratingRBG = true,
                        delete = true
                    }
                    for column, default in pairs(defaultColumns) do
                        if PVPHUB_SETTINGS.visibleColumns[column] == nil then
                            PVPHUB_SETTINGS.visibleColumns[column] = default
                        end
                    end
                end)

                SafeInitStep("welcome/update popup", function()
                    local currentVersion = C_AddOns.GetAddOnMetadata("PVPHUB", "Version") or "Unknown"
                    if not PVPHUB_SETTINGS.welcomeShown then
                        -- Fresh install: show welcome, record version, skip update popup
                        PVPHUB_SETTINGS.lastSeenVersion = currentVersion
                        C_Timer.After(1, function()
                            PVPHUB:ShowWelcomePopup()
                        end)
                    elseif PVPHUB_SETTINGS.lastSeenVersion ~= currentVersion then
                        -- Existing user, version changed: show update popup
                        PVPHUB_SETTINGS.lastSeenVersion = currentVersion
                        C_Timer.After(2, function()
                            PVPHUB:ShowUpdatePopup(currentVersion)
                        end)
                    end
                end)

                SafeInitStep("schedule compact window auto-open", function()
                    if PVPHUB_SETTINGS.compactWindowStayOpen and not PVPHUB_SETTINGS.disableStreamerMode then
                        C_Timer.After(1, function()
                            PVPHUB:CreateCompactWindow()
                        end)
                    end
                end)

                SafeInitStep("schedule title tracker restore", function()
                    -- Restore the floating title tracker (no-ops if nothing is
                    -- ticked "track" in PVPHUB_SETTINGS.trackedTitles).
                    C_Timer.After(1, function()
                        if PVPHUB.UpdateTitleTracker then PVPHUB:UpdateTitleTracker() end
                    end)
                end)

                SafeInitStep("schedule initial backup", function()
                    -- Create initial backup after settings load
                    C_Timer.After(3, CreateDataBackup)
                end)

                PVPHubPrint("|cffff0000[PVP HUB]|r Addon loaded!")
            end
    elseif event == "PLAYER_SPECIALIZATION_CHANGED" then
        -- Handle spec changes - simple version without notification system
        local charKey = GetFullName()
        if charKey and charKey ~= "" and charKey ~= "-" and not PVPHUB_IGNORED[charKey] then
            PVPHUB_DB[charKey] = PVPHUB_DB[charKey] or {}
            
            local specIndex = GetSpecialization()
            if specIndex then
                local specID = GetSpecializationInfo(specIndex)
                if specID then
                    -- Update spec information
                    PVPHUB_DB[charKey].specID = specID
                    PVPHUB_DB[charKey].lastActiveSpecID = specID

                    -- Update spec name and icon
                    local _si = GetCachedSpecInfo(specID)
                    if _si then
                        PVPHUB_DB[charKey].specName = _si.name
                        PVPHUB_DB[charKey].specIcon = _si.icon
                    end

                    -- Pre-initialize per-spec rating slots for the new spec to 0 if this
                    -- spec has never been seen before.  This prevents the display from
                    -- falling back to a different spec's rating while waiting for the server.
                    for _, bkey in ipairs({"ratingShuffle", "ratingBlitz"}) do
                        if type(PVPHUB_DB[charKey][bkey]) ~= "table" then
                            PVPHUB_DB[charKey][bkey] = {}
                        end
                        if PVPHUB_DB[charKey][bkey][specID] == nil then
                            PVPHUB_DB[charKey][bkey][specID] = 0
                        end
                    end

                    -- Record when the spec changed so PVP_RATED_STATS_UPDATE handlers
                    -- can skip writing stale old-spec data into the new spec's slot.
                    PVPHUB._specChangeTime = GetTime()
                    -- Cache is untrustworthy until the server sends fresh data.
                    PVPHUB._pvpCacheReady   = false

                    -- Ask the server for fresh bracket stats for the new spec.
                    -- PVP_RATED_STATS_UPDATE fires when the server responds and its
                    -- handler already calls UpdatePvPRatings() with the correct data.
                    -- The delayed call below is a fallback only; the 3.5s delay
                    -- ensures the server has responded and the client-side
                    -- GetPersonalRatedInfo() cache is no longer stale.
                    if C_PvP.RequestBracketStats then
                        C_PvP.RequestBracketStats()
                    end
                    -- Do NOT call UpdatePvPRatings() directly here: the client cache
                    -- may still be stale at 3.5s if only one PVP_RATED_STATS_UPDATE
                    -- fired (within the 1.5s stale window).  Re-request instead to
                    -- force the server to send a fresh response, which the
                    -- PVP_RATED_STATS_UPDATE handler will then persist correctly.
                    C_Timer.After(3.5, function()
                        if C_PvP.RequestBracketStats then
                            C_PvP.RequestBracketStats()
                        end
                    end)

                    -- Refresh windows if they're open
                    if PVPHUB.window and PVPHUB.window:IsShown() and PVPHUB.window.UpdateContent then
                        PVPHUB.window:UpdateContent()
                    end
                    if PVPHUB.compactWindow and PVPHUB.UpdateCompactWindow then
                        PVPHUB:UpdateCompactWindow()
                    end
                end
            end
        end
    elseif event == "PLAYER_ENTERING_WORLD" then
        -- On every new character session the client cache may hold stale data from
        -- the previous character; block per-spec writes until the server confirms.
        -- We intentionally do NOT wipe stored per-spec tables: the last known values
        -- are shown while waiting for PVP_RATED_STATS_UPDATE, which is correct UX.
        -- The _pvpCacheReady flag ensures no stale data gets written before the
        -- server responds. PVP_RATED_STATS_UPDATE will overwrite any stale values.
        PVPHUB._pvpCacheReady = false

        -- Fallback: if PVP_RATED_STATS_UPDATE never fires (e.g. fresh character
        -- with no PvP history), unblock writes after 8s so data isn't silently
        -- dropped the entire session.
        C_Timer.After(8, function()
            if not PVPHUB._pvpCacheReady then
                PVPHUB._pvpCacheReady = true
            end
        end)

        local enteringPvP = IsInActivePvP()

        -- Force refresh PvP data to ensure current character's ratings are loaded.
        -- Skip when entering a PvP instance: ratings haven't changed yet, and the
        -- UI rebuild (UpdateContent) would cause visible row flashing + stutter.
        -- PVP_RATED_STATS_UPDATE fires after the match and triggers the real update.
        if not enteringPvP then
            C_Timer.After(1, function()
                if C_PvP.RequestBracketStats then
                    C_PvP.RequestBracketStats()
                end
                if C_PvP.RequestSeasonBestInfo then
                    C_PvP.RequestSeasonBestInfo()
                end
                -- Refresh the UI after requesting fresh data
                C_Timer.After(0.5, function()
                    UpdateMMRData()
                    PVPHUB_RefreshUI()
                end)
            end)
        end

        -- Handle arena/BG detection for compact window hiding.
        -- When entering a PvP instance, hide the compact window immediately using
        -- the already-confirmed enteringPvP value — no delay needed, and a delay
        -- is the cause of the visible 0.5 s "flash" the user sees on arena zone-in.
        if enteringPvP and PVPHUB_SETTINGS and PVPHUB_SETTINGS.compactMode and PVPHUB_SETTINGS.compactMode.hideInPvP then
            if PVPHUB.compactWindow and PVPHUB.compactWindow:IsShown() then
                PVPHUB._compactWindowWasOpenBeforePvP = true
                PVPHUB.compactWindow:Hide()
            end
        end

        -- Delayed check handles: (1) zone-out restoration, (2) edge cases where
        -- IsInInstance() wasn't ready at T=0, (3) re-show when hideInPvP is off.
        C_Timer.After(0.5, function()
            if PVPHUB_SETTINGS and PVPHUB_SETTINGS.compactMode and PVPHUB_SETTINGS.compactMode.hideInPvP then
                local isInActivePvP = IsInActivePvP()

                if isInActivePvP then
                    -- Belt-and-suspenders: hide in case the immediate check above missed it
                    -- (e.g. IsInInstance() was not yet updated at T=0 in some clients).
                    if PVPHUB.compactWindow and PVPHUB.compactWindow:IsShown() then
                        PVPHUB._compactWindowWasOpenBeforePvP = true
                        PVPHUB.compactWindow:Hide()
                    end
                else
                    -- Leaving active PvP - restore compact window if it was open before
                    if PVPHUB._compactWindowWasOpenBeforePvP then
                        PVPHUB:CreateCompactWindow()
                    end
                    PVPHUB._compactWindowWasOpenBeforePvP = false
                end
            elseif PVPHUB_SETTINGS.compactWindowStayOpen and not PVPHUB_SETTINGS.disableStreamerMode then
                -- General zone transition (hideInPvP off): re-show the compact window
                -- if it should be open but is currently hidden (e.g. screen reload edge case).
                if PVPHUB.compactWindow and not PVPHUB.compactWindow:IsShown() then
                    PVPHUB:CreateCompactWindow()
                end
            end
        end)

        -- Normal data update — skip when entering a PvP instance to prevent
        -- UpdateContent() from tearing down and rebuilding all row frames mid-load.
        if not enteringPvP then
            ThrottledUpdate()
        end
    elseif event == "UPDATE_BATTLEFIELD_STATUS" or event == "PVP_MATCH_ACTIVE" or event == "PVP_MATCH_INACTIVE" then
        -- Handle real-time PvP status changes for compact window hiding
        if PVPHUB_SETTINGS and PVPHUB_SETTINGS.compactMode and PVPHUB_SETTINGS.compactMode.hideInPvP then
            C_Timer.After(0.1, function() -- Small delay to ensure APIs are updated
                local isInActivePvP = IsInActivePvP()
                
                if isInActivePvP then
                    -- Entering active PvP - hide compact window
                    if PVPHUB.compactWindow and PVPHUB.compactWindow:IsShown() then
                        PVPHUB._compactWindowWasOpenBeforePvP = true
                        PVPHUB.compactWindow:Hide()
                    end
                else
                    -- Leaving active PvP - restore compact window if it was open before
                    if PVPHUB._compactWindowWasOpenBeforePvP then
                        PVPHUB:CreateCompactWindow()
                    end
                    PVPHUB._compactWindowWasOpenBeforePvP = false
                end
            end)
        end
        -- Snapshot Solo Shuffle round stats at the start of each lobby's first round.
        -- PVP_MATCH_ACTIVE fires once per round (6 times), so only snapshot when we
        -- are NOT already tracking a lobby (_shuffleLobbyActive == false).
        if event == "PVP_MATCH_ACTIVE" then
            local isSoloShuffle = C_PvP.IsRatedSoloShuffle and C_PvP.IsRatedSoloShuffle()
            if isSoloShuffle and not PVPHUB._shuffleLobbyActive then
                PVPHUB._shuffleLobbyActive        = true
                PVPHUB._shuffleRecordedThisLobby  = false
                PVPHUB._earlyExitScoreInfo        = nil  -- discard any stale early-exit data from prior lobby
                PVPHUB._shufflePreLobbyPlayed = select(12, GetPersonalRatedInfo(7)) or 0
                PVPHUB._shufflePreLobbyWon    = select(13, GetPersonalRatedInfo(7)) or 0
                SavePreLobbySnapshot(GetFullName(), PVPHUB._shufflePreLobbyPlayed, PVPHUB._shufflePreLobbyWon)
            end
        end
    elseif event == "PVP_MATCH_COMPLETE" then
        -- Reset cache readiness immediately.  The server will push fresh stats
        -- via PVP_RATED_STATS_UPDATE; until then, any bracketStats/wlData writes
        -- would contain pre-match numbers.  PVP_RATED_STATS_UPDATE sets
        -- _pvpCacheReady=true again and triggers the authoritative save.
        PVPHUB._pvpCacheReady = false
        -- args[1]=winner, args[2]=duration (from event payload per API docs)
        -- Pass winner directly so TrackMMRChange never needs GetBattlefieldWinner()
        local eventWinner = (args[1] ~= nil and args[1] < 4) and args[1] or 0
        PVPHUB._lastEventWinner = eventWinner  -- persisted for PVP_RATED_STATS_UPDATE retry path
        -- Snapshot bracket + scoreInfo RIGHT NOW while we are still inside the
        -- match instance.  If the player clicks "Leave Match" before the 0.5 s
        -- timer fires, C_PvP.GetActiveMatchBracket() and GetScoreInfoByPlayerGuid
        -- both return nil in the new zone.  The snapshot lets TrackMMRChange
        -- recover the data and still record the match.
        PVPHUB._lastMatchBracket = C_PvP.GetActiveMatchBracket and C_PvP.GetActiveMatchBracket()
        local _snapGUID = UnitGUID("player")
        if _snapGUID then
            local _ok, _si = pcall(C_PvP.GetScoreInfoByPlayerGuid, _snapGUID)
            PVPHUB._pendingMatchScoreInfo    = (_ok and _si) and _si or nil
            -- Store ratingChange separately: the live API re-called at +0.5s can return
            -- stale 0 after the player leaves the arena, causing Guard 2 to wrongly skip
            -- the final shuffle round. The value here (at PVP_MATCH_COMPLETE time) is
            -- authoritative per Blizzard's own UI which reads it with no delay.
            PVPHUB._pendingMatchRatingChange = (_ok and _si) and (_si.ratingChange or 0) or nil
        else
            PVPHUB._pendingMatchScoreInfo    = nil
            PVPHUB._pendingMatchRatingChange = nil
        end
        -- Pre-arm shuffle round tracking BEFORE the async timers fire.
        -- Without this, PVP_RATED_STATS_UPDATE can arrive at ~+0.35s (before
        -- TrackMMRChange's +0.5s) while the flag is still false, causing the
        -- deferred patching block to be skipped entirely.
        if PVPHUB._shuffleLobbyActive then
            PVPHUB._pendingShuffleRoundCompute = true
            PVPHUB._shuffleFreshRounds = nil
        end
        C_Timer.After(0.5, function() TrackMMRChange(0, eventWinner) end)
        -- Ask server for fresh ratings; PVP_RATED_STATS_UPDATE will fire when
        -- the server responds and its handler will do the authoritative save.
        C_Timer.After(0.3, function() RequestRatedInfo() end)
    elseif event == "UI_SCALE_CHANGED" then
        -- Adjust window sizes when UI scale changes to ensure they fit on screen
        C_Timer.After(0.2, function() -- Small delay to ensure UI scale has been applied
            local success, errorMsg = pcall(function()
                if PVPHUB.window then
                    AdjustWindowToScreen(PVPHUB.window)
                end
                if PVPHUB.compactWindow then
                    AdjustWindowToScreen(PVPHUB.compactWindow)
                end
            end)
            if not success then
                print("|cffff0000[PVPHUB Error]|r UI Scale adjustment error: " .. tostring(errorMsg))
            end
        end)
    elseif event == "PVP_RATED_STATS_UPDATE" then
        -- Server confirmed updated ratings.  Only mark cache as ready once we are
        -- past the spec-change stale window (pvp_tracking's handler fires first and
        -- also sets this flag, but we mirror it here for correctness).
        local tooSoon = PVPHUB._specChangeTime and (GetTime() - PVPHUB._specChangeTime) < 1.5
        if not tooSoon then
            PVPHUB._pvpCacheReady = true
        end
        UpdatePvPRatings()
        ThrottledUpdate()
        -- Patch the most recent Shuffle history record with per-lobby round W/L.
        -- We compare current season totals to the snapshot taken at lobby start.
        -- Two timing paths are handled:
        --   A) This event fires BEFORE TrackMMRChange (+0.5s): cache rounds in
        --      _shuffleFreshRounds; TrackMMRChange will consume it when it runs.
        --   B) This event fires AFTER TrackMMRChange: patch hist[#hist] directly.
        if PVPHUB._pendingShuffleRoundCompute then
            PVPHUB._pendingShuffleRoundCompute = false
            local charKey = GetFullName()
            if charKey and PVPHUB_DB and PVPHUB_DB[charKey] then
                local nowPlayed = select(12, GetPersonalRatedInfo(7)) or 0
                local nowWon    = select(13, GetPersonalRatedInfo(7)) or 0
                local preLobbyPlayed, preLobbyWon = GetPreLobbySnapshot(charKey)
                local roundsWon    = math.max(0, nowWon    - (preLobbyWon    or 0))
                local roundsPlayed = math.max(0, nowPlayed - (preLobbyPlayed or 0))
                local roundsLost   = math.max(0, roundsPlayed - roundsWon)
                if roundsPlayed >= 1 and roundsPlayed <= 6 then
                    local hist = PVPHUB_DB[charKey].mmrHistory and PVPHUB_DB[charKey].mmrHistory.ratingShuffle
                    -- Path B: a record for THIS lobby already exists — patch it.
                    -- Guard with a 10-second timestamp window to avoid patching a
                    -- previous match's record when Guard 2 prematurely skipped round 6.
                    local latestIsNew = hist and #hist > 0
                                        and hist[#hist].roundsWon == nil
                                        and hist[#hist].timestamp
                                        and (GetServerTime() - hist[#hist].timestamp) < 10
                    if latestIsNew then
                        hist[#hist].roundsWon  = roundsWon
                        hist[#hist].roundsLost = roundsLost
                        PVPHubPrint("|cff00ff00[PVPHUB]|r Match recorded!")
                        PVPHUB._shuffleLobbyActive = false
                        ClearPreLobbySnapshot(charKey)
                    else
                        -- Path A: TrackMMRChange hasn't created the record yet
                        -- (either it fires later at +0.5s, or Guard 2 skipped it because
                        -- scoreInfo.ratingChange was still 0 when it ran).
                        -- Store the round data and schedule a retry so the record gets created.
                        PVPHUB._shuffleFreshRounds = { won = roundsWon, lost = roundsLost }
                        if PVPHUB._shuffleLobbyActive then
                            C_Timer.After(0.1, function()
                                TrackMMRChange(0, PVPHUB._lastEventWinner)
                            end)
                        end
                    end
                else
                    -- Delta out of range (snapshot mismatch). Clear lobby state
                    -- to avoid blocking the next lobby's snapshot capture.
                    PVPHUB._shuffleLobbyActive = false
                    ClearPreLobbySnapshot(charKey)
                end
            end
        end
    elseif event == "PLAYER_REGEN_DISABLED" then
        -- Player entered combat - mark combat status
        PVPHUB._inCombat = true
    elseif event == "PLAYER_MONEY" then
        -- Gold changed — save immediately without a full throttled update
        local playerName = UnitName("player") or "Unknown"
        local realmName  = GetRealmName() or "Unknown"
        local charKey    = playerName .. "-" .. realmName
        if PVPHUB_DB and PVPHUB_DB[charKey] then
            PVPHUB_DB[charKey].gold = GetMoney() or 0
        end
        -- A deposit/withdrawal also changes Warband Bank's balance; catch it
        -- here too instead of waiting for the next full UpdateAllData.
        local warbandGold = FetchWarbandGold()
        if warbandGold then
            PVPHUB_SETTINGS.warbandGold = warbandGold
        end
    elseif event == "PLAYER_REGEN_ENABLED" then
        -- Player left combat - mark combat status and check for pending window open
        PVPHUB._inCombat = false
        if PVPHUB._pendingWindowOpen then
            PVPHUB._pendingWindowOpen = false
            -- Open the window after combat ends
            C_Timer.After(0.1, function()
                SlashCmdList["PVPHUB"]("")
            end)
        end
    elseif event == "BAG_UPDATE_DELAYED" then
        -- Skip the throttled update when zoning into a PvP instance.
        -- BAG_UPDATE_DELAYED fires on every zone transition, including arena entry.
        -- Without this guard it triggers UpdateAllData() → PVPHUB_RefreshUI() →
        -- UpdateCompactWindow(), which destroys and recreates all compact rows and
        -- causes the visible flash the user sees when loading into arena.
        if not IsInActivePvP() then
            ThrottledUpdate()
        end
    else
        -- Use throttled updates for other events to prevent spam
        ThrottledUpdate()
    end
    end) -- End pcall
    
    -- Handle any errors to prevent taint
    if not success then
        print("|cffff0000[PVPHUB Error]|r Event handler error: " .. tostring(errorMsg))
    end
end)

-- ═══════════════════════════════════════════════════════════════════════════

-- Keybind localization strings
BINDING_NAME_PVPHUB_TOGGLE = "Toggle PVP HUB Window"

-- Global function for keybind to toggle PVPHUB window
function PVPHUB_ToggleMainWindow()
    -- Use the same logic as the slash command to toggle the main window
    SlashCmdList["PVPHUB"]("")
end

-- IMPORTANT: the client's slash-command registration stops at the FIRST GAP
-- in this numbering (SLASH_PVPHUB1, 2, 3, ...) — keep this list contiguous
-- with no skipped numbers, or everything after the gap silently stops working.
SLASH_PVPHUB1  = "/pvphub"
SLASH_PVPHUB2  = "/ph"
SLASH_PVPHUB3  = "/pvphub streamer"
SLASH_PVPHUB4  = "/pvphub compact"
SLASH_PVPHUB5  = "/pvphub resethonor"
SLASH_PVPHUB6  = "/pvphub fix"
SLASH_PVPHUB7  = "/pvphub welcome"
SLASH_PVPHUB8  = "/pvphub resetseason"
SLASH_PVPHUB9  = "/pvphub help"
SLASH_PVPHUB10 = "/pvphub test"
SLASH_PVPHUB11 = "/pvphub cleartest"
SLASH_PVPHUB12 = "/pvphub seasonlabel"
SlashCmdList["PVPHUB"] = function(msg)
    local args = {strsplit(" ", msg or "")}
    local command = args[1] and string.lower(args[1]) or ""

    if command == "compact" or command == "streamer" then
        if PVPHUB_SETTINGS.disableStreamerMode then
            PVPHubPrint("|cffff0000[PVPHUB]|r Streamer Mode is disabled in settings.")
            return
        end
        -- Only update the compact window UI, do not trigger a data refresh
        if PVPHUB.compactWindow and PVPHUB.compactWindow:IsShown() then
            PVPHUB.compactWindow:Hide()
        else
            PVPHUB:CreateCompactWindow()
        end
        return
    elseif command == "resethonor" then
        -- Reset honor warnings for testing
        PVPHUB_SETTINGS.honorWarnings = {}
        PVPHubPrint("|cffff0000[PVPHUB]|r Honor warning flags reset! You can now test the 14k honor notification again.")
        return
    elseif command == "fix" then
        -- Restore window to proper size if it got corrupted
        if PVPHUB.window then
            PVPHUB.window:RestoreSize()
            PVPHubPrint("|cffff0000[PVPHUB]|r Window size restored!")
        else
            PVPHubPrint("|cffff0000[PVPHUB]|r Window is not currently open. Use /pvphub to open it first.")
        end
        return
    elseif command == "welcome" then
        -- Reset and show the welcome window for testing
        PVPHUB_SETTINGS.welcomeShown = false
        if PVPHUB.welcomeWindow then
            PVPHUB.welcomeWindow:Hide()
            PVPHUB.welcomeWindow = nil
        end
        PVPHUB:ShowWelcomePopup()
        return
    elseif command == "update" then
        -- Preview the update popup for testing
        if PVPHUB.updateWindow then
            PVPHUB.updateWindow:Hide()
            PVPHUB.updateWindow = nil
        end
        local ver = C_AddOns.GetAddOnMetadata("PVPHUB", "Version") or "?"
        PVPHUB:ShowUpdatePopup(ver)
        return
    elseif command == "resetseason" then
        -- Reset season maximum data for current character
        local playerName = UnitName("player") or "Unknown"
        local realmName = GetRealmName() or "Unknown"
        local charKey = playerName .. "-" .. realmName
        if PVPHUB_DB[charKey] then
            PVPHUB_DB[charKey].conquestWeeklyData = nil
            PVPHUB_DB[charKey].bloodytokensWeeklyData = nil
            PVPHubPrint("|cffff0000[PVPHUB]|r Season maximum data reset! Next update will recalculate from current values.")
            -- Trigger an immediate update
            if PVPHUB.UpdateCurrencyData then
                PVPHUB.UpdateCurrencyData()
            end
            PVPHUB_RefreshUI()
        else
            PVPHubPrint("|cffff0000[PVPHUB]|r No data found for current character.")
        end
        return
    elseif command == "resetpos" then
        -- Reset window positions to center of screen
        PVPHUB_SETTINGS.compactWindowPos = nil
        PVPHUB_SETTINGS.windowPos = nil
        PVPHubPrint("|cffff0000[PVPHUB]|r Window positions reset! Close and reopen windows to see them centered.")
        -- If compact window is open, reposition it immediately
        if PVPHUB.compactWindow and PVPHUB.compactWindow:IsShown() then
            PVPHUB.compactWindow:ClearAllPoints()
            PVPHUB.compactWindow:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
        end
        -- If main window is open, reposition it immediately
        if PVPHUB.window and PVPHUB.window:IsShown() then
            PVPHUB.window:ClearAllPoints()
            PVPHUB.window:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
        end
        return
    elseif command == "seasonlabel" then
        -- Relabel the currently-active season in the Stats tab, e.g.
        -- "/pvphub seasonlabel Midnight Season 2". Only affects display —
        -- the underlying season-scoped filtering is unaffected.
        local rawSeason = (C_PvP and C_PvP.GetUIDisplaySeason and C_PvP.GetUIDisplaySeason()) or 0
        if rawSeason <= 0 then
            PVPHubPrint("|cffff0000[PVPHUB]|r Could not determine the current season from the API.")
            return
        end
        PVPHUB_SETTINGS.seasonLabels = PVPHUB_SETTINGS.seasonLabels or {}
        local label = #args > 1 and table.concat(args, " ", 2) or nil
        if not label or label == "" then
            PVPHUB_SETTINGS.seasonLabels[rawSeason] = nil
            PVPHubPrint("|cffff0000[PVPHUB]|r Season label cleared — the Season tab will show \"Season " .. rawSeason .. "\".")
        else
            PVPHUB_SETTINGS.seasonLabels[rawSeason] = label
            PVPHubPrint("|cffff0000[PVPHUB]|r Season tab will now show \"" .. label .. "\" for the current season.")
        end
        if PVPHUB.window and PVPHUB.window.statsFrame and PVPHUB.window.RenderStatsFor and PVPHUB.window.currentTab == "stats" then
            PVPHUB.window.RenderStatsFor()
        end
        return
    elseif command == "help" then
        print("|cffff0000[PVPHUB]|r Available commands:")
        print("  |cff00ff00/pvphub|r - Toggle main window")
        print("  |cff00ff00/ph|r - Shorthand for /pvphub")
        print("  |cff00ff00/pvphub compact|r - Toggle compact window")
        print("  |cff00ff00/pvphub toggle|r - Same as /pvphub (for keybind testing)")
        print("  |cff00ff00/pvphub help|r - Show this help")
        print("  |cff00ff00/pvphub fix|r - Restore window size")
        print("  |cff00ff00/pvphub welcome|r - Show the first-install welcome window")
        print("  |cff00ff00/pvphub resetpos|r - Reset window positions to center")
        print("  |cff00ff00/pvphub resethonor|r - Reset honor warnings")
        print("  |cff00ff00/pvphub resetseason|r - Reset season data")
        print("  |cff00ff00/pvphub seasonlabel <name>|r - Rename the current season shown in the Season tab (no name clears it)")
        print("")
        print("|cffff0000[PVPHUB]|r You can also set a custom keybind in:")
        print("  |cffffff00ESC > Options > Keybindings > PVP HUB > Toggle PVP HUB Window|r")
        return
    elseif command == "toggle" then
        -- Explicit toggle command for testing keybinds
        if PVPHUB.window and PVPHUB.window:IsShown() then
            PVPHUB.window:Hide()
        else
            -- Use the main window showing logic below
            command = ""
        end
        if command == "toggle" then return end
    elseif command == "cleartest" then
        local testKeys = {
            "Pikaboo-Stormrage", "Whaazz-Kazzak", "Venruki-Silvermoon",
            "Cdew-Illidan", "Lolflay-Outland", "Stoopzz-Sargeras",
            "Mes-Ravencrest", "Regentlord-Draenor", "Reck-Area52",
            "Kollektiv-TarrenMill", "Hotted-TarrenMill", "Zugzug-Dunemaul",
        }
        for _, k in ipairs(testKeys) do PVPHUB_DB[k] = nil end
        PVPHUB_RefreshUI()
        PVPHubPrint("|cff00ff00[PVPHUB]|r Test data removed.")
        return
    elseif command == "test" then
        -- Inject dummy characters to test every UI feature.
        -- CR (Current Rating) goes in rating fields; bracketStats gates the rating display.
        -- MMR goes in mmrHistory (the authoritative source read by tooltips).
        -- mmrHistory entry fields: postMatchMMR, preMatchMMR, mmrChange, specID, timestamp.
        -- Honor cap ~15000, Conquest cap ~1800, BloodyTokens cap ~3000.
        local ts = GetServerTime()
        local function mh(specID, cr, mmr)
            return { specID=specID, postMatchMMR=mmr, preMatchMMR=mmr-25, mmrChange=25,
                     rating=cr, ratingChange=12, timestamp=ts }
        end
        -- Flat bracketStats entry (2v2, 3v3, RBG)
        local function bs(rating, won, lost)
            return { rating=rating, won=won, lost=lost, played=won+lost, seasonBest=rating+50 }
        end
        -- Per-spec bracketStats entry (Shuffle, Blitz — keyed by specID inside the bracket table)
        local function bss(rating, won, lost)
            return { rating=rating, won=won, lost=lost, played=won+lost, seasonBest=rating+30 }
        end

        -- 1: Pikaboo-Stormrage – Rogue, ~3100 orange (Glad)
        PVPHUB_DB["Pikaboo-Stormrage"] = {
            class="ROGUE", specID=261, lastActiveSpecID=261, displayName="Pikaboo",
            honor=15000, conquest=1800, bloodstones=25, bloodytokens=3000,
            conquestWeeklyData     = { seasonMaximum=1800, cappedThisWeek=true },
            bloodytokensWeeklyData = { seasonMaximum=3000, cappedThisWeek=true },
            rating2v2=3050, rating3v3=3080, ratingRBG=2980,
            ratingShuffle = { [261]=3124, [259]=3010 },
            ratingBlitz   = { [261]=3060 },
            bracketStats = {
                rating2v2     = bs(3050, 124, 68),
                rating3v3     = bs(3080, 130, 71),
                ratingRBG     = bs(2980, 110, 62),
                ratingShuffle = { [261]=bss(3124, 210, 118), [259]=bss(3010, 198, 112) },
                ratingBlitz   = { [261]=bss(3060, 145, 82) },
            },
            mmrHistory = {
                rating2v2     = { mh(261, 3050, 3120) },
                rating3v3     = { mh(261, 3080, 3150) },
                ratingRBG     = { mh(261, 2980, 3050) },
                ratingShuffle = { mh(259, 3010, 3080), mh(261, 3124, 3190) },
                ratingBlitz   = { mh(261, 3060, 3130) },
            },
            -- Gladiator: early progress (red band, <25%)
            titleProgress = {
                gladiator = { achievementID=62930, bracketKey="rating3v3", current=6, required=50, completed=false, lastUpdated=ts },
            },
        }

        -- 2: Cdew-Illidan – Shaman, ~2800 orange
        PVPHUB_DB["Cdew-Illidan"] = {
            class="SHAMAN", specID=264, lastActiveSpecID=264, displayName="Cdew",
            honor=15000, conquest=1800, bloodstones=21, bloodytokens=2960,
            conquestWeeklyData     = { seasonMaximum=1800, cappedThisWeek=true },
            bloodytokensWeeklyData = { seasonMaximum=2960, cappedThisWeek=false },
            rating2v2=2780, rating3v3=2820, ratingRBG=2750,
            ratingShuffle = { [264]=2860, [262]=2720 },
            ratingBlitz   = { [264]=2800 },
            bracketStats = {
                rating2v2     = bs(2780, 98, 58),
                rating3v3     = bs(2820, 104, 61),
                ratingRBG     = bs(2750, 92, 55),
                ratingShuffle = { [264]=bss(2860, 178, 98), [262]=bss(2720, 155, 92) },
                ratingBlitz   = { [264]=bss(2800, 112, 65) },
            },
            mmrHistory = {
                rating2v2     = { mh(264, 2780, 2850) },
                rating3v3     = { mh(264, 2820, 2890) },
                ratingRBG     = { mh(264, 2750, 2820) },
                ratingShuffle = { mh(262, 2720, 2790), mh(264, 2860, 2930) },
                ratingBlitz   = { mh(264, 2800, 2870) },
            },
            -- Legend: earned (gold "Earned!" state, with a win date)
            titleProgress = {
                legend = { achievementID=62932, bracketKey="ratingShuffle", current=100, required=100, completed=true,
                           earnedMonth=5, earnedDay=29, earnedYear=26, lastUpdated=ts },
            },
        }

        -- 3: Whaazz-Kazzak – Paladin, ~2500 orange
        PVPHUB_DB["Whaazz-Kazzak"] = {
            class="PALADIN", specID=65, lastActiveSpecID=65, displayName="Whaazz",
            honor=15000, conquest=1800, bloodstones=22, bloodytokens=2900,
            conquestWeeklyData     = { seasonMaximum=1800, cappedThisWeek=true },
            bloodytokensWeeklyData = { seasonMaximum=2900, cappedThisWeek=false },
            rating2v2=2460, rating3v3=2510, ratingRBG=2480,
            ratingShuffle = { [65]=2540, [70]=2420 },
            ratingBlitz   = { [65]=2500 },
            bracketStats = {
                rating2v2     = bs(2460, 78, 50),
                rating3v3     = bs(2510, 84, 53),
                ratingRBG     = bs(2480, 80, 51),
                ratingShuffle = { [65]=bss(2540, 148, 88), [70]=bss(2420, 128, 82) },
                ratingBlitz   = { [65]=bss(2500, 92, 60) },
            },
            mmrHistory = {
                rating2v2     = { mh(65, 2460, 2530) },
                rating3v3     = { mh(65, 2510, 2580) },
                ratingRBG     = { mh(65, 2480, 2550) },
                ratingShuffle = { mh(70, 2420, 2490), mh(65, 2540, 2610) },
                ratingBlitz   = { mh(65, 2500, 2570) },
            },
            -- Strategist: near-complete (green band, >=75%)
            titleProgress = {
                strategist = { achievementID=62950, bracketKey="ratingBlitz", current=20, required=25, completed=false, lastUpdated=ts },
            },
        }

        -- 4: Stoopzz-Sargeras – Evoker, ~2350 orange (low end)
        PVPHUB_DB["Stoopzz-Sargeras"] = {
            class="EVOKER", specID=1468, lastActiveSpecID=1468, displayName="Stoopzz",
            honor=14200, conquest=1750, bloodstones=19, bloodytokens=2780,
            conquestWeeklyData     = { seasonMaximum=1750, cappedThisWeek=false },
            bloodytokensWeeklyData = { seasonMaximum=2780, cappedThisWeek=false },
            rating2v2=2320, rating3v3=2380, ratingRBG=2340,
            ratingShuffle = { [1468]=2410, [1467]=2300 },
            ratingBlitz   = { [1468]=2350 },
            bracketStats = {
                rating2v2     = bs(2320, 68, 46),
                rating3v3     = bs(2380, 74, 49),
                ratingRBG     = bs(2340, 70, 47),
                ratingShuffle = { [1468]=bss(2410, 118, 76), [1467]=bss(2300, 105, 72) },
                ratingBlitz   = { [1468]=bss(2350, 82, 54) },
            },
            mmrHistory = {
                rating2v2     = { mh(1468, 2320, 2390) },
                rating3v3     = { mh(1468, 2380, 2450) },
                ratingRBG     = { mh(1468, 2340, 2410) },
                ratingShuffle = { mh(1467, 2300, 2370), mh(1468, 2410, 2480) },
                ratingBlitz   = { mh(1468, 2350, 2420) },
            },
        }

        -- 5: Venruki-Silvermoon – Mage, ~2200 purple
        PVPHUB_DB["Venruki-Silvermoon"] = {
            class="MAGE", specID=64, lastActiveSpecID=64, displayName="Venruki",
            honor=13800, conquest=1670, bloodstones=18, bloodytokens=2550,
            conquestWeeklyData     = { seasonMaximum=1670, cappedThisWeek=false },
            bloodytokensWeeklyData = { seasonMaximum=2550, cappedThisWeek=false },
            rating2v2=2150, rating3v3=2210,
            ratingShuffle = { [64]=2240, [63]=2180 },
            ratingBlitz   = { [64]=2200, [63]=2160 },
            bracketStats = {
                rating2v2     = bs(2150, 58, 44),
                rating3v3     = bs(2210, 64, 47),
                ratingShuffle = { [64]=bss(2240, 105, 78), [63]=bss(2180, 98, 74) },
                ratingBlitz   = { [64]=bss(2200, 80, 60), [63]=bss(2160, 75, 58) },
            },
            mmrHistory = {
                rating2v2     = { mh(64, 2150, 2220) },
                rating3v3     = { mh(64, 2210, 2280) },
                ratingShuffle = { mh(63, 2180, 2250), mh(64, 2240, 2310) },
                ratingBlitz   = { mh(63, 2160, 2230), mh(64, 2200, 2270) },
            },
        }

        -- 6: Lolflay-Outland – Warlock, ~2100 purple (low end)
        PVPHUB_DB["Lolflay-Outland"] = {
            class="WARLOCK", specID=267, lastActiveSpecID=267, displayName="Lolflay",
            honor=11500, conquest=1380, bloodstones=15, bloodytokens=2150,
            conquestWeeklyData     = { seasonMaximum=1380, cappedThisWeek=false },
            bloodytokensWeeklyData = { seasonMaximum=2150, cappedThisWeek=false },
            rating2v2=2080, rating3v3=2120,
            ratingShuffle = { [267]=2140, [265]=2100 },
            ratingBlitz   = { [267]=2110 },
            bracketStats = {
                rating2v2     = bs(2080, 52, 42),
                rating3v3     = bs(2120, 58, 45),
                ratingShuffle = { [267]=bss(2140, 95, 72), [265]=bss(2100, 88, 70) },
                ratingBlitz   = { [267]=bss(2110, 72, 56) },
            },
            mmrHistory = {
                rating2v2     = { mh(267, 2080, 2150) },
                rating3v3     = { mh(267, 2120, 2190) },
                ratingShuffle = { mh(265, 2100, 2170), mh(267, 2140, 2210) },
                ratingBlitz   = { mh(267, 2110, 2180) },
            },
        }

        -- 7: Mes-Ravencrest – Demon Hunter, ~2000 blue
        PVPHUB_DB["Mes-Ravencrest"] = {
            class="DEMONHUNTER", specID=577, lastActiveSpecID=577, displayName="Mes",
            honor=9200, conquest=1140, bloodstones=11, bloodytokens=1700,
            conquestWeeklyData     = { seasonMaximum=1140, cappedThisWeek=false },
            bloodytokensWeeklyData = { seasonMaximum=1700, cappedThisWeek=false },
            rating2v2=1970, rating3v3=2010,
            ratingShuffle = { [577]=2030 },
            ratingBlitz   = { [577]=1990 },
            bracketStats = {
                rating2v2     = bs(1970, 46, 38),
                rating3v3     = bs(2010, 50, 40),
                ratingShuffle = { [577]=bss(2030, 82, 64) },
                ratingBlitz   = { [577]=bss(1990, 68, 55) },
            },
            mmrHistory = {
                rating2v2     = { mh(577, 1970, 2040) },
                rating3v3     = { mh(577, 2010, 2080) },
                ratingShuffle = { mh(577, 2030, 2100) },
                ratingBlitz   = { mh(577, 1990, 2060) },
            },
        }

        -- 8: Regentlord-Draenor – Death Knight, ~1950 blue (low end)
        PVPHUB_DB["Regentlord-Draenor"] = {
            class="DEATHKNIGHT", specID=252, lastActiveSpecID=252, displayName="Regentlord",
            honor=6800, conquest=740, bloodstones=7, bloodytokens=1050,
            conquestWeeklyData     = { seasonMaximum=740,  cappedThisWeek=false },
            bloodytokensWeeklyData = { seasonMaximum=1050, cappedThisWeek=false },
            rating2v2=1950, rating3v3=1970,
            ratingShuffle = { [252]=1960, [251]=1950 },
            ratingBlitz   = { [252]=1955 },
            bracketStats = {
                rating2v2     = bs(1950, 42, 36),
                rating3v3     = bs(1970, 44, 37),
                ratingShuffle = { [252]=bss(1960, 72, 58), [251]=bss(1950, 68, 56) },
                ratingBlitz   = { [252]=bss(1955, 50, 42) },
            },
            mmrHistory = {
                rating2v2     = { mh(252, 1950, 2020) },
                rating3v3     = { mh(252, 1970, 2040) },
                ratingShuffle = { mh(251, 1950, 2020), mh(252, 1960, 2030) },
                ratingBlitz   = { mh(252, 1955, 2025) },
            },
        }

        -- 9: Reck-Area52 – Monk, ~1880 green
        PVPHUB_DB["Reck-Area52"] = {
            class="MONK", specID=269, lastActiveSpecID=269, displayName="Reck",
            honor=5600, conquest=590, bloodstones=5, bloodytokens=870,
            conquestWeeklyData     = { seasonMaximum=590, cappedThisWeek=false },
            bloodytokensWeeklyData = { seasonMaximum=870, cappedThisWeek=false },
            rating2v2=1860, rating3v3=1890,
            ratingShuffle = { [269]=1910, [270]=1870 },
            ratingBlitz   = { [269]=1880 },
            bracketStats = {
                rating2v2     = bs(1860, 38, 33),
                rating3v3     = bs(1890, 40, 35),
                ratingShuffle = { [269]=bss(1910, 62, 54), [270]=bss(1870, 56, 50) },
                ratingBlitz   = { [269]=bss(1880, 44, 38) },
            },
            mmrHistory = {
                rating2v2     = { mh(269, 1860, 1930) },
                rating3v3     = { mh(269, 1890, 1960) },
                ratingShuffle = { mh(270, 1870, 1940), mh(269, 1910, 1980) },
                ratingBlitz   = { mh(269, 1880, 1950) },
            },
        }

        -- 10: Kollektiv-TarrenMill – Priest, ~1820 green (low end)
        PVPHUB_DB["Kollektiv-TarrenMill"] = {
            class="PRIEST", specID=257, lastActiveSpecID=257, displayName="Kollektiv",
            honor=7100, conquest=820, bloodstones=7, bloodytokens=1200,
            conquestWeeklyData     = { seasonMaximum=820, cappedThisWeek=false },
            bloodytokensWeeklyData = { seasonMaximum=1200, cappedThisWeek=false },
            rating2v2=1810, rating3v3=1830,
            ratingShuffle = { [257]=1840, [258]=1820 },
            ratingBlitz   = { [257]=1825 },
            bracketStats = {
                rating2v2     = bs(1810, 34, 30),
                rating3v3     = bs(1830, 36, 31),
                ratingShuffle = { [257]=bss(1840, 58, 50), [258]=bss(1820, 54, 48) },
                ratingBlitz   = { [257]=bss(1825, 40, 35) },
            },
            mmrHistory = {
                rating2v2     = { mh(257, 1810, 1880) },
                rating3v3     = { mh(257, 1830, 1900) },
                ratingShuffle = { mh(258, 1820, 1890), mh(257, 1840, 1910) },
                ratingBlitz   = { mh(257, 1825, 1895) },
            },
        }

        -- 11: Hotted-TarrenMill – Warrior, ~1650 white, note attached
        PVPHUB_DB["Hotted-TarrenMill"] = {
            class="WARRIOR", specID=71, lastActiveSpecID=71, displayName="Hotted",
            honor=3200, conquest=310, bloodstones=3, bloodytokens=420,
            conquestWeeklyData     = { seasonMaximum=310, cappedThisWeek=false },
            bloodytokensWeeklyData = { seasonMaximum=420, cappedThisWeek=false },
            rating2v2=1640, rating3v3=1660,
            ratingShuffle = { [71]=1670, [72]=1650 },
            ratingBlitz   = { [71]=1645 },
            note = "Climbing back up – taking it slow this season!",
            bracketStats = {
                rating2v2     = bs(1640, 26, 27),
                rating3v3     = bs(1660, 28, 26),
                ratingShuffle = { [71]=bss(1670, 44, 42), [72]=bss(1650, 40, 40) },
                ratingBlitz   = { [71]=bss(1645, 30, 29) },
            },
            mmrHistory = {
                rating2v2     = { mh(71, 1640, 1700) },
                rating3v3     = { mh(71, 1660, 1720) },
                ratingShuffle = { mh(72, 1650, 1710), mh(71, 1670, 1730) },
                ratingBlitz   = { mh(71, 1645, 1705) },
            },
        }

        -- 12: Zugzug-Dunemaul – Hunter, ~1300 white (fresh), note attached
        PVPHUB_DB["Zugzug-Dunemaul"] = {
            class="HUNTER", specID=253, lastActiveSpecID=253, displayName="Zugzug",
            honor=650, conquest=0, bloodstones=0, bloodytokens=80,
            conquestWeeklyData     = { seasonMaximum=0,  cappedThisWeek=false },
            bloodytokensWeeklyData = { seasonMaximum=80, cappedThisWeek=false },
            rating2v2=1280, rating3v3=0,
            ratingShuffle = { [253]=1320 },
            ratingBlitz   = {},
            note = "Fresh alt, just starting PvP – wish me luck :)",
            bracketStats = {
                rating2v2     = bs(1280, 8, 14),
                ratingShuffle = { [253]=bss(1320, 10, 16) },
            },
            mmrHistory = {
                rating2v2     = { mh(253, 1280, 1330) },
                ratingShuffle = { mh(253, 1320, 1370) },
            },
        }

        PVPHUB_RefreshUI()
        PVPHubPrint("|cff00ff00[PVPHUB]|r Test data injected (12 characters). Use |cffffd100/pvphub cleartest|r to remove them.")
        return
    end

    -- Check if player is in combat before opening window
    if InCombatLockdown() then
        -- If window is already open and visible, allow closing it
        if PVPHUB.window and PVPHUB.window:IsShown() then
            PVPHUB.window:Hide()
            return
        end
        -- If trying to open during combat, set pending flag and notify player
        PVPHUB._pendingWindowOpen = true
        PVPHubPrint("|cffff0000[PVPHUB]|r PVPHUB will load after dropping combat")
        return
    end

    if PVPHUB.window and PVPHUB.window:IsShown() then
        PVPHUB.window:Hide()
        return
    end

    -- If window exists but is hidden, show it instantly with cached content then refresh
    if PVPHUB.window then
        PVPHUB.window:Show()
        if PVPHUB.Themes then PVPHUB.Themes:UpdateWindow(PVPHUB.window) end
        if PVPHUB.window.StartFadeInAnimation then
            PVPHUB.window.StartFadeInAnimation()
        end
        UpdateAllData()
        return
    end

    -- First open: load data then create the window below
    UpdateAllData()

    if not PVPHUB.window then
        -- Create window frame
        local f = CreateFrame("Frame", "PVPHUBWindow", UIParent)

        -- Rounded border ring (2 px larger on all sides, drawn behind background)
        local borderTex = f:CreateTexture(nil, "BACKGROUND", nil, -2)
        borderTex:SetColorTexture(1, 1, 1, 1)
        borderTex:SetPoint("TOPLEFT",     f, "TOPLEFT",     -7,  7)
        borderTex:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT",  7, -7)
        local borderMask = f:CreateMaskTexture()
        borderMask:SetTexture("Interface\\AddOns\\PVPHUB\\media\\rounded_mask",
            "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
        borderMask:SetPoint("TOPLEFT",     f, "TOPLEFT",     -7,  7)
        borderMask:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT",  7, -7)
        borderTex:AddMaskTexture(borderMask)
        f.borderTex  = borderTex
        f.borderMask = borderMask

        -- Rounded background
        local bgTex = f:CreateTexture(nil, "BACKGROUND", nil, -1)
        bgTex:SetColorTexture(1, 1, 1, 1)
        bgTex:SetAllPoints()
        local bgMask = f:CreateMaskTexture()
        bgMask:SetTexture("Interface\\AddOns\\PVPHUB\\media\\rounded_mask",
            "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
        bgMask:SetAllPoints()
        bgTex:AddMaskTexture(bgMask)
        f.bgTex  = bgTex
        f.bgMask = bgMask

        function f:ApplyFrameStyle()
            local rounded = PVPHUB_SETTINGS.mainWindow and PVPHUB_SETTINGS.mainWindow.roundedFrame
            if rounded == nil then rounded = true end
            if rounded then
                self.bgTex:AddMaskTexture(self.bgMask)
                self.borderTex:AddMaskTexture(self.borderMask)
            else
                self.bgTex:RemoveMaskTexture(self.bgMask)
                self.borderTex:RemoveMaskTexture(self.borderMask)
            end
        end

        -- Ensure theme is applied to match current theme colors
        ApplyTheme()
        f:ApplyFrameStyle()

        -- Initialize window opacity setting
        PVPHUB_SETTINGS.windowOpacity = PVPHUB_SETTINGS.windowOpacity or 0.95

        local bgColor = UI_CONSTANTS.COLORS.WINDOW_BG
        local opacity = PVPHUB_SETTINGS.windowOpacity or 0.95
        ApplyWindowBGColor(f, bgColor[4] * opacity)
        local b = UI_CONSTANTS.COLORS.WINDOW_BORDER
        f.borderTex:SetVertexColor(b[1], b[2], b[3], (b[4] or 1) * 0.3)

        f:SetFrameStrata("HIGH")
        
        -- Calculate optimal window size based on screen resolution
        local optimalWidth, optimalHeight = CalculateOptimalWindowSize()
        
        -- Set initial size (height from saved settings, width calculated dynamically from columns)
        if PVPHUB_SETTINGS.windowSize then
            local savedHeight = PVPHUB_SETTINGS.windowSize.height
            local screenHeight = UIParent:GetHeight()
            
            -- Always use optimal width calculated from columns, ignore saved width
            f:SetWidth(optimalWidth)
            
            -- Use saved height if available and within bounds
            if savedHeight then
                local maxAllowedHeight = screenHeight * 0.85
                f:SetHeight(math.min(savedHeight, maxAllowedHeight))
            else
                f:SetHeight(optimalHeight)
            end
        else
            f:SetWidth(optimalWidth)
            f:SetHeight(optimalHeight)
        end
        f:SetPoint("CENTER")
        
        -- Add smooth fade-in animation for backdrop only (not affecting child elements)
        -- This function will be called every time the window is shown
        local function StartFadeInAnimation()
            local bgColor = UI_CONSTANTS.COLORS.WINDOW_BG
            ApplyWindowBGColor(f, 0)

            local animationTimer = 0
            local animationDuration = 0.3
            local startAlpha = 0
            local targetAlpha = PVPHUB_SETTINGS.windowOpacity or bgColor[4] or 0.95

            if not f.fadeInFrame then
                f.fadeInFrame = CreateFrame("Frame")
            end

            f.fadeInFrame:SetScript("OnUpdate", function(self, elapsed)
                animationTimer = animationTimer + elapsed
                local progress = math.min(animationTimer / animationDuration, 1)
                progress = 1 - (1 - progress)^3
                local currentAlpha = startAlpha + (targetAlpha - startAlpha) * progress
                ApplyWindowBGColor(f, currentAlpha)
                if progress >= 1 then
                    self:SetScript("OnUpdate", nil)
                    ApplyWindowBGColor(f, targetAlpha)
                end
            end)

            C_Timer.After(animationDuration + 0.1, function()
                if f and f.bgTex then
                    ApplyWindowBGColor(f, PVPHUB_SETTINGS.windowOpacity)
                end
            end)
        end
        
        -- Store the animation function for reuse
        f.StartFadeInAnimation = StartFadeInAnimation
        
        -- Hide the window initially to prevent flicker
        f:Hide()
        
        -- Start the initial fade-in animation after a brief delay
        C_Timer.After(0.05, function()
            if f and f.StartFadeInAnimation then
                f:Show() -- Show the window right before starting animation
                f.StartFadeInAnimation()
            end
        end)
        
        -- Multi-layer soft glow: each layer sits further behind and more transparent
        local glowLayers = {}
        local glowOffsets = { {2, 0.25}, {4, 0.14}, {7, 0.07}, {10, 0.03} }
        local gc = UI_CONSTANTS.COLORS.WINDOW_GLOW
        local baseOpacity = PVPHUB_SETTINGS.windowOpacity or 0.95
        for i, cfg in ipairs(glowOffsets) do
            local off, alpha = cfg[1], cfg[2]
            local layer = CreateFrame("Frame", nil, f)
            layer:SetPoint("TOPLEFT",     f, "TOPLEFT",     -off,  off)
            layer:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT",  off, -off)
            layer:SetFrameLevel(f:GetFrameLevel() - 1)
            local tex = layer:CreateTexture(nil, "BACKGROUND", nil, -i)
            tex:SetColorTexture(1, 1, 1, 1)
            tex:SetAllPoints()
            local mask = layer:CreateMaskTexture()
            mask:SetTexture("Interface\\AddOns\\PVPHUB\\media\\rounded_mask",
                "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
            mask:SetAllPoints()
            tex:AddMaskTexture(mask)
            tex:SetVertexColor(gc[1], gc[2], gc[3], alpha * baseOpacity)
            glowLayers[i] = tex
        end
        f.glowFrame  = glowLayers[1] -- kept for compat
        f.glowLayers = glowLayers
        ApplyWindowGlowVisibility(f)

        -- Blizzard close button, desaturated + recolored to silver
        local closeButton = CreateFrame("Button", nil, f, "UIPanelCloseButton")
        closeButton:SetSize(26, 26)
        -- y=-14 to align with dropdown menus
        closeButton:SetPoint("TOPRIGHT", f, "TOPRIGHT", -18, -14)
        closeButton:SetFrameLevel(f:GetFrameLevel() + 5)
        -- Desaturate to strip baked-in red, then apply silver
        local _nt = closeButton:GetNormalTexture()
        local _pt = closeButton:GetPushedTexture()
        local _ht = closeButton:GetHighlightTexture()
        _nt:SetDesaturated(true)
        _pt:SetDesaturated(true)
        _ht:SetDesaturated(true)
        _nt:SetVertexColor(0.82, 0.82, 0.88, 1)
        _pt:SetVertexColor(0.55, 0.55, 0.60, 1)
        _ht:SetVertexColor(1, 1, 1, 1)
        closeButton.normalTex    = _nt
        closeButton.pushedTex    = _pt
        closeButton.highlightTex = _ht
        closeButton:SetScript("OnClick", function() f:Hide() end)
        f.closeButton = closeButton

        -- Create scroll frame with modern TWW styling
        local scrollFrame = CreateFrame("ScrollFrame", "PVPHUBScrollFrame", f, "ScrollFrameTemplate")
        scrollFrame:SetPoint("TOPLEFT", f, "TOPLEFT", 20, -120) -- Align better with headers at -92 + header height (~28px)
        scrollFrame:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -45, 60) -- Reduced bottom margin from 85 to 60 to close gap
        
        -- Apply modern TWW scrollbar styling immediately after creation.
        -- Anchored relative to the window frame itself (not this scrollFrame)
        -- so its position/length exactly matches the Settings and Season
        -- tabs' bars, which use the same PVPHUB_SCROLLBAR_NUDGE.
        ApplyModernScrollbarStyling(scrollFrame, UI_CONSTANTS.COLORS, PVPHUB_SCROLLBAR_NUDGE(f))

        -- Create content frame inside scroll frame
        local contentFrame = CreateFrame("Frame", "PVPHUBContentFrame", scrollFrame)
        contentFrame:SetSize(UI_CONSTANTS.CONTENT_WIDTH, 1)
        scrollFrame:SetScrollChild(contentFrame)

        f.scrollFrame = scrollFrame
        f.contentFrame = contentFrame

        -- Initialize variables
        -- Use saved sortKey from settings, default to "highestRating"
        PVPHUB_SETTINGS.sortKey = PVPHUB_SETTINGS.sortKey or "highestRating"
        PVPHUB.sortKey = PVPHUB_SETTINGS.sortKey
        -- Use saved window scale or default to 1.0
        PVPHUB_SETTINGS.windowScale = PVPHUB_SETTINGS.windowScale or 1.0
        f.currentScale = PVPHUB_SETTINGS.windowScale
        f.scaleButtons = {}
        f.headers = {}
        f.rows = {}
        f.rowBackgrounds = {}

        -- Window is now fixed size - no resizing functionality
        f:SetResizable(false)
        
        -- Function to restore window to proper size if it gets corrupted
        f.RestoreSize = function(self)
            local width = PVPHUB_SETTINGS.windowSize and PVPHUB_SETTINGS.windowSize.width or UI_CONSTANTS.WINDOW_WIDTH
            local height = PVPHUB_SETTINGS.windowSize and PVPHUB_SETTINGS.windowSize.height or UI_CONSTANTS.WINDOW_HEIGHT
            -- Ensure both dimensions are within bounds
            width = math.max(600, math.min(1600, width))
            height = math.max(400, math.min(1200, height))  -- Minimum matches settings baseline
            self:SetSize(width, height)
            if self.UpdateContent then self:UpdateContent() end
            if self.UpdateGreetingLayout then self:UpdateGreetingLayout() end
        end
        
        f:SetMovable(true)
        f:EnableMouse(true)
        f:RegisterForDrag("LeftButton")
        f:SetClampedToScreen(true)
        f:SetScript("OnDragStart", function(self)
            self:StartMoving()
        end)
        f:SetScript("OnDragStop", function(self)
            self:StopMovingOrSizing()
            if not PVPHUB_SETTINGS.windowPos then PVPHUB_SETTINGS.windowPos = {} end
            local point, relativeTo, relativePoint, xOfs, yOfs = self:GetPoint()
            PVPHUB_SETTINGS.windowPos = {point=point, relativePoint=relativePoint, x=xOfs, y=yOfs}
        end)
        -- Restore position if saved
        if PVPHUB_SETTINGS.windowPos then
            local pos = PVPHUB_SETTINGS.windowPos
            f:ClearAllPoints()
            f:SetPoint(pos.point or "CENTER", UIParent, pos.relativePoint or "CENTER", pos.x or 0, pos.y or 0)
        end

        -- Modern title with gradient effect
        -- Deliberately NOT RegisterTrackedFont'd — this is the addon's own
        -- brand mark, so it's hardcoded to the bundled Prototype font and
        -- stays put regardless of the user's Appearance font selection.
        f.title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
        f.title:SetPoint("TOPLEFT", f, "TOPLEFT", 45, -15) -- Moved right to make room for logo
        f.title:SetText("PVP HUB")
        SafeSetFont(f.title, "Interface\\AddOns\\PVPHUB\\media\\fonts\\Prototype.ttf", 22, "OUTLINE")
        f.title:SetTextColor(unpack(UI_CONSTANTS.COLORS.TITLE_COLOR))
        
        -- PVPHUB logo next to title
        f.logo = f:CreateTexture(nil, "OVERLAY")
        f.logo:SetTexture("Interface\\AddOns\\PVPHUB\\media\\PVPHUB.png")
        f.logo:SetSize(24, 24) -- Adjust size to match title height
        f.logo:SetPoint("TOPLEFT", f, "TOPLEFT", 15, -12) -- Positioned just to the left of title
        
        -- Initialize current tab (always default to "characters" when opening PVPHUB)
        f.currentTab = "characters"
        
        -- Create tab system similar to World Map
        f.tabs = {}
        local tabData = {
            {
                id = "characters",
                name = "Characters",
                tooltip = "Character PvP Data",
                icon = "Interface\\Icons\\INV_Scroll_11"  -- Better icon for character data/stats
            },
            {
                id = "stats",
                name = "Season",
                tooltip = "Season PvP Statistics",
                icon = "Interface\\Icons\\INV_Misc_Book_09"
            },
            {
                id = "settings",
                name = "Settings",
                tooltip = "Addon Settings & Configuration",
                icon = "Interface\\Icons\\trade_engineering"
            }
        }
        
        -- Real Blizzard tab art (TabSystemTemplate/PanelTabButtonTemplate),
        -- recolored the same way f.closeButton is above: SetDesaturated(true)
        -- to strip the baked-in tan/stone hue, THEN SetVertexColor to tint —
        -- not vertex-color alone, which just muddies with the existing color
        -- (that's why an earlier attempt at this looked like an unrelated
        -- brown/blue smear instead of a clean theme color). Flush against
        -- the window's bottom edge (0 vertical offset — no gap).
        local tabSystem = CreateFrame("Frame", nil, f, "TabSystemTemplate")
        tabSystem:SetPoint("TOPLEFT", f, "BOTTOMLEFT", 28, 0)
        tabSystem:SetTabSelectedCallback(function() end) -- Required callback
        f.tabSystem = tabSystem

        -- Function to switch tabs (defined before tab creation)
        local function SwitchTab(tabId)
            f.currentTab = tabId
            -- Don't save tab state - always default to "characters" on reopen
            -- PVPHUB_SETTINGS.currentTab = tabId  -- Removed to prevent saving tab state

            -- Show/hide content based on active tab
            if tabId == "characters" then
                -- Show characters content
                if f.scrollFrame then f.scrollFrame:Show() end
                if f.greeting then
                    if PVPHUB_SETTINGS.mainWindow and PVPHUB_SETTINGS.mainWindow.hideWelcomeMessage then
                        f.greeting:Hide()
                        if f.titleLine then f.titleLine:Hide() end
                    else
                        f.greeting:Show()
                    end
                end
                if f.titleLine then
                    if PVPHUB_SETTINGS.mainWindow and PVPHUB_SETTINGS.mainWindow.hideWelcomeMessage then
                        f.titleLine:Hide()
                    else
                        f.titleLine:Show()
                    end
                end
                -- Show/hide manage groups button based on grouping enabled state
                if f.manageGroupsBtn then
                    if PVPHUB_SETTINGS.characterGroups and PVPHUB_SETTINGS.characterGroups.enabled then
                        f.manageGroupsBtn:Show()
                    else
                        f.manageGroupsBtn:Hide()
                    end
                end
                
                -- Hide settings/stats content
                if f.settingsFrame then f.settingsFrame:Hide() end
                if f.statsFrame then f.statsFrame:Hide() end
                if f.UpdateContent then f:UpdateContent() end
                -- Headers use PVPHUBDataFont template — no SetFont override needed.

                -- Sort/Show-Hide only apply to the character list, so they're
                -- hidden on the other tabs (see below) and restored here.
                if _G["PVPHUBSortDropdown"]   then _G["PVPHUBSortDropdown"]:Show()   end
                if _G["PVPHUBColumnDropdown"] then _G["PVPHUBColumnDropdown"]:Show() end
            elseif tabId == "stats" then
                -- Hide characters content
                if f.scrollFrame then f.scrollFrame:Hide() end
                if f.greeting then f.greeting:Hide() end
                if f.titleLine then f.titleLine:Hide() end
                if f.manageGroupsBtn then f.manageGroupsBtn:Hide() end
                if f.headers then
                    for _, header in ipairs(f.headers) do
                        if header then header:Hide() end
                    end
                end
                -- Extra safety sweep: hides ANY widget tagged _pvpHeaderWidget
                -- (set on every header/underline/hover-highlight/hoverBtn in
                -- UpdateContent), regardless of whether it's correctly
                -- present in f.headers — a defensive net against a header
                -- widget from a stale render lingering visible across tabs.
                for _, region in ipairs({ f:GetRegions() }) do
                    if region._pvpHeaderWidget then region:Hide() end
                end
                for _, child in ipairs({ f:GetChildren() }) do
                    if child._pvpHeaderWidget then child:Hide() end
                end
                -- Also clear any in-flight column drag state/ghost — leaving
                -- the tab mid-drag shouldn't leave a floating ghost tile
                -- behind on other tabs.
                PVPHUB._draggingColumnKey = nil
                PVPHUB._dropTargetColumnKey = nil
                if PVPHUB._columnDragGhost then PVPHUB._columnDragGhost:Hide() end
                -- Sort/Show-Hide control the character list, which isn't
                -- shown on the Season tab — hide them so they don't sit there
                -- doing nothing.
                if _G["PVPHUBSortDropdown"]   then _G["PVPHUBSortDropdown"]:Hide()   end
                if _G["PVPHUBColumnDropdown"] then _G["PVPHUBColumnDropdown"]:Hide() end
                -- Hide settings content
                if f.settingsFrame then f.settingsFrame:Hide() end

                -- Show stats content, building it lazily on first visit
                if not f.statsFrame then
                    f:CreateStatsFrame()
                end
                if f.statsFrame then
                    f.statsFrame:Show()
                    -- Re-render on every visit so ratings that changed while the
                    -- tab was closed (a match finished, an alt logged in) show up.
                    if f.RenderStatsFor then
                        f.RenderStatsFor()
                    end
                end
            elseif tabId == "settings" then
                -- Hide characters content
                if f.scrollFrame then f.scrollFrame:Hide() end
                if f.greeting then f.greeting:Hide() end
                if f.titleLine then f.titleLine:Hide() end
                if f.manageGroupsBtn then f.manageGroupsBtn:Hide() end
                -- Hide headers for settings view
                if f.headers then
                    for _, header in ipairs(f.headers) do
                        if header then header:Hide() end
                    end
                end
                -- Same defensive sweep + drag-state reset as the Season tab
                -- branch above.
                for _, region in ipairs({ f:GetRegions() }) do
                    if region._pvpHeaderWidget then region:Hide() end
                end
                for _, child in ipairs({ f:GetChildren() }) do
                    if child._pvpHeaderWidget then child:Hide() end
                end
                PVPHUB._draggingColumnKey = nil
                PVPHUB._dropTargetColumnKey = nil
                if PVPHUB._columnDragGhost then PVPHUB._columnDragGhost:Hide() end
                -- Same as the Season tab — nothing here for Sort/Show-Hide to
                -- act on, so keep them out of the way.
                if _G["PVPHUBSortDropdown"]   then _G["PVPHUBSortDropdown"]:Hide()   end
                if _G["PVPHUBColumnDropdown"] then _G["PVPHUBColumnDropdown"]:Hide() end
                -- Hide stats content
                if f.statsFrame then f.statsFrame:Hide() end
                -- Show settings content
                if not f.settingsFrame then
                    f:CreateSettingsFrame()
                end
                if f.settingsFrame then
                    f.settingsFrame:Show()
                end

                -- Maintain consistent window height when switching tabs
                -- Do not resize window when switching to settings tab for seamless transition
            end
            
            -- Apply theme colors to tabs after switching to update active state
            if f.ApplyTabThemeColors then
                f.ApplyTabThemeColors()
            end
        end

        -- Add tabs to the system
        for i, data in ipairs(tabData) do
            tabSystem:AddTab(data.name)
            local tab = tabSystem:GetTabButton(i)

            -- Set a wide fixed width up front. The active tab renders at a larger
            -- visual size than the inactive one, so the inactive tab's Text gets
            -- less room — use 130px to ensure both states fit "Settings" fully.
            tab:SetWidth(130)
            if tab.Text then
                tab.Text:SetWidth(0)
            end

            -- Desaturate every texture region ONCE here (persists across the
            -- repeated SetVertexColor calls in RefreshTabBar below) — the
            -- same technique f.closeButton uses above. Doing this strips the
            -- tan/stone hue baked into the art BEFORE tinting, which is what
            -- an earlier attempt skipped — vertex-coloring alone just mixes
            -- with the existing color instead of replacing it.
            for _, regionName in ipairs({ "Left", "Middle", "Right", "LeftActive", "MiddleActive", "RightActive" }) do
                local region = tab[regionName]
                if region then region:SetDesaturated(true) end
            end

            -- Store tab data for our use
            f.tabs[data.id] = {
                id = data.id,
                button = tab,
                icon = nil
            }

            -- Hook the tab click to our switch function
            tab:HookScript("OnClick", function()
                SwitchTab(data.id)
            end)

            -- Add tooltips
            tab:SetScript("OnEnter", function(self)
                GameTooltip:SetOwner(self, "ANCHOR_TOP")
                GameTooltip:SetText(data.name, 1, 1, 1)
                GameTooltip:AddLine(data.tooltip, 0.7, 0.7, 0.7, true)
                GameTooltip:Show()
            end)

            tab:SetScript("OnLeave", function(self)
                GameTooltip:Hide()
            end)
        end

        -- Re-apply after one render pass to lock in sizes after the template
        -- has had a chance to run its own sizing logic.
        C_Timer.After(0, function()
            for i, data in ipairs(tabData) do
                local tab = tabSystem:GetTabButton(i)
                if tab then
                    tab:SetWidth(130)
                    if tab.Text then tab.Text:SetWidth(0) end
                end
            end
        end)

        -- Set initial tab
        tabSystem:SetTab(1)
        tabSystem:SetFrameStrata("DIALOG")

        -- Recolors every tab's (already-desaturated, see creation loop above)
        -- texture regions from the current theme + window opacity. Since
        -- desaturating strips the baked-in stone hue, SetVertexColor here
        -- applies a clean tint instead of muddying with the original color.
        --
        -- Left/Middle/Right (the base, always-visible tab shape) get a
        -- muted tone derived from WINDOW_BORDER — this is effectively how
        -- every UNSELECTED tab looks, since Blizzard's own SetTab()/
        -- PanelTemplates internals are what show/hide the LeftActive/
        -- MiddleActive/RightActive overlay on top of it for whichever tab is
        -- actually selected, so there's no need to branch per-tab here for
        -- the textures — only the tab Text color needs an explicit active
        -- check. Colors are read fresh from UI_CONSTANTS.COLORS every call
        -- rather than cached, since ApplyTheme() replaces that whole table
        -- on a theme change. Called from: SwitchTab, the theme dropdown's
        -- OnThemeSelect, and the transparency slider's OnValueChanged.
        local function RefreshTabBar()
            local colors  = UI_CONSTANTS.COLORS
            local opacity = PVPHUB_SETTINGS.windowOpacity or 0.95
            local border  = colors.WINDOW_BORDER
            local accent  = colors.TITLE_COLOR
            local baseR, baseG, baseB = border[1] * 0.55, border[2] * 0.55, border[3] * 0.55

            for tabId, tabInfo in pairs(f.tabs) do
                local tab = tabInfo.button
                if tab then
                    for _, regionName in ipairs({ "Left", "Middle", "Right" }) do
                        local region = tab[regionName]
                        if region then region:SetVertexColor(baseR, baseG, baseB, opacity) end
                    end
                    for _, regionName in ipairs({ "LeftActive", "MiddleActive", "RightActive" }) do
                        local region = tab[regionName]
                        if region then region:SetVertexColor(accent[1], accent[2], accent[3], opacity) end
                    end

                    if tab.Text then
                        local isActive = (f.currentTab == tabId)
                        local c = isActive and 1 or 0.75
                        tab.Text:SetTextColor(c, c, c, 1)
                    end
                end
            end
        end

        -- Kept under its historical name so every existing call site
        -- (SwitchTab, both theme dropdowns, both transparency sliders) keeps
        -- working unchanged.
        f.ApplyTabThemeColors = RefreshTabBar

        -- Paint initial tab state after a brief delay, same timing the old
        -- code used, so this runs after the rest of the window body (and any
        -- other init logic touching f.tabs) has finished.
        C_Timer.After(0.1, function()
            RefreshTabBar()
        end)
        
        -- Function to create settings frame (will be called when settings tab is first accessed)
        function f:CreateSettingsFrame()
            -- Create container frame for settings tab
            local settingsContainer = CreateFrame("Frame", nil, f)
            settingsContainer:SetPoint("TOPLEFT", f, "TOPLEFT", 20, -65)
            settingsContainer:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -45, 85)

            -- The entire build is wrapped in pcall and f.settingsFrame is only assigned
            -- on success. If a Lua error occurs anywhere below (bad saved variable,
            -- missing template, nil table field, etc.), the container is torn down and
            -- f.settingsFrame stays nil — so the next tab click retries the build instead
            -- of permanently caching a half-built/empty settings panel.
            local buildOk, buildErr = pcall(function()

            -- Create scroll frame with modern TWW styling
            local scrollFrame = CreateFrame("ScrollFrame", nil, settingsContainer, "ScrollFrameTemplate")
            scrollFrame:SetPoint("TOPLEFT", settingsContainer, "TOPLEFT", 0, 0)
            scrollFrame:SetPoint("BOTTOMRIGHT", settingsContainer, "BOTTOMRIGHT", -10, 0)
            ApplyModernScrollbarStyling(scrollFrame, UI_CONSTANTS.COLORS, PVPHUB_SCROLLBAR_NUDGE(f))
            scrollFrame:EnableMouseWheel(true)
            scrollFrame:SetScript("OnMouseWheel", function(self, delta)
                local current = self:GetVerticalScroll()
                local maxScroll = self:GetVerticalScrollRange()
                local newScroll = math.max(0, math.min(current - (delta * 20), maxScroll))
                self:SetVerticalScroll(newScroll)
            end)

            -- Create scroll child
            local settingsFrame = CreateFrame("Frame", nil, scrollFrame)
            settingsFrame:SetSize(750, 800)
            scrollFrame:SetScrollChild(settingsFrame)
            scrollFrame:SetScript("OnSizeChanged", function(self, w, _)
                settingsFrame:SetWidth(w)
            end)
            f.settingsScrollFrame = scrollFrame

            -- ============================================================
            -- COLLAPSIBLE SECTION SYSTEM
            -- ============================================================

            -- Persist expand/collapse state per section
            if not PVPHUB_SETTINGS.settingsSections then
                PVPHUB_SETTINGS.settingsSections = {}
            end
            local ss = PVPHUB_SETTINGS.settingsSections
            if ss.display       == nil then ss.display       = false end
            if ss.notifications == nil then ss.notifications = false end
            if ss.queueTimer    == nil then ss.queueTimer    = false end
            if ss.appearance    == nil then ss.appearance    = false end
            if ss.advanced      == nil then ss.advanced      = false end

            local allSections   = {}
            local RecalcPositions  -- forward declaration

            -- Helper: build a collapsible section header + content frame
            local function MakeSection(key, title, colorRGB, iconPath)
                local expanded = (ss[key] ~= false)

                -- Header button with gradient fill that fades to the right
                local header = CreateFrame("Button", nil, settingsFrame, "BackdropTemplate")
                header:SetHeight(28)
                -- Minimal backdrop: transparent bg, keep a subtle bottom border line only
                header:SetBackdrop({
                    bgFile   = "Interface\\Buttons\\WHITE8x8",
                    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
                    tile = false, tileSize = 16, edgeSize = 8,
                    insets = {left=2, right=2, top=2, bottom=2},
                })
                header:SetBackdropColor(0, 0, 0, 0)
                header:SetBackdropBorderColor(colorRGB[1]*0.40, colorRGB[2]*0.40, colorRGB[3]*0.40, 0.35)

                -- Gradient texture: full color on left, transparent on right
                local gradTex = header:CreateTexture(nil, "BACKGROUND")
                gradTex:SetAllPoints(header)
                gradTex:SetTexture("Interface\\Buttons\\WHITE8x8")
                gradTex:SetGradient("HORIZONTAL",
                    CreateColor(colorRGB[1]*0.55, colorRGB[2]*0.55, colorRGB[3]*0.55, 0.92),
                    CreateColor(colorRGB[1]*0.15, colorRGB[2]*0.15, colorRGB[3]*0.15, 0.60))

                header:SetScript("OnEnter", function(self)
                    gradTex:SetGradient("HORIZONTAL",
                        CreateColor(colorRGB[1]*0.75, colorRGB[2]*0.75, colorRGB[3]*0.75, 0.97),
                        CreateColor(colorRGB[1]*0.25, colorRGB[2]*0.25, colorRGB[3]*0.25, 0.70))
                end)
                header:SetScript("OnLeave", function(self)
                    gradTex:SetGradient("HORIZONTAL",
                        CreateColor(colorRGB[1]*0.55, colorRGB[2]*0.55, colorRGB[3]*0.55, 0.92),
                        CreateColor(colorRGB[1]*0.15, colorRGB[2]*0.15, colorRGB[3]*0.15, 0.60))
                end)

                -- Icon
                local iconTex = header:CreateTexture(nil, "OVERLAY")
                iconTex:SetSize(18, 18)
                iconTex:SetPoint("LEFT", header, "LEFT", 8, 0)
                if iconPath then
                    iconTex:SetTexture(iconPath)
                    iconTex:SetTexCoord(0.08, 0.92, 0.08, 0.92) -- trim icon border
                    iconTex:SetVertexColor(1, 1, 1, 0.85)
                else
                    iconTex:SetAlpha(0)
                end

                local titleText = header:CreateFontString(nil, "OVERLAY", "GameFontNormal")
                titleText:SetPoint("LEFT", iconTex, "RIGHT", 7, 0)
                RegisterTrackedFont(titleText, 13, "OUTLINE")
                titleText:SetText(title)
                titleText:SetTextColor(1, 1, 1, 1)

                -- Expand/collapse arrow, placed right after the title
                local arrowText = header:CreateFontString(nil, "OVERLAY", "GameFontNormal")
                arrowText:SetPoint("LEFT", titleText, "RIGHT", 8, 0)
                RegisterTrackedFont(arrowText, 11, "OUTLINE")
                arrowText:SetText(expanded and CreateAtlasMarkup("auctionhouse-ui-sortarrow", 10, 10) or CreateAtlasMarkup("common-icon-forwardarrow", 8, 13))
                arrowText:SetTextColor(1, 1, 1, 0.65)

                -- Content frame (children of this are shown/hidden together)
                local content = CreateFrame("Frame", nil, settingsFrame, "BackdropTemplate")
                content:SetBackdrop({
                    bgFile   = "Interface\\Buttons\\WHITE8x8",
                    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
                    tile = false, tileSize = 16, edgeSize = 8,
                    insets = {left=2, right=2, top=2, bottom=2},
                })
                content:SetBackdropColor(0.11, 0.09, 0.13, 0.72)
                content:SetBackdropBorderColor(colorRGB[1]*0.45, colorRGB[2]*0.45, colorRGB[3]*0.45, 0.55)

                -- Left accent stripe
                local stripe = content:CreateTexture(nil, "BORDER")
                stripe:SetTexture("Interface\\Buttons\\WHITE8x8")
                stripe:SetVertexColor(colorRGB[1], colorRGB[2], colorRGB[3], 0.85)
                stripe:SetPoint("TOPLEFT",    content, "TOPLEFT",    3, -3)
                stripe:SetPoint("BOTTOMLEFT", content, "BOTTOMLEFT", 3,  3)
                stripe:SetWidth(3)

                local sectionData = {
                    key           = key,
                    header        = header,
                    content       = content,
                    titleText     = titleText,
                    arrowText     = arrowText,
                    colorRGB      = colorRGB,
                    expanded      = expanded,
                    contentHeight = 100,  -- estimated; recalculated below
                }

                header:SetScript("OnClick", function()
                    sectionData.expanded = not sectionData.expanded
                    ss[key] = sectionData.expanded
                    RecalcPositions()
                end)

                table.insert(allSections, sectionData)
                return sectionData
            end

            -- Restack all sections vertically after a toggle
            RecalcPositions = function()
                local yPos = -8
                for _, sec in ipairs(allSections) do
                    sec.header:ClearAllPoints()
                    sec.header:SetPoint("TOPLEFT",  settingsFrame, "TOPLEFT",  8, yPos)
                    sec.header:SetPoint("TOPRIGHT", settingsFrame, "TOPRIGHT", -8, yPos)
                    yPos = yPos - 28

                    sec.content:ClearAllPoints()
                    sec.content:SetPoint("TOPLEFT",  settingsFrame, "TOPLEFT",  8, yPos)
                    sec.content:SetPoint("TOPRIGHT", settingsFrame, "TOPRIGHT", -8, yPos)

                    if sec.expanded then
                        sec.content:SetHeight(sec.contentHeight)
                        sec.content:Show()
                        yPos = yPos - sec.contentHeight
                    else
                        sec.content:SetHeight(0.01)
                        sec.content:Hide()
                    end
                    if sec.arrowText then
                        sec.arrowText:SetText(sec.expanded and CreateAtlasMarkup("auctionhouse-ui-sortarrow", 10, 10) or CreateAtlasMarkup("common-icon-forwardarrow", 8, 13))
                    end
                    yPos = yPos - 5  -- gap between sections
                end
                -- Footer credit always visible below all sections
                if f.developerCredit then
                    f.developerCredit:ClearAllPoints()
                    f.developerCredit:SetPoint("TOPLEFT", settingsFrame, "TOPLEFT", 18, yPos - 10)
                end
                settingsFrame:SetHeight(math.max(math.abs(yPos) + 40, 400))
            end

            -- ============================================================
            -- SECTION: DISPLAY
            -- ============================================================
            local sDisp  = MakeSection("display",       "DISPLAY",       {0.15, 0.45, 0.65}, "Interface\\Icons\\Ability_Hunter_EagleEye")
            local dispContent = sDisp.content

            local hideRealmCheckbox = CreateFrame("CheckButton", nil, dispContent, "InterfaceOptionsCheckButtonTemplate")
            hideRealmCheckbox:SetPoint("TOPLEFT", dispContent, "TOPLEFT", 12, -10)
            hideRealmCheckbox.Text:SetText("Hide Realm Names")
            hideRealmCheckbox.tooltipText = "Hide realm names in character display"
            if not PVPHUB_SETTINGS.mainWindow then PVPHUB_SETTINGS.mainWindow = {} end
            hideRealmCheckbox:SetChecked(PVPHUB_SETTINGS.mainWindow.hideServerNames or false)
            hideRealmCheckbox:SetScript("OnClick", function(self)
                PVPHUB_SETTINGS.mainWindow.hideServerNames = self:GetChecked()
                if f.currentTab == "characters" and f.UpdateContent then f:UpdateContent() end
            end)

            local hideNoRatingsCheckbox = CreateFrame("CheckButton", nil, dispContent, "InterfaceOptionsCheckButtonTemplate")
            hideNoRatingsCheckbox:SetPoint("TOPLEFT", hideRealmCheckbox, "BOTTOMLEFT", 0, -2)
            hideNoRatingsCheckbox.Text:SetText("Hide Characters with No Ratings")
            hideNoRatingsCheckbox.tooltipText = "Hide characters that have no rating in any PvP bracket"
            hideNoRatingsCheckbox:SetChecked(PVPHUB_SETTINGS.mainWindow.hideNoRatings or false)
            hideNoRatingsCheckbox:SetScript("OnClick", function(self)
                PVPHUB_SETTINGS.mainWindow.hideNoRatings = self:GetChecked()
                if f.currentTab == "characters" and f.UpdateContent then f:UpdateContent() end
            end)

            local enableGroupsCheckbox = CreateFrame("CheckButton", nil, dispContent, "InterfaceOptionsCheckButtonTemplate")
            enableGroupsCheckbox:SetPoint("TOPLEFT", hideNoRatingsCheckbox, "BOTTOMLEFT", 0, -2)
            enableGroupsCheckbox.Text:SetText("Enable Character Groups")
            enableGroupsCheckbox:SetScript("OnEnter", function(self)
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                GameTooltip:SetText("Enable Character Groups", 1, 1, 1)
                GameTooltip:AddLine("Organize your characters into custom groups that can be collapsed and expanded.", 0.7, 0.7, 0.7, true)
                GameTooltip:AddLine(" ", 1, 1, 1)
                GameTooltip:AddLine("Click the '+ New Group' button to create groups, then right-click characters to move them between groups.", 0.7, 0.7, 0.7, true)
                GameTooltip:Show()
            end)
            enableGroupsCheckbox:SetScript("OnLeave", function() GameTooltip:Hide() end)
            if not PVPHUB_SETTINGS.characterGroups then
                PVPHUB_SETTINGS.characterGroups = {
                    groups = {{name = "No Group", characters = {}, collapsed = false, isDefault = true}},
                    enabled = false,
                }
            end
            enableGroupsCheckbox:SetChecked(PVPHUB_SETTINGS.characterGroups.enabled or false)
            enableGroupsCheckbox:SetScript("OnClick", function(self)
                PVPHUB_SETTINGS.characterGroups.enabled = self:GetChecked()
                if f.currentTab == "characters" then
                    if f.UpdateContent then f:UpdateContent() end
                    if f.manageGroupsBtn then
                        f.manageGroupsBtn:SetShown(PVPHUB_SETTINGS.characterGroups.enabled)
                    end
                end
            end)

            -- Total Honor/Conquest/Gold display thresholds — a character
            -- with less than this amount of a currency is left out of that
            -- currency's Total summary (and its breakdown popup), so a pile
            -- of 1-copper or single-digit-honor alts doesn't dilute the
            -- number. 0 (default) includes everyone, matching prior behavior.
            local function CreateThresholdRow(anchorTo, labelText, tooltipText, settingsKey)
                local label = dispContent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
                label:SetPoint("TOPLEFT", anchorTo, "BOTTOMLEFT", 0, -12)
                label:SetText(labelText)

                local editBox = CreateFrame("EditBox", nil, dispContent, "InputBoxTemplate")
                editBox:SetSize(60, 20)
                -- Fixed offset from each label's own LEFT edge (not its RIGHT
                -- edge) — since every label starts at the same x, this lines
                -- all three editboxes up in one column regardless of how
                -- long "Honor Threshold:" vs. "Conquest Threshold:" is.
                editBox:SetPoint("LEFT", label, "LEFT", 150, -1)
                editBox:SetAutoFocus(false)
                editBox:SetNumeric(true)
                editBox:SetMaxLetters(9)

                local function CurrentValue()
                    return (PVPHUB_SETTINGS.mainWindow and PVPHUB_SETTINGS.mainWindow[settingsKey]) or 0
                end
                editBox:SetText(tostring(CurrentValue()))
                editBox:SetCursorPosition(0)

                local function SaveValue()
                    local val = tonumber(editBox:GetText()) or 0
                    if val < 0 then val = 0 end
                    if not PVPHUB_SETTINGS.mainWindow then PVPHUB_SETTINGS.mainWindow = {} end
                    PVPHUB_SETTINGS.mainWindow[settingsKey] = val
                    editBox:SetText(tostring(val))
                    editBox:ClearFocus()
                    if f.currentTab == "characters" and f.UpdateContent then f:UpdateContent() end
                end
                editBox:SetScript("OnEnterPressed", SaveValue)
                editBox:SetScript("OnEditFocusLost", SaveValue)
                editBox:SetScript("OnEscapePressed", function(self)
                    self:SetText(tostring(CurrentValue()))
                    self:ClearFocus()
                end)
                editBox:SetScript("OnEnter", function(self)
                    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                    GameTooltip:SetText(labelText, 1, 1, 1)
                    GameTooltip:AddLine(tooltipText, 0.7, 0.7, 0.7, true)
                    GameTooltip:Show()
                end)
                editBox:SetScript("OnLeave", function() GameTooltip:Hide() end)

                return label, editBox
            end

            -- Each row anchors to the previous row's LABEL (not its editbox,
            -- which sits further right) so every label stays in one flush
            -- left-aligned column instead of drifting right with each row.
            local honorLabel, honorThresholdBox = CreateThresholdRow(enableGroupsCheckbox,
                "Honor Threshold:",
                "Only count characters with more than this much Honor toward Total Honor. 0 includes everyone.",
                "honorThreshold")
            local conquestLabel, conquestThresholdBox = CreateThresholdRow(honorLabel,
                "Conquest Threshold:",
                "Only count characters with more than this much Conquest toward Total Conquest. 0 includes everyone.",
                "conquestThreshold")
            local goldLabel, goldThresholdBox = CreateThresholdRow(conquestLabel,
                "Gold Threshold:",
                "Only count characters with more than this much Gold toward Total Gold. Value is in gold, not copper. 0 includes everyone.",
                "goldThreshold")

            -- ============================================================
            -- SECTION: NOTIFICATIONS
            -- ============================================================
            local sNotif = MakeSection("notifications",  "NOTIFICATIONS",  {0.65, 0.45, 0.10}, "Interface\\Icons\\INV_Misc_Horn_01")
            local notifContent = sNotif.content

            local disableHonorWarningsCheckbox = CreateFrame("CheckButton", nil, notifContent, "InterfaceOptionsCheckButtonTemplate")
            disableHonorWarningsCheckbox:SetPoint("TOPLEFT", notifContent, "TOPLEFT", 12, -10)
            disableHonorWarningsCheckbox.Text:SetText("Disable Honor Cap Warnings")
            disableHonorWarningsCheckbox.tooltipText = "Disable the popup warning when characters reach 14k Honor"
            PVPHUB_SETTINGS.disableHonorWarnings = PVPHUB_SETTINGS.disableHonorWarnings or false
            disableHonorWarningsCheckbox:SetChecked(PVPHUB_SETTINGS.disableHonorWarnings)
            disableHonorWarningsCheckbox:SetScript("OnClick", function(self)
                PVPHUB_SETTINGS.disableHonorWarnings = self:GetChecked()
                if PVPHUB_SETTINGS.disableHonorWarnings then
                    PVPHubPrint("|cffff0000[PVPHUB]|r Honor cap warnings disabled.")
                else
                    PVPHubPrint("|cffff0000[PVPHUB]|r Honor cap warnings enabled.")
                end
            end)

            local disablePrintCheckbox = CreateFrame("CheckButton", nil, notifContent, "InterfaceOptionsCheckButtonTemplate")
            disablePrintCheckbox:SetPoint("TOPLEFT", disableHonorWarningsCheckbox, "BOTTOMLEFT", 0, -2)
            disablePrintCheckbox.Text:SetText("Disable Chat Notifications")
            PVPHUB_SETTINGS.disablePrintMessages = PVPHUB_SETTINGS.disablePrintMessages or false
            disablePrintCheckbox:SetChecked(PVPHUB_SETTINGS.disablePrintMessages)
            disablePrintCheckbox:SetScript("OnClick", function(self)
                PVPHUB_SETTINGS.disablePrintMessages = self:GetChecked()
            end)
            disablePrintCheckbox:SetScript("OnEnter", function(self)
                GameTooltip:SetOwner(self, "ANCHOR_CURSOR")
                GameTooltip:SetText("Disable Chat Notifications", 1, 1, 1)
                GameTooltip:AddLine("Hide addon messages that appear in your chat window", 0.7, 0.7, 0.7, true)
                GameTooltip:AddLine(" ", 1, 1, 1)
                GameTooltip:AddLine("Examples of messages that will be hidden:", 1, 0.82, 0)
                GameTooltip:AddLine("\226\128\162 MMR recorded! New MMR: 1850 (+15)", 0.9, 0.9, 0.9, true)
                GameTooltip:AddLine("\226\128\162 Note saved: Good healer", 0.9, 0.9, 0.9, true)
                GameTooltip:AddLine("\226\128\162 Character hidden/unhidden", 0.9, 0.9, 0.9, true)
                GameTooltip:AddLine("\226\128\162 PvP ratings updated", 0.9, 0.9, 0.9, true)
                GameTooltip:Show()
            end)
            disablePrintCheckbox:SetScript("OnLeave", function() GameTooltip:Hide() end)

            -- ============================================================
            -- SECTION: QUEUE TIMER
            -- ============================================================
            local sQT    = MakeSection("queueTimer",     "QUEUE TIMER",    {0.15, 0.55, 0.20}, "Interface\\Icons\\INV_Misc_PocketWatch_01")
            local qtContent = sQT.content

            -- Master toggle
            if PVPHUB_SETTINGS.queueTimerEnabled == nil then PVPHUB_SETTINGS.queueTimerEnabled = true end
            local queueTimerCheckbox = CreateFrame("CheckButton", nil, qtContent, "InterfaceOptionsCheckButtonTemplate")
            queueTimerCheckbox:SetPoint("TOPLEFT", qtContent, "TOPLEFT", 12, -10)
            queueTimerCheckbox.Text:SetText("Show Queue Timer")
            queueTimerCheckbox.tooltipText = "Show a draggable queue timer widget when you are in a PvP queue"
            queueTimerCheckbox:SetChecked(PVPHUB_SETTINGS.queueTimerEnabled)
            queueTimerCheckbox:SetScript("OnClick", function(self)
                PVPHUB_SETTINGS.queueTimerEnabled = self:GetChecked()
                if PVPHUB_SETTINGS.queueTimerEnabled then
                    if PVPHUB.QueueTimer then PVPHUB.QueueTimer:Update() end
                else
                    if PVPHUB.QueueTimer then PVPHUB.QueueTimer:Hide() end
                end
            end)
            queueTimerCheckbox:SetScript("OnEnter", function(self)
                GameTooltip:SetOwner(self, "ANCHOR_CURSOR")
                GameTooltip:SetText("Show Queue Timer", 1, 1, 1)
                GameTooltip:AddLine("Displays a small draggable widget while you are in a PvP queue", 0.7, 0.7, 0.7, true)
                GameTooltip:AddLine(" ")
                GameTooltip:AddLine("The timer shows:", 1, 0.82, 0)
                GameTooltip:AddLine("\226\128\162 Queue name (Solo Shuffle, 2v2, 3v3, BlitzBG)", 0.9, 0.9, 0.9, true)
                GameTooltip:AddLine("\226\128\162 Average estimated wait time", 0.9, 0.9, 0.9, true)
                GameTooltip:AddLine("\226\128\162 Your elapsed time in queue", 0.9, 0.9, 0.9, true)
                GameTooltip:AddLine("\226\128\162 Countdown to accept when the queue pops", 0.9, 0.9, 0.9, true)
                GameTooltip:Show()
            end)
            queueTimerCheckbox:SetScript("OnLeave", function() GameTooltip:Hide() end)

            -- Style dropdown: "PVPHUB" (default, themed chrome) or
            -- "Detail" (flat minimal card with a last-match MMR line).
            if not PVPHUB_SETTINGS.queueTimer then PVPHUB_SETTINGS.queueTimer = {} end
            if PVPHUB_SETTINGS.queueTimer.style == nil then PVPHUB_SETTINGS.queueTimer.style = "pvphub" end

            local qtStyleLabel = qtContent:CreateFontString(nil, "ARTWORK", "GameFontNormal")
            qtStyleLabel:SetPoint("TOPLEFT", queueTimerCheckbox, "BOTTOMLEFT", 22, -8)
            qtStyleLabel:SetText("Style:")
            qtStyleLabel:SetTextColor(0.85, 0.85, 0.85, 1)

            local qtStyleNames = { pvphub = "PVPHUB", simple = "Detail", compact = "Compact" }
            local qtStyleDropdown = CreateFrame("Frame", "PVPHUBQueueStyleDropdown", qtContent, "UIDropDownMenuTemplate")
            qtStyleDropdown:SetPoint("LEFT", qtStyleLabel, "RIGHT", -10, 0)
            UIDropDownMenu_SetWidth(qtStyleDropdown, 130)
            ApplyModernDropdownStyling(qtStyleDropdown)
            UIDropDownMenu_SetText(qtStyleDropdown, qtStyleNames[PVPHUB_SETTINGS.queueTimer.style] or "PVPHUB")
            UIDropDownMenu_Initialize(qtStyleDropdown, function(self, level)
                local options = {
                    { value = "pvphub",  text = "PVPHUB" },
                    { value = "simple",  text = "Detail" },
                    { value = "compact", text = "Compact" },
                }
                for _, opt in ipairs(options) do
                    local info   = UIDropDownMenu_CreateInfo()
                    info.text    = opt.text
                    info.value   = opt.value
                    info.checked = (PVPHUB_SETTINGS.queueTimer.style == opt.value)
                    info.func    = function()
                        PVPHUB_SETTINGS.queueTimer.style = opt.value
                        UIDropDownMenu_SetText(qtStyleDropdown, opt.text)
                        if PVPHUB.QueueTimer then
                            PVPHUB.QueueTimer:ApplyTheme()
                            PVPHUB.QueueTimer:Update()
                        end
                    end
                    UIDropDownMenu_AddButton(info)
                end
            end)
            qtStyleDropdown:SetScript("OnEnter", function(self)
                GameTooltip:SetOwner(self, "ANCHOR_CURSOR")
                GameTooltip:SetText("Queue Timer Style", 1, 1, 1)
                GameTooltip:AddLine("PVPHUB: the default themed look with colored accents", 0.7, 0.7, 0.7, true)
                GameTooltip:AddLine("Detail: a minimal dark card showing your last match's MMR change", 0.7, 0.7, 0.7, true)
                GameTooltip:AddLine("Compact: everything squeezed onto a single line", 0.7, 0.7, 0.7, true)
                GameTooltip:Show()
            end)
            qtStyleDropdown:SetScript("OnLeave", function() GameTooltip:Hide() end)
            f.qtStyleDropdown = qtStyleDropdown

            -- Size slider
            PVPHUB_SETTINGS.queueTimerScale = PVPHUB_SETTINGS.queueTimerScale or 1.0
            local queueTimerSizeLabel = qtContent:CreateFontString(nil, "ARTWORK", "GameFontNormal")
            queueTimerSizeLabel:SetPoint("TOPLEFT", qtStyleLabel, "BOTTOMLEFT", 0, -12)
            queueTimerSizeLabel:SetText("Size:")
            queueTimerSizeLabel:SetTextColor(0.85, 0.85, 0.85, 1)

            local queueTimerSizeSlider = CreateFrame("Slider", nil, qtContent, "MinimalSliderTemplate")
            queueTimerSizeSlider:SetPoint("LEFT", queueTimerSizeLabel, "RIGHT", 8, 0)
            queueTimerSizeSlider:SetSize(120, 15)
            queueTimerSizeSlider:SetMinMaxValues(1.0, 2.5)
            queueTimerSizeSlider:SetValue(PVPHUB_SETTINGS.queueTimerScale)
            queueTimerSizeSlider:SetValueStep(0.05)
            queueTimerSizeSlider:SetObeyStepOnDrag(true)

            local queueTimerSizeValue = qtContent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
            queueTimerSizeValue:SetPoint("LEFT", queueTimerSizeSlider, "RIGHT", 6, 0)
            queueTimerSizeValue:SetText(string.format("%.0f%%", PVPHUB_SETTINGS.queueTimerScale * 100))
            queueTimerSizeValue:SetTextColor(1, 1, 1, 1)

            local function ApplyQueueTimerScale(value)
                PVPHUB_SETTINGS.queueTimerScale = value
                queueTimerSizeValue:SetText(string.format("%.0f%%", value * 100))
                if PVPHUB.QueueTimer and PVPHUB.QueueTimer.frame then
                    PVPHUB.QueueTimer.frame:SetScale(value)
                elseif _G.PVPHUBQueueTimerFrame then
                    _G.PVPHUBQueueTimerFrame:SetScale(value)
                end
            end
            queueTimerSizeSlider:SetScript("OnValueChanged", function(self, value)
                if not value then return end
                ApplyQueueTimerScale(value)
            end)
            queueTimerSizeSlider:SetScript("OnMouseDown", function(self, button)
                if button == "LeftButton" then self._dragging = true; self._lastScale = self:GetValue() end
            end)
            queueTimerSizeSlider:SetScript("OnMouseUp", function(self, button)
                if button == "LeftButton" then self._dragging = false; ApplyQueueTimerScale(self:GetValue()) end
            end)
            queueTimerSizeSlider:SetScript("OnUpdate", function(self)
                if not self._dragging then return end
                local value = self:GetValue()
                if value == self._lastScale then return end
                self._lastScale = value
                ApplyQueueTimerScale(value)
            end)

            -- Opacity slider
            if not PVPHUB_SETTINGS.queueTimer then PVPHUB_SETTINGS.queueTimer = {} end
            if PVPHUB_SETTINGS.queueTimer.opacity == nil then PVPHUB_SETTINGS.queueTimer.opacity = 0.95 end

            local qtOpacityLabel = qtContent:CreateFontString(nil, "ARTWORK", "GameFontNormal")
            qtOpacityLabel:SetPoint("TOPLEFT", queueTimerSizeLabel, "BOTTOMLEFT", 0, -12)
            qtOpacityLabel:SetText("Opacity:")
            qtOpacityLabel:SetTextColor(0.85, 0.85, 0.85, 1)

            local qtOpacitySlider = CreateFrame("Slider", nil, qtContent, "MinimalSliderTemplate")
            qtOpacitySlider:SetPoint("LEFT", qtOpacityLabel, "RIGHT", 8, 0)
            qtOpacitySlider:SetSize(120, 15)
            qtOpacitySlider:SetMinMaxValues(0.0, 1.0)
            qtOpacitySlider:SetValue(PVPHUB_SETTINGS.queueTimer.opacity)
            qtOpacitySlider:SetValueStep(0.01)
            qtOpacitySlider:SetObeyStepOnDrag(true)

            local qtOpacityValue = qtContent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
            qtOpacityValue:SetPoint("LEFT", qtOpacitySlider, "RIGHT", 6, 0)
            qtOpacityValue:SetText(string.format("%.0f%%", PVPHUB_SETTINGS.queueTimer.opacity * 100))
            qtOpacityValue:SetTextColor(1, 1, 1, 1)

            local function ApplyQueueTimerOpacity(value)
                if not PVPHUB_SETTINGS.queueTimer then PVPHUB_SETTINGS.queueTimer = {} end
                PVPHUB_SETTINGS.queueTimer.opacity = value
                qtOpacityValue:SetText(string.format("%.0f%%", value * 100))
                if PVPHUB.QueueTimer and PVPHUB.QueueTimer.frame then
                    PVPHUB.QueueTimer:ApplyOpacity()
                elseif _G.PVPHUBQueueTimerFrame then
                    local qf = _G.PVPHUBQueueTimerFrame
                    qf:SetBackdropColor(0.08, 0.05, 0.05, value)
                    qf:SetBackdropBorderColor(0.35, 0.2, 0.25, value)
                end
            end
            qtOpacitySlider:SetScript("OnValueChanged", function(self, value)
                if not value then return end; ApplyQueueTimerOpacity(value)
            end)
            qtOpacitySlider:SetScript("OnMouseDown", function(self, button)
                if button == "LeftButton" then self._dragging = true; self._lastOpacity = self:GetValue() end
            end)
            qtOpacitySlider:SetScript("OnMouseUp", function(self, button)
                if button == "LeftButton" then self._dragging = false; ApplyQueueTimerOpacity(self:GetValue()) end
            end)
            qtOpacitySlider:SetScript("OnUpdate", function(self)
                if not self._dragging then return end
                local value = self:GetValue()
                if value == self._lastOpacity then return end
                self._lastOpacity = value; ApplyQueueTimerOpacity(value)
            end)
            qtOpacitySlider:SetScript("OnEnter", function(self)
                GameTooltip:SetOwner(self, "ANCHOR_CURSOR")
                GameTooltip:SetText("Queue Timer Opacity", 1, 1, 1)
                GameTooltip:AddLine("Adjust the transparency of the queue timer widget (0% - 100%)", 0.7, 0.7, 0.7, true)
                GameTooltip:Show()
            end)
            qtOpacitySlider:SetScript("OnLeave", function() GameTooltip:Hide() end)

            -- Hide in Arenas/BGs
            if PVPHUB_SETTINGS.queueTimer.hideInInstances == nil then
                PVPHUB_SETTINGS.queueTimer.hideInInstances = true
            end
            local hideInInstancesCheckbox = CreateFrame("CheckButton", nil, qtContent, "InterfaceOptionsCheckButtonTemplate")
            hideInInstancesCheckbox:SetPoint("TOPLEFT", qtOpacityLabel, "BOTTOMLEFT", 0, -12)
            hideInInstancesCheckbox.Text:SetText("Hide Queue Timer in Arenas/BGs")
            hideInInstancesCheckbox.tooltipText = "Automatically hide the queue timer widget while inside arenas or battlegrounds"
            hideInInstancesCheckbox:SetChecked(PVPHUB_SETTINGS.queueTimer.hideInInstances)
            hideInInstancesCheckbox:SetScript("OnClick", function(self)
                if not PVPHUB_SETTINGS.queueTimer then PVPHUB_SETTINGS.queueTimer = {} end
                PVPHUB_SETTINGS.queueTimer.hideInInstances = self:GetChecked()
                if PVPHUB.QueueTimer then PVPHUB.QueueTimer:Update() end
            end)
            hideInInstancesCheckbox:SetScript("OnEnter", function(self)
                GameTooltip:SetOwner(self, "ANCHOR_CURSOR")
                GameTooltip:SetText("Hide Queue Timer in Arenas/BGs", 1, 1, 1)
                GameTooltip:AddLine("Hides the queue timer widget while inside arenas or battlegrounds", 0.7, 0.7, 0.7, true)
                GameTooltip:AddLine("The timer resumes displaying once you leave the instance", 0.7, 0.7, 0.7, true)
                GameTooltip:Show()
            end)
            hideInInstancesCheckbox:SetScript("OnLeave", function() GameTooltip:Hide() end)

            -- Font Outline
            if PVPHUB_SETTINGS.queueTimer.fontOutline == nil then PVPHUB_SETTINGS.queueTimer.fontOutline = true end
            local qtOutlineCheckbox = CreateFrame("CheckButton", nil, qtContent, "InterfaceOptionsCheckButtonTemplate")
            qtOutlineCheckbox:SetPoint("TOPLEFT", hideInInstancesCheckbox, "BOTTOMLEFT", 0, -2)
            qtOutlineCheckbox.Text:SetText("Font Outline")
            qtOutlineCheckbox.tooltipText = "Add an outline to the queue timer font for better readability"
            qtOutlineCheckbox:SetChecked(PVPHUB_SETTINGS.queueTimer.fontOutline)
            qtOutlineCheckbox:SetScript("OnClick", function(self)
                if not PVPHUB_SETTINGS.queueTimer then PVPHUB_SETTINGS.queueTimer = {} end
                PVPHUB_SETTINGS.queueTimer.fontOutline = self:GetChecked()
                if PVPHUB.QueueTimer then PVPHUB.QueueTimer:_ScaleFonts() end
            end)
            qtOutlineCheckbox:SetScript("OnEnter", function(self)
                GameTooltip:SetOwner(self, "ANCHOR_CURSOR")
                GameTooltip:SetText("Queue Timer Font Outline", 1, 1, 1)
                GameTooltip:AddLine("Toggle the text outline on queue timer labels", 0.7, 0.7, 0.7, true)
                GameTooltip:Show()
            end)
            qtOutlineCheckbox:SetScript("OnLeave", function() GameTooltip:Hide() end)

            -- Match Ready Sound dropdown
            if PVPHUB_SETTINGS.queueTimer.readySound == nil then
                PVPHUB_SETTINGS.queueTimer.readySound = "PvP Queue Ready"
            end
            local qtSoundLabel = qtContent:CreateFontString(nil, "ARTWORK", "GameFontNormal")
            qtSoundLabel:SetPoint("TOPLEFT", qtOutlineCheckbox, "BOTTOMLEFT", 0, -8)
            qtSoundLabel:SetText("Match Ready Sound:")
            qtSoundLabel:SetTextColor(0.85, 0.85, 0.85, 1)

            local qtSoundDropdown = CreateFrame("Frame", "PVPHUBSoundDropdown", qtContent, "UIDropDownMenuTemplate")
            qtSoundDropdown:SetPoint("LEFT", qtSoundLabel, "RIGHT", -10, 0)
            UIDropDownMenu_SetWidth(qtSoundDropdown, 120)
            UIDropDownMenu_SetText(qtSoundDropdown, PVPHUB_SETTINGS.queueTimer.readySound)
            UIDropDownMenu_Initialize(qtSoundDropdown, function(self, level)
                for _, opt in ipairs(PVPHUB.QueueTimer.SOUND_OPTIONS) do
                    local info    = UIDropDownMenu_CreateInfo()
                    info.text     = opt.label
                    info.value    = opt.label
                    info.checked  = (PVPHUB_SETTINGS.queueTimer.readySound == opt.label)
                    info.func     = function()
                        PVPHUB_SETTINGS.queueTimer.readySound = opt.label
                        UIDropDownMenu_SetText(qtSoundDropdown, opt.label)
                        if opt.id then PlaySound(opt.id, "Master") end
                    end
                    UIDropDownMenu_AddButton(info)
                end
            end)

            -- Queue Pop Volume slider
            if PVPHUB_SETTINGS.queueTimer.readySoundVolume == nil then
                PVPHUB_SETTINGS.queueTimer.readySoundVolume = 100
            end
            local qtVolLabel = qtContent:CreateFontString(nil, "ARTWORK", "GameFontNormal")
            qtVolLabel:SetPoint("TOPLEFT", qtSoundLabel, "BOTTOMLEFT", 0, -8)
            qtVolLabel:SetText("Queue Pop Volume:")
            qtVolLabel:SetTextColor(0.85, 0.85, 0.85, 1)

            local qtVolSlider = CreateFrame("Slider", nil, qtContent, "MinimalSliderTemplate")
            qtVolSlider:SetPoint("LEFT", qtVolLabel, "RIGHT", 8, 0)
            qtVolSlider:SetSize(110, 15)
            qtVolSlider:SetMinMaxValues(0, 100)
            qtVolSlider:SetValueStep(5)
            qtVolSlider:SetObeyStepOnDrag(true)
            qtVolSlider:SetValue(PVPHUB_SETTINGS.queueTimer.readySoundVolume)

            local qtVolValue = qtContent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
            qtVolValue:SetPoint("LEFT", qtVolSlider, "RIGHT", 8, 0)
            qtVolValue:SetText(PVPHUB_SETTINGS.queueTimer.readySoundVolume .. "%")
            qtVolValue:SetTextColor(1, 1, 1, 1)

            qtVolSlider:SetScript("OnValueChanged", function(self, value)
                local v = math.floor(value + 0.5)
                PVPHUB_SETTINGS.queueTimer.readySoundVolume = v
                qtVolValue:SetText(v .. "%")
            end)
            qtVolSlider:SetScript("OnEnter", function(self)
                GameTooltip:SetOwner(self, "ANCHOR_CURSOR")
                GameTooltip:SetText("Queue Pop Volume", 1, 1, 1)
                GameTooltip:AddLine("Adjusts the volume of the match-ready sound alert", 0.7, 0.7, 0.7, true)
                GameTooltip:AddLine("100% = full volume  |  0% = silent", 0.7, 0.7, 0.7, true)
                GameTooltip:Show()
            end)
            qtVolSlider:SetScript("OnLeave", function() GameTooltip:Hide() end)

            -- Play Sound button
            local qtPlaySoundBtn = CreateFrame("Button", nil, qtContent, "UIPanelButtonTemplate")
            qtPlaySoundBtn:SetSize(100, 25)
            qtPlaySoundBtn:SetPoint("TOPLEFT", qtVolLabel, "BOTTOMLEFT", 0, -10)
            qtPlaySoundBtn:SetText("Play Sound")
            qtPlaySoundBtn:GetFontString():SetTextColor(1, 1, 1)
            qtPlaySoundBtn:SetScript("OnClick", function()
                if PVPHUB.QueueTimer then
                    PVPHUB.QueueTimer:PlayReadySound()
                end
            end)
            qtPlaySoundBtn:SetScript("OnEnter", function(self)
                GameTooltip:SetOwner(self, "ANCHOR_CURSOR")
                GameTooltip:SetText("Play Sound", 1, 1, 1)
                GameTooltip:AddLine("Preview the match-ready alert at the current volume", 0.7, 0.7, 0.7, true)
                GameTooltip:Show()
            end)
            qtPlaySoundBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

            -- Preview toggle button
            local qtPreviewBtn = CreateFrame("Button", nil, qtContent, "UIPanelButtonTemplate")
            qtPreviewBtn:SetSize(150, 25)
            qtPreviewBtn:SetPoint("LEFT", qtPlaySoundBtn, "RIGHT", 8, 0)
            qtPreviewBtn:SetText("Show Preview")
            qtPreviewBtn:GetFontString():SetTextColor(1, 1, 1)
            qtPreviewBtn:SetScript("OnClick", function(self)
                if PVPHUB.QueueTimer then
                    local active = PVPHUB.QueueTimer:TogglePreview()
                    self:SetText(active and "Hide Preview" or "Show Preview")
                end
            end)
            qtPreviewBtn:SetScript("OnEnter", function(self)
                GameTooltip:SetOwner(self, "ANCHOR_CURSOR")
                GameTooltip:SetText("Preview Queue Timer", 1, 1, 1)
                GameTooltip:AddLine("Show or hide a sample queue timer widget", 0.7, 0.7, 0.7, true)
                GameTooltip:AddLine("Useful for previewing size, opacity, and font changes", 0.7, 0.7, 0.7, true)
                GameTooltip:AddLine("The preview disappears when you close settings", 0.7, 0.7, 0.7, true)
                GameTooltip:Show()
            end)
            qtPreviewBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
            f.qtPreviewBtn = qtPreviewBtn

            -- ============================================================
            -- SECTION: APPEARANCE
            -- ============================================================
            local sApp   = MakeSection("appearance",     "APPEARANCE",     {0.40, 0.20, 0.60}, "Interface\\Icons\\INV_Misc_Note_04")
            local appContent = sApp.content

            -- Built-in font fallback table (Friends/FRIENDS.TTF no longer ships with WoW)
            local builtInFonts = {
                ["Friz Quadrata TT"] = "Fonts\\FRIZQT__.TTF",
                ["Arial Narrow"]     = "Fonts\\ARIALN.TTF",
                ["Morpheus"]         = "Fonts\\MORPHEUS.TTF",
                ["Skurri"]           = "Fonts\\skurri.ttf",
            }

            local function GetFontPath(fontName)
                -- Check bundled fonts first (guaranteed to exist)
                if PVPHUB.bundledFonts and PVPHUB.bundledFontBase then
                    for _, entry in ipairs(PVPHUB.bundledFonts) do
                        if entry[1] == fontName then
                            return PVPHUB.bundledFontBase .. entry[2]
                        end
                    end
                end
                return builtInFonts[fontName] or "Fonts\\FRIZQT__.TTF"
            end

            local function GetAvailableFonts()
                local seen = {}
                local fonts = {}
                local function add(name)
                    if not seen[name] then seen[name] = true; table.insert(fonts, name) end
                end
                -- WoW built-ins
                for name in pairs(builtInFonts) do add(name) end
                -- PVPHUB bundled fonts
                for _, entry in ipairs(PVPHUB.bundledFonts or {}) do add(entry[1]) end
                -- LSM fonts from other addons
                if LibStub then
                    local LSM = LibStub("LibSharedMedia-3.0", true)
                    if LSM then
                        for _, name in ipairs(LSM:List("font") or {}) do add(name) end
                    end
                end
                table.sort(fonts)
                return fonts
            end

            local function ApplyFontChanges()
                -- Loop the stored FontString references and update in-place.
                -- No UpdateContent rebuild needed — just SetFont on live objects.
                if f.ApplyFont then f:ApplyFont() end
                if f.UpdateGreetingLayout then f:UpdateGreetingLayout() end
                -- Push the new font to everything else that tracks it: Settings/
                -- Stats tab chrome, hover tooltips, and the Queue Timer window.
                -- Streamer Mode is deliberately not touched here — it keeps its
                -- own independent font setting (compactMode.selectedFont).
                PVPHUB:RefreshTrackedFonts()
                if PVPHUB.QueueTimer and PVPHUB.QueueTimer._ScaleFonts then
                    PVPHUB.QueueTimer:_ScaleFonts()
                end
            end

            -- Font sub-label
            local fontsSubtitle = appContent:CreateFontString(nil, "ARTWORK", "GameFontNormal")
            fontsSubtitle:SetPoint("TOPLEFT", appContent, "TOPLEFT", 18, -12)
            fontsSubtitle:SetText("Font")
            RegisterTrackedFont(fontsSubtitle, 12, "OUTLINE")
            fontsSubtitle:SetTextColor(0.70, 0.70, 0.70, 1)
            f.fontsSubtitle = fontsSubtitle

            PVPHUB_SETTINGS.selectedFont = PVPHUB_SETTINGS.selectedFont or "Friz Quadrata TT"
            if not PVPHUB.currentFontPath then PVPHUB.currentFontPath = "Fonts\\FRIZQT__.TTF" end

            local fontDropdown = PVPHUB_CreateFontPicker(appContent, fontsSubtitle, "BOTTOMLEFT", -15, -4, 200,
                function() return PVPHUB_SETTINGS.selectedFont end,
                function(name)
                    PVPHUB_SETTINGS.selectedFont = name
                    ApplyFontChanges()
                    PVPHubPrint("|cffff0000[PVPHUB]|r Font: |cffffff00" .. name .. "|r")
                end,
                GetAvailableFonts)
            ApplyModernDropdownStyling(fontDropdown)
            ApplyFontChanges()
            f.fontDropdown = fontDropdown

            -- Theme sub-label
            local themeSubtitle = appContent:CreateFontString(nil, "ARTWORK", "GameFontNormal")
            themeSubtitle:SetPoint("TOPLEFT", fontDropdown, "BOTTOMLEFT", 0, -8)
            themeSubtitle:SetText("Theme")
            RegisterTrackedFont(themeSubtitle, 12, "OUTLINE")
            themeSubtitle:SetTextColor(0.70, 0.70, 0.70, 1)
            f.themeSubtitle = themeSubtitle

            local themeDropdown = CreateFrame("Frame", "PVPHUBThemeDropdown", appContent, "UIDropDownMenuTemplate")
            themeDropdown:SetPoint("TOPLEFT", themeSubtitle, "BOTTOMLEFT", -15, -4)
            UIDropDownMenu_SetWidth(themeDropdown, 120)
            ApplyModernDropdownStyling(themeDropdown)
            local themeNames    = {BLUE="Blue", RED="Red", DARK="Dark", MIDNIGHT="Midnight", AURORA="Aurora", CLASS="Class"}
            local currentTheme  = PVPHUB_SETTINGS.colorTheme or "RED"
            UIDropDownMenu_SetText(themeDropdown, themeNames[currentTheme] or "Theme")
            f.themeDropdown = themeDropdown

            local function OnThemeSelect(self)
                PVPHUB_SETTINGS.colorTheme = self.value
                UIDropDownMenu_SetText(themeDropdown, themeNames[self.value] or self.value)
                ApplyTheme()

                if f then
                    local bgColor = UI_CONSTANTS.COLORS.WINDOW_BG
                    local opacity = PVPHUB_SETTINGS.windowOpacity or 0.95
                    if f.bgTex then ApplyWindowBGColor(f, bgColor[4] * opacity) end
                    if f.borderTex then
                        local b = UI_CONSTANTS.COLORS.WINDOW_BORDER
                        f.borderTex:SetVertexColor(b[1], b[2], b[3], (b[4] or 1) * 0.3)
                    end

                    -- Tab recoloring now happens via f.ApplyTabThemeColors()
                    -- below (the custom tab bar's own theme-aware refresh),
                    -- which supersedes the Blizzard-tab-texture hack that used
                    -- to live inline here.

                    if f.title      then f.title:SetTextColor(unpack(UI_CONSTANTS.COLORS.TITLE_COLOR)) end
                    if f.scaleLabel then f.scaleLabel:SetTextColor(unpack(UI_CONSTANTS.COLORS.HEADER_COLOR)) end

                    local children = {f:GetChildren()}
                    for _, child in ipairs(children) do
                        if child and child.SetBackdropBorderColor and child ~= f then
                            local glowColor = UI_CONSTANTS.COLORS.WINDOW_GLOW
                            local curOpacity = PVPHUB_SETTINGS.windowOpacity or 0.95
                            child:SetBackdropBorderColor(glowColor[1], glowColor[2], glowColor[3], curOpacity * 0.5)
                            break
                        end
                    end
                end

                if f.ApplyTabThemeColors then f.ApplyTabThemeColors() end

                if f.currentTab == "settings" and f.settingsFrame then
                    if f.fontsSubtitle        then f.fontsSubtitle:SetTextColor(unpack(UI_CONSTANTS.COLORS.HEADER_COLOR)) end
                    if f.themeSubtitle        then f.themeSubtitle:SetTextColor(unpack(UI_CONSTANTS.COLORS.HEADER_COLOR)) end
                    if f.transparencySubtitle then f.transparencySubtitle:SetTextColor(unpack(UI_CONSTANTS.COLORS.HEADER_COLOR)) end
                    if f.developerCredit      then f.developerCredit:SetTextColor(0.8, 0.8, 0.8, 1) end
                    if f.honorText then
                        f.honorText:SetTextColor(1, 1, 1, 1)
                        if f.conquestText then f.conquestText:SetTextColor(1, 1, 1, 1) end
                        if f.goldText     then f.goldText:SetTextColor(1, 1, 1, 1) end
                    end
                end

                if f.titleLine then f.titleLine:SetVertexColor(unpack(UI_CONSTANTS.COLORS.ACCENT_LINE)) end
                if f.currentTab == "characters" and f.UpdateContent then f:UpdateContent() end

                if f.closeButton then
                    local cb = f.closeButton
                    if cb.normalTex    then cb.normalTex:SetVertexColor(0.82, 0.82, 0.88, 1) end
                    if cb.pushedTex    then cb.pushedTex:SetVertexColor(0.55, 0.55, 0.60, 1) end
                    if cb.highlightTex then cb.highlightTex:SetVertexColor(1, 1, 1, 1) end
                end


                local dds = {_G["PVPHUBSortDropdown"], _G["PVPHUBColumnDropdown"], _G["PVPHUBThemeDropdown"]}
                if f.fontDropdown  then table.insert(dds, f.fontDropdown)  end
                if f.themeDropdown then table.insert(dds, f.themeDropdown) end
                for _, dd in ipairs(dds) do RefreshDropdownColors(dd) end

                PVPHubPrint("|cffff0000[PVPHUB]|r Theme changed to " .. self.value .. "!")
            end
            UIDropDownMenu_Initialize(themeDropdown, function(self, level, menuList)
                local themes = {
                    {text="Blue",     value="BLUE"},
                    {text="Red",      value="RED"},
                    {text="Dark",     value="DARK"},
                    {text="Midnight", value="MIDNIGHT"},
                    {text="Aurora",   value="AURORA"},
                    {text="Class",    value="CLASS"},
                }
                for _, theme in ipairs(themes) do
                    local info    = UIDropDownMenu_CreateInfo()
                    info.text     = theme.text
                    info.value    = theme.value
                    info.func     = OnThemeSelect
                    info.checked  = PVPHUB_SETTINGS.colorTheme == theme.value
                    UIDropDownMenu_AddButton(info)
                end
            end)

            -- Transparency sub-label
            local transparencySubtitle = appContent:CreateFontString(nil, "ARTWORK", "GameFontNormal")
            transparencySubtitle:SetPoint("TOPLEFT", themeDropdown, "BOTTOMLEFT", 15, -8)
            transparencySubtitle:SetText("Transparency")
            RegisterTrackedFont(transparencySubtitle, 12, "OUTLINE")
            transparencySubtitle:SetTextColor(0.70, 0.70, 0.70, 1)
            f.transparencySubtitle = transparencySubtitle

            PVPHUB_SETTINGS.windowOpacity = PVPHUB_SETTINGS.windowOpacity or 0.95

            local transparencySlider = CreateFrame("Slider", nil, appContent, "MinimalSliderTemplate")
            transparencySlider:SetPoint("TOPLEFT", transparencySubtitle, "BOTTOMLEFT", -5, -6)
            transparencySlider:SetSize(150, 12)
            transparencySlider:SetMinMaxValues(0.5, 1.0)
            transparencySlider:SetValue(PVPHUB_SETTINGS.windowOpacity)
            transparencySlider:SetValueStep(0.05)
            transparencySlider:SetObeyStepOnDrag(true)

            local transparencyValueLabel = appContent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            transparencyValueLabel:SetPoint("LEFT", transparencySlider, "RIGHT", 10, 0)
            transparencyValueLabel:SetText(math.floor(PVPHUB_SETTINGS.windowOpacity * 100 + 0.5) .. "%")
            transparencyValueLabel:SetTextColor(unpack(UI_CONSTANTS.COLORS.HEADER_COLOR))

            local function ApplyTabTransparency(opacity)
                -- opacity is ignored here — PVPHUB_SETTINGS.windowOpacity is
                -- already updated by the caller (ApplyTransparency) before
                -- this runs, and RefreshTabBar (f.ApplyTabThemeColors) reads
                -- that live rather than needing it passed in.
                if f.ApplyTabThemeColors then f.ApplyTabThemeColors() end
            end

            local function ApplyTransparency(opacity)
                PVPHUB_SETTINGS.windowOpacity = opacity
                transparencyValueLabel:SetText(math.floor(opacity * 100 + 0.5) .. "%")
                if f then
                    local bgColor = UI_CONSTANTS.COLORS.WINDOW_BG
                    if f.bgTex then
                        ApplyWindowBGColor(f, opacity)
                    end
                    if f.glowLayers then
                        local g = UI_CONSTANTS.COLORS.WINDOW_GLOW
                        local alphas = {0.25, 0.14, 0.07, 0.03}
                        for i, tex in ipairs(f.glowLayers) do
                            tex:SetVertexColor(g[1], g[2], g[3], (alphas[i] or 0.05) * opacity)
                        end
                    end
                    ApplyTabTransparency(opacity)
                end
            end
            transparencySlider:SetScript("OnValueChanged", function(self, value)
                if not value then return end; ApplyTransparency(value)
            end)
            transparencySlider:SetScript("OnEnter", function(self)
                GameTooltip:SetOwner(self, "ANCHOR_CURSOR")
                GameTooltip:SetText("Window Transparency", 1, 1, 1)
                GameTooltip:AddLine("Adjust window opacity (50% - 100%)", 0.7, 0.7, 0.7, true)
                GameTooltip:AddLine("Lower values = more transparent", 0.7, 0.7, 0.7, true)
                GameTooltip:Show()
            end)
            transparencySlider:SetScript("OnLeave", function() GameTooltip:Hide() end)
            f.transparencySlider      = transparencySlider
            f.transparencyValueLabel  = transparencyValueLabel
            ApplyTransparency(PVPHUB_SETTINGS.windowOpacity)

            -- Re-anchor: Font → Theme → Transparency (no font size slider anymore)
            fontsSubtitle:ClearAllPoints()
            fontsSubtitle:SetPoint("TOPLEFT", appContent, "TOPLEFT", 18, -12)
            fontDropdown:ClearAllPoints()
            fontDropdown:SetPoint("TOPLEFT", fontsSubtitle, "BOTTOMLEFT", -15, -4)
            themeSubtitle:ClearAllPoints()
            themeSubtitle:SetPoint("TOPLEFT", fontDropdown, "BOTTOMLEFT", 15, -8)
            themeDropdown:ClearAllPoints()
            themeDropdown:SetPoint("TOPLEFT", themeSubtitle, "BOTTOMLEFT", -15, -4)
            transparencySubtitle:ClearAllPoints()
            transparencySubtitle:SetPoint("TOPLEFT", themeDropdown, "BOTTOMLEFT", 15, -8)

            -- Match History sub-label
            local matchHistorySubtitle = appContent:CreateFontString(nil, "ARTWORK", "GameFontNormal")
            matchHistorySubtitle:SetPoint("TOPLEFT", transparencySlider, "BOTTOMLEFT", 5, -16)
            matchHistorySubtitle:SetText("Match History")
            RegisterTrackedFont(matchHistorySubtitle, 12, "OUTLINE")
            matchHistorySubtitle:SetTextColor(0.70, 0.70, 0.70, 1)

            PVPHUB_SETTINGS.matchHistoryEntries = PVPHUB_SETTINGS.matchHistoryEntries or 1

            local historyLabel = appContent:CreateFontString(nil, "ARTWORK", "GameFontNormal")
            historyLabel:SetPoint("TOPLEFT", matchHistorySubtitle, "BOTTOMLEFT", 0, -8)
            historyLabel:SetText("Entries:")
            historyLabel:SetTextColor(0.85, 0.85, 0.85, 1)

            local historySlider = CreateFrame("Slider", nil, appContent, "MinimalSliderTemplate")
            historySlider:SetPoint("LEFT", historyLabel, "RIGHT", 10, 0)
            historySlider:SetSize(80, 15)
            historySlider:SetMinMaxValues(1, 5)
            historySlider:SetValue(PVPHUB_SETTINGS.matchHistoryEntries)
            historySlider:SetValueStep(1)
            historySlider:SetObeyStepOnDrag(true)

            local historyValue = appContent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
            historyValue:SetPoint("LEFT", historySlider, "RIGHT", 5, 0)
            historyValue:SetText(PVPHUB_SETTINGS.matchHistoryEntries)
            historyValue:SetTextColor(1, 1, 1, 1)

            local isDragging = false
            historySlider:SetScript("OnValueChanged", function(self, value)
                if not value then return end
                local newValue = math.floor(value + 0.5)
                PVPHUB_SETTINGS.matchHistoryEntries = newValue
                historyValue:SetText(newValue)
            end)
            historySlider:SetScript("OnMouseDown", function() isDragging = true end)
            historySlider:SetScript("OnMouseUp", function(self)
                if isDragging then isDragging = false; StaticPopup_Show("PVPHUB_RELOAD_UI") end
            end)
            historySlider:SetScript("OnEnter", function(self)
                GameTooltip:SetOwner(self, "ANCHOR_CURSOR")
                GameTooltip:SetText("Match History Entries", 1, 1, 1)
                GameTooltip:AddLine("Number of matches in bracket tooltips (1-5)", 0.7, 0.7, 0.7, true)
                GameTooltip:AddLine("Requires /reload to apply", 1, 0.8, 0, true)
                GameTooltip:Show()
            end)
            historySlider:SetScript("OnLeave", function() GameTooltip:Hide() end)

            -- Date Format
            local dateFormatLabel = appContent:CreateFontString(nil, "ARTWORK", "GameFontNormal")
            dateFormatLabel:SetPoint("TOPLEFT", historyLabel, "BOTTOMLEFT", 0, -14)
            dateFormatLabel:SetText("Date Format:")
            dateFormatLabel:SetTextColor(0.85, 0.85, 0.85, 1)

            local dateFormatDropdown = CreateFrame("Frame", nil, appContent, "UIDropDownMenuTemplate")
            dateFormatDropdown:SetPoint("TOPLEFT", dateFormatLabel, "BOTTOMLEFT", -15, -3)
            UIDropDownMenu_SetWidth(dateFormatDropdown, 135)
            ApplyModernDropdownStyling(dateFormatDropdown)
            f.dateFormatDropdown = dateFormatDropdown

            if not PVPHUB_SETTINGS.dateFormat or PVPHUB_SETTINGS.dateFormat == "AUTO" then
                local locale = GetLocale()
                if locale == "enUS" or locale == "esMX" then
                    PVPHUB_SETTINGS.dateFormat = "US"
                else
                    PVPHUB_SETTINGS.dateFormat = "EU"
                end
            end
            local dateFormatOptions = {EU = "DD.MM.YY (EU)", US = "MM.DD.YY (US)"}
            UIDropDownMenu_SetText(dateFormatDropdown, dateFormatOptions[PVPHUB_SETTINGS.dateFormat])

            local function OnDateFormatSelect(self)
                PVPHUB_SETTINGS.dateFormat = self.value
                UIDropDownMenu_SetText(dateFormatDropdown, dateFormatOptions[self.value])
                PVPHubPrint("|cffff0000[PVPHUB]|r Date format: " .. dateFormatOptions[self.value])
                StaticPopup_Show("PVPHUB_RELOAD_UI")
            end
            UIDropDownMenu_Initialize(dateFormatDropdown, function(self, level)
                local info    = UIDropDownMenu_CreateInfo()
                info.text     = "DD.MM.YY (EU)"; info.value = "EU"; info.func = OnDateFormatSelect
                info.checked  = PVPHUB_SETTINGS.dateFormat == "EU"
                UIDropDownMenu_AddButton(info)
                info.text     = "MM.DD.YY (US)"; info.value = "US"; info.func = OnDateFormatSelect
                info.checked  = PVPHUB_SETTINGS.dateFormat == "US"
                UIDropDownMenu_AddButton(info)
            end)

            -- Hide Welcome Message checkbox
            local hideWelcomeCheckbox = CreateFrame("CheckButton", nil, appContent, "InterfaceOptionsCheckButtonTemplate")
            hideWelcomeCheckbox:SetPoint("TOPLEFT", dateFormatDropdown, "BOTTOMLEFT", 15, -6)
            hideWelcomeCheckbox.Text:SetText("Hide Welcome Message")
            hideWelcomeCheckbox.tooltipText = "Hide the 'Welcome, Name!' greeting in the Characters tab"
            if not PVPHUB_SETTINGS.mainWindow then PVPHUB_SETTINGS.mainWindow = {} end
            hideWelcomeCheckbox:SetChecked(PVPHUB_SETTINGS.mainWindow.hideWelcomeMessage or false)
            hideWelcomeCheckbox:SetScript("OnClick", function(self)
                PVPHUB_SETTINGS.mainWindow.hideWelcomeMessage = self:GetChecked()
                if f.greeting and f.currentTab == "characters" then
                    if PVPHUB_SETTINGS.mainWindow.hideWelcomeMessage then
                        f.greeting:Hide()
                        if f.titleLine then f.titleLine:Hide() end
                    else
                        f.greeting:Show()
                        if f.titleLine then f.titleLine:Show() end
                    end
                end
            end)

            -- Rounded Frame checkbox
            local roundedFrameCheckbox = CreateFrame("CheckButton", nil, appContent, "InterfaceOptionsCheckButtonTemplate")
            roundedFrameCheckbox:SetPoint("TOPLEFT", hideWelcomeCheckbox, "BOTTOMLEFT", 0, -2)
            roundedFrameCheckbox.Text:SetText("Rounded Frame")
            roundedFrameCheckbox.tooltipText = "Use rounded corners on the main window frame"
            if not PVPHUB_SETTINGS.mainWindow then PVPHUB_SETTINGS.mainWindow = {} end
            if PVPHUB_SETTINGS.mainWindow.roundedFrame == nil then PVPHUB_SETTINGS.mainWindow.roundedFrame = true end
            roundedFrameCheckbox:SetChecked(PVPHUB_SETTINGS.mainWindow.roundedFrame)
            roundedFrameCheckbox:SetScript("OnClick", function(self)
                PVPHUB_SETTINGS.mainWindow.roundedFrame = self:GetChecked() and true or false
                if f.ApplyFrameStyle then f:ApplyFrameStyle() end
            end)

            -- Window Glow checkbox
            local windowGlowCheckbox = CreateFrame("CheckButton", nil, appContent, "InterfaceOptionsCheckButtonTemplate")
            windowGlowCheckbox:SetPoint("TOPLEFT", roundedFrameCheckbox, "BOTTOMLEFT", 0, -2)
            windowGlowCheckbox.Text:SetText("Window Glow")
            windowGlowCheckbox.tooltipText = "Show the soft glow and border outline around the main window's edge"
            if PVPHUB_SETTINGS.mainWindow.showGlow == nil then PVPHUB_SETTINGS.mainWindow.showGlow = true end
            windowGlowCheckbox:SetChecked(PVPHUB_SETTINGS.mainWindow.showGlow)
            windowGlowCheckbox:SetScript("OnClick", function(self)
                PVPHUB_SETTINGS.mainWindow.showGlow = self:GetChecked() and true or false
                ApplyWindowGlowVisibility(f)
            end)

            -- ============================================================
            -- SECTION: ADVANCED
            -- ============================================================
            local sAdv   = MakeSection("advanced",       "ADVANCED",       {0.55, 0.15, 0.15}, "Interface\\Icons\\Trade_Engineering")
            local advContent = sAdv.content

            -- Disable Streamer Mode
            if PVPHUB_SETTINGS.disableStreamerMode == nil then PVPHUB_SETTINGS.disableStreamerMode = false end
            local disableStreamerModeCheckbox = CreateFrame("CheckButton", nil, advContent, "InterfaceOptionsCheckButtonTemplate")
            disableStreamerModeCheckbox:SetPoint("TOPLEFT", advContent, "TOPLEFT", 12, -10)
            disableStreamerModeCheckbox.Text:SetText("Disable Streamer Mode")
            disableStreamerModeCheckbox:SetScript("OnEnter", function(self)
                GameTooltip:SetOwner(self, "ANCHOR_CURSOR")
                GameTooltip:SetText("Disable Streamer Mode", 1, 0.8, 0)
                GameTooltip:AddLine("Prevents the Streamer Mode window from being opened or auto-restored on login", 1, 1, 1, true)
                GameTooltip:AddLine("Hides the Streamer Mode button inside the main window", 0.8, 0.8, 0.8, true)
                GameTooltip:Show()
            end)
            disableStreamerModeCheckbox:SetScript("OnLeave", function() GameTooltip:Hide() end)
            disableStreamerModeCheckbox:SetChecked(PVPHUB_SETTINGS.disableStreamerMode)
            if f.compactToggleBtn then f.compactToggleBtn:SetShown(not PVPHUB_SETTINGS.disableStreamerMode) end
            disableStreamerModeCheckbox:SetScript("OnClick", function(self)
                PVPHUB_SETTINGS.disableStreamerMode = self:GetChecked()
                if f.compactToggleBtn then
                    f.compactToggleBtn:SetShown(not PVPHUB_SETTINGS.disableStreamerMode)
                end
                if PVPHUB_SETTINGS.disableStreamerMode then
                    PVPHUB_SETTINGS.compactWindowStayOpen = false
                    if PVPHUB.compactWindow and PVPHUB.compactWindow:IsShown() then
                        PVPHUB.compactWindow:Hide()
                    end
                end
            end)

            -- Manage Hidden Characters button
            local hiddenCharsButton = CreateFrame("Button", nil, advContent, "UIPanelButtonTemplate")
            hiddenCharsButton:SetSize(190, 25)
            hiddenCharsButton:SetPoint("TOPLEFT", disableStreamerModeCheckbox, "BOTTOMLEFT", 3, -8)
            hiddenCharsButton:SetText("Manage Hidden Characters")
            hiddenCharsButton:SetScript("OnClick", function() ShowHiddenCharactersWindow() end)
            hiddenCharsButton:SetScript("OnEnter", function(self)
                GameTooltip:SetOwner(self, "ANCHOR_CURSOR")
                GameTooltip:SetText("Manage Hidden Characters", 1, 0.8, 0)
                GameTooltip:AddLine("View and unhide characters that are currently hidden", 1, 1, 1, true)
                GameTooltip:Show()
            end)
            hiddenCharsButton:SetScript("OnLeave", function() GameTooltip:Hide() end)

            -- Reset All Data button
            local resetButton = CreateFrame("Button", nil, advContent, "UIPanelButtonTemplate")
            resetButton:SetSize(190, 25)
            resetButton:SetPoint("TOPLEFT", hiddenCharsButton, "BOTTOMLEFT", 0, -5)
            resetButton:SetText("Reset All Data")
            resetButton:GetFontString():SetTextColor(1, 1, 1)
            resetButton:SetScript("OnClick", function() StaticPopup_Show("PVPHUB_RESET_ALL_DATA") end)
            resetButton:SetScript("OnEnter", function(self)
                GameTooltip:SetOwner(self, "ANCHOR_CURSOR")
                GameTooltip:SetText("Reset All Character Data", 1, 0.2, 0.2)
                GameTooltip:AddLine("This will permanently delete ALL character PvP data", 1, 1, 0, true)
                GameTooltip:AddLine("This action cannot be undone!", 1, 0.2, 0.2, true)
                GameTooltip:Show()
            end)
            resetButton:SetScript("OnLeave", function() GameTooltip:Hide() end)
            f.resetButton = resetButton

            -- Developer credit (lives on settingsFrame, always visible below all sections)
            local developerCredit = settingsFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
            developerCredit:SetPoint("TOPLEFT", settingsFrame, "TOPLEFT", 18, -800) -- placeholder; RecalcPositions sets real pos
            developerCredit:SetText("Feedback & Bugreports: twitch.tv/soundzgood  |  Discord: soundz1")
            developerCredit:SetFont("Fonts\\FRIZQT__.TTF", 11, "OUTLINE")
            developerCredit:SetTextColor(0.55, 0.55, 0.60, 1)
            f.developerCredit = developerCredit

            -- ============================================================
            -- LAYOUT: set estimated heights, initial pass, then measure
            -- ============================================================
            -- Visual display order (independent of code order above)
            allSections = {sDisp, sApp, sNotif, sQT, sAdv}

            sDisp.contentHeight  = 185
            sApp.contentHeight   = 245
            sNotif.contentHeight = 75
            sQT.contentHeight    = 215
            sAdv.contentHeight   = 115
            RecalcPositions()

            -- Remeasure after one frame when GetBottom() is valid
            C_Timer.After(0, function()
                local function MeasureHeight(content, lastWidget)
                    local ct = content:GetTop()
                    local wb = lastWidget:GetBottom()
                    if ct and wb then return math.abs(ct - wb) + 14 end
                    return 100
                end
                sDisp.contentHeight  = MeasureHeight(dispContent,  goldThresholdBox)
                sApp.contentHeight   = MeasureHeight(appContent,    windowGlowCheckbox)
                sNotif.contentHeight = MeasureHeight(notifContent,  disablePrintCheckbox)
                sQT.contentHeight    = MeasureHeight(qtContent,     qtPreviewBtn)
                sAdv.contentHeight   = MeasureHeight(advContent,    resetButton)
                RecalcPositions()
            end)

            -- Auto-dismiss queue timer preview when settings panel closes
            settingsFrame:HookScript("OnHide", function()
                if PVPHUB.QueueTimer then PVPHUB.QueueTimer:StopPreview() end
                if f.qtPreviewBtn then f.qtPreviewBtn:SetText("Show Preview") end
            end)

            -- Clear two-column refs (theme code guards each with 'if f.xxx then')
            f.settingsLeftBg  = nil
            f.settingsRightBg = nil
            f.settingsTitle   = nil
            f.styleTitle      = nil

            -- Hide the container initially (not the scroll child)
            settingsContainer:Hide()

            end) -- end pcall(function()

            if buildOk then
                f.settingsFrame = settingsContainer
            else
                settingsContainer:Hide()
                settingsContainer:SetParent(nil)
                PVPHubPrint("|cffff0000[PVPHUB]|r Failed to build the Settings panel: " .. tostring(buildErr) .. ". Try opening Settings again, or /reload if it keeps failing.")
            end

        end
        
        -- Always initialize with CHARACTERS tab (prevents header generation bugs when reopening from settings tab)
        SwitchTab("characters")
        
        closeButton:HookScript("OnClick", function()
            if not PVPHUB_SETTINGS.windowPos then PVPHUB_SETTINGS.windowPos = {} end
            local point, relativeTo, relativePoint, xOfs, yOfs = f:GetPoint()
            PVPHUB_SETTINGS.windowPos = {point=point, relativePoint=relativePoint, x=xOfs, y=yOfs}
        end)
        -- Author credit aligned under the title (locked to Prototyp font with fallback)
        f.author = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        f.author:SetPoint("TOPRIGHT", f.title, "BOTTOMRIGHT", 0, -2)
        f.author:SetText("|cffBBBBBBby soundz|r")
        -- Try to use Prototyp font first, fallback to Friz Quadrata TT - this font is locked and won't change
        local authorFont = "Fonts\\FRIZQT__.TTF" -- Default fallback
        -- Try LibSharedMedia for Prototyp font
        if LibStub then
            local LSM = LibStub("LibSharedMedia-3.0", true)
            if LSM then
                local success, prototypFont = pcall(function() 
                    return LSM:Fetch("font", "Prototyp") 
                end)
                if success and prototypFont then
                    authorFont = prototypFont
                end
            end
        end
        f.author:SetFont(authorFont, 11, "OUTLINE")
        f.author:SetTextColor(0.7, 0.7, 0.7, 1) -- Subtle gray color
        
        -- Add greeting with BattleNet account name - styled as a prominent headline
        f.greeting = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        SafeSetFont(f.greeting, PVPHUB_ResolveFontPath(), (12) + 4, "OUTLINE")
        f.greeting:SetShadowColor(0, 0, 0, 1) -- Stronger shadow for better readability
        f.greeting:SetShadowOffset(2, -2) -- Larger shadow offset for prominence
        
        -- Get BattleNet account name and class color
        local battleTag = select(2, BNGetInfo()) or ""
        local accountName = ""
        if battleTag and battleTag ~= "" then
            -- Extract name part before the # (e.g., "PlayerName#1234" -> "PlayerName")
            accountName = string.match(battleTag, "([^#]+)")
        end
        
        -- Get current character's class color
        local _, class = UnitClass("player")
        local classColor = RAID_CLASS_COLORS[class] or NORMAL_FONT_COLOR
        local colorStr = classColor.colorStr or "ffffffff"
        
        if accountName and accountName ~= "" then
            f.greeting:SetText("|c" .. colorStr .. "Welcome, " .. accountName .. "!|r")
        else
            -- Fallback to character name if BattleTag not available
            local playerName = UnitName("player")
            f.greeting:SetText("|c" .. colorStr .. "Welcome, " .. (playerName or "Champion") .. "!|r")
        end
        
        -- Add a more prominent line under the greeting for headline effect
        local titleLine = f:CreateTexture(nil, "ARTWORK")
        titleLine:SetTexture("Interface\\Buttons\\WHITE8x8")
        titleLine:SetVertexColor(unpack(UI_CONSTANTS.COLORS.ACCENT_LINE))
        titleLine:SetSize(250, 3) -- Increased height from 2 to 3 for more prominence
        f.titleLine = titleLine

        -- ============================================================
        -- STATS TAB — season recap (built lazily on first visit, like Settings)
        -- ============================================================
        -- BRACKET_META / GetSeasonDisplayName / BuildSeasonOverviewData live at
        -- file scope (near GetBracketSeasonSummary) — see the comment there.

        local function CardHeight(rows)
            return 8 + rows * 18 + 14
        end

        -- Wraps a character name in its class color, e.g. for roster rows and
        -- "most played by" callouts. Falls back to the plain name if the
        -- character's class isn't known.
        local function ColorCharName(charKey)
            if not charKey or not PVPHUB_DB then return charKey end
            local data  = PVPHUB_DB[charKey]
            local color = data and RAID_CLASS_COLORS[data.class]
            if color and color.colorStr then
                return "|c" .. color.colorStr .. charKey .. "|r"
            end
            return charKey
        end

        function f:CreateStatsFrame()
            local statsContainer = CreateFrame("Frame", nil, f)
            statsContainer:SetPoint("TOPLEFT", f, "TOPLEFT", 20, -65)
            -- Right inset shrunk from -45: the scrollbar now overlays the
            -- content's own right edge (see ApplyModernScrollbarStyling)
            -- instead of needing a dedicated lane, so this can hug the
            -- window edge like the left side does.
            statsContainer:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -20, 85)

            -- Wrapped in pcall like CreateSettingsFrame: f.statsFrame only gets
            -- assigned on success, so a bad saved variable can't leave a
            -- permanently half-built tab — the next tab click retries the build.
            local buildOk, buildErr = pcall(function()

            -- One-time seed: label whatever season is live right now as
            -- "Midnight Season 1". This only ever fires the very first time this
            -- feature runs (seasonLabels doesn't exist yet), so once the raw season
            -- ID changes later, the new season is NOT auto-relabeled — it shows a
            -- generic "Season <raw id>" until relabeled with /pvphub seasonlabel.
            if not PVPHUB_SETTINGS.seasonLabels then
                PVPHUB_SETTINGS.seasonLabels = {}
                local liveSeason = (C_PvP and C_PvP.GetUIDisplaySeason and C_PvP.GetUIDisplaySeason()) or 0
                if liveSeason > 0 then
                    PVPHUB_SETTINGS.seasonLabels[liveSeason] = "Midnight Season 1"
                end
            end
            PVPHUB_SETTINGS.statsSections = PVPHUB_SETTINGS.statsSections or {}

            -- Forward-declared: AddCard's collapse/expand click handler (defined
            -- further down) needs to trigger a full re-render. Declaring the
            -- local this early lets it capture the same upvalue slot, filled in
            -- once RenderStatsFor itself is defined later in this function.
            local RenderStatsFor

            -- The season name is stated in the personalized headline at the top
            -- of the scroll content (RenderAllCharactersOverview) instead of a
            -- separate persistent banner, to avoid saying it twice.
            -- Small fixed lane for the scrollbar (much slimmer than the old
            -- -25) — it fades to near-invisible when idle (see
            -- ApplyModernScrollbarStyling) but still gets its own space so
            -- it never sits on top of card/tile content.
            local scrollFrame = CreateFrame("ScrollFrame", nil, statsContainer, "ScrollFrameTemplate")
            scrollFrame:SetPoint("TOPLEFT", statsContainer, "TOPLEFT", 0, -4)
            scrollFrame:SetPoint("BOTTOMRIGHT", statsContainer, "BOTTOMRIGHT", -10, 0)
            ApplyModernScrollbarStyling(scrollFrame, UI_CONSTANTS.COLORS, PVPHUB_SCROLLBAR_NUDGE(f))
            scrollFrame:EnableMouseWheel(true)
            scrollFrame:SetScript("OnMouseWheel", function(self, delta)
                local current = self:GetVerticalScroll()
                local maxScroll = self:GetVerticalScrollRange()
                local newScroll = math.max(0, math.min(current - (delta * 20), maxScroll))
                self:SetVerticalScroll(newScroll)
            end)

            local statsScrollChild = CreateFrame("Frame", nil, scrollFrame)
            statsScrollChild:SetSize(750, 800)
            scrollFrame:SetScrollChild(statsScrollChild)
            scrollFrame:SetScript("OnSizeChanged", function(self, w, _)
                statsScrollChild:SetWidth(w)
            end)
            f.statsScrollFrame = scrollFrame

            -- Everything created per-render, torn down at the start of the next one.
            local cardWidgets = {}

            -- Colored header bar + body frame, mirroring the Settings tab's
            -- collapsible section look. sectionKey is a stable per-card id used
            -- to persist expand/collapse state across renders and reopens.
            -- Returns the body frame and the total vertical space consumed
            -- (header + body + gap, or just header + gap when collapsed) so the
            -- caller can stack the next card.
            local function AddCard(yPos, title, colorRGB, iconPath, bodyHeight, sectionKey)
                local expanded = (PVPHUB_SETTINGS.statsSections[sectionKey] ~= false)

                local header = CreateFrame("Button", nil, statsScrollChild, "BackdropTemplate")
                header:SetHeight(26)
                header:SetPoint("TOPLEFT",  statsScrollChild, "TOPLEFT",  0, yPos)
                header:SetPoint("TOPRIGHT", statsScrollChild, "TOPRIGHT", -20, yPos)
                header:SetBackdrop({
                    bgFile   = "Interface\\Buttons\\WHITE8x8",
                    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
                    tile = false, tileSize = 16, edgeSize = 8,
                    insets = {left=2, right=2, top=2, bottom=2},
                })
                header:SetBackdropColor(0, 0, 0, 0)
                header:SetBackdropBorderColor(colorRGB[1]*0.40, colorRGB[2]*0.40, colorRGB[3]*0.40, 0.35)

                local gradTex = header:CreateTexture(nil, "BACKGROUND")
                gradTex:SetAllPoints(header)
                gradTex:SetTexture("Interface\\Buttons\\WHITE8x8")
                local function ApplyGradient(hovered)
                    local mul = hovered and 0.75 or 0.55
                    local mul2 = hovered and 0.25 or 0.15
                    gradTex:SetGradient("HORIZONTAL",
                        CreateColor(colorRGB[1]*mul, colorRGB[2]*mul, colorRGB[3]*mul, hovered and 0.97 or 0.92),
                        CreateColor(colorRGB[1]*mul2, colorRGB[2]*mul2, colorRGB[3]*mul2, hovered and 0.70 or 0.60))
                end
                ApplyGradient(false)
                header:SetScript("OnEnter", function() ApplyGradient(true) end)
                header:SetScript("OnLeave", function() ApplyGradient(false) end)

                local iconTex = header:CreateTexture(nil, "OVERLAY")
                iconTex:SetSize(18, 18)
                iconTex:SetPoint("LEFT", header, "LEFT", 8, 0)
                iconTex:SetTexture(iconPath)
                iconTex:SetTexCoord(0.08, 0.92, 0.08, 0.92)
                iconTex:SetVertexColor(1, 1, 1, 0.85)

                local titleText = header:CreateFontString(nil, "OVERLAY", "GameFontNormal")
                titleText:SetPoint("LEFT", iconTex, "RIGHT", 7, 0)
                RegisterTrackedFont(titleText, 13, "OUTLINE")
                titleText:SetText(title)
                titleText:SetTextColor(1, 1, 1, 1)

                local arrowText = header:CreateFontString(nil, "OVERLAY", "GameFontNormal")
                arrowText:SetPoint("LEFT", titleText, "RIGHT", 8, 0)
                RegisterTrackedFont(arrowText, 11, "OUTLINE")
                arrowText:SetText(expanded and CreateAtlasMarkup("auctionhouse-ui-sortarrow", 10, 10) or CreateAtlasMarkup("common-icon-forwardarrow", 8, 13))
                arrowText:SetTextColor(1, 1, 1, 0.65)

                local body = CreateFrame("Frame", nil, statsScrollChild, "BackdropTemplate")
                body:SetPoint("TOPLEFT",  header, "BOTTOMLEFT",  0, 0)
                body:SetPoint("TOPRIGHT", header, "BOTTOMRIGHT", 0, 0)
                body:SetHeight(bodyHeight)
                body:SetBackdrop({
                    bgFile   = "Interface\\Buttons\\WHITE8x8",
                    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
                    tile = false, tileSize = 16, edgeSize = 8,
                    insets = {left=2, right=2, top=2, bottom=2},
                })
                body:SetBackdropColor(0.11, 0.09, 0.13, 0.72)
                body:SetBackdropBorderColor(colorRGB[1]*0.45, colorRGB[2]*0.45, colorRGB[3]*0.45, 0.55)

                local stripe = body:CreateTexture(nil, "BORDER")
                stripe:SetTexture("Interface\\Buttons\\WHITE8x8")
                stripe:SetVertexColor(colorRGB[1], colorRGB[2], colorRGB[3], 0.85)
                stripe:SetPoint("TOPLEFT",    body, "TOPLEFT",    3, -3)
                stripe:SetPoint("BOTTOMLEFT", body, "BOTTOMLEFT", 3,  3)
                stripe:SetWidth(3)

                if not expanded then
                    body:Hide()
                end

                header:SetScript("OnClick", function()
                    PVPHUB_SETTINGS.statsSections[sectionKey] = not expanded
                    RenderStatsFor()
                end)

                table.insert(cardWidgets, header)
                table.insert(cardWidgets, body)

                local consumed = expanded and (26 + bodyHeight + 10) or (26 + 8)
                return body, consumed
            end

            local function AddRow(body, rowYPos, label, value, valueColor)
                local l = body:CreateFontString(nil, "OVERLAY", "GameFontNormal")
                l:SetPoint("TOPLEFT", body, "TOPLEFT", 14, rowYPos)
                RegisterTrackedFont(l, 12, "")
                l:SetTextColor(0.75, 0.75, 0.75, 1)
                l:SetText(label)

                local v = body:CreateFontString(nil, "OVERLAY", "GameFontNormal")
                -- Bounded on both sides (label's right edge <-> body's right
                -- edge) so a long value (e.g. "Most Played By" char-realm
                -- names) wraps instead of running into the label text.
                v:SetPoint("TOPRIGHT", body, "TOPRIGHT", -14, rowYPos)
                v:SetPoint("TOPLEFT", l, "TOPRIGHT", 8, 0)
                v:SetJustifyH("RIGHT")
                v:SetWordWrap(true)
                RegisterTrackedFont(v, 12, "OUTLINE")
                v:SetTextColor(unpack(valueColor or {1, 1, 1, 1}))
                v:SetText(value)

                table.insert(cardWidgets, l)
                table.insert(cardWidgets, v)
            end

            -- Row of big "hero" KPI tiles for the dashboard-style Overview —
            -- distinct from AddCard/AddRow's stacked label/value look, meant to
            -- read at a glance like a summary dashboard rather than a settings list.
            -- tiles: array of { label, value, color, sub (optional) }.
            local function AddHeroTiles(yPos, tiles)
                local containerWidth = statsScrollChild:GetWidth()
                if not containerWidth or containerWidth < 100 then containerWidth = 650 end
                local gap = 8
                local n = #tiles
                local tileWidth = (containerWidth - gap * (n - 1)) / n
                local tileHeight = 80 -- extra room vs. the old 68 so a long sub-line (char-realm names) can wrap to 2 lines instead of overflowing sideways

                for i, tile in ipairs(tiles) do
                    local xOffset = (i - 1) * (tileWidth + gap)

                    local tileFrame = CreateFrame("Frame", nil, statsScrollChild, "BackdropTemplate")
                    tileFrame:SetSize(tileWidth, tileHeight)
                    tileFrame:SetPoint("TOPLEFT", statsScrollChild, "TOPLEFT", xOffset, yPos)
                    tileFrame:SetBackdrop({
                        bgFile   = "Interface\\Buttons\\WHITE8x8",
                        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
                        tile = false, tileSize = 16, edgeSize = 8,
                        insets = {left=2, right=2, top=2, bottom=2},
                    })
                    tileFrame:SetBackdropColor(0.11, 0.09, 0.13, 0.78)
                    tileFrame:SetBackdropBorderColor(tile.color[1]*0.5, tile.color[2]*0.5, tile.color[3]*0.5, 0.6)

                    local topStripe = tileFrame:CreateTexture(nil, "BORDER")
                    topStripe:SetTexture("Interface\\Buttons\\WHITE8x8")
                    topStripe:SetVertexColor(tile.color[1], tile.color[2], tile.color[3], 0.9)
                    topStripe:SetPoint("TOPLEFT",  tileFrame, "TOPLEFT",  2, -2)
                    topStripe:SetPoint("TOPRIGHT", tileFrame, "TOPRIGHT", -2, -2)
                    topStripe:SetHeight(3)

                    local valueText = tileFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
                    valueText:SetPoint("TOP", tileFrame, "TOP", 0, -15)
                    RegisterTrackedFont(valueText, 20, "OUTLINE")
                    valueText:SetTextColor(unpack(tile.color))
                    valueText:SetText(tile.value)

                    local labelText = tileFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
                    labelText:SetPoint("TOP", valueText, "BOTTOM", 0, -4)
                    RegisterTrackedFont(labelText, 10, "")
                    labelText:SetTextColor(0.75, 0.75, 0.75, 1)
                    labelText:SetText(tile.label)

                    table.insert(cardWidgets, tileFrame)
                    table.insert(cardWidgets, topStripe)
                    table.insert(cardWidgets, valueText)
                    table.insert(cardWidgets, labelText)

                    if tile.sub then
                        local subText = tileFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
                        subText:SetPoint("TOP", labelText, "BOTTOM", 0, -2)
                        -- Width + wrap so a long char-realm name wraps onto a
                        -- second line inside the tile instead of overflowing
                        -- past its edges into neighboring tiles.
                        subText:SetWidth(tileWidth - 10)
                        subText:SetWordWrap(true)
                        RegisterTrackedFont(subText, 9, "")
                        subText:SetTextColor(0.55, 0.55, 0.55, 1)
                        subText:SetText(tile.sub)
                        table.insert(cardWidgets, subText)
                    end
                end

                return tileHeight + 12
            end

            -- Row of three equal-width "progress" tiles for the season titles
            -- (Legend/Strategist/Gladiator) — same boxed look as AddHeroTiles,
            -- plus a color-banded fill bar (red <25%, orange <50%, yellow <75%,
            -- green >=75% of the required win count) so a multi-alt player can
            -- see how close the leading character is at a glance. Once earned,
            -- the tile switches to a gold "Earned!" state with the win date.
            -- Wrapped in its own gold-framed panel (background tint + glow +
            -- header label) so it reads as a featured section rather than
            -- blending into the plain KPI tile rows around it.
            local function AddTitleProgressTiles(yPos, titleData)
                local containerWidth = statsScrollChild:GetWidth()
                if not containerWidth or containerWidth < 100 then containerWidth = 650 end
                local pad        = 10
                local headerH    = 20
                local gap        = 8
                local n          = #TITLE_META
                local tileHeight = 104
                local innerWidth = containerWidth - pad * 2
                local tileWidth  = (innerWidth - gap * (n - 1)) / n
                local panelHeight = pad + headerH + tileHeight + pad

                local panel = CreateFrame("Frame", nil, statsScrollChild, "BackdropTemplate")
                panel:SetSize(containerWidth, panelHeight)
                panel:SetPoint("TOPLEFT", statsScrollChild, "TOPLEFT", 0, yPos)
                panel:SetBackdrop({
                    bgFile   = "Interface\\Buttons\\WHITE8x8",
                    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
                    tile = false, tileSize = 16, edgeSize = 12,
                    insets = {left=3, right=3, top=3, bottom=3},
                })
                panel:SetBackdropColor(0.18, 0.13, 0.02, 0.55)
                panel:SetBackdropBorderColor(1, 0.82, 0, 0.55)

                local glow = panel:CreateTexture(nil, "BACKGROUND")
                glow:SetPoint("TOPLEFT",     panel, "TOPLEFT",  3, -3)
                glow:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -3, 3)
                glow:SetTexture("Interface\\Buttons\\WHITE8x8")
                glow:SetGradient("VERTICAL", CreateColor(1, 0.82, 0, 0.12), CreateColor(1, 0.82, 0, 0))

                local header = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
                header:SetPoint("TOP", panel, "TOP", 0, -pad + 2)
                RegisterTrackedFont(header, 13, "OUTLINE")
                header:SetTextColor(1, 0.82, 0, 1)
                header:SetText("Season Titles")

                table.insert(cardWidgets, panel)
                table.insert(cardWidgets, glow)
                table.insert(cardWidgets, header)

                local function BarColor(pct)
                    if pct >= 0.75 then return 0.20, 0.80, 0.25
                    elseif pct >= 0.50 then return 0.90, 0.80, 0.10
                    elseif pct >= 0.25 then return 0.95, 0.55, 0.10
                    else return 0.85, 0.20, 0.20 end
                end

                -- Rounded "pill" bar: 2 circular end-caps + a flat middle,
                -- instead of a StatusBar + stretched rounded_mask.tga.
                -- rounded_mask.tga is proportioned for large square-ish
                -- elements (windows/cards) — its corner radius is nowhere
                -- near 50% of its own size, so stretched over a 10px-tall
                -- bar the radius shrinks to sub-pixel and vanishes entirely.
                -- A CIRCLE mask kept perfectly square (capSize x capSize,
                -- never non-uniformly stretched) gives a true semicircle cap
                -- at any bar width. Returns (container, SetFill) — SetFill
                -- resizes/colors the fill live as progress changes.
                local CAP_MASK = "Interface\\CHARACTERFRAME\\TempPortraitAlphaMask"
                local function CreateCapsuleBar(parent, width, height)
                    local capSize = height
                    local container = CreateFrame("Frame", nil, parent)
                    container:SetSize(width, height)

                    local function MakeCap()
                        local cap = container:CreateTexture(nil, "ARTWORK")
                        cap:SetSize(capSize, capSize)
                        cap:SetTexture("Interface\\Buttons\\WHITE8x8")
                        local mask = container:CreateMaskTexture()
                        mask:SetTexture(CAP_MASK, "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
                        mask:SetAllPoints(cap)
                        cap:AddMaskTexture(mask)
                        return cap
                    end

                    local leftCap  = MakeCap()
                    local rightCap = MakeCap()
                    leftCap:SetPoint("TOPLEFT", container, "TOPLEFT", 0, 0)

                    local mid = container:CreateTexture(nil, "ARTWORK")
                    mid:SetHeight(height)
                    mid:SetTexture("Interface\\Buttons\\WHITE8x8")

                    local function SetFill(px, r, g, b, a)
                        px = math.max(0, math.min(px, width))
                        leftCap:SetVertexColor(r, g, b, a)
                        rightCap:SetVertexColor(r, g, b, a)
                        mid:SetVertexColor(r, g, b, a)
                        if px <= 0 then
                            leftCap:Hide(); rightCap:Hide(); mid:Hide()
                            return
                        end
                        leftCap:Show()
                        if px <= capSize then
                            -- Too narrow yet for two full caps + a straight
                            -- middle — show just the left cap so the bar
                            -- never looks broken at very low progress.
                            rightCap:Hide()
                            mid:Hide()
                        else
                            rightCap:Show()
                            rightCap:ClearAllPoints()
                            rightCap:SetPoint("TOPLEFT", container, "TOPLEFT", px - capSize, 0)
                            mid:ClearAllPoints()
                            mid:SetPoint("TOPLEFT", container, "TOPLEFT", capSize / 2, 0)
                            mid:SetWidth(px - capSize)
                            mid:Show()
                        end
                    end

                    return container, SetFill
                end

                for i, meta in ipairs(TITLE_META) do
                    local tp = titleData[meta.key] or { current = 0, required = 0 }
                    local xOffset = (i - 1) * (tileWidth + gap)

                    local tileFrame = CreateFrame("Frame", nil, panel, "BackdropTemplate")
                    tileFrame:SetSize(tileWidth, tileHeight)
                    tileFrame:SetPoint("TOPLEFT", panel, "TOPLEFT", pad + xOffset, -(pad + headerH))
                    tileFrame:SetBackdrop({
                        bgFile   = "Interface\\Buttons\\WHITE8x8",
                        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
                        tile = false, tileSize = 16, edgeSize = 8,
                        insets = {left=2, right=2, top=2, bottom=2},
                    })
                    tileFrame:SetBackdropColor(0.11, 0.09, 0.13, 0.78)
                    tileFrame:SetBackdropBorderColor(meta.color[1]*0.5, meta.color[2]*0.5, meta.color[3]*0.5, 0.6)

                    local topStripe = tileFrame:CreateTexture(nil, "BORDER")
                    topStripe:SetTexture("Interface\\Buttons\\WHITE8x8")
                    topStripe:SetVertexColor(meta.color[1], meta.color[2], meta.color[3], 0.9)
                    topStripe:SetPoint("TOPLEFT",  tileFrame, "TOPLEFT",  2, -2)
                    topStripe:SetPoint("TOPRIGHT", tileFrame, "TOPRIGHT", -2, -2)
                    topStripe:SetHeight(3)

                    -- "Track" checkbox — surfaces this title's progress in a
                    -- small floating overlay (PVPHUB:UpdateTitleTracker) that
                    -- can be dragged anywhere on screen, so it stays visible
                    -- outside the main window without needing it open.
                    PVPHUB_SETTINGS.trackedTitles = PVPHUB_SETTINGS.trackedTitles or {}
                    local trackCheckbox = CreateFrame("CheckButton", nil, tileFrame, "UICheckButtonTemplate")
                    trackCheckbox:SetSize(16, 16)
                    trackCheckbox:SetPoint("TOPRIGHT", tileFrame, "TOPRIGHT", -3, -6)
                    trackCheckbox:SetFrameLevel(tileFrame:GetFrameLevel() + 2)
                    trackCheckbox:SetChecked(PVPHUB_SETTINGS.trackedTitles[meta.key])
                    trackCheckbox:SetScript("OnClick", function(self)
                        PVPHUB_SETTINGS.trackedTitles[meta.key] = self:GetChecked() and true or nil
                        if PVPHUB.UpdateTitleTracker then PVPHUB:UpdateTitleTracker() end
                    end)
                    trackCheckbox:SetScript("OnEnter", function(self)
                        GameTooltip:SetOwner(self, "ANCHOR_TOP")
                        GameTooltip:ClearLines()
                        GameTooltip:AddLine("Track in floating overlay", 1, 1, 1)
                        GameTooltip:AddLine("Shows this title's progress in a small\nmovable window, even with PVP HUB closed.", 0.7, 0.7, 0.7, true)
                        GameTooltip:Show()
                    end)
                    trackCheckbox:SetScript("OnLeave", function() GameTooltip:Hide() end)

                    -- Real achievement icon once titleProgress has synced; the
                    -- bracket's generic icon is shown as a placeholder until then.
                    local iconTex = tileFrame:CreateTexture(nil, "ARTWORK")
                    iconTex:SetSize(18, 18)
                    iconTex:SetPoint("TOP", tileFrame, "TOP", 0, -8)
                    iconTex:SetTexCoord(0.08, 0.92, 0.08, 0.92)
                    iconTex:SetTexture(tp.icon or meta.icon)

                    local nameText = tileFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
                    nameText:SetPoint("TOP", tileFrame, "TOP", 0, -29)
                    RegisterTrackedFont(nameText, 12, "OUTLINE")
                    nameText:SetTextColor(1, 1, 1, 1)
                    nameText:SetText(meta.name)

                    local valueText = tileFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
                    valueText:SetPoint("TOP", tileFrame, "TOP", 0, -46)
                    RegisterTrackedFont(valueText, 16, "OUTLINE")

                    local subText = tileFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
                    subText:SetPoint("TOP", tileFrame, "TOP", 0, -85)
                    subText:SetWidth(tileWidth - 12)
                    -- Wrap (not clip) long char-realm names: SetWordWrap(false)
                    -- doesn't actually clip a FontString's rendering to its set
                    -- width, so a long name would still overflow past the tile.
                    subText:SetWordWrap(true)
                    RegisterTrackedFont(subText, 9, "")
                    subText:SetTextColor(0.65, 0.65, 0.65, 1)

                    local barWidth = tileWidth - 16 -- 8px padding each side, matches the old barBG footprint

                    local trackContainer, SetTrackFill = CreateCapsuleBar(tileFrame, barWidth, 10)
                    trackContainer:SetPoint("TOPLEFT", tileFrame, "TOPLEFT", 8, -69)
                    SetTrackFill(barWidth, 0, 0, 0, 0.5) -- static, always full width, dark

                    local fillContainer, SetBarFill = CreateCapsuleBar(tileFrame, barWidth, 10)
                    fillContainer:SetPoint("TOPLEFT", tileFrame, "TOPLEFT", 8, -69)
                    fillContainer:SetFrameLevel(trackContainer:GetFrameLevel() + 1)

                    if tp.earned then
                        valueText:SetTextColor(1, 0.82, 0, 1)
                        valueText:SetText("Earned!")
                        SetBarFill(barWidth, 1, 0.82, 0, 1)
                        local who = tp.earnedChar and ColorCharName(tp.earnedChar) or ""
                        subText:SetText(who .. (tp.earnedDate and ("  " .. tp.earnedDate) or ""))
                    else
                        local required = (tp.required and tp.required > 0) and tp.required or 1
                        local current  = math.min(tp.current or 0, required)
                        local pct      = current / required
                        valueText:SetTextColor(1, 1, 1, 1)
                        valueText:SetText((tp.required and tp.required > 0)
                                           and (current .. "/" .. tp.required)
                                           or "—")
                        local cr, cg, cb = BarColor(pct)
                        SetBarFill(barWidth * pct, cr, cg, cb, 1)
                        subText:SetText(tp.closestChar and ColorCharName(tp.closestChar) or "No progress yet")
                    end

                    -- Mouseover tooltip: the requirement text (built from
                    -- TITLE_META's hardcoded template, not the flaky
                    -- GetAchievementInfo description field — see
                    -- GetTitleRequirementText) and reward. Plain text only —
                    -- no progress numbers, no earned/closest-character status
                    -- (that lives on the tile itself, not the tooltip).
                    tileFrame:EnableMouse(true)
                    tileFrame:SetScript("OnEnter", function(self)
                        GameTooltip:SetOwner(self, "ANCHOR_TOP")
                        GameTooltip:ClearLines()
                        GameTooltip:AddLine(meta.name, 1, 0.82, 0)
                        local reqText = GetTitleRequirementText(meta, tp)
                        if reqText then
                            GameTooltip:AddLine(reqText, 0.9, 0.9, 0.9, true)
                        end
                        if meta.rewardText and meta.rewardText ~= "" then
                            GameTooltip:AddLine(" ")
                            GameTooltip:AddLine("Reward: " .. meta.rewardText, 0.55, 0.80, 1, true)
                        end
                        GameTooltip:Show()
                    end)
                    tileFrame:SetScript("OnLeave", function() GameTooltip:Hide() end)

                    table.insert(cardWidgets, tileFrame)
                    table.insert(cardWidgets, topStripe)
                    table.insert(cardWidgets, trackCheckbox)
                    table.insert(cardWidgets, iconTex)
                    table.insert(cardWidgets, nameText)
                    table.insert(cardWidgets, valueText)
                    table.insert(cardWidgets, subText)
                    table.insert(cardWidgets, trackContainer)
                    table.insert(cardWidgets, fillContainer)
                end

                return panelHeight + 14
            end

            -- Row of boxed tiles — same visual language as AddHeroTiles (backdrop
            -- box, colored top stripe) but left-aligned and built for either:
            --   tile.icons = { {icon=, count=}, ... }  → a row of icons with small
            --                count badges (used for the class breakdown, where a
            --                single text string reads as a chaotic run-on list)
            --   tile.value (+ optional tile.icon)      → one icon plus word-wrapped
            --                text (used for Most Played Class/Spec)
            local function AddInfoTiles(yPos, tiles)
                local containerWidth = statsScrollChild:GetWidth()
                if not containerWidth or containerWidth < 100 then containerWidth = 650 end
                local gap = 8
                local n = #tiles
                local tileWidth = (containerWidth - gap * (n - 1)) / n
                -- Icon-row tiles (label + a line of class icons beneath it) need
                -- more vertical room than the plain label+value tiles, or the
                -- icon row spills past the bottom border. Icons wrap after 4
                -- per row, so a 5th+ icon needs an extra row of height too.
                local iconsPerRow = 4
                local maxIconRows = 0
                local hasSubLine = false
                for _, tile in ipairs(tiles) do
                    if tile.icons and #tile.icons > 0 then
                        local rows = math.ceil(#tile.icons / iconsPerRow)
                        if rows > maxIconRows then maxIconRows = rows end
                    elseif tile.icon and tile.sub then
                        hasSubLine = true
                    end
                end
                local tileHeight = 56
                if maxIconRows > 0 then
                    tileHeight = 68 + (maxIconRows - 1) * 28
                elseif hasSubLine then
                    tileHeight = 68
                end

                for i, tile in ipairs(tiles) do
                    local xOffset = (i - 1) * (tileWidth + gap)

                    local tileFrame = CreateFrame("Frame", nil, statsScrollChild, "BackdropTemplate")
                    tileFrame:SetSize(tileWidth, tileHeight)
                    tileFrame:SetPoint("TOPLEFT", statsScrollChild, "TOPLEFT", xOffset, yPos)
                    tileFrame:SetBackdrop({
                        bgFile   = "Interface\\Buttons\\WHITE8x8",
                        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
                        tile = false, tileSize = 16, edgeSize = 8,
                        insets = {left=2, right=2, top=2, bottom=2},
                    })
                    tileFrame:SetBackdropColor(0.11, 0.09, 0.13, 0.78)
                    tileFrame:SetBackdropBorderColor(tile.color[1]*0.5, tile.color[2]*0.5, tile.color[3]*0.5, 0.6)

                    local topStripe = tileFrame:CreateTexture(nil, "BORDER")
                    topStripe:SetTexture("Interface\\Buttons\\WHITE8x8")
                    topStripe:SetVertexColor(tile.color[1], tile.color[2], tile.color[3], 0.9)
                    topStripe:SetPoint("TOPLEFT",  tileFrame, "TOPLEFT",  2, -2)
                    topStripe:SetPoint("TOPRIGHT", tileFrame, "TOPRIGHT", -2, -2)
                    topStripe:SetHeight(3)

                    local labelText = tileFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
                    labelText:SetPoint("TOPLEFT", tileFrame, "TOPLEFT", 10, -11)
                    RegisterTrackedFont(labelText, 10, "")
                    labelText:SetTextColor(0.65, 0.65, 0.65, 1)
                    labelText:SetText(tile.label)

                    table.insert(cardWidgets, tileFrame)
                    table.insert(cardWidgets, topStripe)
                    table.insert(cardWidgets, labelText)

                    if tile.icons and #tile.icons > 0 then
                        local iconSize, xCursor, yCursor = 22, 0, 0
                        for iconIdx, entry in ipairs(tile.icons) do
                            if iconIdx > 1 and (iconIdx - 1) % iconsPerRow == 0 then
                                xCursor = 0
                                yCursor = yCursor - (iconSize + 6)
                            end
                            local iconTex = tileFrame:CreateTexture(nil, "ARTWORK")
                            iconTex:SetSize(iconSize, iconSize)
                            iconTex:SetPoint("TOPLEFT", labelText, "BOTTOMLEFT", xCursor, yCursor - 6)
                            if entry.icon then
                                iconTex:SetTexture(entry.icon)
                                iconTex:SetTexCoord(0.08, 0.92, 0.08, 0.92)
                            end
                            table.insert(cardWidgets, iconTex)

                            if entry.count and entry.count > 1 then
                                local countText = tileFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
                                countText:SetPoint("BOTTOMRIGHT", iconTex, "BOTTOMRIGHT", 3, -2)
                                RegisterTrackedFont(countText, 10, "OUTLINE")
                                countText:SetTextColor(1, 0.9, 0.3, 1)
                                countText:SetShadowColor(0, 0, 0, 1)
                                countText:SetShadowOffset(1, -1)
                                countText:SetText(tostring(entry.count))
                                table.insert(cardWidgets, countText)
                            end

                            -- Invisible mouse-catcher over the icon (Textures can't
                            -- take OnEnter/OnLeave) — hover to see which characters
                            -- are that class.
                            if entry.chars and #entry.chars > 0 then
                                local hitbox = CreateFrame("Frame", nil, tileFrame)
                                hitbox:SetAllPoints(iconTex)
                                hitbox:EnableMouse(true)
                                hitbox:SetScript("OnEnter", function(self)
                                    GameTooltip:SetOwner(self, "ANCHOR_TOP")
                                    GameTooltip:SetText(entry.label or "Class", 1, 1, 1)
                                    local c = entry.color
                                    for _, memberCharKey in ipairs(entry.chars) do
                                        if c then
                                            GameTooltip:AddLine(memberCharKey, c.r, c.g, c.b)
                                        else
                                            GameTooltip:AddLine(memberCharKey, 0.85, 0.85, 0.85)
                                        end
                                    end
                                    GameTooltip:Show()
                                end)
                                hitbox:SetScript("OnLeave", function() GameTooltip:Hide() end)
                                table.insert(cardWidgets, hitbox)
                            end

                            xCursor = xCursor + iconSize + 8
                        end
                    elseif tile.icon then
                        local iconTex = tileFrame:CreateTexture(nil, "ARTWORK")
                        iconTex:SetSize(24, 24)
                        iconTex:SetPoint("TOPLEFT", labelText, "BOTTOMLEFT", 0, -6)
                        iconTex:SetTexture(tile.icon)
                        iconTex:SetTexCoord(0.08, 0.92, 0.08, 0.92)
                        table.insert(cardWidgets, iconTex)

                        local valueText = tileFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
                        if tile.sub then
                            valueText:SetPoint("TOPLEFT", iconTex, "TOPRIGHT", 6, -2)
                        else
                            valueText:SetPoint("LEFT", iconTex, "RIGHT", 6, 0)
                        end
                        valueText:SetPoint("RIGHT", tileFrame, "RIGHT", -8, 0)
                        valueText:SetJustifyH("LEFT")
                        RegisterTrackedFont(valueText, 11, "OUTLINE")
                        valueText:SetTextColor(1, 1, 1, 1)
                        valueText:SetWordWrap(true)
                        valueText:SetText(tile.value)
                        table.insert(cardWidgets, valueText)

                        if tile.sub then
                            local subText = tileFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
                            subText:SetPoint("TOPLEFT", valueText, "BOTTOMLEFT", 0, -2)
                            subText:SetPoint("RIGHT",   tileFrame, "RIGHT", -8, 0)
                            subText:SetJustifyH("LEFT")
                            RegisterTrackedFont(subText, 9, "")
                            subText:SetTextColor(0.65, 0.65, 0.65, 1)
                            subText:SetWordWrap(true)
                            subText:SetText(tile.sub)
                            table.insert(cardWidgets, subText)
                        end
                    else
                        local valueText = tileFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
                        valueText:SetPoint("TOPLEFT",  labelText, "BOTTOMLEFT", 0, -4)
                        valueText:SetPoint("RIGHT",    tileFrame, "RIGHT", -10, 0)
                        valueText:SetJustifyH("LEFT")
                        RegisterTrackedFont(valueText, 12, "OUTLINE")
                        valueText:SetTextColor(1, 1, 1, 1)
                        valueText:SetWordWrap(true)
                        valueText:SetText(tile.value)
                        table.insert(cardWidgets, valueText)
                    end
                end

                return tileHeight + 10
            end

            -- CharacterHasStatsData / GetStatsCharacterList / BuildSeasonOverviewData
            -- now live at file scope (near GetBracketSeasonSummary) — see the
            -- comment there. They're used here as plain upvalues.

            -- Widget-building only — takes a data table built by
            -- BuildSeasonOverviewData plus a season label, and lays out the
            -- dashboard for the live, current season.
            local function RenderSeasonOverview(overviewData, seasonLabel)
                for _, w in ipairs(cardWidgets) do
                    w:Hide()
                    w:SetParent(nil)
                end
                cardWidgets = {}

                local yPos = 0

                -- Personalized headline: "This is your Midnight Season 1, Name!"
                -- Pulls the BattleTag name (falling back to the character name,
                -- same fallback order as the Characters tab's own greeting),
                -- colored in the current character's class color.
                local battleTag   = select(2, BNGetInfo()) or ""
                local displayName = (battleTag ~= "" and string.match(battleTag, "([^#]+)")) or nil
                if not displayName or displayName == "" then
                    displayName = UnitName("player") or "Champion"
                end
                local _, playerClass = UnitClass("player")
                local nameColor    = RAID_CLASS_COLORS[playerClass] or NORMAL_FONT_COLOR
                local nameColorStr = nameColor.colorStr or "ffffffff"

                local introText = statsScrollChild:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
                introText:SetPoint("TOP", statsScrollChild, "TOP", 0, yPos)
                introText:SetJustifyH("CENTER")
                RegisterTrackedFont(introText, 16, "OUTLINE")
                introText:SetText("|cffff8800[BETA]|r This is your " .. seasonLabel .. ", |c" .. nameColorStr .. displayName .. "|r!")
                table.insert(cardWidgets, introText)
                yPos = yPos - 20

                local disclaimerText = statsScrollChild:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
                disclaimerText:SetPoint("TOP", statsScrollChild, "TOP", 0, yPos)
                disclaimerText:SetWidth(600)
                disclaimerText:SetWordWrap(true)
                disclaimerText:SetJustifyH("CENTER")
                -- PVPHUB only starts recording matches once it's installed, so anyone
                -- who picked it up mid-season will be missing earlier games from this
                -- season — call that out here rather than let the numbers look "wrong".
                disclaimerText:SetText("Note: PVPHUB only tracks matches played since it was installed — if you installed mid-season, earlier games this season won't be included.")
                disclaimerText:SetTextColor(0.6, 0.6, 0.6, 1)
                table.insert(cardWidgets, disclaimerText)
                yPos = yPos - 34

                -- Season title progress — one row of three equal-width tiles
                -- (Legend/Strategist/Gladiator), placed first and set apart in
                -- its own gold-framed panel so it reads as the featured section
                -- rather than just another row of KPI tiles. Shows the earning
                -- character + date once earned; otherwise the account's closest
                -- character and a color-banded fill bar.
                do
                    local consumed = AddTitleProgressTiles(yPos, overviewData.titleProgress)
                    yPos = yPos - consumed
                end

                -- Hero KPI tile row — the dashboard's headline numbers -------------
                do
                    local winPct = overviewData.totalGames > 0 and (overviewData.totalWon / overviewData.totalGames * 100) or 0
                    local consumed = AddHeroTiles(yPos, {
                        { label = "Total Games Played", value = tostring(overviewData.totalGames),
                          color = {0.35, 0.70, 1.00} },
                        { label = "Combined Win Rate",  value = string.format("%.0f%%", winPct),
                          sub = string.format("%d - %d", overviewData.totalWon, overviewData.totalLost),
                          color = {0.40, 0.85, 0.50} },
                        { label = "Highest Rating",      value = overviewData.bestRatingChar and tostring(overviewData.bestRating) or "—",
                          sub = overviewData.bestRatingChar and (ColorCharName(overviewData.bestRatingChar) .. " — " .. overviewData.bestRatingBracket) or nil,
                          color = {1.00, 0.82, 0.20} },
                        { label = "Characters Tracked", value = tostring(overviewData.charCount),
                          color = {0.75, 0.55, 1.00} },
                    })
                    yPos = yPos - consumed
                end

                -- Roster composition tiles — same boxed look as the hero tiles
                -- above, always visible (no card chrome, no collapse) so it reads
                -- at a glance alongside the headline numbers.
                do
                    local consumed = AddInfoTiles(yPos, {
                        { label = "Class Breakdown",   icons = overviewData.classBreakdownIcons, color = {0.55, 0.35, 0.85} },
                        { label = "Most Played Class", value = overviewData.mostPlayedClassStr,  sub = overviewData.mostPlayedClassSub,  icon = overviewData.mostPlayedClassIcon, color = {0.85, 0.55, 0.25} },
                        { label = "Most Played Spec",  value = overviewData.mostPlayedSpecStr,   sub = overviewData.mostPlayedSpecSub,   icon = overviewData.mostPlayedSpecIcon,  color = {0.35, 0.75, 0.75} },
                        { label = "Favourite Bracket", value = overviewData.favoriteBracketStr,  sub = overviewData.favoriteBracketSub,  icon = overviewData.favoriteBracketIcon, color = {0.85, 0.20, 0.30} },
                    })
                    yPos = yPos - consumed
                end

                -- Per-bracket totals card ------------------------------------------
                for _, meta in ipairs(BRACKET_META) do
                    local bt = overviewData.bracketTotals[meta.key]
                    if bt and bt.played > 0 then
                        local winPct = bt.played > 0 and (bt.won / bt.played * 100) or 0
                        local body, consumed = AddCard(yPos, meta.label .. " (All Characters)", meta.color, meta.icon, CardHeight(3), "roster_bracket_" .. meta.key)
                        AddRow(body, -8,  "Games Played",    tostring(bt.played))
                        AddRow(body, -26, "Combined Record", string.format("%d - %d  (%.0f%%)", bt.won, bt.lost, winPct))
                        AddRow(body, -44, "Most Played By",  bt.mostPlayedChar and (ColorCharName(bt.mostPlayedChar) .. "  (" .. bt.mostPlayedGames .. " games)") or "—")
                        yPos = yPos - consumed
                    end
                end

                if overviewData.totalGames == 0 then
                    local msg = statsScrollChild:CreateFontString(nil, "OVERLAY", "GameFontNormal")
                    msg:SetPoint("TOPLEFT", statsScrollChild, "TOPLEFT", 4, yPos - 10)
                    msg:SetText("No rated PvP games recorded this season on any tracked character yet.")
                    msg:SetTextColor(0.6, 0.6, 0.6, 1)
                    table.insert(cardWidgets, msg)
                    yPos = yPos - 30
                end

                statsScrollChild:SetHeight(math.max(200, math.abs(yPos) + 20))
            end

            -- Always renders live, current-season data.
            RenderStatsFor = function()
                local rawSeason  = (C_PvP and C_PvP.GetUIDisplaySeason and C_PvP.GetUIDisplaySeason()) or 0
                local seasonName = GetSeasonDisplayName(rawSeason) or "this season"
                local charList   = GetStatsCharacterList()
                RenderSeasonOverview(BuildSeasonOverviewData(charList), seasonName)
            end
            f.RenderStatsFor = RenderStatsFor

            RenderStatsFor()

            end) -- end buildOk pcall

            if buildOk then
                f.statsFrame = statsContainer
            else
                print("|cffff0000[PVPHUB Error]|r Failed to build Stats tab: " .. tostring(buildErr))
                statsContainer:Hide()
                statsContainer:SetParent(nil)
            end
        end

        -- Function to update greeting layout to prevent collision with top buttons and headers
        function f:UpdateGreetingLayout()
            local windowWidth = self:GetWidth()
            
            -- Count visible columns to determine header density and window width
            local visibleColumnCount = 0
            for _, header in ipairs(COLUMN_HEADERS) do
                if PVPHUB_SETTINGS.visibleColumns[header.key] then
                    visibleColumnCount = visibleColumnCount + 1
                end
            end
            
            -- Headers are at Y=-92, greeting needs to stay ABOVE them
            -- More columns = move greeting HIGHER UP to avoid collision
            local greetingYOffset = -45  -- Base position
            
            -- CORRECTED LOGIC: More columns = move greeting UP (higher Y values)
            if visibleColumnCount <= 3 then
                greetingYOffset = -65 -- Few columns = lower position (more space available)
            elseif visibleColumnCount <= 5 then
                greetingYOffset = -55 -- Moderate columns = medium position
            elseif visibleColumnCount == 6 then
                greetingYOffset = -50 -- 6 columns = better spacing from dropdowns
            elseif visibleColumnCount == 7 then
                greetingYOffset = -45 -- 7 columns = improved clearance
            elseif visibleColumnCount == 8 then
                greetingYOffset = -40 -- 8 columns = higher position
            elseif visibleColumnCount == 9 then
                greetingYOffset = -35 -- 9 columns = very high position
            else
                greetingYOffset = -30 -- All columns (10+) = highest position
            end
            
            -- Dynamic font size: scale with user's data font size setting
            local baseFontSize = 12
            local fontSize = baseFontSize + 4  -- Slightly larger than data rows, not a huge headline
            if visibleColumnCount >= 9 then
                fontSize = baseFontSize + 2
            elseif visibleColumnCount >= 7 then
                fontSize = baseFontSize + 3
            end
            
            -- Apply dynamic font size with stronger shadow for headline effect
            local greetingFontPath = PVPHUB_ResolveFontPath()
            local ok, result = pcall(function() return self.greeting:SetFont(greetingFontPath, fontSize, "OUTLINE") end)
            if not (ok and result) then
                self.greeting:SetFont("Fonts\\FRIZQT__.TTF", fontSize, "OUTLINE")
            end
            self.greeting:SetShadowColor(0, 0, 0, 1) -- Strong shadow
            self.greeting:SetShadowOffset(2, -2) -- Prominent shadow offset
            
            -- Additional window width adjustments
            if windowWidth < 700 then
                greetingYOffset = greetingYOffset - 5 -- Move up more for narrow windows
            elseif windowWidth > 1500 then
                greetingYOffset = greetingYOffset + 5 -- Can move down slightly for very wide windows
            end
            
            -- Safety check - never go below Y=-70 to ensure clearance from headers at Y=-92
            if greetingYOffset < -70 then
                greetingYOffset = -70
            end
            
            self.greeting:ClearAllPoints()
            self.greeting:SetPoint("TOP", self, "TOP", 0, greetingYOffset)
            
            -- Calculate greeting text width and adjust titleLine width to match (with enhanced thickness)
            local greetingWidth = self.greeting:GetStringWidth()
            self.titleLine:SetSize(greetingWidth, 3) -- Increased from 2 to 3 for headline prominence
            
            self.titleLine:ClearAllPoints()
            self.titleLine:SetPoint("TOP", self.greeting, "BOTTOM", 0, -2)
        end
        
        -- Initial greeting layout
        f:UpdateGreetingLayout()
        if PVPHUB_SETTINGS.mainWindow and PVPHUB_SETTINGS.mainWindow.hideWelcomeMessage then
            f.greeting:Hide()
            f.titleLine:Hide()
        end

        local dropdown = CreateFrame("Frame", "PVPHUBSortDropdown", f, "UIDropDownMenuTemplate")
        -- Positioned to the left of the close button (close btn: TOPRIGHT -6, width 22 → left edge at -28; gap 8 → -36)
        dropdown:SetPoint("TOPRIGHT", f, "TOPRIGHT", -48, -10)
        UIDropDownMenu_SetWidth(dropdown, 120)
        ApplyModernDropdownStyling(dropdown)
        -- Set dropdown text to the current sort option, always prefixed with 'Sort: '
        local sortDisplayNames = {
            highestRating = "Highest Rating",
            honor = "Honor",
            conquest = "Conquest",
            bloodstones = "Heliotrope",
            rating2v2 = "2v2 Rating",
            rating3v3 = "3v3 Rating",
            ratingShuffle = "Shuffle Rating",
            ratingBlitz = "Blitz Rating",
            ratingRBG = "RBG Rating",
        }
        UIDropDownMenu_SetText(dropdown, "Sort: " .. (sortDisplayNames[PVPHUB_SETTINGS.sortKey or "highestRating"] or "Sort by"))

        local function OnClick(self)
            PVPHUB_SETTINGS.sortKey = self.value
            PVPHUB.sortKey = self.value
            UIDropDownMenu_SetText(dropdown, "Sort: " .. (sortDisplayNames[self.value] or (self.value or "")))
            -- Only update content if we're NOT in settings tab
            if f.currentTab == "characters" and PVPHUB.window and PVPHUB.window.UpdateContent then
                PVPHUB.window:UpdateContent()
            end
        end

        UIDropDownMenu_Initialize(dropdown, function(self, level, menuList)
            for _, option in ipairs({
                { text = "Highest Rating",      value = "highestRating",      icon = nil },
                { text = "Honor",               value = "honor",              icon = "1455894" },
                { text = "Conquest",            value = "conquest",           icon = "1523630" },
                { text = "Heliotrope",         value = "bloodstones",        icon = "134128" },
                { text = "2v2 Rating",          value = "rating2v2",          icon = "Interface\\Icons\\achievement_arena_2v2_1" },
                { text = "3v3 Rating",          value = "rating3v3",          icon = "Interface\\Icons\\achievement_arena_3v3_1" },
                { text = "Shuffle Rating",      value = "ratingShuffle",      icon = "Interface\\Icons\\ability_dualwield" },
                { text = "Blitz Rating",        value = "ratingBlitz",        icon = "Interface\\Icons\\achievement_bg_killxenemies_generalsroom" },
                { text = "RBG Rating",          value = "ratingRBG",          icon = "Interface\\Icons\\achievement_pvp_a_15" },
            }) do
                local info = UIDropDownMenu_CreateInfo()
                info.text = option.text
                info.value = option.value
                info.func = OnClick
                info.checked = (PVPHUB_SETTINGS.sortKey == option.value)
                if option.icon then
                    info.icon = option.icon
                    info.tCoordLeft = 0
                    info.tCoordRight = 1
                    info.tCoordTop = 0
                    info.tCoordBottom = 1
                    info.iconXOffset = -5
                    info.iconYOffset = 0
                end
                UIDropDownMenu_AddButton(info)
            end
        end)

        -- Manage Groups Button (positioned above Character header)
        local manageGroupsBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
        manageGroupsBtn:SetSize(105, 20)
        manageGroupsBtn:SetPoint("TOPLEFT", f, "TOPLEFT", 20, -62)
        manageGroupsBtn:SetText("+ New Group")
        f.manageGroupsBtn = manageGroupsBtn
        
        -- Initially hide the button if grouping is not enabled
        if not (PVPHUB_SETTINGS.characterGroups and PVPHUB_SETTINGS.characterGroups.enabled) then
            manageGroupsBtn:Hide()
        end
        
        manageGroupsBtn:SetScript("OnClick", function()
            StaticPopup_Show("PVPHUB_CREATE_GROUP")
        end)
        manageGroupsBtn:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_CURSOR")
            GameTooltip:SetText("Create New Group", 1, 1, 1)
            GameTooltip:AddLine("Organize your characters into groups", 0.7, 0.7, 0.7, true)
            GameTooltip:AddLine("|cffFFD700Right-click groups to rename/delete|r", 0.7, 0.7, 0.7, true)
            GameTooltip:Show()
        end)
        manageGroupsBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

        -- Streamer Mode Toggle Button
        local compactToggleBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
        compactToggleBtn:SetSize(90, 18)
        compactToggleBtn:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -145, 19)
        compactToggleBtn:SetText("Streamer Mode")
        compactToggleBtn:GetFontString():SetFont("Fonts\\ARIALN.TTF", 10)

        -- Store reference for theme updates
        f.compactToggleBtn = compactToggleBtn

        -- Respect the Disable Streamer Mode setting
        if PVPHUB_SETTINGS.disableStreamerMode then
            compactToggleBtn:Hide()
        end

        compactToggleBtn:SetScript("OnClick", function()
            -- Show compact window without hiding main window
            PVPHUB:CreateCompactWindow()
            
            -- Create smooth blinking border highlight effect using Blizzard's animation system
            if PVPHUB.compactWindow then
                -- Create a temporary border overlay frame for highlighting (even when background is hidden)
                if not PVPHUB.compactWindow.highlightBorder then
                    PVPHUB.compactWindow.highlightBorder = CreateFrame("Frame", nil, PVPHUB.compactWindow, "BackdropTemplate")
                    PVPHUB.compactWindow.highlightBorder:SetAllPoints(PVPHUB.compactWindow)
                    PVPHUB.compactWindow.highlightBorder:SetFrameLevel(PVPHUB.compactWindow:GetFrameLevel() + 100)
                    PVPHUB.compactWindow.highlightBorder:SetBackdrop({
                        edgeFile = "Interface\\Buttons\\WHITE8x8",
                        edgeSize = 3,
                    })
                    PVPHUB.compactWindow.highlightBorder:SetBackdropBorderColor(0, 1, 1, 1) -- Cyan color
                    
                    -- Create animation group for smooth pulsing
                    local ag = PVPHUB.compactWindow.highlightBorder:CreateAnimationGroup()
                    
                    -- Fade in
                    local fadeIn = ag:CreateAnimation("Alpha")
                    fadeIn:SetFromAlpha(0)
                    fadeIn:SetToAlpha(1)
                    fadeIn:SetDuration(0.2)
                    fadeIn:SetOrder(1)
                    
                    -- Fade out
                    local fadeOut = ag:CreateAnimation("Alpha")
                    fadeOut:SetFromAlpha(1)
                    fadeOut:SetToAlpha(0)
                    fadeOut:SetDuration(0.2)
                    fadeOut:SetOrder(2)
                    
                    -- Set to loop 3 times
                    ag:SetLooping("REPEAT")
                    ag:SetScript("OnLoop", function(self, loopState)
                        if not self.loopCount then self.loopCount = 0 end
                        self.loopCount = self.loopCount + 1
                        if self.loopCount >= 3 then
                            self:Stop()
                            PVPHUB.compactWindow.highlightBorder:Hide()
                            self.loopCount = 0
                        end
                    end)
                    
                    PVPHUB.compactWindow.highlightBorder.animGroup = ag
                    PVPHUB.compactWindow.highlightBorder:Hide()
                end
                
                -- Show border and play animation
                PVPHUB.compactWindow.highlightBorder:Show()
                PVPHUB.compactWindow.highlightBorder:SetAlpha(0)
                if PVPHUB.compactWindow.highlightBorder.animGroup.loopCount then
                    PVPHUB.compactWindow.highlightBorder.animGroup.loopCount = 0
                end
                PVPHUB.compactWindow.highlightBorder.animGroup:Play()
            end
        end)
        compactToggleBtn:SetScript("OnEnter", function(self)
            if self.bg then
                local c = UI_CONSTANTS.COLORS
                self.bg:SetVertexColor(c.WINDOW_BG[1] * 2.5, c.WINDOW_BG[2] * 2.5, c.WINDOW_BG[3] * 2.8, 0.95)
            end
            if self.border then
                local c = UI_CONSTANTS.COLORS
                self.border:SetVertexColor(c.WINDOW_BORDER[1] * 1.6, c.WINDOW_BORDER[2] * 1.6, c.WINDOW_BORDER[3] * 1.6, 1)
            end
            GameTooltip:SetOwner(self, "ANCHOR_CURSOR")
            GameTooltip:SetText("Switch to Streamer Mode", 1, 1, 1)
            GameTooltip:AddLine("Opens a streamlined window perfect for streaming", 0.7, 0.7, 0.7, true)
            GameTooltip:Show()
        end)
        compactToggleBtn:SetScript("OnLeave", function(self)
            if self.bg and self.modernStyling then
                self.bg:SetVertexColor(unpack(self.modernStyling.bgColor))
            end
            if self.border and self.modernStyling then
                self.border:SetVertexColor(unpack(self.modernStyling.borderColor))
            end
            GameTooltip:Hide()
        end)

        -- Start Fresh for New Season button — placed beside Streamer Mode since
        -- both are situational, opt-in actions rather than always-relevant window
        -- controls. Opens the same confirmation as the automatic login-time
        -- prompt (see UpdateCurrencyData's season-change detection), so this is
        -- also how to re-trigger it any time after dismissing that prompt.
        local startFreshBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
        startFreshBtn:SetSize(100, 18)
        startFreshBtn:SetPoint("BOTTOMRIGHT", compactToggleBtn, "BOTTOMLEFT", -8, 0)
        startFreshBtn:SetText("Start Fresh")
        startFreshBtn:GetFontString():SetFont("Fonts\\ARIALN.TTF", 10)
        f.startFreshBtn = startFreshBtn
        startFreshBtn:SetScript("OnClick", function() PVPHUB:ShowSeasonFreshStartPopup() end)
        startFreshBtn:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_CURSOR")
            GameTooltip:SetText("Start Fresh for New Season", 0.2, 1, 0.4)
            GameTooltip:AddLine("Clears last season's ratings, W/L, and match history for every tracked character.", 1, 1, 1, true)
            GameTooltip:AddLine("Honor, gold, notes, and settings are kept.", 0.8, 0.8, 0.8, true)
            GameTooltip:Show()
        end)
        startFreshBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

        -- Use saved window scale or default to 1.0
        PVPHUB_SETTINGS.windowScale = PVPHUB_SETTINGS.windowScale or 1.0
        f.currentScale = PVPHUB_SETTINGS.windowScale
        
        -- Simple scale slider using proven approach (like RaidFrameSettings)
        local scaleSlider = CreateFrame("Slider", nil, f, "MinimalSliderTemplate")
        scaleSlider:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -20, 20)
        scaleSlider:SetSize(100, 12)
        scaleSlider:SetMinMaxValues(0.90, 1.50)
        scaleSlider:SetValue(f.currentScale)
        scaleSlider:SetValueStep(0.01)
        scaleSlider:SetObeyStepOnDrag(true)
        
        -- Scale label (hidden by default, shows on hover)
        local scaleLabel = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        scaleLabel:SetPoint("BOTTOM", scaleSlider, "TOP", 0, 2)
        scaleLabel:SetText(string.format("Scale: %d%%", f.currentScale * 100))
        RegisterTrackedFont(scaleLabel, 9, "OUTLINE")
        scaleLabel:SetTextColor(unpack(UI_CONSTANTS.COLORS.HEADER_COLOR))
        scaleLabel:Hide() -- Hide by default
        
        -- Handle value changes (similar to RaidFrameSettings approach)
        -- NOTE: SetScale is applied on MouseUp, not OnValueChanged — the slider lives
        -- inside f itself, so rescaling the parent mid-drag shifts the slider under
        -- the cursor and causes a feedback glitch (same issue as compact toolbar).
        scaleSlider:SetScript("OnValueChanged", function(self, value)
            if not value then return end
            PVPHUB_SETTINGS.windowScale = value
            f.currentScale = value
            scaleLabel:SetText(string.format("Scale: %d%%", value * 100))
            if self:IsMouseOver() or self.isDragging then
                scaleLabel:Show()
            end
        end)
        
        -- Track dragging state for real-time label display
        scaleSlider:SetScript("OnMouseDown", function(self, button)
            if button == "LeftButton" then
                self.isDragging = true
                scaleLabel:Show()
                GameTooltip:Hide()
                -- Lock out window dragging so the parent frame doesn't start moving
                -- while we're adjusting the slider value.
                f:StopMovingOrSizing()
                f:SetMovable(false)
            end
        end)
        
        scaleSlider:SetScript("OnMouseUp", function(self, button)
            if button == "LeftButton" then
                self.isDragging = false
                -- Re-enable window dragging and apply the new scale.
                f:SetMovable(true)
                f:SetScale(PVPHUB_SETTINGS.windowScale)
                if not self:IsMouseOver() then
                    scaleLabel:Hide()
                end
            end
        end)
        
        -- Tooltip and label visibility
        scaleSlider:SetScript("OnEnter", function(self)
            scaleLabel:Show() -- Show label on hover
            -- Only show tooltip if not currently dragging
            if not self.isDragging then
                GameTooltip:SetOwner(self, "ANCHOR_CURSOR")
                GameTooltip:SetText("Window Scale", 1, 1, 1)
                GameTooltip:AddLine("Drag to adjust window size", 0.7, 0.7, 0.7, true)
                GameTooltip:AddLine(string.format("Current: %d%% (Range: 90%% - 150%%)", self:GetValue() * 100), 0.7, 0.7, 0.7, true)
                GameTooltip:Show()
            end
        end)
        
        scaleSlider:SetScript("OnLeave", function(self)
            -- Only hide label if not currently dragging
            if not self.isDragging then
                scaleLabel:Hide()
            end
            GameTooltip:Hide()
        end)
        
        -- Store references for theme updates
        f.scaleSlider = scaleSlider
        f.scaleLabel = scaleLabel
        
        -- Apply saved scale
        f:SetScale(f.currentScale)

        -- Column Visibility Dropdown
        local columnDropdown = CreateFrame("Frame", "PVPHUBColumnDropdown", f, "UIDropDownMenuTemplate")
        -- Sort is at TOPRIGHT -36 with frame 190px; sort left edge at -226; gap 12px → column at -238
        -- Sort frame is 170px wide at TOPRIGHT -36; visible left edge at 184px from right.
        -- 4px gap → column visible right at -188 → frame right at -186.
        columnDropdown:SetPoint("TOPRIGHT", f, "TOPRIGHT", -198, -10)
        UIDropDownMenu_SetWidth(columnDropdown, 80)
        UIDropDownMenu_SetText(columnDropdown, "Show/Hide")
        ApplyModernDropdownStyling(columnDropdown)

        local function OnColumnToggle(self)
            PVPHUB_SETTINGS.visibleColumns[self.value] = not PVPHUB_SETTINGS.visibleColumns[self.value]
            -- Only update content if we're NOT in settings tab
            if f.currentTab == "characters" and PVPHUB.window and PVPHUB.window.UpdateContent then
                PVPHUB.window:UpdateContent()
            end
        end

        UIDropDownMenu_Initialize(columnDropdown, function(self, level, menuList)
            local columns = {
                { text = "Honor",         value = "honor",         icon = "1455894" },
                { text = "Conquest",      value = "conquest",      icon = "1523630" },
                { text = "Heliotrope",    value = "bloodstones",   icon = "134128" },
                { text = "Tokens",        value = "bloodytokens",  icon = "4638431" },
                { text = "2v2 Rating",    value = "rating2v2",     icon = "Interface\\Icons\\achievement_arena_2v2_1" },
                { text = "3v3 Rating",    value = "rating3v3",     icon = "Interface\\Icons\\achievement_arena_3v3_1" },
                { text = "Shuffle Rating", value = "ratingShuffle", icon = "Interface\\Icons\\ability_dualwield" },
                { text = "Blitz Rating",  value = "ratingBlitz",   icon = "Interface\\Icons\\achievement_bg_killxenemies_generalsroom" },
                { text = "RBG Rating",    value = "ratingRBG",     icon = "Interface\\Icons\\achievement_pvp_a_15" },
            }
            
            for _, column in ipairs(columns) do
                local info = UIDropDownMenu_CreateInfo()
                info.text = column.text
                info.value = column.value
                info.func = OnColumnToggle
                info.checked = PVPHUB_SETTINGS.visibleColumns[column.value]
                info.isNotRadio = true
                info.keepShownOnClick = true
                if column.icon then
                    info.icon = column.icon
                    info.tCoordLeft = 0
                    info.tCoordRight = 1
                    info.tCoordTop = 0
                    info.tCoordBottom = 1
                    info.iconXOffset = -5  -- Move icon left
                    info.iconYOffset = 0
                end
                UIDropDownMenu_AddButton(info)
            end
        end)

        -- Initialize headers with dynamic positioning
        local visibleHeaders = {}
        f.xOffsets = {}
        local currentOffset = 30
        local dynamicContentWidth = 0
        local fontScale = (12) / 12

        for _, header in ipairs(GetOrderedColumnHeaders()) do
            if PVPHUB_SETTINGS.visibleColumns[header.key] then
                table.insert(visibleHeaders, header)
                table.insert(f.xOffsets, currentOffset)
                local colWidth = math.ceil((header.minWidth or UI_CONSTANTS.COLUMN_WIDTHS.standard or 85) * fontScale)
                currentOffset = currentOffset + colWidth
                dynamicContentWidth = dynamicContentWidth + colWidth
            end
        end

        -- Set content frame width to use available space (with minimum)
        local minContentWidth = dynamicContentWidth + 40  -- Add minimum right padding
        f.contentFrame:SetWidth(minContentWidth)
        
        -- Calculate and set dynamic window width (add padding for UI elements, allow expanding)
        local dynamicWindowWidth = math.max(minContentWidth + 80, 800) -- Minimum 800px width
        f:SetWidth(dynamicWindowWidth)
        
        -- Update greeting layout after initial width is set
        f:UpdateGreetingLayout()

        -- Initialize empty headers array (headers will be created when switching to characters tab)
        f.headers = {}

        -- fontStrings: all text objects built by UpdateContent.
        -- ApplyFont loops this table and calls SetFont — no rebuild needed for font changes.
        f.fontStrings = {}

        function f:ApplyFont()
            local path = PVPHUB_ResolveFontPath()
            PVPHUB.currentFontPath = path
            -- Update the shared named font so any future FontStrings using
            -- "PVPHUBDataFont" as template pick up the change automatically.
            PVPHUB.dataFont:SetFont(path, 12, "OUTLINE")
            for _, fs in ipairs(self.fontStrings) do
                if fs and fs.SetFont then
                    SafeSetFont(fs, path, 12, "OUTLINE")
                end
            end
        end

        function f:UpdateContent()
            -- Resolve font from DB each time rows are built.
            local currentFont = PVPHUB_ResolveFontPath()
            PVPHUB.currentFontPath = currentFont
            -- Reset fontStrings so ApplyFont only touches live objects.
            f.fontStrings = {}

            -- Clear tracked row frames (Frames, FontStrings, Textures)
            for _, element in ipairs({f.rows, f.rowBackgrounds}) do
                if element then
                    for _, item in ipairs(element) do
                        if item.Hide then item:Hide() end
                        if item.SetParent then item:SetParent(nil) end
                    end
                end
            end
            f.rows = {}
            f.rowBackgrounds = {}

            -- Detach child Frames (cardFrames, backgroundBtns, groupHeaders, etc.)
            local children = {f.contentFrame:GetChildren()}
            for _, child in ipairs(children) do
                if child.Hide then child:Hide() end
                if child.SetParent then child:SetParent(nil) end
            end

            -- Hide orphaned regions (FontStrings / Textures) directly on contentFrame.
            -- GetChildren() only returns Frames; regions created via CreateFontString /
            -- CreateTexture are NOT returned and accumulate across UpdateContent calls.
            -- Hiding them here prevents invisible stale text rendering under new rows.
            local regions = {f.contentFrame:GetRegions()}
            for _, region in ipairs(regions) do
                if region.Hide then region:Hide() end
            end

            -- Recreate headers dynamically. Header labels embed inline icon
            -- markup (|T...|t) in their text — clearing the text BEFORE
            -- reparenting (rather than just Hide()+SetParent(nil)) makes sure
            -- those inline icon glyphs get torn down while the FontString
            -- still has valid context, instead of potentially leaving a
            -- residual icon/text fragment visible under the next render.
            -- This is what showed up as old header text bleeding through new
            -- header text once column reordering made headers actually
            -- change between renders (a plain toggle/sort refresh redraws
            -- the same text, so this never became visible before).
            if f.headers then
                for _, h in ipairs(f.headers) do
                    h:Hide()
                    if h.SetText then h:SetText("") end
                    h:SetParent(nil)
                end
            end
            f.headers = {}

            -- Extra safety sweep, same as SwitchTab's: hides ANY widget
            -- tagged _pvpHeaderWidget regardless of whether it was correctly
            -- present in the f.headers array just cleared above, plus clears
            -- any in-flight column-drag ghost/state so a refresh mid-drag
            -- can't leave stale visuals behind.
            for _, region in ipairs({ f:GetRegions() }) do
                if region._pvpHeaderWidget then
                    region:Hide()
                    if region.SetText then region:SetText("") end
                end
            end
            for _, child in ipairs({ f:GetChildren() }) do
                if child._pvpHeaderWidget then child:Hide() end
            end
            PVPHUB._draggingColumnKey = nil
            PVPHUB._dropTargetColumnKey = nil
            if PVPHUB._columnDragGhost then PVPHUB._columnDragGhost:Hide() end
            
            -- Create dynamic headers and calculate offsets
            local visibleHeaders = {}
            f.xOffsets = {}
            local currentOffset = 20
            local dynamicContentWidth = 0
            local fontScale = (12) / 12

            for _, header in ipairs(GetOrderedColumnHeaders()) do
                if PVPHUB_SETTINGS.visibleColumns[header.key] then
                    table.insert(visibleHeaders, header)
                    table.insert(f.xOffsets, currentOffset)
                    local colWidth = math.ceil((header.minWidth or UI_CONSTANTS.COLUMN_WIDTHS.standard or 85) * fontScale)
                    currentOffset = currentOffset + colWidth
                    dynamicContentWidth = dynamicContentWidth + colWidth
                end
            end

            -- Update content frame and window width dynamically with expandable right space
            local minContentWidth = dynamicContentWidth + 25  -- Add minimum right padding
            f.contentFrame:SetWidth(minContentWidth)
            local dynamicWindowWidth = math.max(minContentWidth + 65, 700) -- Minimum 700px width
            f:SetWidth(dynamicWindowWidth)
            
            -- Store the dynamic content width for use in row backgrounds
            f.dynamicRowWidth = minContentWidth
            
            -- Update greeting layout after width change
            if f.UpdateGreetingLayout then
                f:UpdateGreetingLayout()
            end

            -- Always create headers (visibility is controlled by tab switching)
            -- Create headers with modern styling
            local activeSortKey = PVPHUB_SETTINGS.sortKey or "highestRating"
            for i, header in ipairs(visibleHeaders) do
                -- Skip creating header for delete column
                if not header.hideHeader then
                    local h = f:CreateFontString(nil, "OVERLAY")
                    SafeSetFont(h, currentFont, 12, "OUTLINE")
                    table.insert(f.fontStrings, h)
                    local hXOffset = f.xOffsets[i]
                    h:SetPoint("TOPLEFT", f, "TOPLEFT", hXOffset, -92)
                    if header.key == activeSortKey then
                        h:SetTextColor(0.2, 0.85, 1, 1)
                    else
                        h:SetTextColor(unpack(UI_CONSTANTS.COLORS.HEADER_COLOR))
                    end
                    local displayText = header.text
                    if header.key == activeSortKey then
                        displayText = displayText .. " " .. CreateAtlasMarkup("auctionhouse-ui-sortarrow", 10, 10)
                    end
                    h:SetText(displayText)
                    h._pvpHeaderWidget = true
                    table.insert(f.headers, h)

                    -- Add header separator line that matches text width
                    local headerLine = f:CreateTexture(nil, "ARTWORK")
                    headerLine:SetTexture("Interface\\Buttons\\WHITE8x8")
                    headerLine:SetVertexColor(unpack(UI_CONSTANTS.COLORS.HEADER_LINE))
                    local textWidth = h:GetStringWidth()
                    headerLine:SetSize(textWidth, 1)
                    headerLine:SetPoint("TOPLEFT", h, "BOTTOMLEFT", 0, -3)
                    headerLine._pvpHeaderWidget = true
                    table.insert(f.headers, headerLine)

                    -- Column width for this header (matches xOffsets calculation)
                    local colWidth = math.ceil((header.minWidth or UI_CONSTANTS.COLUMN_WIDTHS.standard or 85) * fontScale)

                    -- Full-column hover highlight (header row down to scroll area bottom)
                    local hb = UI_CONSTANTS.COLORS.WINDOW_BORDER
                    local colHL = f:CreateTexture(nil, "BACKGROUND", nil, 2)
                    colHL:SetTexture("Interface\\Buttons\\WHITE8x8")
                    colHL:SetVertexColor(hb[1], hb[2], hb[3], 0.10)
                    colHL:SetPoint("TOPLEFT",     f, "TOPLEFT",   hXOffset - 20, -82)
                    colHL:SetPoint("BOTTOMRIGHT", f, "BOTTOMLEFT", hXOffset - 20 + colWidth, 60)
                    colHL:Hide()
                    colHL._pvpHeaderWidget = true
                    table.insert(f.headers, colHL)

                    -- Invisible button overlay to capture mouse hover on the header
                    local isSort = (header.key == activeSortKey)
                    local hoverBtn = CreateFrame("Button", nil, f)
                    hoverBtn:SetPoint("TOPLEFT", f, "TOPLEFT", hXOffset - 20, -82)
                    hoverBtn:SetSize(colWidth, 32)
                    hoverBtn:SetFrameLevel(f:GetFrameLevel() + 10)
                    hoverBtn:SetScript("OnEnter", function()
                        colHL:Show()
                        h:SetTextColor(1, 1, 1, 1)
                        headerLine:SetVertexColor(1, 1, 1, 0.6)
                    end)
                    hoverBtn:SetScript("OnLeave", function()
                        colHL:Hide()
                        if isSort then
                            h:SetTextColor(0.2, 0.85, 1, 1)
                        else
                            h:SetTextColor(unpack(UI_CONSTANTS.COLORS.HEADER_COLOR))
                        end
                        headerLine:SetVertexColor(unpack(UI_CONSTANTS.COLORS.HEADER_LINE))
                    end)

                    -- Drag-and-drop column reordering — same pattern as the
                    -- character-group drag-and-drop above (GetGroupDragGhost/
                    -- ReorderGroup), adapted horizontally. "character" is the
                    -- fixed identifier column and never gets this wiring.
                    if header.key ~= "character" then
                        hoverBtn:RegisterForDrag("LeftButton")
                        hoverBtn:SetScript("OnDragStart", function(self)
                            PVPHUB._draggingColumnKey = header.key
                            PVPHUB._dropTargetColumnKey = nil
                            local ghost = GetColumnDragGhost(f)
                            -- Height comes from the OnUpdate anchoring (full
                            -- column span); only width needs setting here.
                            ghost:SetWidth(colWidth)
                            ghost.label:SetText(header.text)
                            SafeSetFont(ghost.label, currentFont, 12, "OUTLINE")
                            ghost:Show()
                        end)
                        hoverBtn:SetScript("OnDragStop", function(self)
                            local fromKey = PVPHUB._draggingColumnKey
                            local toKey   = PVPHUB._dropTargetColumnKey
                            PVPHUB._draggingColumnKey  = nil
                            PVPHUB._dropTargetColumnKey = nil
                            if PVPHUB._columnDragGhost then PVPHUB._columnDragGhost:Hide() end
                            if self._dropLine then self._dropLine:Hide() end
                            if fromKey and toKey and fromKey ~= toKey then
                                ReorderColumn(fromKey, toKey)
                            end
                        end)

                        local function showColumnDropLine(frame)
                            if not frame._dropLine then
                                local line = frame:CreateTexture(nil, "OVERLAY")
                                line:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, 0)
                                line:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 0, 0)
                                line:SetWidth(2)
                                line:SetColorTexture(0.2, 0.6, 1, 1)
                                frame._dropLine = line
                            end
                            frame._dropLine:Show()
                        end

                        -- Hooked (not set) so this stacks on top of the
                        -- hover-highlight OnEnter/OnLeave above instead of
                        -- replacing it.
                        hoverBtn:HookScript("OnEnter", function(self)
                            if PVPHUB._draggingColumnKey and PVPHUB._draggingColumnKey ~= header.key then
                                PVPHUB._dropTargetColumnKey = header.key
                                showColumnDropLine(self)
                            end
                        end)
                        hoverBtn:HookScript("OnLeave", function(self)
                            if PVPHUB._dropTargetColumnKey == header.key then
                                PVPHUB._dropTargetColumnKey = nil
                            end
                            if self._dropLine then self._dropLine:Hide() end
                        end)
                    end

                    hoverBtn._pvpHeaderWidget = true
                    table.insert(f.headers, hoverBtn)

                    -- Hide everything initially if not in characters tab
                    if f.currentTab ~= "characters" then
                        h:Hide()
                        headerLine:Hide()
                        colHL:Hide()
                        hoverBtn:Hide()
                    end
                end
            end

            -- Sort and prepare character data
            local sortKey = PVPHUB_SETTINGS.sortKey or "highestRating" -- Fixed: use same default as initialization
            local sorted = {}
            
            -- Helper function to check if character has any CURRENT-season
            -- ratings. Reads bracketStats — season-tagged, and cleared by
            -- both the automatic season-boundary reset and "Start Fresh" —
            -- rather than the legacy flat rating2v2/ratingShuffle/etc fields.
            -- Those flat fields are never cleared by either reset (the
            -- roster display gates on bracketStats instead, via
            -- isRatingKnown), so checking them here left "Hide Characters
            -- with No Ratings" showing characters tagged "(last season)"
            -- since their old rating numbers were technically still >0.
            local function hasAnyRating(data)
                local bs = data.bracketStats
                if not bs then return false end
                for _, meta in ipairs(BRACKET_META) do
                    local entry = bs[meta.key]
                    if entry then
                        if meta.key == "ratingShuffle" or meta.key == "ratingBlitz" then
                            for _, spec in pairs(entry) do
                                if type(spec) == "table" and (spec.rating or 0) > 0 then
                                    return true
                                end
                            end
                        elseif (entry.rating or 0) > 0 then
                            return true
                        end
                    end
                end
                return false
            end
            
            local totalHonor, totalConquest, totalGold = 0, 0, 0

            -- Display thresholds (Settings > Display) — a character below
            -- the threshold is left out of that currency's total entirely,
            -- same as a hidden character, so a pile of near-zero alts
            -- doesn't dilute the number. 0 (default) includes everyone.
            local honorThreshold    = (PVPHUB_SETTINGS.mainWindow and PVPHUB_SETTINGS.mainWindow.honorThreshold) or 0
            local conquestThreshold = (PVPHUB_SETTINGS.mainWindow and PVPHUB_SETTINGS.mainWindow.conquestThreshold) or 0
            local goldThreshold     = ((PVPHUB_SETTINGS.mainWindow and PVPHUB_SETTINGS.mainWindow.goldThreshold) or 0) * 10000 -- gold -> copper

            for char, data in pairs(PVPHUB_DB) do
                if type(data) == "table" and not IsCharacterHidden(char) then
                    -- Totals cover every tracked (non-hidden) character
                    -- regardless of the "Hide Characters with No Ratings"
                    -- filter below — honor/conquest/gold aren't rating-gated,
                    -- so a character with no PvP rating this season (e.g.
                    -- freshly wiped by Start Fresh, before it's logged back
                    -- in) should still count toward the summary instead of
                    -- vanishing from it entirely.
                    if (data.honor or 0) > honorThreshold then
                        totalHonor = totalHonor + (data.honor or 0)
                    end
                    if (data.gold or 0) > goldThreshold then
                        totalGold = totalGold + (data.gold or 0)
                    end

                    -- Conquest is the one currency Blizzard actually zeroes
                    -- out at the season boundary (unlike honor/gold, which
                    -- never reset) — data.conquest is just a snapshot of
                    -- that character's wallet as of their last login, so for
                    -- a character that hasn't logged in since the season
                    -- changed, it's known to be their stale pre-reset amount,
                    -- not their real current balance. Leave it out of the
                    -- total instead of counting a number we know is wrong.
                    if not IsCharacterStaleThisSeason(char) and (data.conquest or 0) > conquestThreshold then
                        totalConquest = totalConquest + (data.conquest or 0)
                    end

                    -- Filter out characters with no ratings if setting is enabled
                    if PVPHUB_SETTINGS.mainWindow and PVPHUB_SETTINGS.mainWindow.hideNoRatings then
                        if hasAnyRating(data) then
                            table.insert(sorted, { char = char, data = data })
                        end
                    else
                        table.insert(sorted, { char = char, data = data })
                    end
                end
            end

            -- Warband Bank is account-wide, not per-character — add it once
            -- rather than in the per-character loop above (which would count
            -- it once per character and wildly overstate the total).
            totalGold = totalGold + (PVPHUB_SETTINGS.warbandGold or 0)

            -- Hoisted out of the comparator: table.sort calls this O(n log n)
            -- times, and UnitName/GetRealmName/concat don't change mid-sort.
            local currentPlayer = UnitName("player")
            local currentRealm = GetRealmName()
            local currentChar = currentPlayer and currentRealm and (currentPlayer .. "-" .. currentRealm) or nil
            table.sort(sorted, function(a, b)
                -- Always put current character first
                if currentChar then
                    if a.char == currentChar then
                        return true  -- a (current) comes before b
                    elseif b.char == currentChar then
                        return false -- b (current) comes before a
                    end
                end
                
                -- Get pinned character setting (secondary priority after current char)
                local pinnedChar = PVPHUB_SETTINGS.mainWindow and PVPHUB_SETTINGS.mainWindow.pinnedCharacter
                
                -- If there's a pinned character, put it second (after current char)
                if pinnedChar then
                    if a.char == pinnedChar then
                        return true  -- a (pinned) comes before b
                    elseif b.char == pinnedChar then
                        return false -- b (pinned) comes before a
                    end
                    -- If neither is pinned, continue with normal sorting
                end
                
                local function getDisplayedRating(ratingTable, currentSpecID)
                    if type(ratingTable) == "number" then return ratingTable end
                    if type(ratingTable) ~= "table" then return 0 end
                    if currentSpecID and currentSpecID ~= 0 then
                        return ratingTable[currentSpecID] or 0
                    end
                    local max = 0
                    for _, v in pairs(ratingTable) do if v > max then max = v end end
                    return max
                end

                local function getHighestRating(entry)
                    local d = entry.data
                    local maxRating = 0
                    local specID = d.specID or d.lastActiveSpecID
                    
                    -- Check standard brackets
                    for _, k in ipairs({"rating2v2", "rating3v3", "ratingRBG"}) do
                        local rating = d[k] or 0
                        if rating > maxRating then
                            maxRating = rating
                        end
                    end
                    
                    -- Shuffle and Blitz: use displayed (spec-aware) rating, same as columns show
                    local shuffle = getDisplayedRating(d.ratingShuffle, specID)
                    if shuffle > maxRating then maxRating = shuffle end

                    local blitz = getDisplayedRating(d.ratingBlitz, specID)
                    if blitz > maxRating then maxRating = blitz end
                    
                    return maxRating
                end
                if sortKey == "highestRating" then
                    return getHighestRating(a) > getHighestRating(b)
                else
                    local aVal = a.data[sortKey]
                    local bVal = b.data[sortKey]
                    -- Handle multi-spec rating sorting (Shuffle and Blitz) — use displayed rating
                    if sortKey == "ratingShuffle" or sortKey == "ratingBlitz" then
                        aVal = getDisplayedRating(a.data[sortKey], a.data.specID or a.data.lastActiveSpecID)
                        bVal = getDisplayedRating(b.data[sortKey], b.data.specID or b.data.lastActiveSpecID)
                    end
                    return (aVal or 0) > (bVal or 0)
                end
            end)
            
            local contentHeight = 0
            local currentChar = GetFullName()
            local dynamicRowHeight = GetDynamicRowHeight()
            local groupHeaderHeight = 30
            local groupBottomPadding = 3

            -- Check if grouping is enabled and reorganize characters
            local displayList = {} -- Will contain both group headers and character entries
            local groupingEnabled = PVPHUB_SETTINGS.characterGroups and PVPHUB_SETTINGS.characterGroups.enabled
            
            if groupingEnabled and PVPHUB_SETTINGS.characterGroups.groups then
                local groups = PVPHUB_SETTINGS.characterGroups.groups
                
                -- Organize characters into groups
                local groupedChars = {}
                for i, group in ipairs(groups) do
                    groupedChars[i] = {
                        group = group,
                        characters = {}
                    }
                end
                
                -- Assign each character to their group
                for _, entry in ipairs(sorted) do
                    local groupIndex = GetCharacterGroup(entry.char)
                    table.insert(groupedChars[groupIndex].characters, entry)
                end
                
                -- Separate "No Group" (default) from other groups
                local defaultGroup = nil
                local otherGroups = {}
                
                for i = 1, #groupedChars do  -- Forward iteration: array order is user-defined via drag-and-drop
                    if groupedChars[i].group.isDefault then
                        defaultGroup = groupedChars[i]
                    else
                        table.insert(otherGroups, groupedChars[i])
                    end
                end
                
                -- Build display list: newest groups first (reversed order), then No Group at bottom
                for _, groupData in ipairs(otherGroups) do
                    -- Add group header entry
                    table.insert(displayList, {
                        isGroupHeader = true,
                        groupIndex = groupData.group.isDefault and 1 or nil,  -- Will need to recalculate
                        groupName = groupData.group.name,
                        groupCollapsed = groupData.group.collapsed or false,
                        groupIsDefault = groupData.group.isDefault or false,
                        characterCount = #groupData.characters,
                        groupData = groupData.group  -- Store reference for index lookup
                    })
                    
                    -- Add characters if not collapsed
                    if not (groupData.group.collapsed) then
                        for _, entry in ipairs(groupData.characters) do
                            table.insert(displayList, entry)
                        end
                    end
                end
                
                -- Add default "No Group" at the bottom
                if defaultGroup then
                    table.insert(displayList, {
                        isGroupHeader = true,
                        groupIndex = 1,
                        groupName = defaultGroup.group.name,
                        groupCollapsed = defaultGroup.group.collapsed or false,
                        groupIsDefault = true,
                        characterCount = #defaultGroup.characters,
                        groupData = defaultGroup.group
                    })
                    
                    if not (defaultGroup.group.collapsed) then
                        for _, entry in ipairs(defaultGroup.characters) do
                            table.insert(displayList, entry)
                        end
                    end
                end
                
                -- Fix groupIndex references for non-default groups
                for i, entry in ipairs(displayList) do
                    if entry.isGroupHeader and entry.groupData then
                        -- Find actual index in PVPHUB_SETTINGS.characterGroups.groups
                        for idx, group in ipairs(PVPHUB_SETTINGS.characterGroups.groups) do
                            if group == entry.groupData then
                                entry.groupIndex = idx
                                break
                            end
                        end
                    end
                end
            else
                -- No grouping, use original sorted list
                displayList = sorted
            end

            -- Check if there are any characters at all (not just visible ones)
            local hasAnyCharacters = #sorted > 0
            
            -- Show empty state message if no characters exist
            if not hasAnyCharacters then
                local emptyText = f.contentFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
                emptyText:SetPoint("CENTER", f.contentFrame, "CENTER", 0, 0)
                emptyText:SetText("Nothing to see, no rating, no characters...")
                SafeSetFont(emptyText, currentFont, 16, "")
                emptyText:SetTextColor(0.6, 0.6, 0.6, 1)
                table.insert(f.rows, emptyText)
                table.insert(f.fontStrings, emptyText)
                contentHeight = 100 -- Minimal height for empty state
            end

            -- Create character rows (now includes group headers if grouping enabled)
            local currentYOffset = 0  -- Track actual Y position
            for _, entry in ipairs(displayList) do
                if entry.isGroupHeader then
                    -- Render group header
                    local y = -currentYOffset
                    
                    local groupHeader = CreateFrame("Frame", nil, f.contentFrame)
                    groupHeader:SetPoint("TOPLEFT", f.contentFrame, "TOPLEFT", 0, y)
                    groupHeader:SetSize(dynamicContentWidth, groupHeaderHeight)
                    table.insert(f.rows, groupHeader)
                    
                    -- Add a subtle separator line at the top of group (except first)
                    if currentYOffset > 0 then
                        local separator = groupHeader:CreateTexture(nil, "ARTWORK")
                        separator:SetPoint("TOPLEFT", groupHeader, "TOPLEFT", 8, 0)
                        separator:SetPoint("TOPRIGHT", groupHeader, "TOPRIGHT", -8, 0)
                        separator:SetHeight(1)
                        separator:SetColorTexture(0.3, 0.3, 0.3, 0.5)
                    end
                    
                    -- Collapse/Expand button
                    local collapseBtn = CreateFrame("Button", nil, groupHeader)
                    collapseBtn:SetSize(16, 16)
                    collapseBtn:SetPoint("LEFT", groupHeader, "LEFT", 8, 0)
                    local btnTexture = entry.groupCollapsed and "Interface\\Buttons\\UI-PlusButton-Up" or "Interface\\Buttons\\UI-MinusButton-Up"
                    collapseBtn:SetNormalTexture(btnTexture)
                    collapseBtn:SetHighlightTexture("Interface\\Buttons\\UI-PlusButton-Hilight")
                    collapseBtn:SetScript("OnClick", function()
                        PVPHUB_SETTINGS.characterGroups.groups[entry.groupIndex].collapsed = not PVPHUB_SETTINGS.characterGroups.groups[entry.groupIndex].collapsed
                        if PVPHUB.window and PVPHUB.window.UpdateContent then
                            PVPHUB.window:UpdateContent()
                        end
                    end)
                    
                    -- Group name with better positioning
                    local groupText = groupHeader:CreateFontString(nil, "OVERLAY", "GameFontNormal")
                    groupText:SetPoint("LEFT", collapseBtn, "RIGHT", 6, 0)
                    groupText:SetText(string.format("|cffffffff%s|r |cff888888(%d)|r", entry.groupName, entry.characterCount))
                    SafeSetFont(groupText, currentFont, 13, "OUTLINE")
                    table.insert(f.fontStrings, groupText)
                    
                    -- Right-click for rename/delete (except default No Group)
                    if not entry.groupIsDefault then
                        groupHeader:EnableMouse(true)
                        groupHeader:SetScript("OnMouseUp", function(self, button)
                            if button == "RightButton" then
                                local menu = {
                                    {
                                        text = "Rename Group",
                                        func = function()
                                            PVPHUB._renameGroupCtx = { groupIndex = entry.groupIndex, groupName = entry.groupName }
                                            StaticPopup_Show("PVPHUB_RENAME_GROUP")
                                        end
                                    },
                                    {
                                        text = "Delete Group",
                                        func = function()
                                            PVPHUB._deleteGroupCtx = { groupIndex = entry.groupIndex }
                                            StaticPopupDialogs["PVPHUB_DELETE_GROUP"].text = "Delete group '" .. entry.groupName .. "'?\n\nCharacters will move to No Group."
                                            StaticPopup_Show("PVPHUB_DELETE_GROUP")
                                        end
                                    }
                                }

                                -- Create dropdown menu
                                if not PVPHUB.groupContextMenu then
                                    PVPHUB.groupContextMenu = CreateFrame("Frame", "PVPHUBGroupContextMenu", UIParent, "UIDropDownMenuTemplate")
                                end

                                UIDropDownMenu_Initialize(PVPHUB.groupContextMenu, function(self, level)
                                    for _, item in ipairs(menu) do
                                        local info = UIDropDownMenu_CreateInfo()
                                        info.text = item.text
                                        info.func = item.func
                                        info.notCheckable = true
                                        UIDropDownMenu_AddButton(info)
                                    end
                                end, "MENU")

                                ToggleDropDownMenu(1, nil, PVPHUB.groupContextMenu, "cursor", 0, 0)
                            end
                        end)

                        -- Drag-and-drop reordering
                        groupHeader:RegisterForDrag("LeftButton")
                        groupHeader:SetScript("OnDragStart", function(self)
                            PVPHUB._draggingGroupIndex = entry.groupIndex
                            PVPHUB._dropTargetGroupIndex = nil
                            local ghost = GetGroupDragGhost()
                            -- Match the real header's size, icon, text, and font exactly
                            ghost:SetSize(dynamicContentWidth, groupHeaderHeight)
                            local btnTex = entry.groupCollapsed
                                and "Interface\\Buttons\\UI-PlusButton-Up"
                                or  "Interface\\Buttons\\UI-MinusButton-Up"
                            ghost.icon:SetTexture(btnTex)
                            ghost.label:SetText(string.format("|cffffffff%s|r |cff888888(%d)|r", entry.groupName, entry.characterCount))
                            SafeSetFont(ghost.label, currentFont, 13, "OUTLINE")
                            ghost:Show()
                        end)
                        groupHeader:SetScript("OnDragStop", function(self)
                            local fromIndex = PVPHUB._draggingGroupIndex
                            local toIndex = PVPHUB._dropTargetGroupIndex
                            PVPHUB._draggingGroupIndex = nil
                            PVPHUB._dropTargetGroupIndex = nil
                            if PVPHUB._groupDragGhost then PVPHUB._groupDragGhost:Hide() end
                            if fromIndex and toIndex and fromIndex ~= toIndex then
                                ReorderGroup(fromIndex, toIndex)
                            end
                        end)
                        local function showDropLine(frame)
                            if not frame._dropLine then
                                local line = frame:CreateTexture(nil, "OVERLAY")
                                line:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, 0)
                                line:SetPoint("TOPRIGHT", frame, "TOPRIGHT", 0, 0)
                                line:SetHeight(2)
                                line:SetColorTexture(0.2, 0.6, 1, 1)
                                frame._dropLine = line
                            end
                            frame._dropLine:Show()
                        end
                        groupHeader:SetScript("OnEnter", function(self)
                            if PVPHUB._draggingGroupIndex and PVPHUB._draggingGroupIndex ~= entry.groupIndex then
                                PVPHUB._dropTargetGroupIndex = entry.groupIndex
                                showDropLine(self)
                            end
                        end)
                        groupHeader:SetScript("OnLeave", function(self)
                            if PVPHUB._dropTargetGroupIndex == entry.groupIndex then
                                PVPHUB._dropTargetGroupIndex = nil
                            end
                            if self._dropLine then self._dropLine:Hide() end
                        end)
                    else
                        -- No Group is a drop target: dropping here moves the dragged group to last position
                        groupHeader:EnableMouse(true)
                        groupHeader:SetScript("OnEnter", function(self)
                            if PVPHUB._draggingGroupIndex then
                                PVPHUB._dropTargetGroupIndex = entry.groupIndex
                                if not self._dropLine then
                                    local line = self:CreateTexture(nil, "OVERLAY")
                                    line:SetPoint("TOPLEFT", self, "TOPLEFT", 0, 0)
                                    line:SetPoint("TOPRIGHT", self, "TOPRIGHT", 0, 0)
                                    line:SetHeight(2)
                                    line:SetColorTexture(0.2, 0.6, 1, 1)
                                    self._dropLine = line
                                end
                                self._dropLine:Show()
                            end
                        end)
                        groupHeader:SetScript("OnLeave", function(self)
                            if PVPHUB._dropTargetGroupIndex == entry.groupIndex then
                                PVPHUB._dropTargetGroupIndex = nil
                            end
                            if self._dropLine then self._dropLine:Hide() end
                        end)
                    end
                    
                    currentYOffset = currentYOffset + groupHeaderHeight
                    contentHeight = contentHeight + groupHeaderHeight
                    
                    -- Add bottom padding after group header for spacing before first character
                    if not entry.groupCollapsed then
                        currentYOffset = currentYOffset + groupBottomPadding
                        contentHeight = contentHeight + groupBottomPadding
                    end
                else
                    -- Render normal character row
                    local isExpanded = (PVPHUB.expandedChar == entry.char)
                    local panelFont     = currentFont
                    local panelFontSize = math.max(10, (12) - 1)
                    -- Height: MMR row + last-updated row + realm row + buffers
                    local expandPanelH  = isExpanded and (panelFontSize * 2 + 30) or 0
                    local y = -currentYOffset
                    currentYOffset = currentYOffset + dynamicRowHeight + expandPanelH
                    contentHeight = math.max(contentHeight, currentYOffset)
                    
                    local rowIndex = math.floor(currentYOffset / dynamicRowHeight)

                -- Card-style row frame with class-colored accent strip
                local rowWidth = f.dynamicRowWidth or UI_CONSTANTS.CONTENT_WIDTH
                local rowHeight = dynamicRowHeight - 2
                local cardTotalH = rowHeight + expandPanelH
                local isCurrentChar = (entry.char == currentChar)
                local isSelectedChar = (PVPHUB.selectedChar == entry.char)
                local charClass = (entry.data and entry.data.class) and entry.data.class:upper() or "WARRIOR"
                local classColorInfo = RAID_CLASS_COLORS[charClass] or RAID_CLASS_COLORS["WARRIOR"]

                -- Determine card border and fill colors based on row state
                local cardBorderR, cardBorderG, cardBorderB, cardBorderA
                local cardFillR,   cardFillG,   cardFillB,   cardFillA
                if isSelectedChar then
                    -- Gold border + warm amber fill for the click-selected character
                    cardBorderR, cardBorderG, cardBorderB, cardBorderA = 1.0, 0.82, 0.2, 1.0
                    cardFillR,   cardFillG,   cardFillB,   cardFillA   = 0.28, 0.20, 0.02, 0.32
                elseif isCurrentChar then
                    -- Accent-colored border + class-tinted fill for the logged-in character
                    local ac = UI_CONSTANTS.COLORS.ACCENT_LINE
                    local ab = UI_CONSTANTS.COLORS.CURRENT_CHAR_BG
                    local cr, cg, cb = classColorInfo.r, classColorInfo.g, classColorInfo.b
                    cardBorderR, cardBorderG, cardBorderB, cardBorderA = ac[1], ac[2], ac[3], 0.70
                    cardFillR = ab[1] * 0.70 + cr * 0.30
                    cardFillG = ab[2] * 0.70 + cg * 0.30
                    cardFillB = ab[3] * 0.70 + cb * 0.30
                    cardFillA = 0.55
                else
                    -- Normal rows: class-color tint blended into fill and border
                    local ab = UI_CONSTANTS.COLORS.ALTERNATING_ROW_BG
                    local cr, cg, cb = classColorInfo.r, classColorInfo.g, classColorInfo.b
                    cardFillR = ab[1] * 0.70 + cr * 0.30
                    cardFillG = ab[2] * 0.70 + cg * 0.30
                    cardFillB = ab[3] * 0.70 + cb * 0.30
                    cardFillA = 0.55
                    cardBorderR = 0.25 + cr * 0.45
                    cardBorderG = 0.25 + cg * 0.45
                    cardBorderB = 0.30 + cb * 0.45
                    cardBorderA = 0.55
                end

                local cardFrame = CreateFrame("Frame", nil, f.contentFrame)
                cardFrame:SetPoint("TOPLEFT", f.contentFrame, "TOPLEFT", 0, y)
                cardFrame:SetSize(rowWidth, cardTotalH)
                cardFrame:SetFrameLevel(f.contentFrame:GetFrameLevel())

                -- Fill: solid left 65%, fades to transparent over right 35%
                local solidW = math.floor(rowWidth * 0.65)
                local solidTex = cardFrame:CreateTexture(nil, "BACKGROUND")
                solidTex:SetTexture("Interface\\Buttons\\WHITE8x8")
                solidTex:SetPoint("TOPLEFT",    cardFrame, "TOPLEFT",    0, 0)
                solidTex:SetPoint("BOTTOMLEFT", cardFrame, "BOTTOMLEFT", 0, 0)
                solidTex:SetWidth(solidW)
                solidTex:SetVertexColor(cardFillR, cardFillG, cardFillB, cardFillA)

                local gradTex = cardFrame:CreateTexture(nil, "BACKGROUND")
                gradTex:SetTexture("Interface\\Buttons\\WHITE8x8")
                gradTex:SetPoint("TOPLEFT",     solidTex,  "TOPRIGHT",    0, 0)
                gradTex:SetPoint("BOTTOMRIGHT", cardFrame, "BOTTOMRIGHT", 0, 0)
                gradTex:SetGradient("HORIZONTAL",
                    CreateColor(cardFillR, cardFillG, cardFillB, cardFillA),
                    CreateColor(cardFillR, cardFillG, cardFillB, 0))

                -- Border lines: solid on left ~80%, fade to transparent on the right
                local fadeW = math.floor(rowWidth * 0.80)
                local topLine = cardFrame:CreateTexture(nil, "BORDER")
                topLine:SetTexture("Interface\\Buttons\\WHITE8x8")
                topLine:SetHeight(1)
                topLine:SetPoint("TOPLEFT",  cardFrame, "TOPLEFT",  0, 0)
                topLine:SetPoint("TOPRIGHT", cardFrame, "TOPRIGHT", 0, 0)
                topLine:SetGradient("HORIZONTAL",
                    CreateColor(cardBorderR, cardBorderG, cardBorderB, cardBorderA),
                    CreateColor(cardBorderR, cardBorderG, cardBorderB, 0))

                local botLine = cardFrame:CreateTexture(nil, "BORDER")
                botLine:SetTexture("Interface\\Buttons\\WHITE8x8")
                botLine:SetHeight(1)
                botLine:SetPoint("BOTTOMLEFT",  cardFrame, "BOTTOMLEFT",  0, 0)
                botLine:SetPoint("BOTTOMRIGHT", cardFrame, "BOTTOMRIGHT", 0, 0)
                botLine:SetGradient("HORIZONTAL",
                    CreateColor(cardBorderR, cardBorderG, cardBorderB, cardBorderA),
                    CreateColor(cardBorderR, cardBorderG, cardBorderB, 0))

                table.insert(f.rowBackgrounds, cardFrame)
                table.insert(f.rowBackgrounds, solidTex)
                table.insert(f.rowBackgrounds, gradTex)
                table.insert(f.rowBackgrounds, topLine)
                table.insert(f.rowBackgrounds, botLine)

                -- 8px class-colored accent strip on the far left edge
                local accentStrip = cardFrame:CreateTexture(nil, "OVERLAY")
                accentStrip:SetWidth(8)
                accentStrip:SetHeight(rowHeight - 2)
                accentStrip:SetPoint("TOPLEFT", cardFrame, "TOPLEFT", 1, -1)
                accentStrip:SetColorTexture(classColorInfo.r, classColorInfo.g, classColorInfo.b, 1.0)
                table.insert(f.rowBackgrounds, accentStrip)

                -- Create row data
                local data = entry.data

                -- Dim the whole row (background, icon, and every column's text
                -- all inherit a frame's alpha) when this character hasn't
                -- logged in since the last detected season change - its
                -- honor/conquest/ratings are still last season's snapshot and
                -- there's no way to refresh them without logging into it.
                local isStaleThisSeason = IsCharacterStaleThisSeason(entry.char)
                if isStaleThisSeason then
                    cardFrame:SetAlpha(0.45)
                end

                -- Class icon texture: same width and height as the accent strip, zoom-cropped to center
                local classIconTexPath = nil
                if data and data.specID then
                    local _si = GetCachedSpecInfo(data.specID)
                    classIconTexPath = _si and _si.icon
                end
                if not classIconTexPath then
                    classIconTexPath = CLASS_ICON_PATHS[charClass]
                end
                local hasClassIcon = classIconTexPath ~= nil
                if hasClassIcon then
                    local classIconTex = cardFrame:CreateTexture(nil, "OVERLAY")
                    local iconH = rowHeight - 2    -- match the accent strip height
                    local iconW = iconH             -- square: zoom fills the full height
                    classIconTex:SetWidth(iconW)
                    classIconTex:SetHeight(iconH)
                    classIconTex:SetPoint("TOPLEFT", cardFrame, "TOPLEFT", 10, -1)
                    classIconTex:SetTexture(classIconTexPath)
                    -- Full square: no cropping needed when width == height
                    classIconTex:SetTexCoord(0, 1, 0, 1)
                    table.insert(f.rowBackgrounds, classIconTex)
                end

                local coloredName = CreateCharacterName(entry, false, true)
                if isStaleThisSeason then
                    coloredName = coloredName .. " |cff888888(last season)|r"
                end

                local function coloredRating(val)
                    return string.format("%s%d|r", GetRatingColor(val), val)
                end
                
                local function coloredCurrency(val, currencyType, data)
                    return string.format("%s%s|r", GetCurrencyColor(val, currencyType, data), FormatNumber(val))
                end

                -- Conquest cell: shows wallet amount, plus a green checkmark when
                -- the character has hit their weekly cap during the current reset week.
                -- For in-progress characters, shows earned/cap instead of wallet.
                local CONQUEST_CHECK = "|TInterface\\RaidFrame\\ReadyCheck-Ready:12:12:0:0|t"
                local function coloredConquestWithCap(data)
                    local amount = data.conquest or 0
                    local wd = data.conquestWeeklyData
                    local currentWeek = math.floor(GetServerTime() / (7 * 24 * 60 * 60))
                    if wd and wd.week == currentWeek then
                        if wd.cappedThisWeek then
                            return string.format("|cff00ff00%s|r %s", FormatNumber(amount), CONQUEST_CHECK)
                        elseif wd.weeklyEarned and wd.weeklyEarned > 0 and wd.weeklyCapAmount and wd.weeklyCapAmount > 0 then
                            return string.format("%s%s|r|cff666666/%s|r",
                                GetCurrencyColor(amount, "conquest", data),
                                FormatNumber(wd.weeklyEarned),
                                FormatNumber(wd.weeklyCapAmount))
                        end
                    end
                    return string.format("%s%s|r", GetCurrencyColor(amount, "conquest", data), FormatNumber(amount))
                end
                
                -- Unified display for any rating bracket.
                -- Handles flat numbers (2v2/3v3) and per-spec tables (Shuffle/Blitz)
                -- through the shared GetShuffleDisplayInfo path.
                local function getMultiSpecDisplay(data, charKey, bracketKey)
                    local currentRating, _, specCount = GetShuffleDisplayInfo(data, charKey, bracketKey)
                    local display = coloredRating(currentRating)
                    if specCount > 1 then
                        display = display .. " |TInterface\\Common\\FavoritesIcon:12|t"
                    end
                    return display
                end

                -- Returns true only when bracketStats has been written at least once for
                -- this bracket (even if the confirmed rating is 0, i.e. genuinely unrated).
                -- Returns false when the entry is nil — data was never fetched from the server.
                local function isRatingKnown(charKey, bracketKey)
                    local bs = PVPHUB_DB[charKey]
                               and PVPHUB_DB[charKey].bracketStats
                               and PVPHUB_DB[charKey].bracketStats[bracketKey]
                    return bs ~= nil
                end

                local DASH = "|cff555555—|r"

    local allValues = {
        { value = coloredName, key = "character" },
        { value = coloredCurrency(data.honor or 0, "honor", data), key = "honor" },
        { value = coloredConquestWithCap(data), key = "conquest" },
        { value = coloredCurrency(data.bloodstones or 0, "bloodstones", data), key = "bloodstones" },
        { value = coloredCurrency(data.bloodytokens or 0, "bloodytokens", data), key = "bloodytokens" },
        { value = isRatingKnown(entry.char, "rating2v2")     and getMultiSpecDisplay(data, entry.char, "rating2v2")     or DASH, key = "rating2v2" },
        { value = isRatingKnown(entry.char, "rating3v3")     and getMultiSpecDisplay(data, entry.char, "rating3v3")     or DASH, key = "rating3v3" },
        { value = isRatingKnown(entry.char, "ratingShuffle") and getMultiSpecDisplay(data, entry.char, "ratingShuffle") or DASH, key = "ratingShuffle" },
        { value = isRatingKnown(entry.char, "ratingBlitz")   and getMultiSpecDisplay(data, entry.char, "ratingBlitz")   or DASH, key = "ratingBlitz" },
        { value = isRatingKnown(entry.char, "ratingRBG")     and getMultiSpecDisplay(data, entry.char, "ratingRBG")     or DASH, key = "ratingRBG" },
    }
                
                -- Look up each value by key so row cells line up with
                -- visibleHeaders' order (which may be custom — see
                -- GetOrderedColumnHeaders) instead of assuming allValues'
                -- own fixed declaration order. Without this, dragging a
                -- header to a new position would move the label but leave
                -- the actual data in its old column.
                local valueByKey = {}
                for _, item in ipairs(allValues) do
                    valueByKey[item.key] = item.value
                end

                local values = {}
                for _, header in ipairs(visibleHeaders) do
                    table.insert(values, { value = valueByKey[header.key], key = header.key })
                end

                -- Hover highlight overlay: gradient fades out to the right like the fill.
                local hoverBG = cardFrame:CreateTexture(nil, "OVERLAY")
                hoverBG:SetTexture("Interface\\Buttons\\WHITE8x8")
                local theme = GetCurrentTheme()
                local hoverColor = theme.HOVER_BG
                hoverBG:SetGradient("HORIZONTAL",
                    CreateColor(hoverColor[1], hoverColor[2], hoverColor[3], hoverColor[4]),
                    CreateColor(hoverColor[1], hoverColor[2], hoverColor[3], 0))
                hoverBG:SetAllPoints(cardFrame)
                hoverBG:Hide()
                table.insert(f.rowBackgrounds, hoverBG)

                -- Expanded row panel: MMR under each CR column + info strip
                if isExpanded then
                    local lineH = panelFontSize + 5

                    -- Class-colored divider line
                    local divLine = cardFrame:CreateTexture(nil, "OVERLAY")
                    divLine:SetTexture("Interface\\Buttons\\WHITE8x8")
                    divLine:SetVertexColor(classColorInfo.r, classColorInfo.g, classColorInfo.b, 0.45)
                    divLine:SetPoint("TOPLEFT", cardFrame, "TOPLEFT", 10, -rowHeight)
                    divLine:SetSize(rowWidth - 20, 1)
                    table.insert(f.rowBackgrounds, divLine)

                    -- Spec-aware MMR lookup (newest mmrHistory → lastKnownMMR → mmrData)
                    local function getBracketMMR(bKey)
                        local charDB = PVPHUB_DB[entry.char]
                        if not charDB then return nil end
                        local isSpecBracket = (bKey == "ratingShuffle" or bKey == "ratingBlitz")
                        local currentSpecID = isSpecBracket and (charDB.specID or charDB.lastActiveSpecID) or nil
                        if charDB.mmrHistory and charDB.mmrHistory[bKey] then
                            local hist = charDB.mmrHistory[bKey]
                            for i = #hist, 1, -1 do
                                local m = hist[i]
                                if m.postMatchMMR and m.postMatchMMR > 0 then
                                    if not isSpecBracket or not currentSpecID or m.specID == currentSpecID then
                                        return m.postMatchMMR
                                    end
                                end
                            end
                            if isSpecBracket then return nil end
                        end
                        if charDB.lastKnownMMR and charDB.lastKnownMMR[bKey] then
                            if isSpecBracket and currentSpecID then
                                local d = charDB.lastKnownMMR[bKey][currentSpecID]
                                if type(d) == "table" and d.mmr and d.mmr > 0 then return d.mmr end
                                return nil
                            else
                                local best = 0
                                for _, d in pairs(charDB.lastKnownMMR[bKey]) do
                                    if d.mmr and d.mmr > best then best = d.mmr end
                                end
                                if best > 0 then return best end
                            end
                        end
                        if charDB.mmrData and charDB.mmrData[bKey] then
                            local bData = charDB.mmrData[bKey]
                            if type(bData) == "table" then
                                if bData.mmr and bData.mmr > 0 then return bData.mmr end
                                if isSpecBracket and currentSpecID then
                                    local sd = bData[currentSpecID]
                                    if type(sd) == "table" and sd.mmr and sd.mmr > 0 then return sd.mmr end
                                    return nil
                                else
                                    local best = 0
                                    for _, sd in pairs(bData) do
                                        if type(sd) == "table" and sd.mmr and sd.mmr > best then best = sd.mmr end
                                    end
                                    if best > 0 then return best end
                                end
                            end
                        end
                        return nil
                    end

                    local function fmtMMR(val)
                        if not val or val == 0 then return "|cff666666—|r" end
                        return GetRatingColor(val) .. val .. "|r"
                    end

                    -- Place each MMR value at exactly the same x as its rating column above.
                    -- Format: "<value> MMR" so the number leads.
                    local mmrY = y - rowHeight - 5
                    local RATING_KEYS = { rating2v2=true, rating3v3=true, ratingShuffle=true, ratingBlitz=true, ratingRBG=true }
                    for colIdx, item in ipairs(values) do
                        if RATING_KEYS[item.key] then
                            -- Create on cardFrame (child of contentFrame) so it is collected
                            -- by GetChildren() and properly detached on the next UpdateContent.
                            local mmrTxt = cardFrame:CreateFontString(nil, "OVERLAY", "GameFontWhite")
                            SafeSetFont(mmrTxt, panelFont, panelFontSize, "OUTLINE")
                            mmrTxt:SetShadowColor(0, 0, 0, 0.8)
                            mmrTxt:SetShadowOffset(1, -1)
                            mmrTxt:SetPoint("TOPLEFT", f.contentFrame, "TOPLEFT", f.xOffsets[colIdx] - 20, mmrY)
                            mmrTxt:SetText(fmtMMR(getBracketMMR(item.key)) .. " |cff888888MMR|r")
                            table.insert(f.rowBackgrounds, mmrTxt)
                        end
                    end

                    -- Last updated + realm: sits at the same y as the MMR strip,
                    -- anchored under the character name column (left edge).
                    local lastSeenStr = "|cff666666Unknown|r"
                    if data.lastSeen then
                        local diff = math.floor((GetServerTime() - data.lastSeen) / 86400)
                        if diff == 0 then
                            lastSeenStr = "|cff44ff44Today|r"
                        elseif diff == 1 then
                            lastSeenStr = "|cffccff44Yesterday|r"
                        elseif diff < 7 then
                            lastSeenStr = string.format("|cffffaa22%d days ago|r", diff)
                        else
                            lastSeenStr = string.format("|cffff6644%d days ago|r", diff)
                        end
                    end
                    local realm = entry.char:match("%-(.+)$") or "Unknown"
                    local charNameX = f.xOffsets[1] - 20 + (hasClassIcon and (rowHeight + 16) or 0)

                    -- Line 1: Last updated
                    -- Created on cardFrame so it is cleaned up by GetChildren() next cycle.
                    local infoRow = cardFrame:CreateFontString(nil, "OVERLAY", "GameFontWhite")
                    SafeSetFont(infoRow, panelFont, panelFontSize, "OUTLINE")
                    infoRow:SetShadowColor(0, 0, 0, 0.8)
                    infoRow:SetShadowOffset(1, -1)
                    infoRow:SetPoint("TOPLEFT", f.contentFrame, "TOPLEFT", charNameX, mmrY)
                    infoRow:SetText(string.format("|cffaaaaaaLast updated:|r %s", lastSeenStr))
                    table.insert(f.rowBackgrounds, infoRow)

                    -- Line 2: Realm (directly below)
                    local realmRow = cardFrame:CreateFontString(nil, "OVERLAY", "GameFontWhite")
                    SafeSetFont(realmRow, panelFont, panelFontSize, "OUTLINE")
                    realmRow:SetShadowColor(0, 0, 0, 0.8)
                    realmRow:SetShadowOffset(1, -1)
                    realmRow:SetPoint("TOPLEFT", f.contentFrame, "TOPLEFT", charNameX, mmrY - lineH)
                    realmRow:SetText(string.format("|cffaaaaaaRealm:|r |cffffcc00%s|r", realm))
                    table.insert(f.rowBackgrounds, realmRow)
                end

                -- Create invisible background button to handle gaps between columns
                local backgroundBtn = CreateFrame("Button", nil, f.contentFrame)
                backgroundBtn:SetPoint("TOPLEFT", f.contentFrame, "TOPLEFT", 0, y)
                backgroundBtn:SetSize(rowWidth, cardTotalH)
                backgroundBtn:SetFrameLevel(f.contentFrame:GetFrameLevel() + 1) -- Lower priority than column buttons
                backgroundBtn:SetScript("OnEnter", function()
                    hoverBG:Show()
                    local hbr = math.min(1.0, cardBorderR * 1.6)
                    local hbg = math.min(1.0, cardBorderG * 1.6)
                    local hbb = math.min(1.0, cardBorderB * 1.6)
                    local hba = math.min(1.0, cardBorderA * 1.4)
                    topLine:SetGradient("HORIZONTAL", CreateColor(hbr,hbg,hbb,hba), CreateColor(hbr,hbg,hbb,0))
                    botLine:SetGradient("HORIZONTAL", CreateColor(hbr,hbg,hbb,hba), CreateColor(hbr,hbg,hbb,0))
                    accentStrip:SetColorTexture(math.min(1,classColorInfo.r*1.5), math.min(1,classColorInfo.g*1.5), math.min(1,classColorInfo.b*1.5), 1.0)
                    accentStrip:SetWidth(11)
                end)
                backgroundBtn:SetScript("OnLeave", function()
                    hoverBG:Hide()
                    topLine:SetGradient("HORIZONTAL", CreateColor(cardBorderR,cardBorderG,cardBorderB,cardBorderA), CreateColor(cardBorderR,cardBorderG,cardBorderB,0))
                    botLine:SetGradient("HORIZONTAL", CreateColor(cardBorderR,cardBorderG,cardBorderB,cardBorderA), CreateColor(cardBorderR,cardBorderG,cardBorderB,0))
                    accentStrip:SetColorTexture(classColorInfo.r, classColorInfo.g, classColorInfo.b, 1.0)
                    accentStrip:SetWidth(8)
                end)
                backgroundBtn:RegisterForClicks("LeftButtonUp")
                backgroundBtn:SetScript("OnClick", nil)

                -- Create column content
                for i, item in ipairs(values) do
                    local val = item.value
                    local key = item.key

                    -- Resolve column width for this slot — must match the scaled widths used
                    -- when building xOffsets, otherwise buttons and text drift at non-default font sizes.
                    local colWidth = math.ceil(((visibleHeaders[i] and visibleHeaders[i].minWidth) or UI_CONSTANTS.COLUMN_WIDTHS.standard or 85) * fontScale)

                    local txt = cardFrame:CreateFontString(nil, "OVERLAY")
                    local fontSize = 12
                    SafeSetFont(txt, currentFont, fontSize, "OUTLINE")
                    table.insert(f.fontStrings, txt)
                    txt:SetShadowColor(0, 0, 0, 0.7)
                    txt:SetShadowOffset(1, -1)

                    local rowBackgroundHeight = dynamicRowHeight - 2
                    local verticalOffset = math.floor((rowBackgroundHeight - fontSize) / 2) + 1

                    local charColOffset = (key == "character" and hasClassIcon) and (rowHeight + 16) or 0
                    txt:SetPoint("TOPLEFT", f.contentFrame, "TOPLEFT", f.xOffsets[i] - 20 + charColOffset, y - verticalOffset)
                    local usableWidth = colWidth - charColOffset - 6
                    txt:SetWidth(usableWidth)
                    txt:SetNonSpaceWrap(false)
                    txt:SetWordWrap(false)
                    txt:SetJustifyH("LEFT")
                    txt:SetText(val)
                    
                    -- Create tooltip areas (invisible) for specific columns that need tooltips
                    local tooltipBtn = CreateFrame("Button", nil, f.contentFrame)
                    tooltipBtn:SetPoint("TOPLEFT", f.contentFrame, "TOPLEFT", f.xOffsets[i] - 20, y)
                    
                    tooltipBtn:SetSize(colWidth, dynamicRowHeight - 2)
                    if key == "character" then
                        tooltipBtn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
                    end
                    
                    tooltipBtn:SetFrameLevel(f.contentFrame:GetFrameLevel() + 10)
                    tooltipBtn.charName = entry.char
                    
                    -- Add note icon for character column (only when note exists)
                    if key == "character" then
                        local hasNote = PVPHUB_DB[entry.char] and PVPHUB_DB[entry.char].note and PVPHUB_DB[entry.char].note ~= ""
                        if hasNote then
                            local noteIconBtn = CreateFrame("Button", nil, f.contentFrame)
                            noteIconBtn:SetSize(16, 16)
                            -- Anchor to a fixed position near the right edge of the character column
                            -- so it never bleeds into the next (honor) column.
                            -- Column right edge in contentFrame coords = xOffsets[i] - 20 + colWidth
                            -- Place icon with its right edge 4px before the column boundary.
                            local noteX = f.xOffsets[i] - 20 + colWidth - 20
                            local noteY = y - math.floor((rowHeight - 16) / 2)
                            noteIconBtn:SetPoint("TOPLEFT", f.contentFrame, "TOPLEFT", noteX, noteY)
                            noteIconBtn:SetFrameLevel(f.contentFrame:GetFrameLevel() + 20) -- Higher than tooltipBtn
                            
                            local noteIconTexture = noteIconBtn:CreateTexture(nil, "ARTWORK")
                            noteIconTexture:SetAllPoints()
                            noteIconTexture:SetTexture("Interface\\Icons\\INV_Inscription_Parchment")
                            noteIconTexture:SetVertexColor(1, 0.82, 0, 1) -- Gold
                            
                            -- Show note on hover
                            noteIconBtn:SetScript("OnEnter", function(self)
                                GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                                GameTooltip:SetText("|cffFFD700Note:|r", 1, 1, 1, 1, true)
                                GameTooltip:AddLine(PVPHUB_DB[entry.char].note, 0.9, 0.9, 0.7, true)
                                GameTooltip:Show()
                            end)
                            noteIconBtn:SetScript("OnLeave", function()
                                GameTooltip:Hide()
                            end)
                            
                            table.insert(f.rowBackgrounds, noteIconBtn)
                        end
                    end
                    
                    -- Combined scripts - handle both highlighting and tooltips
                    tooltipBtn:SetScript("OnEnter", function()
                        hoverBG:Show()
                        local hbr = math.min(1.0, cardBorderR * 1.6)
                        local hbg = math.min(1.0, cardBorderG * 1.6)
                        local hbb = math.min(1.0, cardBorderB * 1.6)
                        local hba = math.min(1.0, cardBorderA * 1.4)
                        topLine:SetGradient("HORIZONTAL", CreateColor(hbr,hbg,hbb,hba), CreateColor(hbr,hbg,hbb,0))
                        botLine:SetGradient("HORIZONTAL", CreateColor(hbr,hbg,hbb,hba), CreateColor(hbr,hbg,hbb,0))
                        accentStrip:SetColorTexture(math.min(1,classColorInfo.r*1.5), math.min(1,classColorInfo.g*1.5), math.min(1,classColorInfo.b*1.5), 1.0)
                        accentStrip:SetWidth(11)

                        -- Show character tooltip for character column
                        if key == "character" then
                            ShowCharacterTooltip(entry.char, tooltipBtn)
                        -- Show tooltip for shuffle ratings
                        elseif key == "ratingShuffle" then
                            local shuffleData = data.ratingShuffle
                            
                            if type(shuffleData) == "table" then
                                local specCount = 0
                                local specsWithRating = {}
                                
                                -- Count specs with ratings > 0
                                for specID, rating in pairs(shuffleData) do
                                    if rating > 0 then
                                        specCount = specCount + 1
                                        table.insert(specsWithRating, {specID = specID, rating = rating})
                                    end
                                end
                                
                                -- Show tooltip if there are any specs with ratings > 0
                                if specCount > 0 then
                                    ShowPVPHUBRatingTooltip(tooltipBtn, entry.char, "ratingShuffle", shuffleData)
                                end
                            elseif type(shuffleData) == "number" and shuffleData > 0 then
                                ShowPVPHUBRatingTooltip(tooltipBtn, entry.char, "ratingShuffle", shuffleData)
                            end
                        -- Show tooltip for blitz ratings
                        elseif key == "ratingBlitz" then
                            local blitzData = data.ratingBlitz
                            if type(blitzData) == "table" then
                                local specCount = 0
                                local specsWithRating = {}
                                
                                -- Count specs with ratings > 0
                                for specID, rating in pairs(blitzData) do
                                    if rating > 0 then
                                        specCount = specCount + 1
                                        table.insert(specsWithRating, {specID = specID, rating = rating})
                                    end
                                end
                                
                                -- Show tooltip if there are any specs with ratings > 0
                                if specCount > 0 then
                                    ShowPVPHUBRatingTooltip(tooltipBtn, entry.char, "ratingBlitz", blitzData)
                                end
                            elseif type(blitzData) == "number" and blitzData > 0 then
                                ShowPVPHUBRatingTooltip(tooltipBtn, entry.char, "ratingBlitz", blitzData)
                            end
                        -- Show tooltip for RBG rating with MMR
                        elseif key == "ratingRBG" then
                            local rbgRating = data.ratingRBG
                            if rbgRating and rbgRating > 0 then
                                ShowPVPHUBRatingTooltip(tooltipBtn, entry.char, "ratingRBG", rbgRating)
                            end
                        -- Show tooltip for honor (current / cap)
                        elseif key == "honor" then
                            local honorAmount = data.honor or 0
                            GameTooltip:SetOwner(tooltipBtn, "ANCHOR_CURSOR")
                            GameTooltip:SetText("|cffe6cc80Honor|r", 1, 1, 1)
                            GameTooltip:AddLine("Earned from PvP activities.", 1, 0.82, 0)
                            GameTooltip:AddLine(" ", 1, 1, 1)
                            local honorColor = GetCurrencyColor(honorAmount, "honor", data)
                            local capInfo = C_CurrencyInfo.GetCurrencyInfo(CURRENCY_IDS.honor)
                            if capInfo and capInfo.maxQuantity and capInfo.maxQuantity > 0 then
                                GameTooltip:AddDoubleLine("Current:", honorColor .. FormatNumber(honorAmount) .. "|r / |cffffffff" .. FormatNumber(capInfo.maxQuantity) .. "|r", 0.7, 0.7, 0.7, 1, 1, 1)
                            else
                                GameTooltip:AddDoubleLine("Current:", honorColor .. FormatNumber(honorAmount) .. "|r", 0.7, 0.7, 0.7, 1, 1, 1)
                            end
                            if capInfo and capInfo.quantityEarnedThisWeek and capInfo.quantityEarnedThisWeek > 0 then
                                GameTooltip:AddDoubleLine("Earned this week:", "|cffffffff" .. FormatNumber(capInfo.quantityEarnedThisWeek) .. "|r", 0.7, 0.7, 0.7, 1, 1, 1)
                            end
                            GameTooltip:Show()
                        -- Show tooltip for conquest
                        elseif key == "conquest" then
                            local currentAmount = data.conquest or 0
                            GameTooltip:SetOwner(tooltipBtn, "ANCHOR_CURSOR")
                            GameTooltip:SetText("|cff0070ddConquest|r", 1, 1, 1)
                            GameTooltip:AddLine("Earned from PvP activities.", 1, 0.82, 0)
                            GameTooltip:AddLine(" ", 1, 1, 1)
                            local capInfo      = C_CurrencyInfo.GetCurrencyInfo(CURRENCY_IDS.conquest)
                            local seasonCap    = capInfo and capInfo.maxQuantity and capInfo.maxQuantity > 0 and capInfo.maxQuantity or nil
                            local weeklyData   = data.conquestWeeklyData
                            local seasonEarned = weeklyData and weeklyData.seasonMaximum and weeklyData.seasonMaximum > 0 and weeklyData.seasonMaximum or nil
                            local cappedThisWeek = weeklyData and weeklyData.cappedThisWeek
                            local weeklyEarned = capInfo and capInfo.quantityEarnedThisWeek or 0
                            -- Season progress — the primary metric
                            if seasonEarned then
                                local seasonColor = cappedThisWeek and "|cffff4444" or "|cffffff00"
                                if seasonCap then
                                    GameTooltip:AddDoubleLine("Season:", seasonColor .. FormatNumber(seasonEarned) .. "|r / |cffffffff" .. FormatNumber(seasonCap) .. "|r", 0.7, 0.7, 0.7, 1, 1, 1)
                                else
                                    GameTooltip:AddDoubleLine("Season:", "|cffffffff" .. FormatNumber(seasonEarned) .. "|r  |cff888888(uncapped)|r", 0.7, 0.7, 0.7, 1, 1, 1)
                                end
                            end
                            -- Weekly cap status
                            if cappedThisWeek then
                                GameTooltip:AddDoubleLine("This week:", "|cff00ff00Capped|r", 0.7, 0.7, 0.7, 1, 1, 1)
                            elseif weeklyEarned > 0 then
                                GameTooltip:AddDoubleLine("This week:", "|cffffff00" .. FormatNumber(weeklyEarned) .. "|r earned", 0.7, 0.7, 0.7, 1, 1, 1)
                            end
                            -- Wallet — what you currently have to spend on gear (no cap denominator: same number as season cap would just confuse)
                            local currentColor = GetCurrencyColor(currentAmount, "conquest", data)
                            GameTooltip:AddDoubleLine("Current:", currentColor .. FormatNumber(currentAmount) .. "|r", 0.7, 0.7, 0.7, 1, 1, 1)
                            GameTooltip:Show()
                        -- Show tooltip for bloody tokens
                        elseif key == "bloodstones" then
                            local currentAmount = data.bloodstones or 0
                            GameTooltip:SetOwner(tooltipBtn, "ANCHOR_CURSOR")
                            GameTooltip:SetText("|cff9b59b6Heliotrope|r", 1, 1, 1)
                            GameTooltip:AddLine("Infused Heliotrope — used for PvP crafting.", 1, 0.82, 0)
                            GameTooltip:AddLine(" ", 1, 1, 1)
                            GameTooltip:AddDoubleLine("Current:", "|cffffffff" .. FormatNumber(currentAmount) .. "|r", 0.7, 0.7, 0.7, 1, 1, 1)
                            GameTooltip:Show()
                        elseif key == "bloodytokens" then
                            local currentAmount = data.bloodytokens or 0
                            GameTooltip:SetOwner(tooltipBtn, "ANCHOR_CURSOR")
                            GameTooltip:SetText("|cffff2020Bloody Tokens|r", 1, 1, 1)
                            GameTooltip:AddLine("Earned from War Mode activities.", 1, 0.82, 0)
                            GameTooltip:AddLine(" ", 1, 1, 1)
                            local capInfo      = C_CurrencyInfo.GetCurrencyInfo(CURRENCY_IDS.bloodytokens)
                            local seasonCap    = capInfo and capInfo.maxQuantity and capInfo.maxQuantity > 0 and capInfo.maxQuantity or nil
                            local weeklyData   = data.bloodytokensWeeklyData
                            local seasonEarned = weeklyData and weeklyData.seasonMaximum and weeklyData.seasonMaximum > 0 and weeklyData.seasonMaximum or nil
                            local cappedThisWeek = weeklyData and weeklyData.cappedThisWeek
                            local weeklyEarned = capInfo and capInfo.quantityEarnedThisWeek or 0
                            -- Season progress
                            if seasonEarned then
                                local seasonColor = cappedThisWeek and "|cffff4444" or "|cffffff00"
                                if seasonCap then
                                    GameTooltip:AddDoubleLine("Season:", seasonColor .. FormatNumber(seasonEarned) .. "|r / |cffffffff" .. FormatNumber(seasonCap) .. "|r", 0.7, 0.7, 0.7, 1, 1, 1)
                                else
                                    GameTooltip:AddDoubleLine("Season:", "|cffffffff" .. FormatNumber(seasonEarned) .. "|r  |cff888888(uncapped)|r", 0.7, 0.7, 0.7, 1, 1, 1)
                                end
                            end
                            -- Weekly cap status
                            if cappedThisWeek then
                                GameTooltip:AddDoubleLine("This week:", "|cff00ff00Capped|r", 0.7, 0.7, 0.7, 1, 1, 1)
                            elseif weeklyEarned > 0 then
                                GameTooltip:AddDoubleLine("This week:", "|cffffff00" .. FormatNumber(weeklyEarned) .. "|r earned", 0.7, 0.7, 0.7, 1, 1, 1)
                            end
                            -- Wallet
                            local currentColor = GetCurrencyColor(currentAmount, "bloodytokens", data)
                            GameTooltip:AddDoubleLine("Current:", currentColor .. FormatNumber(currentAmount) .. "|r", 0.7, 0.7, 0.7, 1, 1, 1)
                            GameTooltip:Show()
                        -- Show tooltip for 2v2 rating with MMR
                        elseif key == "rating2v2" then
                            local rating = data.rating2v2
                            if rating and rating > 0 then
                                ShowPVPHUBRatingTooltip(tooltipBtn, entry.char, "rating2v2", rating)
                            end
                        -- Show tooltip for 3v3 rating with MMR
                        elseif key == "rating3v3" then
                            local rating = data.rating3v3
                            if rating and rating > 0 then
                                ShowPVPHUBRatingTooltip(tooltipBtn, entry.char, "rating3v3", rating)
                            end
                        end
                    end)
                    tooltipBtn:SetScript("OnLeave", function()
                        hoverBG:Hide()
                        topLine:SetGradient("HORIZONTAL", CreateColor(cardBorderR,cardBorderG,cardBorderB,cardBorderA), CreateColor(cardBorderR,cardBorderG,cardBorderB,0))
                        botLine:SetGradient("HORIZONTAL", CreateColor(cardBorderR,cardBorderG,cardBorderB,cardBorderA), CreateColor(cardBorderR,cardBorderG,cardBorderB,0))
                        accentStrip:SetColorTexture(classColorInfo.r, classColorInfo.g, classColorInfo.b, 1.0)
                        accentStrip:SetWidth(8)
                        if key == "character" then
                            HideCharacterTooltip()
                        else
                            GameTooltip:Hide()
                            ClosePVPHUBRatingTooltip()
                        end
                    end)
                    
                    -- Character selection and pin functionality
                    if key == "character" then
                        tooltipBtn:SetScript("OnClick", function(self, button)
                            if button == "LeftButton" then
                                -- Toggle expand; clicking the expanded char collapses it
                                if PVPHUB.expandedChar == self.charName then
                                    PVPHUB.expandedChar = nil
                                    PVPHUB.selectedChar = nil
                                else
                                    PVPHUB.expandedChar = self.charName
                                    PVPHUB.selectedChar = self.charName
                                end
                                f:UpdateContent()
                            elseif button == "RightButton" then
                                -- Initialize pinned character setting if not present
                                if not PVPHUB_SETTINGS.mainWindow then
                                    PVPHUB_SETTINGS.mainWindow = {}
                                end
                                
                                local currentPinnedChar = PVPHUB_SETTINGS.mainWindow.pinnedCharacter
                                local isCurrentlyPinned = (currentPinnedChar == self.charName)
                                
                                -- Create dropdown menu
                                local function InitializeDropDown(self, level)
                                    level = level or 1
                                    local info = UIDropDownMenu_CreateInfo()
                                    
                                    -- Handle group submenu
                                    if level == 2 and UIDROPDOWNMENU_MENU_VALUE == "GROUPS" then
                                        local currentGroupIndex = GetCharacterGroup(tooltipBtn.charName)
                                        for i, group in ipairs(PVPHUB_SETTINGS.characterGroups.groups) do
                                            info = UIDropDownMenu_CreateInfo()
                                            info.text = group.name
                                            info.checked = (i == currentGroupIndex)
                                            info.func = function()
                                                MoveCharacterToGroup(tooltipBtn.charName, i)
                                                f:UpdateContent()
                                                CloseDropDownMenus()
                                                PVPHubPrint("|cff00ff00[PVPHUB]|r Moved character to group '" .. group.name .. "'")
                                            end
                                            UIDropDownMenu_AddButton(info, level)
                                        end
                                        return
                                    end
                                    
                                    -- Main menu (level 1)
                                    if isCurrentlyPinned then
                                        -- Character is pinned, show unpin option
                                        info.text = "Unpin from Top"
                                        info.icon = "Interface\\Buttons\\UI-GroupLoot-Pass-Up"
                                        info.func = function()
                                            PVPHUB_SETTINGS.mainWindow.pinnedCharacter = nil
                                            f:UpdateContent()
                                            CloseDropDownMenus()
                                        end
                                        info.notCheckable = true
                                        UIDropDownMenu_AddButton(info, level)
                                    else
                                        -- Character is not pinned, show pin option
                                        info.text = "Pin to Top"
                                        info.icon = "Interface\\Minimap\\UI-Minimap-ZoomInButton-Up"
                                        info.func = function()
                                            PVPHUB_SETTINGS.mainWindow.pinnedCharacter = tooltipBtn.charName
                                            f:UpdateContent()
                                            CloseDropDownMenus()
                                        end
                                        info.notCheckable = true
                                        UIDropDownMenu_AddButton(info, level)
                                    end
                                    
                                    -- Add separator
                                    info = UIDropDownMenu_CreateInfo()
                                    info.text = ""
                                    info.isTitle = true
                                    info.notCheckable = true
                                    UIDropDownMenu_AddButton(info, level)
                                    
                                    -- Add Move to Group option (if grouping enabled)
                                    if PVPHUB_SETTINGS.characterGroups and PVPHUB_SETTINGS.characterGroups.enabled and PVPHUB_SETTINGS.characterGroups.groups then
                                        info = UIDropDownMenu_CreateInfo()
                                        info.text = "Move to Group"
                                        info.icon = "Interface\\Icons\\INV_Misc_GroupLooking"
                                        info.hasArrow = true
                                        info.notCheckable = true
                                        info.value = "GROUPS"
                                        UIDropDownMenu_AddButton(info, level)
                                    end
                                    
                                    -- Add separator
                                    info = UIDropDownMenu_CreateInfo()
                                    info.text = ""
                                    info.isTitle = true
                                    info.notCheckable = true
                                    UIDropDownMenu_AddButton(info, level)
                                    
                                    -- Add Edit Note option
                                    info = UIDropDownMenu_CreateInfo()
                                    local hasNote = PVPHUB_DB[tooltipBtn.charName] and PVPHUB_DB[tooltipBtn.charName].note
                                    info.text = hasNote and "Edit Note" or "Add Note"
                                    info.icon = "Interface\\Icons\\INV_Inscription_Parchment"
                                    info.func = function()
                                        local popup = StaticPopup_Show("PVPHUB_EDIT_NOTE")
                                        if popup then
                                            popup.charKey = tooltipBtn.charName
                                        end
                                        CloseDropDownMenus()
                                    end
                                    info.notCheckable = true
                                    UIDropDownMenu_AddButton(info, level)
                                    
                                    -- Add separator
                                    info = UIDropDownMenu_CreateInfo()
                                    info.text = ""
                                    info.isTitle = true
                                    info.notCheckable = true
                                    UIDropDownMenu_AddButton(info, level)
                                    
                                    -- Add Hide Character option
                                    info = UIDropDownMenu_CreateInfo()
                                    info.text = "Hide Character"
                                    info.icon = "Interface\\Buttons\\UI-GuildButton-MOTD-Disabled"
                                    info.func = function()
                                        HideCharacter(tooltipBtn.charName)
                                        CloseDropDownMenus()
                                    end
                                    info.notCheckable = true
                                    UIDropDownMenu_AddButton(info, level)
                                    
                                    -- Add Delete Character option
                                    info = UIDropDownMenu_CreateInfo()
                                    info.text = "|cffff4040Delete Character|r"
                                    info.icon = "Interface\\Buttons\\UI-GroupLoot-Pass-Down"
                                    info.func = function()
                                        PVPHUB._deleteCharCtx = tooltipBtn.charName
                                        StaticPopupDialogs["PVPHUB_DELETE_CHARACTER"].text = "Are you sure you want to permanently delete all data for |cff4da6ff" .. tooltipBtn.charName .. "|r?\n\nThis action cannot be undone!"
                                        StaticPopup_Show("PVPHUB_DELETE_CHARACTER")
                                        CloseDropDownMenus()
                                    end
                                    info.notCheckable = true
                                    UIDropDownMenu_AddButton(info, level)
                                    
                                    -- Add Manage Hidden Characters option
                                    info = UIDropDownMenu_CreateInfo()
                                    info.text = "Manage Hidden Characters"
                                    info.icon = "Interface\\Buttons\\UI-GuildButton-PublicNote-Up"
                                    info.func = function()
                                        ShowHiddenCharactersWindow()
                                        CloseDropDownMenus()
                                    end
                                    info.notCheckable = true
                                    UIDropDownMenu_AddButton(info, level)
                                end
                                
                                -- Create the dropdown menu frame if it doesn't exist
                                if not PVPHUB.pinDropdownMenu then
                                    PVPHUB.pinDropdownMenu = CreateFrame("Frame", "PVPHUBPinDropdown", UIParent, "UIDropDownMenuTemplate")
                                end
                                
                                UIDropDownMenu_Initialize(PVPHUB.pinDropdownMenu, InitializeDropDown, "MENU")
                                ToggleDropDownMenu(1, nil, PVPHUB.pinDropdownMenu, "cursor", 3, -3)
                            end
                        end)
                    else
                        -- Non-character columns: left-click toggles expand
                        tooltipBtn:SetScript("OnClick", function(self, button)
                            if button == "LeftButton" then
                                if PVPHUB.expandedChar == entry.char then
                                    PVPHUB.expandedChar = nil
                                    PVPHUB.selectedChar = nil
                                else
                                    PVPHUB.expandedChar = entry.char
                                    PVPHUB.selectedChar = entry.char
                                end
                                f:UpdateContent()
                            end
                        end)
                    end

                    table.insert(f.rows, txt)
                end -- End of for i, item in ipairs(values) do
                end -- End of if entry.isGroupHeader else
            end -- End of for _, entry in ipairs(displayList)

            -- Set content frame height
            f.contentFrame:SetHeight(math.max(contentHeight, 100))

            -- Create/update summary
            if not f.summaryTopLine then
                f.summaryTopLine = f:CreateTexture(nil, "ARTWORK")
                f.summaryTopLine:SetTexture("Interface\\Buttons\\WHITE8x8")
                f.summaryTopLine:SetVertexColor(unpack(UI_CONSTANTS.COLORS.SUMMARY_LINE))
                f.summaryTopLine:SetSize(dynamicContentWidth - 30, 1) -- Subtract margin to match content width
                f.summaryTopLine:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 20, 50) -- Moved down from 72 to 50
            else
                f.summaryTopLine:SetVertexColor(unpack(UI_CONSTANTS.COLORS.SUMMARY_LINE))
                -- Update summary line width to match dynamic content width with proper margin
                f.summaryTopLine:SetSize(dynamicContentWidth - 30, 1) -- Subtract margin to match content width
            end

            -- Always keep summary text white regardless of theme

            if not f.honorText then
                -- Three separate FontStrings so tooltip buttons track exact text bounds
                f.honorText = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
                f.honorText:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 25, 33)
                f.honorText:SetShadowColor(0, 0, 0, 0.7)
                f.honorText:SetShadowOffset(1, -1)

                f.conquestText = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
                f.conquestText:SetPoint("LEFT", f.honorText, "RIGHT", 6, 0)
                f.conquestText:SetShadowColor(0, 0, 0, 0.7)
                f.conquestText:SetShadowOffset(1, -1)

                f.goldText = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
                f.goldText:SetPoint("LEFT", f.conquestText, "RIGHT", 6, 0)
                f.goldText:SetShadowColor(0, 0, 0, 0.7)
                f.goldText:SetShadowOffset(1, -1)

                -- Keep summaryText as alias so existing references still work
                f.summaryText = f.honorText

                -- Local formatNumber function for tooltips
                local function tooltipFormatNumber(num)
                    local formatted = tostring(num)
                    local k
                    while true do
                        formatted, k = string.gsub(formatted, "^(-?%d+)(%d%d%d)", '%1.%2')
                        if k == 0 then break end
                    end
                    return formatted
                end

                -- Tooltip buttons anchored directly to their FontString so they always align
                -- Honor tooltip button
                f.honorTooltipBtn = CreateFrame("Button", nil, f)
                f.honorTooltipBtn:SetPoint("TOPLEFT", f.honorText, "TOPLEFT", 0, 0)
                f.honorTooltipBtn:SetPoint("BOTTOMRIGHT", f.honorText, "BOTTOMRIGHT", 0, 0)
                f.honorTooltipBtn:SetFrameLevel(f:GetFrameLevel() + 1)
                
                f.honorTooltipBtn:SetScript("OnEnter", function()
                    -- Collect character data
                    local honorThreshold = (PVPHUB_SETTINGS.mainWindow and PVPHUB_SETTINGS.mainWindow.honorThreshold) or 0
                    local charData = {}
                    for charKey, data in pairs(PVPHUB_DB) do
                        if type(data) == "table" and charKey ~= "settings" and not IsCharacterHidden(charKey) and (data.honor or 0) > honorThreshold then
                            table.insert(charData, {
                                char = charKey,
                                honor = data.honor or 0,
                                class = data.class or "WARRIOR"
                            })
                        end
                    end

                    -- Sort by highest honor
                    table.sort(charData, function(a, b) return a.honor > b.honor end)

                    local entries = {}
                    for _, entry in ipairs(charData) do
                        local classColor = RAID_CLASS_COLORS[entry.class] or RAID_CLASS_COLORS["WARRIOR"]
                        local coloredName = string.format("|cff%02x%02x%02x%s|r",
                            classColor.r * 255, classColor.g * 255, classColor.b * 255, entry.char)
                        table.insert(entries, { char = entry.char, coloredName = coloredName,
                            value = "|cffffffff" .. tooltipFormatNumber(entry.honor) .. "|r" })
                    end

                    ShowTotalsPopup(f.honorTooltipBtn, "Total Honor", { 1, 0.42, 0 }, entries)
                end)

                f.honorTooltipBtn:SetScript("OnLeave", function()
                    ScheduleHideTotalsPopup()
                end)
                
                -- Conquest tooltip button
                f.conquestTooltipBtn = CreateFrame("Button", nil, f)
                f.conquestTooltipBtn:SetPoint("TOPLEFT", f.conquestText, "TOPLEFT", 0, 0)
                f.conquestTooltipBtn:SetPoint("BOTTOMRIGHT", f.conquestText, "BOTTOMRIGHT", 0, 0)
                f.conquestTooltipBtn:SetFrameLevel(f:GetFrameLevel() + 1)
                
                f.conquestTooltipBtn:SetScript("OnEnter", function()
                    -- Collect character data. Excludes characters that haven't
                    -- logged in since the season changed (see
                    -- IsCharacterStaleThisSeason) — Blizzard zeroes Conquest
                    -- out at the season boundary, so a stale character's
                    -- cached data.conquest is a known-wrong pre-reset amount,
                    -- same reasoning as the totalConquest summary above.
                    local conquestThreshold = (PVPHUB_SETTINGS.mainWindow and PVPHUB_SETTINGS.mainWindow.conquestThreshold) or 0
                    local charData = {}
                    for charKey, data in pairs(PVPHUB_DB) do
                        if type(data) == "table" and charKey ~= "settings" and not IsCharacterHidden(charKey)
                           and not IsCharacterStaleThisSeason(charKey) and (data.conquest or 0) > conquestThreshold then
                            table.insert(charData, {
                                char = charKey,
                                conquest = data.conquest or 0,
                                class = data.class or "WARRIOR"
                            })
                        end
                    end

                    -- Sort by highest conquest
                    table.sort(charData, function(a, b) return a.conquest > b.conquest end)

                    local entries = {}
                    for _, entry in ipairs(charData) do
                        local classColor = RAID_CLASS_COLORS[entry.class] or RAID_CLASS_COLORS["WARRIOR"]
                        local coloredName = string.format("|cff%02x%02x%02x%s|r",
                            classColor.r * 255, classColor.g * 255, classColor.b * 255, entry.char)
                        table.insert(entries, { char = entry.char, coloredName = coloredName,
                            value = "|cffffffff" .. tooltipFormatNumber(entry.conquest) .. "|r" })
                    end

                    ShowTotalsPopup(f.conquestTooltipBtn, "Total Conquest", { 0.64, 0.21, 0.93 }, entries)
                end)

                f.conquestTooltipBtn:SetScript("OnLeave", function()
                    ScheduleHideTotalsPopup()
                end)
                
                -- Gold tooltip button
                f.goldTooltipBtn = CreateFrame("Button", nil, f)
                f.goldTooltipBtn:SetPoint("TOPLEFT", f.goldText, "TOPLEFT", 0, 0)
                f.goldTooltipBtn:SetPoint("BOTTOMRIGHT", f.goldText, "BOTTOMRIGHT", 0, 0)
                f.goldTooltipBtn:SetFrameLevel(f:GetFrameLevel() + 1)
                
                f.goldTooltipBtn:SetScript("OnEnter", function()
                    -- Collect character data
                    local goldThreshold = ((PVPHUB_SETTINGS.mainWindow and PVPHUB_SETTINGS.mainWindow.goldThreshold) or 0) * 10000 -- gold -> copper
                    local charData = {}
                    for charKey, data in pairs(PVPHUB_DB) do
                        if type(data) == "table" and charKey ~= "settings" and not IsCharacterHidden(charKey) and (data.gold or 0) > goldThreshold then
                            table.insert(charData, {
                                char = charKey,
                                gold = data.gold or 0,
                                class = data.class or "WARRIOR"
                            })
                        end
                    end

                    -- Sort by highest gold
                    table.sort(charData, function(a, b) return a.gold > b.gold end)

                    local function FormatGoldCopper(copper)
                        local goldAmount = copper / 10000 -- Convert copper to gold
                        if goldAmount >= 1000000 then
                            return string.format("%.1fM", goldAmount / 1000000)
                        elseif goldAmount >= 1000 then
                            return string.format("%.1fk", goldAmount / 1000)
                        else
                            return string.format("%.0f", goldAmount)
                        end
                    end

                    local entries = {}

                    -- Warband Bank first — account-wide, not a character, so
                    -- it has no delete button (nil char) and isn't part of
                    -- the per-character loop above. Only shown once we've
                    -- actually fetched a value (see FetchWarbandGold).
                    if PVPHUB_SETTINGS.warbandGold then
                        table.insert(entries, {
                            char = nil,
                            coloredName = "|cff00ccffWarband Bank|r",
                            value = "|cffffffff" .. FormatGoldCopper(PVPHUB_SETTINGS.warbandGold) .. "|r",
                        })
                    end

                    for _, entry in ipairs(charData) do
                        local classColor = RAID_CLASS_COLORS[entry.class] or RAID_CLASS_COLORS["WARRIOR"]
                        local coloredName = string.format("|cff%02x%02x%02x%s|r",
                            classColor.r * 255, classColor.g * 255, classColor.b * 255, entry.char)
                        table.insert(entries, { char = entry.char, coloredName = coloredName,
                            value = "|cffffffff" .. FormatGoldCopper(entry.gold) .. "|r" })
                    end

                    ShowTotalsPopup(f.goldTooltipBtn, "Total Gold", { 1, 1, 0 }, entries)
                end)

                f.goldTooltipBtn:SetScript("OnLeave", function()
                    ScheduleHideTotalsPopup()
                end)
            end
            
            -- Match the user's font and size settings
            SafeSetFont(f.honorText,    currentFont, 12, "OUTLINE")
            SafeSetFont(f.conquestText, currentFont, 12, "OUTLINE")
            SafeSetFont(f.goldText,     currentFont, 12, "OUTLINE")
            table.insert(f.fontStrings, f.honorText)
            table.insert(f.fontStrings, f.conquestText)
            table.insert(f.fontStrings, f.goldText)

            -- Always keep summary text white
            f.honorText:SetTextColor(1, 1, 1, 1)
            f.conquestText:SetTextColor(1, 1, 1, 1)
            f.goldText:SetTextColor(1, 1, 1, 1)

            -- Format numbers with thousand separators (decimal points)
            local function formatNumber(num)
                local formatted = tostring(num)
                local k
                while true do
                    formatted, k = string.gsub(formatted, "^(-?%d+)(%d%d%d)", '%1.%2')
                    if k == 0 then break end
                end
                return formatted
            end

            -- Format total gold nicely
            local totalGoldFormatted = ""
            local goldAmount = totalGold / 10000 -- Convert copper to gold
            if goldAmount >= 1000000 then
                totalGoldFormatted = string.format("%.1fM", goldAmount / 1000000)
            elseif goldAmount >= 1000 then
                totalGoldFormatted = string.format("%.1fk", goldAmount / 1000)
            else
                totalGoldFormatted = string.format("%.0f", goldAmount)
            end

            -- Format summary text with currency icons matching column headers
            local honorIcon = "|T1455894:0:0:0:0|t"  -- Same as column header
            local conquestIcon = "|T1523630:0:0:0:0|t"  -- Same as column header
            local goldIcon = "|TInterface\\MoneyFrame\\UI-GoldIcon:0:0:0:0|t"
            
            -- Each FontString is auto-sized to its content; buttons track them via anchors
            f.honorText:SetText(string.format("%s Honor: %s", honorIcon, formatNumber(totalHonor)))
            f.conquestText:SetText(string.format("%s Conquest: %s", conquestIcon, formatNumber(totalConquest)))
            f.goldText:SetText(string.format("%s Gold: %s", goldIcon, totalGoldFormatted))

            -- Update Note section - single line only
            if not f.updateNote then
                -- Single line: Icon + Note + Season info
                f.updateNote = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
                f.updateNote:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 25, 8) -- Moved closer to bottom border
                f.updateNote:SetShadowColor(0, 0, 0, 0.8)
                f.updateNote:SetShadowOffset(1, -1)
                f.updateNote:SetWidth(UI_CONSTANTS.CONTENT_WIDTH - 40)
                f.updateNote:SetJustifyH("LEFT")
            end
            
            -- Apply default font only (never changes with user selection)
            RegisterTrackedFont(f.updateNote, 11, "OUTLINE")
            
            -- Update colors for note line
            f.updateNote:SetTextColor(0.9, 0.85, 0.5, 1) -- Keep warm yellow for visibility
            f.updateNote:SetShadowColor(0, 0, 0, 0.8)
            f.updateNote:SetShadowOffset(1, -1)
            
            -- Set the content for the single note line
            f.updateNote:SetText("|TInterface\\Icons\\achievement_pvp_a_01:16|t Season 2 is finally here! Make sure you enjoy it!")
            
            -- Dynamic height adjustment based on content
            if not PVPHUB_SETTINGS.windowSize or not PVPHUB_SETTINGS.windowSize.userResized then
                local characterCount = #sorted
                local headerHeight = 120  -- Header area with buttons
                local footerHeight = 60   -- Footer area
                local dynamicRowHeight = GetDynamicRowHeight()
                local characterRowsHeight = characterCount * dynamicRowHeight
                local calculatedHeight = headerHeight + characterRowsHeight + footerHeight
                
                -- Comfortable minimum, grow with content
                local settingsBaselineHeight = 420
                local screenHeight = UIParent:GetHeight()
                local minHeight = settingsBaselineHeight
                local maxHeight = math.min(600, screenHeight * 0.60) -- Activate scrolling sooner
                local optimalHeight = math.min(maxHeight, math.max(minHeight, calculatedHeight))
                
                -- Only resize if significantly different from current height
                local currentHeight = f:GetHeight()
                if math.abs(currentHeight - optimalHeight) > 50 then
                    f:SetHeight(optimalHeight)
                    -- Save the new size but don't mark as user-resized
                    PVPHUB_SETTINGS.windowSize = PVPHUB_SETTINGS.windowSize or {}
                    PVPHUB_SETTINGS.windowSize.height = optimalHeight
                end
            end
        end

        PVPHUB.window = f
        if PVPHUB.Themes then PVPHUB.Themes:UpdateWindow(f) end
        tinsert(UISpecialFrames, f:GetName())

        -- Ensure window fits properly on screen after creation
        AdjustWindowToScreen(f)
        
        -- Only update content if we're in characters tab (we always start in characters tab now)
        if f.currentTab == "characters" then
            f:UpdateContent()
        end
    else
        PVPHUB.window:Show()
        if PVPHUB.Themes then PVPHUB.Themes:UpdateWindow(PVPHUB.window) end
        -- Trigger fade animation when reopening the window
        if PVPHUB.window.StartFadeInAnimation then
            PVPHUB.window.StartFadeInAnimation()
        end
    end
end




-- ============================================================
-- Shared module API — these locals are exposed on the PVPHUB
-- namespace so compact.lua and popups.lua (loaded after this
-- file) can reference them without breaking local scoping.
-- ============================================================
PVPHUB._UI_CONSTANTS                = UI_CONSTANTS
PVPHUB._PVPHUB_CONSTANTS            = PVPHUB_CONSTANTS
PVPHUB._IsInActivePvP               = IsInActivePvP
PVPHUB._GetCurrentTheme             = GetCurrentTheme
PVPHUB._IsCharacterHidden           = IsCharacterHidden
PVPHUB._GetRatingColor              = GetRatingColor
PVPHUB._GetShuffleDisplayInfo       = GetShuffleDisplayInfo
PVPHUB._ApplyModernScrollbarStyling = ApplyModernScrollbarStyling
PVPHUB._ApplyModernDropdownStyling  = ApplyModernDropdownStyling
PVPHUB._FormatNumber                = FormatNumber
PVPHUB._PVP_BRACKETS                = PVP_BRACKETS
PVPHUB._GetFullName                 = GetFullName
PVPHUB._PVPHubPrint                 = PVPHubPrint
PVPHUB._CreateCharacterName         = CreateCharacterName
PVPHUB._ShowCharacterTooltip        = ShowCharacterTooltip
PVPHUB._HideCharacterTooltip        = HideCharacterTooltip
PVPHUB._ShowPVPHUBRatingTooltip     = ShowPVPHUBRatingTooltip
PVPHUB._ClosePVPHUBRatingTooltip    = ClosePVPHUBRatingTooltip
PVPHUB._GetCachedSpecInfo           = GetCachedSpecInfo
PVPHUB._GetSeasonDisplayName        = GetSeasonDisplayName


-- Honor Warning System (Current Character Only)
local ShowHonorWarning  -- forward declaration; defined below
local function CheckHonorWarnings()
    -- Check if honor warnings are disabled
    if PVPHUB_SETTINGS.disableHonorWarnings then
        return -- Exit early if warnings are disabled
    end
    
    local currentChar = GetFullName()
    if not currentChar or not PVPHUB_DB[currentChar] then return end
    
    local currentHonor = PVPHUB_DB[currentChar].honor or 0
    -- Warn once honor is within 1000 of the actual cap so this doesn't go
    -- stale if Blizzard changes the honor cap; 14000 is just the fallback.
    local warningThreshold = 14000
    local honorInfo = C_CurrencyInfo and C_CurrencyInfo.GetCurrencyInfo and C_CurrencyInfo.GetCurrencyInfo(1792)
    if honorInfo and honorInfo.maxQuantity and honorInfo.maxQuantity > 0 then
        warningThreshold = honorInfo.maxQuantity - 1000
    end
    
    -- Initialize honor warnings table if it doesn't exist
    PVPHUB_SETTINGS.honorWarnings = PVPHUB_SETTINGS.honorWarnings or {}
    
    -- Check if character hit 14k honor and hasn't been warned yet
    if currentHonor >= warningThreshold then
        if not PVPHUB_SETTINGS.honorWarnings[currentChar] then
            -- Mark as warned
            PVPHUB_SETTINGS.honorWarnings[currentChar] = true
            
            -- Show honor warning notification
            ShowHonorWarning(currentChar, currentHonor)
        end
    else
        -- Reset warning if honor dropped below threshold (allows re-warning)
        if PVPHUB_SETTINGS.honorWarnings[currentChar] then
            PVPHUB_SETTINGS.honorWarnings[currentChar] = nil
        end
    end
end

ShowHonorWarning = function(charName, honorAmount)
    -- Clean up character name - extract just the name part without server and fix any truncation issues
    local cleanName = charName
    if string.find(charName, "-") then
        cleanName = string.match(charName, "([^-]+)")  -- Get everything before the first dash
    end
    
    -- Remove "ba" prefix if present (database corruption fix)
    if cleanName and string.sub(cleanName, 1, 2) == "ba" then
        cleanName = string.sub(cleanName, 3)
    end
    
    -- Get class color for character name
    local classColor = "ff999999" -- Default grey to avoid conflicts with actual class colors
    if PVPHUB_DB[charName] and PVPHUB_DB[charName].class then
        local classColorData = RAID_CLASS_COLORS[PVPHUB_DB[charName].class]
        if classColorData and classColorData.colorStr then
            classColor = classColorData.colorStr
        end
    end
    
    -- Create a popup warning dialog with classic WoW styling.
    -- Fixed name (not GetTime()-suffixed): honor can drop below the warning
    -- threshold and re-trigger this multiple times per session, and a
    -- unique key per call would grow StaticPopupDialogs (a global table)
    -- without bound for the rest of the session.
    local dialogName = "PVPHUB_HONOR_WARNING"
    StaticPopupDialogs[dialogName] = {
        text = string.format("|T1455894:16|t HONOR CAP WARNING\n\n|c%s%s|r has reached |cffFFD700%s Honor|r!",
            classColor, cleanName, FormatNumber(honorAmount)),
        button1 = "I got it bro",
        button2 = "Open PVP Hub",
        OnAccept = function()
            -- Dismiss - do nothing
        end,
        OnCancel = function()
            -- Open PVPHUB window to see all characters
            SlashCmdList["PVPHUB"]("")
        end,
        timeout = 0,
        whileDead = true,
        hideOnEscape = true,
        preferredIndex = 3,
    }
    StaticPopup_Show(dialogName)
    
    -- Also show a brief chat message (cleaned up)
    PVPHubPrint(string.format("|T1455894:14|t |cffff0000[PVPHUB]|r WARNING: %s has |cffFFD700%s Honor|r - Close to cap!",
        cleanName, FormatNumber(honorAmount)))
    
    -- Play a notification sound
    PlaySound(8959) -- "igQuestLogAbandonQuest" - attention-grabbing sound
end

-- Hook into the data update system
local function HookHonorTracking()
    -- Hook the UpdateAllData function to check for honor warnings
    if UpdateAllData then
        local originalUpdateAllData = UpdateAllData
        UpdateAllData = function()
            originalUpdateAllData()
            -- Check honor warnings after data is updated (current character only)
            C_Timer.After(0.1, CheckHonorWarnings)
        end
    end
end

-- Standalone function to update honor data without opening PVPHUB window
local function UpdateHonorDataStandalone()
    local currentChar = GetFullName()
    if not currentChar then return end
    
    -- Initialize character data if not exists
    PVPHUB_DB = PVPHUB_DB or {}
    PVPHUB_DB[currentChar] = PVPHUB_DB[currentChar] or {}
    
    -- Get honor currency (ID 1792 for honor points)
    local honorInfo = C_CurrencyInfo.GetCurrencyInfo(1792)
    if honorInfo then
        PVPHUB_DB[currentChar].honor = honorInfo.quantity or 0
    end
    
    -- Also update class info for color coding
    local _, class = UnitClass("player")
    if class then
        PVPHUB_DB[currentChar].class = class
    end
end

-- Initialize honor tracking with comprehensive event handling
local _pendingCurrencyRefresh = false
local honorTrackingFrame = CreateFrame("Frame")
honorTrackingFrame:RegisterEvent("ADDON_LOADED")
honorTrackingFrame:RegisterEvent("CURRENCY_DISPLAY_UPDATE")
honorTrackingFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
honorTrackingFrame:RegisterEvent("PLAYER_LOGIN")
-- Only register events that are valid in The War Within and relevant for honor/currency changes
honorTrackingFrame:RegisterEvent("QUEST_TURNED_IN")
honorTrackingFrame:RegisterEvent("CHAT_MSG_COMBAT_HONOR_GAIN")
honorTrackingFrame:RegisterEvent("CURRENCY_TRANSFER_SUCCESS")
honorTrackingFrame:SetScript("OnEvent", function(self, event, addonName, ...)
    -- Protect against addon conflicts and taint issues (mirrors PVPHUB.frame's
    -- main handler) so one bad event doesn't spam Lua errors.
    local success, errorMsg = pcall(function()
    if event == "ADDON_LOADED" and addonName == "PVPHUB" then
        -- Hook honor tracking after addon is loaded
        C_Timer.After(1, HookHonorTracking)
        -- Initial check (current character only)
        C_Timer.After(2, function()
            CheckHonorWarnings()
        end)
    elseif event == "CURRENCY_DISPLAY_UPDATE" then
        -- Coalesce rapid-fire currency ticks (e.g. honor gained repeatedly
        -- during a match) into a single deferred refresh instead of
        -- stacking one full-window-rebuild PVPHUB_RefreshUI() call per tick.
        if not _pendingCurrencyRefresh then
            _pendingCurrencyRefresh = true
            C_Timer.After(0.5, function()
                _pendingCurrencyRefresh = false
                UpdateHonorDataStandalone()
                CheckHonorWarnings()
                PVPHUB_RefreshUI()
            end)
        end
    elseif event == "PLAYER_ENTERING_WORLD" or event == "PLAYER_LOGIN" then
        -- Snapshot honor on login/zone change so DB is populated without opening PVPHUB.
        -- Skip the UI rebuild when entering a PvP instance: ratings haven't changed yet,
        -- and rebuilding the compact/main window causes the visible row-flash the user sees.
        local enteringPvP = IsInActivePvP()
        C_Timer.After(3, function()
            UpdateHonorDataStandalone()
            if not enteringPvP then
                CheckHonorWarnings()
                PVPHUB_RefreshUI()
            end
        end)

        -- Request PvP ratings from server so they're available without opening PvP window.
        -- Skip in PvP instance: data hasn't changed and the request is superfluous.
        if not enteringPvP then
            C_Timer.After(2, function()
                RequestRatedInfo()  -- Requests 2v2, 3v3, Solo Shuffle, and Blitz ratings
            end)
        end
    elseif event == "QUEST_TURNED_IN" then
        -- After turning in quests (PvP dailies/weeklies)
        C_Timer.After(1, function()
            UpdateHonorDataStandalone()
            CheckHonorWarnings()
            PVPHUB_RefreshUI()
        end)
    elseif event == "CHAT_MSG_COMBAT_HONOR_GAIN" then
        -- Honor gained in PvP combat - save immediately so DB stays current
        C_Timer.After(0.5, function()
            UpdateHonorDataStandalone()
            CheckHonorWarnings()
            PVPHUB_RefreshUI()
        end)
    elseif event == "CURRENCY_TRANSFER_SUCCESS" then
        -- Honor was successfully transferred between characters.
        -- Use the official API to get the completed transaction details.
        C_Timer.After(0.3, function()
            if not C_CurrencyInfo.FetchCurrencyTransferTransactions then return end
            local transactions = C_CurrencyInfo.FetchCurrencyTransferTransactions()
            if not transactions or #transactions == 0 then return end

            -- The most recent transaction is the last entry
            local tx = transactions[#transactions]
            if not tx then return end
            -- Only process Honor transfers (currency ID 1792)
            if tx.currencyType ~= 1792 then return end

            -- tx.quantityTransferred = amount the RECIPIENT receives (what was entered in dialog).
            -- The SENDER pays amount + fee. Fee is ~25% of the transfer amount.
            -- Use GetCostToTransferCurrency to get the exact total cost (amount + fee).
            local amount = tx.quantityTransferred
            if not amount or amount <= 0 then return end

            -- Get the exact total cost deducted from sender (amount + fee).
            -- Fall back to math.ceil(amount * 1.25) if the API is unavailable.
            local totalSenderCost
            if C_CurrencyInfo.GetCostToTransferCurrency then
                totalSenderCost = C_CurrencyInfo.GetCostToTransferCurrency(tx.currencyType, amount) or math.ceil(amount * 1.25)
            else
                totalSenderCost = math.ceil(amount * 1.25)
            end
            local fee = totalSenderCost - amount

            -- Find PVPHUB_DB keys by name only (realm-agnostic)
            local function FindCharKey(name)
                if not name or name == "" then return nil end
                local nameLower = name:lower()
                for key in pairs(PVPHUB_DB) do
                    local dbName = key:match("^([^%-]+)")
                    if dbName and dbName:lower() == nameLower then
                        return key
                    end
                end
                return nil
            end

            -- API provides both short name and full name (with realm); try both
            local senderKey = FindCharKey(tx.sourceCharacterName) or FindCharKey((tx.fullSourceCharacterName or ""):match("^([^%-]+)"))
            local recipientKey = FindCharKey(tx.destinationCharacterName) or FindCharKey((tx.fullDestinationCharacterName or ""):match("^([^%-]+)"))

            -- Sender loses: amount + fee (total cost)
            if senderKey and PVPHUB_DB[senderKey] then
                PVPHUB_DB[senderKey].honor = math.max(0, (PVPHUB_DB[senderKey].honor or 0) - totalSenderCost)
            end
            -- Recipient gains: amount (full requested amount, fee is paid by sender)
            if recipientKey and PVPHUB_DB[recipientKey] then
                PVPHUB_DB[recipientKey].honor = (PVPHUB_DB[recipientKey].honor or 0) + amount
            end

            -- Override with the exact API value for the currently logged-in character
            local currentKey = GetFullName()
            if currentKey then
                local honorInfo = C_CurrencyInfo.GetCurrencyInfo(1792)
                if honorInfo and PVPHUB_DB[currentKey] then
                    PVPHUB_DB[currentKey].honor = honorInfo.quantity or 0
                end
            end

            -- Confirm the transfer was registered, including fee info
            local senderName = tx.sourceCharacterName or "Unknown"
            local recipientName = tx.destinationCharacterName or "Unknown"

            local function GetClassColorStr(charKey)
                if charKey and PVPHUB_DB[charKey] and PVPHUB_DB[charKey].class then
                    local color = RAID_CLASS_COLORS[PVPHUB_DB[charKey].class]
                    if color and color.colorStr then return color.colorStr end
                end
                return "ff00ccff" -- fallback cyan
            end

            local senderColor = GetClassColorStr(senderKey)
            local recipientColor = GetClassColorStr(recipientKey)

            PVPHubPrint(string.format("|cffFFD700[Honor Transfer]|r |c%s%s|r transferred |cffFFD700%s|r Honor to |c%s%s|r. (|cffff6666%s Honor Fee|r)",
                senderColor, senderName, FormatNumber(amount), recipientColor, recipientName, FormatNumber(fee)))

            PVPHUB_RefreshUI()
            CheckHonorWarnings()
        end)
    end
    end) -- End pcall

    if not success then
        print("|cffff0000[PVPHUB Error]|r Event handler error: " .. tostring(errorMsg))
    end
end)

-- Main function called when clicking the addon compartment button
function PVPHUB_AddonCompartmentFunc(addonName, buttonName)
    if buttonName == "RightButton" then
        MenuUtil.CreateContextMenu(UIParent, function(ownerRegion, rootDescription)
            rootDescription:CreateTitle("PVPHUB")
            rootDescription:CreateButton("Open Main Window", function()
                SlashCmdList["PVPHUB"]("")
            end)
            if not PVPHUB_SETTINGS.disableStreamerMode then
                rootDescription:CreateButton("Open Streamer Window", function()
                    SlashCmdList["PVPHUB"]("compact")
                end)
            end
            rootDescription:CreateDivider()
            rootDescription:CreateButton("Open Settings", function()
                if not PVPHUB.window or not PVPHUB.window:IsShown() then
                    SlashCmdList["PVPHUB"]("")
                end
                -- Simulate clicking the Settings tab button
                C_Timer.After(0.05, function()
                    local settingsTab = PVPHUB.window
                        and PVPHUB.window.tabs
                        and PVPHUB.window.tabs["settings"]
                    if settingsTab and settingsTab.button then
                        settingsTab.button:Click()
                    end
                end)
            end)
        end)
    else
        SlashCmdList["PVPHUB"]("")
    end
end

-- Function called when hovering over the addon compartment button
function PVPHUB_AddonCompartmentFuncOnEnter(addonName, buttonName)
    -- Handle parameter mixup - sometimes addonName is the button object
    local actualButton = buttonName
    if type(addonName) == "table" and addonName.GetObjectType then
        actualButton = addonName
    end

    if not GameTooltip:IsForbidden() then
        GameTooltip:SetOwner(actualButton, "ANCHOR_LEFT")
        GameTooltip:SetText("PVPHUB", 1, 0.29, 0.29, 1)
        GameTooltip:AddLine("PvP Overview for all characters", 1, 1, 1, true)
        GameTooltip:AddLine(" ", 1, 1, 1, true)
        GameTooltip:AddLine("|cffFFD700Left-click:|r Open PVPHUB window", 0.7, 0.7, 0.7, true)
        GameTooltip:AddLine("|cffFFD700Right-click:|r Quick actions", 0.7, 0.7, 0.7, true)
        GameTooltip:Show()
    end
end

-- Function called when mouse leaves the addon compartment button
function PVPHUB_AddonCompartmentFuncOnLeave(addonName, buttonName)
    if not GameTooltip:IsForbidden() then
        GameTooltip:Hide()
    end
end

-- Register PVPHUB under Options > AddOns (Settings.RegisterAddOnCategory)
local optionsPanelRegistered = false
local function RegisterOptionsPanel()
    if optionsPanelRegistered then return end
    if not Settings or not Settings.RegisterCanvasLayoutCategory then return end
    optionsPanelRegistered = true

    local panel = CreateFrame("Frame")
    panel.name = "PVPHUB"

    local title = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 16, -16)
    title:SetText("PVPHUB")

    local desc = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    desc:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -8)
    desc:SetPoint("RIGHT", panel, "RIGHT", -16, 0)
    desc:SetJustifyH("LEFT")
    desc:SetText("PvP overview and tracking for all your characters.")

    local openButton = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    openButton:SetSize(160, 24)
    openButton:SetPoint("TOPLEFT", desc, "BOTTOMLEFT", 0, -16)
    openButton:SetText("Open PVP Hub")
    openButton:SetScript("OnClick", function()
        -- Close Options first: PVPHUB's window is Escape-closable (UISpecialFrames),
        -- and leaving Options open behind it means one Escape press closes both.
        if SettingsPanel and SettingsPanel:IsShown() then
            HideUIPanel(SettingsPanel)
        end
        SlashCmdList["PVPHUB"]("")
    end)

    local category = Settings.RegisterCanvasLayoutCategory(panel, panel.name)
    category.ID = panel.name
    Settings.RegisterAddOnCategory(category)
    PVPHUB.optionsCategory = category
end

-- Ensure addon compartment registration on load
local registrationAttempted = false
local function RegisterAddonCompartment()
    -- Prevent multiple registrations
    if registrationAttempted then return end
    registrationAttempted = true
    
    -- Make sure the functions are globally accessible
    _G["PVPHUB_AddonCompartmentFunc"] = PVPHUB_AddonCompartmentFunc
    _G["PVPHUB_AddonCompartmentFuncOnEnter"] = PVPHUB_AddonCompartmentFuncOnEnter
    _G["PVPHUB_AddonCompartmentFuncOnLeave"] = PVPHUB_AddonCompartmentFuncOnLeave
    
    -- LibDBIcon compatibility for addon collection tools.
    -- IMPORTANT: never assign a stand-in to _G.LibStub. A real LibStub that
    -- loads later (from another addon) checks `LibStub.minor < LIBSTUB_MINOR`
    -- during its own setup; our stand-in has no .minor field, so that
    -- comparison (nil < number) throws and aborts the real LibStub's init,
    -- breaking every other addon that depends on it. Keep the fallback local
    -- and only use it when the real LibStub genuinely isn't present.
    local function GetLib(major)
        if LibStub then
            return LibStub(major, true)
        end
        if major == "LibDataBroker-1.1" then
            return {
                NewDataObject = function(self, name, obj)
                    _G["LibDataBroker_" .. name] = obj
                    return obj
                end
            }
        elseif major == "LibDBIcon-1.0" then
            return {
                Register = function(self, name, obj, settings)
                    -- Minimal registration for collection addon detection
                    _G["LibDBIcon_" .. name] = {
                        button = obj.miniMapButton,
                        icon = obj.icon,
                        IsRegistered = function() return true end,
                        Show = function() end,
                        Hide = function() end
                    }
                end,
                IsRegistered = function(self, name) return _G["LibDBIcon_" .. name] ~= nil end
            }
        end
        return nil
    end

    -- Create LibDataBroker data object
    local LDB = GetLib("LibDataBroker-1.1")
    if LDB then
        local dataObj = LDB:NewDataObject("PVPHUB", {
            type = "launcher",
            text = "PVPHUB",
            icon = "Interface\\AddOns\\PVPHUB\\media\\PVPHUB.png",
            OnClick = function(clickedframe, button)
                SlashCmdList["PVPHUB"]("")
            end,
            OnTooltipShow = function(tooltip)
                tooltip:AddLine("PVPHUB", 1, 0.29, 0.29)
                tooltip:AddLine("PvP Overview for all characters", 1, 1, 1)
                tooltip:AddLine(" ")
                tooltip:AddLine("|cffFFD700Click:|r Open PVPHUB window", 0.7, 0.7, 0.7)
            end
        })
        
        -- Ensure minimap settings exist (backward compatibility)
        PVPHUB_SETTINGS.minimap = PVPHUB_SETTINGS.minimap or {
            hide = false,
            minimapPos = 220,  -- Default position angle around minimap
            radius = 80        -- Default distance from minimap center
        }
        
        -- Store data object for later use
        PVPHUB.dataObj = dataObj
        
        -- Register with LibDBIcon using saved minimap settings with retry logic
        local function TryRegisterIcon()
            local LDBIcon = GetLib("LibDBIcon-1.0")
            if LDBIcon then
                -- Unregister first if already registered to prevent conflicts
                if LDBIcon:IsRegistered("PVPHUB") then
                    pcall(LDBIcon.Hide, LDBIcon, "PVPHUB")
                end
                
                -- Register the icon
                LDBIcon:Register("PVPHUB", dataObj, PVPHUB_SETTINGS.minimap)
                
                -- Ensure icon is shown if not hidden in settings
                if not PVPHUB_SETTINGS.minimap.hide then
                    C_Timer.After(0.1, function()
                        if LDBIcon:IsRegistered("PVPHUB") then
                            pcall(LDBIcon.Show, LDBIcon, "PVPHUB")
                        end
                    end)
                end
                
                -- Store reference for later visibility checks
                PVPHUB.LDBIcon = LDBIcon
                return true
            end
            return false
        end
        
        -- Try to register immediately
        if not TryRegisterIcon() then
            -- If failed, retry after a short delay (LibDBIcon might load later)
            C_Timer.After(1, function()
                if not TryRegisterIcon() then
                    -- Final retry after 3 seconds
                    C_Timer.After(2, TryRegisterIcon)
                end
            end)
        end
    end
    
    -- The TOC file should be sufficient for addon compartment registration
    -- We don't need to manually register if it's already working through TOC
    
    -- Only do fallback registration if compartment doesn't detect us
    if C_AddOns and C_AddOns.GetAddOnMetadata then
        local addonName = "PVPHUB"
        if not C_AddOns.GetAddOnMetadata(addonName, "AddonCompartmentFunc") then
            -- Fallback metadata for collection addons that don't read TOC properly
            _G["__ADDONCOMPARTMENT_" .. addonName] = {
                func = "PVPHUB_AddonCompartmentFunc",
                funcOnEnter = "PVPHUB_AddonCompartmentFuncOnEnter",
                funcOnLeave = "PVPHUB_AddonCompartmentFuncOnLeave",
                icon = "Interface\\AddOns\\PVPHUB\\PVPHUB.png",
                title = "PVPHUB"
            }
        end
    end
end

-- Register after addon loaded (simplified to prevent multiple registrations)
local compartmentFrame = CreateFrame("Frame")
compartmentFrame:RegisterEvent("ADDON_LOADED")
compartmentFrame:SetScript("OnEvent", function(self, event, addonName)
    -- Protect against addon conflicts and taint issues (mirrors PVPHUB.frame's
    -- main handler) so one bad event doesn't spam Lua errors.
    local success, errorMsg = pcall(function()
    if event == "ADDON_LOADED" and addonName == "PVPHUB" then
        RegisterAddonCompartment()
        RegisterOptionsPanel()

        -- Start periodic minimap icon check after initial registration
        C_Timer.After(5, function()
            local function CheckMinimapIcon()
                if PVPHUB.LDBIcon and PVPHUB.dataObj and not PVPHUB_SETTINGS.minimap.hide then
                    if PVPHUB.LDBIcon:IsRegistered("PVPHUB") then
                        -- Icon is registered, make sure it's visible
                        pcall(PVPHUB.LDBIcon.Show, PVPHUB.LDBIcon, "PVPHUB")
                    else
                        -- Icon got unregistered somehow, re-register it
                        pcall(PVPHUB.LDBIcon.Register, PVPHUB.LDBIcon, "PVPHUB", PVPHUB.dataObj, PVPHUB_SETTINGS.minimap)
                        pcall(PVPHUB.LDBIcon.Show, PVPHUB.LDBIcon, "PVPHUB")
                    end
                end
            end
            
            -- Check every 30 seconds
            local checkTimer
            checkTimer = C_Timer.NewTicker(30, CheckMinimapIcon)
            
            -- Store timer reference for cleanup if needed
            PVPHUB.minimapCheckTimer = checkTimer
        end)
        
        -- Unregister to prevent multiple calls
        self:UnregisterEvent("ADDON_LOADED")
        self:SetScript("OnEvent", nil)
    end
    end) -- End pcall

    if not success then
        print("|cffff0000[PVPHUB Error]|r Event handler error: " .. tostring(errorMsg))
    end
end)

-- Handlers for the branded "Start Fresh" popup (modules/popups.lua,
-- PVPHUB:ShowSeasonFreshStartPopup) — kept here rather than in the popup
-- module because they need UpdateCurrencyData/CURRENCY_IDS/PVPHubPrint,
-- which only exist as locals in this file's chunk. The popup module is
-- UI-only and just calls these.
--
-- Only clears season-scoped PvP tracking (ratings, W/L, match history,
-- conquest/token season progress) for every stored character; honor, gold,
-- notes, hidden characters, and settings are all left untouched.
function PVPHUB:ExecuteSeasonFreshStart()
    for charKey, data in pairs(PVPHUB_DB) do
        if type(data) == "table" and charKey ~= "settings" then
            ClearCharacterSeasonData(data)
        end
    end

    -- Re-anchor the season-boundary bookkeeping to right now, so
    -- UpdateCurrencyData's automatic detection doesn't immediately think
    -- another season just started, and every character but this one
    -- correctly shows as "last season" (see IsCharacterStaleThisSeason)
    -- until it logs in and reports fresh data.
    local nowSeason = (C_PvP and C_PvP.GetUIDisplaySeason and C_PvP.GetUIDisplaySeason()) or 0
    if nowSeason > 0 then
        PVPHUB_SETTINGS.lastKnownSeasonID = nowSeason
        -- Explicit decision made — stop re-prompting for this season.
        PVPHUB_SETTINGS.seasonFreshStartResolvedForSeason = nowSeason
    end
    local capOk, capInfo = pcall(C_CurrencyInfo.GetCurrencyInfo, CURRENCY_IDS.conquest)
    if capOk and capInfo and capInfo.maxQuantity and capInfo.maxQuantity > 0 then
        PVPHUB_SETTINGS.lastKnownConquestCap = capInfo.maxQuantity
    end
    PVPHUB_SETTINGS.seasonStartTimestamp = GetServerTime()

    -- Immediately repopulate the current character rather than leaving
    -- it on a blank state until the next natural update event fires.
    UpdateCurrencyData()
    if PVPHUB.PvPTracking and PVPHUB.PvPTracking.SaveBracketStats then
        PVPHUB.PvPTracking.SaveBracketStats(GetFullName())
    end

    if PVPHUB.window and PVPHUB.window.UpdateContent then
        PVPHUB.window:UpdateContent()
    end
    if PVPHUB.window and PVPHUB.window:IsShown() and PVPHUB.window.currentTab == "stats"
       and PVPHUB.window.statsFrame and PVPHUB.window.RenderStatsFor then
        PVPHUB.window.RenderStatsFor()
    end
    if PVPHUB.compactWindow and PVPHUB.compactWindow.UpdateContent then
        PVPHUB.compactWindow:UpdateContent()
    end

    PVPHubPrint("|cff33ff66[PVPHUB]|r Fresh start! Season tracking cleared for all characters — honor, gold, and notes were kept.")
    PlaySound(8959)
end

-- Final safety gate before ExecuteSeasonFreshStart actually runs — clicking
-- "Yes, Start Fresh" on the branded popup (modules/popups.lua) opens this
-- plain native confirm instead of wiping immediately, since that button
-- sits right next to the decline button and a misclick there would
-- otherwise be irreversible with a single click. Canceling here leaves the
-- season unresolved, same as closing the branded popup via its X — reopen
-- the "Start Fresh" button beside Streamer Mode whenever you're ready.
StaticPopupDialogs["PVPHUB_CONFIRM_SEASON_FRESH_START"] = {
    text = "|cffff4444Are you sure?|r\n\nThis will permanently clear last season's ratings, win/loss records, and match history for every tracked character.\n\n|cff888888This can't be undone.|r",
    button1 = "Yes, I'm Sure",
    button2 = "Cancel",
    OnAccept = function()
        PVPHUB:ExecuteSeasonFreshStart()
    end,
    OnCancel = function()
        -- Do nothing — leaves seasonFreshStartResolvedForSeason untouched.
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
}

-- Explicit decision to handle it manually — marks the season resolved so
-- the reminder banner/dimming still treats it normally. Only reached via an
-- actual button click (see ShowSeasonFreshStartPopup's X close, which calls
-- neither handler).
function PVPHUB:DeclineSeasonFreshStart()
    local nowSeason = (C_PvP and C_PvP.GetUIDisplaySeason and C_PvP.GetUIDisplaySeason()) or 0
    if nowSeason > 0 then
        PVPHUB_SETTINGS.seasonFreshStartResolvedForSeason = nowSeason
    end
    PVPHubPrint("|cffaaaaaa[PVPHUB]|r No problem — log into each character when you get a chance and PVPHUB will pick up fresh season data automatically.")
end

-- StaticPopup for confirming reset all data
StaticPopupDialogs["PVPHUB_RESET_ALL_DATA"] = {
    text = "RESET ALL CHARACTER DATA\n\nThis will permanently delete ALL character PvP data including ratings, honor, conquest, and currencies.\n\n|cffFF0000This action cannot be undone!|r\n\nAre you sure you want to continue?",
    button1 = "Yes, Reset Everything",
    button2 = "Cancel",
    OnAccept = function()
        -- Clear all character data
        PVPHUB_DB = {}
        PVPHUB_IGNORED = {}
        
        -- Reset settings to defaults but keep window preferences
        local windowSize = PVPHUB_SETTINGS.windowSize
        local windowPos = PVPHUB_SETTINGS.windowPos
        local windowScale = PVPHUB_SETTINGS.windowScale
        local windowOpacity = PVPHUB_SETTINGS.windowOpacity
        local colorTheme = PVPHUB_SETTINGS.colorTheme
        local visibleColumns = PVPHUB_SETTINGS.visibleColumns
        local minimap = PVPHUB_SETTINGS.minimap
        local mainWindow = PVPHUB_SETTINGS.mainWindow
        local disableHonorWarnings = PVPHUB_SETTINGS.disableHonorWarnings
        
        PVPHUB_SETTINGS = {
            sortKey = "highestRating",
            compactSortKey = "highestRating",
            colorTheme = colorTheme or "RED",
            visibleColumns = visibleColumns or {
                character = true, honor = true, conquest = true, bloodstones = true,
                bloodytokens = true, rating2v2 = true, rating3v3 = true,
                ratingShuffle = true, ratingBlitz = true, ratingRBG = true, delete = true
            },
            windowSize = windowSize,
            windowPos = windowPos,
            windowScale = windowScale or 1.0,
            windowOpacity = windowOpacity or 0.95,
            minimap = minimap or {
                hide = false,
                minimapPos = 220,
                radius = 80
            },
            currentTab = "data",
            mainWindow = mainWindow or {},
            disableHonorWarnings = disableHonorWarnings or false
        }
        
        -- Refresh the UI if main window is open
        if PVPHUB.window and PVPHUB.window.UpdateContent then
            PVPHUB.window:UpdateContent()
        end
        
        -- Refresh compact window if it's open
        if PVPHUB.compactWindow and PVPHUB.compactWindow.UpdateContent then
            PVPHUB.compactWindow:UpdateContent()
        end
        
        -- Show confirmation message
        PVPHubPrint("|cffff0000[PVPHUB]|r All character data has been reset!")
        PlaySound(8959) -- Attention sound
    end,
    OnCancel = function()
        -- Do nothing - user cancelled
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
}

-- StaticPopup for reload UI prompt
StaticPopupDialogs["PVPHUB_RELOAD_UI"] = {
    text = "Match history setting changed.\n\nReload UI to apply changes?",
    button1 = "Reload UI",
    button2 = "Later",
    OnAccept = function()
        ReloadUI()
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
}

-- StaticPopup for editing character notes
StaticPopupDialogs["PVPHUB_EDIT_NOTE"] = {
    text = "Character Note:",
    button1 = "Save",
    button2 = "Cancel",
    button3 = "Clear Note",
    hasEditBox = true,
    maxLetters = 50,
    OnShow = function(self)
        local charKey = self.charKey
        local note = PVPHUB_DB[charKey] and PVPHUB_DB[charKey].note or ""
        self.EditBox:SetText(note)
        self.EditBox:SetFocus()
        self.EditBox:HighlightText()
        
        -- Add character name to dialog
        local data = PVPHUB_DB[charKey]
        if data then
            local class = data.class or "PRIEST"
            local color = RAID_CLASS_COLORS[class] or NORMAL_FONT_COLOR
            local displayName = charKey:match("^([^%-]+)")
            self.text:SetFormattedText("Set note for |c%s%s|r:", color.colorStr or "ffffffff", displayName)
        end
    end,
    OnAccept = function(self)
        local charKey = self.charKey
        local note = self.EditBox:GetText()
        
        if not PVPHUB_DB[charKey] then
            PVPHUB_DB[charKey] = {}
        end
        
        PVPHUB_DB[charKey].note = note ~= "" and note or nil
        
        -- Refresh UI
        if PVPHUB.window and PVPHUB.window.UpdateContent then
            PVPHUB.window:UpdateContent()
        end
        
        if note ~= "" then
            PVPHubPrint("|cffff0000[PVPHUB]|r Note saved: " .. note)
        else
            PVPHubPrint("|cffff0000[PVPHUB]|r Note cleared")
        end
    end,
    OnAlt = function(self)
        -- Clear Note button
        local charKey = self.charKey
        if PVPHUB_DB[charKey] then
            PVPHUB_DB[charKey].note = nil
        end
        
        -- Refresh UI
        if PVPHUB.window and PVPHUB.window.UpdateContent then
            PVPHUB.window:UpdateContent()
        end
        
        PVPHubPrint("|cffff0000[PVPHUB]|r Note cleared")
    end,
    EditBoxOnEnterPressed = function(self)
        local parent = self:GetParent()
        StaticPopup_OnClick(parent, 1)
    end,
    EditBoxOnEscapePressed = function(self)
        self:GetParent():Hide()
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
}

-- StaticPopup: add/create a new character group
StaticPopupDialogs["PVPHUB_ADD_GROUP"] = {
    text = "Enter group name:",
    button1 = "Create",
    button2 = "Cancel",
    hasEditBox = true,
    enterClicksFirstButton = true,
    OnShow = function(self)
        local eb = self.editBox or self.EditBox
        if not eb then return end
        eb:SetText("")
        eb:SetFocus()
        eb:SetScript("OnEnterPressed", function() StaticPopup_OnClick(self, 1) end)
    end,
    OnAccept = function(self)
        local eb = self.editBox or self.EditBox
        local groupName = eb and eb:GetText():match("^%s*(.-)%s*$") or ""
        if groupName == "" then return end
        if not PVPHUB_SETTINGS.characterGroups then
            PVPHUB_SETTINGS.characterGroups = {
                groups = {{name = "No Group", characters = {}, collapsed = false, isDefault = true}},
                enabled = false
            }
        end
        local groups = PVPHUB_SETTINGS.characterGroups.groups
        for _, g in ipairs(groups) do
            if g.name == groupName then return end
        end
        if not PVPHUB_SETTINGS.characterGroups.enabled then
            PVPHUB_SETTINGS.characterGroups.enabled = true
        end
        table.insert(groups, {name = groupName, characters = {}, collapsed = false})
        if PVPHUB.window and PVPHUB.window.UpdateContent then PVPHUB.window:UpdateContent() end
        if PVPHUB.groupMgmtWindow and PVPHUB.groupMgmtWindow:IsShown() then PVPHUB.groupMgmtWindow:UpdateContent() end
        PVPHubPrint("|cff00ff00[PVPHUB]|r Group '" .. groupName .. "' created!")
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
}
StaticPopupDialogs["PVPHUB_CREATE_GROUP"] = StaticPopupDialogs["PVPHUB_ADD_GROUP"]

-- StaticPopup: rename a group — caller sets PVPHUB._renameGroupCtx = { groupIndex, groupName }
StaticPopupDialogs["PVPHUB_RENAME_GROUP"] = {
    text = "Rename group:",
    button1 = "Rename",
    button2 = "Cancel",
    hasEditBox = true,
    enterClicksFirstButton = true,
    OnShow = function(self)
        local ctx = PVPHUB._renameGroupCtx
        local eb = self.editBox or self.EditBox
        if not eb then return end
        eb:SetText(ctx and ctx.groupName or "")
        eb:SetFocus()
        eb:HighlightText()
        eb:SetScript("OnEnterPressed", function() StaticPopup_OnClick(self, 1) end)
    end,
    OnAccept = function(self)
        local ctx = PVPHUB._renameGroupCtx
        if not ctx then return end
        local eb = self.editBox or self.EditBox
        local newName = eb and eb:GetText():match("^%s*(.-)%s*$") or ""
        if newName == "" then return end
        local groups = PVPHUB_SETTINGS.characterGroups and PVPHUB_SETTINGS.characterGroups.groups
        if groups then
            for _, g in ipairs(groups) do
                if g.name ~= ctx.groupName and g.name == newName then return end
            end
            if groups[ctx.groupIndex] then groups[ctx.groupIndex].name = newName end
        end
        if PVPHUB.window and PVPHUB.window.UpdateContent then PVPHUB.window:UpdateContent() end
        if PVPHUB.groupMgmtWindow and PVPHUB.groupMgmtWindow:IsShown() then PVPHUB.groupMgmtWindow:UpdateContent() end
        PVPHUB._renameGroupCtx = nil
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
}

-- StaticPopup: delete a group — caller sets PVPHUB._deleteGroupCtx = { groupIndex } and updates .text
StaticPopupDialogs["PVPHUB_DELETE_GROUP"] = {
    text = "Delete this group?\n\nCharacters will be moved to No Group.",
    button1 = "Delete",
    button2 = "Cancel",
    OnAccept = function()
        local ctx = PVPHUB._deleteGroupCtx
        if not ctx then return end
        local groups = PVPHUB_SETTINGS.characterGroups and PVPHUB_SETTINGS.characterGroups.groups
        if not groups or not groups[ctx.groupIndex] then return end
        for _, char in ipairs(groups[ctx.groupIndex].characters) do
            table.insert(groups[1].characters, char)
        end
        table.remove(groups, ctx.groupIndex)
        if PVPHUB.window and PVPHUB.window.UpdateContent then PVPHUB.window:UpdateContent() end
        if PVPHUB.groupMgmtWindow and PVPHUB.groupMgmtWindow:IsShown() then PVPHUB.groupMgmtWindow:UpdateContent() end
        PVPHUB._deleteGroupCtx = nil
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
}

-- StaticPopup: delete a character — caller sets PVPHUB._deleteCharCtx = charName and updates .text
StaticPopupDialogs["PVPHUB_DELETE_CHARACTER"] = {
    text = "Delete this character? This action cannot be undone!",
    button1 = "Delete",
    button2 = "Cancel",
    OnAccept = function()
        local charToDelete = PVPHUB._deleteCharCtx
        if not charToDelete then return end
        if PVPHUB_DB[charToDelete] then
            PVPHUB_DB[charToDelete] = nil
            collectgarbage("collect")
        end
        if PVPHUB_SETTINGS.hiddenChars and PVPHUB_SETTINGS.hiddenChars[charToDelete] then
            PVPHUB_SETTINGS.hiddenChars[charToDelete] = nil
        end
        if PVPHUB_SETTINGS.compactMode and PVPHUB_SETTINGS.compactMode.selectedChars then
            PVPHUB_SETTINGS.compactMode.selectedChars[charToDelete] = nil
        end
        if PVPHUB_SETTINGS.mainWindow and PVPHUB_SETTINGS.mainWindow.pinnedCharacter == charToDelete then
            PVPHUB_SETTINGS.mainWindow.pinnedCharacter = nil
        end
        if PVPHUB.window and PVPHUB.window.UpdateContent then PVPHUB.window:UpdateContent() end
        if PVPHUB.mainWindow and PVPHUB.mainWindow.UpdateContent then PVPHUB.mainWindow:UpdateContent() end
        if PVPHUB.compactWindow and PVPHUB.UpdateCompactWindow then PVPHUB:UpdateCompactWindow() end
        if PVPHUB.hiddenCharsWindow and PVPHUB.hiddenCharsWindow:IsVisible() and PVPHUB.hiddenCharsWindow.UpdateContent then
            PVPHUB.hiddenCharsWindow:UpdateContent()
        end
        PVPHubPrint("|cff00ff00[PVPHUB]|r Character |cff4da6ff" .. charToDelete .. "|r has been permanently deleted.")
        PVPHUB._deleteCharCtx = nil
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
}

-- Slash Commands for Hidden Characters Management
SLASH_PVPHUBHIDE1 = "/pvphide"
SLASH_PVPHUBHIDE2 = "/pvphubhide"
SlashCmdList["PVPHUBHIDE"] = function(msg)
    local args = {strsplit(" ", msg)}
    local command = args[1] and args[1]:lower() or ""
    
    if command == "" or command == "show" or command == "manage" then
        -- Default action: show the management window
        ShowHiddenCharactersWindow()
    elseif command == "list" then
        local hiddenChars = GetHiddenCharactersList()
        if #hiddenChars == 0 then
            PVPHubPrint("|cff00ff00[PVPHUB]|r No characters are currently hidden.")
        else
            PVPHubPrint("|cff00ff00[PVPHUB]|r Hidden characters:")
            for _, charKey in ipairs(hiddenChars) do
                PVPHubPrint("  - " .. charKey)
            end
        end
    elseif command == "unhide" then
        local charKey = args[2]
        if charKey then
            if UnhideCharacter(charKey) then
                -- Success message is already printed in UnhideCharacter function
            else
                PVPHubPrint("|cffff0000[PVPHUB]|r Character '" .. charKey .. "' was not hidden.")
            end
        else
            PVPHubPrint("|cffff0000[PVPHUB]|r Usage: /pvphide unhide <character-server>")
            PVPHubPrint("|cffff0000[PVPHUB]|r Example: /pvphide unhide Typeshi-BurningLegion")
        end
    elseif command == "clear" then
        PVPHUB_SETTINGS.hiddenCharacters = {}
        hiddenCharSet = {}
        PVPHubPrint("|cff00ff00[PVPHUB]|r All characters are now visible again.")
        
        -- Force immediate UI refresh
        if PVPHUB.window and PVPHUB.window.UpdateContent then
            PVPHUB.window:UpdateContent()
        end
        if PVPHUB.compactWindow and PVPHUB.UpdateCompactWindow then
            PVPHUB:UpdateCompactWindow()
        end
        
        -- Update hidden characters window if it's open
        if PVPHUB.hiddenCharsWindow and PVPHUB.hiddenCharsWindow:IsVisible() and PVPHUB.hiddenCharsWindow.UpdateContent then
            PVPHUB.hiddenCharsWindow.UpdateContent()
        end
    else
        PVPHubPrint("|cff00ff00[PVPHUB]|r Hidden Characters Management:")
        PVPHubPrint("  |cffffffff/pvphide|r - Open hidden characters management window")
        PVPHubPrint("  |cffffffff/pvphide list|r - Show all hidden characters in chat")
        PVPHubPrint("  |cffffffff/pvphide unhide <character-server>|r - Unhide a specific character")
        PVPHubPrint("  |cffffffff/pvphide clear|r - Unhide all characters")
        PVPHubPrint("  |cffffffff|r")
        PVPHubPrint("  |cffccccccTo hide a character: Right-click on the character name in PVPHUB|r")
    end
end
