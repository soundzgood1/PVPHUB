local _, PVPHUB = ...

-- Local aliases for helpers defined in PVPHUB_core.lua.
local UI_CONSTANTS      = PVPHUB._UI_CONSTANTS

-- Welcome Popup Functions
function PVPHUB:ShowWelcomePopup()
    if PVPHUB.welcomeWindow then
        PVPHUB.welcomeWindow:Show()
        return
    end

    -- Mark seen the moment it's shown, not on a particular dismissal path.
    -- This used to only get set from the "Don't show again" checkbox below,
    -- so anyone who just clicked "Let's Go!" (i.e. almost everyone) kept
    -- welcomeShown false forever — leaving them eligible to see this again
    -- on a later login, at which point whatever version bump had happened
    -- in between made the update popup fire too, showing both back to back.
    PVPHUB_SETTINGS.welcomeShown = true

    local f = CreateFrame("Frame", "PVPHUBWelcomeWindow", UIParent, "BackdropTemplate")
    -- FULLSCREEN_DIALOG (not just HIGH, same as the main window) so this
    -- always draws above the main window's content regardless of internal
    -- frame levels (e.g. the Settings tab's collapsible section cards,
    -- which carry their own levels to stack header-over-body) — strata
    -- always wins over level, level only matters within the same strata.
    f:SetFrameStrata("FULLSCREEN_DIALOG")
    f:SetSize(460, 400) -- height is a placeholder; recomputed from content at the end
    f:SetPoint("CENTER")
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetClampedToScreen(true)
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)

    f:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        tile = false,
        tileSize = 0,
        edgeSize = 2,
        insets = { left = 2, right = 2, top = 2, bottom = 2 }
    })
    f:SetBackdropColor(unpack(UI_CONSTANTS.COLORS.WINDOW_BG))
    f:SetBackdropBorderColor(unpack(UI_CONSTANTS.COLORS.WINDOW_BORDER))

    -- Glow is a touch brighter than the standard window glow (this is a
    -- one-time "welcome" moment, so it can afford to feel a bit more special).
    local glowFrame = CreateFrame("Frame", nil, f, "BackdropTemplate")
    glowFrame:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        tile = false,
        edgeSize = 10,
        insets = { left = -10, right = -10, top = -10, bottom = -10 }
    })
    glowFrame:SetBackdropColor(0, 0, 0, 0)
    glowFrame:SetBackdropBorderColor(unpack(UI_CONSTANTS.COLORS.WINDOW_GLOW))
    glowFrame:SetPoint("TOPLEFT", f, "TOPLEFT", -10, 10)
    glowFrame:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", 10, -10)
    glowFrame:SetFrameLevel(f:GetFrameLevel() - 1)

    -- Banner strip across the top — gives the header some presence instead of
    -- floating title text directly on the window background. SetGradient only
    -- interpolates linearly, which reads as a visible cutoff/hard edge, so
    -- this stacks three progressively softer gradient layers to approximate
    -- an eased fade — lower peak intensity, no hard block right at the top
    -- border, and a long gentle tail instead of one abrupt linear fade.
    local titleColor = UI_CONSTANTS.COLORS.TITLE_COLOR
    local bannerR, bannerG, bannerB = titleColor[1] * 0.22, titleColor[2] * 0.22, titleColor[3] * 0.22

    local banner1 = f:CreateTexture(nil, "ARTWORK")
    banner1:SetTexture("Interface\\Buttons\\WHITE8x8")
    banner1:SetGradient("VERTICAL",
        CreateColor(bannerR, bannerG, bannerB, 0.45),
        CreateColor(bannerR, bannerG, bannerB, 0.24))
    banner1:SetPoint("TOPLEFT", f, "TOPLEFT", 2, -2)
    banner1:SetPoint("TOPRIGHT", f, "TOPRIGHT", -2, -2)
    banner1:SetHeight(50)

    local banner2 = f:CreateTexture(nil, "ARTWORK")
    banner2:SetTexture("Interface\\Buttons\\WHITE8x8")
    banner2:SetGradient("VERTICAL",
        CreateColor(bannerR, bannerG, bannerB, 0.24),
        CreateColor(bannerR, bannerG, bannerB, 0.10))
    banner2:SetPoint("TOPLEFT", banner1, "BOTTOMLEFT", 0, 0)
    banner2:SetPoint("TOPRIGHT", banner1, "BOTTOMRIGHT", 0, 0)
    banner2:SetHeight(70)

    local banner3 = f:CreateTexture(nil, "ARTWORK")
    banner3:SetTexture("Interface\\Buttons\\WHITE8x8")
    banner3:SetGradient("VERTICAL",
        CreateColor(bannerR, bannerG, bannerB, 0.10),
        CreateColor(bannerR, bannerG, bannerB, 0))
    banner3:SetPoint("TOPLEFT", banner2, "BOTTOMLEFT", 0, 0)
    banner3:SetPoint("TOPRIGHT", banner2, "BOTTOMRIGHT", 0, 0)
    banner3:SetHeight(90)

    -- Logo
    local logo = f:CreateTexture(nil, "OVERLAY")
    logo:SetTexture("Interface\\AddOns\\PVPHUB\\media\\PVPHUB.png")
    logo:SetSize(48, 48)
    logo:SetPoint("TOP", 0, -20)

    -- Title
    local title = f:CreateFontString(nil, "OVERLAY")
    title:SetPoint("TOP", logo, "BOTTOM", 0, -8)
    title:SetFont("Fonts\\FRIZQT__.TTF", 22, "OUTLINE")
    title:SetText("Welcome to PVPHUB!")
    title:SetTextColor(unpack(UI_CONSTANTS.COLORS.TITLE_COLOR))

    -- Tagline
    local tagline = f:CreateFontString(nil, "OVERLAY")
    tagline:SetPoint("TOP", title, "BOTTOM", 0, -6)
    tagline:SetFont("Fonts\\FRIZQT__.TTF", 13)
    tagline:SetText("Your entire PvP career, one window. Here's what you get:")
    tagline:SetTextColor(unpack(UI_CONSTANTS.COLORS.HEADER_COLOR))

    local divider1 = f:CreateTexture(nil, "OVERLAY")
    divider1:SetColorTexture(unpack(UI_CONSTANTS.COLORS.ACCENT_LINE))
    divider1:SetSize(400, 1)
    divider1:SetPoint("TOP", tagline, "BOTTOM", 0, -14)

    -- Running distance from the frame's top edge, mirroring every offset used
    -- below. The window's final height is set from this at the end instead of
    -- being a fixed guess, so it always fits the actual feature-card content.
    local cursorY = 20 + 48 + 8 + title:GetStringHeight() + 6 + tagline:GetStringHeight() + 14 + 1

    -- Feature cards { title, desc, atlas, fallbackIcon, color } — same visual
    -- language as the "what's new" popup. atlas is a best-guess Blizzard atlas
    -- name for a sleeker flat icon; fallbackIcon (a known-good spell/item icon)
    -- is used automatically if that atlas doesn't actually exist — see the
    -- C_Texture.GetAtlasInfo check below. No atlas name here is verified
    -- in-game, so don't be surprised if some cards end up on their fallback.
    local features = {
        {
            title = "Every Bracket, At A Glance",
            desc  = "2v2, 3v3, Solo Shuffle & Blitz ratings for every character, in one place.",
            atlas = "honorsystem-icon-honor",
            fallbackIcon = "Interface\\Icons\\achievement_arena_2v2_1",
            color = { 0.85, 0.65, 0.15 },
        },
        {
            title = "Tracked Automatically",
            desc  = "Every alt on your account gets picked up the moment you log in — nothing to set up.",
            atlas = "groupfinder-icon-friends",
            fallbackIcon = "Interface\\Icons\\INV_Misc_GroupLooking",
            color = { 0.45, 0.65, 0.85 },
        },
        {
            title = "Live Queue Timer",
            desc  = "Always know exactly how long you've been waiting in queue.",
            atlas = "auctionhouse-icon-clock",
            fallbackIcon = "Interface\\Icons\\INV_Misc_PocketWatch_01",
            color = { 0.20, 0.65, 0.30 },
        },
        {
            title = "Streamer Mode",
            desc  = "A compact, movable overlay built for showing your ratings on stream.",
            atlas = "communities-icon-notification-clubs",
            fallbackIcon = "Interface\\Icons\\INV_Misc_Spyglass_03",
            color = { 0.55, 0.35, 0.85 },
        },
    }

    -- Fixed layout constants for each card, used both to build it and to
    -- compute how tall it needs to be.
    local ICON_LEFT, ICON_SIZE, ICON_GAP = 12, 34, 10
    local TEXT_LEFT = ICON_LEFT + ICON_SIZE + ICON_GAP
    local CARD_TOP_PAD, CARD_BOTTOM_PAD, TITLE_DESC_GAP = 8, 8, 4

    local lastAnchor = divider1
    local firstRow = true
    for _, entry in ipairs(features) do
        local row = CreateFrame("Frame", nil, f, "BackdropTemplate")
        row:SetWidth(400)
        local rowGap = firstRow and 14 or 10
        row:SetPoint("TOP", lastAnchor, "BOTTOM", 0, -rowGap)
        firstRow = false
        cursorY = cursorY + rowGap

        row:SetBackdrop({
            bgFile   = "Interface\\Buttons\\WHITE8x8",
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            tile = false, tileSize = 16, edgeSize = 8,
            insets = { left = 2, right = 2, top = 2, bottom = 2 },
        })
        row:SetBackdropColor(1, 1, 1, 0.05)
        row:SetBackdropBorderColor(entry.color[1], entry.color[2], entry.color[3], 0.4)

        local stripe = row:CreateTexture(nil, "ARTWORK")
        stripe:SetTexture("Interface\\Buttons\\WHITE8x8")
        stripe:SetVertexColor(entry.color[1], entry.color[2], entry.color[3], 0.9)
        stripe:SetPoint("TOPLEFT",    row, "TOPLEFT",    2, -2)
        stripe:SetPoint("BOTTOMLEFT", row, "BOTTOMLEFT", 2,  2)
        stripe:SetWidth(3)

        -- Icon badge — vertically centered in the row regardless of its final
        -- height, so it still looks right whether the card ends up short or tall.
        local iconBg = row:CreateTexture(nil, "ARTWORK")
        iconBg:SetTexture("Interface\\Buttons\\WHITE8x8")
        iconBg:SetVertexColor(entry.color[1] * 0.3, entry.color[2] * 0.3, entry.color[3] * 0.3, 0.7)
        iconBg:SetSize(ICON_SIZE, ICON_SIZE)
        iconBg:SetPoint("LEFT", row, "LEFT", ICON_LEFT, 0)

        local icon = row:CreateTexture(nil, "OVERLAY")
        icon:SetSize(24, 24)
        icon:SetPoint("CENTER", iconBg, "CENTER", 0, 0)
        -- Try the atlas first; C_Texture.GetAtlasInfo returns nil if the name
        -- doesn't exist, in which case fall back to the known-good icon so a
        -- bad guess never shows up as a blank texture.
        local atlasInfo = entry.atlas and C_Texture.GetAtlasInfo(entry.atlas)
        if atlasInfo then
            icon:SetAtlas(entry.atlas, false)
        else
            icon:SetTexture(entry.fallbackIcon)
            icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        end

        -- Text column anchors to the row's own top-left (not to iconBg) so its
        -- position never depends on the row's height — that height is what
        -- we're about to compute FROM the text, so the two can't depend on
        -- each other without a circular layout.
        local titleLabel = row:CreateFontString(nil, "OVERLAY")
        titleLabel:SetFont("Fonts\\FRIZQT__.TTF", 13, "OUTLINE")
        titleLabel:SetText(entry.title)
        titleLabel:SetTextColor(1, 1, 1, 1)
        titleLabel:SetPoint("TOPLEFT", row, "TOPLEFT", TEXT_LEFT, -CARD_TOP_PAD)

        local descLabel = row:CreateFontString(nil, "OVERLAY")
        descLabel:SetFont("Fonts\\FRIZQT__.TTF", 11)
        descLabel:SetTextColor(unpack(UI_CONSTANTS.COLORS.HEADER_COLOR))
        descLabel:SetJustifyH("LEFT")
        descLabel:SetWidth(330)
        descLabel:SetWordWrap(true)
        descLabel:SetPoint("TOPLEFT", titleLabel, "BOTTOMLEFT", 0, -TITLE_DESC_GAP)
        descLabel:SetText(entry.desc)

        -- Size the card to fit its own text, never smaller than the icon needs.
        local textHeight = CARD_TOP_PAD + titleLabel:GetStringHeight() + TITLE_DESC_GAP + descLabel:GetStringHeight() + CARD_BOTTOM_PAD
        local iconHeight = ICON_SIZE + 12
        local rowHeight = math.max(textHeight, iconHeight)
        row:SetHeight(rowHeight)
        cursorY = cursorY + rowHeight

        lastAnchor = row
    end

    local divider2 = f:CreateTexture(nil, "OVERLAY")
    divider2:SetColorTexture(unpack(UI_CONSTANTS.COLORS.ACCENT_LINE))
    divider2:SetSize(400, 1)
    divider2:SetPoint("TOP", lastAnchor, "BOTTOM", 0, -18)
    cursorY = cursorY + 18 + 1

    -- Friendly closing line above the CTA
    local closingLine = f:CreateFontString(nil, "OVERLAY")
    closingLine:SetPoint("TOP", divider2, "BOTTOM", 0, -12)
    closingLine:SetFont("Fonts\\FRIZQT__.TTF", 11)
    closingLine:SetText("That's it — no setup needed. Good luck out there!")
    closingLine:SetTextColor(unpack(UI_CONSTANTS.COLORS.SUMMARY_TEXT))
    cursorY = cursorY + 12 + closingLine:GetStringHeight()

    -- Open button (single CTA)
    local openMainBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    openMainBtn:SetSize(170, 32)
    openMainBtn:SetPoint("TOP", closingLine, "BOTTOM", 0, -18)
    openMainBtn:SetText("Let's Go!")
    openMainBtn:SetScript("OnClick", function()
        f:Hide()
        SlashCmdList["PVPHUB"]()
    end)
    f.openMainBtn = openMainBtn
    cursorY = cursorY + 18 + 32

    -- X close button — welcomeShown is already set to true above, so any
    -- dismissal path (this, or "Let's Go!") is equally final.
    local xCloseBtn = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    xCloseBtn:SetPoint("TOPRIGHT", -5, -5)
    xCloseBtn:SetScript("OnClick", function()
        f:Hide()
    end)
    if PVPHUB.UI then
        PVPHUB.UI.SkinButton(openMainBtn)
        PVPHUB.UI.SkinCloseButton(xCloseBtn)
    end

    -- Now that every element's actual size is known, size the window to fit
    -- it exactly instead of the earlier fixed guess.
    f:SetHeight(cursorY + 26)

    PVPHUB.welcomeWindow = f
    f:Show()
