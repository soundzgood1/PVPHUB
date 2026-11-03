-- PVPHUB Card View
-- The Characters tab's second layout: the selected character's information
-- on the left (80% of the width) and a vertical list of character cards in
-- the style of WoW's character select screen on the right (20%) to pick
-- from. Switched with the List/Cards toggle
-- in the window's toolbar and saved in PVPHUB_SETTINGS.mainWindow.characterView
-- ("list" or "cards").
--
-- The list's renderer (f:UpdateContent in core) does everything both views
-- share (hidden characters, the No-Ratings filter, sorting, pinning, groups,
-- totals) and hands its display list to Cards.Render instead of building
-- rows. Character cards, group headers and the info panel's rows are pooled: the
-- client never frees frames, so they're created once and reused.

local _, PVPHUB = ...

local Cards = {}
PVPHUB.Cards = Cards

-- Card view area inside the window, in window units: below the title row
-- (title, toolbar, close), above the footer, same side margins as the list.
-- The list's column headers sit at the same height (core, -62).
local AREA_TOP, AREA_BOTTOM, AREA_LEFT, AREA_RIGHT = -62, 60, 20, 45
local LIST_TOP     = -90    -- the list's own scroll area starts below its column headers
local LIST_SHARE   = 0.20   -- the character list's share of the width; the info panel gets the rest
local LIST_MIN_W   = 200    -- wide enough for a full spec and realm name
local COLUMN_GAP   = 12

local CARD_HEIGHT  = 64     -- character card in the list (character select style)
local CARD_GAP     = 6
local CARD_RADIUS  = 5
local EMBLEM_SIZE  = 38
local GROUP_HEIGHT = 26     -- group bar in the list

-- The toolbar in the title row (the tabs are a rail outside the window), for
-- the list and the card view alike: List/Cards after the title; search,
-- Groups, "+" (new group), Columns (list only) and Sort before the close
-- button, each in a thin frame (UI.AddToolFrame)
local TOOLBAR_Y, TOOLBAR_H = -14, 24   -- level with the title and close button
local TOOLBAR_LEFT  = 152   -- the title and "by soundz vX" under it end before this
local TOOLBAR_RIGHT = 52    -- the close button: 26 wide, 18 from the right edge
local TOOL_GAP      = 6
local GROUPS_W      = 92    -- the Groups switch and its label, in their frame
local SEARCH_MIN_W  = 70    -- narrower than this, the search box hides
local SEARCH_MAX_W  = 180

local DETAIL_PAD   = 14
local BIG_PORTRAIT = 52
local TILE_HEIGHT  = 82     -- rating tile, one per bracket (and spec)
local TILE_GAP     = 10

local BRACKETS = {
    { key = "rating2v2",     label = "2v2",     icon = "Interface\\Icons\\achievement_arena_2v2_1" },
    { key = "rating3v3",     label = "3v3",     icon = "Interface\\Icons\\achievement_arena_3v3_1" },
    { key = "ratingShuffle", label = "Shuffle", icon = "Interface\\Icons\\ability_dualwield", perSpec = true },
    { key = "ratingBlitz",   label = "Blitz",   icon = "Interface\\Icons\\achievement_bg_killxenemies_generalsroom", perSpec = true },
    { key = "ratingRBG",     label = "RBG",     icon = "Interface\\Icons\\achievement_pvp_a_15" },
}


local WHITE       = "Interface\\Buttons\\WHITE8x8"
local CIRCLE_MASK = "Interface\\CHARACTERFRAME\\TempPortraitAlphaMask"

Cards.pool    = {}   -- card frames, reused in display order
Cards.headers = {}   -- group header frames, likewise

-- --------------------------------------------------------------------------
-- View setting
-- --------------------------------------------------------------------------

function Cards.IsActive()
    local mw = PVPHUB_SETTINGS and PVPHUB_SETTINGS.mainWindow
    return (mw and mw.characterView == "cards") and true or false
end

-- Window size for the card view: fixed, so it doesn't change with the
-- list's columns or the selected character (the info panel scrolls when
-- there's more). The list keeps sizing itself to its columns and rows.
-- Never more than most of the screen, in the window's own (scaled) units.
local CARD_WINDOW_W, CARD_WINDOW_H = 760, 720

function Cards.WindowWidth(f)
    return math.floor(math.min(CARD_WINDOW_W, UIParent:GetWidth() * 0.85 / f:GetScale()))
end

function Cards.WindowHeight(f)
    return math.floor(math.min(CARD_WINDOW_H, UIParent:GetHeight() * 0.85 / f:GetScale()))
end

-- Pins the window by its top-left corner before its size changes, so it
-- grows and shrinks to the right and down instead of around its center.
function Cards.KeepTopLeft(f)
    local left, top = f:GetLeft(), f:GetTop()
    if left and top then
        f:ClearAllPoints()
        f:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", left, top)
    end
end

function Cards.SetActive(on)
    PVPHUB_SETTINGS.mainWindow = PVPHUB_SETTINGS.mainWindow or {}
    PVPHUB_SETTINGS.mainWindow.characterView = on and "cards" or "list"
    local f = PVPHUB.window
    if not f then return end
    if f.scrollFrame then f.scrollFrame:SetVerticalScroll(0) end
    if f.viewToggle then Cards.PaintToggle(f.viewToggle) end
    if f.currentTab == "characters" and f.UpdateContent then f:UpdateContent() end
end

-- --------------------------------------------------------------------------
-- Helpers
-- --------------------------------------------------------------------------

-- A FontString that follows the Style section's font setting.
local function NewText(parent, size)
    local fs = parent:CreateFontString(nil, "OVERLAY")
    PVPHUB._RegisterTrackedFont(fs, size, "OUTLINE")
    fs:SetShadowColor(0, 0, 0, 0.8)
    fs:SetShadowOffset(1, -1)
    fs:SetJustifyH("LEFT")
    fs:SetWordWrap(false)
    return fs
end

local function GetColors()
    return (PVPHUB.currentColors and next(PVPHUB.currentColors) and PVPHUB.currentColors) or {}
end

-- The theme's highlight color, the same the UI kit's switches and sliders use
local function ThemeColor()
    if PVPHUB.UI and PVPHUB.UI.ThemeColor then return PVPHUB.UI.ThemeColor() end
    return GetColors().ACCENT_LINE or { 0.8, 0.3, 0.5 }
end

-- The view's own colors: dark cards like the character select screen and
-- gold. A theme can restyle them with a CARDS table (Graphite does); a
-- field it leaves out falls back to these.
--   cardFill/cardRing             a character card
--   selBottom/selTop/selRing      the selected card (fill gradient, rim)
--   groupFill/groupRing           a group bar
--   heading                       section titles, their lines, the +/- signs
--   name                          an unselected card's name (hex)
--   tileSel {r, g, b, a, hoverA}  the rating tile the graph shows
--   tileDrop                      a tile something is dragged over
local DEFAULT_CARDS = {
    cardFill  = { 0.06, 0.05, 0.04, 0.85 },
    cardRing  = { 0.32, 0.29, 0.26, 0.7 },
    selBottom = { 0.30, 0.22, 0.03, 0.95 },
    selTop    = { 0.58, 0.44, 0.08, 0.95 },
    selRing   = { 1, 0.85, 0.2, 1 },
    groupFill = { 0.09, 0.07, 0.06, 0.92 },
    groupRing = { 0.36, 0.32, 0.28, 0.8 },
    heading   = { 1, 0.82, 0 },
    name      = "ffd100",
    tileSel   = { 0.32, 0.24, 0.05, 0.55, 0.7 },
    tileDrop  = { 0.5, 0.38, 0.08, 0.85 },
}
local CARDS_FALLBACK = { __index = DEFAULT_CARDS }

local function CardStyle()
    local style = GetColors().CARDS
    if not style then return DEFAULT_CARDS end
    if not getmetatable(style) then setmetatable(style, CARDS_FALLBACK) end
    return style
end

local function ToggleText(open)
    local h = CardStyle().heading
    return string.format("|cff%02x%02x%02x%s|r",
        math.floor(h[1] * 255 + 0.5), math.floor(h[2] * 255 + 0.5), math.floor(h[3] * 255 + 0.5), open and "–" or "+")
end

local function ClassColor(data)
    local token = data and data.class and data.class:upper() or "WARRIOR"
    return RAID_CLASS_COLORS[token] or RAID_CLASS_COLORS.WARRIOR, token
end

-- Inline icon markup, cropped like the other icons
local function IconMarkup(path, size)
    return string.format("|T%s:%d:%d:0:0:64:64:5:59:5:59|t", path, size, size)
end

local function ColoredRating(value)
    if not value or value <= 0 then return "|cff555555—|r" end
    return PVPHUB._GetRatingColor(value) .. value .. "|r"
end

-- Race portrait atlas ("raceicon128-human-male") for a saved race key
-- (UnitRace's second return) and UnitSex value. A few races' portraits use
-- a different name than their key, so each candidate is checked against the
-- client's atlas list; nil when none exists (e.g. a race newer than the
-- portraits), and the spec or class icon is used instead.
local RACE_ATLAS_ALIASES = {
    Scourge            = "undead",
    HighmountainTauren = "highmountain",
    LightforgedDraenei = "lightforged",
    ZandalariTroll     = "zandalari",
    EarthenDwarf       = "earthen",
}
local raceAtlasCache = {}
local function GetRaceAtlas(race, gender)
    if type(race) ~= "string" then return nil end
    local sex = (gender == 3) and "female" or "male"
    local key = race .. "-" .. sex
    if raceAtlasCache[key] == nil then
        raceAtlasCache[key] = false
        for _, name in ipairs({ race:lower(), RACE_ATLAS_ALIASES[race] }) do
            for _, prefix in ipairs({ "raceicon128-", "raceicon-" }) do
                local atlas = prefix .. name .. "-" .. sex
                if C_Texture.GetAtlasInfo(atlas) then
                    raceAtlasCache[key] = atlas
                    break
                end
            end
            if raceAtlasCache[key] then break end
        end
    end
    return raceAtlasCache[key] or nil
end

-- "NightElf" -> "Night Elf"; Blizzard's key for Undead is "Scourge"
local function RaceName(race)
    if type(race) ~= "string" then return nil end
    if race == "Scourge" then return "Undead" end
    return (race:gsub("(%l)(%u)", "%1 %2"))
end

