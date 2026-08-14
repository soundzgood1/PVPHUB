local _, PVPHUB = ...

-- Local aliases for helpers defined in PVPHUB_core.lua.
-- core.lua loads before this file and exposes them via PVPHUB._xxx.
local UI_CONSTANTS                  = PVPHUB._UI_CONSTANTS
local PVPHUB_CONSTANTS              = PVPHUB._PVPHUB_CONSTANTS
local IsInActivePvP                 = PVPHUB._IsInActivePvP
local GetCurrentTheme               = PVPHUB._GetCurrentTheme
local IsCharacterHidden             = PVPHUB._IsCharacterHidden
local GetRatingColor                = PVPHUB._GetRatingColor
local GetShuffleDisplayInfo         = PVPHUB._GetShuffleDisplayInfo
local ApplyModernScrollbarStyling   = PVPHUB._ApplyModernScrollbarStyling
local ApplyModernDropdownStyling    = PVPHUB._ApplyModernDropdownStyling
local FormatNumber                  = PVPHUB._FormatNumber
local PVP_BRACKETS                  = PVPHUB._PVP_BRACKETS

local function compactHasAnyRating(data)
    if not data then return false end
    if (data.rating2v2 or 0) > 0 or (data.rating3v3 or 0) > 0 or (data.ratingRBG or 0) > 0 then return true end
    local function tableMax(t)
        if type(t) == "number" then return t end
        if type(t) ~= "table" then return 0 end
        local m = 0; for _, v in pairs(t) do if v > m then m = v end end; return m
    end
    return tableMax(data.ratingShuffle) > 0 or tableMax(data.ratingBlitz) > 0
end

-- Returns how many distinct specs a character has ever earned a rating>0 in,
-- across Shuffle and Blitz. This decides whether the character is shown as a
-- single combined row that just follows the currently-active spec (zero rated
-- specs — nothing to pin yet) or as individually tickable per-spec rows (one
-- or more rated specs) — see PromoteToMultiSpecIfNeeded below.
local function GetDistinctRatedSpecCount(data)
    if not data then return 0 end
    local seen = {}
    local count = 0
    for _, bracketKey in ipairs({"ratingShuffle", "ratingBlitz"}) do
        local bracketData = data[bracketKey]
        if type(bracketData) == "table" then
            for specID, rating in pairs(bracketData) do
                if rating and rating > 0 and not seen[specID] then
                    seen[specID] = true
                    count = count + 1
                end
            end
        end
    end
    return count
end

-- Returns true if a character has ever earned a rating>0 for the given spec,
-- in either Shuffle or Blitz — i.e. whether that spec is legitimately
-- "known" and safe to pin, as opposed to a phantom 0 left behind by a respec
-- pre-initializing a bracket slot the character never actually queued.
local function CharacterHasRatingForSpec(data, specID)
    if not specID then return false end
    for _, bracketKey in ipairs({"ratingShuffle", "ratingBlitz"}) do
        local bracketData = data[bracketKey]
        local rating = type(bracketData) == "table" and bracketData[specID]
        if type(rating) == "number" and rating > 0 then
            return true
        end
    end
    return false
end

-- Returns the specID with the single highest rating>0 across Shuffle and
-- Blitz, or nil if the character has no rated spec at all. Used to seed a
-- pin for whichever spec actually has something to show, since the
-- currently-active spec (e.g. right after a respec) may have none.
local function GetBestRatedSpec(data)
    local bestSpecID, bestRating = nil, 0
    for _, bracketKey in ipairs({"ratingShuffle", "ratingBlitz"}) do
        local bracketData = data[bracketKey]
        if type(bracketData) == "table" then
            for specID, rating in pairs(bracketData) do
                if rating and rating > bestRating then
                    bestRating = rating
                    bestSpecID = specID
                end
            end
        end
    end
    return bestSpecID
end

-- pinnedSpecs used to be nested per-bracket (pinnedSpecs[charKey][bracketKey]
-- [specID]) so a pinned row showed exactly one bracket's rating, blanking the
-- rest. It's now flat (pinnedSpecs[charKey][specID]): ticking a spec shows
-- that spec's rating across every enabled bracket at once, same as the old
-- combined row just scoped to one spec instead of "whichever is active".
-- This converts any leftover nested-shape data to the flat shape, once.
local function MigratePinnedSpecsSchema()
    local cm = PVPHUB_SETTINGS.compactMode
    if cm.pinnedSpecsSchemaV2 then return end
    cm.pinnedSpecsSchemaV2 = true

    local pins = cm.pinnedSpecs
    if not pins then return end
    for charKey, entry in pairs(pins) do
        local flat = {}
        local wasNested = false
        for key, value in pairs(entry) do
            if (key == "ratingShuffle" or key == "ratingBlitz") and type(value) == "table" then
                wasNested = true
                for specID in pairs(value) do
                    flat[specID] = true
                end
            end
        end
        if wasNested then
            pins[charKey] = flat
        end
    end
end

-- A character that has earned a rating in any spec "graduates" from the single
-- combined row (governed by the plain selectedChars checkbox, which always
-- tracks whatever spec is currently active — showing 0 the moment you respec
-- into a spec with no history) to individually tickable per-spec rows
-- (governed by pinnedSpecs), which keep showing a spec's rating no matter what
-- you're currently playing. This runs at most once per character: if it was
-- being shown via the old checkbox, a pin is seeded so it doesn't just
-- disappear the moment it graduates — after that, ticks are entirely up to
-- the user, including unticking down to zero rows. Also doubles as the
-- one-time migration for characters that were already multi-spec under the
-- old (>=2 rated specs) model.
local function PromoteToMultiSpecIfNeeded(charKey, data)
    if GetDistinctRatedSpecCount(data) < 1 then return end

    local cm = PVPHUB_SETTINGS.compactMode
    cm.promotedMultiSpec = cm.promotedMultiSpec or {}
    if cm.promotedMultiSpec[charKey] then return end
    cm.promotedMultiSpec[charKey] = true

    local sel = cm.selectedChars
    local wasSelected = false
    for i = #sel, 1, -1 do
        if sel[i] == charKey then
            table.remove(sel, i)
            wasSelected = true
        end
    end

    if wasSelected then
        -- Prefer the currently-active spec if it's actually rated; otherwise
        -- fall back to whichever spec has the best rating, so a character
        -- caught mid-respec (active spec rated 0, like Elemental right after
        -- swapping off a rated Restoration) doesn't just vanish from the
        -- display until the user manually re-pins it.
        local currentSpecID = data.specID or data.lastActiveSpecID
        local specToSeed = CharacterHasRatingForSpec(data, currentSpecID) and currentSpecID or GetBestRatedSpec(data)
        if specToSeed then
            cm.pinnedSpecs = cm.pinnedSpecs or {}
            cm.pinnedSpecs[charKey] = cm.pinnedSpecs[charKey] or {}
            cm.pinnedSpecs[charKey][specToSeed] = true
        end
    end
end

-- Display order for compact window columns — matches the main window (2v2, 3v3, Shuffle, Blitz, RBG)
local COMPACT_BRACKET_ORDER = {
    { key = "rating2v2",     name = "2v2",     icon = "|TInterface\\Icons\\achievement_arena_2v2_1:16|t" },
    { key = "rating3v3",     name = "3v3",     icon = "|TInterface\\Icons\\achievement_arena_3v3_1:16|t" },
    { key = "ratingShuffle", name = "Shuffle", icon = "|TInterface\\Icons\\ability_dualwield:16|t" },
    { key = "ratingBlitz",   name = "Blitz",   icon = "|TInterface\\Icons\\achievement_bg_killxenemies_generalsroom:16|t" },
    { key = "ratingRBG",     name = "RBG",     icon = "|TInterface\\Icons\\achievement_pvp_a_15:16|t" },
}
local GetFullName                   = PVPHUB._GetFullName
local PVPHubPrint                   = PVPHUB._PVPHubPrint
local CreateCharacterName           = PVPHUB._CreateCharacterName
local ShowCharacterTooltip          = PVPHUB._ShowCharacterTooltip
local HideCharacterTooltip          = PVPHUB._HideCharacterTooltip
local ShowPVPHUBRatingTooltip       = PVPHUB._ShowPVPHUBRatingTooltip
local ClosePVPHUBRatingTooltip      = PVPHUB._ClosePVPHUBRatingTooltip
local GetCachedSpecInfo             = PVPHUB._GetCachedSpecInfo

local FALLBACK_FONT = "Fonts\\FRIZQT__.TTF"

-- Safe SetFont: suppresses C-level errors via pcall.
-- Sets IsFontmancerPreview = true so Fontmancer's global metatable hook skips
-- this instance and never overwrites our chosen font.
-- Does NOT check SetFont's boolean return — WoW can return false for some valid
-- paths while still rendering correctly; checking it causes blank text.
local function SafeSetFont(fontString, path, size, flags)
    if not fontString or not fontString.SetFont then return end
    fontString.IsFontmancerPreview = true   -- exempt from Fontmancer's hook
    pcall(function() fontString:SetFont(path, size, flags) end)
end