end

-- The "What's new" popup for 7.0, kept short and bold: one line on the
-- overhaul, the card view as the headline feature with a small preview
-- built from the player's own characters (character select style cards
-- beside a rating tile), Streamer Mode and the new design as two tiles,
-- then "Try Cards" (opens PVPHUB on the card view) or "Close".
-- Shown once when a character first logs in on 7.0 (see the
-- "welcome/update popup" step in core); /pvphub update shows it any time.
local POPUP_W = 520
local POPUP_PAD = 22

local function PopupText(parent, size, flags)
    local fs = parent:CreateFontString(nil, "OVERLAY")
    fs:SetFont("Fonts\\FRIZQT__.TTF", size, flags or "")
    fs:SetJustifyH("LEFT")
    return fs
end

-- Up to three of the player's characters for the preview, most recently
-- played first, with their best current rating
local function PreviewCharacters()
    local list = {}
    for key, data in pairs(PVPHUB_DB or {}) do
        if type(data) == "table" and key ~= "settings" and key:find("-", 1, true) and data.class then
            local best = 0
            for _, bracket in pairs(data.bracketStats or {}) do
                if type(bracket) == "table" then
                    if bracket.rating then
                        best = math.max(best, bracket.rating or 0)
                    else
                        for _, s in pairs(bracket) do
                            if type(s) == "table" then best = math.max(best, s.rating or 0) end
                        end
                    end
                end
            end
            list[#list + 1] = { key = key, data = data, best = best }
        end
    end
    table.sort(list, function(a, b) return (a.data.lastSeen or 0) > (b.data.lastSeen or 0) end)
    while #list > 3 do table.remove(list) end
    return list
end

-- Opens PVPHUB on the Characters tab in the card view
local function ShowCardView()
    local w = PVPHUB.window
    if not (w and w:IsShown()) then
        SlashCmdList["PVPHUB"]()
        w = PVPHUB.window
    end
    if not w then return end
    if w.SwitchTab and w.currentTab ~= "characters" then w.SwitchTab("characters") end
    if PVPHUB.Cards then PVPHUB.Cards.SetActive(true) end
end

-- A rounded box (UI kit shape), with a fallback for a missing UI kit
local function Box(parent, radius, r, g, b, a)
    local box = PVPHUB.CreateRoundedShape(parent, "BACKGROUND", 0, 0, radius)
    box:SetRounded(true)
    box:SetVertexColor(r, g, b, a)
    return box
end

-- The card view preview: three character cards (the first one selected,
-- gold) beside the selected one's rating tile
local function BuildPreview(parent, width)
    local holder = CreateFrame("Frame", nil, parent)
    holder:SetSize(width, 104)
    local chars = PreviewCharacters()
    if #chars == 0 then
        chars = { { key = "Your character-Realm", data = { class = "WARRIOR" }, best = 2100 } }
    end

    local cardW = math.floor(width * 0.46)
    for i, c in ipairs(chars) do
        local card = CreateFrame("Frame", nil, holder)
        card:SetSize(cardW, 30)
        card:SetPoint("TOPRIGHT", holder, "TOPRIGHT", 0, -((i - 1) * 36))
        if i == 1 then
            local fill = PVPHUB.CreateRoundedShape(card, "BACKGROUND", 0, 0, 5)
            fill:SetRounded(true)
            fill:SetGradient("VERTICAL", CreateColor(0.30, 0.22, 0.03, 0.95), CreateColor(0.58, 0.44, 0.08, 0.95))
        else
            Box(card, 5, 0.06, 0.05, 0.04, 0.9)
        end
        local icon = card:CreateTexture(nil, "ARTWORK")
        icon:SetSize(20, 20)
        icon:SetPoint("LEFT", 6, 0)
        icon:SetTexture(PVPHUB._CLASS_ICON_PATHS and PVPHUB._CLASS_ICON_PATHS[c.data.class:upper()])
        icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        local name = PopupText(card, 12, "OUTLINE")
        name:SetPoint("LEFT", icon, "RIGHT", 7, 0)
        name:SetWidth(cardW - 40)
        name:SetWordWrap(false)
        local cc = RAID_CLASS_COLORS[c.data.class:upper()]
        local short = c.key:match("^([^%-]+)") or c.key
        name:SetText(i == 1 and ("|cffffffff" .. short .. "|r") or (cc and cc:WrapTextInColorCode(short) or short))
    end

    -- The selected character's rating tile
    local tile = CreateFrame("Frame", nil, holder)
    tile:SetSize(width - cardW - 14, 102)
    tile:SetPoint("TOPLEFT", holder, "TOPLEFT", 0, 0)
    Box(tile, 8, 1, 1, 1, 0.06)
    local label = PopupText(tile, 12, "OUTLINE")
    label:SetPoint("TOPLEFT", 12, -12)
    label:SetText("|cffffd100Best rating|r")
    local rating = PopupText(tile, 30, "OUTLINE")
    rating:SetPoint("TOPLEFT", 12, -34)
    local best = chars[1].best or 0
    rating:SetText(best > 0 and (PVPHUB._GetRatingColor(best) .. best .. "|r") or "|cff888888—|r")
    local sub = PopupText(tile, 11)
    sub:SetPoint("TOPLEFT", 12, -74)
    sub:SetText("|cff9a97a6Ratings, MMR, history,\ntitles and gear|r")
    return holder
end

function PVPHUB:ShowUpdatePopup(version)
    if PVPHUB.updateWindow then
        PVPHUB.updateWindow:Show()
        return
    end

    local f = CreateFrame("Frame", "PVPHUBUpdateWindow", UIParent)
    -- FULLSCREEN_DIALOG so it draws above the main window's content
    f:SetFrameStrata("FULLSCREEN_DIALOG")
    f:SetSize(POPUP_W, 400) -- height set from the content at the end
    f:SetPoint("CENTER")
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetClampedToScreen(true)
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    tinsert(UISpecialFrames, "PVPHUBUpdateWindow")
    if PVPHUB.UI then PVPHUB.UI.SkinWindow(f) end

    local inner = POPUP_W - POPUP_PAD * 2
    local y = 22

    -- Header: logo and "PVPHUB 7.0", then the version line
    local logo = f:CreateTexture(nil, "OVERLAY")
    logo:SetTexture("Interface\\AddOns\\PVPHUB\\media\\PVPHUB.png")
    logo:SetSize(30, 30)
    logo:SetPoint("TOPLEFT", POPUP_PAD, -y + 2)
    local title = PopupText(f, 22, "OUTLINE")
    title:SetFont("Interface\\AddOns\\PVPHUB\\media\\fonts\\Prototype.ttf", 24, "OUTLINE")
    title:SetPoint("LEFT", logo, "RIGHT", 10, 0)
    title:SetText("PVPHUB 7.0")
    title:SetTextColor(unpack(UI_CONSTANTS.COLORS.TITLE_COLOR))
    local ver = PopupText(f, 11)
    ver:SetPoint("TOPRIGHT", -POPUP_PAD - 24, -y - 8)
    ver:SetJustifyH("RIGHT")
    ver:SetText("|cff8f8c99What's new  ·  " .. (version or "?") .. "|r")
    y = y + 44

    -- The big line: 7.0 rebuilds the whole addon
    local tagline = PopupText(f, 18, "OUTLINE")
    tagline:SetPoint("TOPLEFT", POPUP_PAD, -y)
    tagline:SetText("|cffffffffRebuilt from the ground up.|r")
    local tagSub = PopupText(f, 12)
    tagSub:SetPoint("TOPLEFT", tagline, "BOTTOMLEFT", 0, -6)
    tagSub:SetText("|cff9a97a6New look. New views. Your data stays.|r")
    y = y + tagline:GetStringHeight() + 6 + tagSub:GetStringHeight() + 18

    -- Headline feature: the card view
    local hero = CreateFrame("Frame", nil, f)
    hero:SetPoint("TOPLEFT", POPUP_PAD, -y)
    hero:SetWidth(inner)
    Box(hero, 12, 1, 0.82, 0, 0.07)

    local badge = PVPHUB.CreateNewBadge and PVPHUB.CreateNewBadge(hero, {}, "7.0")
    if badge then badge:SetPoint("TOPLEFT", 16, -18) end
    local heroTitle = PopupText(hero, 20, "OUTLINE")
    heroTitle:SetPoint("TOPLEFT", badge and 54 or 16, -14)
    heroTitle:SetText("|cffffd100Cards|r")
    local heroText = PopupText(hero, 13)
    heroText:SetPoint("TOPLEFT", 16, -44)
    heroText:SetText("|cffd8d6deYour characters as cards. Click one, see everything.|r")
    local preview = BuildPreview(hero, inner - 32)
    preview:SetPoint("TOPLEFT", 16, -(44 + heroText:GetStringHeight() + 14))
    local heroH = 44 + heroText:GetStringHeight() + 14 + preview:GetHeight() + 16
    hero:SetHeight(heroH)
    y = y + heroH + 10

    -- Two tiles side by side: Streamer Mode and the new design
    local tiles = {
        { icon = "Interface\\Icons\\Ability_Hunter_EagleEye", title = "Streamer Mode",
          text = "5 skins. Live preview. Easy setup." },
        { icon = "Interface\\Icons\\INV_Misc_Gear_02", title = "All-new design",
          text = "New tabs, toolbar and Season tab." },
    }
    local tileW = (inner - 10) / 2
    local tileH = 0
    for i, t in ipairs(tiles) do
        local tile = CreateFrame("Frame", nil, f)
        tile:SetPoint("TOPLEFT", POPUP_PAD + (i - 1) * (tileW + 10), -y)
        tile:SetWidth(tileW)
        Box(tile, 10, 1, 1, 1, 0.05)
        local icon = tile:CreateTexture(nil, "ARTWORK")
        icon:SetSize(30, 30)
        icon:SetPoint("TOPLEFT", 14, -14)
        icon:SetTexture(t.icon)
        icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        local head = PopupText(tile, 14, "OUTLINE")
        head:SetPoint("TOPLEFT", icon, "TOPRIGHT", 10, 0)
        head:SetText("|cffffffff" .. t.title .. "|r")
        local text = PopupText(tile, 11)
        text:SetPoint("TOPLEFT", head, "BOTTOMLEFT", 0, -4)
        text:SetWidth(tileW - 68)
        text:SetWordWrap(true)
        text:SetText("|cff9a97a6" .. t.text .. "|r")
        t.frame = tile
        tileH = math.max(tileH, 14 + math.max(30, head:GetStringHeight() + 4 + text:GetStringHeight()) + 14)
    end
    for _, t in ipairs(tiles) do t.frame:SetHeight(tileH) end
    y = y + tileH + 18

    -- Buttons: "Try Cards" opens the card view, "Close" just closes
    local close = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    close:SetSize(110, 28)
    close:SetPoint("TOPRIGHT", -POPUP_PAD, -y)
    close:SetText("Close")
    close:SetScript("OnClick", function() f:Hide() end)

    local show = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    show:SetSize(150, 28)
    show:SetPoint("RIGHT", close, "LEFT", -10, 0)
    show:SetText("Try Cards")
    show:SetScript("OnClick", function()
        f:Hide()
        ShowCardView()
    end)
    y = y + 28 + POPUP_PAD

    local xBtn = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    xBtn:SetPoint("TOPRIGHT", -6, -6)
    xBtn:SetScript("OnClick", function() f:Hide() end)
    if PVPHUB.UI then
        PVPHUB.UI.SkinButton(show)
        PVPHUB.UI.SkinButton(close)
        PVPHUB.UI.SkinCloseButton(xBtn)
    end

    f:SetHeight(y)
    PVPHUB.updateWindow = f
    f:Show()
end
