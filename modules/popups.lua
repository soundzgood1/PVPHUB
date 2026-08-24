local _, PVPHUB = ...

-- Local aliases for helpers defined in PVPHUB_core.lua.
local UI_CONSTANTS      = PVPHUB._UI_CONSTANTS
local FormatNumber      = PVPHUB._FormatNumber
local GetCachedSpecInfo = PVPHUB._GetCachedSpecInfo

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

    -- Now that every element's actual size is known, size the window to fit
    -- it exactly instead of the earlier fixed guess.
    f:SetHeight(cursorY + 26)

    PVPHUB.welcomeWindow = f
    f:Show()
end

function PVPHUB:ShowUpdatePopup(version)
    if PVPHUB.updateWindow then
        PVPHUB.updateWindow:Show()
        return
    end

    local f = CreateFrame("Frame", "PVPHUBUpdateWindow", UIParent, "BackdropTemplate")
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
        tile = false, tileSize = 0, edgeSize = 2,
        insets = { left = 2, right = 2, top = 2, bottom = 2 }
    })
    f:SetBackdropColor(unpack(UI_CONSTANTS.COLORS.WINDOW_BG))
    f:SetBackdropBorderColor(unpack(UI_CONSTANTS.COLORS.WINDOW_BORDER))

    local glowFrame = CreateFrame("Frame", nil, f, "BackdropTemplate")
    glowFrame:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        tile = false, edgeSize = 8,
        insets = { left = -8, right = -8, top = -8, bottom = -8 }
    })
    glowFrame:SetBackdropColor(0, 0, 0, 0)
    glowFrame:SetBackdropBorderColor(unpack(UI_CONSTANTS.COLORS.WINDOW_GLOW))
    glowFrame:SetPoint("TOPLEFT", f, "TOPLEFT", -8, 8)
    glowFrame:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", 8, -8)
    glowFrame:SetFrameLevel(f:GetFrameLevel() - 1)

    -- Header
    local title = f:CreateFontString(nil, "OVERLAY")
    title:SetPoint("TOP", 13, -22)
    title:SetFont("Fonts\\FRIZQT__.TTF", 20, "OUTLINE")
    title:SetText("PVPHUB Updated!")
    title:SetTextColor(unpack(UI_CONSTANTS.COLORS.TITLE_COLOR))

    -- PVPHUB logo, left of the title (mirrors the main window's logo+title layout)
    local logo = f:CreateTexture(nil, "OVERLAY")
    logo:SetTexture("Interface\\AddOns\\PVPHUB\\media\\PVPHUB.png")
    logo:SetSize(26, 26)
    logo:SetPoint("RIGHT", title, "LEFT", -8, 1)

    local verLabel = f:CreateFontString(nil, "OVERLAY")
    verLabel:SetPoint("TOP", title, "BOTTOM", 0, -6)
    verLabel:SetFont("Fonts\\FRIZQT__.TTF", 12)
    verLabel:SetText("Version " .. (version or "?") .. "  —  What's new")
    verLabel:SetTextColor(unpack(UI_CONSTANTS.COLORS.HEADER_COLOR))

    local divider1 = f:CreateTexture(nil, "OVERLAY")
    divider1:SetColorTexture(unpack(UI_CONSTANTS.COLORS.ACCENT_LINE))
    divider1:SetSize(400, 1)
    divider1:SetPoint("TOP", verLabel, "BOTTOM", 0, -14)

    -- Running distance from the frame's top edge, mirroring every offset used
    -- below. The window's final height is set from this at the end instead of
    -- being a fixed guess — so it always fits the actual changelog length,
    -- whether that's 2 short entries or 4 long ones.
    local cursorY = 22 + title:GetStringHeight() + 6 + verLabel:GetStringHeight() + 14 + 1

    -- Changelog entries  { title, desc, icon, color }. Icons/colors are reused
    -- from the section they belong to elsewhere in the addon (Season tab,
    -- Queue Timer settings) so the popup reads as part of the same visual
    -- language instead of a plain bulleted list.
    local changes = {
        {
            title = "Season Reset, Fully Fixed",
            desc  = "\"Start Fresh\" (and the automatic new-season reset) now properly clears every character's old ratings, including alts you haven't logged into yet. If you were already affected, it's cleaned up automatically — no action needed.",
            icon  = "Interface\\Icons\\INV_Misc_Broom_01",
            color = { 0.3, 0.85, 0.45 },
        },
        {
            title = "Streamer Mode Polish",
            desc  = "The bottom toolbar now matches your window's theme and color and sits flush against the panel, instead of looking like a separate mismatched bar underneath.",
            icon  = "Interface\\Icons\\INV_Misc_Gear_02",
            color = { 0.35, 0.7, 1.0 },
        },
        {
            title = "Stability & Performance",
            desc  = "A batch of under-the-hood fixes: less chance of a hitch right as a match ends, no more memory buildup during long streaming sessions, and a compatibility fix that could have interfered with other addons.",
            icon  = "Interface\\Icons\\Trade_Engineering",
            color = { 0.85, 0.65, 0.15 },
        },
    }

    -- Fixed layout constants for each card, used both to build it and to
    -- compute how tall it needs to be.
    local ICON_LEFT, ICON_SIZE, ICON_GAP = 12, 34, 10
    local TEXT_LEFT = ICON_LEFT + ICON_SIZE + ICON_GAP
    local CARD_TOP_PAD, CARD_BOTTOM_PAD, TITLE_DESC_GAP = 8, 8, 4

    local lastAnchor = divider1
    local firstRow = true
    for _, entry in ipairs(changes) do
        local row = CreateFrame("Frame", nil, f, "BackdropTemplate")
        row:SetWidth(400)
        local rowGap = firstRow and 14 or 10
        row:SetPoint("TOP", lastAnchor, "BOTTOM", 0, -rowGap)
        firstRow = false
        cursorY = cursorY + rowGap

        -- Card background, tinted by the entry's accent color (same visual
        -- language as the Settings tab's colored sections).
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
        icon:SetTexture(entry.icon)
        icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

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

    -- CTA
    local openBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    openBtn:SetSize(160, 30)
    openBtn:SetPoint("TOP", divider2, "BOTTOM", 0, -20)
    openBtn:SetText("Open PVPHUB")
    openBtn:SetScript("OnClick", function()
        f:Hide()
        SlashCmdList["PVPHUB"]()
    end)
    cursorY = cursorY + 20 + 30

    -- X close
    local xBtn = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    xBtn:SetPoint("TOPRIGHT", -5, -5)
    xBtn:SetScript("OnClick", function() f:Hide() end)

    -- Now that every element's actual size is known, size the window to fit
    -- it exactly instead of the earlier fixed guess.
    f:SetHeight(cursorY + 26)

    PVPHUB.updateWindow = f
    f:Show()
end

-- New Spec Popup Functions
function PVPHUB:ShowNewSpecPopup(specName)
    if PVPHUB.newSpecWindow then
        PVPHUB.newSpecWindow:Show()
        return
    end
    
    -- Get current spec icon
    local specIndex = GetSpecialization()
    local specIcon = "Interface\\Icons\\INV_Misc_QuestionMark"
    if specIndex then
        local specID = GetSpecializationInfo(specIndex)
        if specID then
            local _si = GetCachedSpecInfo(specID)
            if _si and _si.icon then
                specIcon = _si.icon
            end
        end
    end
    
    local f = CreateFrame("Frame", "PVPHUBNewSpecWindow", UIParent, "BackdropTemplate")
    -- FULLSCREEN_DIALOG (not just HIGH, same as the main window) so this
    -- always draws above the main window's content regardless of internal
    -- frame levels (e.g. the Settings tab's collapsible section cards,
    -- which carry their own levels to stack header-over-body) — strata
    -- always wins over level, level only matters within the same strata.
    f:SetFrameStrata("FULLSCREEN_DIALOG")
    f:SetSize(500, 320)
    f:SetPoint("CENTER")
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetClampedToScreen(true)
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    
    -- Modern styled background
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
    
    -- Add glow effect
    local glowFrame = CreateFrame("Frame", nil, f, "BackdropTemplate")
    glowFrame:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        tile = false,
        edgeSize = 8,
        insets = { left = -8, right = -8, top = -8, bottom = -8 }
    })
    glowFrame:SetBackdropColor(0, 0, 0, 0)
    glowFrame:SetBackdropBorderColor(unpack(UI_CONSTANTS.COLORS.WINDOW_GLOW))
    glowFrame:SetPoint("TOPLEFT", f, "TOPLEFT", -8, 8)
    glowFrame:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", 8, -8)
    glowFrame:SetFrameLevel(f:GetFrameLevel() - 1)
    
    -- Title
    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOP", 0, -30)
    title:SetText("New Specialization Detected!")
    title:SetFont("Fonts\\FRIZQT__.TTF", 18, "OUTLINE")
    title:SetTextColor(unpack(UI_CONSTANTS.COLORS.TITLE_COLOR))
    
    -- Spec name with spec icon
    local specText = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    specText:SetPoint("TOP", title, "BOTTOM", 0, -20)
    specText:SetText("|T" .. specIcon .. ":20:20|t " .. specName .. " detected!")
    specText:SetFont("Fonts\\FRIZQT__.TTF", 14, "OUTLINE")
    specText:SetTextColor(1, 0.2, 0.2, 1)
    
    -- Instruction text
    local instructionText = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    instructionText:SetPoint("TOP", specText, "BOTTOM", 0, -25)
    instructionText:SetText("PVPHUB will automatically fetch ratings for this spec.")
    instructionText:SetFont("Fonts\\FRIZQT__.TTF", 12)
    instructionText:SetTextColor(unpack(UI_CONSTANTS.COLORS.HEADER_COLOR))
    instructionText:SetWidth(460)
    instructionText:SetJustifyH("CENTER")
    
    -- Info text
    local warningText = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    warningText:SetPoint("TOP", instructionText, "BOTTOM", 0, -20)
    warningText:SetText("|T" .. specIcon .. ":16:16|t Ratings for " .. specName .. " will appear shortly.\nIf they don't update within a few seconds, try playing a rated match.")
    warningText:SetFont("Fonts\\FRIZQT__.TTF", 11)
    warningText:SetTextColor(unpack(UI_CONSTANTS.COLORS.SUMMARY_TEXT))
    warningText:SetWidth(460)
    warningText:SetJustifyH("CENTER")
    
    -- Close button centered
    local closeBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    closeBtn:SetSize(100, 30)
    closeBtn:SetPoint("BOTTOM", 0, 30)
    closeBtn:SetText("Close")
    closeBtn:SetScript("OnClick", function()
        f:Hide()
    end)
    
    PVPHUB.newSpecWindow = f
    f:Show()