function PVPHUB:CreateCompactWindow()
    PVPHUB:EnsureCompactModeDefaults()
    
    -- Initialize compact font path (UpdateCompactWindow will re-derive this on every
    -- rebuild, so this block just ensures the global is set before the first update).
    do
        local sel = PVPHUB_SETTINGS.compactMode.selectedFont or "Friz Quadrata TT"
        local builtInFonts = {
            ["Friz Quadrata TT"] = "Fonts\\FRIZQT__.TTF",
            ["Arial Narrow"]     = "Fonts\\ARIALN.TTF",
            ["Morpheus"]         = "Fonts\\MORPHEUS.TTF",
            ["Skurri"]           = "Fonts\\skurri.ttf",
        }
        PVPHUB.compactCurrentFontPath = builtInFonts[sel] or "Fonts\\FRIZQT__.TTF"
        if LibStub then
            local LSM = LibStub("LibSharedMedia-3.0", true)
            if LSM and LSM.HashTable then
                local fontTable = LSM:HashTable("font")
                if fontTable and fontTable[sel] then
                    PVPHUB.compactCurrentFontPath = fontTable[sel]
                end
            end
        end
    end
    
    -- Prevent showing in active PvP if option is enabled
    if PVPHUB_SETTINGS and PVPHUB_SETTINGS.compactMode and PVPHUB_SETTINGS.compactMode.hideInPvP then
        if IsInActivePvP() then
            -- We're in active PvP and hiding is enabled - don't show window
            if PVPHUB.compactWindow then
                PVPHUB.compactWindow:Hide()
            end
            PVPHUB._compactWindowWasOpenBeforePvP = true -- Track that user wanted it open
            return
        end
    end
    PVPHUB_SETTINGS.compactWindowStayOpen = true
    if not PVPHUB.compactWindow then
        PVPHUB.compactWindow = CreateFrame("Frame", "PVPHUBCompactFrame", UIParent, "BackdropTemplate")
        PVPHUB.compactWindow:SetFrameStrata("MEDIUM")
        
        -- Calculate initial width (will be updated dynamically)
        -- Add sorting dropdown to compact window
        local sortKeys = {"highestRating", "rating2v2", "rating3v3", "ratingShuffle", "ratingBlitz", "ratingRBG"}
        local sortDisplayNames = {
            highestRating = "Highest",
            rating2v2 = "2v2",
            rating3v3 = "3v3",
            ratingShuffle = "Shuffle",
            ratingBlitz = "Blitz",
            ratingRBG = "RBG"
        }
        PVPHUB_SETTINGS.compactSortKey = PVPHUB_SETTINGS.compactSortKey or "highestRating"
        
        -- Toolbar sits BELOW the content window; dragging the parent moves both.
        -- Controls fade in on hover and fade out after 3 s of inactivity.
        local toolbarHeight = 20
        local toolbar = CreateFrame("Frame", nil, PVPHUB.compactWindow, "BackdropTemplate")
        toolbar:SetPoint("TOPLEFT",  PVPHUB.compactWindow, "BOTTOMLEFT",  0, -1)
        toolbar:SetPoint("TOPRIGHT", PVPHUB.compactWindow, "BOTTOMRIGHT", 0, -1)
        toolbar:SetHeight(toolbarHeight)
        toolbar:SetFrameLevel(PVPHUB.compactWindow:GetFrameLevel() + 1)
        toolbar:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8x8", tile = false })
        toolbar:SetBackdropColor(0, 0, 0, 0.72)

        PVPHUB.compactWindow.toolbar = toolbar

        -- Sort dropdown — left side of toolbar.
        -- Opens upward so the popup doesn't overlap the content window.
        local sortIconMap = {
            highestRating = "|TInterface\\Icons\\achievement_pvp_a_01:12|t",
            rating2v2     = "|TInterface\\Icons\\achievement_arena_2v2_1:12|t",
            rating3v3     = "|TInterface\\Icons\\achievement_arena_3v3_1:12|t",
            ratingShuffle = "|TInterface\\Icons\\ability_dualwield:12|t",
            ratingBlitz   = "|TInterface\\Icons\\achievement_bg_killxenemies_generalsroom:12|t",
            ratingRBG     = "|TInterface\\Icons\\achievement_pvp_a_15:12|t",
        }
        local function GetSortLabel(key)
            return (sortIconMap[key] or "") .. " " .. (sortDisplayNames[key] or key)
        end

        local ddW, ddH, rowH = 90, 20, 18

        -- Dropdown button — no background, blends into the toolbar.
        -- Only a right-side separator line marks it as a button.
        local sortDropBtn = CreateFrame("Button", nil, toolbar)
        sortDropBtn:SetPoint("LEFT", toolbar, "LEFT", 4, 0)
        sortDropBtn:SetSize(ddW, ddH)
        sortDropBtn:SetFrameLevel(toolbar:GetFrameLevel() + 1)

        -- Subtle hover tint only (no opaque bg)
        local ddBtnHL = sortDropBtn:CreateTexture(nil, "HIGHLIGHT")
        ddBtnHL:SetAllPoints(); ddBtnHL:SetTexture("Interface\\Buttons\\WHITE8x8")
        ddBtnHL:SetVertexColor(1, 1, 1, 0.06)

        local ddBtnLabel = sortDropBtn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        ddBtnLabel:SetPoint("LEFT", sortDropBtn, "LEFT", 5, 0)
        ddBtnLabel:SetPoint("RIGHT", sortDropBtn, "RIGHT", -14, 0)
        ddBtnLabel:SetJustifyH("LEFT")
        ddBtnLabel:SetFont("Fonts\\FRIZQT__.TTF", 9, "OUTLINE")
        ddBtnLabel:SetTextColor(0.9, 0.9, 0.9)
        ddBtnLabel:SetText(GetSortLabel(PVPHUB_SETTINGS.compactSortKey))

        -- "v" chevron on the right
        local ddArrow = sortDropBtn:CreateFontString(nil, "OVERLAY")
        ddArrow:SetFont("Fonts\\FRIZQT__.TTF", 8, "OUTLINE")
        ddArrow:SetPoint("RIGHT", sortDropBtn, "RIGHT", -3, 0)
        ddArrow:SetTextColor(0.55, 0.55, 0.55); ddArrow:SetText(CreateAtlasMarkup("auctionhouse-ui-sortarrow", 8, 8))

        -- Single 1 px separator on the right edge only
        local sep = sortDropBtn:CreateTexture(nil, "BORDER")
        sep:SetTexture("Interface\\Buttons\\WHITE8x8")
        sep:SetVertexColor(0.32, 0.32, 0.40, 0.7)
        sep:SetWidth(1)
        sep:SetPoint("TOPRIGHT",    sortDropBtn, "TOPRIGHT",  0,  -2)
        sep:SetPoint("BOTTOMRIGHT", sortDropBtn, "BOTTOMRIGHT", 0,  2)

        -- Popup (opens downward, below the toolbar)
        local ddPopup = CreateFrame("Frame", nil, UIParent)
        ddPopup:SetSize(ddW, #sortKeys * rowH)
        ddPopup:SetFrameStrata("FULLSCREEN_DIALOG"); ddPopup:SetFrameLevel(200)
        ddPopup:Hide()
        local ppBg = ddPopup:CreateTexture(nil,"BACKGROUND"); ppBg:SetAllPoints()
        ppBg:SetTexture("Interface\\Buttons\\WHITE8x8"); ppBg:SetVertexColor(0.10, 0.10, 0.14, 0.97)
        -- Border
        for _, anchor in ipairs({
            {"TOPLEFT","TOPRIGHT",1,nil},{"BOTTOMLEFT","BOTTOMRIGHT",1,nil},
            {"TOPLEFT","BOTTOMLEFT",nil,1},{"TOPRIGHT","BOTTOMRIGHT",nil,1},
        }) do
            local t = ddPopup:CreateTexture(nil,"BORDER"); t:SetTexture("Interface\\Buttons\\WHITE8x8")
            t:SetVertexColor(0.3,0.3,0.38,1)
            t:SetPoint(anchor[1]); t:SetPoint(anchor[2])
            if anchor[3] then t:SetHeight(anchor[3]) end
            if anchor[4] then t:SetWidth(anchor[4]) end
        end

        -- Click-away catcher
        local ddCatcher = CreateFrame("Frame", nil, UIParent)
        ddCatcher:SetAllPoints(UIParent); ddCatcher:EnableMouse(true)
        ddCatcher:SetFrameStrata("FULLSCREEN_DIALOG"); ddCatcher:SetFrameLevel(199); ddCatcher:Hide()
        ddCatcher:SetScript("OnMouseDown", function() ddPopup:Hide() end)
        ddPopup:SetScript("OnHide", function() ddCatcher:Hide() end)

        -- Popup rows
        local function refreshHighlight()
            for _, row in ipairs(ddPopup.rows) do
                if row.key == PVPHUB_SETTINGS.compactSortKey then
                    row.bg:SetVertexColor(0, 0.75, 1, 0.20)
                else
                    row.bg:SetVertexColor(0, 0, 0, 0)
                end
            end
        end
        ddPopup.rows = {}
        for i, key in ipairs(sortKeys) do
            local row = CreateFrame("Button", nil, ddPopup)
            row:SetSize(ddW, rowH)
            row:SetPoint("TOPLEFT", ddPopup, "TOPLEFT", 0, -(i-1)*rowH)
            local rbg = row:CreateTexture(nil,"BACKGROUND"); rbg:SetAllPoints()
            rbg:SetTexture("Interface\\Buttons\\WHITE8x8"); rbg:SetVertexColor(0,0,0,0)
            local rhl = row:CreateTexture(nil,"HIGHLIGHT"); rhl:SetAllPoints()
            rhl:SetTexture("Interface\\Buttons\\WHITE8x8"); rhl:SetVertexColor(0,0.75,1,0.13)
            local rtxt = row:CreateFontString(nil,"OVERLAY","GameFontNormalSmall")
            rtxt:SetPoint("LEFT",row,"LEFT",6,0); rtxt:SetJustifyH("LEFT")
            rtxt:SetFont("Fonts\\FRIZQT__.TTF",9,"OUTLINE"); rtxt:SetTextColor(0.9,0.9,0.9)
            rtxt:SetText(GetSortLabel(key))
            row.key = key; row.bg = rbg
            row:SetScript("OnClick", function()
                PVPHUB_SETTINGS.compactSortKey = key
                ddBtnLabel:SetText(GetSortLabel(key))
                ddPopup:Hide()
                if PVPHUB.UpdateCompactWindow then PVPHUB:UpdateCompactWindow() end
            end)
            table.insert(ddPopup.rows, row)
        end

        ddPopup:SetScript("OnShow", function()
            -- anchor popup just below the toolbar (opens downward)
            ddPopup:ClearAllPoints()
            ddPopup:SetPoint("TOPLEFT", sortDropBtn, "BOTTOMLEFT", 0, -2)
            refreshHighlight()
            ddCatcher:Show()
        end)

        sortDropBtn:SetScript("OnClick", function()
            if ddPopup:IsShown() then ddPopup:Hide() else ddPopup:Show() end
        end)

        -- Keep references so UpdateCompactWindow can still update the label
        PVPHUB.compactWindow.sortBtnText  = ddBtnLabel  -- same field, just a FontString
        PVPHUB.compactWindow.GetSortLabel = GetSortLabel
        PVPHUB.compactWindow.sortDropPopup = ddPopup
        local initialWidth = PVPHUB_CONSTANTS.COMPACT_WINDOW.MIN_WIDTH
        local initialHeight = 80 -- Better initial height
        PVPHUB.compactWindow:SetWidth(initialWidth)
        PVPHUB.compactWindow:SetHeight(initialHeight)
        -- Restore position if saved (always clear first to avoid duplicate anchors)
        PVPHUB.compactWindow:ClearAllPoints()
        if PVPHUB_SETTINGS.compactWindowPos then
            local pos = PVPHUB_SETTINGS.compactWindowPos
            PVPHUB.compactWindow:SetPoint(pos.point or "TOPLEFT", UIParent, pos.relativePoint or "TOPLEFT", pos.x or 100, pos.y or -100)
        else
            PVPHUB.compactWindow:SetPoint("TOPLEFT", UIParent, "TOPLEFT", 100, -100)
        end
        PVPHUB.compactWindow:SetMovable(true)
        PVPHUB.compactWindow:EnableMouse(true)
        PVPHUB.compactWindow:RegisterForDrag("LeftButton")
        PVPHUB.compactWindow:SetClampedToScreen(true)
        -- Reserve space below the window equal to the toolbar height so the
        -- toolbar (anchored below the content frame) is never pushed off-screen.
        PVPHUB.compactWindow:SetClampRectInsets(0, 0, 0, toolbarHeight + 1)
        PVPHUB.compactWindow:SetScript("OnDragStart", PVPHUB.compactWindow.StartMoving)
        PVPHUB.compactWindow:SetScript("OnDragStop", function(self)
            self:StopMovingOrSizing()
            if not PVPHUB_SETTINGS.compactWindowPos then PVPHUB_SETTINGS.compactWindowPos = {} end
            local point, relativeTo, relativePoint, xOfs, yOfs = self:GetPoint()
            PVPHUB_SETTINGS.compactWindowPos = {point=point, relativePoint=relativePoint, x=xOfs, y=yOfs}
        end)
        
        -- Respect hideBackground setting
        if not PVPHUB_SETTINGS.compactMode.hideBackground then
            PVPHUB.compactWindow:SetBackdrop({
                bgFile = "Interface\\Buttons\\WHITE8x8",
                tile = false,
                insets = { left = 0, right = 0, top = 0, bottom = 0 }
            })
            local color = PVPHUB_SETTINGS.compactMode.backgroundColor or {unpack(UI_CONSTANTS.COLORS.COMPACT_BG)}
            PVPHUB.compactWindow:SetBackdropColor(color[1], color[2], color[3], color[4] or 0.8)
        else
            PVPHUB.compactWindow:SetBackdrop(nil)
        end

        -- Character rows container — fills the full window; the overlay drifts on top at the bottom.
        PVPHUB.compactWindow.content = CreateFrame("Frame", nil, PVPHUB.compactWindow)
        PVPHUB.compactWindow.content:SetPoint("TOPLEFT", 8, -5)
        PVPHUB.compactWindow.content:SetPoint("BOTTOMRIGHT", PVPHUB.compactWindow, "BOTTOMRIGHT", -8, 5)
        
        -- Close button — same desaturated-silver style as the main window
        PVPHUB.compactWindow.closeBtn = CreateFrame("Button", nil, toolbar, "UIPanelCloseButton")
        PVPHUB.compactWindow.closeBtn:SetPoint("RIGHT", toolbar, "RIGHT", -3, 0)
        PVPHUB.compactWindow.closeBtn:SetSize(18, 18)
        do
            local _nt = PVPHUB.compactWindow.closeBtn:GetNormalTexture()
            local _pt = PVPHUB.compactWindow.closeBtn:GetPushedTexture()
            local _ht = PVPHUB.compactWindow.closeBtn:GetHighlightTexture()
            _nt:SetDesaturated(true); _nt:SetVertexColor(0.82, 0.82, 0.88, 1)
            _pt:SetDesaturated(true); _pt:SetVertexColor(0.55, 0.55, 0.60, 1)
            _ht:SetDesaturated(true); _ht:SetVertexColor(1,    1,    1,    1)
        end
        PVPHUB.compactWindow.closeBtn:SetScript("OnClick", function()
            PVPHUB_SETTINGS.compactWindowStayOpen = false
            PVPHUB.compactWindow:Hide()
            if PVPHUB.compactWindow.RefreshSettingsToggle then
                PVPHUB.compactWindow.RefreshSettingsToggle()
            end
        end)
        PVPHUB.compactWindow.closeBtn:HookScript("OnClick", function()
            if not PVPHUB_SETTINGS.compactWindowPos then PVPHUB_SETTINGS.compactWindowPos = {} end
            local point, relativeTo, relativePoint, xOfs, yOfs = PVPHUB.compactWindow:GetPoint()
            PVPHUB_SETTINGS.compactWindowPos = {point=point, relativePoint=relativePoint, x=xOfs, y=yOfs}
        end)
        
        -- Settings button (in toolbar, next to close button)
        PVPHUB.compactWindow.settingsBtn = CreateFrame("Button", nil, toolbar)
        PVPHUB.compactWindow.settingsBtn:SetSize(14, 14)
        PVPHUB.compactWindow.settingsBtn:SetPoint("RIGHT", PVPHUB.compactWindow.closeBtn, "LEFT", -2, 0)
        PVPHUB.compactWindow.settingsBtn:SetNormalTexture("Interface\\Buttons\\UI-OptionsButton")
        PVPHUB.compactWindow.settingsBtn:SetScript("OnClick", function() PVPHUB:ShowCompactSettings() end)
        PVPHUB.compactWindow.settingsBtn:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_CURSOR")
            GameTooltip:SetText("Settings", 1, 1, 1)
            GameTooltip:Show()
        end)
        PVPHUB.compactWindow.settingsBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
        
        -- Scale slider for compact window (positioned inside bottom toolbar)
        -- Clamp the saved scale to the valid slider range [1.0, 2.0] so that
        -- values from older addon versions (e.g. 0.75) don't produce a wrong
        -- label or push the slider thumb outside its bounds.
        PVPHUB_SETTINGS.compactWindowScale = math.max(1.0, math.min(2.0, PVPHUB_SETTINGS.compactWindowScale or 1.0))
        PVPHUB.compactWindow.currentScale = PVPHUB_SETTINGS.compactWindowScale
        
        -- Create scale slider (positioned in bottom toolbar, right side with more spacing from buttons)
        local scaleSlider = CreateFrame("Slider", nil, toolbar, "MinimalSliderTemplate")
        scaleSlider:SetPoint("RIGHT", toolbar, "RIGHT", -40, 0)
        scaleSlider:SetSize(60, 10)
        scaleSlider:SetMinMaxValues(1.0, 2.0)
        scaleSlider:SetValue(PVPHUB.compactWindow.currentScale)
        scaleSlider:SetValueStep(0.01)
        scaleSlider:SetObeyStepOnDrag(true)
        
        -- Scale label (positioned to left of slider)
        local scaleLabel = toolbar:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        scaleLabel:SetPoint("RIGHT", scaleSlider, "LEFT", -5, 0)
        scaleLabel:SetFont("Fonts\\FRIZQT__.TTF", 9, "OUTLINE")
        scaleLabel:SetTextColor(0.8, 0.8, 0.8)
        -- Set text AFTER clamping so it always reflects the actual slider value.
        scaleLabel:SetText(string.format("%d%%", PVPHUB.compactWindow.currentScale * 100))
        
        -- Handle value changes
        -- NOTE: SetScale is applied on MouseUp, not OnValueChanged, because this slider
        -- lives inside compactWindow itself — rescaling the parent mid-drag would shift
        -- the slider under the cursor and cause a feedback glitch.
        -- NOTE: The compact window has RegisterForDrag("LeftButton"), so we must temporarily
        -- disable its movable state while dragging the slider, otherwise both the window drag
        -- and the slider drag activate simultaneously, causing the window to move under the
        -- cursor and the slider value to jump erratically.
        scaleSlider:SetScript("OnValueChanged", function(self, value)
            if not value then return end
            PVPHUB_SETTINGS.compactWindowScale = value
            PVPHUB.compactWindow.currentScale = value
            scaleLabel:SetText(string.format("%d%%", value * 100))
        end)

        scaleSlider:SetScript("OnMouseDown", function(self, button)
            if button == "LeftButton" then
                -- Lock out window dragging so the parent frame doesn't start moving
                -- while we're adjusting the slider value.
                PVPHUB.compactWindow:StopMovingOrSizing()
                PVPHUB.compactWindow:SetMovable(false)
            end
        end)

        scaleSlider:SetScript("OnMouseUp", function(self, button)
            if button == "LeftButton" then
                -- Re-enable window dragging and apply the new scale.
                PVPHUB.compactWindow:SetMovable(true)
                PVPHUB.compactWindow:SetScale(PVPHUB_SETTINGS.compactWindowScale)
            end
        end)
        
        -- Tooltip
        scaleSlider:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_CURSOR")
            GameTooltip:SetText("Window Scale", 1, 1, 1)
            GameTooltip:AddLine("Drag to adjust window size", 0.7, 0.7, 0.7, true)
            GameTooltip:AddLine(string.format("Current: %d%% (Range: 100%% - 200%%)", self:GetValue() * 100), 0.7, 0.7, 0.7, true)
            GameTooltip:Show()
        end)
        
        scaleSlider:SetScript("OnLeave", function(self)
            GameTooltip:Hide()
        end)
        
        -- Store references for theme updates and fade functionality
        PVPHUB.compactWindow.scaleSlider = scaleSlider
        PVPHUB.compactWindow.scaleLabel = scaleLabel
        
        -- Apply saved scale to compact window
        PVPHUB.compactWindow:SetScale(PVPHUB.compactWindow.currentScale)
        
        -- Overlay starts fully visible; the idle timer fades it out as one unit.
        -- Fading the parent toolbar frame automatically fades all its children.
        PVPHUB.compactWindow.fadeTimer = nil
        toolbar:SetAlpha(1)

        local function fadeToolbarIn()
            UIFrameFadeIn(toolbar, 0.3, toolbar:GetAlpha(), 1)
        end

        local function fadeToolbarOut()
            UIFrameFadeOut(toolbar, 1, toolbar:GetAlpha(), 0)
        end

        local function startFadeTimer()
            if PVPHUB.compactWindow.fadeTimer then
                PVPHUB.compactWindow.fadeTimer:Cancel()
            end
            PVPHUB.compactWindow.fadeTimer = C_Timer.NewTimer(3, function()
                PVPHUB.compactWindow.fadeTimer = nil
                fadeToolbarOut()
            end)
        end

        local function cancelFadeTimer()
            if PVPHUB.compactWindow.fadeTimer then
                PVPHUB.compactWindow.fadeTimer:Cancel()
                PVPHUB.compactWindow.fadeTimer = nil
            end
            fadeToolbarIn()
        end
        
        -- Set up hover detection on both the window and the toolbar below it
        PVPHUB.compactWindow:SetScript("OnEnter", function()
            cancelFadeTimer()
        end)
        
        PVPHUB.compactWindow:SetScript("OnLeave", function()
            startFadeTimer()
        end)

        toolbar:EnableMouse(true)
        toolbar:SetScript("OnEnter", function()
            cancelFadeTimer()
        end)
        toolbar:SetScript("OnLeave", function()
            startFadeTimer()
        end)
        
        -- Start the initial fade timer
        startFadeTimer()
    end
    
    PVPHUB:UpdateCompactWindow()
    PVPHUB.compactWindow:Show()
    PVPHUB_SETTINGS.compactWindowStayOpen = true