-- A round portrait: race portrait, else spec icon, else class icon, with
-- the class icon as a badge on its bottom-right corner (left out when the
-- portrait already is the class icon).
local function CreatePortrait(parent, size, badgeSize)
    local p = {}
    p.icon = parent:CreateTexture(nil, "ARTWORK")
    p.icon:SetSize(size, size)
    local mask = parent:CreateMaskTexture()
    mask:SetTexture(CIRCLE_MASK, "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
    mask:SetAllPoints(p.icon)
    p.icon:AddMaskTexture(mask)

    p.badgeBack = parent:CreateTexture(nil, "OVERLAY", nil, 1)
    p.badgeBack:SetSize(badgeSize + 2, badgeSize + 2)
    p.badgeBack:SetPoint("CENTER", p.icon, "BOTTOMRIGHT", -3, 3)
    p.badgeBack:SetColorTexture(0, 0, 0, 0.85)

    p.badge = parent:CreateTexture(nil, "OVERLAY", nil, 2)
    p.badge:SetSize(badgeSize, badgeSize)
    p.badge:SetPoint("CENTER", p.badgeBack, "CENTER")
    p.badge:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    return p
end

local function PaintPortrait(p, data)
    local _, token = ClassColor(data)
    local spec      = PVPHUB._GetCachedSpecInfo(data.specID)
    local classIcon = PVPHUB._CLASS_ICON_PATHS[token]
    local raceAtlas = GetRaceAtlas(data.race, data.gender)
    local isClass = false
    if raceAtlas then
        p.icon:SetAtlas(raceAtlas)
    else
        local path = (spec and spec.icon) or classIcon
        isClass = (path == classIcon)
        p.icon:SetTexture(path or "Interface\\Icons\\INV_Misc_QuestionMark")
        p.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    end
    local showBadge = classIcon ~= nil and not isClass
    if showBadge then p.badge:SetTexture(classIcon) end
    p.badge:SetShown(showBadge)
    p.badgeBack:SetShown(showBadge)
end


-- --------------------------------------------------------------------------
-- Character list (cards in the style of WoW's character select screen)
-- --------------------------------------------------------------------------

-- Faction for the emblem: saved on login (data.faction), else the race's
-- faction. Pandaren, Dracthyr, Earthen and newer races can be either, so
-- they get no emblem until the character has logged in once.
local RACE_FACTION = {
    Human = "Alliance", Dwarf = "Alliance", NightElf = "Alliance", Gnome = "Alliance",
    Draenei = "Alliance", Worgen = "Alliance", VoidElf = "Alliance", LightforgedDraenei = "Alliance",
    DarkIronDwarf = "Alliance", KulTiran = "Alliance", Mechagnome = "Alliance",
    Orc = "Horde", Scourge = "Horde", Tauren = "Horde", Troll = "Horde", BloodElf = "Horde",
    Goblin = "Horde", Nightborne = "Horde", HighmountainTauren = "Horde", MagharOrc = "Horde",
    ZandalariTroll = "Horde", Vulpera = "Horde",
}

-- The faction emblem: the first of these atlases the client has, else the
-- battleground start timer's faction logo. Shown desaturated and faint,
-- like the gray emblems on the character select screen.
local FACTION_ATLASES = {
    Alliance = { "glues-characterselect-icon-faction-alliance", "MountJournalIcons-Alliance" },
    Horde    = { "glues-characterselect-icon-faction-horde", "MountJournalIcons-Horde" },
}
local factionArt = {}
local function SetFactionEmblem(tex, faction)
    if faction ~= "Alliance" and faction ~= "Horde" then
        tex:Hide()
        return
    end
    if factionArt[faction] == nil then
        factionArt[faction] = { file = "Interface\\Timer\\" .. faction .. "-Logo" }
        for _, atlas in ipairs(FACTION_ATLASES[faction]) do
            if C_Texture.GetAtlasInfo(atlas) then
                factionArt[faction] = { atlas = atlas }
                break
            end
        end
    end
    local art = factionArt[faction]
    if art.atlas then
        tex:SetAtlas(art.atlas)
    else
        tex:SetTexture(art.file)
        tex:SetTexCoord(0, 1, 0, 1)
    end
    tex:SetDesaturated(true)
    tex:SetAlpha(0.4)
    tex:Show()
end

local function CreateCharCard(container)
    local card = CreateFrame("Button", nil, container)
    card:SetHeight(CARD_HEIGHT)
    card:RegisterForClicks("LeftButtonUp", "RightButtonUp")

    -- A 1 px rim behind the fill, slightly rounded corners
    card.ring = PVPHUB.CreateRoundedShape(card, "BACKGROUND", 0, 0, CARD_RADIUS)
    card.fill = PVPHUB.CreateRoundedShape(card, "BACKGROUND", 1, -1, CARD_RADIUS - 1)
    card.glow = PVPHUB.CreateRoundedShape(card, "BORDER", 0, -1, CARD_RADIUS - 1)
    card.ring:SetRounded(true)
    card.fill:SetRounded(true)
    card.glow:SetRounded(true)
    card.glow:SetVertexColor(1, 1, 1, 0.06)
    card.glow:Hide()

    card.emblem = card:CreateTexture(nil, "ARTWORK")
    card.emblem:SetSize(EMBLEM_SIZE, EMBLEM_SIZE)
    card.emblem:SetPoint("RIGHT", -12, 0)

    -- Name, "Level 90 [spec] Class", realm
    card.name = NewText(card, 14)
    card.name:SetPoint("TOPLEFT", 12, -9)
    card.who = NewText(card, 12)
    card.who:SetPoint("TOPLEFT", card.name, "BOTTOMLEFT", 0, -3)
    card.realm = NewText(card, 11)
    card.realm:SetPoint("TOPLEFT", card.who, "BOTTOMLEFT", 0, -3)

    card.noteIcon = card:CreateTexture(nil, "OVERLAY")
    card.noteIcon:SetSize(12, 12)
    card.noteIcon:SetPoint("TOPRIGHT", -6, -6)
    card.noteIcon:SetTexture("Interface\\Buttons\\UI-GuildButton-PublicNote-Up")

    card:SetScript("OnEnter", function(self) self.glow:Show() end)
    card:SetScript("OnLeave", function(self) self.glow:Hide() end)
    card:SetScript("OnClick", function(self, button)
        if not self.charKey or Cards.JustDragged() then return end
        if button == "RightButton" then
            local f = PVPHUB.window
            if f and f.ShowCharacterMenu then f:ShowCharacterMenu(self, self.charKey) end
        else
            Cards.Select(self.charKey)
        end
    end)

    -- Drag to reorder, or into another group (see the drag section below)
    card:RegisterForDrag("LeftButton")
    card:SetScript("OnDragStart", function(self) Cards.BeginDrag(self, "card") end)
    card:SetScript("OnDragStop", function() Cards.EndDrag() end)

    return card
end

local function PaintCharCard(card, entry, width, selected)
    local charKey, data = entry.char, entry.data
    card.charKey, card.entry = charKey, entry
    local cc, token = ClassColor(data)

    -- Dark card like the character select screen; the selected one is gold,
    -- lighter at the top, with a bright gold rim (CardStyle)
    local style = CardStyle()
    if selected then
        card.ring:SetVertexColor(unpack(style.selRing))
        card.fill:SetGradient("VERTICAL", CreateColor(unpack(style.selBottom)), CreateColor(unpack(style.selTop)))
    else
        card.ring:SetVertexColor(unpack(style.cardRing))
        card.fill:SetVertexColor(unpack(style.cardFill))
    end

    SetFactionEmblem(card.emblem, data.faction or RACE_FACTION[data.race])

    local textW = width - 12 - EMBLEM_SIZE - 18
    card.name:SetWidth(textW)
    card.who:SetWidth(textW)
    card.realm:SetWidth(textW)

    card.name:SetText("|cff" .. (selected and "ffffff" or style.name) .. (data.displayName or charKey:match("^([^%-]+)") or charKey) .. "|r")

    local className = (LOCALIZED_CLASS_NAMES_MALE and LOCALIZED_CLASS_NAMES_MALE[token]) or token
    local spec = PVPHUB._GetCachedSpecInfo(data.specID)
    local who = (data.level and data.level > 0) and ("|cffffffffLevel " .. data.level .. "|r ") or ""
    if spec and spec.icon then who = who .. IconMarkup(spec.icon, 12) .. " " end
    card.who:SetText(who .. cc:WrapTextInColorCode(className))

    card.realm:SetText("|cff999999" .. (charKey:match("%-(.+)$") or "") .. "|r")

    card.noteIcon:SetShown(data.note ~= nil and data.note ~= "")
    card:SetAlpha(PVPHUB._IsCharacterStaleThisSeason(charKey) and 0.7 or 1)
end

-- Group bar: a framed bar like the character cards, the name on the left
-- and a gold + / - on the right. Click to collapse, right-click to rename
-- or delete, drag to move the group.
local function CreateGroupHeader(container)
    local h = CreateFrame("Button", nil, container)
    h:SetHeight(GROUP_HEIGHT)
    h:RegisterForClicks("LeftButtonUp", "RightButtonUp")

    h.ring = PVPHUB.CreateRoundedShape(h, "BACKGROUND", 0, 0, 4)
    h.fill = PVPHUB.CreateRoundedShape(h, "BACKGROUND", 1, -1, 3)
    h.glow = PVPHUB.CreateRoundedShape(h, "BORDER", 0, -1, 3)
    h.ring:SetRounded(true)
    h.fill:SetRounded(true)
    h.glow:SetRounded(true)
    h.glow:SetVertexColor(1, 1, 1, 0.06)
    h.glow:Hide()

    h.text = NewText(h, 12)
    h.text:SetPoint("LEFT", 10, 0)

    h.toggle = NewText(h, 16)
    h.toggle:SetPoint("RIGHT", -10, 0)
    h.toggle:SetJustifyH("RIGHT")

    h:SetScript("OnEnter", function(self) self.glow:Show() end)
    h:SetScript("OnLeave", function(self) self.glow:Hide() end)

    h:SetScript("OnClick", function(self, button)
        if Cards.JustDragged() then return end
        local groups = PVPHUB_SETTINGS.characterGroups and PVPHUB_SETTINGS.characterGroups.groups
        local group = groups and groups[self.groupIndex]
        if not group then return end
        local f = PVPHUB.window
        if button == "LeftButton" then
            group.collapsed = not group.collapsed
            if f and f.UpdateContent then f:UpdateContent() end
        elseif not self.isDefault then
            -- Same rename/delete menu as the list's group headers
            local index, name = self.groupIndex, self.groupName
            MenuUtil.CreateContextMenu(self, function(_, root)
                root:CreateTitle(name)
                root:CreateButton("Rename Group", function()
                    PVPHUB._renameGroupCtx = { groupIndex = index, groupName = name }
                    PVPHUB.ShowDialog("PVPHUB_RENAME_GROUP")
                end)
                root:CreateButton("|cffff4040Delete Group|r", function()
                    PVPHUB._deleteGroupCtx = { groupIndex = index }
                    PVPHUB.Dialogs["PVPHUB_DELETE_GROUP"].text = "Delete group '" .. name .. "'?\n\nCharacters will move to No Group."
                    PVPHUB.ShowDialog("PVPHUB_DELETE_GROUP")
                end)
            end)
        end
    end)

    -- "No Group" always stays last, so only the user's own groups move
    h:RegisterForDrag("LeftButton")
    h:SetScript("OnDragStart", function(self)
        if not self.isDefault then Cards.BeginDrag(self, "group") end
    end)
    h:SetScript("OnDragStop", function() Cards.EndDrag() end)

    return h
end

local function PaintGroupHeader(h, entry)
    h.entry      = entry
    h.groupIndex = entry.groupIndex
    h.groupName  = entry.groupName
    h.isDefault  = entry.groupIsDefault
    local style = CardStyle()
    h.ring:SetVertexColor(unpack(style.groupRing))
    h.fill:SetVertexColor(unpack(style.groupFill))
    h.toggle:SetText(ToggleText(not entry.groupCollapsed))
    h.text:SetText(string.format("|cffffffff%s|r  |cff777777%d|r", entry.groupName or "", entry.characterCount or 0))
end

-- --------------------------------------------------------------------------
-- Drag and drop
-- --------------------------------------------------------------------------
-- Cards: drag one up or down to put it where you want; dropping it on a
-- group bar or among another group's cards moves it into that group. The
-- result is saved as PVPHUB_SETTINGS.customOrder (every character, in
-- order) and the Sort dropdown switches to Custom Order to show it. When
-- another sort was active, the order on screen is the starting point, so
-- only the dragged character moves.
-- Group bars: drag one between the others to reorder the groups.
--
-- Render records where everything sits (Cards.layout: kind, frame, char,
-- groupIndex, top, height in the list's own units).

local DRAG_EDGE   = 28    -- dragging this close to the list's top/bottom edge scrolls it
local DRAG_SCROLL = 6     -- scroll speed per frame while there

local drag = {}

function Cards.JustDragged()
    return Cards.dragEndedAt ~= nil and GetTime() - Cards.dragEndedAt < 0.25
end

-- While dragging, an exact copy of the card or group bar follows the cursor
-- (held where it was grabbed) and the original stays faded in its place.
-- The copies are a card and a group bar of their own, painted like the
-- dragged one, on a solid background so they read over anything.
local function GetDragVisuals()
    if drag.marker then return drag.marker end

    local function Ghost(frame)
        frame:SetFrameStrata("TOOLTIP")
        frame:EnableMouse(false)
        frame:Hide()
        return frame
    end
    drag.cardGhost = Ghost(CreateCharCard(UIParent))
    drag.groupGhost = Ghost(CreateGroupHeader(UIParent))

    -- Where the dragged card or group will land
    local marker = Cards.container:CreateTexture(nil, "OVERLAY", nil, 7)
    marker:SetTexture(WHITE)
    marker:SetHeight(2)
    marker:SetVertexColor(1, 0.82, 0, 1)
    marker:Hide()
    drag.marker = marker
    return marker
end

-- The cursor in the list's own units, relative to the top of its content
local function CursorInList()
    local c = Cards.container
    local scale = c:GetEffectiveScale()
    local x, y = GetCursorPosition()
    return x / scale, y / scale, c:GetTop()
end

local function ShowMarker(y)
    drag.marker:ClearAllPoints()
    drag.marker:SetPoint("TOPLEFT", Cards.container, "TOPLEFT", 0, -y)
    drag.marker:SetPoint("TOPRIGHT", Cards.container, "TOPRIGHT", 0, -y)
    drag.marker:Show()
end

-- Works out the drop target under the cursor and moves the marker there
local function UpdateDropTarget()
    drag.target = nil
    drag.marker:Hide()
    if drag.overHeader then drag.overHeader.glow:Hide() end
    drag.overHeader = nil

    local f = PVPHUB.window
    local x, y, top = CursorInList()
    local sf = f.scrollFrame
    local left, right = sf:GetLeft(), sf:GetRight()
    if not (top and left) or x < left - 40 or x > right + 40 then return end
    local rel = top - y   -- distance below the top of the list content

    local layout = Cards.layout or {}
    if drag.kind == "card" then
        -- Prefer a hit on a card (before/after by halves) or a group bar
        -- (into that group, at its top); between or beyond, the nearest edge
        local best
        for _, item in ipairs(layout) do
            if rel >= item.top - CARD_GAP / 2 and rel < item.top + item.height + CARD_GAP / 2 then
                best = item
                break
            end
        end
        if not best then
            best = (rel < 0) and layout[1] or layout[#layout]
        end
        if not best then return end

        if best.kind == "header" then
            drag.target = { intoGroup = best.groupIndex }
            drag.overHeader = best.frame
            best.frame.glow:Show()
            ShowMarker(best.top + best.height + 1)
        elseif best.char ~= drag.source.charKey then
            local after = rel >= best.top + best.height / 2
            drag.target = { char = best.char, after = after, groupIndex = best.groupIndex }
            ShowMarker(after and (best.top + best.height + CARD_GAP / 2) or (best.top - CARD_GAP / 2))
        end
    else
        -- Groups land in front of the group bar below the cursor; "No
        -- Group" stays last, so in front of it means behind every other group
        local groups = PVPHUB_SETTINGS.characterGroups and PVPHUB_SETTINGS.characterGroups.groups or {}
        local before
        for _, item in ipairs(layout) do
            if item.kind == "header" and rel < item.top + item.height / 2 then
                before = item
                break
            end
        end
        local beforeGroup = before and groups[before.groupIndex]
        if beforeGroup and beforeGroup.isDefault then beforeGroup = nil end
        if beforeGroup == groups[drag.source.groupIndex] then return end
        drag.target = { beforeGroup = beforeGroup }
        -- Marker in front of that bar, or behind the last of the user's groups
        local markY
        if before and not (groups[before.groupIndex] or {}).isDefault then
            markY = before.top - 2
        else
            for _, item in ipairs(layout) do
                if item.kind == "header" and (groups[item.groupIndex] or {}).isDefault then
                    markY = item.top - 2
                end
            end
            markY = markY or ((layout[#layout] and (layout[#layout].top + layout[#layout].height + 2)) or 0)
        end
        ShowMarker(markY)
    end
end

local function DragOnUpdate()
    if not drag.active then return end
    -- The window closed mid-drag: drop nothing
    if not drag.source:IsVisible() then
        drag.target = nil
        Cards.EndDrag()
        return
    end
    local ghost = drag.ghost
    local scale = ghost:GetEffectiveScale()
    local cx, cy = GetCursorPosition()
    ghost:ClearAllPoints()
    ghost:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", cx / scale - drag.grabX, cy / scale - drag.grabY)

    -- Scroll the list while the cursor is near its top or bottom edge
    local sf = PVPHUB.window.scrollFrame
    local _, y = CursorInList()
    local top, bottom = sf:GetTop(), sf:GetBottom()
    if top and bottom then
        local current, range = sf:GetVerticalScroll(), sf:GetVerticalScrollRange()
        if y > top - DRAG_EDGE and current > 0 then
            sf:SetVerticalScroll(math.max(0, current - DRAG_SCROLL))
        elseif y < bottom + DRAG_EDGE and current < range then
            sf:SetVerticalScroll(math.min(range, current + DRAG_SCROLL))
        end
    end

    UpdateDropTarget()
end

function Cards.BeginDrag(source, kind)
    -- Positions in a filtered list are ambiguous: no dragging while searching
    if drag.active or (Cards.searchText or "") ~= "" then return end
    if not source.entry then return end
    GetDragVisuals()
    drag.active, drag.kind, drag.source = true, kind, source

    local ghost
    if kind == "card" then
        ghost = drag.cardGhost
        local selected = source.charKey == Cards.selected
        PaintCharCard(ghost, source.entry, source:GetWidth(), selected)
        if not selected then ghost.fill:SetVertexColor(0.04, 0.035, 0.03, 0.97) end
    else
        ghost = drag.groupGhost
        PaintGroupHeader(ghost, source.entry)
        ghost.fill:SetVertexColor(0.04, 0.035, 0.03, 0.97)
    end
    ghost:SetSize(source:GetWidth(), source:GetHeight())
    -- Same size on screen as the original, wherever the window is scaled
    ghost:SetScale(source:GetEffectiveScale() / UIParent:GetEffectiveScale())
    ghost:SetAlpha(0.9)
    -- Keep the copy under the cursor where the original was grabbed
    local cx, cy = GetCursorPosition()
    local s = source:GetEffectiveScale()
    drag.grabX = cx / s - source:GetLeft()
    drag.grabY = cy / s - source:GetTop()
    drag.ghost = ghost
    ghost:Show()

    drag.sourceAlpha = source:GetAlpha()
    source:SetAlpha(0.35)
    if not drag.driver then
        drag.driver = CreateFrame("Frame")
    end
    drag.driver:SetScript("OnUpdate", DragOnUpdate)
end

-- Every listed character in the order shown now; for Custom Order the
-- saved order, with characters it doesn't know yet added at the end
local function CurrentOrder()
    local order, seen = {}, {}
    local function add(key)
        if key and not seen[key] then
            seen[key] = true
            order[#order + 1] = key
        end
    end
    if PVPHUB_SETTINGS.sortKey == "custom" then
        for _, key in ipairs(PVPHUB_SETTINGS.customOrder or {}) do
            if PVPHUB_DB[key] then add(key) end
        end
    end
    for _, entry in ipairs(Cards.lastSorted or {}) do add(entry.char) end
    return order
end

local function DropCard(charKey, target)
    local order = CurrentOrder()
    for i = #order, 1, -1 do
        if order[i] == charKey then table.remove(order, i) end
    end

    local groupsOn = PVPHUB_SETTINGS.characterGroups and PVPHUB_SETTINGS.characterGroups.enabled
    local pos = #order + 1
    local newGroup
    if target.intoGroup then
        -- Top of that group: in front of its first character in the order
        newGroup = target.intoGroup
        for i, key in ipairs(order) do
            if PVPHUB._GetCharacterGroup(key) == newGroup then
                pos = i
                break
            end
        end
    else
        newGroup = target.groupIndex
        for i, key in ipairs(order) do
            if key == target.char then
                pos = target.after and (i + 1) or i
                break
            end
        end
    end
    table.insert(order, pos, charKey)
    PVPHUB_SETTINGS.customOrder = order

    if groupsOn and newGroup and PVPHUB._GetCharacterGroup(charKey) ~= newGroup then
        PVPHUB._MoveCharacterToGroup(charKey, newGroup)
    end

    local f = PVPHUB.window
    if f and f.ApplySort then
        f:ApplySort("custom")   -- shows the new order (and refreshes)
    elseif f and f.UpdateContent then
        f:UpdateContent()
    end
end

function Cards.EndDrag()
    if not drag.active then return end
    drag.active = false
    drag.driver:SetScript("OnUpdate", nil)
    drag.ghost:Hide()
    drag.marker:Hide()
    if drag.overHeader then drag.overHeader.glow:Hide() end
    drag.overHeader = nil
    drag.source:SetAlpha(drag.sourceAlpha or 1)
    Cards.dragEndedAt = GetTime()

    local source, kind, target = drag.source, drag.kind, drag.target
    drag.source, drag.target = nil, nil
    if not target then return end
    if kind == "card" and source.charKey then
        DropCard(source.charKey, target)
    elseif kind == "group" and source.groupIndex then
        PVPHUB._ReorderGroup(source.groupIndex, target.beforeGroup)
    end
end

-- --------------------------------------------------------------------------
-- Character info panel
-- --------------------------------------------------------------------------

local function CurrentSeason()
    return (C_PvP and C_PvP.GetUIDisplaySeason and C_PvP.GetUIDisplaySeason()) or 0
end

-- Past season picked in the info panel's season menu, per character for the
-- session (nil = the current season)
Cards.viewSeason = {}

-- What the info panel shows for a character and which season that is: its
-- live data for the current season, or the picked season from the season
-- archive (modules/seasons.lua), shaped like live data.
local function DetailData(charKey)
    local data = charKey and PVPHUB_DB[charKey]
    local season = charKey and Cards.viewSeason[charKey]
    if data and season and PVPHUB.Seasons then
        local view = PVPHUB.Seasons.View(charKey, season)
        if view then return view, season, true end
        Cards.viewSeason[charKey] = nil
    end
    return data, CurrentSeason(), false
end

-- Newest MMR for a bracket (and spec, for Shuffle/Blitz): the last recorded
-- match, else the last value the game reported.
local function GetMMR(data, bracketKey, specID)
    local hist = data.mmrHistory and data.mmrHistory[bracketKey]
    if hist then
        for i = #hist, 1, -1 do
            local m = hist[i]
            if (m.postMatchMMR or 0) > 0 and (not specID or m.specID == specID) then
                return m.postMatchMMR
            end
        end
    end
    local known = data.lastKnownMMR and data.lastKnownMMR[bracketKey]
    if type(known) == "table" then
        if specID then
            local d = known[specID]
            if type(d) == "table" and (d.mmr or 0) > 0 then return d.mmr end
        else
            local best
            for _, d in pairs(known) do
                if type(d) == "table" and (d.mmr or 0) > (best or 0) then best = d.mmr end
            end
            return best
        end
    end
    return nil
end

-- The shown season's rated brackets as table rows; Shuffle and Blitz get one
-- row per spec, highest first.
local function CollectRatingRows(data, season)
    local rows = {}
    local function isCurrent(s)
        return type(s) == "table" and (season == 0 or not s.season or s.season == season)
            and ((s.rating or 0) > 0 or (s.played or 0) > 0)
    end
    for _, bracket in ipairs(BRACKETS) do
        local bs = data.bracketStats and data.bracketStats[bracket.key]
        if bracket.perSpec then
            if type(bs) == "table" then
                local specRows = {}
                for specID, s in pairs(bs) do
                    if type(specID) == "number" and isCurrent(s) then
                        specRows[#specRows + 1] = { bracket = bracket, specID = specID, stats = s }
                    end
                end
                table.sort(specRows, function(a, b) return (a.stats.rating or 0) > (b.stats.rating or 0) end)
                for _, row in ipairs(specRows) do rows[#rows + 1] = row end
            end
        elseif isCurrent(bs) then
            rows[#rows + 1] = { bracket = bracket, stats = bs }
        end
    end
    return rows
end

-- Section header: gold title with an underline that fades out to the
-- right, and a gold + / – on the right. Clicking it collapses or expands
-- the section; the state is saved per section in
-- PVPHUB_SETTINGS.mainWindow.cardSections[key] (false = collapsed).
local function SectionOpen(key)
    local sections = PVPHUB_SETTINGS.mainWindow and PVPHUB_SETTINGS.mainWindow.cardSections
    return not (sections and sections[key] == false)
end

-- The sections in the user's order (PVPHUB_SETTINGS.mainWindow.cardSectionOrder,
-- set by dragging their header bars); any section missing from a saved
-- order keeps its default place at the end.
local SECTION_KEYS = { "ratings", "titles", "history", "gear", "currencies" }
local function SectionOrder()
    local known = {}
    for _, key in ipairs(SECTION_KEYS) do known[key] = true end
    local order, seen = {}, {}
    local saved = PVPHUB_SETTINGS.mainWindow and PVPHUB_SETTINGS.mainWindow.cardSectionOrder
    for _, key in ipairs(saved or {}) do
        if known[key] and not seen[key] then
            seen[key] = true
            order[#order + 1] = key
        end
    end
    for _, key in ipairs(SECTION_KEYS) do
        if not seen[key] then order[#order + 1] = key end
    end
    return order
end

-- Colors a section's title and the line under it (CardStyle heading)
local function PaintSectionHeader(h)
    local c = CardStyle().heading
    h.title:SetTextColor(c[1], c[2], c[3], 1)
    h.line:SetGradient("HORIZONTAL", CreateColor(c[1], c[2], c[3], 0.5), CreateColor(c[1], c[2], c[3], 0))
end

local function CreateSectionHeader(parent, text, key)
    local h = CreateFrame("Button", nil, parent)
    h:SetHeight(22)
    h.key = key

    h.title = NewText(h, 13)
    h.title:SetPoint("LEFT", 0, 2)
    h.title:SetText(text)

    h.toggle = NewText(h, 15)
    h.toggle:SetPoint("RIGHT", -4, 2)
    h.toggle:SetJustifyH("RIGHT")

    h.line = h:CreateTexture(nil, "ARTWORK")
    h.line:SetTexture(WHITE)
    h.line:SetHeight(1)
    h.line:SetPoint("BOTTOMLEFT")
    h.line:SetPoint("BOTTOMRIGHT")

    local hl = h:CreateTexture(nil, "HIGHLIGHT")
    hl:SetAllPoints()
    hl:SetTexture(WHITE)
    hl:SetVertexColor(1, 1, 1, 0.04)

    h:SetScript("OnClick", function(self)
        if not Cards.JustDragged() then Cards.ToggleSection(self.key) end
    end)
    -- Drag the bar to move the whole section
    h:RegisterForDrag("LeftButton")
    h:SetScript("OnDragStart", function(self) Cards.BeginSectionDrag(self) end)
    h:SetScript("OnDragStop", function() Cards.EndSectionDrag() end)
    PaintSectionHeader(h)
    return h
end

-- The frame holding a section's content: hiding it collapses the section.
-- Content is still anchored to the scroll content, like before.
local function CreateSectionBody(parent)
    local body = CreateFrame("Frame", nil, parent)
    body:SetAllPoints(parent)
    return body
end

-- Tiles and list rows react the same way: hover shows the bracket's match
-- tooltip, left-click shows the bracket in the rating history graph,
-- right-click opens the menu that picks which brackets get tiles.
local function BracketOnEnter(self)
    self.hover = true
    if self.PaintHover then self:PaintHover() end
    -- The tooltip shows live data, so not while a past season is shown
    local data = self.charKey and not Cards.viewSeason[self.charKey] and PVPHUB_DB[self.charKey]
    if data then
        PVPHUB._ShowRatingTooltip(self, self.charKey, self.bracketKey, data[self.bracketKey])
    end
end

local function BracketOnLeave(self)
    self.hover = false
    if self.PaintHover then self:PaintHover() end
    PVPHUB._CloseRatingTooltip()
end

local function BracketOnClick(self, button)
    if Cards.JustDragged() then return end
    if button == "RightButton" then
        Cards.OpenTileMenu(self)
    elseif self.info and self.info.id then
        -- Also without recorded matches: the graph then says so
        Cards.graphChoice[self.charKey] = self.info.id
        Cards.RefreshDetail()
    end
end

local function BracketScripts(b)
    b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    b:SetScript("OnEnter", BracketOnEnter)
    b:SetScript("OnLeave", BracketOnLeave)
    b:SetScript("OnClick", BracketOnClick)
    -- Drag onto a tile to put it there (Cards.BeginTileDrag)
    b:RegisterForDrag("LeftButton")
    b:SetScript("OnDragStart", function(self) Cards.BeginTileDrag(self) end)
    b:SetScript("OnDragStop", function() Cards.EndTileDrag() end)
end

-- Rating tile, like check-pvp's bracket boxes: bracket on top (and the spec's
-- icon in the corner), the rating big under it, then one small line with
-- MMR left and season best right. The tile the graph shows is tinted gold.
-- Three in a row (TILE_COUNT); the other brackets go in the list under
-- them. Painted by PaintRatingTile.
local TILE_COUNT = 3
local TILE_PAD   = 9

local function CreateRatingTile(content)
    local t = CreateFrame("Button", nil, content)
    t:SetHeight(TILE_HEIGHT)
    t.bg = PVPHUB.CreateRoundedShape(t, "BACKGROUND", 0, 0, 8)
    t.bg:SetRounded(true)

    t.icon = t:CreateTexture(nil, "ARTWORK")
    t.icon:SetSize(16, 16)
    t.icon:SetPoint("TOPLEFT", TILE_PAD, -10)
    t.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    t.label = NewText(t, 12)
    t.label:SetPoint("LEFT", t.icon, "RIGHT", 5, 0)
    t.specIcon = t:CreateTexture(nil, "ARTWORK")
    t.specIcon:SetSize(18, 18)
    t.specIcon:SetPoint("TOPRIGHT", -TILE_PAD, -9)
    t.specIcon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

    t.rating = NewText(t, 24)
    t.rating:SetPoint("TOPLEFT", TILE_PAD, -31)

    -- One small line under the rating: MMR left, season best right
    t.mmr = NewText(t, 11)
    t.mmr:SetPoint("BOTTOMLEFT", TILE_PAD, 10)
    t.best = NewText(t, 11)
    t.best:SetPoint("BOTTOMRIGHT", -TILE_PAD, 10)
    t.best:SetJustifyH("RIGHT")

    t.PaintHover = function(self) Cards.PaintTileBackground(self) end
    BracketScripts(t)
    return t
end

-- The list under the tiles: one compact row per remaining bracket, in the
-- columns the old ratings table had. Painted by PaintRatingRow.
local LIST_ROW_H = 22
local LIST_COLUMNS = {
    { key = "rating", title = "Rating", x = 0.42 },
    { key = "best",   title = "Best",   x = 0.54 },
    { key = "mmr",    title = "MMR",    x = 0.66 },
    { key = "wl",     title = "W–L",    x = 0.78 },
    { key = "win",    title = "Win",    x = 0.91 },
}

local function CreateRatingRow(content)
    local row = CreateFrame("Button", nil, content)
    row:SetHeight(LIST_ROW_H)
    local hl = row:CreateTexture(nil, "HIGHLIGHT")
    hl:SetAllPoints()
    hl:SetTexture(WHITE)
    hl:SetVertexColor(1, 1, 1, 0.05)

    row.icon = row:CreateTexture(nil, "ARTWORK")
    row.icon:SetSize(16, 16)
    row.icon:SetPoint("LEFT", 4, 0)
    row.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    row.label = NewText(row, 12)
    row.label:SetPoint("LEFT", row.icon, "RIGHT", 6, 0)
    row.cells = {}
    for i = 1, #LIST_COLUMNS do row.cells[i] = NewText(row, 12) end

    -- Lights up while a tile is dragged over the row
    row.dropHL = row:CreateTexture(nil, "BACKGROUND")
    row.dropHL:SetAllPoints()
    row.dropHL:SetTexture(WHITE)
    row.dropHL:SetVertexColor(1, 0.82, 0, 0.18)
    row.dropHL:Hide()
    row.PaintHover = function(self) self.dropHL:SetShown(self.dropTarget == true) end

    BracketScripts(row)
    return row
end

-- Gold tint for the tile the graph shows, lighter on hover; brightest while
-- something is dragged over it (CardStyle)
function Cards.PaintTileBackground(t)
    local style = CardStyle()
    if t.isGhost then
        -- The drag copy floats over anything: solid black, so it reads
        t.bg:SetVertexColor(0.03, 0.03, 0.04, 0.97)
    elseif t.dropTarget then
        t.bg:SetVertexColor(unpack(style.tileDrop))
    elseif t.selected then
        local c = style.tileSel
        t.bg:SetVertexColor(c[1], c[2], c[3], t.hover and c[5] or c[4])
    else
        t.bg:SetVertexColor(1, 1, 1, t.hover and 0.09 or 0.05)
    end
end

-- --------------------------------------------------------------------------
-- Rating history graph
-- --------------------------------------------------------------------------
-- CR and MMR after each recorded match, for one bracket (and spec, for
-- Shuffle and Blitz) at a time. Each match record stores the CR going into
-- the match and the change, so the CR after it is rating + ratingChange.
-- Lines are the client's own Line regions, pooled.

local GRAPH_HEIGHT  = 150
local GRAPH_LABEL_W = 38     -- left margin for the rating labels
local GRAPH_MAX     = 300    -- the most recent matches drawn at most ("Season")
local CR_COLOR      = { 1, 0.82, 0 }
local MMR_COLOR     = { 0.45, 0.72, 1 }
local RANGES = {
    { key = 20, text = "Last 20" },
    { key = 50, text = "Last 50" },
    { key = 0,  text = "Season" },
}

Cards.graphRange  = 50
Cards.graphChoice = {}   -- [charKey] = series id the user picked, for the session

-- The shown season's match history as graph series: one per bracket, and one
-- per spec for Shuffle and Blitz, in BRACKETS order, matches oldest first.
local function CollectSeries(data, season)
    local list = {}
    local hist = data.mmrHistory
    if type(hist) ~= "table" then return list end
    for _, bracket in ipairs(BRACKETS) do
        local matches = hist[bracket.key]
        if type(matches) == "table" then
            local bySpec, order = {}, {}
            for _, m in ipairs(matches) do
                if type(m) == "table" and (season == 0 or not m.season or m.season == season) then
                    local sk = bracket.perSpec and (m.specID or 0) or 0
                    if not bySpec[sk] then
                        bySpec[sk] = {}
                        order[#order + 1] = sk
                    end
                    table.insert(bySpec[sk], m)
                end
            end
            for _, sk in ipairs(order) do
                local last = bySpec[sk][#bySpec[sk]]
                list[#list + 1] = {
                    id = bracket.key .. ":" .. sk,
                    bracket = bracket,
                    specID = (sk ~= 0) and sk or nil,
                    matches = bySpec[sk],
                    lastPlayed = last.timestamp or 0,
                }
            end
        end
    end
    return list
end

local function SeriesPoints(series, range)
    local matches = series.matches
    local limit = (range > 0) and range or GRAPH_MAX
    local first = math.max(1, #matches - limit + 1)
    local pts = {}
    for i = first, #matches do
        local m = matches[i]
        pts[#pts + 1] = {
            cr = (m.rating or 0) + (m.ratingChange or 0),
            mmr = ((m.postMatchMMR or 0) > 0) and m.postMatchMMR or nil,
            match = m,
        }
    end
    return pts
end

-- Spacing for ~4 grid lines over a rating span
local function GridStep(span)
    for _, step in ipairs({ 10, 20, 25, 50, 100, 200, 250, 500 }) do
        if span / step <= 4 then return step end
    end
    return 1000
end

local function NewDot(parent, color)
    local dot = parent:CreateTexture(nil, "OVERLAY", nil, 3)
    dot:SetSize(7, 7)
    dot:SetColorTexture(color[1], color[2], color[3], 1)
    local mask = parent:CreateMaskTexture()
    mask:SetTexture(CIRCLE_MASK, "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
    mask:SetAllPoints(dot)
    dot:AddMaskTexture(mask)
    return dot
end

local function GraphX(g, i)
    if #g.pts <= 1 then return g.w / 2 end
    return (i - 1) / (#g.pts - 1) * g.w
end

local function GraphY(g, value)
    return (value - g.lo) / (g.hi - g.lo) * g.h
end

-- Puts the dots (and, while hovering, the marker) on point i
local function PlaceDots(g, i, hovering)
    local p = g.pts[i]
    if not p then
        g.crDot:Hide(); g.mmrDot:Hide(); g.marker:Hide()
        return
    end
    local x = GraphX(g, i)
    g.crDot:ClearAllPoints()
    g.crDot:SetPoint("CENTER", g.plot, "BOTTOMLEFT", x, GraphY(g, p.cr))
    g.crDot:Show()
    if p.mmr then
        g.mmrDot:ClearAllPoints()
        g.mmrDot:SetPoint("CENTER", g.plot, "BOTTOMLEFT", x, GraphY(g, p.mmr))
        g.mmrDot:Show()
    else
        g.mmrDot:Hide()
    end
    if hovering then
        g.marker:ClearAllPoints()
        g.marker:SetPoint("TOP", g.plot, "TOPLEFT", x, 0)
        g.marker:SetPoint("BOTTOM", g.plot, "BOTTOMLEFT", x, 0)
        g.marker:Show()
    else
        g.marker:Hide()
    end
end

-- "before -> after" arrow: an atlas icon, as in the queue timer, because
-- WoW's fonts have no Unicode arrow glyph (it showed as a box)
local ARROW = CreateAtlasMarkup("common-icon-forwardarrow", 10, 10)

local function ShowPointTooltip(g, i)
    local p = g.pts[i]
    local m = p.match
    GameTooltip:SetOwner(g, "ANCHOR_CURSOR")
    local when = PVPHUB._FormatTimestamp(m.timestamp)
    if m.timestamp then when = when .. "  " .. date("%H:%M", m.timestamp) end
    GameTooltip:SetText(when, 1, 1, 1)

    local change = m.ratingChange or 0
    if m.roundsWon and m.roundsLost then
        GameTooltip:AddLine(string.format("Rounds %d–%d", m.roundsWon, m.roundsLost), 0.85, 0.85, 0.85)
    elseif change > 0 then
        GameTooltip:AddLine("Win", 0.25, 1, 0.25)
    elseif change < 0 then
        GameTooltip:AddLine("Loss", 1, 0.3, 0.3)
    end

    local before = m.rating or 0
    GameTooltip:AddDoubleLine("CR", string.format("%d %s %s%d|r%s", before, ARROW,
        PVPHUB._GetRatingColor(math.max(p.cr, 1)), p.cr, change ~= 0 and PVPHUB.FormatRatingDelta(change) or ""),
        CR_COLOR[1], CR_COLOR[2], CR_COLOR[3], 1, 1, 1)
    if p.mmr then
        -- "before -> after +change" like CR; just the value when the match
        -- has no pre-match MMR
        local text = tostring(p.mmr)
        local pre = m.preMatchMMR or 0
        if pre > 0 then
            local mmrChange = p.mmr - pre
            text = pre .. " " .. ARROW .. " " .. p.mmr
                .. (mmrChange ~= 0 and PVPHUB.FormatRatingDelta(mmrChange) or "")
        end
        GameTooltip:AddDoubleLine("MMR", text, MMR_COLOR[1], MMR_COLOR[2], MMR_COLOR[3], 1, 1, 1)
    end
    GameTooltip:Show()
end

local function GraphOnUpdate(g)
    if not g.pts or #g.pts == 0 then return end
    local left = g.plot:GetLeft()
    if not left then return end
    local cursorX = GetCursorPosition() / g.plot:GetEffectiveScale()
    local i = 1
    if #g.pts > 1 then
        i = math.floor((cursorX - left) / g.w * (#g.pts - 1) + 1.5)
        i = math.max(1, math.min(#g.pts, i))
    end
    if i == g.hoverIndex then return end
    g.hoverIndex = i
    PlaceDots(g, i, true)
    ShowPointTooltip(g, i)
end

local function CreateGraph(parent)
    local g = CreateFrame("Frame", nil, parent)
    g:SetHeight(GRAPH_HEIGHT)
    g.bg = g:CreateTexture(nil, "BACKGROUND")
    g.bg:SetAllPoints()
    g.bg:SetColorTexture(0, 0, 0, 0.2)

    g.plot = CreateFrame("Frame", nil, g)
    g.plot:SetPoint("TOPLEFT", GRAPH_LABEL_W, -10)
    g.plot:SetPoint("BOTTOMRIGHT", -10, 10)

    g.grid = {}
    for i = 1, 6 do
        local line = g.plot:CreateTexture(nil, "BORDER")
        line:SetTexture(WHITE)
        line:SetHeight(1)
        line:SetVertexColor(1, 1, 1, 0.07)
        local label = NewText(g, 9)
        label:SetJustifyH("RIGHT")
        label:SetTextColor(0.6, 0.6, 0.6, 1)
        g.grid[i] = { line = line, label = label }
    end

    g.crLines, g.mmrLines = {}, {}

    g.marker = g.plot:CreateTexture(nil, "OVERLAY")
    g.marker:SetTexture(WHITE)
    g.marker:SetWidth(1)
    g.marker:SetVertexColor(1, 1, 1, 0.3)
    g.marker:Hide()
    g.crDot  = NewDot(g.plot, CR_COLOR)
    g.mmrDot = NewDot(g.plot, MMR_COLOR)

    g.empty = NewText(g, 11)
    g.empty:SetPoint("CENTER")
    g.empty:SetJustifyH("CENTER")
    g.empty:SetSpacing(4)
    g.empty:SetText("|cff777777No matches recorded this season|r")

    g:EnableMouse(true)
    g:SetScript("OnEnter", function(self)
        self.hoverIndex = nil
        self:SetScript("OnUpdate", GraphOnUpdate)
    end)
    g:SetScript("OnLeave", function(self)
        self:SetScript("OnUpdate", nil)
        self.hoverIndex = nil
        GameTooltip:Hide()
        if self.pts then PlaceDots(self, #self.pts, false) end
    end)
    return g
end

-- Graph lines use a texture that fades out across the line's width
-- (media/graph_line.tga), so their edges are smooth instead of the hard
-- stair steps a solid line gets on a slope. The visible core is about half
-- the thickness. Pixel snapping is off so a line can sit between pixels.
local LINE_TEXTURE = "Interface\\AddOns\\PVPHUB\\media\\graph_line"

local function GetLine(pool, parent, i, color, thickness)
    local line = pool[i]
    if not line then
        line = parent:CreateLine(nil, "ARTWORK")
        line:SetTexture(LINE_TEXTURE)
        if line.SetSnapToPixelGrid then
            line:SetSnapToPixelGrid(false)
            line:SetTexelSnappingBias(0)
        end
        pool[i] = line
    end
    line:SetThickness(thickness)
    line:SetVertexColor(color[1], color[2], color[3], 1)
    return line
end

local function DrawGraph(g, pts, width)
    g.pts = pts
    g.w = width - GRAPH_LABEL_W - 10
    g.h = GRAPH_HEIGHT - 20
    local hasPoints = #pts > 0
    g.empty:SetShown(not hasPoints)

    local lo, hi = math.huge, -math.huge
    for _, p in ipairs(pts) do
        lo, hi = math.min(lo, p.cr), math.max(hi, p.cr)
        if p.mmr then lo, hi = math.min(lo, p.mmr), math.max(hi, p.mmr) end
    end
    if not hasPoints then lo, hi = 0, 100 end
    local step = GridStep(math.max(hi - lo, 40))
    g.lo = math.max(0, math.floor((lo - step * 0.3) / step) * step)
    g.hi = math.ceil((hi + step * 0.3) / step) * step
    if g.hi <= g.lo then g.hi = g.lo + step end

    -- Grid lines and their rating labels
    local n = 0
    for value = g.lo, g.hi, step do
        n = n + 1
        local gl = g.grid[n]
        if not gl then break end
        local y = GraphY(g, value)
        gl.line:ClearAllPoints()
        gl.line:SetPoint("BOTTOMLEFT", g.plot, "BOTTOMLEFT", 0, y)
        gl.line:SetPoint("BOTTOMRIGHT", g.plot, "BOTTOMRIGHT", 0, y)
        gl.label:ClearAllPoints()
        gl.label:SetPoint("RIGHT", g.plot, "BOTTOMLEFT", -6, y)
        gl.label:SetText(value)
        gl.line:SetShown(hasPoints)
        gl.label:SetShown(hasPoints)
    end
    for i = n + 1, #g.grid do
        g.grid[i].line:Hide()
        g.grid[i].label:Hide()
    end

    -- CR line, and the MMR line between matches that have an MMR
    local nCR, nMMR = 0, 0
    for i = 2, #pts do
        local a, b = pts[i - 1], pts[i]
        local x1, x2 = GraphX(g, i - 1), GraphX(g, i)
        nCR = nCR + 1
        local line = GetLine(g.crLines, g.plot, nCR, CR_COLOR, 4)
        line:SetStartPoint("BOTTOMLEFT", g.plot, x1, GraphY(g, a.cr))
        line:SetEndPoint("BOTTOMLEFT", g.plot, x2, GraphY(g, b.cr))
        line:Show()
        if a.mmr and b.mmr then
            nMMR = nMMR + 1
            local mline = GetLine(g.mmrLines, g.plot, nMMR, MMR_COLOR, 3)
            mline:SetStartPoint("BOTTOMLEFT", g.plot, x1, GraphY(g, a.mmr))
            mline:SetEndPoint("BOTTOMLEFT", g.plot, x2, GraphY(g, b.mmr))
            mline:Show()
        end
    end
    for i = nCR + 1, #g.crLines do g.crLines[i]:Hide() end
    for i = nMMR + 1, #g.mmrLines do g.mmrLines[i]:Hide() end

    -- Dots on the newest match until the mouse picks another
    g.hoverIndex = nil
    PlaceDots(g, #pts, false)
end

-- Small toggle buttons above the graph (bracket/spec, range)
local function CreateChip(parent, onClick)
    local chip = CreateFrame("Button", nil, parent)
    chip:SetHeight(20)
    chip.bg = chip:CreateTexture(nil, "BACKGROUND")
    chip.bg:SetAllPoints()
    chip.bg:SetTexture(WHITE)
    local hl = chip:CreateTexture(nil, "HIGHLIGHT")
    hl:SetAllPoints()
    hl:SetTexture(WHITE)
    hl:SetVertexColor(1, 1, 1, 0.08)
    chip.text = NewText(chip, 10)
    chip.text:SetPoint("CENTER")
    chip:SetScript("OnClick", onClick)
    return chip
end

local function PaintChip(chip, active)
    if active then
        local ac = ThemeColor()
        chip.bg:SetVertexColor(ac[1], ac[2], ac[3], 0.45)
        chip.text:SetTextColor(1, 1, 1, 1)
    else
        chip.bg:SetVertexColor(0, 0, 0, 0.35)
        chip.text:SetTextColor(0.75, 0.75, 0.75, 1)
    end
end

-- The series the graph shows: the one the user picked for this character
-- (a chip, a rating tile or a list row), else the one played last. A picked
-- bracket with a rating but no recorded matches (played before PVPHUB was
-- installed, or on another PC) returns nil plus its rating row, so the
-- graph can say so instead of quietly showing another bracket.
local function ChosenSeries(charKey, seriesList, ratingRows)
    local pick = Cards.graphChoice[charKey]
    if pick then
        for _, s in ipairs(seriesList) do
            if s.id == pick then return s end
        end
        for _, info in ipairs(ratingRows) do
            if info.bracket.key .. ":" .. (info.specID or 0) == pick then return nil, info end
        end
    end
    local chosen
    for _, s in ipairs(seriesList) do
        if not chosen or s.lastPlayed > chosen.lastPlayed then chosen = s end
    end
    return chosen
end

-- Paints the graph section (chips + graph) for one character
local function PaintHistory(panel, charKey, width)
    local data, season, archived = DetailData(charKey)
    if not data then return end
    local seriesList = CollectSeries(data, season)
    local chosen, emptyPick = ChosenSeries(charKey, seriesList, CollectRatingRows(data, season))

    -- Series chips, left to right
    local x = 0
    for i, s in ipairs(seriesList) do
        local chip = panel.seriesChips[i]
        if not chip then
            chip = CreateChip(panel.historyBody, function(self)
                -- The whole panel, so the rating tiles show the pick too
                Cards.graphChoice[self.charKey] = self.seriesID
                Cards.RefreshDetail()
            end)
            panel.seriesChips[i] = chip
        end
        chip.charKey, chip.seriesID = charKey, s.id
        local specInfo = s.specID and PVPHUB._GetCachedSpecInfo(s.specID)
        if specInfo then
            chip.text:SetText(IconMarkup(specInfo.icon, 11) .. " " .. s.bracket.label)
            chip:SetWidth(78)
        else
            chip.text:SetText(s.bracket.label)
            chip:SetWidth(48)
        end
        chip:ClearAllPoints()
        chip:SetPoint("TOPLEFT", panel.historyRow, "TOPLEFT", x, 0)
        PaintChip(chip, s == chosen)
        chip:Show()
        x = x + chip:GetWidth() + 4
    end
    for i = #seriesList + 1, #panel.seriesChips do panel.seriesChips[i]:Hide() end

    for _, chip in ipairs(panel.rangeChips) do
        PaintChip(chip, chip.range == Cards.graphRange)
        chip:SetShown(#seriesList > 0 and not emptyPick)
    end

    -- An empty graph says why: the picked bracket has no recorded matches
    local empty = "|cff777777No matches recorded this season|r"
    if emptyPick then
        local name = emptyPick.bracket.label
        local specInfo = emptyPick.specID and PVPHUB._GetCachedSpecInfo(emptyPick.specID)
        if specInfo and specInfo.name then name = specInfo.name .. " " .. name end
        empty = string.format("|cff999999No matches recorded for %s %s|r\n|cff666666Its rating comes from the game; matches show here once PVPHUB records them.|r",
            name, archived and "in this season" or "this season yet")
    end
    panel.graph.empty:SetText(empty)

    panel.graph:SetWidth(width)
    DrawGraph(panel.graph, chosen and SeriesPoints(chosen, Cards.graphRange) or {}, width)
end

-- --------------------------------------------------------------------------
-- Rating tiles (see CreateRatingTile)
-- --------------------------------------------------------------------------

-- "Shuffle  [icon] Mistweaver" (or just "2v2"), for list rows and menus
local function BracketLabel(info)
    local label = info.bracket.label
    local specInfo = info.specID and PVPHUB._GetCachedSpecInfo(info.specID)
    if specInfo then
        label = label .. "  |cffaaaaaa" .. IconMarkup(specInfo.icon, 12) .. " " .. specInfo.name .. "|r"
    end
    return label
end

local function WinLossText(s)
    local won, lost = s.won or 0, s.lost or 0
    if won + lost == 0 then return "|cff555555—|r", "|cff555555—|r" end
    local pct = math.floor(won / (won + lost) * 100 + 0.5)
    return string.format("|cff40ff40%d|r|cff888888–|r|cffff5050%d|r", won, lost),
        (pct >= 50 and "|cff40ff40" or "|cffff8040") .. pct .. "%|r"
end

-- What tiles and rows have in common. Everything they were painted with is
-- kept, so dragging can paint an identical copy (Cards.BeginTileDrag).
local function SetBracket(b, info, data, series, selected, width)
    b.info = info
    b.bracketKey = info.bracket.key
    b.seriesID = series and series.id
    b.selected = selected
    b.data, b.series, b.width = data, series, width
end

-- info: a CollectRatingRows row; series: its graph series (nil without
-- recorded matches); selected: the graph shows it
local function PaintRatingTile(t, info, data, series, selected, width)
    SetBracket(t, info, data, series, selected, width)
    t:SetWidth(width)
    Cards.PaintTileBackground(t)

    -- The spec only as an icon in the corner: its name doesn't fit beside
    -- the bracket's in a third of the panel
    t.icon:SetTexture(info.bracket.icon)
    t.label:SetText(info.bracket.label)
    t.label:SetTextColor(selected and 1 or 0.9, selected and 0.82 or 0.9, selected and 0 or 0.9, 1)
    local specInfo = info.specID and PVPHUB._GetCachedSpecInfo(info.specID)
    t.specIcon:SetShown(specInfo ~= nil)
    if specInfo then t.specIcon:SetTexture(specInfo.icon) end

    -- W-L and win rate aren't on the tile: the hover tooltip and the list
    -- rows show them
    local s = info.stats
    t.rating:SetText(ColoredRating(s.rating))
    t.mmr:SetText("|cff8f8c99MMR|r " .. ColoredRating(GetMMR(data, info.bracket.key, info.specID)))
    t.best:SetText("|cff8f8c99Best|r " .. ColoredRating(s.seasonBest))
end

local function PaintRatingRow(row, info, data, series, selected, width)
    SetBracket(row, info, data, series, selected, width)
    row:SetWidth(width)
    row.icon:SetTexture(info.bracket.icon)
    row.label:SetText(BracketLabel(info))
    row.label:SetTextColor(selected and 1 or 0.9, selected and 0.82 or 0.9, selected and 0 or 0.9, 1)
    local s = info.stats
    local wl, win = WinLossText(s)
    local values = {
        rating = ColoredRating(s.rating),
        best   = ColoredRating(s.seasonBest),
        mmr    = ColoredRating(GetMMR(data, info.bracket.key, info.specID)),
        wl     = wl,
        win    = win,
    }
    for c, col in ipairs(LIST_COLUMNS) do
        local cell = row.cells[c]
        cell:ClearAllPoints()
        cell:SetPoint("LEFT", row, "LEFT", math.floor(width * col.x), 0)
        cell:SetText(values[col.key])
    end
end

-- Which brackets get tiles, per character:
-- PVPHUB_SETTINGS.mainWindow.ratingTiles[charKey] = { id, id, id }, ids as
-- "bracketKey:specID" (0 without a spec). Without a choice, or for a slot
-- whose bracket has no games this season, the highest ratings fill in.
local function TileChoices()
    PVPHUB_SETTINGS.mainWindow = PVPHUB_SETTINGS.mainWindow or {}
    PVPHUB_SETTINGS.mainWindow.ratingTiles = PVPHUB_SETTINGS.mainWindow.ratingTiles or {}
    return PVPHUB_SETTINGS.mainWindow.ratingTiles
end

-- Splits the rating rows into the tiles (up to TILE_COUNT, in slot order)
-- and the rest (for the list, in the usual bracket order)
local function SplitRatingRows(charKey, rows)
    local byID = {}
    for _, info in ipairs(rows) do
        info.id = info.bracket.key .. ":" .. (info.specID or 0)
        byID[info.id] = info
    end
    local tiles, used = {}, {}
    for _, id in ipairs(TileChoices()[charKey] or {}) do
        if byID[id] and not used[id] and #tiles < TILE_COUNT then
            tiles[#tiles + 1] = byID[id]
            used[id] = true
        end
    end
    local ranked = {}
    for _, info in ipairs(rows) do ranked[#ranked + 1] = info end
    table.sort(ranked, function(a, b)
        if (a.stats.rating or 0) ~= (b.stats.rating or 0) then return (a.stats.rating or 0) > (b.stats.rating or 0) end
        return (a.stats.played or 0) > (b.stats.played or 0)
    end)
    for _, info in ipairs(ranked) do
        if #tiles >= TILE_COUNT then break end
        if not used[info.id] then
            tiles[#tiles + 1] = info
            used[info.id] = true
        end
    end
    local rest = {}
    for _, info in ipairs(rows) do
        if not used[info.id] then rest[#rest + 1] = info end
    end
    return tiles, rest
end

-- Puts bracket id in tile slot (swapping places if it already has a tile)
function Cards.SetTile(charKey, slot, id)
    local shown = Cards.shownTiles or {}
    local ids = {}
    for i = 1, TILE_COUNT do ids[i] = shown[i] end
    for i = 1, TILE_COUNT do
        if ids[i] == id then ids[i] = ids[slot] end
    end
    ids[slot] = id
    TileChoices()[charKey] = ids
    Cards.RefreshDetail()
end

function Cards.ResetTiles(charKey)
    TileChoices()[charKey] = nil
    Cards.RefreshDetail()
end

-- Right-click on a tile: which list bracket to show there instead.
-- Right-click on a list row: which tile it should replace.
function Cards.OpenTileMenu(owner)
    local charKey, info = owner.charKey, owner.info
    if not charKey or not info or not MenuUtil then return end
    local tiles, rest = Cards.shownTileInfos or {}, Cards.shownRestInfos or {}
    MenuUtil.CreateContextMenu(owner, function(_, root)
        if owner.slot then
            root:CreateTitle("Show in this tile instead")
            for _, other in ipairs(rest) do
                root:CreateButton(BracketLabel(other), function() Cards.SetTile(charKey, owner.slot, other.id) end)
            end
            if #rest == 0 then root:CreateTitle("|cff888888No other brackets this season|r") end
        else
            root:CreateTitle("Show as a tile instead of")
            for slot, tile in ipairs(tiles) do
                root:CreateButton(BracketLabel(tile), function() Cards.SetTile(charKey, slot, info.id) end)
            end
        end
        root:CreateDivider()
        root:CreateButton("Reset to highest ratings", function() Cards.ResetTiles(charKey) end)
    end)
end

-- Dragging: a tile onto another tile swaps the two; a list row onto a tile
-- takes that tile's place (the tile's bracket goes to the list), and a tile
-- onto a list row swaps with it. An exact copy of what's dragged follows the
-- cursor, held where it was grabbed, while the original stays faded in its
-- place; what it would land on lights up.
local tileDrag = {}

-- The copy: a tile or a row of its own, painted like the dragged one, on
-- black (see PaintTileBackground; rows have no background in the panel).
local function DragGhost(kind)
    tileDrag.ghosts = tileDrag.ghosts or {}
    local g = tileDrag.ghosts[kind]
    if g then return g end
    if kind == "tile" then
        g = CreateRatingTile(UIParent)
        g.isGhost = true
    else
        g = CreateRatingRow(UIParent)
        local bg = g:CreateTexture(nil, "BACKGROUND", nil, -1)
        bg:SetAllPoints()
        bg:SetTexture(WHITE)
        bg:SetVertexColor(0.03, 0.03, 0.04, 0.97)
    end
    g:SetFrameStrata("TOOLTIP")
    g:EnableMouse(false)
    g:Hide()
    tileDrag.ghosts[kind] = g
    return g
end

-- Where a drag would land: a tile, or for a dragged tile also a list row
-- (the two swap either way)
local function DropTargetUnderCursor(source)
    local panel = PVPHUB.window and PVPHUB.window.cardDetail
    if not panel then return nil end
    for _, t in ipairs(panel.tiles) do
        if t ~= source and t:IsShown() and t:IsMouseOver() then return t end
    end
    if source.slot then
        for _, row in ipairs(panel.listRows) do
            if row:IsShown() and row:IsMouseOver() then return row end
        end
    end
end

local function TileDragOnUpdate()
    -- The window closed mid-drag: drop nothing, like the cards' drag
    if not tileDrag.source:IsVisible() then
        if tileDrag.target then
            tileDrag.target.dropTarget = nil
            tileDrag.target:PaintHover()
            tileDrag.target = nil
        end
        Cards.EndTileDrag()
        return
    end
    local g = tileDrag.ghost
    local x, y = GetCursorPosition()
    local scale = g:GetEffectiveScale()
    g:ClearAllPoints()
    g:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", x / scale - tileDrag.grabX, y / scale - tileDrag.grabY)
    local target = DropTargetUnderCursor(tileDrag.source)
    if target ~= tileDrag.target then
        if tileDrag.target then
            tileDrag.target.dropTarget = nil
            tileDrag.target:PaintHover()
        end
        tileDrag.target = target
        if target then
            target.dropTarget = true
            target:PaintHover()
        end
    end
end

function Cards.BeginTileDrag(source)
    if not source.info or not source.charKey then return end
    PVPHUB._CloseRatingTooltip()
    tileDrag.source = source
    source:SetAlpha(0.45)

    local g = DragGhost(source.slot and "tile" or "row")
    local paint = source.slot and PaintRatingTile or PaintRatingRow
    paint(g, source.info, source.data, source.series, source.selected, source.width)
    -- Same size on screen as the original, wherever the window is scaled
    g:SetScale(source:GetEffectiveScale() / UIParent:GetEffectiveScale())
    g:SetAlpha(0.9)
    -- Keep the copy under the cursor where the original was grabbed
    local x, y = GetCursorPosition()
    local s = source:GetEffectiveScale()
    tileDrag.grabX = x / s - source:GetLeft()
    tileDrag.grabY = y / s - source:GetTop()
    tileDrag.ghost = g
    g:Show()
    g:SetScript("OnUpdate", TileDragOnUpdate)
    TileDragOnUpdate()
end

function Cards.EndTileDrag()
    local source, target = tileDrag.source, tileDrag.target
    if not source then return end
    tileDrag.source, tileDrag.target = nil, nil
    tileDrag.ghost:SetScript("OnUpdate", nil)
    tileDrag.ghost:Hide()
    source:SetAlpha(1)
    Cards.dragEndedAt = GetTime()   -- so the release doesn't count as a click
    if not target then return end
    target.dropTarget = nil
    target:PaintHover()
    if target.slot then
        -- Onto a tile: the dragged bracket goes there
        Cards.SetTile(source.charKey, target.slot, source.info.id)
    else
        -- A tile onto a list row: the row's bracket takes the tile's place
        Cards.SetTile(source.charKey, source.slot, target.info.id)
    end
end

-- --------------------------------------------------------------------------
-- Season titles
-- --------------------------------------------------------------------------
-- One tile per season title (Gladiator, Legend, Strategist; see TITLE_META
-- in core) with this character's progress from data.titleProgress[key] =
-- { current, required, completed, earnedDay/Month/Year, icon }.

local TITLE_TILE_HEIGHT = 64
local TITLE_TILE_GAP    = 10
local BAR_HEIGHT        = 8

-- Red under 25%, orange under 50%, yellow under 75%, green above, like the Season tab
local function BarColor(pct)
    if pct >= 0.75 then return 0.25, 0.85, 0.3 end
    if pct >= 0.5 then return 0.95, 0.8, 0.2 end
    if pct >= 0.25 then return 1, 0.55, 0.15 end
    return 0.9, 0.25, 0.2
end

local function CreateTitleTile(parent)
    local t = CreateFrame("Frame", nil, parent)
    t:SetHeight(TITLE_TILE_HEIGHT)

    t.bg = t:CreateTexture(nil, "BACKGROUND")
    t.bg:SetAllPoints()
    t.bg:SetColorTexture(0, 0, 0, 0.25)
    t.stripe = t:CreateTexture(nil, "BORDER")
    t.stripe:SetTexture(WHITE)
    t.stripe:SetHeight(2)
    t.stripe:SetPoint("TOPLEFT")
    t.stripe:SetPoint("TOPRIGHT")

    t.icon = t:CreateTexture(nil, "ARTWORK")
    t.icon:SetSize(18, 18)
    t.icon:SetPoint("TOPLEFT", 8, -10)
    t.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    -- Line 1: icon and name. Line 2: "25 to go" on the left, "0 / 25" on
    -- the right, so a long name never runs into the numbers.
    t.name = NewText(t, 12)
    t.name:SetPoint("LEFT", t.icon, "RIGHT", 6, 0)
    t.sub = NewText(t, 10)
    t.sub:SetPoint("TOPLEFT", 8, -34)
    t.value = NewText(t, 12)
    t.value:SetJustifyH("RIGHT")
    t.value:SetPoint("TOPRIGHT", -8, -33)

    -- Rounded progress bar: a dark track and a colored fill on top
    t.bar = CreateFrame("Frame", nil, t)
    t.bar:SetHeight(BAR_HEIGHT)
    t.bar:SetPoint("BOTTOMLEFT", 8, 10)
    t.bar:SetPoint("BOTTOMRIGHT", -8, 10)
    t.track = PVPHUB.CreateRoundedShape(t.bar, "ARTWORK", 0, 0, BAR_HEIGHT / 2)
    t.track:SetRounded(true)
    t.track:SetVertexColor(0, 0, 0, 0.5)
    t.fillFrame = CreateFrame("Frame", nil, t.bar)
    t.fillFrame:SetPoint("TOPLEFT")
    t.fillFrame:SetPoint("BOTTOMLEFT")
    t.fill = PVPHUB.CreateRoundedShape(t.fillFrame, "ARTWORK", 1, 0, BAR_HEIGHT / 2)
    t.fill:SetRounded(true)

    -- Requirement and reward, worded like the Season tab's tiles
    t:EnableMouse(true)
    t:SetScript("OnEnter", function(self)
        if not self.meta then return end
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:AddLine(self.meta.name, 1, 0.82, 0)
        local req = PVPHUB._GetTitleRequirementText(self.meta, self.tp)
        if req then GameTooltip:AddLine(req, 0.9, 0.9, 0.9, true) end
        if self.meta.rewardText and self.meta.rewardText ~= "" then
            GameTooltip:AddLine(" ")
            GameTooltip:AddLine("Reward: " .. self.meta.rewardText, 0.55, 0.8, 1, true)
        end
        GameTooltip:Show()
    end)
    t:SetScript("OnLeave", function() GameTooltip:Hide() end)
    return t
end

local function PaintTitleTile(t, meta, tp, width, stale)
    t:SetWidth(width)
    t.meta, t.tp = meta, tp
    t.stripe:SetVertexColor(meta.color[1], meta.color[2], meta.color[3], 0.9)
    t.icon:SetTexture((tp and tp.icon) or meta.icon)
    t.name:SetText(meta.name)
    t.name:SetWidth(width - 8 - 18 - 6 - 8)

    local barW = width - 16
    local pct, r, g, b = 0, 1, 1, 1
    if tp and tp.completed then
        pct, r, g, b = 1, 1, 0.82, 0
        t.value:SetText("|cffffd100Earned|r")
        local when = ""
        if tp.earnedYear and tp.earnedMonth and tp.earnedDay then
            local year = tp.earnedYear < 100 and (2000 + tp.earnedYear) or tp.earnedYear
            when = PVPHUB._FormatTimestamp(time({ year = year, month = tp.earnedMonth, day = tp.earnedDay, hour = 12 }))
        end
        t.sub:SetText("|cffaaaaaa" .. when .. "|r")
    elseif tp and (tp.required or 0) > 0 then
        local current = math.min(tp.current or 0, tp.required)
        pct = current / tp.required
        r, g, b = BarColor(pct)
        t.value:SetText(string.format("|cffffffff%d|r |cff888888/ %d|r", current, tp.required))
        t.sub:SetText(string.format("|cffaaaaaa%d to go|r", tp.required - current))
    else
        t.value:SetText("|cff666666—|r")
        t.sub:SetText("|cff777777No progress yet|r")
    end

    if pct > 0 then
        t.fillFrame:SetWidth(math.max(BAR_HEIGHT, barW * pct))
        t.fill:SetVertexColor(r, g, b, 1)
        t.fillFrame:Show()
    else
        t.fillFrame:Hide()
    end
    -- A character not played this season still shows last season's progress
    t:SetAlpha(stale and 0.6 or 1)
end

-- --------------------------------------------------------------------------
-- Gear display
-- --------------------------------------------------------------------------

-- Slot ID -> global string with the slot's name (also the key for its
-- empty-slot icon). Recording (end of file) walks the same list.
Cards.GEAR_SLOTS = {
    [1]  = "HEADSLOT",     [2]  = "NECKSLOT",     [3]  = "SHOULDERSLOT", [15] = "BACKSLOT",
    [5]  = "CHESTSLOT",    [9]  = "WRISTSLOT",    [16] = "MAINHANDSLOT", [17] = "SECONDARYHANDSLOT",
    [10] = "HANDSSLOT",    [6]  = "WAISTSLOT",    [7]  = "LEGSSLOT",     [8]  = "FEETSLOT",
    [11] = "FINGER0SLOT",  [12] = "FINGER1SLOT",  [13] = "TRINKET0SLOT", [14] = "TRINKET1SLOT",
}
-- Two columns like the character sheet; the weapons close the left one
local GEAR_COLUMNS = {
    { 1, 2, 3, 15, 5, 9, 16, 17 },
    { 10, 6, 7, 8, 11, 12, 13, 14 },
}
local GEAR_ROW_HEIGHT = 38
local GEAR_ICON       = 32
local GEAR_COL_GAP    = 16

local function QualityColor(quality)
    if quality and C_Item.GetItemQualityColor then
        local r, g, b, hex = C_Item.GetItemQualityColor(quality)
        if r then return r, g, b, hex end
    end
    return 1, 1, 1, "ffffffff"
end

-- One slot: icon with a quality-colored border, item level and name, then
-- enchant and gems. Hover shows the real item tooltip from the saved link;
-- Shift-click links it in chat, Ctrl-click tries it on, like in the bags.
local function CreateGearRow(parent)
    local row = CreateFrame("Button", nil, parent)
    row:SetHeight(GEAR_ROW_HEIGHT)

    row.border = row:CreateTexture(nil, "ARTWORK", nil, 0)
    row.border:SetSize(GEAR_ICON + 2, GEAR_ICON + 2)
    row.border:SetPoint("LEFT", 0, 0)
    row.icon = row:CreateTexture(nil, "ARTWORK", nil, 1)
    row.icon:SetSize(GEAR_ICON, GEAR_ICON)
    row.icon:SetPoint("CENTER", row.border, "CENTER")
    row.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

    local hl = row:CreateTexture(nil, "HIGHLIGHT")
    hl:SetAllPoints()
    hl:SetTexture(WHITE)
    hl:SetVertexColor(1, 1, 1, 0.05)

    row.name = NewText(row, 12)
    row.name:SetPoint("TOPLEFT", row.border, "TOPRIGHT", 8, -3)
    row.detail = NewText(row, 10)
    row.detail:SetPoint("TOPLEFT", row.name, "BOTTOMLEFT", 0, -4)

    row:SetScript("OnEnter", function(self)
        if not self.link then return end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetHyperlink(self.link)
        GameTooltip:Show()
    end)
    row:SetScript("OnLeave", function() GameTooltip:Hide() end)
    row:SetScript("OnClick", function(self)
        if self.link then HandleModifiedItemClick(self.link) end
    end)
    return row
end

local function PaintGearRow(row, slot, item, width)
    row:SetWidth(width)
    row.name:SetWidth(width - GEAR_ICON - 12)
    row.detail:SetWidth(width - GEAR_ICON - 12)

    if item then
        row.link = item.link
        local r, g, b, hex = QualityColor(item.quality)
        row.icon:SetTexture(item.icon or 134400)
        row.icon:SetDesaturated(false)
        row.icon:SetAlpha(1)
        row.border:SetColorTexture(r, g, b, 0.9)
        local ilvl = item.ilvl and ("|cffffffff" .. item.ilvl .. "|r  ") or ""
        row.name:SetText(ilvl .. "|c" .. hex .. (item.name or "?") .. "|r")

        local parts = {}
        if item.enchant then parts[#parts + 1] = "|cff40ff40" .. item.enchant .. "|r" end
        if item.gems then
            local icons = {}
            for _, gemID in ipairs(item.gems) do
                local icon = C_Item.GetItemIconByID(gemID)
                if icon then icons[#icons + 1] = IconMarkup(icon, 12) end
            end
            if #icons > 0 then parts[#parts + 1] = table.concat(icons, " ") end
        end
        row.detail:SetText(table.concat(parts, "   "))
    else
        row.link = nil
        local slotName = Cards.GEAR_SLOTS[slot]
        local _, emptyIcon = GetInventorySlotInfo(slotName)
        row.icon:SetTexture(emptyIcon)
        row.icon:SetDesaturated(true)
        row.icon:SetAlpha(0.6)
        row.border:SetColorTexture(0.3, 0.3, 0.3, 0.6)
        row.name:SetText("|cff777777" .. (_G[slotName] or "") .. "|r")
        row.detail:SetText("|cff555555Empty|r")
    end
end

local function GetDetail(f)
    if f.cardDetail then return f.cardDetail end

    local panel = CreateFrame("Frame", nil, f)
    panel.bg = PVPHUB.CreateRoundedShape(panel, "BACKGROUND", 0, 0, 12)
    panel.bg:SetRounded(true)

    -- Scrolls when the information is taller than the window
    local scroll = CreateFrame("ScrollFrame", nil, panel)
    scroll:SetPoint("TOPLEFT", DETAIL_PAD, -DETAIL_PAD)
    scroll:SetPoint("BOTTOMRIGHT", -DETAIL_PAD, DETAIL_PAD)
    local content = CreateFrame("Frame", nil, scroll)
    content:SetSize(1, 1)
    scroll:SetScrollChild(content)
    PVPHUB.EnableSmoothScroll(scroll, 40)
    panel.scroll, panel.content = scroll, content

    -- Header
    panel.portrait = CreatePortrait(content, BIG_PORTRAIT, 18)
    panel.portrait.icon:SetPoint("TOPLEFT", 0, 0)

    panel.name = NewText(content, 18)
    panel.name:SetPoint("TOPLEFT", panel.portrait.icon, "TOPRIGHT", 14, -2)
    panel.line2 = NewText(content, 12)
    panel.line2:SetPoint("TOPLEFT", panel.name, "BOTTOMLEFT", 0, -5)
    panel.line3 = NewText(content, 11)
    panel.line3:SetPoint("TOPLEFT", panel.line2, "BOTTOMLEFT", 0, -4)
    panel.line4 = NewText(content, 11)
    panel.line4:SetPoint("TOPLEFT", panel.line3, "BOTTOMLEFT", 0, -4)

    panel.note = NewText(content, 11)
    panel.note:SetWordWrap(true)

    -- Season menu, top right: the current season or one from the season
    -- archive. Shown once a character has an archived past season.
    panel.seasonBtn = CreateFrame("Button", nil, content, "UIPanelButtonTemplate")
    panel.seasonBtn:SetSize(170, 22)
    panel.seasonBtn:SetPoint("TOPRIGHT", content, "TOPRIGHT", 0, -2)
    panel.seasonBtn:SetScript("OnClick", function(self) Cards.OpenSeasonMenu(self) end)
    if PVPHUB.UI then PVPHUB.UI.SkinButton(panel.seasonBtn) end

    -- Ratings
    panel.ratingsHeader = CreateSectionHeader(content, "Ratings", "ratings")
    panel.ratingsBody = CreateSectionBody(content)
    panel.noRatings = NewText(panel.ratingsBody, 11)
    panel.noRatings:SetText("|cff777777No rated games this season|r")
    panel.tiles = {}
    -- The list under the tiles: a gold separator that fades out to both
    -- sides, column titles, rows
    panel.listSep = CreateFrame("Frame", nil, panel.ratingsBody)
    panel.listSep:SetHeight(1)
    -- (colored in PaintDetail, CardStyle heading)
    panel.sepLeft = panel.listSep:CreateTexture(nil, "ARTWORK")
    panel.sepLeft:SetTexture(WHITE)
    panel.sepLeft:SetPoint("TOPLEFT")
    panel.sepLeft:SetPoint("BOTTOMRIGHT", panel.listSep, "BOTTOM")
    panel.sepRight = panel.listSep:CreateTexture(nil, "ARTWORK")
    panel.sepRight:SetTexture(WHITE)
    panel.sepRight:SetPoint("TOPLEFT", panel.listSep, "TOP")
    panel.sepRight:SetPoint("BOTTOMRIGHT")
    panel.listTitles = {}
    for i, col in ipairs(LIST_COLUMNS) do
        local fs = NewText(panel.ratingsBody, 10)
        fs:SetText(col.title)
        fs:SetTextColor(0.6, 0.6, 0.6, 1)
        panel.listTitles[i] = fs
    end
    panel.listRows = {}

    -- Season titles
    panel.titlesHeader = CreateSectionHeader(content, "Season titles", "titles")
    panel.titlesBody = CreateSectionBody(content)
    panel.titleTiles = {}
    for i = 1, #(PVPHUB._TITLE_META or {}) do
        panel.titleTiles[i] = CreateTitleTile(panel.titlesBody)
    end

    -- Rating history: bracket/spec chips, the graph, legend and range chips
    panel.historyHeader = CreateSectionHeader(content, "Rating history", "history")
    panel.historyBody = CreateSectionBody(content)
    panel.historyRow = CreateFrame("Frame", nil, panel.historyBody)
    panel.historyRow:SetHeight(20)
    panel.seriesChips = {}
    panel.graph = CreateGraph(panel.historyBody)

    panel.legendRow = CreateFrame("Frame", nil, panel.historyBody)
    panel.legendRow:SetHeight(20)
    panel.legend = NewText(panel.legendRow, 10)
    panel.legend:SetPoint("LEFT", 2, 0)
    panel.legend:SetText(string.format(
        "|TInterface\\Buttons\\WHITE8x8:3:14:0:0:8:8:0:8:0:8:%d:%d:%d|t |cffccccccCR|r     |TInterface\\Buttons\\WHITE8x8:2:14:0:0:8:8:0:8:0:8:%d:%d:%d|t |cffccccccMMR|r     |cff777777hover for details|r",
        CR_COLOR[1] * 255, CR_COLOR[2] * 255, CR_COLOR[3] * 255,
        MMR_COLOR[1] * 255, MMR_COLOR[2] * 255, MMR_COLOR[3] * 255))
    panel.rangeChips = {}
    for i, range in ipairs(RANGES) do
        local chip = CreateChip(panel.legendRow, function(self)
            Cards.graphRange = self.range
            if Cards.selected then PaintHistory(panel, Cards.selected, Cards.historyWidth or 400) end
        end)
        chip.range = range.key
        chip.text:SetText(range.text)
        chip:SetWidth(56)
        chip:SetPoint("TOPRIGHT", panel.legendRow, "TOPRIGHT", -(#RANGES - i) * 60, 0)
        panel.rangeChips[i] = chip
    end

    -- Gear
    panel.gearHeader = CreateSectionHeader(content, "Gear", "gear")
    panel.gearBody = CreateSectionBody(content)
    panel.gearStamp = NewText(panel.gearBody, 10)
    panel.gearStamp:SetJustifyH("RIGHT")
    panel.noGear = NewText(panel.gearBody, 11)
    panel.noGear:SetText("|cff777777Log in on this character once to record its gear.|r")
    panel.gearRows = {}
    for slot in pairs(Cards.GEAR_SLOTS) do
        panel.gearRows[slot] = CreateGearRow(panel.gearBody)
    end

    -- Currencies
    panel.currencyHeader = CreateSectionHeader(content, "Currencies", "currencies")
    panel.currencyBody = CreateSectionBody(content)
    panel.currencies = NewText(panel.currencyBody, 12)

    panel.empty = NewText(panel, 13)
    panel.empty:SetPoint("CENTER")
    panel.empty:SetText("|cff777777Select a character|r")

    f.cardDetail = panel
    return panel
end

local function LastSeenText(lastSeen)
    if not lastSeen then return "|cff666666unknown|r" end
    local days = math.floor((GetServerTime() - lastSeen) / 86400)
    if days <= 0 then return "|cff44ff44today|r" end
    if days == 1 then return "|cffccff44yesterday|r" end
    if days < 7 then return string.format("|cffffaa22%d days ago|r", days) end
    return string.format("|cffff6644%d days ago|r", days)
end

local function PaintDetail(f, charKey, width)
    local panel = GetDetail(f)
    local data, season, archived = DetailData(charKey)
    local colors = GetColors()
    local base = colors.WINDOW_BG or { 0.08, 0.05, 0.05 }
    panel.bg:SetVertexColor(base[1] * 1.6, base[2] * 1.6, base[3] * 1.6, 0.55)
    local hc = CardStyle().heading
    panel.sepLeft:SetGradient("HORIZONTAL", CreateColor(hc[1], hc[2], hc[3], 0), CreateColor(hc[1], hc[2], hc[3], 0.6))
    panel.sepRight:SetGradient("HORIZONTAL", CreateColor(hc[1], hc[2], hc[3], 0.6), CreateColor(hc[1], hc[2], hc[3], 0))

    panel.content:SetShown(data ~= nil)
    panel.empty:SetShown(data == nil)
    if not data then return 0 end

    local contentW = width - DETAIL_PAD * 2
    panel.content:SetWidth(contentW)
    local cc, token = ClassColor(data)

    -- Header
    PaintPortrait(panel.portrait, data)
    panel.name:SetText(cc:WrapTextInColorCode(data.displayName or charKey:match("^([^%-]+)") or charKey))

    local className = (LOCALIZED_CLASS_NAMES_MALE and LOCALIZED_CLASS_NAMES_MALE[token]) or token
    local raceName = RaceName(data.race)
    local line2 = raceName and (raceName .. " " .. className) or className
    if (data.level or 0) > 0 then line2 = "Level " .. data.level .. " " .. line2 end
    local spec = PVPHUB._GetCachedSpecInfo(data.specID)
    if spec and spec.name then
        line2 = line2 .. "  ·  " .. (spec.icon and (IconMarkup(spec.icon, 12) .. " ") or "") .. spec.name
    end
    panel.line2:SetText("|cffdddddd" .. line2 .. "|r")

    local line3 = { "|cffaaaaaa" .. (charKey:match("%-(.+)$") or "") .. "|r" }
    if (data.itemLevel or 0) > 0 then
        line3[#line3 + 1] = "|cffaaaaaaItem level|r " .. math.floor(data.itemLevel)
    end
    if (data.pvpItemLevel or 0) > 0 then
        line3[#line3 + 1] = "|cffaaaaaaPvP|r " .. data.pvpItemLevel
    end
    panel.line3:SetText(table.concat(line3, "   "))

    local line4 = "|cffaaaaaaLast seen|r " .. LastSeenText(data.lastSeen)
    local groups = PVPHUB_SETTINGS.characterGroups
    if groups and groups.enabled and groups.groups then
        local group = groups.groups[PVPHUB._GetCharacterGroup(charKey)]
        if group and not group.isDefault then
            line4 = line4 .. "   |cffaaaaaaGroup|r " .. group.name
        end
    end
    if archived then
        line4 = line4 .. "   |cffffd100Showing " .. PVPHUB.Seasons.Name(season) .. " (archive)|r"
    elseif PVPHUB._IsCharacterStaleThisSeason(charKey) then
        line4 = line4 .. "   |cff777777(last season's data)|r"
    end
    panel.line4:SetText(line4)

    local past = PVPHUB.Seasons and PVPHUB.Seasons.List(charKey) or {}
    panel.seasonBtn.charKey = charKey
    panel.seasonBtn:SetText(archived and PVPHUB.Seasons.Name(season) or "Current season")
    panel.seasonBtn:SetShown(#past > 0)

    local y = BIG_PORTRAIT + 14

    -- Places a section's header bar at top and shows or hides its content.
    -- Returns where the content starts and whether the section is open.
    local function Section(header, body, top)
        header:ClearAllPoints()
        header:SetPoint("TOPLEFT", panel.content, "TOPLEFT", 0, -top)
        header:SetWidth(contentW)
        local open = SectionOpen(header.key)
        PaintSectionHeader(header)
        header.toggle:SetText(ToggleText(open))
        body:SetShown(open)
        return top + 26, open
    end

    -- One function per section: lays it out from top and returns where the
    -- next one may start. They're drawn in the user's order (drag a
    -- section's header bar, see SectionOrder).
    local paint = {}

    -- Three rating tiles, the other brackets in a list under them
    paint.ratings = function(top)
        local at, open = Section(panel.ratingsHeader, panel.ratingsBody, top)
        if not open then return at end
        at = at + 4

        local ratingRows = CollectRatingRows(data, season)
        panel.noRatings:SetText(archived and "|cff777777No rated games archived for this season|r"
            or "|cff777777No rated games this season|r")
        panel.noRatings:SetShown(#ratingRows == 0)
        if #ratingRows == 0 then
            panel.noRatings:ClearAllPoints()
            panel.noRatings:SetPoint("TOPLEFT", panel.content, "TOPLEFT", 4, -at)
            at = at + 22
        end

        -- Each tile's graph series, and the one the graph shows
        local seriesList = CollectSeries(data, season)
        local byID = {}
        for _, s in ipairs(seriesList) do byID[s.id] = s end
        local chosen, emptyPick = ChosenSeries(charKey, seriesList, ratingRows)
        -- The bracket the graph shows, recorded matches or not
        local function Shown(info, series)
            return (series ~= nil and series == chosen) or info == emptyPick
        end

        local tileInfos, rest = SplitRatingRows(charKey, ratingRows)
        -- For the right-click menu (Cards.OpenTileMenu, Cards.SetTile)
        Cards.shownTileInfos, Cards.shownRestInfos, Cards.shownTiles = tileInfos, rest, {}

        local tileW = math.floor((contentW - TILE_GAP * (TILE_COUNT - 1)) / TILE_COUNT)
        for i, info in ipairs(tileInfos) do
            local t = panel.tiles[i] or CreateRatingTile(panel.ratingsBody)
            panel.tiles[i] = t
            t.charKey, t.slot = charKey, i
            Cards.shownTiles[i] = info.id
            t:ClearAllPoints()
            t:SetPoint("TOPLEFT", panel.content, "TOPLEFT", (i - 1) * (tileW + TILE_GAP), -at)
            local series = byID[info.id]
            PaintRatingTile(t, info, data, series, Shown(info, series), tileW)
            t:Show()
        end
        for i = #tileInfos + 1, #panel.tiles do panel.tiles[i]:Hide() end
        if #tileInfos > 0 then at = at + TILE_HEIGHT end

        -- The rest as rows, like the old ratings table
        local hasList = #rest > 0
        panel.listSep:SetShown(hasList)
        for _, fs in ipairs(panel.listTitles) do fs:SetShown(hasList) end
        if hasList then
            at = at + 14
            panel.listSep:ClearAllPoints()
            panel.listSep:SetPoint("TOPLEFT", panel.content, "TOPLEFT", 0, -at)
            panel.listSep:SetWidth(contentW)
            at = at + 12
            for i, col in ipairs(LIST_COLUMNS) do
                panel.listTitles[i]:ClearAllPoints()
                panel.listTitles[i]:SetPoint("TOPLEFT", panel.content, "TOPLEFT", math.floor(contentW * col.x), -at)
            end
            at = at + 14
        end
        for i, info in ipairs(rest) do
            local row = panel.listRows[i] or CreateRatingRow(panel.ratingsBody)
            panel.listRows[i] = row
            row.charKey, row.slot = charKey, nil
            row:ClearAllPoints()
            row:SetPoint("TOPLEFT", panel.content, "TOPLEFT", 0, -at)
            local series = byID[info.id]
            PaintRatingRow(row, info, data, series, Shown(info, series), contentW)
            row:Show()
            at = at + LIST_ROW_H
        end
        for i = #rest + 1, #panel.listRows do panel.listRows[i]:Hide() end
        return at
    end

    -- Season titles, side by side
    paint.titles = function(top)
        local at, open = Section(panel.titlesHeader, panel.titlesBody, top)
        if not open then return at end
        local metas = PVPHUB._TITLE_META or {}
        if #metas == 0 then return at end
        local stale = not archived and PVPHUB._IsCharacterStaleThisSeason(charKey)
        local tileW = math.floor((contentW - TITLE_TILE_GAP * (#metas - 1)) / #metas)
        for i, meta in ipairs(metas) do
            local tile = panel.titleTiles[i]
            tile:ClearAllPoints()
            tile:SetPoint("TOPLEFT", panel.content, "TOPLEFT", (i - 1) * (tileW + TITLE_TILE_GAP), -at)
            PaintTitleTile(tile, meta, data.titleProgress and data.titleProgress[meta.key], tileW, stale)
            tile:Show()
        end
        return at + TITLE_TILE_HEIGHT
    end

    -- Rating history graph
    paint.history = function(top)
        local at, open = Section(panel.historyHeader, panel.historyBody, top)
        if not open then return at end
        panel.historyRow:ClearAllPoints()
        panel.historyRow:SetPoint("TOPLEFT", panel.content, "TOPLEFT", 0, -at)
        panel.historyRow:SetWidth(contentW)
        at = at + 26
        panel.graph:ClearAllPoints()
        panel.graph:SetPoint("TOPLEFT", panel.content, "TOPLEFT", 0, -at)
        at = at + GRAPH_HEIGHT + 6
        panel.legendRow:ClearAllPoints()
        panel.legendRow:SetPoint("TOPLEFT", panel.content, "TOPLEFT", 0, -at)
        panel.legendRow:SetWidth(contentW)
        at = at + 22
        Cards.historyWidth = contentW
        PaintHistory(panel, charKey, contentW)
        return at
    end

    -- Gear: two columns of slots, recorded the last time this character
    -- was played. The "Recorded" stamp sits on the header's right, left of
    -- its + / –.
    paint.gear = function(top)
        local at, open = Section(panel.gearHeader, panel.gearBody, top)
        panel.gearStamp:ClearAllPoints()
        panel.gearStamp:SetPoint("TOPRIGHT", panel.content, "TOPRIGHT", -24, -top - 4)
        if not open then return at end
        local gear = data.gear
        if type(gear) == "table" then
            local colW = math.floor((contentW - GEAR_COL_GAP) / 2)
            for c, slots in ipairs(GEAR_COLUMNS) do
                for r, slot in ipairs(slots) do
                    local row = panel.gearRows[slot]
                    row:ClearAllPoints()
                    row:SetPoint("TOPLEFT", panel.content, "TOPLEFT",
                        (c - 1) * (colW + GEAR_COL_GAP), -(at + (r - 1) * GEAR_ROW_HEIGHT))
                    PaintGearRow(row, slot, gear[slot], colW)
                    row:Show()
                end
            end
            panel.gearStamp:SetText("|cff888888Recorded|r " .. LastSeenText(data.gearUpdated))
            panel.gearStamp:Show()
            panel.noGear:Hide()
            return at + #GEAR_COLUMNS[1] * GEAR_ROW_HEIGHT
        end
        for _, row in pairs(panel.gearRows) do row:Hide() end
        panel.gearStamp:Hide()
        panel.noGear:ClearAllPoints()
        panel.noGear:SetPoint("TOPLEFT", panel.content, "TOPLEFT", 4, -at)
        panel.noGear:Show()
        return at + 20
    end

    -- Currencies
    paint.currencies = function(top)
        local at, open = Section(panel.currencyHeader, panel.currencyBody, top)
        if not open then return at end
        local fmt, color = PVPHUB._FormatNumber, PVPHUB._GetCurrencyColor
        local honor, conquest = data.honor or 0, data.conquest or 0
        local helio, tokens = data.bloodstones or 0, data.bloodytokens or 0
        panel.currencies:ClearAllPoints()
        panel.currencies:SetPoint("TOPLEFT", panel.content, "TOPLEFT", 0, -at)
        panel.currencies:SetText(string.format(
            "%s %s%s|r      %s %s%s|r      %s %s%s|r      %s %s%s|r      %s %s",
            "|T1455894:14:14:0:0|t", color(honor, "honor", data), fmt(honor),
            "|T1523630:14:14:0:0|t", color(conquest, "conquest", data), fmt(conquest),
            "|T134128:14:14:0:0|t", color(helio, "bloodstones", data), fmt(helio),
            "|T4638431:14:14:0:0|t", color(tokens, "bloodytokens", data), fmt(tokens),
            "|TInterface\\MoneyFrame\\UI-GoldIcon:14:14:0:0|t", fmt(math.floor((data.gold or 0) / 10000))))
        return at + 20
    end

    -- Draw them in order; remember where each one sits for dragging
    panel.sectionLayout = {}
    for i, key in ipairs(SectionOrder()) do
        local top = (i == 1) and y or (y + 16)
        y = paint[key](top)
        panel.sectionLayout[i] = { key = key, top = top, bottom = y }
    end

    -- Note last: its wrapped height only adds to the total, nothing below it
    -- depends on it
    if data.note and data.note ~= "" then
        y = y + 12
        panel.note:ClearAllPoints()
        panel.note:SetPoint("TOPLEFT", panel.content, "TOPLEFT", 0, -y)
        panel.note:SetWidth(contentW)
        panel.note:SetText("|cffFFD700Note:|r " .. data.note)
        panel.note:Show()
        y = y + math.max(14, panel.note:GetStringHeight() or 14)
    else
        panel.note:Hide()
    end

    panel.content:SetHeight(y)
    return y
end

-- Collapses or expands one of the info panel's sections (saved) and
-- redraws the panel where it is, without scrolling back to the top
function Cards.ToggleSection(key)
    PVPHUB_SETTINGS.mainWindow = PVPHUB_SETTINGS.mainWindow or {}
    local sections = PVPHUB_SETTINGS.mainWindow.cardSections or {}
    PVPHUB_SETTINGS.mainWindow.cardSections = sections
    sections[key] = not SectionOpen(key)
    Cards.RefreshDetail()
end

-- Redraws the info panel where it is, without scrolling back to the top
function Cards.RefreshDetail()
    local f = PVPHUB.window
    if f and f.cardDetail and Cards.selected then
        PaintDetail(f, Cards.selected, Cards.detailWidth or 400)
    end
end

-- Shows a character's current season (season = nil) or an archived one in
-- the info panel, from the top
function Cards.ShowSeason(charKey, season)
    Cards.viewSeason[charKey] = season
    local f = PVPHUB.window
    if f and f.cardDetail and Cards.selected == charKey then
        f.cardDetail.scroll:SetVerticalScroll(0)
        PaintDetail(f, charKey, Cards.detailWidth or 400)
    end
end

-- The season menu: the current season, then the character's archived ones,
-- newest first, each with when it was last played
function Cards.OpenSeasonMenu(owner)
    local charKey = owner.charKey
    if not charKey or not MenuUtil or not PVPHUB.Seasons then return end
    MenuUtil.CreateContextMenu(owner, function(_, root)
        root:CreateTitle("Show season")
        local function Add(text, season)
            root:CreateRadio(text,
                function() return Cards.viewSeason[charKey] == season end,
                function()
                    Cards.ShowSeason(charKey, season)
                    return MenuResponse and MenuResponse.Close
                end)
        end
        Add("Current season", nil)
        for _, s in ipairs(PVPHUB.Seasons.List(charKey)) do
            local text = PVPHUB.Seasons.Name(s.season)
            if s.lastPlayed > 0 then
                text = text .. "  |cff888888last played " .. PVPHUB._FormatTimestamp(s.lastPlayed) .. "|r"
            end
            Add(text, s.season)
        end
    end)
end

-- Dragging a section's header bar moves the whole section. A gold line
-- in the info panel shows where it will land; near the panel's top or
-- bottom edge it scrolls. PaintDetail records where each section sits
-- (panel.sectionLayout).
local sectionDrag = {}

local function SectionDragOnUpdate()
    local f = PVPHUB.window
    local panel = f and f.cardDetail
    if not (sectionDrag.active and panel and sectionDrag.source:IsVisible()) then
        sectionDrag.target = nil
        Cards.EndSectionDrag()
        return
    end

    local ghost = sectionDrag.ghost
    local gs = ghost:GetEffectiveScale()
    local cx, cy = GetCursorPosition()
    ghost:ClearAllPoints()
    ghost:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", cx / gs - sectionDrag.grabX, cy / gs - sectionDrag.grabY)

    -- The cursor in the panel's own units
    local scale = panel.content:GetEffectiveScale()
    local y = cy / scale
    local scroll = panel.scroll
    local top, bottom = scroll:GetTop(), scroll:GetBottom()
    if top and bottom then
        local current, range = scroll:GetVerticalScroll(), scroll:GetVerticalScrollRange()
        if y > top - DRAG_EDGE and current > 0 then
            scroll:SetVerticalScroll(math.max(0, current - DRAG_SCROLL))
        elseif y < bottom + DRAG_EDGE and current < range then
            scroll:SetVerticalScroll(math.min(range, current + DRAG_SCROLL))
        end
    end

    -- Lands in front of the first section whose middle is below the cursor
    local contentTop = panel.content:GetTop()
    local layout = panel.sectionLayout or {}
    if not contentTop or #layout == 0 then return end
    local rel = contentTop - y
    local beforeKey, markY
    for _, s in ipairs(layout) do
        if rel < (s.top + s.bottom) / 2 then
            beforeKey, markY = s.key, s.top - 8
            break
        end
    end
    if not beforeKey then markY = layout[#layout].bottom + 6 end

    -- Dropping right where it already is changes nothing
    local order = SectionOrder()
    local from
    for i, key in ipairs(order) do
        if key == sectionDrag.key then from = i end
    end
    local unchanged = beforeKey == sectionDrag.key or beforeKey == order[from + 1]
        or (beforeKey == nil and from == #order)
    sectionDrag.target = (not unchanged) and { before = beforeKey } or nil

    local marker = sectionDrag.marker
    if sectionDrag.target then
        marker:ClearAllPoints()
        marker:SetPoint("TOPLEFT", panel.content, "TOPLEFT", 0, -markY)
        marker:SetPoint("TOPRIGHT", panel.content, "TOPRIGHT", 0, -markY)
        marker:Show()
    else
        marker:Hide()
    end
end

function Cards.BeginSectionDrag(header)
    local f = PVPHUB.window
    local panel = f and f.cardDetail
    if sectionDrag.active or not panel or drag.active then return end
    -- An exact copy of the header bar follows the cursor, like the cards'
    if not sectionDrag.ghost then
        local g = CreateSectionHeader(UIParent, "", nil)
        g:SetFrameStrata("TOOLTIP")
        g:EnableMouse(false)
        local bg = g:CreateTexture(nil, "BACKGROUND")
        bg:SetAllPoints()
        bg:SetTexture(WHITE)
        bg:SetVertexColor(0.03, 0.03, 0.04, 0.97)
        g:Hide()
        sectionDrag.ghost = g
    end
    if not sectionDrag.marker then
        local marker = panel.content:CreateTexture(nil, "OVERLAY", nil, 7)
        marker:SetTexture(WHITE)
        marker:SetHeight(2)
        marker:SetVertexColor(1, 0.82, 0, 1)
        marker:Hide()
        sectionDrag.marker = marker
    end
    sectionDrag.active, sectionDrag.source, sectionDrag.key = true, header, header.key
    local g = sectionDrag.ghost
    g.title:SetText(header.title:GetText() or "")
    g.toggle:SetText(header.toggle:GetText() or "")
    g:SetSize(header:GetWidth(), header:GetHeight())
    g:SetScale(header:GetEffectiveScale() / UIParent:GetEffectiveScale())
    g:SetAlpha(0.9)
    local cx, cy = GetCursorPosition()
    local s = header:GetEffectiveScale()
    sectionDrag.grabX = cx / s - header:GetLeft()
    sectionDrag.grabY = cy / s - header:GetTop()
    g:Show()
    header:SetAlpha(0.35)
    if not sectionDrag.driver then sectionDrag.driver = CreateFrame("Frame") end
    sectionDrag.driver:SetScript("OnUpdate", SectionDragOnUpdate)
end

function Cards.EndSectionDrag()
    if not sectionDrag.active then return end
    sectionDrag.active = false
    sectionDrag.driver:SetScript("OnUpdate", nil)
    sectionDrag.ghost:Hide()
    sectionDrag.marker:Hide()
    sectionDrag.source:SetAlpha(1)
    Cards.dragEndedAt = GetTime()

    local key, target = sectionDrag.key, sectionDrag.target
    sectionDrag.source, sectionDrag.target = nil, nil
    if not target then return end

    local order = SectionOrder()
    for i = #order, 1, -1 do
        if order[i] == key then table.remove(order, i) end
    end
    local pos = #order + 1
    for i, k in ipairs(order) do
        if k == target.before then
            pos = i
            break
        end
    end
    table.insert(order, pos, key)
    PVPHUB_SETTINGS.mainWindow = PVPHUB_SETTINGS.mainWindow or {}
    PVPHUB_SETTINGS.mainWindow.cardSectionOrder = order

    local f = PVPHUB.window
    if f and f.cardDetail and Cards.selected then
        PaintDetail(f, Cards.selected, Cards.detailWidth or 400)
    end
end

-- Shows another character's information without rebuilding the window
function Cards.Select(charKey)
    Cards.selected = charKey
    local f = PVPHUB.window
    if not f then return end
    for _, card in ipairs(Cards.pool) do
        if card:IsShown() and card.entry then
            PaintCharCard(card, card.entry, card:GetWidth(), card.charKey == charKey)
        end
    end
    if f.cardDetail then f.cardDetail.scroll:SetVerticalScroll(0) end
    PaintDetail(f, charKey, Cards.detailWidth or 400)
end

-- --------------------------------------------------------------------------
-- Rendering
-- --------------------------------------------------------------------------

-- The character cards live in their own frame inside the list's scroll child. Marked
-- _pvpKeep so f:UpdateContent doesn't detach it along with the list's rows.
local function GetContainer(f)
    if not Cards.container then
        local c = CreateFrame("Frame", nil, f.contentFrame)
        c:SetPoint("TOPLEFT", f.contentFrame, "TOPLEFT", 0, 0)
        c._pvpKeep = true
        Cards.container = c
    end
    return Cards.container
end

-- Turns character groups on or off (the card view's "Groups" switch) and
-- redraws the list; the Settings switch picks it up when it's next shown
function Cards.SetGroupsEnabled(on)
    if not PVPHUB_SETTINGS.characterGroups then
        PVPHUB_SETTINGS.characterGroups = {
            groups = { { name = "No Group", characters = {}, collapsed = false, isDefault = true } },
            enabled = false,
        }
    end
    PVPHUB_SETTINGS.characterGroups.enabled = on
    local f = PVPHUB.window
    if f and f.UpdateContent then f:UpdateContent() end
end

-- Splits the area: the info panel on the left, the card list (the main
-- scroll frame, narrowed) on the right.
local function SetCardArea(f)
    local areaW = f:GetWidth() - AREA_LEFT - AREA_RIGHT
    local listW = math.max(LIST_MIN_W, math.floor(areaW * LIST_SHARE))
    local detailW = areaW - listW - COLUMN_GAP
    local listX = AREA_LEFT + detailW + COLUMN_GAP

    -- The list starts level with the info panel: New Group, the Groups
    -- switch and the search box are in the toolbar row above (LayoutToolbar)
    f.scrollFrame:ClearAllPoints()
    f.scrollFrame:SetPoint("TOPLEFT", f, "TOPLEFT", listX, AREA_TOP)
    f.scrollFrame:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -AREA_RIGHT, AREA_BOTTOM)

    local panel = GetDetail(f)
    panel:ClearAllPoints()
    panel:SetPoint("TOPLEFT", f, "TOPLEFT", AREA_LEFT, AREA_TOP)
    panel:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", AREA_LEFT, AREA_BOTTOM)
    panel:SetWidth(detailW)
    panel:Show()
    return listW, detailW
end

-- --------------------------------------------------------------------------
-- Search
-- --------------------------------------------------------------------------
-- The toolbar's search box filters the cards and the list as you type: a
-- character matches when its name, realm, class or spec contains the text.
-- Groups show only their matches, expanded even when collapsed, and groups
-- without matches are left out. Dragging is paused while searching.

Cards.searchText = ""

local function MatchesSearch(entry, query)
    local data = entry.data
    local _, token = ClassColor(data)
    local spec = PVPHUB._GetCachedSpecInfo(data.specID)
    local text = table.concat({
        data.displayName or "",
        entry.char or "",
        (LOCALIZED_CLASS_NAMES_MALE and LOCALIZED_CLASS_NAMES_MALE[token]) or token or "",
        (spec and spec.name) or "",
    }, " "):lower()
    return text:find(query, 1, true) ~= nil
end

local function BuildSearchList(displayList, sorted, query)
    query = query:lower()
    local out, headers = {}, {}
    for _, entry in ipairs(displayList) do
        if entry.isGroupHeader then headers[#headers + 1] = entry end
    end
    if #headers == 0 then
        for _, entry in ipairs(sorted or {}) do
            if entry.data and MatchesSearch(entry, query) then out[#out + 1] = entry end
        end
        return out
    end
    for _, header in ipairs(headers) do
        local matches = {}
        for _, entry in ipairs(sorted or {}) do
            if entry.data and PVPHUB._GetCharacterGroup(entry.char) == header.groupIndex
               and MatchesSearch(entry, query) then
                matches[#matches + 1] = entry
            end
        end
        if #matches > 0 then
            out[#out + 1] = {
                isGroupHeader  = true,
                groupData      = header.groupData,   -- the list's group bars use it
                groupIndex     = header.groupIndex,
                groupName      = header.groupName,
                groupIsDefault = header.groupIsDefault,
                groupCollapsed = false,
                characterCount = #matches,
            }
            for _, entry in ipairs(matches) do out[#out + 1] = entry end
        end
    end
    return out
end

-- The list's display list as the search leaves it (core's UpdateContent,
-- for the list view; the card view filters in Render)
function Cards.FilterForSearch(displayList, sorted)
    if Cards.searchText == "" then return displayList end
    return BuildSearchList(displayList, sorted, Cards.searchText)
end

-- Called as the search text changes: redraws just the card view, or the
-- whole list
function Cards.SetSearch(text)
    text = (text or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if text == Cards.searchText then return end
    Cards.searchText = text
    local f = PVPHUB.window
    if not (f and f.currentTab == "characters") then return end
    if Cards.IsActive() and Cards.lastDisplayList then
        local height = Cards.Render(f, Cards.lastDisplayList, Cards.lastSorted)
        f.contentFrame:SetHeight(math.max(height, 100))
        f.scrollFrame:SetVerticalScroll(0)
    elseif not Cards.IsActive() and f.UpdateContent then
        f.scrollFrame:SetVerticalScroll(0)
        f:UpdateContent()
    end
end

-- Lays out the card view. displayList is the list's (groups and
-- characters as shown), sorted every listed character in sort order (the
-- starting point when a drag switches to Custom Order). Returns the card
-- list's height.
function Cards.Render(f, displayList, sorted)
    -- Only on the Characters tab. The window keeps its tab when it's closed,
    -- and the data refresh on opening it again redraws the list on any tab;
    -- the info panel isn't inside the (hidden) scroll frame, so it would sit
    -- on top of the Season or Settings tab. Switching back redraws it.
    if f.currentTab ~= "characters" then
        if f.cardDetail then f.cardDetail:Hide() end
        return 0
    end
    local listW, detailW = SetCardArea(f)
    Cards.detailWidth = detailW
    Cards.lastSorted = sorted
    local container = GetContainer(f)
    if f.viewToggle then Cards.PaintToggle(f.viewToggle) end
    -- The toolbar without Columns, which do nothing here
    Cards.LayoutToolbar(f)

    -- Keep the chosen character while it's listed at all, even inside a
    -- collapsed group; otherwise start with the logged-in one, or the first.
    local present, first = {}, nil
    for _, entry in ipairs(sorted or displayList) do
        if entry.char and entry.data then
            present[entry.char] = true
            first = first or entry.char
        end
    end
    if not (Cards.selected and present[Cards.selected]) then
        local current = PVPHUB._GetFullName()
        Cards.selected = present[current] and current or first
    end

    -- A search shows only the matching characters
    Cards.lastDisplayList = displayList
    local searching = Cards.searchText ~= ""
    local shown = searching and BuildSearchList(displayList, sorted, Cards.searchText) or displayList

    -- Where everything sits, for drag and drop
    local layout = {}
    Cards.layout = layout

    local cardW = listW - 2
    local y, nCards, nHeaders = 0, 0, 0
    local groupIndex   -- the group the following cards belong to
    for _, entry in ipairs(shown) do
        if entry.isGroupHeader then
            nHeaders = nHeaders + 1
            local h = Cards.headers[nHeaders] or CreateGroupHeader(container)
            Cards.headers[nHeaders] = h
            PaintGroupHeader(h, entry)
            h:ClearAllPoints()
            h:SetPoint("TOPLEFT", container, "TOPLEFT", 0, -y)
            h:SetWidth(cardW)
            h:Show()
            groupIndex = entry.groupIndex
            layout[#layout + 1] = { kind = "header", frame = h, groupIndex = groupIndex, top = y, height = GROUP_HEIGHT }
            y = y + GROUP_HEIGHT + 4
        elseif entry.char and entry.data then
            nCards = nCards + 1
            local card = Cards.pool[nCards] or CreateCharCard(container)
            Cards.pool[nCards] = card
            card:ClearAllPoints()
            card:SetPoint("TOPLEFT", container, "TOPLEFT", 0, -y)
            card:SetWidth(cardW)
            PaintCharCard(card, entry, cardW, entry.char == Cards.selected)
            card:Show()
            layout[#layout + 1] = { kind = "card", frame = card, char = entry.char, groupIndex = groupIndex, top = y, height = CARD_HEIGHT }
            y = y + CARD_HEIGHT + CARD_GAP
        end
    end

    for i = nCards + 1, #Cards.pool do
        Cards.pool[i]:Hide()
        Cards.pool[i].charKey, Cards.pool[i].entry = nil, nil
    end
    for i = nHeaders + 1, #Cards.headers do Cards.headers[i]:Hide() end

    -- A search that matches nobody says so
    if not container.noResults then
        container.noResults = NewText(container, 11)
        container.noResults:SetPoint("TOP", container, "TOP", 0, -12)
        container.noResults:SetJustifyH("CENTER")
        container.noResults:SetText("|cff888888No characters match|r")
    end
    container.noResults:SetShown(searching and nCards == 0)
    if searching and nCards == 0 then y = 40 end

    f.contentFrame:SetWidth(listW)
    container:SetSize(listW, math.max(y, 1))
    container:Show()

    -- The window keeps its fixed card view size (Cards.WindowHeight); the
    -- info panel scrolls when the information is taller
    PaintDetail(f, Cards.selected, detailW)
    return y
end

-- Back to the list: hides the card view and gives the scroll area back its
-- usual place below the column headers.
function Cards.Hide(f)
    if Cards.container then Cards.container:Hide() end
    if f.cardDetail then f.cardDetail:Hide() end
    if f.scrollFrame then
        f.scrollFrame:ClearAllPoints()
        f.scrollFrame:SetPoint("TOPLEFT", f, "TOPLEFT", 20, LIST_TOP)
        f.scrollFrame:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -AREA_RIGHT, AREA_BOTTOM)
    end
    if f.viewToggle then Cards.PaintToggle(f.viewToggle) end
    -- The toolbar with Columns again
    Cards.LayoutToolbar(f)
end

-- --------------------------------------------------------------------------
-- List/Cards switch
-- --------------------------------------------------------------------------
-- A segmented control: a faint pill-shaped track with a highlight in the
-- theme's accent color that slides to the active side.

local SWITCH_W, SWITCH_H = 132, 24
local SWITCH_INSET = 2

-- Places the highlight at x; each label brightens as the highlight reaches
-- it and dims as it leaves
local function PlaceThumb(bar, x)
    bar.thumbFrame:ClearAllPoints()
    bar.thumbFrame:SetPoint("LEFT", bar, "LEFT", x, 0)
    local t = (x - SWITCH_INSET) / (SWITCH_W / 2 - SWITCH_INSET)   -- 0 on List, 1 on Cards
    for _, b in ipairs(bar.buttons) do
        local on = (b.mode == "cards") and t or (1 - t)
        if b.hover then on = math.max(on, 0.7) end
        b.text:SetTextColor(0.62 + 0.38 * on, 0.62 + 0.38 * on, 0.66 + 0.34 * on, 1)
    end
end

-- Colors the switch and slides the highlight to the active view (instantly
-- the first time). The slide is UI.Slide's, which doesn't skip frames when
-- the click rebuilds the window in the same frame.
function Cards.PaintToggle(bar, instant)
    local ac = ThemeColor()
    bar.track:SetVertexColor(1, 1, 1, 0.08)
    bar.thumb:SetGradient("VERTICAL",
        CreateColor(ac[1] * 0.55, ac[2] * 0.55, ac[3] * 0.55, 0.95),
        CreateColor(math.min(1, ac[1] * 0.9 + 0.1), math.min(1, ac[2] * 0.9 + 0.1), math.min(1, ac[3] * 0.9 + 0.1), 0.95))
    PVPHUB.UI.Slide(bar, Cards.IsActive() and (SWITCH_W / 2) or SWITCH_INSET, bar.place, instant)
end

local BuildToolbar   -- below, under Toolbar

-- Builds the switch at the left of the Characters tab's toolbar row and the
-- rest of that row (BuildToolbar). SwitchTab shows the switch on the
-- Characters tab only; LayoutToolbar places everything.
function Cards.CreateToggle(f)
    if f.viewToggle then return f.viewToggle end

    local bar = CreateFrame("Frame", nil, f)
    bar:SetSize(SWITCH_W, SWITCH_H)
    bar:SetPoint("TOPLEFT", f, "TOPLEFT", TOOLBAR_LEFT, TOOLBAR_Y)

    -- Track: a faint lighter pill, no outline. Track and highlight are
    -- smooth textures (UI.CreatePill), not masked shapes, which left a thin
    -- line at the left end.
    bar.track = PVPHUB.UI.CreatePill(bar, "BACKGROUND", 0)

    -- The sliding highlight behind the active label
    bar.thumbFrame = CreateFrame("Frame", nil, bar)
    bar.thumbFrame:SetSize(SWITCH_W / 2 - SWITCH_INSET, SWITCH_H - SWITCH_INSET * 2)
    bar.thumb = PVPHUB.UI.CreatePill(bar.thumbFrame, "ARTWORK", 0)
    bar.place = function(x) PlaceThumb(bar, x) end
    local function Repaint() PlaceThumb(bar, bar.pvpSlide and bar.pvpSlide.value or SWITCH_INSET) end

    bar.buttons = {}
    local modes = {
        { key = "list",  text = "List",  tip = "Show your characters as a list" },
        { key = "cards", text = "Cards", tip = "Pick a character from cards and see all of its information" },
    }
    for i, mode in ipairs(modes) do
        local b = CreateFrame("Button", nil, bar)
        b:SetSize(SWITCH_W / 2, SWITCH_H)
        b:SetPoint("LEFT", bar, "LEFT", (i - 1) * SWITCH_W / 2, 0)
        b:SetFrameLevel(bar.thumbFrame:GetFrameLevel() + 1)
        b.mode = mode.key

        b.text = NewText(b, 11)
        b.text:SetPoint("CENTER", 0, 0)
        b.text:SetJustifyH("CENTER")
        b.text:SetText(mode.text)

        b:SetScript("OnClick", function()
            if Cards.IsActive() ~= (mode.key == "cards") then
                Cards.SetActive(mode.key == "cards")
            end
        end)
        b:SetScript("OnEnter", function(self)
            self.hover = true
            Repaint()
            GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
            GameTooltip:SetText(mode.text, 1, 1, 1)
            GameTooltip:AddLine(mode.tip, 0.7, 0.7, 0.7, true)
            GameTooltip:Show()
        end)
        b:SetScript("OnLeave", function(self)
            self.hover = nil
            Repaint()
            GameTooltip:Hide()
        end)
        bar.buttons[i] = b
    end

    -- A "NEW" tag under "Cards" for all of 7.0 (gone with 7.1), so players
    -- find the card view; it isn't tied to being seen or hovered. It sits
    -- between the title row and the content, out of the toolbar's way (its
    -- blink animation sets its alpha, so it can't be faded out for room).
    if PVPHUB.CreateNewBadge then
        local badge = PVPHUB.CreateNewBadge(bar, {}, "7.0")
        badge:SetPoint("TOP", bar.buttons[2], "BOTTOM", 0, -3)
        badge:SetFrameLevel(bar.buttons[2]:GetFrameLevel() + 2)
        bar.newBadge = badge
    end

    f.viewToggle = bar
    Cards.PaintToggle(bar, true)
    bar:SetShown(f.currentTab == "characters")
    BuildToolbar(f, bar)
    f:HookScript("OnSizeChanged", function() Cards.LayoutToolbar(f) end)
    Cards.LayoutToolbar(f)
    return bar
end

-- --------------------------------------------------------------------------
-- Toolbar
-- --------------------------------------------------------------------------
-- In the title row: List/Cards after the title (its NEW tag under it),
-- then the greeting when there's room; search, Groups, "+" (core's
-- f.manageGroupsBtn, while groups are on), Columns (list only, core's
-- PVPHUBColumnDropdown) and Sort (PVPHUBSortDropdown) before the close
-- button, each in a thin frame. What's left goes to the search first (it
-- hides below SEARCH_MIN_W), then the greeting. The list view is at least
-- 820 wide for this (core), the card view 760.

-- The search box and the Groups switch. A child of the List/Cards switch,
-- so the row shows on the Characters tab only, as the switch does.
function BuildToolbar(f, bar)
    local tb = CreateFrame("Frame", nil, bar)
    tb:SetAllPoints(bar)   -- the items are anchored to the window
    f.toolbar = tb

    -- Blizzard's search box (magnifier, placeholder, clear button)
    local s = CreateFrame("EditBox", nil, tb, "SearchBoxTemplate")
    s:SetAutoFocus(false)
    s:SetMaxLetters(40)
    s:SetHeight(TOOLBAR_H - 4)
    s:HookScript("OnTextChanged", function(self) Cards.SetSearch(self:GetText()) end)
    PVPHUB.UI.SkinToolSearch(s)
    tb.search = s

    -- Groups on or off, the same setting as Settings > Display > Enable
    -- Character Groups; the whole frame is clickable
    local g = CreateFrame("Frame", nil, tb)
    g:SetSize(GROUPS_W, TOOLBAR_H)
    local cb = CreateFrame("CheckButton", nil, g, "UICheckButtonTemplate")
    cb:SetSize(30, TOOLBAR_H)
    cb:SetPoint("LEFT", g, "LEFT", 9, 0)
    cb.Text = cb.Text or NewText(cb, 12)
    cb.Text:SetText("Groups")
    cb.Text:SetTextColor(0.9, 0.9, 0.9, 1)
    cb:SetHitRectInsets(-9, -(GROUPS_W - 39), 0, 0)
    cb:SetScript("OnClick", function(self)
        Cards.SetGroupsEnabled(self:GetChecked() and true or false)
    end)
    cb:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
        GameTooltip:SetText("Character groups", 1, 1, 1)
        GameTooltip:AddLine("Show your characters in their groups, or as one list.", 0.7, 0.7, 0.7, true)
        GameTooltip:Show()
    end)
    cb:SetScript("OnLeave", function() GameTooltip:Hide() end)
    PVPHUB.UI.SkinSwitch(cb)
    PVPHUB.UI.AddToolFrame(g, nil, cb)
    g.switch = cb
    tb.groups = g
end

-- Puts a dropdown's box (22 in from the frame's left, 2 from its right, 5
-- from the top; its tool frame 4) with its right edge `right` from the
-- window's right, top at the toolbar's. Returns the box's width.
local function PlaceDropdown(f, dd, right)
    dd:ClearAllPoints()
    dd:SetPoint("TOPRIGHT", f, "TOPRIGHT", -(right - 2), TOOLBAR_Y + 4)
    return dd:GetWidth() - 24
end

-- Places the row for the current view and width: on every render of the
-- Characters tab (Render, Hide), when the window's size changes, and from
-- core's UpdateGreetingLayout. Shows and hides items only on that tab.
function Cards.LayoutToolbar(f)
    local bar, tb = f.viewToggle, f.toolbar
    if not (bar and tb) then return end
    local cards = Cards.IsActive()
    local onTab = f.currentTab == "characters"
    local groups = PVPHUB_SETTINGS.characterGroups
    local groupsOn = groups and groups.enabled and true or false

    bar:ClearAllPoints()
    bar:SetPoint("TOPLEFT", f, "TOPLEFT", TOOLBAR_LEFT, TOOLBAR_Y)
    local left = TOOLBAR_LEFT + bar:GetWidth() + 14

    -- From the close button leftwards
    local right = TOOLBAR_RIGHT
    local sort = _G.PVPHUBSortDropdown
    if sort then
        PVPHUB.UI.SkinToolDropdown(sort)
        right = right + PlaceDropdown(f, sort, right) + TOOL_GAP
    end
    local columns = _G.PVPHUBColumnDropdown
    if columns then
        PVPHUB.UI.SkinToolDropdown(columns)
        if onTab then columns:SetShown(not cards) end
        if not cards then right = right + PlaceDropdown(f, columns, right) + TOOL_GAP end
    end
    local plus = f.manageGroupsBtn
    if plus then
        if onTab then plus:SetShown(groupsOn) end
        plus:ClearAllPoints()
        plus:SetPoint("TOPRIGHT", f, "TOPRIGHT", -right, TOOLBAR_Y)
        plus:SetFrameLevel(tb:GetFrameLevel() + 5)
        if groupsOn then right = right + plus:GetWidth() + TOOL_GAP end
    end
    tb.groups:ClearAllPoints()
    tb.groups:SetPoint("TOPRIGHT", f, "TOPRIGHT", -right, TOOLBAR_Y)
    tb.groups.switch:SetChecked(groupsOn)
    right = right + GROUPS_W + TOOL_GAP

    -- The search: the room left, up to SEARCH_MAX_W; its frame reaches 6
    -- left of the box and 2 above it
    local searchW = math.min(SEARCH_MAX_W, f:GetWidth() - right - left)
    tb.search:SetShown(searchW >= SEARCH_MIN_W)
    tb.search:ClearAllPoints()
    tb.search:SetPoint("TOPRIGHT", f, "TOPRIGHT", -right, TOOLBAR_Y - 2)
    tb.search:SetWidth(math.max(1, searchW - 6))
    if tb.search:IsShown() then right = right + searchW + 8 end

    -- The greeting (when it's on) between List/Cards and the search, cut
    -- short with "..." when it doesn't fit; no underline in this row
    if f.greeting then
        local room = f:GetWidth() - right - left
        f.greeting:ClearAllPoints()
        f.greeting:SetPoint("LEFT", f, "TOPLEFT", left, TOOLBAR_Y - TOOLBAR_H / 2)
        f.greeting:SetPoint("RIGHT", f, "TOPRIGHT", -right, TOOLBAR_Y - TOOLBAR_H / 2)
        f.greeting:SetJustifyH("LEFT")
        f.greeting:SetWordWrap(false)
        f.greeting:SetAlpha(room >= 80 and 1 or 0)
        if f.titleLine then f.titleLine:SetAlpha(0) end
    end
end

-- --------------------------------------------------------------------------
-- Gear, level and faction recording
-- --------------------------------------------------------------------------
-- The logged-in character's equipment is saved on login and whenever it
-- changes, so the info panel can show every character's gear:
--   PVPHUB_DB[charKey].gear[slotID] = { link, ilvl, quality, icon, name,
--                                       enchant, gems = { gemItemID, ... } }
-- along with data.level and data.faction for the character cards.
-- Alts show what they had the last time they were played.

-- "Enchanted: %s" (localized) as a pattern that captures the enchant
local enchantPattern
do
    local line = ENCHANTED_TOOLTIP_LINE or "Enchanted: %s"
    line = line:gsub("%%s", "\001")
    line = line:gsub("([%%%(%)%.%+%-%*%?%[%]%^%$])", "%%%1")
    enchantPattern = "^" .. line:gsub("\001", "(.+)") .. "$"
end

local function EnchantText(slot)
    if not (C_TooltipInfo and C_TooltipInfo.GetInventoryItem) then return nil end
    local enchantLine = Enum.TooltipDataLineType and Enum.TooltipDataLineType.ItemEnchantmentPermanent
    local info = C_TooltipInfo.GetInventoryItem("player", slot)
    if not (enchantLine and info and info.lines) then return nil end
    for _, line in ipairs(info.lines) do
        if line.type == enchantLine and line.leftText then
            return line.leftText:match(enchantPattern) or line.leftText
        end
    end
    return nil
end

local function RecordGear()
    local charKey = PVPHUB._GetFullName and PVPHUB._GetFullName()
    local data = charKey and PVPHUB_DB and PVPHUB_DB[charKey]
    if not data then return end

    -- Level and faction for the character cards ("Level 90 Paladin", emblem)
    data.level = UnitLevel("player")
    data.faction = UnitFactionGroup("player")

    local gear = {}
    for slot in pairs(Cards.GEAR_SLOTS) do
        local link = GetInventoryItemLink("player", slot)
        if link then
            local loc = ItemLocation:CreateFromEquipmentSlot(slot)
            local ilvl = (loc and C_Item.DoesItemExist(loc)) and C_Item.GetCurrentItemLevel(loc) or nil
            local name, _, quality = C_Item.GetItemInfo(link)
            local entry = {
                link    = link,
                ilvl    = ilvl,
                quality = GetInventoryItemQuality("player", slot) or quality,
                icon    = GetInventoryItemTexture("player", slot),
                name    = name or link:match("%[(.-)%]"),
                enchant = EnchantText(slot),
            }
            -- Socketed gems: the four fields after the enchant in the item string
            for _, gem in ipairs({ link:match("item:%d+:%d*:(%d*):(%d*):(%d*):(%d*)") }) do
                local gemID = tonumber(gem)
                if gemID and gemID > 0 then
                    entry.gems = entry.gems or {}
                    table.insert(entry.gems, gemID)
                end
            end
            gear[slot] = entry
        end
    end
    data.gear = gear
    data.gearUpdated = GetServerTime()

    -- Refresh the info panel if it's showing this character
    local f = PVPHUB.window
    if f and f:IsShown() and f.currentTab == "characters" and Cards.IsActive() and Cards.selected == charKey then
        Cards.Select(charKey)
    end
end

do
    local pending = false
    local function Schedule(delay)
        if pending then return end
        pending = true
        C_Timer.After(delay, function()
            pending = false
            RecordGear()
        end)
    end

    local events = CreateFrame("Frame")
    events:RegisterEvent("PLAYER_ENTERING_WORLD")
    events:RegisterEvent("PLAYER_EQUIPMENT_CHANGED")
    events:RegisterEvent("PLAYER_LEVEL_UP")
    events:RegisterUnitEvent("UNIT_INVENTORY_CHANGED", "player") -- enchants and gems
    events:SetScript("OnEvent", function(_, event)
        -- Login: give item data a moment to load. Changes come in bursts
        -- (a whole gear set swaps at once), so they're gathered for a second.
        Schedule(event == "PLAYER_ENTERING_WORLD" and 3 or 1)
    end)
end