end

-- "Start Fresh for New Season" popup — offers to clear last season's ratings,
-- W/L, match history, and conquest/token progress across every tracked
-- character. Only reachable via the "Start Fresh" button beside Streamer
-- Mode — it no longer opens itself automatically at login. Branded like the
-- rest of the addon's popups instead of a generic StaticPopup — logo, theme
-- colors, custom buttons.
--
-- Either decision button marks the season resolved (PVPHUB_SETTINGS.
-- seasonFreshStartResolvedForSeason).
function PVPHUB:ShowSeasonFreshStartPopup()
    if PVPHUB.seasonFreshStartWindow then
        PVPHUB.seasonFreshStartWindow:Show()
        return
    end

    local f = CreateFrame("Frame", "PVPHUBSeasonFreshStartWindow", UIParent, "BackdropTemplate")
    f:SetFrameStrata("FULLSCREEN_DIALOG")
    f:SetSize(440, 400) -- height is a placeholder; recomputed from content at the end
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
        tile = false, tileSize = 0, edgeSize = 2,
        insets = { left = 2, right = 2, top = 2, bottom = 2 }
    })
    f:SetBackdropColor(unpack(UI_CONSTANTS.COLORS.WINDOW_BG))
    f:SetBackdropBorderColor(unpack(UI_CONSTANTS.COLORS.WINDOW_BORDER))

    local glowFrame = CreateFrame("Frame", nil, f, "BackdropTemplate")
    glowFrame:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        tile = false, edgeSize = 8,
        insets = { left = -8, right = -8, top = -8, bottom = -8 }
    })
    glowFrame:SetBackdropColor(0, 0, 0, 0)
    glowFrame:SetBackdropBorderColor(unpack(UI_CONSTANTS.COLORS.WINDOW_GLOW))
    glowFrame:SetPoint("TOPLEFT", f, "TOPLEFT", -8, 8)
    glowFrame:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", 8, -8)
    glowFrame:SetFrameLevel(f:GetFrameLevel() - 1)

    -- Logo + title, centered like the Welcome popup — this is a seasonal
    -- moment worth a bit of presence, not just a settings confirmation.
    local logo = f:CreateTexture(nil, "OVERLAY")
    logo:SetTexture("Interface\\AddOns\\PVPHUB\\media\\PVPHUB.png")
    logo:SetSize(40, 40)
    logo:SetPoint("TOP", 0, -20)

    local title = f:CreateFontString(nil, "OVERLAY")
    title:SetPoint("TOP", logo, "BOTTOM", 0, -10)
    title:SetFont("Fonts\\FRIZQT__.TTF", 19, "OUTLINE")
    title:SetText("Start Fresh for the New Season")
    title:SetTextColor(unpack(UI_CONSTANTS.COLORS.TITLE_COLOR))

    local divider1 = f:CreateTexture(nil, "OVERLAY")
    divider1:SetColorTexture(unpack(UI_CONSTANTS.COLORS.ACCENT_LINE))
    divider1:SetSize(380, 1)
    divider1:SetPoint("TOP", title, "BOTTOM", 0, -14)

    local cursorY = 20 + logo:GetHeight() + 10 + title:GetStringHeight() + 14 + 1

    -- Body copy
    local bodyText = f:CreateFontString(nil, "OVERLAY")
    bodyText:SetPoint("TOP", divider1, "BOTTOM", 0, -16)
    bodyText:SetFont("Fonts\\FRIZQT__.TTF", 13)
    bodyText:SetTextColor(1, 1, 1, 1)
    bodyText:SetWidth(370)
    bodyText:SetWordWrap(true)
    bodyText:SetJustifyH("CENTER")
    bodyText:SetText("This clears last season's ratings, win/loss records, match history, and conquest/token progress for every tracked character — so your dashboard starts clean for the new season.")
    cursorY = cursorY + 16 + bodyText:GetStringHeight()

    local keptText = f:CreateFontString(nil, "OVERLAY")
    keptText:SetPoint("TOP", bodyText, "BOTTOM", 0, -12)
    keptText:SetFont("Fonts\\FRIZQT__.TTF", 12)
    keptText:SetTextColor(unpack(UI_CONSTANTS.COLORS.HEADER_COLOR))
    keptText:SetWidth(370)
    keptText:SetWordWrap(true)
    keptText:SetJustifyH("CENTER")
    keptText:SetText("Honor, gold, notes, and settings are kept.")
    cursorY = cursorY + 12 + keptText:GetStringHeight()

    local warnText = f:CreateFontString(nil, "OVERLAY")
    warnText:SetPoint("TOP", keptText, "BOTTOM", 0, -10)
    warnText:SetFont("Fonts\\FRIZQT__.TTF", 11)
    warnText:SetTextColor(0.55, 0.55, 0.55, 1)
    warnText:SetText("This can't be undone.")
    cursorY = cursorY + 10 + warnText:GetStringHeight()

    local divider2 = f:CreateTexture(nil, "OVERLAY")
    divider2:SetColorTexture(unpack(UI_CONSTANTS.COLORS.ACCENT_LINE))
    divider2:SetSize(380, 1)
    divider2:SetPoint("TOP", warnText, "BOTTOM", 0, -16)
    cursorY = cursorY + 16 + 1

    -- Primary action — green-tinted to read as the positive/recommended path
    -- without overriding the window's own theme color everywhere else.
    local acceptBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    acceptBtn:SetSize(260, 30)
    acceptBtn:SetPoint("TOP", divider2, "BOTTOM", 0, -16)
    acceptBtn:SetText("Yes, Start Fresh")
    acceptBtn:GetFontString():SetTextColor(0.4, 1, 0.55, 1)
    cursorY = cursorY + 16 + 30

    -- Secondary action — long label, so this button is taller and its
    -- fontstring wraps to two lines instead of overflowing/clipping.
    local declineBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    declineBtn:SetSize(300, 36)
    declineBtn:SetPoint("TOP", acceptBtn, "BOTTOM", 0, -10)
    declineBtn:SetText("I'll log into every character myself, no reset needed")
    local declineFS = declineBtn:GetFontString()
    declineFS:SetWidth(270)
    declineFS:SetWordWrap(true)
    declineFS:SetJustifyH("CENTER")
    declineFS:SetTextColor(0.75, 0.75, 0.75, 1)
    cursorY = cursorY + 10 + 36

    -- X close — makes no decision, so seasonFreshStartResolvedForSeason is
    -- left untouched; both buttons below explicitly resolve it. Since this
    -- popup only opens via the "Start Fresh" button, closing it this way
    -- just requires clicking that button again to reopen it.
    local xBtn = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    xBtn:SetPoint("TOPRIGHT", -5, -5)
    xBtn:SetScript("OnClick", function() f:Hide() end)

    -- The actual data wipe/decline logic lives in PVPHUB_core.lua (it needs
    -- several locals — UpdateCurrencyData, CURRENCY_IDS, PVPHubPrint — that
    -- only exist in that file's chunk); this module stays UI-only and just
    -- calls the exported handles.
    --
    -- "Yes, Start Fresh" doesn't wipe immediately — it sits right next to
    -- the decline button, so a misclick here would otherwise be irreversible
    -- in one press. It opens a final native "are you sure?" confirm
    -- (PVPHUB_CONFIRM_SEASON_FRESH_START) instead; only accepting that
    -- actually runs the wipe.
    acceptBtn:SetScript("OnClick", function()
        f:Hide()
        StaticPopup_Show("PVPHUB_CONFIRM_SEASON_FRESH_START")
    end)

    declineBtn:SetScript("OnClick", function()
        PVPHUB:DeclineSeasonFreshStart()
        f:Hide()
    end)

    -- Now that every element's actual size is known, size the window to fit
    -- it exactly instead of an earlier fixed guess.
    f:SetHeight(cursorY + 26)

    PVPHUB.seasonFreshStartWindow = f
    f:Show()
end