end

function PVPHUB:UpdateCompactWindow()
    if not PVPHUB.compactWindow or not PVPHUB.compactWindow.content then return end

    -- Font path is resolved by ApplyCompactFontChanges (on change) or by
    -- CreateCompactWindow (on first open / reload). Don't re-resolve it here —
    -- doing so with a limited built-in list would overwrite the LSM path that
    -- was already correctly set, causing font changes to appear not to work.
    if not PVPHUB.compactCurrentFontPath then
        PVPHUB.compactCurrentFontPath = FALLBACK_FONT
    end

    -- Ensure compact mode settings exist
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
    PVPHUB_SETTINGS.compactMode.pinnedSpecs = PVPHUB_SETTINGS.compactMode.pinnedSpecs or {}
    
    -- Respect hideBackground setting (refresh on every update)
    if PVPHUB_SETTINGS.compactMode.hideBackground then
        PVPHUB.compactWindow:SetBackdrop(nil)
    else
        PVPHUB.compactWindow:SetBackdrop({
            bgFile = "Interface\\Buttons\\WHITE8x8",
            edgeFile = "Interface\\Buttons\\WHITE8x8",
            tile = false,
            edgeSize = 1,
            insets = { left = 1, right = 1, top = 1, bottom = 1 }
        })
        local color = PVPHUB_SETTINGS.compactMode.backgroundColor or {unpack(UI_CONSTANTS.COLORS.COMPACT_BG)}
        PVPHUB.compactWindow:SetBackdropColor(color[1], color[2], color[3], color[4] or 0.8)
        PVPHUB.compactWindow:SetBackdropBorderColor(0, 0, 0, 0)
    end
    
    -- If nothing is selected AND nothing is pinned, add current character by
    -- default. Checking pinnedSpecs too matters because graduating to
    -- pinned-spec rows (PromoteToMultiSpecIfNeeded) removes a character from
    -- selectedChars, which can leave it at zero entries even though the
    -- character is still very much being shown via its pinned row(s) — without
    -- this check, this default would re-add that character to selectedChars
    -- right back on top of its pinned row, producing a duplicate.
    if #PVPHUB_SETTINGS.compactMode.selectedChars == 0 then
        local hasAnyPin = false
        for _, pins in pairs(PVPHUB_SETTINGS.compactMode.pinnedSpecs) do
            if next(pins) then hasAnyPin = true; break end
        end
        if not hasAnyPin then
            local currentChar = GetFullName()
            if currentChar and PVPHUB_DB[currentChar] then
                table.insert(PVPHUB_SETTINGS.compactMode.selectedChars, currentChar)
            end
        end
    end
    -- Remove any prompt about opening PvP window for compact mode; data is fetched automatically for current character
    
    -- Calculate dynamic window width based on visible columns
    local visibleRatingCount = 0
    for _, bracket in ipairs(PVP_BRACKETS) do
        if PVPHUB_SETTINGS.compactMode.showRatings[bracket.key] then
            visibleRatingCount = visibleRatingCount + 1
        end
    end
    
    local dynamicWidth = math.max(
        PVPHUB_CONSTANTS.COMPACT_WINDOW.MIN_WIDTH,
        PVPHUB_CONSTANTS.COMPACT_WINDOW.BASE_WIDTH + (visibleRatingCount * PVPHUB_CONSTANTS.COMPACT_WINDOW.COLUMN_WIDTH)
    )
    
    -- Update window and content width
    PVPHUB.compactWindow:SetWidth(dynamicWidth)
    PVPHUB.compactWindow.content:SetWidth(dynamicWidth - 16)

    -- Keep the sort cycle button label in sync
    if PVPHUB.compactWindow.sortBtnText and PVPHUB.compactWindow.GetSortLabel then
        PVPHUB.compactWindow.sortBtnText:SetText(PVPHUB.compactWindow.GetSortLabel(PVPHUB_SETTINGS.compactSortKey or "highestRating"))
    end
    
    -- Clear existing content: hide AND deparent so stale frames don't
    -- accumulate as siblings under content, which causes WoW to glitch
    -- rendering of newly created frames at the same anchor position.
    for _, row in ipairs(PVPHUB.compactWindow.rows or {}) do
        row:Hide()
        row:SetParent(nil)
    end
    for _, header in ipairs(PVPHUB.compactWindow.headers or {}) do
        header:Hide()
        header:SetParent(nil)
    end
    PVPHUB.compactWindow.rows = {}
    PVPHUB.compactWindow.headers = {}
    
    local yOffset = 0
    local rowHeight = PVPHUB_CONSTANTS.COMPACT_WINDOW.ROW_HEIGHT
    
    -- Create headers first
    local headerRow = CreateFrame("Frame", nil, PVPHUB.compactWindow.content)
    headerRow:SetSize(dynamicWidth - 16, rowHeight)
    headerRow:SetPoint("TOPLEFT", 0, -yOffset - 3) -- Add 3px top padding
    
    -- Character header
    local charHeader = headerRow:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    charHeader:SetPoint("LEFT", 8, 0)
    charHeader:SetWidth(PVPHUB_CONSTANTS.COMPACT_WINDOW.BASE_WIDTH - 15) -- Leave some padding
    charHeader:SetJustifyH("LEFT")
    charHeader:SetWordWrap(false) -- Prevent text wrapping
    charHeader:SetNonSpaceWrap(false) -- Prevent wrapping on non-space characters
    charHeader:SetMaxLines(1) -- Force single line display
    charHeader:SetText("|cffFFD700Character|r")
    SafeSetFont(charHeader, PVPHUB.compactCurrentFontPath, 10, "OUTLINE")
    
    -- Rating headers with dynamic positioning
    local headerData = COMPACT_BRACKET_ORDER
    
    local columnIndex = 0
    for _, header in ipairs(headerData) do
        if PVPHUB_SETTINGS.compactMode.showRatings[header.key] then
            local xPos = PVPHUB_CONSTANTS.COMPACT_WINDOW.BASE_WIDTH + (columnIndex * PVPHUB_CONSTANTS.COMPACT_WINDOW.COLUMN_WIDTH) - 5
            local headerText = headerRow:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            headerText:SetPoint("LEFT", xPos, 0)
            headerText:SetWidth(PVPHUB_CONSTANTS.COMPACT_WINDOW.COLUMN_WIDTH - 10) -- Set width for centering
            headerText:SetJustifyH("CENTER") -- Center the header text
            headerText:SetText("|cffFFD700" .. header.icon .. " " .. header.name .. "|r")
            SafeSetFont(headerText, PVPHUB.compactCurrentFontPath, 9, "OUTLINE")
            columnIndex = columnIndex + 1
        end
    end
    
    table.insert(PVPHUB.compactWindow.headers, headerRow)
    yOffset = yOffset + rowHeight + 5  -- Extra space after header
    
    -- Sort and show selected characters by compactSortKey
    local sortKey = PVPHUB_SETTINGS.compactSortKey or "highestRating"
    local hideNoRating = PVPHUB_SETTINGS.compactMode.hideNoRating

    MigratePinnedSpecsSchema()

    -- Auto-graduate any character that has grown a second rated spec since we
    -- last checked, BEFORE reading selectedChars below, so isMainSelected
    -- reflects the post-graduation state instead of a stale snapshot. Iterate
    -- a copy since PromoteToMultiSpecIfNeeded may remove entries from the live
    -- selectedChars array.
    do
        local snapshot = {}
        for _, charKey in ipairs(PVPHUB_SETTINGS.compactMode.selectedChars) do
            table.insert(snapshot, charKey)
        end
        for _, charKey in ipairs(snapshot) do
            local data = PVPHUB_DB[charKey]
            if data then
                PromoteToMultiSpecIfNeeded(charKey, data)
            end
        end
    end

    -- Self-heal: a character that already graduated to pinned-spec rows in an
    -- earlier session (promotedMultiSpec already set) skips the graduation
    -- above, so if it somehow also ended up back in selectedChars — e.g. the
    -- "nothing selected" default above re-adding it after graduating emptied
    -- the list — strip it out here every time rather than only at the moment
    -- of graduation, so a stale entry like that can't linger indefinitely.
    do
        local sel = PVPHUB_SETTINGS.compactMode.selectedChars
        for i = #sel, 1, -1 do
            local pins = PVPHUB_SETTINGS.compactMode.pinnedSpecs[sel[i]]
            if pins and next(pins) then
                table.remove(sel, i)
            end
        end
    end

    -- A character shows up if it's explicitly selected (no rated spec yet) OR
    -- has any pinned spec — never both, since graduating to pinned rows always
    -- removes the character from selectedChars (see the self-heal above).
    local isMainSelected = {}
    for _, charKey in ipairs(PVPHUB_SETTINGS.compactMode.selectedChars) do
        isMainSelected[charKey] = true
    end
    local charKeysToShow = {}
    for charKey in pairs(isMainSelected) do
        charKeysToShow[charKey] = true
    end
    for charKey, pinned in pairs(PVPHUB_SETTINGS.compactMode.pinnedSpecs) do
        if next(pinned) then
            charKeysToShow[charKey] = true
        end
    end

    -- Build one group per character (main row + its pinned-spec rows) instead of a
    -- flat list, so pinned rows can be kept adjacent to their character below
    -- instead of scattering across the list by rating. A character only ever
    -- has a mainEntry OR pinnedEntries in practice — once graduated to
    -- multi-spec it's removed from selectedChars for good — so there's no
    -- longer a need to guard against a pinned row duplicating the main one.
    local groups = {}
    for charKey in pairs(charKeysToShow) do
        local data = PVPHUB_DB[charKey]
        if data and not IsCharacterHidden(charKey) then
            if not hideNoRating or compactHasAnyRating(data) then
                local pinned = PVPHUB_SETTINGS.compactMode.pinnedSpecs[charKey]
                local group = { char = charKey, data = data, mainEntry = nil, pinnedEntries = {} }

                -- Default "current spec" row — only for single-spec characters
                -- explicitly selected via the main checkbox.
                if isMainSelected[charKey] then
                    group.mainEntry = { char = charKey, data = data }
                end

                -- Rows for every spec explicitly ticked on this character —
                -- each shows that spec's rating across every enabled bracket
                -- column, so more than one spec can be showcased at once.
                -- A pin with no real rating anywhere is skipped and quietly
                -- unticked — this self-heals any stray 0-rated pin saved
                -- before PromoteToMultiSpecIfNeeded stopped seeding those,
                -- and it also wouldn't be reachable to untick manually since
                -- the settings list only offers candidates with rating > 0.
                if pinned then
                    for specID in pairs(pinned) do
                        if CharacterHasRatingForSpec(data, specID) then
                            table.insert(group.pinnedEntries, {
                                char         = charKey,
                                data         = data,
                                pinnedSpecID = specID,
                            })
                        else
                            pinned[specID] = nil
                        end
                    end
                end

                if group.mainEntry or #group.pinnedEntries > 0 then
                    table.insert(groups, group)
                end
            end
        end
    end

    -- Returns the rating that the display will actually show for a multi-spec bracket.
    -- Mirrors getMultiSpecDisplay: current spec's rating, or highest if spec is unknown.
    local function getDisplayedRating(ratingTable, currentSpecID)
        if type(ratingTable) == "number" then return ratingTable end
        if type(ratingTable) ~= "table" then return 0 end
        if currentSpecID and currentSpecID ~= 0 then
            return ratingTable[currentSpecID] or 0
        end
        -- Unknown spec — fall back to highest, same as the display does
        local max = 0
        for _, v in pairs(ratingTable) do
            if v > max then max = v end
        end
        return max
    end

    -- A pinned row now shows every enabled bracket for its one specific spec
    -- (just like the main row, but for that spec instead of "whichever is
    -- active"), so sorting only needs to swap in pinnedSpecID wherever the
    -- character's live current spec would otherwise be used.
    local function getHighestRating(entry)
        local maxRating = 0
        local d = entry.data
        local specID = entry.pinnedSpecID or d.specID or d.lastActiveSpecID
        local shuffle = getDisplayedRating(d.ratingShuffle, specID)
        if shuffle > maxRating then maxRating = shuffle end
        for _, k in ipairs({"rating2v2", "rating3v3", "ratingRBG"}) do
            if type(d[k]) == "number" and d[k] > maxRating then
                maxRating = d[k]
            end
        end
        local blitz = getDisplayedRating(d.ratingBlitz, specID)
        if blitz > maxRating then maxRating = blitz end
        return maxRating
    end

    -- Value used to sort one entry when sorting by a specific bracket column
    -- (as opposed to "highestRating" across all brackets).
    local function getSortValue(entry)
        if sortKey == "ratingShuffle" or sortKey == "ratingBlitz" then
            local specID = entry.pinnedSpecID or entry.data.specID or entry.data.lastActiveSpecID
            return getDisplayedRating(entry.data[sortKey], specID)
        end
        return entry.data[sortKey] or 0
    end

    -- A group's sort value is the best of its main row and all its pinned rows,
    -- so a character with a strong pinned-spec rating still sorts near the top
    -- even if its main (current-spec) row is weaker.
    local function getGroupSortValue(group)
        local best = 0
        local valueOf = (sortKey == "highestRating") and getHighestRating or getSortValue
        if group.mainEntry then
            best = valueOf(group.mainEntry)
        end
        for _, entry in ipairs(group.pinnedEntries) do
            local v = valueOf(entry)
            if v > best then best = v end
        end
        return best
    end

    table.sort(groups, function(a, b)
        local aVal, bVal = getGroupSortValue(a), getGroupSortValue(b)
        if aVal ~= bVal then
            return aVal > bVal
        end
        -- Tiebreaker: without this, characters tied at the same value (most
        -- commonly 0 — no rating at all in the sorted bracket) fall back to
        -- pairs() hash order, which isn't deterministic and can shuffle
        -- between reloads. Alphabetical keeps it stable and predictable.
        return a.char:lower() < b.char:lower()
    end)

    -- Within a group, order pinned rows by rating too, then flatten: main row
    -- first (if any), followed immediately by its pinned rows — this is what
    -- keeps a character's rows anchored together instead of scattered by rating.
    -- Each entry is tagged isSubRow: true for every row EXCEPT the first one in
    -- its group. That first row is the group's anchor — main row if one exists,
    -- otherwise whichever pinned row sorts highest — and always renders plain
    -- (no indent/connector/dimming), since a group with no main row can still
    -- end up as a single row sitting next to a totally unrelated character
    -- after sorting; only rows that truly sit under their own group's anchor
    -- should look connected to it.
    local selected = {}
    for _, group in ipairs(groups) do
        table.sort(group.pinnedEntries, function(a, b)
            return getHighestRating(a) > getHighestRating(b)
        end)
        local isFirstInGroup = true
        if group.mainEntry then
            group.mainEntry.isSubRow = false
            table.insert(selected, group.mainEntry)
            isFirstInGroup = false
        end
        for _, entry in ipairs(group.pinnedEntries) do
            entry.isSubRow = not isFirstInGroup
            table.insert(selected, entry)
            isFirstInGroup = false
        end
    end

    local visibleCharCount = 0
    for _, entry in ipairs(selected) do
        local row = PVPHUB:CreateCompactCharacterRow(entry.char, entry.data, yOffset, dynamicWidth, entry.pinnedSpecID, entry.isSubRow)
        if row then
            table.insert(PVPHUB.compactWindow.rows, row)
            yOffset = yOffset + rowHeight
            visibleCharCount = visibleCharCount + 1
        end
    end
    
    -- Calculate dynamic window height based on content only.
    -- The overlay toolbar floats on top and does not reserve space.
    local headerHeight = rowHeight + 5
    local characterRowsHeight = visibleCharCount * rowHeight
    local windowPadding = 14 -- top (5) + bottom (9)

    local dynamicHeight = math.max(40, headerHeight + characterRowsHeight + windowPadding)
    
    -- Update window height dynamically
    PVPHUB.compactWindow:SetHeight(dynamicHeight)
    PVPHUB.compactWindow.content:SetSize(dynamicWidth - 16, yOffset)
end

-- pinnedSpecID (optional): renders this character's row showing THAT spec's
-- rating across every enabled bracket column, instead of the character's live
-- current spec — same shape as the default row, just scoped to one specific
-- spec, so a character can have more than one spec shown as its own row at
-- the same time (see PromoteToMultiSpecIfNeeded).
-- isSubRow: true when this row sits directly under another row of the SAME
-- character (its group's anchor) in the flattened, sorted list. A pinned-spec
-- row is NOT automatically a sub-row — if its character has no main row shown,
-- it's the only row for that character and may land next to a completely
-- unrelated character after sorting, so it must render as a plain anchor row
-- itself rather than visually latching onto whatever happens to be above it.
function PVPHUB:CreateCompactCharacterRow(charKey, data, yOffset, windowWidth, pinnedSpecID, isSubRow)
    local content = PVPHUB.compactWindow.content
    local row = CreateFrame("Frame", nil, content)
    row:SetSize((windowWidth or PVPHUB_CONSTANTS.COMPACT_WINDOW.MIN_WIDTH) - 16, PVPHUB_CONSTANTS.COMPACT_WINDOW.ROW_HEIGHT)
    row:SetPoint("TOPLEFT", 0, -yOffset)

    -- Row hover highlight (same as main window)
    local hoverBG = row:CreateTexture(nil, "OVERLAY")
    hoverBG:SetTexture("Interface\\Buttons\\WHITE8x8")
    local _cTheme = GetCurrentTheme()
    local _hc = _cTheme.HOVER_BG
    hoverBG:SetVertexColor(_hc[1], _hc[2], _hc[3], _hc[4])
    hoverBG:SetAllPoints(row)
    hoverBG:Hide()

    -- Character name (truncated if too long). On a pinned-spec row, show that
    -- spec's icon instead of the character's currently-active one, so the
    -- duplicated rows for one character are visually distinguishable.
    -- Sub-rows are indented with a small tree connector so they read as
    -- belonging to the row directly above them, instead of looking like an
    -- unrelated duplicate entry once rows are grouped adjacently.
    local nameIndent = isSubRow and 16 or 5
    if isSubRow then
        local connectorV = row:CreateTexture(nil, "OVERLAY")
        connectorV:SetTexture("Interface\\Buttons\\WHITE8x8")
        connectorV:SetVertexColor(0.5, 0.5, 0.55, 0.6)
        connectorV:SetWidth(1)
        connectorV:SetPoint("TOPLEFT", row, "TOPLEFT", 9, 0)
        connectorV:SetPoint("BOTTOM", row, "CENTER", 0, 0)

        local connectorH = row:CreateTexture(nil, "OVERLAY")
        connectorH:SetTexture("Interface\\Buttons\\WHITE8x8")
        connectorH:SetVertexColor(0.5, 0.5, 0.55, 0.6)
        connectorH:SetHeight(1)
        connectorH:SetPoint("LEFT", row, "LEFT", 9, 0)
        connectorH:SetPoint("RIGHT", row, "LEFT", nameIndent, 0)
        connectorH:SetPoint("TOP", row, "CENTER", 0, 0)
    end

    local nameText = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    nameText:SetPoint("LEFT", nameIndent, 0)
    nameText:SetWidth(PVPHUB_CONSTANTS.COMPACT_WINDOW.BASE_WIDTH - 15 - (nameIndent - 5)) -- Leave some padding
    nameText:SetJustifyH("LEFT")
    nameText:SetWordWrap(false) -- Prevent text wrapping
    nameText:SetNonSpaceWrap(false) -- Prevent wrapping on non-space characters
    nameText:SetMaxLines(1) -- Force single line display
    if pinnedSpecID then
        local pinnedSpecIcon = ""
        local _si = GetCachedSpecInfo(pinnedSpecID)
        if _si and _si.icon then
            pinnedSpecIcon = "|T" .. _si.icon .. ":14|t "
        end
        -- Suppress the current-character dot on sub-rows — the anchor row
        -- above already shows it, and repeating it here is just noise. A solo
        -- pinned row (no main row shown) keeps its dot since it's the only
        -- representation of that character in the list.
        nameText:SetText(pinnedSpecIcon .. CreateCharacterName({char = charKey, data = data}, true, true, isSubRow))
        if isSubRow then
            nameText:SetAlpha(0.85) -- Slightly dimmed to read as a sub-row of the row above
        end
    else
        nameText:SetText(CreateCharacterName({char = charKey, data = data}, true))
    end
    -- Use compact-specific font
    SafeSetFont(nameText, PVPHUB.compactCurrentFontPath, 11)
    -- Add backdrop shadow for better readability
    nameText:SetShadowOffset(2, -2)
    nameText:SetShadowColor(0, 0, 0, 1)

    -- Add character tooltip to name area
    local nameTooltipBtn = CreateFrame("Button", nil, row)
    nameTooltipBtn:SetPoint("LEFT", nameIndent, 0)
    nameTooltipBtn:SetSize(PVPHUB_CONSTANTS.COMPACT_WINDOW.BASE_WIDTH - 15, PVPHUB_CONSTANTS.COMPACT_WINDOW.ROW_HEIGHT)
    nameTooltipBtn:SetScript("OnEnter", function()
        hoverBG:Show()
        ShowCharacterTooltip(charKey, nameTooltipBtn)
    end)
    nameTooltipBtn:SetScript("OnLeave", function()
        hoverBG:Hide()
        HideCharacterTooltip()
    end)
    
    -- Ensure compact mode settings exist
    if not PVPHUB_SETTINGS.compactMode or not PVPHUB_SETTINGS.compactMode.showRatings then
        return row
    end

    -- Rating columns with dynamic positioning — same order as headers
    local columnIndex = 0
    for _, bracket in ipairs(COMPACT_BRACKET_ORDER) do
        if PVPHUB_SETTINGS.compactMode.showRatings[bracket.key] then
            -- On a pinned-spec row, the per-spec brackets (Shuffle/Blitz) show
            -- THAT spec's rating specifically. 2v2/3v3/RBG aren't spec-specific
            -- to begin with, so they render exactly like the default row.
            local currentRating, isMultiSpec
            if pinnedSpecID and (bracket.key == "ratingShuffle" or bracket.key == "ratingBlitz") then
                local ratingTable = data[bracket.key]
                currentRating = (type(ratingTable) == "table" and ratingTable[pinnedSpecID]) or 0
                isMultiSpec = false -- explicit single spec, no ambiguity to flag
            else
                -- GetShuffleDisplayInfo handles flat numbers (2v2/3v3) and per-spec
                -- tables (Shuffle/Blitz) through the same code path.
                local _, specCount
                currentRating, _, specCount = GetShuffleDisplayInfo(data, charKey, bracket.key)
                isMultiSpec = (specCount > 1)
            end
            -- 2v2/3v3/RBG aren't spec-specific — on a sub-row they'd just repeat
            -- the exact same number already shown on the anchor row above, which
            -- reads as if it might differ per spec when it can't. Show a "same as
            -- above" placeholder there instead of the number itself (only when
            -- there's actually a value to point back to).
            local isCharacterWideBracket = bracket.key == "rating2v2" or bracket.key == "rating3v3" or bracket.key == "ratingRBG"
            local showAsDitto = isSubRow and isCharacterWideBracket and currentRating > 0

            local display
            if showAsDitto then
                display = "|cff666666^|r"
            else
                display = GetRatingColor(currentRating) .. (currentRating > 0 and currentRating or "-") .. "|r"
            end

            local text = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            local xPos = PVPHUB_CONSTANTS.COMPACT_WINDOW.BASE_WIDTH + (columnIndex * PVPHUB_CONSTANTS.COMPACT_WINDOW.COLUMN_WIDTH) - 5
            text:SetPoint("LEFT", xPos, 0)
            text:SetWidth(PVPHUB_CONSTANTS.COMPACT_WINDOW.COLUMN_WIDTH - 10) -- Set width for centering
            text:SetJustifyH("CENTER") -- Center the text
            text:SetText(display)
            SafeSetFont(text, PVPHUB.compactCurrentFontPath, 11)
            -- Add backdrop shadow for better readability
            text:SetShadowOffset(2, -2)
            text:SetShadowColor(0, 0, 0, 1)

            -- Add star icon for multi-spec ratings, positioned to the right of the centered rating
            if isMultiSpec then
                local starIcon = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
                starIcon:SetPoint("LEFT", xPos + (PVPHUB_CONSTANTS.COMPACT_WINDOW.COLUMN_WIDTH / 2) + 15, 0) -- Position to the right of center
                starIcon:SetText("|TInterface\\Common\\FavoritesIcon:12|t")
                SafeSetFont(starIcon, PVPHUB.compactCurrentFontPath, 11)
                starIcon:SetShadowOffset(2, -2)
                starIcon:SetShadowColor(0, 0, 0, 1)
            end

            columnIndex = columnIndex + 1

            do
                -- Create comprehensive tooltip for all ratings (copied from main window)
                local hoverBtn = CreateFrame("Button", nil, row)
                hoverBtn:SetPoint("LEFT", xPos, 0)
                hoverBtn:SetSize(PVPHUB_CONSTANTS.COMPACT_WINDOW.COLUMN_WIDTH - 10, PVPHUB_CONSTANTS.COMPACT_WINDOW.ROW_HEIGHT)
                hoverBtn:SetFrameLevel(row:GetFrameLevel() + 5)
                hoverBtn:SetScript("OnEnter", function()
                    hoverBG:Show()
                    -- Show tooltip for shuffle ratings
                    if bracket.key == "ratingShuffle" then
                        local shuffleData = data.ratingShuffle

                        if type(shuffleData) == "table" then
                            local specCount = 0
                            local specsWithRating = {}

                            -- Count specs with ratings > 0
                            for specID, ratingVal in pairs(shuffleData) do
                                if ratingVal > 0 then
                                    specCount = specCount + 1
                                    table.insert(specsWithRating, {specID = specID, rating = ratingVal})
                                end
                            end

                            -- Show tooltip if there are any specs with ratings > 0
                            if specCount > 0 then
                                ShowPVPHUBRatingTooltip(hoverBtn, charKey, "ratingShuffle", shuffleData)
                            end
                        elseif type(shuffleData) == "number" and shuffleData > 0 then
                            ShowPVPHUBRatingTooltip(hoverBtn, charKey, "ratingShuffle", shuffleData)
                        end
                    -- Show tooltip for blitz ratings
                    elseif bracket.key == "ratingBlitz" then
                        local blitzData = data.ratingBlitz
                        if type(blitzData) == "table" then
                            local specCount = 0
                            local specsWithRating = {}

                            -- Count specs with ratings > 0
                            for specID, ratingVal in pairs(blitzData) do
                                if ratingVal > 0 then
                                    specCount = specCount + 1
                                    table.insert(specsWithRating, {specID = specID, rating = ratingVal})
                                end
                            end

                            -- Show tooltip if there are any specs with ratings > 0
                            if specCount > 0 then
                                ShowPVPHUBRatingTooltip(hoverBtn, charKey, "ratingBlitz", blitzData)
                            end
                        elseif type(blitzData) == "number" and blitzData > 0 then
                            ShowPVPHUBRatingTooltip(hoverBtn, charKey, "ratingBlitz", blitzData)
                        end
                    -- Show tooltip for RBG rating with MMR
                    elseif bracket.key == "ratingRBG" then
                        local ratingVal = data.ratingRBG
                        if ratingVal and ratingVal > 0 then
                            ShowPVPHUBRatingTooltip(hoverBtn, charKey, "ratingRBG", ratingVal)
                        end
                    -- Show tooltip for 2v2 rating with MMR
                    elseif bracket.key == "rating2v2" then
                        local ratingVal = data.rating2v2
                        if ratingVal and ratingVal > 0 then
                            ShowPVPHUBRatingTooltip(hoverBtn, charKey, "rating2v2", ratingVal)
                        end
                    elseif bracket.key == "rating3v3" then
                        local ratingVal = data.rating3v3
                        if ratingVal and ratingVal > 0 then
                            ShowPVPHUBRatingTooltip(hoverBtn, charKey, "rating3v3", ratingVal)
                        end
                    end
                end)
                hoverBtn:SetScript("OnLeave", function()
                    hoverBG:Hide()
                    GameTooltip:Hide()
                    ClosePVPHUBRatingTooltip()
                end)
            end
        end
    end

    return row
end

function PVPHUB:ShowCompactSettings()
    PVPHUB:EnsureCompactModeDefaults()
    if PVPHUB.compactSettingsWindow and PVPHUB.compactSettingsWindow:IsShown() then
        PVPHUB.compactSettingsWindow:Hide()
        return
    end

    if not PVPHUB.compactSettingsWindow then
        local colors = UI_CONSTANTS.COLORS

        -- ── Low-level helpers (theme-aware) ─────────────────────────────────
        local function SK_Border(frame, c)
            c = c or colors.SETTINGS_BORDER
            local r, g, b, a = c[1], c[2], c[3], c[4] or 1
            local t = frame:CreateTexture(nil,"BORDER"); t:SetColorTexture(r,g,b,a)
            t:SetPoint("TOPLEFT"); t:SetPoint("TOPRIGHT"); t:SetHeight(1)
            local bot = frame:CreateTexture(nil,"BORDER"); bot:SetColorTexture(r,g,b,a)
            bot:SetPoint("BOTTOMLEFT"); bot:SetPoint("BOTTOMRIGHT"); bot:SetHeight(1)
            local l = frame:CreateTexture(nil,"BORDER"); l:SetColorTexture(r,g,b,a)
            l:SetPoint("TOPLEFT",0,-1); l:SetPoint("BOTTOMLEFT",0,1); l:SetWidth(1)
            local rr = frame:CreateTexture(nil,"BORDER"); rr:SetColorTexture(r,g,b,a)
            rr:SetPoint("TOPRIGHT",0,-1); rr:SetPoint("BOTTOMRIGHT",0,1); rr:SetWidth(1)
        end

        local function SK_Btn(parent, text, w, h)
            local b = CreateFrame("Button", nil, parent)
            b:SetSize(w or 100, h or 24)
            local bg = b:CreateTexture(nil,"BACKGROUND"); bg:SetAllPoints()
            local btnColor = colors.SCALE_BUTTON_BG
            bg:SetColorTexture(btnColor[1],btnColor[2],btnColor[3],1)
            local hl = b:CreateTexture(nil,"HIGHLIGHT"); hl:SetAllPoints()
            local accent = colors.ACCENT_LINE
            hl:SetColorTexture(accent[1],accent[2],accent[3],0.15)
            local lbl = b:CreateFontString(nil,"OVERLAY","GameFontHighlightSmall")
            lbl:SetAllPoints(); lbl:SetJustifyH("CENTER"); lbl:SetText(text)
            local pressColor = colors.WINDOW_BG
            b:SetScript("OnMouseDown", function() bg:SetColorTexture(pressColor[1],pressColor[2],pressColor[3],1) end)
            b:SetScript("OnMouseUp",   function() bg:SetColorTexture(btnColor[1],btnColor[2],btnColor[3],1) end)
            b:SetScript("OnLeave",     function() bg:SetColorTexture(btnColor[1],btnColor[2],btnColor[3],1) end)
            SK_Border(b)
            return b, lbl
        end

        local function SK_Check(parent, yAbs, text, onChange)
            local cb = CreateFrame("CheckButton", nil, parent)
            cb:SetSize(20, 20)
            cb:SetNormalTexture("Interface\\Buttons\\UI-CheckBox-Up")
            cb:SetPushedTexture("Interface\\Buttons\\UI-CheckBox-Down")
            cb:SetHighlightTexture("Interface\\Buttons\\UI-CheckBox-Highlight","ADD")
            cb:SetCheckedTexture("Interface\\Buttons\\UI-CheckBox-Check")
            cb:SetDisabledCheckedTexture("Interface\\Buttons\\UI-CheckBox-Check-Disabled")
            cb:SetPoint("TOPLEFT", parent, "TOPLEFT", 20, yAbs)
            cb:SetScript("OnClick", function(self) onChange(self:GetChecked() and true or false) end)
            local lbl = parent:CreateFontString(nil,"OVERLAY","GameFontHighlight")
            lbl:SetPoint("LEFT", cb, "RIGHT", 4, 0)
            lbl:SetText(text)
            cb.lbl = lbl
            return cb
        end

        -- ── Main window ─────────────────────────────────────────────────────
        -- Named uniquely per build (not a fixed "PVPHUBCompactSettings") so a
        -- theme change can safely tear down and rebuild this window — reusing
        -- the same global frame name on a second CreateFrame call is unreliable.
        PVPHUB._compactSettingsSeq = (PVPHUB._compactSettingsSeq or 0) + 1
        local frameName = "PVPHUBCompactSettings" .. PVPHUB._compactSettingsSeq
        local f = CreateFrame("Frame", frameName, UIParent)
        f:SetFrameStrata("DIALOG")
        f:SetSize(460, 560)
        f:SetPoint("CENTER")
        f:SetMovable(true)
        f:EnableMouse(true)
        f:RegisterForDrag("LeftButton")
        f:SetClampedToScreen(true)
        f:SetScript("OnDragStart", f.StartMoving)
        f:SetScript("OnDragStop",  f.StopMovingOrSizing)
        table.insert(UISpecialFrames, frameName)

        -- Theme-matched background/border
        local winBg = f:CreateTexture(nil,"BACKGROUND",nil,-1)
        winBg:SetAllPoints()
        local bgC = colors.SETTINGS_BG
        winBg:SetColorTexture(bgC[1], bgC[2], bgC[3], bgC[4] or 0.95)
        SK_Border(f)

        -- Accent stripe (3px) at the very top, themed
        local accentC = colors.ACCENT_LINE
        local accentTop = f:CreateTexture(nil,"BORDER",nil,1)
        accentTop:SetColorTexture(accentC[1], accentC[2], accentC[3], 1)
        accentTop:SetHeight(3); accentTop:SetPoint("TOPLEFT"); accentTop:SetPoint("TOPRIGHT")

        -- Title bar background (36 px) — slightly darker than the body
        local titleBg = f:CreateTexture(nil,"BACKGROUND",nil,0)
        titleBg:SetColorTexture(bgC[1]*0.75, bgC[2]*0.75, bgC[3]*0.75, 1)
        titleBg:SetHeight(36); titleBg:SetPoint("TOPLEFT"); titleBg:SetPoint("TOPRIGHT")

        -- Separator under title bar
        local borderC = colors.SETTINGS_BORDER
        local titleSep = f:CreateTexture(nil,"ARTWORK")
        titleSep:SetColorTexture(borderC[1], borderC[2], borderC[3], 1); titleSep:SetHeight(1)
        titleSep:SetPoint("TOPLEFT",f,"TOPLEFT",0,-36)
        titleSep:SetPoint("TOPRIGHT",f,"TOPRIGHT",0,-36)

        -- Icon + title text
        local titleIcon = f:CreateTexture(nil,"OVERLAY")
        titleIcon:SetTexture("Interface\\Icons\\Inv_misc_camera_02")
        titleIcon:SetSize(20,20); titleIcon:SetPoint("LEFT",f,"TOPLEFT",12,-20)

        -- The Class theme's TITLE_COLOR is r/g/b * 1.2 for extra vibrancy, which
        -- can exceed 1.0 — clamp before scaling to 0-255 or %02x produces a
        -- 3-digit component and corrupts the fixed-width |cAARRGGBB code.
        local function ToByte(v)
            return math.floor(math.max(0, math.min(1, v or 1)) * 255 + 0.5)
        end
        local titleColorC = colors.TITLE_COLOR
        local titleColorStr = string.format("ff%02x%02x%02x", ToByte(titleColorC[1]), ToByte(titleColorC[2]), ToByte(titleColorC[3]))
        local titleText = f:CreateFontString(nil,"OVERLAY","GameFontNormal")
        titleText:SetPoint("LEFT", titleIcon, "RIGHT", 7, 0)
        titleText:SetText("|c" .. titleColorStr .. "Streamer Mode|r  |cff555566— PVPHUB|r")

        -- Close button — same desaturated-silver style as the main window
        local closeBtn = CreateFrame("Button", nil, f, "UIPanelCloseButton")
        closeBtn:SetSize(26, 26)
        closeBtn:SetPoint("TOPRIGHT", f, "TOPRIGHT", -5, -5)
        closeBtn:SetFrameLevel(f:GetFrameLevel() + 5)
        do
            local _nt = closeBtn:GetNormalTexture()
            local _pt = closeBtn:GetPushedTexture()
            local _ht = closeBtn:GetHighlightTexture()
            _nt:SetDesaturated(true); _nt:SetVertexColor(0.82, 0.82, 0.88, 1)
            _pt:SetDesaturated(true); _pt:SetVertexColor(0.55, 0.55, 0.60, 1)
            _ht:SetDesaturated(true); _ht:SetVertexColor(1,    1,    1,    1)
        end
        closeBtn:SetScript("OnClick", function()
            if PVPHUB.compactWindow and PVPHUB.compactWindow:IsShown() then
                PVPHUB:UpdateCompactWindow()
            end
            if SaveSettings then SaveSettings() end
            f:Hide()
        end)

        -- ── Scrollable, collapsible card area ────────────────────────────────
        local footerHeight = 46
        local scrollFrame = CreateFrame("ScrollFrame", nil, f, "ScrollFrameTemplate")
        scrollFrame:SetPoint("TOPLEFT", f, "TOPLEFT", 4, -40)
        scrollFrame:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -25, footerHeight)
        ApplyModernScrollbarStyling(scrollFrame, colors)
        scrollFrame:EnableMouseWheel(true)
        scrollFrame:SetScript("OnMouseWheel", function(self, delta)
            local current = self:GetVerticalScroll()
            local maxScroll = self:GetVerticalScrollRange()
            self:SetVerticalScroll(math.max(0, math.min(current - (delta * 20), maxScroll)))
        end)

        local cardParent = CreateFrame("Frame", nil, scrollFrame)
        cardParent:SetSize(410, 400)
        scrollFrame:SetScrollChild(cardParent)
        scrollFrame:SetScript("OnSizeChanged", function(self, w)
            cardParent:SetWidth(w)
        end)

        if not PVPHUB_SETTINGS.compactSettingsSections then
            PVPHUB_SETTINGS.compactSettingsSections = {}
        end
        local cs = PVPHUB_SETTINGS.compactSettingsSections

        local allSections = {}
        local function RecalcPositions()
            local finalY = PVPHUB_RecalcCardPositions(cardParent, allSections, -8)
            cardParent:SetHeight(math.max(200, math.abs(finalY) + 10))
        end

        -- ── SECTION: Window Controls (toggle left | scale right) ────────────
        local sControls = PVPHUB_CreateCollapsibleCard(cardParent, cs, "windowControls", "WINDOW CONTROLS", {0.20, 0.45, 0.65}, "Interface\\Icons\\Trade_Engineering", RecalcPositions)
        table.insert(allSections, sControls)
        local wcContent = sControls.content

        local toggleBtn, toggleLbl = SK_Btn(wcContent, PVPHUB.compactWindow and PVPHUB.compactWindow:IsShown() and "Hide Streamer Window" or "Show Streamer Window", 190, 26)
        toggleBtn:SetPoint("TOPLEFT", wcContent, "TOPLEFT", 10, -12)
        local function RefreshToggleBtn()
            if PVPHUB.compactWindow and PVPHUB.compactWindow:IsShown() then
                toggleLbl:SetText("Hide Streamer Window")
            else
                toggleLbl:SetText("Show Streamer Window")
            end
        end
        if PVPHUB.compactWindow then
            PVPHUB.compactWindow.RefreshSettingsToggle = RefreshToggleBtn
        end
        toggleBtn:SetScript("OnClick", function()
            if PVPHUB.compactWindow and PVPHUB.compactWindow:IsShown() then
                PVPHUB_SETTINGS.compactWindowStayOpen = false
                PVPHUB.compactWindow:Hide()
            else
                PVPHUB:CreateCompactWindow()
                if PVPHUB.compactWindow then
                    PVPHUB.compactWindow.RefreshSettingsToggle = RefreshToggleBtn
                end
            end
            RefreshToggleBtn()
        end)

        PVPHUB_SETTINGS.compactWindowScale = math.max(1.0, math.min(2.0, PVPHUB_SETTINGS.compactWindowScale or 1.0))

        local scaleTitleLbl = wcContent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        scaleTitleLbl:SetPoint("TOPLEFT", wcContent, "TOPLEFT", 220, -8)
        scaleTitleLbl:SetText("SCALE")
        scaleTitleLbl:SetTextColor(unpack(colors.HEADER_COLOR))

        local scaleValLabel = wcContent:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        scaleValLabel:SetPoint("TOPLEFT", wcContent, "TOPLEFT", 340, -8)
        scaleValLabel:SetText(string.format("%d%%", PVPHUB_SETTINGS.compactWindowScale * 100))

        local scaleSlider = CreateFrame("Slider", "PVPHUBSettingsScaleSlider", wcContent, "MinimalSliderTemplate")
        scaleSlider:SetPoint("TOPLEFT", wcContent, "TOPLEFT", 220, -26)
        scaleSlider:SetSize(155, 12)
        scaleSlider:SetMinMaxValues(1.0, 2.0)
        scaleSlider:SetValueStep(0.01)
        scaleSlider:SetObeyStepOnDrag(true)
        scaleSlider:SetValue(PVPHUB_SETTINGS.compactWindowScale)
        scaleSlider:SetScript("OnValueChanged", function(self, val)
            if not val then return end
            PVPHUB_SETTINGS.compactWindowScale = val
            scaleValLabel:SetText(string.format("%d%%", val * 100))
            if PVPHUB.compactWindow then
                PVPHUB.compactWindow:SetScale(val)
                if PVPHUB.compactWindow.scaleSlider then
                    PVPHUB.compactWindow.scaleSlider:SetValue(val)
                end
                if PVPHUB.compactWindow.scaleLabel then
                    PVPHUB.compactWindow.scaleLabel:SetText(string.format("%d%%", val * 100))
                end
            end
        end)

        sControls.contentHeight = 56

        -- ── SECTION: Character Selection ─────────────────────────────────────
        local sChar = PVPHUB_CreateCollapsibleCard(cardParent, cs, "characterSelection", "CHARACTER SELECTION", {0.55, 0.30, 0.65}, "Interface\\Icons\\INV_Misc_GroupLooking", RecalcPositions)
        table.insert(allSections, sChar)
        local charSecContent = sChar.content

        local hideNoRatingCB = SK_Check(charSecContent, -10, "Hide No Rating", function(v)
            PVPHUB_SETTINGS.compactMode.hideNoRating = v
            if v then
                local sel = PVPHUB_SETTINGS.compactMode.selectedChars
                for i = #sel, 1, -1 do
                    if not compactHasAnyRating(PVPHUB_DB and PVPHUB_DB[sel[i]]) then
                        table.remove(sel, i)
                    end
                end
            end
            if f.RefreshCharacterList then f:RefreshCharacterList() end
            if PVPHUB.compactWindow and PVPHUB.UpdateCompactWindow then PVPHUB:UpdateCompactWindow() end
        end)
        hideNoRatingCB:SetChecked(PVPHUB_SETTINGS.compactMode.hideNoRating or false)
        hideNoRatingCB:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetText("Hide No Rating", 1, 1, 1)
            GameTooltip:AddLine("Remove characters with no rated activity from the selection list.", 0.7, 0.7, 0.7, true)
            GameTooltip:Show()
        end)
        hideNoRatingCB:SetScript("OnLeave", function() GameTooltip:Hide() end)
        f.hideNoRatingCheckbox = hideNoRatingCB

        f.charCheckboxes = {}
        local charScrollFrame = CreateFrame("ScrollFrame", nil, charSecContent, "ScrollFrameTemplate")
        charScrollFrame:SetPoint("TOPLEFT", charSecContent, "TOPLEFT", 10, -38)
        charScrollFrame:SetSize(376, 130)
        ApplyModernScrollbarStyling(charScrollFrame, colors)

        f.charContent = CreateFrame("Frame", nil, charScrollFrame)
        charScrollFrame:SetScrollChild(f.charContent)
        f.charContent:SetSize(360, 200)

        function f:RefreshCharacterList()
            MigratePinnedSpecsSchema()

            for _, cb in ipairs(self.charCheckboxes) do
                cb:Hide(); cb:SetParent(nil)
                if cb.lbl then cb.lbl:Hide(); cb.lbl:SetParent(nil) end
            end
            self.charCheckboxes = {}

            local currentChar = GetFullName()
            if currentChar and currentChar ~= "" then
                PVPHUB_DB[currentChar] = PVPHUB_DB[currentChar] or {}
                if not PVPHUB_DB[currentChar].class then
                    local _, class = UnitClass("player")
                    PVPHUB_DB[currentChar].class = class
                    PVPHUB_DB[currentChar].race   = select(2, UnitRace("player"))
                    PVPHUB_DB[currentChar].gender = UnitSex("player")
                end
            end

            local hideNoRating = PVPHUB_SETTINGS.compactMode.hideNoRating
            local charList = {}
            for charKey, data in pairs(PVPHUB_DB) do
                if type(data) == "table" and charKey ~= "" and not IsCharacterHidden(charKey) then
                    if not hideNoRating or compactHasAnyRating(data) then
                        table.insert(charList, charKey)
                    end
                end
            end
            table.sort(charList)

            -- Small top pad so the first row doesn't sit flush against the
            -- scrollframe's clip edge.
            local yPos = 4
            for charIndex, charKey in ipairs(charList) do
                local groupStartY = yPos
                local charData = PVPHUB_DB[charKey] or {}
                if charKey == currentChar then local _,cl = UnitClass("player"); charData.class = cl end
                local classColor = RAID_CLASS_COLORS[charData.class] or NORMAL_FONT_COLOR

                -- Settings can be opened without the compact window ever having
                -- refreshed, so run the same graduation check here too.
                PromoteToMultiSpecIfNeeded(charKey, charData)

                local function buildNameLabel(specIDForIcon)
                    local label = charKey
                    if specIDForIcon then
                        local _si = GetCachedSpecInfo(specIDForIcon)
                        if _si and _si.icon then label = "|T".._si.icon..":14|t "..label end
                    end
                    label = string.format("|c%s%s|r", classColor.colorStr or "ffffffff", label)
                    if charKey == currentChar then label = label .. " |TInterface\\Common\\Indicator-Green:12|t" end
                    return label
                end

                local isMultiSpec = GetDistinctRatedSpecCount(charData) >= 1

                if not isMultiSpec then
                    -- Unrated character: one checkbox controls the whole
                    -- combined row (every enabled bracket column at once),
                    -- tracking whatever spec is currently active. Once any
                    -- spec earns a rating, PromoteToMultiSpecIfNeeded moves
                    -- the character to individually pinnable spec rows below.
                    local cb = SK_Check(self.charContent, -yPos, "", function(v)
                        PVPHUB:ToggleCompactCharacter(charKey, v)
                    end)
                    cb:SetSize(20,20); cb:SetPoint("TOPLEFT", self.charContent, "TOPLEFT", 4, -yPos)
                    cb:Show()
                    cb.lbl:SetText(buildNameLabel(charData.specID))

                    local isSelected = false
                    for _, sel in ipairs(PVPHUB_SETTINGS.compactMode.selectedChars) do
                        if sel == charKey then isSelected = true; break end
                    end
                    cb:SetChecked(isSelected)

                    table.insert(self.charCheckboxes, cb)
                    yPos = yPos + 24
                else
                    -- Multi-spec character: the name is a plain header — there's
                    -- no single "current spec" row anymore, so visibility is
                    -- controlled entirely by which spec rows below are ticked.
                    local header = self.charContent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
                    header:SetPoint("TOPLEFT", self.charContent, "TOPLEFT", 6, -yPos - 4)
                    header:SetText(buildNameLabel(nil))
                    table.insert(self.charCheckboxes, header)
                    yPos = yPos + 20

                    -- One checkbox per distinct spec that has ever earned a
                    -- rating (in either Shuffle or Blitz), including whichever
                    -- spec is currently active — every row is equally tickable.
                    -- Ticking one shows that spec across every enabled bracket
                    -- column, so there's no need to split by bracket here.
                    local specCandidates = {}
                    local bestRatingBySpec = {}
                    for _, bracketKey in ipairs({"ratingShuffle", "ratingBlitz"}) do
                        local bracketData = charData[bracketKey]
                        if type(bracketData) == "table" then
                            for specID, rating in pairs(bracketData) do
                                if rating and rating > 0 then
                                    if not bestRatingBySpec[specID] then
                                        local entry = { specID = specID, bestRating = rating }
                                        bestRatingBySpec[specID] = entry
                                        table.insert(specCandidates, entry)
                                    elseif rating > bestRatingBySpec[specID].bestRating then
                                        bestRatingBySpec[specID].bestRating = rating
                                    end
                                end
                            end
                        end
                    end
                    table.sort(specCandidates, function(a, b) return a.bestRating > b.bestRating end)

                    local currentSpecID = charData.specID or charData.lastActiveSpecID
                    local connectorTop = yPos
                    for _, cand in ipairs(specCandidates) do
                        local specIcon, specName = "", "Spec"
                        local _si = GetCachedSpecInfo(cand.specID)
                        if _si then
                            if _si.icon then specIcon = "|T" .. _si.icon .. ":12|t " end
                            specName = _si.name or specName
                        end

                        local pinCb = SK_Check(self.charContent, -yPos, "", function(v)
                            local pins = PVPHUB_SETTINGS.compactMode.pinnedSpecs
                            pins[charKey] = pins[charKey] or {}
                            pins[charKey][cand.specID] = v or nil
                            if PVPHUB.compactWindow and PVPHUB.compactWindow:IsShown() then
                                PVPHUB:UpdateCompactWindow()
                            end
                        end)
                        pinCb:SetSize(18, 18)
                        pinCb:ClearAllPoints()
                        pinCb:SetPoint("TOPLEFT", self.charContent, "TOPLEFT", 30, -yPos)
                        pinCb:Show()
                        -- No rating number or bracket name — one checkbox = one
                        -- spec, and it shows every enabled bracket column, so
                        -- there's nothing bracket-specific left to disambiguate.
                        local currentTag = (cand.specID == currentSpecID) and " |TInterface\\Common\\Indicator-Green:10|t" or ""
                        pinCb.lbl:SetText(string.format("%s%s%s", specIcon, specName, currentTag))
                        pinCb.lbl:SetFontObject("GameFontHighlightSmall")

                        local pinned = PVPHUB_SETTINGS.compactMode.pinnedSpecs[charKey]
                        local isPinned = pinned and pinned[cand.specID]
                        pinCb:SetChecked(isPinned and true or false)

                        table.insert(self.charCheckboxes, pinCb)
                        yPos = yPos + 20
                    end

                    if #specCandidates > 0 then
                        -- Connector stripe ties the spec rows visually back to
                        -- their character, in the character's class color.
                        local connector = self.charContent:CreateTexture(nil, "ARTWORK")
                        connector:SetTexture("Interface\\Buttons\\WHITE8x8")
                        connector:SetVertexColor(classColor.r or 1, classColor.g or 1, classColor.b or 1, 0.55)
                        connector:SetWidth(2)
                        connector:SetPoint("TOPLEFT",    self.charContent, "TOPLEFT", 13, -connectorTop + 2)
                        connector:SetPoint("BOTTOMLEFT", self.charContent, "TOPLEFT", 13, -yPos + 10)
                        table.insert(self.charCheckboxes, connector)
                    end
                end

                -- Alternating background band behind the whole character group
                -- (checkbox row + any pinned-spec rows) so adjacent characters
                -- read as distinct blocks instead of one blurred list.
                if charIndex % 2 == 0 then
                    local band = self.charContent:CreateTexture(nil, "BACKGROUND")
                    band:SetTexture("Interface\\Buttons\\WHITE8x8")
                    local bandColor = UI_CONSTANTS.COLORS.ALTERNATING_ROW_BG or {0.15, 0.2, 0.3, 0.35}
                    band:SetVertexColor(bandColor[1], bandColor[2], bandColor[3], bandColor[4] or 0.35)
                    band:SetPoint("TOPLEFT",  self.charContent, "TOPLEFT",  -4, -groupStartY + 3)
                    band:SetPoint("TOPRIGHT", self.charContent, "TOPRIGHT",  4, -groupStartY + 3)
                    band:SetHeight(yPos - groupStartY)
                    table.insert(self.charCheckboxes, band)
                end

                yPos = yPos + 6 -- gap between character groups
            end
            self.charContent:SetHeight(math.max(110, yPos))

            if #charList == 0 then
                if not self.noCharsLabel then
                    self.noCharsLabel = self.charContent:CreateFontString(nil,"OVERLAY","GameFontNormalSmall")
                    self.noCharsLabel:SetPoint("TOPLEFT",10,-10); self.noCharsLabel:SetWidth(340)
                    self.noCharsLabel:SetJustifyH("LEFT"); self.noCharsLabel:SetTextColor(0.6,0.6,0.6,1)
                end
                self.noCharsLabel:SetText("No characters found. Log in with each character and open PVPHUB.")
                self.noCharsLabel:Show()
            elseif self.noCharsLabel then
                self.noCharsLabel:Hide()
            end
        end
        f:RefreshCharacterList()

        sChar.contentHeight = 178

        -- ── SECTION: PvP Brackets ─────────────────────────────────────────────
        local sBrackets = PVPHUB_CreateCollapsibleCard(cardParent, cs, "pvpBrackets", "PVP BRACKETS", {0.65, 0.20, 0.20}, "Interface\\Icons\\achievement_pvp_a_15", RecalcPositions)
        table.insert(allSections, sBrackets)
        local bracketsContent = sBrackets.content

        local ratingData = {
            { key = "rating2v2",     name = "2v2 Arena",    icon = "Interface\\Icons\\achievement_arena_2v2_1" },
            { key = "rating3v3",     name = "3v3 Arena",    icon = "Interface\\Icons\\achievement_arena_3v3_1" },
            { key = "ratingShuffle", name = "Solo Shuffle",  icon = "Interface\\Icons\\ability_dualwield" },
            { key = "ratingBlitz",   name = "Blitz",         icon = "Interface\\Icons\\achievement_bg_killxenemies_generalsroom" },
            { key = "ratingRBG",     name = "Rated BG",      icon = "Interface\\Icons\\achievement_pvp_a_15" },
        }

        f.ratingCheckboxes = {}
        local bY = -10
        local bX = { 10, 190 }
        for i, bracket in ipairs(ratingData) do
            local col = (i % 2 == 0) and 1 or 0
            local row = math.floor((i - 1) / 2)
            local cb = SK_Check(bracketsContent, bY - row * 28, "|T"..bracket.icon..":14|t "..bracket.name, function(v)
                PVPHUB:ToggleCompactRating(bracket.key, v)
            end)
            cb:SetPoint("TOPLEFT", bracketsContent, "TOPLEFT", bX[col + 1], bY - row * 28)
            cb:SetChecked(PVPHUB_SETTINGS.compactMode.showRatings[bracket.key])
            cb.bracketKey = bracket.key
            table.insert(f.ratingCheckboxes, cb)
        end

        sBrackets.contentHeight = 104

        -- ── SECTION: Display Options ──────────────────────────────────────────
        local sDisplay = PVPHUB_CreateCollapsibleCard(cardParent, cs, "displayOptions", "DISPLAY OPTIONS", {0.20, 0.55, 0.25}, "Interface\\Icons\\Ability_Hunter_EagleEye", RecalcPositions)
        table.insert(allSections, sDisplay)
        local displayContent = sDisplay.content

        local displayOptions = {
            { key = "hideBackground",  label = "Hide Background",   tip = "Remove the window backdrop for a transparent overlay." },
            { key = "hideInPvP",       label = "Auto-hide in PvP",  tip = "Hide the window automatically during arena/BG matches." },
            { key = "hideServerNames", label = "Hide Server Names", tip = "Show character names without the realm suffix." },
        }
        local doCBs = {}
        local dY = -10
        for _, opt in ipairs(displayOptions) do
            local cb = SK_Check(displayContent, dY, opt.label, function(v)
                PVPHUB_SETTINGS.compactMode[opt.key] = v
                if opt.key == "hideBackground" then
                    if PVPHUB.compactWindow then
                        if v then
                            PVPHUB.compactWindow:SetBackdrop(nil)
                        else
                            PVPHUB.compactWindow:SetBackdrop({bgFile="Interface\\Buttons\\WHITE8x8",edgeFile="Interface\\Buttons\\WHITE8x8",tile=false,edgeSize=1,insets={left=1,right=1,top=1,bottom=1}})
                            local c = PVPHUB_SETTINGS.compactMode.backgroundColor or {unpack(UI_CONSTANTS.COLORS.COMPACT_BG)}
                            PVPHUB.compactWindow:SetBackdropColor(c[1],c[2],c[3],c[4] or 0.8)
                            PVPHUB.compactWindow:SetBackdropBorderColor(0, 0, 0, 0)
                        end
                    end
                elseif opt.key == "hideInPvP" then
                    C_Timer.After(0.1, function()
                        if v and IsInActivePvP() and PVPHUB.compactWindow and PVPHUB.compactWindow:IsShown() then
                            PVPHUB._compactWindowWasOpenBeforePvP = true
                            PVPHUB.compactWindow:Hide()
                        elseif not v and PVPHUB._compactWindowWasOpenBeforePvP then
                            PVPHUB:CreateCompactWindow()
                        end
                    end)
                elseif opt.key == "hideServerNames" then
                    if PVPHUB.compactWindow and PVPHUB.UpdateCompactWindow then PVPHUB:UpdateCompactWindow() end
                end
            end)
            cb:SetChecked(PVPHUB_SETTINGS.compactMode[opt.key] or false)
            doCBs[opt.key] = cb
            cb:SetScript("OnEnter", function(self)
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                GameTooltip:SetText(opt.label, 1, 1, 1)
                GameTooltip:AddLine(opt.tip, 0.7, 0.7, 0.7, true)
                GameTooltip:Show()
            end)
            cb:SetScript("OnLeave", function() GameTooltip:Hide() end)
            dY = dY - 26
        end
        f.hideBGCheckbox          = doCBs["hideBackground"]
        f.hideInPvPCheckbox       = doCBs["hideInPvP"]
        f.hideServerNamesCheckbox = doCBs["hideServerNames"]

        sDisplay.contentHeight = 92

        -- ── SECTION: Background Color ─────────────────────────────────────────
        local sBgColor = PVPHUB_CreateCollapsibleCard(cardParent, cs, "backgroundColor", "BACKGROUND COLOR", {0.65, 0.50, 0.10}, "Interface\\Icons\\trade_engineering", RecalcPositions)
        table.insert(allSections, sBgColor)
        local bgColorContent = sBgColor.content

        if not PVPHUB_SETTINGS.compactMode.backgroundColor then
            PVPHUB_SETTINGS.compactMode.backgroundColor = {0.1, 0.1, 0.1, 0.8}
        end

        local swatchFrame = CreateFrame("Frame", nil, bgColorContent)
        swatchFrame:SetSize(20, 20)
        swatchFrame:SetPoint("TOPLEFT", bgColorContent, "TOPLEFT", 10, -14)
        local colorSwatch = swatchFrame:CreateTexture(nil, "ARTWORK")
        colorSwatch:SetAllPoints()
        colorSwatch:SetTexture("Interface\\Buttons\\WHITE8x8")
        local function RefreshSwatch()
            local c = PVPHUB_SETTINGS.compactMode.backgroundColor
            colorSwatch:SetVertexColor(c[1],c[2],c[3],c[4])
        end
        RefreshSwatch()
        SK_Border(swatchFrame)

        local colorBtn, _ = SK_Btn(bgColorContent, "Pick Color", 100, 24)
        colorBtn:SetPoint("TOPLEFT", bgColorContent, "TOPLEFT", 38, -12)
        colorBtn:SetScript("OnClick", function()
            local c = PVPHUB_SETTINGS.compactMode.backgroundColor
            local function swatchFunc()
                local r,g,b = ColorPickerFrame:GetColorRGB()
                local a = ColorPickerFrame:GetColorAlpha()
                PVPHUB_SETTINGS.compactMode.backgroundColor = {r,g,b,a}
                RefreshSwatch()
                if PVPHUB.compactWindow and not PVPHUB_SETTINGS.compactMode.hideBackground then
                    PVPHUB.compactWindow:SetBackdropColor(r,g,b,a)
                end
                if SaveSettings then SaveSettings() end
            end
            local function cancelFunc(prev)
                if prev then
                    PVPHUB_SETTINGS.compactMode.backgroundColor = {prev.r,prev.g,prev.b,prev.a}
                    RefreshSwatch()
                    if PVPHUB.compactWindow and not PVPHUB_SETTINGS.compactMode.hideBackground then
                        PVPHUB.compactWindow:SetBackdropColor(prev.r,prev.g,prev.b,prev.a)
                    end
                    if SaveSettings then SaveSettings() end
                end
            end
            ColorPickerFrame:SetupColorPickerAndShow({
                swatchFunc = swatchFunc, cancelFunc = cancelFunc,
                hasOpacity = true, opacity = c[4],
                r = c[1], g = c[2], b = c[3],
            })
        end)
        f.UpdateColorButtonAppearance = RefreshSwatch

        sBgColor.contentHeight = 46

        -- ── SECTION: Compact Window Font ──────────────────────────────────────
        local sFont = PVPHUB_CreateCollapsibleCard(cardParent, cs, "compactFont", "COMPACT WINDOW FONT", {0.35, 0.75, 0.75}, "Interface\\Icons\\INV_Misc_Note_04", RecalcPositions)
        table.insert(allSections, sFont)
        local fontContent = sFont.content

        if not PVPHUB_SETTINGS.compactMode.selectedFont then
            PVPHUB_SETTINGS.compactMode.selectedFont = "Friz Quadrata TT"
        end

        local builtInFonts = {
            ["Friz Quadrata TT"] = "Fonts\\FRIZQT__.TTF",
            ["Arial Narrow"]     = "Fonts\\ARIALN.TTF",
            ["Morpheus"]         = "Fonts\\MORPHEUS.TTF",
            ["Skurri"]           = "Fonts\\skurri.ttf",
        }

        -- Resolve a font name to its file path via built-in table then LSM.
        -- Uses LSM:HashTable (raw path table) instead of LSM:Fetch so that
        -- global overrides from font-manager addons (e.g. Fontmancer) don't
        -- hijack the lookup and return the wrong font.
        local function ResolveFontPath(name)
            local path = builtInFonts[name]
            if not path and LibStub then
                local LSM = LibStub("LibSharedMedia-3.0", true)
                if LSM and LSM.HashTable then
                    local fontTable = LSM:HashTable("font")
                    if fontTable then path = fontTable[name] end
                end
            end
            return path or nil
        end

        local function ApplyCompactFontChanges()
            local sel = PVPHUB_SETTINGS.compactMode.selectedFont
            PVPHUB.compactCurrentFontPath = ResolveFontPath(sel) or FALLBACK_FONT
            if PVPHUB.compactWindow and PVPHUB.compactWindow:IsShown() and PVPHUB.UpdateCompactWindow then
                PVPHUB:UpdateCompactWindow()
            end
        end

        -- Build font list — only include fonts whose paths WoW can actually load.
        -- "Friends" (FRIENDS.TTF) was removed from WoW's game files; the validation
        -- would catch it anyway, but skip it here to avoid generating the error at all.
        local availableFonts = {}
        for _, name in ipairs({"Friz Quadrata TT","Arial Narrow","Morpheus","Skurri"}) do
            if ResolveFontPath(name) then table.insert(availableFonts, name) end
        end
        if LibStub then
            local LSM = LibStub("LibSharedMedia-3.0", true)
            if LSM then
                for _, fn in ipairs(LSM:List("font") or {}) do
                    local found = false
                    for _, ex in ipairs(availableFonts) do if ex == fn then found = true; break end end
                    if not found and ResolveFontPath(fn) then
                        table.insert(availableFonts, fn)
                    end
                end
            end
        end
        table.sort(availableFonts)

        local fontDropBtn = PVPHUB_CreateFontPicker(fontContent, fontContent, "TOPLEFT", -15, -10, 220,
            function() return PVPHUB_SETTINGS.compactMode.selectedFont end,
            function(v)
                PVPHUB_SETTINGS.compactMode.selectedFont = v
                ApplyCompactFontChanges()
                PVPHubPrint("|cffff0000[PVPHUB]|r Font changed to " .. v)
            end,
            function() return availableFonts end)
        ApplyModernDropdownStyling(fontDropBtn)
        f.compactFontDropdown = fontDropBtn
        ApplyCompactFontChanges()

        sFont.contentHeight = 46

        -- ── Footer buttons (fixed, outside the scroll area) ──────────────────
        local footerSep = f:CreateTexture(nil, "ARTWORK")
        footerSep:SetColorTexture(borderC[1], borderC[2], borderC[3], 1); footerSep:SetHeight(1)
        footerSep:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 0, footerHeight)
        footerSep:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", 0, footerHeight)

        local openMainBtn, _ = SK_Btn(f, "Open Main Window", 140, 26)
        openMainBtn:SetPoint("BOTTOM", f, "BOTTOM", -44, 12)
        openMainBtn:SetScript("OnClick", function()
            SlashCmdList["PVPHUB"]("")
        end)
        openMainBtn:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_TOP")
            GameTooltip:SetText("Open Main Window", 1, 1, 1)
            GameTooltip:AddLine("Opens the main PVPHUB character list.", 0.7, 0.7, 0.7, true)
            GameTooltip:Show()
        end)
        openMainBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

        local closeFooterBtn, _ = SK_Btn(f, "Close", 80, 26)
        closeFooterBtn:SetPoint("LEFT", openMainBtn, "RIGHT", 8, 0)
        closeFooterBtn:SetScript("OnClick", function() f:Hide() end)

        RecalcPositions()

        PVPHUB.compactSettingsWindow = f
    end

    -- Sync live values every time the window opens
    local w = PVPHUB.compactSettingsWindow
    w:RefreshCharacterList()
    for _, cb in ipairs(w.ratingCheckboxes or {}) do
        if cb.bracketKey then cb:SetChecked(PVPHUB_SETTINGS.compactMode.showRatings[cb.bracketKey]) end
    end
    if w.UpdateColorButtonAppearance then w.UpdateColorButtonAppearance() end

    PVPHUB.compactSettingsWindow:Show()
