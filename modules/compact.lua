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

-- Season-aware: last season's numbers are kept in the DB (they are no longer
-- deleted on a season change — see IsSeasonDataCurrent in core.lua), so this
-- filter has to ignore them explicitly rather than assume anything present is
-- current.
local function compactHasAnyRating(data)
    if not data then return false end
    if PVPHUB._IsSeasonDataCurrent and not PVPHUB._IsSeasonDataCurrent(data) then
        return false
    end
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

-- Pins the spec a character shown as a plain row was showing: its active
-- spec if that's rated; otherwise whichever spec has the best rating, so a
-- character caught mid-respec (active spec rated 0, like Elemental right
-- after swapping off a rated Restoration) doesn't just vanish from the
-- display until the user manually re-pins it.
local function PinShownSpec(charKey, data)
    local currentSpecID = data.specID or data.lastActiveSpecID
    local specToSeed = CharacterHasRatingForSpec(data, currentSpecID) and currentSpecID or GetBestRatedSpec(data)
    if specToSeed then
        local cm = PVPHUB_SETTINGS.compactMode
        cm.pinnedSpecs = cm.pinnedSpecs or {}
        cm.pinnedSpecs[charKey] = cm.pinnedSpecs[charKey] or {}
        cm.pinnedSpecs[charKey][specToSeed] = true
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
        PinShownSpec(charKey, data)
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

-- --------------------------------------------------------------------------
-- Skins (7.0)
-- --------------------------------------------------------------------------
-- The overlay's look, chosen in its settings (Display Options): a rounded
-- panel in the background color, see-through with a light border, with a
-- border in the theme's color, or no background at all (outlined text
-- straight on the game, e.g. for capture setups). compactMode.hideBackground
-- stays in step with "none", so 6.x shows the overlay the same way and a
-- change made there carries over.
local SKINS = {
    { key = "solid", label = "Solid", tip = "A rounded panel in your background color." },
    { key = "glass", label = "Glass", tip = "A see-through panel with a light border." },
    { key = "theme", label = "Theme", tip = "A rounded panel with a border in your theme's color." },
    { key = "none",  label = "None",  tip = "No background: outlined text straight on the game." },
    { key = "minimal", label = "Minimal", tip = "One pill per spec, stacked: its best Solo Shuffle or Blitz rating and ladder rank, no names." },
}
local PANEL_CORNER = 8

local function CompactSkin()
    local cm = PVPHUB_SETTINGS.compactMode
    if cm.hideBackground then
        cm.skin = "none"
    elseif cm.skin == nil or cm.skin == "none" then
        cm.skin = "solid"
    end
    return cm.skin
end

local function SetCompactSkin(skin)
    local cm = PVPHUB_SETTINGS.compactMode
    cm.skin = skin
    cm.hideBackground = (skin == "none")
end

-- Colors a panel and its outline (UI.CreatePanel "fill" and "ring") for
-- the skin: the overlay's own, and the settings' live preview of it
local function PaintSkinPanel(fill, ring)
    local skin = CompactSkin()
    local c = PVPHUB_SETTINGS.compactMode.backgroundColor or UI_CONSTANTS.COLORS.COMPACT_BG
    local alpha = c[4] or 0.8
    -- Minimal has no panel: each of its pills has its own (PaintSpecPill)
    fill:SetShown(skin ~= "none" and skin ~= "minimal")
    fill:SetVertexColor(c[1], c[2], c[3], skin == "glass" and alpha * 0.55 or alpha)
    ring:SetShown(skin == "glass" or skin == "theme")
    if skin == "theme" then
        local t = PVPHUB.UI.ThemeColor()
        ring:SetVertexColor(t[1], t[2], t[3], 0.7)
    else
        ring:SetVertexColor(1, 1, 1, 0.18)
    end
end

-- Builds the overlay's panel on first use and colors it for the skin
local function PaintCompactShell()
    local cw = PVPHUB.compactWindow
    if not cw then return end
    if not cw.shellFill then
        cw:SetBackdrop(nil)
        cw.shellFill = PVPHUB.UI.CreatePanel(cw, "fill", "BACKGROUND", -1, PANEL_CORNER)
        cw.shellRing = PVPHUB.UI.CreatePanel(cw, "ring", "BORDER", 0, PANEL_CORNER)
    end
    PaintSkinPanel(cw.shellFill, cw.shellRing)
end

-- The overlay's text: outlined without a background, a soft shadow on one
local function StyleCompactText(fs, size)
    local bare = CompactSkin() == "none"
    SafeSetFont(fs, PVPHUB.compactCurrentFontPath, size, bare and "OUTLINE" or "")
    fs:SetShadowOffset(1, -1)
    fs:SetShadowColor(0, 0, 0, bare and 1 or 0.7)
end

-- --------------------------------------------------------------------------
-- Minimal skin
-- --------------------------------------------------------------------------
-- One pill per spec on the overlay, stacked: the spec's icon and its
-- highest rating in Solo Shuffle or Blitz (the brackets rated per spec),
-- with its ladder rank when the game reported one ("#207 - 2536"), the
-- border in the rating's color. No names. Uses the Shuffle/Blitz columns
-- that are switched on, both when neither is.
local SPEC_PILL_H, SPEC_PILL_GAP, SPEC_PILL_ICON = 34, 6, 24
local PORTRAIT_MASK = "Interface\\CharacterFrame\\TempPortraitAlphaMask"

local function RatingRGB(rating)
    local r, g, b = GetRatingColor(rating):match("|c%x%x(%x%x)(%x%x)(%x%x)")
    if not r then return 1, 1, 1 end
    return tonumber(r, 16) / 255, tonumber(g, 16) / 255, tonumber(b, 16) / 255
end