end

-- Called from ApplyTheme() (PVPHUB_core.lua) whenever the color theme
-- changes, so the streamer overlay and its settings window pick up the new
-- theme immediately instead of needing a /reload.
function PVPHUB:RefreshCompactTheme()
    -- The overlay already re-reads UI_CONSTANTS.COLORS.COMPACT_BG and rebuilds
    -- its rows on every call, so just re-running the normal update is enough.
    if PVPHUB.compactWindow then
        PVPHUB:UpdateCompactWindow()
    end

    -- The settings window bakes its colors into textures/strings once at
    -- build time, so there's no cheap way to retint it in place. Tear the
    -- cached frame down and, if it was open, rebuild it immediately so it
    -- reopens already re-themed.
    if PVPHUB.compactSettingsWindow then
        local wasShown = PVPHUB.compactSettingsWindow:IsShown()
        -- Preserve wherever the user dragged it to — rebuilding is a fresh
        -- CreateFrame call that would otherwise snap back to the default
        -- SetPoint("CENTER") every time the theme changes.
        local point, relativeTo, relativePoint, xOfs, yOfs = PVPHUB.compactSettingsWindow:GetPoint(1)
        local name = PVPHUB.compactSettingsWindow:GetName()
        if name then
            for i = #UISpecialFrames, 1, -1 do
                if UISpecialFrames[i] == name then
                    table.remove(UISpecialFrames, i)
                    break
                end
            end
        end
        PVPHUB.compactSettingsWindow:Hide()
        PVPHUB.compactSettingsWindow:SetParent(nil)
        PVPHUB.compactSettingsWindow = nil
        if wasShown then
            PVPHUB:ShowCompactSettings()
            if point and PVPHUB.compactSettingsWindow then
                PVPHUB.compactSettingsWindow:ClearAllPoints()
                PVPHUB.compactSettingsWindow:SetPoint(point, relativeTo, relativePoint, xOfs, yOfs)
            end
        end
    end
end

function PVPHUB:ToggleCompactCharacter(charKey, enabled)
    if enabled then
        -- Add character if not already in list
        local found = false
        for _, selected in ipairs(PVPHUB_SETTINGS.compactMode.selectedChars) do
            if selected == charKey then
                found = true
                break
            end
        end
        if not found then
            table.insert(PVPHUB_SETTINGS.compactMode.selectedChars, charKey)
        end
    else
        -- Remove character from list
        for i, selected in ipairs(PVPHUB_SETTINGS.compactMode.selectedChars) do
            if selected == charKey then
                table.remove(PVPHUB_SETTINGS.compactMode.selectedChars, i)
                break
            end
        end
    end
    
    -- Update compact window if it's open
    if PVPHUB.compactWindow and PVPHUB.compactWindow:IsShown() then
        PVPHUB:UpdateCompactWindow()
    end
end

function PVPHUB:ToggleCompactRating(bracketKey, enabled)
    PVPHUB_SETTINGS.compactMode.showRatings[bracketKey] = enabled
    
    -- Update compact window if it's open
    if PVPHUB.compactWindow and PVPHUB.compactWindow:IsShown() then
        PVPHUB:UpdateCompactWindow()
    end
end