-- One item per spec row of the overlay (entries: { char, data,
-- pinnedSpecID }) that has a rating, best first
local function SpecPillItems(entries)
    local showRatings = PVPHUB_SETTINGS.compactMode.showRatings
    local brackets = {}
    for _, key in ipairs({ "ratingShuffle", "ratingBlitz" }) do
        if showRatings[key] then brackets[#brackets + 1] = key end
    end
    if #brackets == 0 then brackets = { "ratingShuffle", "ratingBlitz" } end

    local items = {}
    for _, entry in ipairs(entries) do
        local data = entry.data
        local specID = entry.pinnedSpecID or data.specID or data.lastActiveSpecID
        local current = not PVPHUB._IsSeasonDataCurrent or PVPHUB._IsSeasonDataCurrent(data)
        local best, bestKey = 0, nil
        for _, key in ipairs(brackets) do
            local ratings = data[key]
            local rating = current and specID and type(ratings) == "table" and ratings[specID] or 0
            if rating > best then best, bestKey = rating, key end
        end
        if best > 0 then
            items[#items + 1] = { charKey = entry.char, data = data, specID = specID, rating = best, bracketKey = bestKey }
        end
    end
    table.sort(items, function(a, b) return a.rating > b.rating end)
    return items
end

local function CreateSpecPill(parent)
    local UI = PVPHUB.UI
    local p = CreateFrame("Button", nil, parent)
    p:SetHeight(SPEC_PILL_H)
    p.fill = UI.CreatePanel(p, "fill", "BACKGROUND", 0, SPEC_PILL_H / 2)
    p.ring = UI.CreatePanel(p, "ring", "BORDER", 0, SPEC_PILL_H / 2)
    p.icon = p:CreateTexture(nil, "ARTWORK")
    p.icon:SetSize(SPEC_PILL_ICON, SPEC_PILL_ICON)
    p.icon:SetPoint("LEFT", p, "LEFT", 6, 0)
    local mask = p:CreateMaskTexture()
    mask:SetTexture(PORTRAIT_MASK, "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
    mask:SetAllPoints(p.icon)
    p.icon:AddMaskTexture(mask)
    p.text = p:CreateFontString(nil, "OVERLAY")
    p.text:SetFont(FALLBACK_FONT, 14, "")
    p.text:SetPoint("LEFT", p.icon, "RIGHT", 8, 0)
    return p
end

-- Paints a pill for one item; returns the width its text needs
local function PaintSpecPill(p, item)
    local c = PVPHUB_SETTINGS.compactMode.backgroundColor or UI_CONSTANTS.COLORS.COMPACT_BG
    p.fill:SetVertexColor(c[1], c[2], c[3], c[4] or 0.8)
    local r, g, b = RatingRGB(item.rating)
    p.ring:SetVertexColor(r, g, b, 1)
    local info = GetCachedSpecInfo(item.specID)
    p.icon:SetTexture(info and info.icon or "Interface\\Icons\\INV_Misc_QuestionMark")
    StyleCompactText(p.text, 14)
    local rank = PVPHUB.GetLadderRank and PVPHUB.GetLadderRank(item.charKey, item.bracketKey, item.specID)
    p.text:SetText(rank and string.format("#%s - %d", BreakUpLargeNumbers(rank), item.rating) or tostring(item.rating))
    p.text:SetTextColor(r, g, b)
    p.charKey, p.bracketKey, p.data = item.charKey, item.bracketKey, item.data
    return p.text:GetStringWidth()
end

-- Stacks a pill per item down from parent's top left, all as wide as the
-- widest; returns the stack's width and height
local function LayoutSpecPills(parent, pool, items)
    local textW = 0
    for i, item in ipairs(items) do
        pool[i] = pool[i] or CreateSpecPill(parent)
        textW = math.max(textW, PaintSpecPill(pool[i], item))
    end
    -- GetStringWidth comes out a little short on scaled frames: some slack
    local width = 6 + SPEC_PILL_ICON + 8 + math.ceil(textW * 1.1) + 14
    for i, p in ipairs(pool) do
        p:SetShown(items[i] ~= nil)
        if items[i] then
            p:ClearAllPoints()
            p:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, -(i - 1) * (SPEC_PILL_H + SPEC_PILL_GAP))
            p:SetWidth(width)
        end
    end
    return width, math.max(0, #items * (SPEC_PILL_H + SPEC_PILL_GAP) - SPEC_PILL_GAP)
end

-- Keeps the floating toolbar on screen: under the overlay's left edge, or
-- its right edge when it would run off the right side of the screen (it's
-- wider than the Minimal skin's overlay), and above the overlay when
-- there's no room below. The overlay itself is clamped to the screen.
local TOOLBAR_GAP = 4

local function PlaceToolbar()
    local cw = PVPHUB.compactWindow
    local tb = cw and cw.toolbar
    local left, bottom = cw and cw:GetLeft(), cw and cw:GetBottom()
    if not (tb and left and bottom) then return end
    -- The screen's width in the overlay's own (scaled) units
    local screenW = UIParent:GetWidth() * UIParent:GetEffectiveScale() / cw:GetEffectiveScale()
    local side = (left + tb:GetWidth() > screenW) and "RIGHT" or "LEFT"
    tb:ClearAllPoints()
    if bottom - TOOLBAR_GAP - tb:GetHeight() >= 0 then
        tb:SetPoint("TOP" .. side, cw, "BOTTOM" .. side, 0, -TOOLBAR_GAP)
    else
        tb:SetPoint("BOTTOM" .. side, cw, "TOP" .. side, 0, TOOLBAR_GAP)
    end
end

-- On the overlay, a pill shows the rating tooltip (with the ranks) and
-- moves the window when dragged, like the rest of the overlay
local function HookOverlayPill(p)
    if p.overlayHooked then return end
    p.overlayHooked = true
    local cw = PVPHUB.compactWindow
    p:RegisterForDrag("LeftButton")
    p:SetScript("OnDragStart", function()
        local start = cw:GetScript("OnDragStart")
        if start then start(cw) end
    end)
    p:SetScript("OnDragStop", function()
        local stop = cw:GetScript("OnDragStop")
        if stop then stop(cw) end
    end)
    p:SetScript("OnEnter", function(self)
        local enter = cw:GetScript("OnEnter")   -- keeps the toolbar up
        if enter then enter(cw) end
        if self.charKey then
            ShowPVPHUBRatingTooltip(self, self.charKey, self.bracketKey, self.data and self.data[self.bracketKey])
        end
    end)
    p:SetScript("OnLeave", function()
        ClosePVPHUBRatingTooltip()
        local leave = cw:GetScript("OnLeave")
        if leave then leave(cw) end
    end)
end

-- The Skin choice in the settings: the skins side by side, the chosen one
-- on a pill in the theme's color. picker.onChange runs after a change.
local SKIN_BUTTON_W, SKIN_BUTTON_H = 76, 24

local function CreateSkinPicker(parent)
    local UI = PVPHUB.UI
    local picker = CreateFrame("Frame", nil, parent)
    picker:SetSize(SKIN_BUTTON_W * #SKINS + 4, SKIN_BUTTON_H + 4)
    picker.track = UI.CreatePill(picker, "BACKGROUND")
    picker.track:SetVertexColor(1, 1, 1, 0.06)
    picker.buttons = {}

    function picker.Paint()
        local skin = CompactSkin()
        local t = UI.ThemeColor()
        -- Dark text on a light theme color (the grey of the Dark theme)
        local onText = (t[1] * 0.3 + t[2] * 0.59 + t[3] * 0.11) > 0.6 and 0.08 or 1
        for _, b in ipairs(picker.buttons) do
            local on = b.key == skin
            b.fill:SetVertexColor(t[1], t[2], t[3], on and 0.9 or 0)
            local c = on and onText or (b:IsMouseOver() and 1 or 0.7)
            b.label:SetTextColor(c, c, c)
        end
    end

    for i, s in ipairs(SKINS) do
        local b = CreateFrame("Button", nil, picker)
        b:SetSize(SKIN_BUTTON_W, SKIN_BUTTON_H)
        b:SetPoint("LEFT", picker, "LEFT", 2 + (i - 1) * SKIN_BUTTON_W, 0)
        b.key = s.key
        b.fill = UI.CreatePill(b, "ARTWORK")
        -- The settings window's font, a size up and without an outline: the
        -- small game font got its outline from font addons, which smeared
        -- dark text on the light selected pill
        b.label = b:CreateFontString(nil, "OVERLAY")
        SafeSetFont(b.label, FALLBACK_FONT, 12, "")
        b.label:SetPoint("CENTER")
        b.label:SetText(s.label)
        b:SetScript("OnClick", function()
            SetCompactSkin(s.key)
            picker.Paint()
            if PVPHUB.compactWindow then PVPHUB:UpdateCompactWindow() end
            if picker.onChange then picker.onChange() end
        end)
        b:SetScript("OnEnter", function(self)
            picker.Paint()
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetText(s.label, 1, 1, 1)
            GameTooltip:AddLine(s.tip, 0.7, 0.7, 0.7, true)
            GameTooltip:Show()
        end)
        b:SetScript("OnLeave", function()
            GameTooltip:Hide()
            picker.Paint()
        end)
        picker.buttons[i] = b
    end
    picker.Paint()
    return picker
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
        
        -- Toolbar: a dark pill floating under the content window, whatever
        -- its skin (PlaceToolbar keeps it on screen); dragging the parent
        -- moves both. Controls fade in on hover and fade out after 3 s of
        -- inactivity, so on stream only the overlay itself shows.
        local toolbar = CreateFrame("Frame", nil, PVPHUB.compactWindow)
        toolbar:SetPoint("TOPLEFT", PVPHUB.compactWindow, "BOTTOMLEFT", 0, -TOOLBAR_GAP)
        toolbar:SetSize(250, 22)
        toolbar:SetFrameLevel(PVPHUB.compactWindow:GetFrameLevel() + 1)
        toolbar.bg = PVPHUB.UI.CreatePill(toolbar, "BACKGROUND")
        toolbar.bg:SetVertexColor(0.05, 0.055, 0.08, 0.92)

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
        sortDropBtn:SetPoint("LEFT", toolbar, "LEFT", 8, 0)
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
        -- Closes with the compact window (Escape, the toggle) while open
        sortDropBtn:HookScript("OnHide", function() ddPopup:Hide() end)

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

        ddPopup:SetClampedToScreen(true)   -- never past the screen's sides
        ddPopup:SetScript("OnShow", function()
            -- Opens below the sort button, or above it when there's no
            -- room below (the toolbar can sit at the bottom of the screen).
            -- Compared in screen pixels: the button is in the scaled
            -- overlay, the list isn't.
            ddPopup:ClearAllPoints()
            local below = (sortDropBtn:GetBottom() or 0) * sortDropBtn:GetEffectiveScale()
            if below - (ddPopup:GetHeight() + 2) * ddPopup:GetEffectiveScale() >= 0 then
                ddPopup:SetPoint("TOPLEFT", sortDropBtn, "BOTTOMLEFT", 0, -2)
            else
                ddPopup:SetPoint("BOTTOMLEFT", sortDropBtn, "TOPLEFT", 0, 2)
            end
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
        -- The toolbar follows along while dragging, so it stays on screen
        -- at every edge (PlaceToolbar)
        local toolbarFollow = CreateFrame("Frame", nil, PVPHUB.compactWindow)
        PVPHUB.compactWindow:SetScript("OnDragStart", function(self)
            self:StartMoving()
            toolbarFollow:SetScript("OnUpdate", PlaceToolbar)
        end)
        PVPHUB.compactWindow:SetScript("OnDragStop", function(self)
            self:StopMovingOrSizing()
            toolbarFollow:SetScript("OnUpdate", nil)
            PlaceToolbar()
            if not PVPHUB_SETTINGS.compactWindowPos then PVPHUB_SETTINGS.compactWindowPos = {} end
            local point, relativeTo, relativePoint, xOfs, yOfs = self:GetPoint()
            PVPHUB_SETTINGS.compactWindowPos = {point=point, relativePoint=relativePoint, x=xOfs, y=yOfs}
        end)
        
        -- The rounded panel of the chosen skin
        PaintCompactShell()

        -- Character rows container — fills the full window; the overlay drifts on top at the bottom.
        PVPHUB.compactWindow.content = CreateFrame("Frame", nil, PVPHUB.compactWindow)
        PVPHUB.compactWindow.content:SetPoint("TOPLEFT", 8, -5)
        PVPHUB.compactWindow.content:SetPoint("BOTTOMRIGHT", PVPHUB.compactWindow, "BOTTOMRIGHT", -8, 5)
        
        -- Close button — same desaturated-silver style as the main window
        PVPHUB.compactWindow.closeBtn = CreateFrame("Button", nil, toolbar, "UIPanelCloseButton")
        PVPHUB.compactWindow.closeBtn:SetPoint("RIGHT", toolbar, "RIGHT", -6, 0)
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
        -- 7.0: the UI kit replaces the silver art with its thin "×"
        if PVPHUB.UI then PVPHUB.UI.SkinCloseButton(PVPHUB.compactWindow.closeBtn) end
        
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
        scaleSlider:SetPoint("RIGHT", toolbar, "RIGHT", -44, 0)
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
                PlaceToolbar()
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
        if PVPHUB.UI then PVPHUB.UI.SkinSlider(scaleSlider) end
        
        -- Apply saved scale to compact window
        PVPHUB.compactWindow:SetScale(PVPHUB.compactWindow.currentScale)
        
        -- Overlay starts fully visible; the idle timer fades it out as one unit.
        -- Fading the parent toolbar frame automatically fades all its children.
        PVPHUB.compactWindow.fadeTimer = nil
        toolbar:SetAlpha(1)

        local function fadeToolbarIn()
            PVPHUB_SimpleFade(toolbar, 0.3, toolbar:GetAlpha(), 1)
        end

        local function fadeToolbarOut()
            PVPHUB_SimpleFade(toolbar, 1, toolbar:GetAlpha(), 0)
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

        -- 7.0: ladder ranks move while others play, and the game only
        -- reports the logged-in character's when asked. Ask every 5
        -- minutes while the overlay is up, out of combat and matches; the
        -- answer (PVP_RATED_STATS_UPDATE) saves it with the rating
        -- (pvp_tracking.lua), then the overlay redraws (a new rank alone
        -- doesn't change what PVPHUB_RefreshUI compares).
        PVPHUB.compactWindow.rankTicker = C_Timer.NewTicker(300, function()
            local cw = PVPHUB.compactWindow
            if not (cw:IsShown() and RequestRatedInfo) or InCombatLockdown() or IsInActivePvP() then return end
            RequestRatedInfo()
            C_Timer.After(3, function()
                if cw:IsShown() then PVPHUB:UpdateCompactWindow() end
            end)
        end)

        -- The toolbar's place once the window's position is known
        PVPHUB.compactWindow:HookScript("OnShow", function() C_Timer.After(0, PlaceToolbar) end)
    end
    
    PVPHUB:UpdateCompactWindow()
    PVPHUB.compactWindow:Show()
    PVPHUB_SETTINGS.compactWindowStayOpen = true
end

-- Streamer Mode widgets are pooled: the header row and every character row
-- are created once and reconfigured on each update. They used to be rebuilt
-- from scratch on every update with the old ones only hidden and detached,
-- but the client never frees frames, so a stream left running for hours kept
-- piling up rows, buttons and textures (a few dozen per update, and updates
-- arrive with every rating and currency change).

-- True when a stored rating (flat number or per-spec table) has anything
-- above 0 for the rating tooltip to show.
-- Row layout (7.0). In each rating column the rating is right-aligned, so
-- the digits line up, and a recent change sits after it as a small green or
-- red pill. The columns are as wide as their content (CompactLayout);
-- NUMBER_W is only a new rating text's width until then.
local NUMBER_W     = 42
local HEADER_TEXT  = { 0.56, 0.55, 0.62 }
local DELTA_UP     = { 0.29, 0.87, 0.50 }
local DELTA_DOWN   = { 0.97, 0.44, 0.44 }

local function HasRatingToShow(value)
    if type(value) == "number" then return value > 0 end
    if type(value) == "table" then
        for _, v in pairs(value) do
            if type(v) == "number" and v > 0 then return true end
        end
    end
    return false
end

local function GetCompactHeaderRow()
    local cw = PVPHUB.compactWindow
    if cw.headerRow then return cw.headerRow end

    local headerRow = CreateFrame("Frame", nil, cw.content)

    local charHeader = headerRow:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    charHeader:SetPoint("LEFT", 5, 0)   -- in line with the names
    charHeader:SetJustifyH("LEFT")
    charHeader:SetWordWrap(false) -- Prevent text wrapping
    charHeader:SetNonSpaceWrap(false) -- Prevent wrapping on non-space characters
    charHeader:SetMaxLines(1) -- Force single line display
    charHeader:SetText("Character")
    charHeader:SetTextColor(unpack(HEADER_TEXT))
    headerRow.charHeader = charHeader

    -- One label per bracket in display order; hidden while its column is
    -- off. Right-aligned like the ratings under it.
    headerRow.columns = {}
    for i, header in ipairs(COMPACT_BRACKET_ORDER) do
        local headerText = headerRow:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        headerText:SetJustifyH("RIGHT")
        headerText:SetText(header.name)
        headerText:SetTextColor(unpack(HEADER_TEXT))
        headerRow.columns[i] = headerText
    end

    cw.headerRow = headerRow
    return headerRow
end

-- Returns pooled row #index, creating it on first use. Everything that
-- depends on which character or spec the row shows is set by
-- ConfigureCompactRow; the scripts below read it back from the row when
-- hovered.
local function AcquireCompactRow(index)
    local cw = PVPHUB.compactWindow
    cw.rowPool = cw.rowPool or {}
    local row = cw.rowPool[index]
    if row then return row end

    local C = PVPHUB_CONSTANTS.COMPACT_WINDOW
    row = CreateFrame("Frame", nil, cw.content)

    -- Row hover highlight (same as main window)
    local hoverBG = row:CreateTexture(nil, "OVERLAY")
    hoverBG:SetTexture("Interface\\Buttons\\WHITE8x8")
    hoverBG:SetAllPoints(row)
    hoverBG:Hide()
    row.hoverBG = hoverBG

    -- Small tree connector, shown on sub-rows only
    local connectorV = row:CreateTexture(nil, "OVERLAY")
    connectorV:SetTexture("Interface\\Buttons\\WHITE8x8")
    connectorV:SetVertexColor(0.5, 0.5, 0.55, 0.6)
    connectorV:SetWidth(1)
    connectorV:SetPoint("TOPLEFT", row, "TOPLEFT", 9, 0)
    connectorV:SetPoint("BOTTOM", row, "CENTER", 0, 0)
    row.connectorV = connectorV

    local connectorH = row:CreateTexture(nil, "OVERLAY")
    connectorH:SetTexture("Interface\\Buttons\\WHITE8x8")
    connectorH:SetVertexColor(0.5, 0.5, 0.55, 0.6)
    connectorH:SetHeight(1)
    connectorH:SetPoint("LEFT", row, "LEFT", 9, 0)
    connectorH:SetPoint("RIGHT", row, "LEFT", 16, 0) -- 16 = sub-row name indent
    connectorH:SetPoint("TOP", row, "CENTER", 0, 0)
    row.connectorH = connectorH

    local nameText = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    nameText:SetJustifyH("LEFT")
    nameText:SetWordWrap(false) -- Prevent text wrapping
    nameText:SetNonSpaceWrap(false) -- Prevent wrapping on non-space characters
    nameText:SetMaxLines(1) -- Force single line display
    row.nameText = nameText

    -- Character tooltip over the name area
    local nameTooltipBtn = CreateFrame("Button", nil, row)
    nameTooltipBtn:SetScript("OnEnter", function(self)
        row.hoverBG:Show()
        ShowCharacterTooltip(row.charKey, self)
    end)
    nameTooltipBtn:SetScript("OnLeave", function()
        row.hoverBG:Hide()
        HideCharacterTooltip()
    end)
    row.nameTooltipBtn = nameTooltipBtn

    -- One rating cell per bracket in display order: the value, the recent
    -- change pill, the multi-spec star and an invisible button for the
    -- rating tooltip.
    row.slots = {}
    for i, bracket in ipairs(COMPACT_BRACKET_ORDER) do
        local slot = {}

        local text = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        text:SetWidth(NUMBER_W)
        text:SetJustifyH("RIGHT")
        slot.text = text

        local pill = CreateFrame("Frame", nil, row)
        pill:SetSize(26, 14)   -- height before the pill shape, which reads it
        pill.bg = PVPHUB.UI.CreatePill(pill, "BACKGROUND")
        pill.text = pill:CreateFontString(nil, "OVERLAY")
        pill.text:SetPoint("CENTER", 0, 0)
        pill:Hide()
        slot.pill = pill

        local star = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        star:SetText("|TInterface\\Common\\FavoritesIcon:12|t")
        slot.star = star

        local hoverBtn = CreateFrame("Button", nil, row)
        hoverBtn:SetSize(C.COLUMN_WIDTH - 10, C.ROW_HEIGHT)
        hoverBtn:SetFrameLevel(row:GetFrameLevel() + 5)
        hoverBtn:SetScript("OnEnter", function(self)
            row.hoverBG:Show()
            local value = row.data and row.data[bracket.key]
            if HasRatingToShow(value) then
                ShowPVPHUBRatingTooltip(self, row.charKey, bracket.key, value)
            end
        end)
        hoverBtn:SetScript("OnLeave", function()
            row.hoverBG:Hide()
            GameTooltip:Hide()
            ClosePVPHUBRatingTooltip()
        end)
        slot.hoverBtn = hoverBtn

        row.slots[i] = slot
    end

    cw.rowPool[index] = row
    return row
end

-- Points a pooled row at one character and lays it out.
--
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
-- Fills in the texts only; PlaceCompactRow lays them out once every row is
-- filled, since the columns are as wide as their widest content.
local function ConfigureCompactRow(row, charKey, data, yOffset, pinnedSpecID, isSubRow)
    local C = PVPHUB_CONSTANTS.COMPACT_WINDOW
    row.charKey = charKey
    row.data = data

    row:SetHeight(C.ROW_HEIGHT)
    row:ClearAllPoints()
    row:SetPoint("TOPLEFT", 0, -yOffset)

    local hc = GetCurrentTheme().HOVER_BG
    row.hoverBG:SetVertexColor(hc[1], hc[2], hc[3], hc[4])
    row.hoverBG:Hide()

    -- Sub-rows are indented with the tree connector so they read as belonging
    -- to the row directly above them, instead of looking like an unrelated
    -- duplicate entry once rows are grouped adjacently.
    row.nameIndent = isSubRow and 16 or 5
    row.connectorV:SetShown(isSubRow == true)
    row.connectorH:SetShown(isSubRow == true)

    -- Character name in its class color (truncated if too long), with the
    -- green dot for the logged-in character. On a pinned-spec row, show
    -- that spec's icon instead of the character's currently-active one, so
    -- the duplicated rows for one character are visually distinguishable.
    local nameText = row.nameText
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
    else
        nameText:SetText(CreateCharacterName({char = charKey, data = data}, true))
    end
    -- Slightly dimmed to read as a sub-row of the row above
    nameText:SetAlpha((pinnedSpecID and isSubRow) and 0.85 or 1)
    StyleCompactText(nameText, 11)

    -- Rating columns — same order as headers
    local showRatings = PVPHUB_SETTINGS.compactMode and PVPHUB_SETTINGS.compactMode.showRatings
    for i, bracket in ipairs(COMPACT_BRACKET_ORDER) do
        local slot = row.slots[i]
        if showRatings and showRatings[bracket.key] then
            -- On a pinned-spec row, the per-spec brackets (Shuffle/Blitz) show
            -- THAT spec's rating specifically. 2v2/3v3/RBG aren't spec-specific
            -- to begin with, so they render exactly like the default row.
            local currentRating, isMultiSpec, shownSpecID
            if pinnedSpecID and (bracket.key == "ratingShuffle" or bracket.key == "ratingBlitz") then
                local ratingTable = data[bracket.key]
                currentRating = (type(ratingTable) == "table" and ratingTable[pinnedSpecID]) or 0
                isMultiSpec = false -- explicit single spec, no ambiguity to flag
                shownSpecID = pinnedSpecID
            else
                -- GetShuffleDisplayInfo handles flat numbers (2v2/3v3) and per-spec
                -- tables (Shuffle/Blitz) through the same code path.
                local specCount
                currentRating, shownSpecID, specCount = GetShuffleDisplayInfo(data, charKey, bracket.key)
                isMultiSpec = (specCount > 1)
            end
            -- 2v2/3v3/RBG aren't spec-specific — on a sub-row they'd just repeat
            -- the exact same number already shown on the anchor row above, which
            -- reads as if it might differ per spec when it can't. Show a "same as
            -- above" placeholder there instead of the number itself (only when
            -- there's actually a value to point back to).
            local isCharacterWideBracket = bracket.key == "rating2v2" or bracket.key == "rating3v3" or bracket.key == "ratingRBG"
            local showAsDitto = isSubRow and isCharacterWideBracket and currentRating > 0

            local display, delta, changeAge, changeAt
            if showAsDitto then
                display = "|cff666666^|r"
            else
                display = GetRatingColor(currentRating) .. (currentRating > 0 and currentRating or "-") .. "|r"
                -- Recent change after a match, shown as a pill: "1843 (+18)"
                delta, changeAge, changeAt = PVPHUB.GetRecentRatingChange(charKey, bracket.key, shownSpecID)
            end

            slot.text:SetText(display)
            StyleCompactText(slot.text, 11)
            slot.text:Show()

            local pill = slot.pill
            if delta then
                local c = delta > 0 and DELTA_UP or DELTA_DOWN
                StyleCompactText(pill.text, 10)
                pill.text:SetText(string.format("%+d", delta))
                pill.text:SetTextColor(c[1], c[2], c[3])
                pill.bg:SetVertexColor(c[1], c[2], c[3], 0.16)
                pill:SetWidth(math.ceil(pill.text:GetStringWidth()) + 10)
                pill:Show()
            else
                pill:Hide()
            end
            -- Blink once when a fresh change first shows up in this cell
            if PVPHUB.IsRatingChangeFresh(changeAge) and slot.flashedChangeAt ~= changeAt then
                slot.flashedChangeAt = changeAt
                PVPHUB.FlashRegion(slot.text)
                PVPHUB.FlashRegion(pill)
            end

            -- Star icon for multi-spec ratings, after the rating (and its change)
            if isMultiSpec then
                StyleCompactText(slot.star, 11)
                slot.star:Show()
            else
                slot.star:Hide()
            end
            slot.hoverBtn:Show()
        else
            slot.text:Hide()
            slot.pill:Hide()
            slot.star:Hide()
            slot.hoverBtn:Hide()
        end
    end

    row:Show()
end

-- Column layout (7.0): the overlay is only as wide as what it shows. The
-- name column fits the longest name shown, each rating column its widest
-- rating or header plus the change pills and stars in it. It used to
-- reserve 135 for the names and 80 per column, 260 at least, for a toolbar
-- that floats on its own now.
local NAME_GAP, COLUMN_GAP, ROW_PAD = 14, 12, 5

-- Blizzard allows character names of 2 to 12 letters (accents, but no
-- numbers or symbols). With server names shown, core's CreateCharacterName
-- shortens the realm so name and realm are 20 characters at most. The name
-- column's limit is that many of the widest letters in the overlay's font,
-- with every icon a name can carry (spec, logged-in dot, pin), so no real
-- name is cut; anything longer (broken data) ends in "...".
local NAME_LETTERS, NAME_WITH_REALM = 12, 20
local NAME_ICONS = "|TInterface\\Icons\\INV_Misc_QuestionMark:14|t "
    .. "|TInterface\\Common\\Indicator-Green:12|t "
    .. "|TInterface\\Minimap\\UI-Minimap-ZoomInButton-Up:14|t "

local function NameColumnLimit(headerRow)
    local probe = headerRow.nameProbe
    if not probe then
        probe = headerRow:CreateFontString(nil, "OVERLAY")
        probe:SetPoint("LEFT")
        probe:SetAlpha(0)   -- only measured
        headerRow.nameProbe = probe
    end
    StyleCompactText(probe, 11)   -- as the names
    local cm = PVPHUB_SETTINGS.compactMode
    local letters = cm.hideServerNames and NAME_LETTERS or NAME_WITH_REALM
    local widest = 0
    for _, wide in ipairs({ { "M", "m" }, { "W", "w" } }) do
        probe:SetText(NAME_ICONS .. wide[1] .. string.rep(wide[2], letters - 1))
        widest = math.max(widest, probe:GetUnboundedStringWidth())
    end
    return 16 + math.ceil(widest) + 2   -- 16: a sub-row's indent, the deepest
end

-- How far a cell's change pill and star reach past its rating
local function CellExtra(slot)
    local w = 0
    if slot.pill:IsShown() then w = 4 + slot.pill:GetWidth() end
    if slot.star:IsShown() then w = w + (w > 0 and 2 or 4) + slot.star:GetStringWidth() end
    return w
end

-- Measures the filled header and rows: where the names end, and each shown
-- column's x, rating width (the ratings are right-aligned in it, under
-- their header) and full width
local function CompactLayout(headerRow, rows)
    local layout = { columnX = {}, numberW = {}, columnW = {} }
    local nameRight = ROW_PAD + headerRow.charHeader:GetUnboundedStringWidth()
    for _, row in ipairs(rows) do
        nameRight = math.max(nameRight, row.nameIndent + row.nameText:GetUnboundedStringWidth())
    end
    -- A little slack, so a name that just fits isn't cut by rounding
    layout.nameRight = math.min(NameColumnLimit(headerRow), math.ceil(nameRight) + 2)
    local right = layout.nameRight
    local x = right + NAME_GAP
    for i, header in ipairs(headerRow.columns) do
        if header:IsShown() then
            local numberW, extra = header:GetUnboundedStringWidth(), 0
            for _, row in ipairs(rows) do
                local slot = row.slots[i]
                numberW = math.max(numberW, slot.text:GetUnboundedStringWidth())
                extra = math.max(extra, CellExtra(slot))
            end
            numberW = math.ceil(numberW) + 2
            layout.columnX[i], layout.numberW[i] = x, numberW
            layout.columnW[i] = numberW + math.ceil(extra)
            right = x + layout.columnW[i]
            x = right + COLUMN_GAP
        end
    end
    layout.width = right + ROW_PAD
    return layout
end

local function PlaceCompactRow(row, layout)
    local height = PVPHUB_CONSTANTS.COMPACT_WINDOW.ROW_HEIGHT
    local indent = row.nameIndent
    row:SetWidth(layout.width)
    row.nameText:ClearAllPoints()
    row.nameText:SetPoint("LEFT", indent, 0)
    row.nameText:SetWidth(layout.nameRight - indent)
    row.nameTooltipBtn:ClearAllPoints()
    row.nameTooltipBtn:SetPoint("LEFT", indent, 0)
    row.nameTooltipBtn:SetSize(layout.nameRight - indent, height)
    for i, slot in ipairs(row.slots) do
        local x = layout.columnX[i]
        if x then
            slot.text:ClearAllPoints()
            slot.text:SetPoint("LEFT", x, 0)
            slot.text:SetWidth(layout.numberW[i])
            -- The change pill after the rating, the star after both
            local after = x + layout.numberW[i] + 4
            slot.pill:ClearAllPoints()
            slot.pill:SetPoint("LEFT", row, "LEFT", after, 0)
            if slot.pill:IsShown() then after = after + slot.pill:GetWidth() + 2 end
            slot.star:ClearAllPoints()
            slot.star:SetPoint("LEFT", after, 0)
            slot.hoverBtn:ClearAllPoints()
            slot.hoverBtn:SetPoint("LEFT", x, 0)
            slot.hoverBtn:SetSize(layout.columnW[i], height)
        end
    end
end

-- Implementation for PVPHUB:UpdateCompactWindow (wrapped below in a pcall).
-- Rebuilds the entire streamer overlay from scratch every call, with deep
-- indexing into PVPHUB_DB/PVPHUB_SETTINGS and no per-call guards — unlike
-- most other update paths in the addon, so one bad index here would
-- otherwise throw a raw, on-stream, error instead of failing gracefully.
local function UpdateCompactWindowImpl()
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
    
    -- The skin's panel (refreshed on every update: theme, color, skin)
    PaintCompactShell()

    -- If nothing is selected AND nothing is pinned, add the current character,
    -- once ever (seededDefault), so a new overlay isn't empty. After that an
    -- empty overlay is the user's choice: this used to run on every update,
    -- so switching off the last spec put the character straight back, as a
    -- plain row the settings had no switch for. Checking pinnedSpecs too
    -- matters because graduating to pinned-spec rows
    -- (PromoteToMultiSpecIfNeeded) removes a character from selectedChars.
    local cm = PVPHUB_SETTINGS.compactMode
    if not cm.seededDefault then
        local hasAny = #cm.selectedChars > 0
        for _, pins in pairs(cm.pinnedSpecs) do
            if next(pins) then hasAny = true; break end
        end
        if not hasAny then
            local currentChar = GetFullName()
            if currentChar and PVPHUB_DB[currentChar] then
                table.insert(cm.selectedChars, currentChar)
                hasAny = true
            end
        end
        cm.seededDefault = hasAny or nil   -- try again once the character is saved
    end
    -- Remove any prompt about opening PvP window for compact mode; data is fetched automatically for current character

    -- The width follows the content, set once the rows are filled
    -- (CompactLayout)

    -- Keep the sort cycle button label in sync
    if PVPHUB.compactWindow.sortBtnText and PVPHUB.compactWindow.GetSortLabel then
        PVPHUB.compactWindow.sortBtnText:SetText(PVPHUB.compactWindow.GetSortLabel(PVPHUB_SETTINGS.compactSortKey or "highestRating"))
    end
    
    local yOffset = 0
    local rowHeight = PVPHUB_CONSTANTS.COMPACT_WINDOW.ROW_HEIGHT

    -- Header row (pooled, see GetCompactHeaderRow)
    local headerRow = GetCompactHeaderRow()
    headerRow:SetHeight(rowHeight)
    headerRow:ClearAllPoints()
    headerRow:SetPoint("TOPLEFT", 0, -yOffset - 3) -- Add 3px top padding
    StyleCompactText(headerRow.charHeader, 10)

    -- Rating headers, placed with the rows (PlaceCompactRow)
    for i, header in ipairs(COMPACT_BRACKET_ORDER) do
        local headerText = headerRow.columns[i]
        if PVPHUB_SETTINGS.compactMode.showRatings[header.key] then
            StyleCompactText(headerText, 10)
            headerText:Show()
        else
            headerText:Hide()
        end
    end
    headerRow:Show()

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
    -- A rated character left there without pins (the old every-update default
    -- re-added one) gets its shown spec pinned instead: the settings list
    -- only has spec switches for it, so the plain row couldn't be turned off.
    do
        local sel = PVPHUB_SETTINGS.compactMode.selectedChars
        for i = #sel, 1, -1 do
            local charKey = sel[i]
            local pins = PVPHUB_SETTINGS.compactMode.pinnedSpecs[charKey]
            local data = PVPHUB_DB[charKey]
            if pins and next(pins) then
                table.remove(sel, i)
            elseif data and GetDistinctRatedSpecCount(data) >= 1 then
                table.remove(sel, i)
                PinShownSpec(charKey, data)
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

    -- Minimal skin: a pill per spec instead of the table
    local cw = PVPHUB.compactWindow
    local minimal = CompactSkin() == "minimal"
    cw.pillPool = cw.pillPool or {}
    headerRow:SetShown(not minimal)
    if minimal then
        for _, row in ipairs(cw.rowPool or {}) do row:Hide() end
        local items = SpecPillItems(selected)
        local width, height = LayoutSpecPills(cw.content, cw.pillPool, items)
        for _, p in ipairs(cw.pillPool) do HookOverlayPill(p) end
        if not cw.pillEmpty then
            cw.pillEmpty = cw.content:CreateFontString(nil, "OVERLAY")
            cw.pillEmpty:SetFont(FALLBACK_FONT, 11, "")
            cw.pillEmpty:SetPoint("TOPLEFT", cw.content, "TOPLEFT", 2, -4)
        end
        cw.pillEmpty:SetShown(#items == 0)
        if #items == 0 then
            StyleCompactText(cw.pillEmpty, 11)
            cw.pillEmpty:SetText("No rated specs on the overlay yet")
            cw.pillEmpty:SetTextColor(unpack(HEADER_TEXT))
            width, height = cw.pillEmpty:GetStringWidth() + 8, 20
        end
        cw:SetSize(width + 16, height + 10)
        PlaceToolbar()
        return
    end
    for _, p in ipairs(cw.pillPool) do p:Hide() end
    if cw.pillEmpty then cw.pillEmpty:Hide() end

    local visibleCharCount = 0
    PVPHUB.compactWindow.rows = {}
    for i, entry in ipairs(selected) do
        local row = AcquireCompactRow(i)
        ConfigureCompactRow(row, entry.char, entry.data, yOffset, entry.pinnedSpecID, entry.isSubRow)
        table.insert(PVPHUB.compactWindow.rows, row)
        yOffset = yOffset + rowHeight
        visibleCharCount = visibleCharCount + 1
    end
    -- Hide pooled rows left over from a longer list
    local pool = PVPHUB.compactWindow.rowPool
    if pool then
        for i = #selected + 1, #pool do
            pool[i]:Hide()
        end
    end

    -- Columns as wide as their content, then the window around them
    local layout = CompactLayout(headerRow, PVPHUB.compactWindow.rows)
    headerRow:SetWidth(layout.width)
    headerRow.charHeader:SetWidth(layout.nameRight - ROW_PAD)
    for i, headerText in ipairs(headerRow.columns) do
        local x = layout.columnX[i]
        if x then
            headerText:ClearAllPoints()
            headerText:SetPoint("LEFT", x, 0)
            headerText:SetWidth(layout.numberW[i])   -- right-aligned over the ratings
        end
    end
    for _, row in ipairs(PVPHUB.compactWindow.rows) do
        PlaceCompactRow(row, layout)
    end
    local dynamicWidth = layout.width + 16
    PVPHUB.compactWindow:SetWidth(dynamicWidth)

    -- Calculate dynamic window height based on content only.
    -- The overlay toolbar floats on top and does not reserve space.
    local headerHeight = rowHeight + 5
    local characterRowsHeight = visibleCharCount * rowHeight
    local windowPadding = 14 -- top (5) + bottom (9)

    local dynamicHeight = math.max(40, headerHeight + characterRowsHeight + windowPadding)
    
    -- Update window height dynamically
    PVPHUB.compactWindow:SetHeight(dynamicHeight)
    PVPHUB.compactWindow.content:SetSize(dynamicWidth - 16, yOffset)
    PlaceToolbar()
end

function PVPHUB:UpdateCompactWindow()
    -- Remember which data this render was built from so PVPHUB_RefreshUI can
    -- skip identical rebuilds; only kept when the render succeeded.
    local sig = PVPHUB._ComputeDisplaySignature and PVPHUB._ComputeDisplaySignature()
    PVPHUB._compactRenderSig = nil
    local ok, err = pcall(UpdateCompactWindowImpl)
    if ok then
        PVPHUB._compactRenderSig = sig
    else
        PVPHubPrint("|cffff0000[PVP HUB]|r Compact window update failed: " .. tostring(err))
    end
end

-- --------------------------------------------------------------------------
-- Settings window (7.0)
-- --------------------------------------------------------------------------
-- Streamer Mode's settings: a header with the overlay's on/off switch, a
-- sidebar with four pages (Appearance with a live preview of the overlay,
-- Characters, Brackets, Behavior) and the chosen page beside it. The last
-- page opened is remembered (PVPHUB_SETTINGS.compactSettingsPage).

local SET_W, SET_H   = 640, 480
local SET_HEADER_H   = 52
local SET_SIDEBAR_W  = 164
local SET_PAD        = 20
local SET_FONT       = "Fonts\\FRIZQT__.TTF"
local SET_TEXT       = { 0.93, 0.92, 0.95 }
local SET_MUTED      = { 0.62, 0.61, 0.68 }
local CHAR_ROW_H, SPEC_ROW_H = 34, 28

local SETTINGS_PAGES = {
    { key = "appearance", label = "Appearance", icon = "Interface\\Icons\\Ability_Hunter_EagleEye" },
    { key = "characters", label = "Characters", icon = "Interface\\Icons\\INV_Misc_GroupLooking" },
    { key = "brackets",   label = "Brackets",   icon = "Interface\\Icons\\achievement_pvp_a_15" },
    { key = "behavior",   label = "Behavior",   icon = "Interface\\Icons\\Trade_Engineering" },
}

local BRACKET_TILES = {
    { key = "rating2v2",     name = "2v2 Arena",    icon = "Interface\\Icons\\achievement_arena_2v2_1" },
    { key = "rating3v3",     name = "3v3 Arena",    icon = "Interface\\Icons\\achievement_arena_3v3_1" },
    { key = "ratingShuffle", name = "Solo Shuffle", icon = "Interface\\Icons\\ability_dualwield" },
    { key = "ratingBlitz",   name = "Blitz",        icon = "Interface\\Icons\\achievement_bg_killxenemies_generalsroom" },
    { key = "ratingRBG",     name = "Rated BG",     icon = "Interface\\Icons\\achievement_pvp_a_15" },
}

-- The overlay's font choices: the game's own fonts, then LibSharedMedia's.
-- Looked up through LSM's raw path table rather than LSM:Fetch, so font
-- manager addons (e.g. Fontmancer) can't hand back a different font.
local BUILTIN_FONTS = {
    ["Friz Quadrata TT"] = "Fonts\\FRIZQT__.TTF",
    ["Arial Narrow"]     = "Fonts\\ARIALN.TTF",
    ["Morpheus"]         = "Fonts\\MORPHEUS.TTF",
    ["Skurri"]           = "Fonts\\skurri.ttf",
}

local function ResolveCompactFont(name)
    local path = BUILTIN_FONTS[name]
    if not path and LibStub then
        local LSM = LibStub("LibSharedMedia-3.0", true)
        if LSM and LSM.HashTable then
            local fontTable = LSM:HashTable("font")
            if fontTable then path = fontTable[name] end
        end
    end
    return path
end

local function CompactFontList()
    local list, seen = {}, {}
    for name in pairs(BUILTIN_FONTS) do
        list[#list + 1] = name
        seen[name] = true
    end
    if LibStub then
        local LSM = LibStub("LibSharedMedia-3.0", true)
        if LSM then
            for _, name in ipairs(LSM:List("font") or {}) do
                if not seen[name] and ResolveCompactFont(name) then
                    seen[name] = true
                    list[#list + 1] = name
                end
            end
        end
    end
    table.sort(list)
    return list
end

-- A character's best current-season rating in any bracket
local function BestRating(data)
    if not data or (PVPHUB._IsSeasonDataCurrent and not PVPHUB._IsSeasonDataCurrent(data)) then
        return 0
    end
    local best = 0
    for _, bracket in ipairs(COMPACT_BRACKET_ORDER) do
        local value = data[bracket.key]
        if type(value) == "number" then
            best = math.max(best, value)
        elseif type(value) == "table" then
            for _, v in pairs(value) do
                if type(v) == "number" then best = math.max(best, v) end
            end
        end
    end
    return best
end

local function RatingText(rating)
    if rating and rating > 0 then return GetRatingColor(rating) .. rating .. "|r" end
    return "|cff555555-|r"
end

-- On the overlay: picked (no rated spec yet) or with a pinned spec
local function IsOnOverlay(charKey)
    local cm = PVPHUB_SETTINGS.compactMode
    local pins = cm.pinnedSpecs and cm.pinnedSpecs[charKey]
    if pins and next(pins) then return true end
    for _, key in ipairs(cm.selectedChars) do
        if key == charKey then return true end
    end
    return false
end

local function SettingsText(parent, size, color)
    local fs = parent:CreateFontString(nil, "OVERLAY")
    fs:SetFont(SET_FONT, size, "")
    fs:SetJustifyH("LEFT")
    fs:SetWordWrap(false)
    local c = color or SET_TEXT
    fs:SetTextColor(c[1], c[2], c[3])
    return fs
end

-- A pill switch (UI kit); onChange gets the new state
local function SettingsSwitch(parent, onChange)
    local cb = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
    cb:SetSize(30, 20)
    PVPHUB.UI.SkinSwitch(cb)
    cb:SetScript("OnClick", function(self) onChange(self:GetChecked() and true or false) end)
    return cb
end

-- A setting as a row: its name and a line of explanation on the left, its
-- switch on the right. Clicking anywhere on the row flips the switch.
local function OptionRow(parent, width, title, desc, onChange)
    local row = CreateFrame("Button", nil, parent)
    row:SetSize(width, desc and 52 or 38)
    row.title = SettingsText(row, 13)
    row.title:SetText(title)
    if desc then
        row.title:SetPoint("TOPLEFT", row, "TOPLEFT", 0, -10)
        row.desc = SettingsText(row, 11, SET_MUTED)
        row.desc:SetPoint("TOPLEFT", row.title, "BOTTOMLEFT", 0, -5)
        row.desc:SetText(desc)
    else
        row.title:SetPoint("LEFT", row, "LEFT", 0, 0)
    end
    row.switch = SettingsSwitch(row, onChange)
    row.switch:SetPoint("RIGHT", row, "RIGHT", -2, 0)
    row:SetScript("OnClick", function() row.switch:Click() end)
    local line = row:CreateTexture(nil, "BACKGROUND")
    line:SetColorTexture(1, 1, 1, 0.06)
    line:SetHeight(1)
    line:SetPoint("BOTTOMLEFT")
    line:SetPoint("BOTTOMRIGHT")
    return row
end

-- Sidebar entries: the open page on the theme color, the others light up
-- on hover
local function PaintNavButton(b)
    local hover = b:IsMouseOver()
    if b.selected then
        local t = PVPHUB.UI.ThemeColor()
        b.fill:SetVertexColor(t[1], t[2], t[3], 0.22)
    else
        b.fill:SetVertexColor(1, 1, 1, hover and 0.05 or 0)
    end
    local lit = b.selected or hover
    local c = lit and 1 or 0.72
    b.label:SetTextColor(c, c, c)
    b.icon:SetAlpha(lit and 1 or 0.7)
end

local function NavButton(parent, label, icon)
    local b = CreateFrame("Button", nil, parent)
    b:SetSize(SET_SIDEBAR_W - 24, 34)
    b.fill = PVPHUB.UI.CreatePanel(b, "fill", "BACKGROUND", 0, 7)
    b.icon = b:CreateTexture(nil, "ARTWORK")
    b.icon:SetSize(18, 18)
    b.icon:SetPoint("LEFT", b, "LEFT", 10, 0)
    b.icon:SetTexture(icon)
    b.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    b.label = SettingsText(b, 13)
    b.label:SetPoint("LEFT", b.icon, "RIGHT", 10, 0)
    b.label:SetText(label)
    b:SetScript("OnEnter", PaintNavButton)
    b:SetScript("OnLeave", PaintNavButton)
    PaintNavButton(b)
    return b
end

-- --------------------------------------------------------------------------
-- Appearance page
-- --------------------------------------------------------------------------
-- A live preview of the overlay on top: its header and two of its
-- characters (the logged-in one first) with up to three rating columns,
-- drawn with the overlay's own skin, panel and text styling.

local PREVIEW_NAME_W, PREVIEW_COL_W, PREVIEW_ROW_H = 112, 52, 20

local function PreviewCharacters()
    local cm = PVPHUB_SETTINGS.compactMode
    local list = {}
    local function add(key)
        local data = PVPHUB_DB[key]
        if data and not IsCharacterHidden(key) then
            list[#list + 1] = { key = key, data = data }
        end
    end
    for _, key in ipairs(cm.selectedChars) do add(key) end
    for key, pins in pairs(cm.pinnedSpecs or {}) do
        if next(pins) then add(key) end
    end
    local current = GetFullName()
    if #list == 0 and current then add(current) end
    table.sort(list, function(a, b)
        if (a.key == current) ~= (b.key == current) then return a.key == current end
        local ra, rb = BestRating(a.data), BestRating(b.data)
        if ra ~= rb then return ra > rb end
        return a.key < b.key
    end)
    while #list > 2 do table.remove(list) end
    return list
end

local function CreatePreview(parent)
    local p = CreateFrame("Frame", nil, parent)
    p.fill = PVPHUB.UI.CreatePanel(p, "fill", "BACKGROUND", 0, PANEL_CORNER)
    p.ring = PVPHUB.UI.CreatePanel(p, "ring", "BORDER", 0, PANEL_CORNER)
    local function Text()
        local fs = p:CreateFontString(nil, "OVERLAY")
        fs:SetFont(SET_FONT, 11, "")   -- until StyleCompactText sets the overlay's
        fs:SetWordWrap(false)
        return fs
    end
    p.headName = Text()
    p.headCols = { Text(), Text(), Text() }
    p.rows = {}
    for r = 1, 2 do
        local row = { cells = { Text(), Text(), Text() } }
        row.name = Text()
        p.rows[r] = row
    end
    return p
end

-- The overlay's rows as SpecPillItems takes them: each picked character
-- (its current spec) and each pinned spec
local function OverlayEntries()
    local cm = PVPHUB_SETTINGS.compactMode
    local entries = {}
    for _, key in ipairs(cm.selectedChars) do
        if PVPHUB_DB[key] and not IsCharacterHidden(key) then
            entries[#entries + 1] = { char = key, data = PVPHUB_DB[key] }
        end
    end
    for key, pins in pairs(cm.pinnedSpecs or {}) do
        if PVPHUB_DB[key] and not IsCharacterHidden(key) then
            for specID in pairs(pins) do
                entries[#entries + 1] = { char = key, data = PVPHUB_DB[key], pinnedSpecID = specID }
            end
        end
    end
    return entries
end

-- The Minimal skin's preview: its top two pills
local function PaintPillPreview(p)
    p.headName:Hide()
    for _, fs in ipairs(p.headCols) do fs:Hide() end
    for _, row in ipairs(p.rows) do
        row.name:Hide()
        for _, fs in ipairs(row.cells) do fs:Hide() end
    end
    PaintSkinPanel(p.fill, p.ring)   -- hides the panel

    local items = SpecPillItems(OverlayEntries())
    while #items > 2 do table.remove(items) end
    local width, height = LayoutSpecPills(p, p.pills, items)
    if #items == 0 then
        StyleCompactText(p.headName, 11)
        p.headName:ClearAllPoints()
        p.headName:SetPoint("CENTER")
        p.headName:SetWidth(0)
        p.headName:SetText("No rated specs on the overlay yet")
        p.headName:SetTextColor(unpack(HEADER_TEXT))
        p.headName:Show()
        width, height = 200, 20
    end
    p:SetSize(width, height)
end

local function PaintPreview(p)
    p.pills = p.pills or {}
    if CompactSkin() == "minimal" then
        PaintPillPreview(p)
        return
    end
    for _, pill in ipairs(p.pills) do pill:Hide() end

    local cols = {}
    local showRatings = PVPHUB_SETTINGS.compactMode.showRatings
    for _, bracket in ipairs(COMPACT_BRACKET_ORDER) do
        if showRatings[bracket.key] and #cols < 3 then cols[#cols + 1] = bracket end
    end
    local chars = PreviewCharacters()
    local width = 10 + PREVIEW_NAME_W + #cols * PREVIEW_COL_W + 10
    p:SetSize(width, 12 + PREVIEW_ROW_H * (1 + #chars))
    PaintSkinPanel(p.fill, p.ring)

    local function Line(fs, size, x, rowIndex, w, justify)
        StyleCompactText(fs, size)
        fs:ClearAllPoints()
        fs:SetPoint("LEFT", p, "TOPLEFT", x, -6 - PREVIEW_ROW_H * rowIndex - PREVIEW_ROW_H / 2)
        fs:SetWidth(w)
        fs:SetJustifyH(justify)
        fs:Show()
    end
    local function ColumnX(i) return 10 + PREVIEW_NAME_W + (i - 1) * PREVIEW_COL_W end

    Line(p.headName, 10, 13, 0, PREVIEW_NAME_W - 8, "LEFT")
    p.headName:SetText("Character")
    p.headName:SetTextColor(unpack(HEADER_TEXT))
    for i, fs in ipairs(p.headCols) do
        local bracket = cols[i]
        if bracket then
            Line(fs, 10, ColumnX(i), 0, PREVIEW_COL_W - 8, "RIGHT")
            fs:SetText(bracket.name)
            fs:SetTextColor(unpack(HEADER_TEXT))
        else
            fs:Hide()
        end
    end

    for r, row in ipairs(p.rows) do
        local entry = chars[r]
        local shown = entry ~= nil
        row.name:SetShown(shown)
        if shown then
            Line(row.name, 11, 13, r, PREVIEW_NAME_W - 8, "LEFT")
            -- With the logged-in character's green dot, as on the overlay
            row.name:SetText(CreateCharacterName({ char = entry.key, data = entry.data }, true))
        end
        for i, fs in ipairs(row.cells) do
            local bracket = shown and cols[i]
            if bracket then
                Line(fs, 11, ColumnX(i), r, PREVIEW_COL_W - 8, "RIGHT")
                fs:SetText(RatingText((GetShuffleDisplayInfo(entry.data, entry.key, bracket.key))))
            else
                fs:Hide()
            end
        end
    end
end

local function BuildAppearancePage(f, page, width)
    local UI = PVPHUB.UI
    local cm = PVPHUB_SETTINGS.compactMode

    -- The preview on a grey stand-in for the game behind the overlay
    local stage = CreateFrame("Frame", nil, page)
    stage:SetPoint("TOPLEFT", page, "TOPLEFT", 0, 0)
    stage:SetSize(width, 112)
    UI.CreatePanel(stage, "fill", "BACKGROUND", 0, 10):SetVertexColor(0.25, 0.27, 0.32, 1)
    local preview = CreatePreview(stage)
    preview:SetPoint("CENTER")
    local caption = SettingsText(page, 11, SET_MUTED)
    caption:SetPoint("TOP", stage, "BOTTOM", 0, -5)
    caption:SetText("Live preview")

    -- Skin
    local skinLabel = SettingsText(page, 12, SET_MUTED)
    skinLabel:SetPoint("TOPLEFT", stage, "BOTTOMLEFT", 0, -28)
    skinLabel:SetText("Skin")
    local picker = CreateSkinPicker(page)
    picker:SetPoint("TOPLEFT", skinLabel, "BOTTOMLEFT", -2, -6)
    f.skinPicker = picker

    -- Background color, while the skin has a background
    local bgLabel = SettingsText(page, 12, SET_MUTED)
    bgLabel:SetPoint("TOPLEFT", picker, "BOTTOMLEFT", 2, -18)
    bgLabel:SetText("Background")
    local bgRow = CreateFrame("Frame", nil, page)
    bgRow:SetPoint("TOPLEFT", bgLabel, "BOTTOMLEFT", 0, -6)
    bgRow:SetSize(width, 28)
    local swatch = CreateFrame("Button", nil, bgRow)
    swatch:SetSize(28, 28)
    swatch:SetPoint("LEFT")
    swatch.fill = UI.CreatePanel(swatch, "fill", "ARTWORK", 0, 6)
    swatch.ring = UI.CreatePanel(swatch, "ring", "OVERLAY", 0, 6)
    swatch.ring:SetVertexColor(1, 1, 1, 0.35)
    local pick = CreateFrame("Button", nil, bgRow, "UIPanelButtonTemplate")
    pick:SetSize(116, 26)
    pick:SetPoint("LEFT", swatch, "RIGHT", 10, 0)
    pick:SetText("Pick color")
    UI.SkinButton(pick)
    local alphaText = SettingsText(bgRow, 12, SET_MUTED)
    alphaText:SetPoint("LEFT", pick, "RIGHT", 12, 0)
    local noBackground = SettingsText(page, 12, SET_MUTED)
    noBackground:SetPoint("LEFT", bgRow, "LEFT", 0, 0)
    noBackground:SetText("The None skin has no background to color.")

    local function OpenColorPicker()
        local c = cm.backgroundColor
        local function Apply(r, g, b, a)
            cm.backgroundColor = { r, g, b, a }
            PaintCompactShell()
            -- The Minimal skin's pills are filled with it too
            local cw = PVPHUB.compactWindow
            for _, pill in ipairs(cw and cw.pillPool or {}) do
                pill.fill:SetVertexColor(r, g, b, a or 0.8)
            end
            page.Refresh()
        end
        local function FromPicker()
            local r, g, b = ColorPickerFrame:GetColorRGB()
            Apply(r, g, b, ColorPickerFrame:GetColorAlpha())
        end
        ColorPickerFrame:SetupColorPickerAndShow({
            swatchFunc = FromPicker,
            opacityFunc = FromPicker,
            cancelFunc = function(prev)
                if prev then Apply(prev.r, prev.g, prev.b, prev.a) end
            end,
            hasOpacity = true, opacity = c[4],
            r = c[1], g = c[2], b = c[3],
        })
    end
    swatch:SetScript("OnClick", OpenColorPicker)
    pick:SetScript("OnClick", OpenColorPicker)

    -- Font and size, side by side
    local fontLabel = SettingsText(page, 12, SET_MUTED)
    fontLabel:SetPoint("TOPLEFT", bgRow, "BOTTOMLEFT", 0, -24)
    fontLabel:SetText("Font")
    local fonts = CompactFontList()
    local fontDrop = PVPHUB_CreateFontPicker(page, fontLabel, "BOTTOMLEFT", -16, -2, 220,
        function() return cm.selectedFont end,
        function(name)
            cm.selectedFont = name
            PVPHUB.compactCurrentFontPath = ResolveCompactFont(name) or FALLBACK_FONT
            if PVPHUB.compactWindow and PVPHUB.compactWindow:IsShown() then
                PVPHUB:UpdateCompactWindow()
            end
            page.Refresh()
        end,
        function() return fonts end)
    ApplyModernDropdownStyling(fontDrop)
    f.compactFontDropdown = fontDrop

    local sizeLabel = SettingsText(page, 12, SET_MUTED)
    sizeLabel:SetPoint("TOPLEFT", fontLabel, "TOPLEFT", 240, 0)
    local slider = CreateFrame("Slider", nil, page, "MinimalSliderTemplate")
    slider:SetPoint("TOPLEFT", sizeLabel, "BOTTOMLEFT", 2, -16)
    slider:SetSize(186, 12)
    slider:SetMinMaxValues(1.0, 2.0)
    slider:SetValueStep(0.01)
    slider:SetObeyStepOnDrag(true)
    slider:SetValue(PVPHUB_SETTINGS.compactWindowScale)
    sizeLabel:SetText(string.format("Size  |cffffffff%d%%|r", PVPHUB_SETTINGS.compactWindowScale * 100))
    slider:SetScript("OnValueChanged", function(_, val)
        if not val then return end
        PVPHUB_SETTINGS.compactWindowScale = val
        sizeLabel:SetText(string.format("Size  |cffffffff%d%%|r", val * 100))
        local cw = PVPHUB.compactWindow
        if cw then
            cw:SetScale(val)
            PlaceToolbar()
            if cw.scaleSlider then cw.scaleSlider:SetValue(val) end
            if cw.scaleLabel then cw.scaleLabel:SetText(string.format("%d%%", val * 100)) end
        end
    end)
    UI.SkinSlider(slider)

    function page.Refresh()
        picker.Paint()
        local c = cm.backgroundColor
        swatch.fill:SetVertexColor(c[1], c[2], c[3], 1)
        alphaText:SetText(string.format("%d%% opacity", math.floor((c[4] or 0.8) * 100 + 0.5)))
        local bare = CompactSkin() == "none"
        bgRow:SetShown(not bare)
        noBackground:SetShown(bare)
        slider:SetValue(PVPHUB_SETTINGS.compactWindowScale)
        UIDropDownMenu_SetText(fontDrop, cm.selectedFont)
        PaintPreview(preview)
    end
    picker.onChange = page.Refresh
end

-- --------------------------------------------------------------------------
-- Characters page
-- --------------------------------------------------------------------------
-- Every character with a switch for the overlay. A character with a rated
-- spec lists those specs under it, each with its own switch (pinned specs,
-- see PromoteToMultiSpecIfNeeded); one without shows as a single row that
-- follows its current spec. Rows are pooled.

local function CharacterRow(parent)
    local r = CreateFrame("Button", nil, parent)
    r.hl = r:CreateTexture(nil, "HIGHLIGHT")
    r.hl:SetAllPoints()
    r.hl:SetColorTexture(1, 1, 1, 0.03)
    r.icon = r:CreateTexture(nil, "ARTWORK")
    r.icon:SetSize(18, 18)
    r.icon:SetPoint("LEFT", r, "LEFT", 26, 0)
    r.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    r.name = SettingsText(r, 13)
    r.sub = SettingsText(r, 11, SET_MUTED)
    r.sub:SetPoint("LEFT", r.name, "RIGHT", 8, -1)
    r.switch = SettingsSwitch(r, function(on)
        if r.onToggle then r.onToggle(on) end
    end)
    r.switch:SetPoint("RIGHT", r, "RIGHT", -6, 0)
    r.rating = SettingsText(r, 12)
    r.rating:SetJustifyH("RIGHT")
    r.rating:SetPoint("RIGHT", r, "RIGHT", -48, 0)
    r.line = r:CreateTexture(nil, "BACKGROUND")
    r.line:SetColorTexture(1, 1, 1, 0.06)
    r.line:SetHeight(1)
    r.line:SetPoint("BOTTOMLEFT")
    r.line:SetPoint("BOTTOMRIGHT")
    r:SetScript("OnClick", function(self)
        if self.switch:IsShown() then self.switch:Click() end
    end)
    return r
end

-- kind: "char" (a switch), "head" (a character with spec rows, no switch)
-- or "spec" (indented, with the spec's icon). Character names are in their
-- class color.
local function PaintCharacterRow(r, kind, color, name, sub, rating)
    r.icon:SetShown(kind == "spec")
    r.switch:SetShown(kind ~= "head")
    r.hl:SetAlpha(kind == "head" and 0 or 1)
    r.name:ClearAllPoints()
    if kind == "spec" then
        r.name:SetPoint("LEFT", r.icon, "RIGHT", 8, 0)
        r.name:SetFont(SET_FONT, 12, "")
        r.name:SetTextColor(unpack(SET_TEXT))
    else
        r.name:SetPoint("LEFT", r, "LEFT", 6, 0)
        r.name:SetFont(SET_FONT, 13, "")
        r.name:SetTextColor(color and color.r or 0.9, color and color.g or 0.9, color and color.b or 0.9)
    end
    r.name:SetText(name)
    r.sub:SetText(sub or "")
    r.rating:SetText(rating or "")
end

local function BuildCharactersPage(f, page, width)
    local cm = PVPHUB_SETTINGS.compactMode
    local listW = width - 14   -- the scroll bar's room

    local search = CreateFrame("EditBox", nil, page, "SearchBoxTemplate")
    search:SetSize(250, 26)
    search:SetPoint("TOPLEFT", page, "TOPLEFT", 6, 0)
    search:SetAutoFocus(false)
    search:SetMaxLetters(40)
    if search.Instructions then search.Instructions:SetText("Search characters") end
    local count = SettingsText(page, 12, SET_MUTED)
    count:SetPoint("RIGHT", page, "TOPRIGHT", 0, -13)
    count:SetJustifyH("RIGHT")

    local hideRow = OptionRow(page, width, "Hide characters without a rating", nil, function(on)
        cm.hideNoRating = on
        if on then
            local sel = cm.selectedChars
            for i = #sel, 1, -1 do
                if not compactHasAnyRating(PVPHUB_DB and PVPHUB_DB[sel[i]]) then
                    table.remove(sel, i)
                end
            end
        end
        page.Refresh()
        if PVPHUB.compactWindow and PVPHUB.compactWindow:IsShown() then PVPHUB:UpdateCompactWindow() end
    end)
    hideRow:SetPoint("TOPLEFT", page, "TOPLEFT", 0, -34)
    f.hideNoRatingCheckbox = hideRow.switch

    local scroll = CreateFrame("ScrollFrame", nil, page, "ScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", hideRow, "BOTTOMLEFT", 0, -6)
    scroll:SetPoint("BOTTOMRIGHT", page, "BOTTOMRIGHT", -14, 0)
    ApplyModernScrollbarStyling(scroll, UI_CONSTANTS.COLORS)
    PVPHUB.EnableSmoothScroll(scroll, 40)
    local list = CreateFrame("Frame", nil, scroll)
    list:SetSize(listW, 10)
    scroll:SetScrollChild(list)
    f.charScrollFrame = scroll

    local empty = SettingsText(list, 12, SET_MUTED)
    empty:SetPoint("TOPLEFT", list, "TOPLEFT", 4, -12)

    local rows = {}

    function page.Refresh()
        MigratePinnedSpecsSchema()
        cm.pinnedSpecs = cm.pinnedSpecs or {}
        local current = GetFullName()
        if current and current ~= "" then
            PVPHUB_DB[current] = PVPHUB_DB[current] or {}
            local own = PVPHUB_DB[current]
            if not own.class then
                own.class = select(2, UnitClass("player"))
                own.race = select(2, UnitRace("player"))
                own.gender = UnitSex("player")
            end
        end

        local query = (search:GetText() or ""):lower()
        local total, onOverlay, keys = 0, 0, {}
        for key, data in pairs(PVPHUB_DB) do
            if type(data) == "table" and key:find("-", 1, true) and not IsCharacterHidden(key)
               and (not cm.hideNoRating or compactHasAnyRating(data)) then
                -- Settings can open before the overlay ever updated, so
                -- characters graduate to spec rows here too
                PromoteToMultiSpecIfNeeded(key, data)
                total = total + 1
                if IsOnOverlay(key) then onOverlay = onOverlay + 1 end
                if query == "" or key:lower():find(query, 1, true) then
                    keys[#keys + 1] = key
                end
            end
        end
        table.sort(keys)
        count:SetText(string.format("%d of %d on the overlay", onOverlay, total))

        local n, y = 0, 0
        local function NextRow(kind)
            n = n + 1
            local r = rows[n] or CharacterRow(list)
            rows[n] = r
            r:ClearAllPoints()
            r:SetPoint("TOPLEFT", list, "TOPLEFT", 0, -y)
            r:SetSize(listW, kind == "spec" and SPEC_ROW_H or CHAR_ROW_H)
            y = y + r:GetHeight()
            r:Show()
            return r
        end

        for _, key in ipairs(keys) do
            local data = PVPHUB_DB[key]
            if key == current then data.class = select(2, UnitClass("player")) end
            local color = RAID_CLASS_COLORS[data.class or ""]
            local name = key:match("^(.-)%-") or key
            local realm = key:match("%-(.+)$") or ""
            -- The logged-in character's green dot, as on the overlay
            if key == current then name = name .. " |TInterface\\Common\\Indicator-Green:12|t" end

            if GetDistinctRatedSpecCount(data) < 1 then
                -- No rated spec yet: one switch, the row follows the
                -- current spec
                local r = NextRow("char")
                PaintCharacterRow(r, "char", color, name, realm, RatingText(BestRating(data)))
                local selected = false
                for _, k in ipairs(cm.selectedChars) do
                    if k == key then selected = true; break end
                end
                r.switch:SetChecked(selected)
                r.line:Show()
                r.onToggle = function(on)
                    PVPHUB:ToggleCompactCharacter(key, on)
                    page.Refresh()
                end
            else
                local head = NextRow("head")
                PaintCharacterRow(head, "head", color, name, realm, nil)
                head.line:Hide()
                head.onToggle = nil

                -- Every spec that has earned a rating in Shuffle or Blitz,
                -- best first
                local specs, bySpec = {}, {}
                for _, bracketKey in ipairs({ "ratingShuffle", "ratingBlitz" }) do
                    local bracketData = data[bracketKey]
                    if type(bracketData) == "table" then
                        for specID, rating in pairs(bracketData) do
                            if rating and rating > 0 then
                                if not bySpec[specID] then
                                    bySpec[specID] = { specID = specID, best = rating }
                                    specs[#specs + 1] = bySpec[specID]
                                elseif rating > bySpec[specID].best then
                                    bySpec[specID].best = rating
                                end
                            end
                        end
                    end
                end
                table.sort(specs, function(a, b) return a.best > b.best end)
                head.rating:SetText(string.format("|cff9a97a6%d %s|r", #specs, #specs == 1 and "spec" or "specs"))

                local currentSpec = data.specID or data.lastActiveSpecID
                local pins = cm.pinnedSpecs[key]
                for i, spec in ipairs(specs) do
                    local r = NextRow("spec")
                    local info = GetCachedSpecInfo(spec.specID)
                    r.icon:SetTexture(info and info.icon or "Interface\\Icons\\INV_Misc_QuestionMark")
                    local specName = info and info.name or "Spec"
                    -- Only the logged-in character's spec: the others' last
                    -- spec isn't "online"
                    if key == current and spec.specID == currentSpec then
                        specName = specName .. " |TInterface\\Common\\Indicator-Green:10|t"
                    end
                    PaintCharacterRow(r, "spec", color, specName, nil, RatingText(spec.best))
                    r.switch:SetChecked(pins and pins[spec.specID] and true or false)
                    r.line:SetShown(i == #specs)
                    r.onToggle = function(on)
                        cm.pinnedSpecs[key] = cm.pinnedSpecs[key] or {}
                        cm.pinnedSpecs[key][spec.specID] = on or nil
                        if PVPHUB.compactWindow and PVPHUB.compactWindow:IsShown() then
                            PVPHUB:UpdateCompactWindow()
                        end
                        page.Refresh()
                    end
                end
            end
        end
        for i = n + 1, #rows do
            rows[i]:Hide()
            rows[i].onToggle = nil
        end
        list:SetHeight(math.max(y, 1))

        empty:SetShown(#keys == 0)
        empty:SetText(query ~= "" and "No characters match"
            or "No characters found. Log in with each character and open PVPHUB.")
        hideRow.switch:SetChecked(cm.hideNoRating or false)
    end

    search:HookScript("OnTextChanged", function() page.Refresh() end)
end

-- --------------------------------------------------------------------------
-- Brackets and Behavior pages
-- --------------------------------------------------------------------------

local function PaintBracketTile(t)
    local on = PVPHUB_SETTINGS.compactMode.showRatings[t.key] and true or false
    local hover = t:IsMouseOver()
    if on then
        local c = PVPHUB.UI.ThemeColor()
        t.fill:SetVertexColor(c[1], c[2], c[3], hover and 0.24 or 0.16)
        t.ring:SetVertexColor(c[1], c[2], c[3], 0.9)
    else
        t.fill:SetVertexColor(1, 1, 1, hover and 0.06 or 0.03)
        t.ring:SetVertexColor(1, 1, 1, hover and 0.25 or 0.1)
    end
    t.icon:SetDesaturated(not on)
    t.icon:SetAlpha(on and 1 or 0.6)
    local tc = on and 1 or 0.65
    t.label:SetTextColor(tc, tc, tc)
    t.state:SetText(on and "Shown" or "Hidden")
end

local function BuildBracketsPage(page, width)
    local UI = PVPHUB.UI
    local caption = SettingsText(page, 12, SET_MUTED)
    caption:SetPoint("TOPLEFT", page, "TOPLEFT", 0, -2)
    caption:SetText("Columns on the overlay")

    local gap, tileH = 10, 64
    local tileW = math.floor((width - gap * 2) / 3)
    local tiles = {}
    for i, bracket in ipairs(BRACKET_TILES) do
        local t = CreateFrame("Button", nil, page)
        t:SetSize(tileW, tileH)
        local col, row = (i - 1) % 3, math.floor((i - 1) / 3)
        t:SetPoint("TOPLEFT", caption, "BOTTOMLEFT", col * (tileW + gap), -10 - row * (tileH + gap))
        t.key = bracket.key
        t.fill = UI.CreatePanel(t, "fill", "BACKGROUND", 0, 8)
        t.ring = UI.CreatePanel(t, "ring", "BORDER", 0, 8)
        t.icon = t:CreateTexture(nil, "ARTWORK")
        t.icon:SetSize(26, 26)
        t.icon:SetPoint("LEFT", t, "LEFT", 12, 0)
        t.icon:SetTexture(bracket.icon)
        t.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        t.label = SettingsText(t, 13)
        t.label:SetPoint("TOPLEFT", t.icon, "TOPRIGHT", 10, 0)
        t.label:SetText(bracket.name)
        t.state = SettingsText(t, 11, SET_MUTED)
        t.state:SetPoint("TOPLEFT", t.label, "BOTTOMLEFT", 0, -4)
        t:SetScript("OnClick", function(self)
            PVPHUB:ToggleCompactRating(self.key, not PVPHUB_SETTINGS.compactMode.showRatings[self.key])
            PaintBracketTile(self)
        end)
        t:SetScript("OnEnter", PaintBracketTile)
        t:SetScript("OnLeave", PaintBracketTile)
        tiles[i] = t
    end

    local hint = SettingsText(page, 11, SET_MUTED)
    hint:SetPoint("TOPLEFT", caption, "BOTTOMLEFT", 0, -10 - 2 * (tileH + gap) - 6)
    hint:SetText("They show in this order. Sort the overlay from its toolbar.")

    function page.Refresh()
        for _, t in ipairs(tiles) do PaintBracketTile(t) end
    end
end

local function BuildBehaviorPage(f, page, width)
    local cm = PVPHUB_SETTINGS.compactMode
    local pvpRow = OptionRow(page, width, "Auto-hide in PvP",
        "Hidden during arenas and battlegrounds, back afterwards.", function(on)
        cm.hideInPvP = on
        C_Timer.After(0.1, function()
            if on and IsInActivePvP() and PVPHUB.compactWindow and PVPHUB.compactWindow:IsShown() then
                PVPHUB._compactWindowWasOpenBeforePvP = true
                PVPHUB.compactWindow:Hide()
            elseif not on and PVPHUB._compactWindowWasOpenBeforePvP then
                PVPHUB:CreateCompactWindow()
            end
            f.SyncOverlaySwitch()
        end)
    end)
    pvpRow:SetPoint("TOPLEFT", page, "TOPLEFT", 0, 0)

    local namesRow = OptionRow(page, width, "Hide server names",
        "Only the character's name, without its realm.", function(on)
        cm.hideServerNames = on
        if PVPHUB.compactWindow then PVPHUB:UpdateCompactWindow() end
    end)
    namesRow:SetPoint("TOPLEFT", pvpRow, "BOTTOMLEFT", 0, 0)

    f.hideInPvPCheckbox = pvpRow.switch
    f.hideServerNamesCheckbox = namesRow.switch

    function page.Refresh()
        pvpRow.switch:SetChecked(cm.hideInPvP or false)
        namesRow.switch:SetChecked(cm.hideServerNames or false)
    end
end

-- --------------------------------------------------------------------------
-- The window
-- --------------------------------------------------------------------------

local function BuildCompactSettings()
    local UI = PVPHUB.UI
    local cm = PVPHUB_SETTINGS.compactMode
    cm.backgroundColor = cm.backgroundColor or { 0.1, 0.1, 0.1, 0.8 }
    cm.selectedFont = cm.selectedFont or "Friz Quadrata TT"
    PVPHUB.compactCurrentFontPath = ResolveCompactFont(cm.selectedFont) or FALLBACK_FONT
    PVPHUB_SETTINGS.compactWindowScale = math.max(1.0, math.min(2.0, PVPHUB_SETTINGS.compactWindowScale or 1.0))

    -- Named uniquely per build: a theme change tears this window down and
    -- builds it again (RefreshCompactTheme), and reusing a global frame
    -- name for a second CreateFrame is unreliable.
    PVPHUB._compactSettingsSeq = (PVPHUB._compactSettingsSeq or 0) + 1
    local frameName = "PVPHUBCompactSettings" .. PVPHUB._compactSettingsSeq
    local f = CreateFrame("Frame", frameName, UIParent)
    f:SetFrameStrata("DIALOG")
    f:SetSize(SET_W, SET_H)
    f:SetPoint("CENTER")
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetClampedToScreen(true)
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    table.insert(UISpecialFrames, frameName)
    UI.SkinWindow(f)

    -- Header: title, the overlay's on/off switch, close
    f.title = f:CreateFontString(nil, "OVERLAY")
    f.title:SetFont("Interface\\AddOns\\PVPHUB\\media\\fonts\\Prototype.ttf", 18, "")
    f.title:SetPoint("LEFT", f, "TOPLEFT", SET_PAD, -SET_HEADER_H / 2)
    f.title:SetText("Streamer Mode")
    f.title:SetTextColor(unpack(UI_CONSTANTS.COLORS.TITLE_COLOR))
    local brand = SettingsText(f, 12, SET_MUTED)
    brand:SetPoint("LEFT", f.title, "RIGHT", 8, -1)
    brand:SetText("PVPHUB")

    local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    close:SetSize(26, 26)
    close:SetPoint("RIGHT", f, "TOPRIGHT", -14, -SET_HEADER_H / 2)
    close:SetScript("OnClick", function()
        if PVPHUB.compactWindow and PVPHUB.compactWindow:IsShown() then
            PVPHUB:UpdateCompactWindow()
        end
        f:Hide()
    end)
    UI.SkinCloseButton(close)

    f.overlaySwitch = SettingsSwitch(f, function(on)
        if on then
            PVPHUB:CreateCompactWindow()
        elseif PVPHUB.compactWindow then
            PVPHUB_SETTINGS.compactWindowStayOpen = false
            PVPHUB.compactWindow:Hide()
        end
        f.SyncOverlaySwitch()
    end)
    f.overlaySwitch:SetPoint("RIGHT", close, "LEFT", -16, 0)
    local overlayLabel = SettingsText(f, 12, SET_MUTED)
    overlayLabel:SetPoint("RIGHT", f.overlaySwitch, "LEFT", -8, 0)
    overlayLabel:SetText("Overlay shown")

    -- The switch follows the overlay, also when it's closed from its own
    -- toolbar (RefreshSettingsToggle) or kept hidden in PvP
    function f.SyncOverlaySwitch()
        local cw = PVPHUB.compactWindow
        f.overlaySwitch:SetChecked(cw and cw:IsShown() or false)
        if cw then cw.RefreshSettingsToggle = f.SyncOverlaySwitch end
    end

    local headLine = f:CreateTexture(nil, "ARTWORK")
    headLine:SetColorTexture(1, 1, 1, 0.07)
    headLine:SetHeight(1)
    headLine:SetPoint("TOPLEFT", f, "TOPLEFT", 1, -SET_HEADER_H)
    headLine:SetPoint("TOPRIGHT", f, "TOPRIGHT", -1, -SET_HEADER_H)
    local sideLine = f:CreateTexture(nil, "ARTWORK")
    sideLine:SetColorTexture(1, 1, 1, 0.07)
    sideLine:SetWidth(1)
    sideLine:SetPoint("TOPLEFT", f, "TOPLEFT", SET_SIDEBAR_W, -SET_HEADER_H)
    sideLine:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", SET_SIDEBAR_W, 1)

    -- Sidebar and pages
    f.pages, f.nav = {}, {}
    for i, info in ipairs(SETTINGS_PAGES) do
        local b = NavButton(f, info.label, info.icon)
        b:SetPoint("TOPLEFT", f, "TOPLEFT", 12, -(SET_HEADER_H + 12 + (i - 1) * 38))
        b:SetScript("OnClick", function() f.ShowPage(info.key) end)
        f.nav[info.key] = b
        local page = CreateFrame("Frame", nil, f)
        page:SetPoint("TOPLEFT", f, "TOPLEFT", SET_SIDEBAR_W + SET_PAD, -(SET_HEADER_H + 16))
        page:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -SET_PAD, 16)
        page:Hide()
        f.pages[info.key] = page
    end
    local openMain = NavButton(f, "Open PVPHUB", "Interface\\AddOns\\PVPHUB\\media\\PVPHUB.png")
    openMain.icon:SetTexCoord(0, 1, 0, 1)
    openMain:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 12, 12)
    openMain:SetScript("OnClick", function() SlashCmdList["PVPHUB"]("") end)

    local pageW = SET_W - SET_SIDEBAR_W - SET_PAD * 2
    BuildAppearancePage(f, f.pages.appearance, pageW)
    BuildCharactersPage(f, f.pages.characters, pageW)
    BuildBracketsPage(f.pages.brackets, pageW)
    BuildBehaviorPage(f, f.pages.behavior, pageW)

    function f.ShowPage(key)
        if not f.pages[key] then key = "appearance" end
        PVPHUB_SETTINGS.compactSettingsPage = key
        for k, page in pairs(f.pages) do page:SetShown(k == key) end
        for k, b in pairs(f.nav) do
            b.selected = (k == key)
            PaintNavButton(b)
        end
        f.pages[key].Refresh()
    end
    function f:RefreshCharacterList() self.pages.characters.Refresh() end
    return f
end

function PVPHUB:ShowCompactSettings()
    PVPHUB:EnsureCompactModeDefaults()
    local w = PVPHUB.compactSettingsWindow
    if w and w:IsShown() then
        w:Hide()
        return
    end
    if not w then
        w = BuildCompactSettings()
        PVPHUB.compactSettingsWindow = w
    end
    w.SyncOverlaySwitch()
    w.ShowPage(PVPHUB_SETTINGS.compactSettingsPage or "appearance")
    w:Show()
end

-- CreateFrame with a name string always registers that name in _G. Named
-- children (e.g. the font picker built by PVPHUB_CreateFontPicker, which
-- needs a real global name for its UIDropDownMenuTemplate to resolve) leak
-- just as permanently as the top-level frame unless their names are cleared
-- too, so walk the whole subtree instead of only the frame passed in.
local function ClearNamedGlobalsRecursive(frame)
    if not frame or not frame.GetName then return end
    local name = frame:GetName()
    if name then _G[name] = nil end
    if frame.GetChildren then
        for _, child in ipairs({ frame:GetChildren() }) do
            ClearNamedGlobalsRecursive(child)
        end
    end
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
        -- Deliberately NOT removing this frame's name from UISpecialFrames here.
        -- UISpecialFrames is a shared Blizzard table, and repeatedly
        -- table.remove()-ing from it at runtime (shifting every later index)
        -- taints it — Blizzard's own Escape-key handling then throws "attempted
        -- to iterate a table that cannot be accessed while tainted" the next
        -- time it needs to walk the list. A stale leftover name is harmless:
        -- ClearNamedGlobalsRecursive (below) nils out _G[name], and Blizzard's
        -- iteration already skips any entry whose global no longer resolves.
        PVPHUB.compactSettingsWindow:Hide()
        -- Clear this frame's and every named descendant's _G entry (e.g. the
        -- font picker) before dropping our own reference — otherwise each
        -- theme switch permanently leaks the whole tree, reachable forever
        -- via those globals even after SetParent(nil).
        ClearNamedGlobalsRecursive(PVPHUB.compactSettingsWindow)
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
