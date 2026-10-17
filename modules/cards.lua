-- PVPHUB Card View
-- The Characters tab's second layout: the selected character's information
-- on the left (80% of the width) and a vertical list of pill-shaped character
-- cards on the right (20%) to pick from. Switched with the List/Cards toggle
-- in the window's toolbar and saved in PVPHUB_SETTINGS.mainWindow.characterView
-- ("list" or "cards").
--
-- The list's renderer (f:UpdateContent in core) does everything both views
-- share (hidden characters, the No-Ratings filter, sorting, pinning, groups,
-- totals) and hands its display list to Cards.Render instead of building
-- rows. Pills, group headers and the info panel's rows are pooled: the
-- client never frees frames, so they're created once and reused.

local _, PVPHUB = ...

local Cards = {}
PVPHUB.Cards = Cards

-- Card view area inside the window, in window units: below the toolbar row,
-- above the footer, same side margins as the list.
local AREA_TOP, AREA_BOTTOM, AREA_LEFT, AREA_RIGHT = -92, 60, 20, 45
local LIST_TOP     = -120   -- the list's own scroll area starts below its column headers
local LIST_SHARE   = 0.20   -- the character list's share of the width; the info panel gets the rest
local LIST_MIN_W   = 200    -- wide enough for a full spec and realm name
local COLUMN_GAP   = 12

local PILL_HEIGHT  = 48
local PILL_GAP     = 6
local GROUP_HEIGHT = 22
local PORTRAIT     = 34

local DETAIL_PAD   = 14
local BIG_PORTRAIT = 52
local ROW_HEIGHT   = 22     -- ratings table row

local BRACKETS = {
    { key = "rating2v2",     label = "2v2",     icon = "Interface\\Icons\\achievement_arena_2v2_1" },
    { key = "rating3v3",     label = "3v3",     icon = "Interface\\Icons\\achievement_arena_3v3_1" },
    { key = "ratingShuffle", label = "Shuffle", icon = "Interface\\Icons\\ability_dualwield", perSpec = true },
    { key = "ratingBlitz",   label = "Blitz",   icon = "Interface\\Icons\\achievement_bg_killxenemies_generalsroom", perSpec = true },
    { key = "ratingRBG",     label = "RBG",     icon = "Interface\\Icons\\achievement_pvp_a_15" },
}

-- Ratings table columns: left edge as a share of the table width
local COLUMNS = {
    { key = "rating", title = "Rating", x = 0.42 },
    { key = "best",   title = "Best",   x = 0.54 },
    { key = "mmr",    title = "MMR",    x = 0.66 },
    { key = "wl",     title = "W–L",    x = 0.78 },
    { key = "win",    title = "Win",    x = 0.91 },
}

local WHITE       = "Interface\\Buttons\\WHITE8x8"
local CIRCLE_MASK = "Interface\\CHARACTERFRAME\\TempPortraitAlphaMask"

Cards.pool    = {}   -- pill frames, reused in display order
Cards.headers = {}   -- group header frames, likewise

-- --------------------------------------------------------------------------
-- View setting
-- --------------------------------------------------------------------------

function Cards.IsActive()
    local mw = PVPHUB_SETTINGS and PVPHUB_SETTINGS.mainWindow
    return (mw and mw.characterView == "cards") and true or false
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

local function ClassColor(data)
    local token = data and data.class and data.class:upper() or "WARRIOR"
    return RAID_CLASS_COLORS[token] or RAID_CLASS_COLORS.WARRIOR, token
end

-- "|cffRRGGBB" -> r, g, b
local function HexToRGB(code)
    local hex = code:match("|c%x%x(%x%x%x%x%x%x)")
    if not hex then return 1, 1, 1 end
    return tonumber(hex:sub(1, 2), 16) / 255, tonumber(hex:sub(3, 4), 16) / 255, tonumber(hex:sub(5, 6), 16) / 255
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
-- Character list (pills)
-- --------------------------------------------------------------------------

local function CreatePill(container)
    local pill = CreateFrame("Button", nil, container)
    pill:SetHeight(PILL_HEIGHT)
    pill:RegisterForClicks("LeftButtonUp", "RightButtonUp")

    -- A 1 px ring behind the fill gives the pill its outline
    local r = PILL_HEIGHT / 2
    pill.ring = PVPHUB.CreateRoundedShape(pill, "BACKGROUND", 0, 0, r)
    pill.fill = PVPHUB.CreateRoundedShape(pill, "BACKGROUND", 1, -1, r - 1)
    pill.glow = PVPHUB.CreateRoundedShape(pill, "BORDER", 0, -1, r - 1)
    pill.ring:SetRounded(true)
    pill.fill:SetRounded(true)
    pill.glow:SetRounded(true)
    pill.glow:SetVertexColor(1, 1, 1, 0.07)
    pill.glow:Hide()

    pill.portrait = CreatePortrait(pill, PORTRAIT, 12)
    pill.portrait.icon:SetPoint("LEFT", 5, 0)

    -- Name, spec, realm; race and class are the portrait and its badge
    pill.name = NewText(pill, 12)
    pill.name:SetPoint("LEFT", pill.portrait.icon, "RIGHT", 8, 12)

    pill.spec = NewText(pill, 11)
    pill.spec:SetPoint("LEFT", pill.portrait.icon, "RIGHT", 8, 0)

    pill.realm = NewText(pill, 11)
    pill.realm:SetPoint("LEFT", pill.portrait.icon, "RIGHT", 8, -12)

    pill.noteIcon = pill:CreateTexture(nil, "OVERLAY")
    pill.noteIcon:SetSize(12, 12)
    pill.noteIcon:SetPoint("RIGHT", -12, 0)
    pill.noteIcon:SetTexture("Interface\\Buttons\\UI-GuildButton-PublicNote-Up")

    pill:SetScript("OnEnter", function(self) self.glow:Show() end)
    pill:SetScript("OnLeave", function(self) self.glow:Hide() end)
    pill:SetScript("OnClick", function(self, button)
        if not self.charKey then return end
        if button == "RightButton" then
            local f = PVPHUB.window
            if f and f.ShowCharacterMenu then f:ShowCharacterMenu(self, self.charKey) end
        else
            Cards.Select(self.charKey)
        end
    end)

    return pill
end

local function PaintPill(pill, entry, width, selected)
    local charKey, data = entry.char, entry.data
    pill.charKey, pill.entry = charKey, entry
    local cc = ClassColor(data)
    local colors = GetColors()
    local base = colors.ALTERNATING_ROW_BG or { 0.1, 0.1, 0.12 }

    if selected then
        local ac = colors.ACCENT_LINE or { 0.8, 0.3, 0.5 }
        pill.ring:SetVertexColor(ac[1], ac[2], ac[3], 1)
        pill.fill:SetVertexColor(base[1] * 0.5 + cc.r * 0.5, base[2] * 0.5 + cc.g * 0.5, base[3] * 0.5 + cc.b * 0.5, 0.8)
    else
        pill.ring:SetVertexColor(0.25 + cc.r * 0.45, 0.25 + cc.g * 0.45, 0.30 + cc.b * 0.45, 0.6)
        pill.fill:SetVertexColor(base[1] * 0.7 + cc.r * 0.3, base[2] * 0.7 + cc.g * 0.3, base[3] * 0.7 + cc.b * 0.3, 0.55)
    end

    PaintPortrait(pill.portrait, data)

    -- Room left of the right end's curve, and of the note icon when there is one
    local hasNote = data.note ~= nil and data.note ~= ""
    local textW = width - 5 - PORTRAIT - 8 - (hasNote and 28 or 14)
    pill.name:SetWidth(textW)
    pill.spec:SetWidth(textW)
    pill.realm:SetWidth(textW)
    pill.name:SetText(cc:WrapTextInColorCode(data.displayName or charKey:match("^([^%-]+)") or charKey))

    local spec = PVPHUB._GetCachedSpecInfo(data.specID)
    if spec and spec.name then
        pill.spec:SetText("|cffdddddd" .. (spec.icon and (IconMarkup(spec.icon, 11) .. " ") or "") .. spec.name .. "|r")
    else
        pill.spec:SetText("|cff888888No spec yet|r")
    end
    pill.realm:SetText("|cffbbbbbb" .. (charKey:match("%-(.+)$") or "") .. "|r")

    pill.noteIcon:SetShown(hasNote)
    pill:SetAlpha(PVPHUB._IsCharacterStaleThisSeason(charKey) and 0.7 or 1)
end

local function CreateGroupHeader(container)
    local h = CreateFrame("Button", nil, container)
    h:SetHeight(GROUP_HEIGHT)
    h:RegisterForClicks("LeftButtonUp", "RightButtonUp")

    h.toggle = h:CreateTexture(nil, "ARTWORK")
    h.toggle:SetSize(12, 12)
    h.toggle:SetPoint("LEFT", 4, 0)

    h.text = NewText(h, 11)
    h.text:SetPoint("LEFT", h.toggle, "RIGHT", 5, 0)

    h.line = h:CreateTexture(nil, "ARTWORK")
    h.line:SetTexture(WHITE)
    h.line:SetHeight(1)
    h.line:SetPoint("BOTTOMLEFT", 0, 1)
    h.line:SetPoint("BOTTOMRIGHT", 0, 1)
    h.line:SetGradient("HORIZONTAL", CreateColor(0.6, 0.6, 0.6, 0.5), CreateColor(0.6, 0.6, 0.6, 0))

    h:SetScript("OnClick", function(self, button)
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
                    StaticPopup_Show("PVPHUB_RENAME_GROUP")
                end)
                root:CreateButton("|cffff4040Delete Group|r", function()
                    PVPHUB._deleteGroupCtx = { groupIndex = index }
                    StaticPopupDialogs["PVPHUB_DELETE_GROUP"].text = "Delete group '" .. name .. "'?\n\nCharacters will move to No Group."
                    StaticPopup_Show("PVPHUB_DELETE_GROUP")
                end)
            end)
        end
    end)

    return h
end

local function PaintGroupHeader(h, entry)
    h.groupIndex = entry.groupIndex
    h.groupName  = entry.groupName
    h.isDefault  = entry.groupIsDefault
    h.toggle:SetTexture(entry.groupCollapsed and "Interface\\Buttons\\UI-PlusButton-Up" or "Interface\\Buttons\\UI-MinusButton-Up")
    h.text:SetText(string.format("|cffffffff%s|r |cff888888(%d)|r", entry.groupName or "", entry.characterCount or 0))
end

-- --------------------------------------------------------------------------
-- Character info panel
-- --------------------------------------------------------------------------

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

-- This season's rated brackets as table rows; Shuffle and Blitz get one row
-- per spec, highest first.
local function CollectRatingRows(data)
    local rows = {}
    local season = (C_PvP and C_PvP.GetUIDisplaySeason and C_PvP.GetUIDisplaySeason()) or 0
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

-- A row band that fades out to both sides, like the arena stats tooltip
local function CreateBand(parent)
    local left = parent:CreateTexture(nil, "BACKGROUND")
    local right = parent:CreateTexture(nil, "BACKGROUND")
    left:SetTexture(WHITE)
    right:SetTexture(WHITE)
    left:SetPoint("TOPLEFT")
    left:SetPoint("BOTTOMRIGHT", parent, "BOTTOM")
    right:SetPoint("TOPLEFT", parent, "TOP")
    right:SetPoint("BOTTOMRIGHT")
    return { left = left, right = right }
end

local function PaintBand(band, r, g, b, a)
    band.left:SetGradient("HORIZONTAL", CreateColor(r, g, b, 0), CreateColor(r, g, b, a))
    band.right:SetGradient("HORIZONTAL", CreateColor(r, g, b, a), CreateColor(r, g, b, 0))
end

-- Section title with an underline that fades out to the right
local function CreateSectionTitle(parent, text)
    local title = NewText(parent, 13)
    title:SetText(text)
    title:SetTextColor(1, 0.82, 0, 1)
    local line = parent:CreateTexture(nil, "ARTWORK")
    line:SetTexture(WHITE)
    line:SetHeight(1)
    line:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -4)
    line:SetPoint("RIGHT", parent, "RIGHT", 0, 0)
    line:SetGradient("HORIZONTAL", CreateColor(1, 0.82, 0, 0.5), CreateColor(1, 0.82, 0, 0))
    return title
end

local function CreateRatingRow(content)
    local row = CreateFrame("Button", nil, content)
    row:SetHeight(ROW_HEIGHT)
    row.band = CreateBand(row)

    row.icon = row:CreateTexture(nil, "ARTWORK")
    row.icon:SetSize(16, 16)
    row.icon:SetPoint("LEFT", 4, 0)
    row.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

    row.label = NewText(row, 12)
    row.label:SetPoint("LEFT", row.icon, "RIGHT", 6, 0)

    row.cells = {}
    for i = 1, #COLUMNS do
        row.cells[i] = NewText(row, 12)
    end

    row:SetScript("OnEnter", function(self)
        local data = self.charKey and PVPHUB_DB[self.charKey]
        if data then
            PVPHUB._ShowRatingTooltip(self, self.charKey, self.bracketKey, data[self.bracketKey])
        end
    end)
    row:SetScript("OnLeave", function() PVPHUB._CloseRatingTooltip() end)
    return row
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

-- This season's match history as graph series: one per bracket, and one per
-- spec for Shuffle and Blitz, in BRACKETS order, matches oldest first.
local function CollectSeries(data)
    local list = {}
    local hist = data.mmrHistory
    if type(hist) ~= "table" then return list end
    local season = (C_PvP and C_PvP.GetUIDisplaySeason and C_PvP.GetUIDisplaySeason()) or 0
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
    GameTooltip:AddDoubleLine("CR", string.format("%d  →  %s%d|r%s", before,
        PVPHUB._GetRatingColor(math.max(p.cr, 1)), p.cr, change ~= 0 and PVPHUB.FormatRatingDelta(change) or ""),
        CR_COLOR[1], CR_COLOR[2], CR_COLOR[3], 1, 1, 1)
    if p.mmr then
        local pre = (m.preMatchMMR or 0) > 0 and (m.preMatchMMR .. "  →  ") or ""
        GameTooltip:AddDoubleLine("MMR", pre .. p.mmr, MMR_COLOR[1], MMR_COLOR[2], MMR_COLOR[3], 1, 1, 1)
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
        local ac = GetColors().ACCENT_LINE or { 0.8, 0.3, 0.5 }
        chip.bg:SetVertexColor(ac[1], ac[2], ac[3], 0.45)
        chip.text:SetTextColor(1, 1, 1, 1)
    else
        chip.bg:SetVertexColor(0, 0, 0, 0.35)
        chip.text:SetTextColor(0.75, 0.75, 0.75, 1)
    end
end

-- Paints the graph section (chips + graph) for one character
local function PaintHistory(panel, charKey, data, width)
    local seriesList = CollectSeries(data)

    -- The series the user picked for this character, else the one played last
    local chosen
    local pick = Cards.graphChoice[charKey]
    for _, s in ipairs(seriesList) do
        if s.id == pick then chosen = s end
    end
    if not chosen then
        for _, s in ipairs(seriesList) do
            if not chosen or s.lastPlayed > chosen.lastPlayed then chosen = s end
        end
    end

    -- Series chips, left to right
    local x = 0
    for i, s in ipairs(seriesList) do
        local chip = panel.seriesChips[i]
        if not chip then
            chip = CreateChip(panel.content, function(self)
                Cards.graphChoice[self.charKey] = self.seriesID
                local f = PVPHUB.window
                local d = self.charKey and PVPHUB_DB[self.charKey]
                if f and f.cardDetail and d then
                    PaintHistory(f.cardDetail, self.charKey, d, Cards.historyWidth or width)
                end
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
        chip:SetShown(#seriesList > 0)
    end

    panel.graph:SetWidth(width)
    DrawGraph(panel.graph, chosen and SeriesPoints(chosen, Cards.graphRange) or {}, width)
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
    t.name = NewText(t, 12)
    t.name:SetPoint("LEFT", t.icon, "RIGHT", 6, 0)
    t.value = NewText(t, 12)
    t.value:SetJustifyH("RIGHT")
    t.value:SetPoint("TOPRIGHT", -8, -13)
    t.sub = NewText(t, 10)
    t.sub:SetPoint("TOPLEFT", 8, -33)

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

    -- Ratings
    panel.ratingsTitle = CreateSectionTitle(content, "Ratings")
    panel.colTitles = {}
    for i, col in ipairs(COLUMNS) do
        local fs = NewText(content, 10)
        fs:SetText(col.title)
        fs:SetTextColor(0.6, 0.6, 0.6, 1)
        panel.colTitles[i] = fs
    end
    panel.noRatings = NewText(content, 11)
    panel.noRatings:SetText("|cff777777No rated games this season|r")
    panel.rows = {}

    -- Season titles
    panel.titlesTitle = CreateSectionTitle(content, "Season titles")
    panel.titleTiles = {}
    for i = 1, #(PVPHUB._TITLE_META or {}) do
        panel.titleTiles[i] = CreateTitleTile(content)
    end

    -- Rating history: bracket/spec chips, the graph, legend and range chips
    panel.historyTitle = CreateSectionTitle(content, "Rating history")
    panel.historyRow = CreateFrame("Frame", nil, content)
    panel.historyRow:SetHeight(20)
    panel.seriesChips = {}
    panel.graph = CreateGraph(content)

    panel.legendRow = CreateFrame("Frame", nil, content)
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
            local data = Cards.selected and PVPHUB_DB[Cards.selected]
            if data then PaintHistory(panel, Cards.selected, data, Cards.historyWidth or 400) end
        end)
        chip.range = range.key
        chip.text:SetText(range.text)
        chip:SetWidth(56)
        chip:SetPoint("TOPRIGHT", panel.legendRow, "TOPRIGHT", -(#RANGES - i) * 60, 0)
        panel.rangeChips[i] = chip
    end

    -- Gear
    panel.gearTitle = CreateSectionTitle(content, "Gear")
    panel.gearStamp = NewText(content, 10)
    panel.gearStamp:SetJustifyH("RIGHT")
    panel.noGear = NewText(content, 11)
    panel.noGear:SetText("|cff777777Log in on this character once to record its gear.|r")
    panel.gearRows = {}
    for slot in pairs(Cards.GEAR_SLOTS) do
        panel.gearRows[slot] = CreateGearRow(content)
    end

    -- Currencies
    panel.currencyTitle = CreateSectionTitle(content, "Currencies")
    panel.currencies = NewText(content, 12)

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
    local data = charKey and PVPHUB_DB[charKey]
    local colors = GetColors()
    local base = colors.WINDOW_BG or { 0.08, 0.05, 0.05 }
    panel.bg:SetVertexColor(base[1] * 1.6, base[2] * 1.6, base[3] * 1.6, 0.55)

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
    if PVPHUB._IsCharacterStaleThisSeason(charKey) then
        line4 = line4 .. "   |cff777777(last season's data)|r"
    end
    panel.line4:SetText(line4)

    local y = BIG_PORTRAIT + 14

    -- Ratings table
    panel.ratingsTitle:ClearAllPoints()
    panel.ratingsTitle:SetPoint("TOPLEFT", panel.content, "TOPLEFT", 0, -y)
    y = y + 26
    for i, col in ipairs(COLUMNS) do
        panel.colTitles[i]:ClearAllPoints()
        panel.colTitles[i]:SetPoint("TOPLEFT", panel.content, "TOPLEFT", math.floor(contentW * col.x), -y)
    end
    y = y + 16

    local ratingRows = CollectRatingRows(data)
    panel.noRatings:SetShown(#ratingRows == 0)
    if #ratingRows == 0 then
        panel.noRatings:ClearAllPoints()
        panel.noRatings:SetPoint("TOPLEFT", panel.content, "TOPLEFT", 4, -y - 4)
        y = y + ROW_HEIGHT
    end
    for i, info in ipairs(ratingRows) do
        local row = panel.rows[i] or CreateRatingRow(panel.content)
        panel.rows[i] = row
        row.charKey, row.bracketKey = charKey, info.bracket.key
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", panel.content, "TOPLEFT", 0, -y)
        row:SetWidth(contentW)

        local s = info.stats
        local rating = s.rating or 0
        local r, g, b = HexToRGB(PVPHUB._GetRatingColor(math.max(rating, 1)))
        PaintBand(row.band, r, g, b, (i % 2 == 1) and 0.10 or 0.05)

        local label = info.bracket.label
        local specInfo = info.specID and PVPHUB._GetCachedSpecInfo(info.specID)
        if specInfo then
            label = label .. "  |cffaaaaaa" .. IconMarkup(specInfo.icon, 12) .. " " .. specInfo.name .. "|r"
        end
        row.icon:SetTexture(info.bracket.icon)
        row.label:SetText(label)

        local won, lost = s.won or 0, s.lost or 0
        local games = won + lost
        local winText = "|cff555555—|r"
        if games > 0 then
            local pct = math.floor(won / games * 100 + 0.5)
            winText = (pct >= 50 and "|cff40ff40" or "|cffff8040") .. pct .. "%|r"
        end
        local values = {
            rating = ColoredRating(rating),
            best   = ColoredRating(s.seasonBest),
            mmr    = ColoredRating(GetMMR(data, info.bracket.key, info.specID)),
            wl     = games > 0 and string.format("|cff40ff40%d|r|cff888888–|r|cffff5050%d|r", won, lost) or "|cff555555—|r",
            win    = winText,
        }
        for c, col in ipairs(COLUMNS) do
            local cell = row.cells[c]
            cell:ClearAllPoints()
            cell:SetPoint("LEFT", row, "LEFT", math.floor(contentW * col.x), 0)
            cell:SetText(values[col.key])
        end
        row:Show()
        y = y + ROW_HEIGHT
    end
    for i = #ratingRows + 1, #panel.rows do panel.rows[i]:Hide() end

    -- Season titles, side by side
    local metas = PVPHUB._TITLE_META or {}
    if #metas > 0 then
        y = y + 16
        panel.titlesTitle:ClearAllPoints()
        panel.titlesTitle:SetPoint("TOPLEFT", panel.content, "TOPLEFT", 0, -y)
        y = y + 26
        local stale = PVPHUB._IsCharacterStaleThisSeason(charKey)
        local tileW = math.floor((contentW - TITLE_TILE_GAP * (#metas - 1)) / #metas)
        for i, meta in ipairs(metas) do
            local tile = panel.titleTiles[i]
            tile:ClearAllPoints()
            tile:SetPoint("TOPLEFT", panel.content, "TOPLEFT", (i - 1) * (tileW + TITLE_TILE_GAP), -y)
            PaintTitleTile(tile, meta, data.titleProgress and data.titleProgress[meta.key], tileW, stale)
            tile:Show()
        end
        y = y + TITLE_TILE_HEIGHT
    end

    -- Rating history graph
    y = y + 16
    panel.historyTitle:ClearAllPoints()
    panel.historyTitle:SetPoint("TOPLEFT", panel.content, "TOPLEFT", 0, -y)
    y = y + 26
    panel.historyRow:ClearAllPoints()
    panel.historyRow:SetPoint("TOPLEFT", panel.content, "TOPLEFT", 0, -y)
    panel.historyRow:SetWidth(contentW)
    y = y + 26
    panel.graph:ClearAllPoints()
    panel.graph:SetPoint("TOPLEFT", panel.content, "TOPLEFT", 0, -y)
    y = y + GRAPH_HEIGHT + 6
    panel.legendRow:ClearAllPoints()
    panel.legendRow:SetPoint("TOPLEFT", panel.content, "TOPLEFT", 0, -y)
    panel.legendRow:SetWidth(contentW)
    y = y + 22
    Cards.historyWidth = contentW
    PaintHistory(panel, charKey, data, contentW)

    -- Gear: two columns of slots, recorded the last time this character
    -- was played
    y = y + 16
    panel.gearTitle:ClearAllPoints()
    panel.gearTitle:SetPoint("TOPLEFT", panel.content, "TOPLEFT", 0, -y)
    panel.gearStamp:ClearAllPoints()
    panel.gearStamp:SetPoint("TOPRIGHT", panel.content, "TOPRIGHT", 0, -y - 2)
    y = y + 26
    local gear = data.gear
    if type(gear) == "table" then
        local colW = math.floor((contentW - GEAR_COL_GAP) / 2)
        for c, slots in ipairs(GEAR_COLUMNS) do
            for r, slot in ipairs(slots) do
                local row = panel.gearRows[slot]
                row:ClearAllPoints()
                row:SetPoint("TOPLEFT", panel.content, "TOPLEFT",
                    (c - 1) * (colW + GEAR_COL_GAP), -(y + (r - 1) * GEAR_ROW_HEIGHT))
                PaintGearRow(row, slot, gear[slot], colW)
                row:Show()
            end
        end
        y = y + #GEAR_COLUMNS[1] * GEAR_ROW_HEIGHT
        panel.gearStamp:SetText("|cff888888Recorded|r " .. LastSeenText(data.gearUpdated))
        panel.gearStamp:Show()
        panel.noGear:Hide()
    else
        for _, row in pairs(panel.gearRows) do row:Hide() end
        panel.gearStamp:Hide()
        panel.noGear:ClearAllPoints()
        panel.noGear:SetPoint("TOPLEFT", panel.content, "TOPLEFT", 4, -y)
        panel.noGear:Show()
        y = y + 20
    end

    -- Currencies
    y = y + 16
    panel.currencyTitle:ClearAllPoints()
    panel.currencyTitle:SetPoint("TOPLEFT", panel.content, "TOPLEFT", 0, -y)
    y = y + 26
    local fmt, color = PVPHUB._FormatNumber, PVPHUB._GetCurrencyColor
    local honor, conquest = data.honor or 0, data.conquest or 0
    local helio, tokens = data.bloodstones or 0, data.bloodytokens or 0
    panel.currencies:ClearAllPoints()
    panel.currencies:SetPoint("TOPLEFT", panel.content, "TOPLEFT", 0, -y)
    panel.currencies:SetText(string.format(
        "%s %s%s|r      %s %s%s|r      %s %s%s|r      %s %s%s|r      %s %s",
        "|T1455894:14:14:0:0|t", color(honor, "honor", data), fmt(honor),
        "|T1523630:14:14:0:0|t", color(conquest, "conquest", data), fmt(conquest),
        "|T134128:14:14:0:0|t", color(helio, "bloodstones", data), fmt(helio),
        "|T4638431:14:14:0:0|t", color(tokens, "bloodytokens", data), fmt(tokens),
        "|TInterface\\MoneyFrame\\UI-GoldIcon:14:14:0:0|t", fmt(math.floor((data.gold or 0) / 10000))))
    y = y + 20

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

-- Shows another character's information without rebuilding the window
function Cards.Select(charKey)
    Cards.selected = charKey
    local f = PVPHUB.window
    if not f then return end
    for _, pill in ipairs(Cards.pool) do
        if pill:IsShown() and pill.entry then
            PaintPill(pill, pill.entry, pill:GetWidth(), pill.charKey == charKey)
        end
    end
    if f.cardDetail then f.cardDetail.scroll:SetVerticalScroll(0) end
    PaintDetail(f, charKey, Cards.detailWidth or 400)
end

-- --------------------------------------------------------------------------
-- Rendering
-- --------------------------------------------------------------------------

-- The pills live in their own frame inside the list's scroll child. Marked
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

-- Splits the area: the info panel on the left, the pill list (the main
-- scroll frame, narrowed) on the right.
local function SetCardArea(f)
    local areaW = f:GetWidth() - AREA_LEFT - AREA_RIGHT
    local listW = math.max(LIST_MIN_W, math.floor(areaW * LIST_SHARE))
    local detailW = areaW - listW - COLUMN_GAP

    f.scrollFrame:ClearAllPoints()
    f.scrollFrame:SetPoint("TOPLEFT", f, "TOPLEFT", AREA_LEFT + detailW + COLUMN_GAP, AREA_TOP)
    f.scrollFrame:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -AREA_RIGHT, AREA_BOTTOM)

    local panel = GetDetail(f)
    panel:ClearAllPoints()
    panel:SetPoint("TOPLEFT", f, "TOPLEFT", AREA_LEFT, AREA_TOP)
    panel:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", AREA_LEFT, AREA_BOTTOM)
    panel:SetWidth(detailW)
    panel:Show()
    return listW, detailW
end

-- Lays out the card view. Returns the pill list's height.
function Cards.Render(f, displayList)
    local listW, detailW = SetCardArea(f)
    Cards.detailWidth = detailW
    local container = GetContainer(f)
    if f.viewToggle then Cards.PaintToggle(f.viewToggle) end

    -- Keep the chosen character while it's in the list; otherwise start
    -- with the logged-in one, or the first.
    local present, first = {}, nil
    for _, entry in ipairs(displayList) do
        if entry.char and entry.data then
            present[entry.char] = true
            first = first or entry.char
        end
    end
    if not (Cards.selected and present[Cards.selected]) then
        local current = PVPHUB._GetFullName()
        Cards.selected = present[current] and current or first
    end

    local pillW = listW - 2
    local y, nPills, nHeaders = 0, 0, 0
    for _, entry in ipairs(displayList) do
        if entry.isGroupHeader then
            nHeaders = nHeaders + 1
            local h = Cards.headers[nHeaders] or CreateGroupHeader(container)
            Cards.headers[nHeaders] = h
            PaintGroupHeader(h, entry)
            h:ClearAllPoints()
            h:SetPoint("TOPLEFT", container, "TOPLEFT", 0, -y)
            h:SetWidth(pillW)
            h:Show()
            y = y + GROUP_HEIGHT + 4
        elseif entry.char and entry.data then
            nPills = nPills + 1
            local pill = Cards.pool[nPills] or CreatePill(container)
            Cards.pool[nPills] = pill
            pill:ClearAllPoints()
            pill:SetPoint("TOPLEFT", container, "TOPLEFT", 0, -y)
            pill:SetWidth(pillW)
            PaintPill(pill, entry, pillW, entry.char == Cards.selected)
            pill:Show()
            y = y + PILL_HEIGHT + PILL_GAP
        end
    end

    for i = nPills + 1, #Cards.pool do
        Cards.pool[i]:Hide()
        Cards.pool[i].charKey, Cards.pool[i].entry = nil, nil
    end
    for i = nHeaders + 1, #Cards.headers do Cards.headers[i]:Hide() end

    f.contentFrame:SetWidth(listW)
    container:SetSize(listW, math.max(y, 1))
    container:Show()

    -- The window grows to fit the information where the screen allows
    -- (see the height logic in f:UpdateContent).
    local detailH = PaintDetail(f, Cards.selected, detailW)
    Cards.neededWindowHeight = -AREA_TOP + AREA_BOTTOM + DETAIL_PAD * 2 + detailH
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
end

-- --------------------------------------------------------------------------
-- List/Cards toggle
-- --------------------------------------------------------------------------

local function CreateOutline(frame, layer)
    local edges = {}
    for _, side in ipairs({ "TOP", "BOTTOM", "LEFT", "RIGHT" }) do
        local t = frame:CreateTexture(nil, layer or "BORDER")
        t:SetTexture(WHITE)
        if side == "TOP" or side == "BOTTOM" then
            t:SetHeight(1)
            t:SetPoint(side .. "LEFT")
            t:SetPoint(side .. "RIGHT")
        else
            t:SetWidth(1)
            t:SetPoint("TOP" .. side)
            t:SetPoint("BOTTOM" .. side)
        end
        edges[#edges + 1] = t
    end
    return edges
end

function Cards.PaintToggle(bar)
    local colors = GetColors()
    local ac = colors.ACCENT_LINE or { 0.8, 0.3, 0.5 }
    local bd = colors.WINDOW_BORDER or { 0.35, 0.2, 0.25 }
    local active = Cards.IsActive() and "cards" or "list"
    for _, b in ipairs(bar.buttons) do
        if b.mode == active then
            b.bg:SetVertexColor(ac[1], ac[2], ac[3], 0.45)
            b.text:SetTextColor(1, 1, 1, 1)
        else
            b.bg:SetVertexColor(0, 0, 0, 0.35)
            b.text:SetTextColor(0.7, 0.7, 0.7, 1)
        end
    end
    for _, t in ipairs(bar.edges) do t:SetVertexColor(bd[1], bd[2], bd[3], 0.9) end
    bar.divider:SetVertexColor(bd[1], bd[2], bd[3], 0.9)
end

-- Builds the toggle on the Characters tab's toolbar row, right-aligned with
-- the list (SwitchTab shows it on the Characters tab only).
function Cards.CreateToggle(f)
    if f.viewToggle then return f.viewToggle end
    local BUTTON_W, BUTTON_H = 52, 20

    local bar = CreateFrame("Frame", nil, f)
    bar:SetSize(BUTTON_W * 2, BUTTON_H)
    bar:SetPoint("TOPRIGHT", f, "TOPRIGHT", -AREA_RIGHT, -62)
    bar.buttons = {}

    local modes = {
        { key = "list",  text = "List",  tip = "Show your characters as a list" },
        { key = "cards", text = "Cards", tip = "Pick a character from cards and see all of its information" },
    }
    for i, mode in ipairs(modes) do
        local b = CreateFrame("Button", nil, bar)
        b:SetSize(BUTTON_W, BUTTON_H)
        b:SetPoint("LEFT", bar, "LEFT", (i - 1) * BUTTON_W, 0)
        b.mode = mode.key

        b.bg = b:CreateTexture(nil, "BACKGROUND")
        b.bg:SetAllPoints()
        b.bg:SetTexture(WHITE)

        local hl = b:CreateTexture(nil, "HIGHLIGHT")
        hl:SetAllPoints()
        hl:SetTexture(WHITE)
        hl:SetVertexColor(1, 1, 1, 0.08)

        b.text = NewText(b, 11)
        b.text:SetPoint("CENTER")
        b.text:SetText(mode.text)

        b:SetScript("OnClick", function()
            if Cards.IsActive() ~= (mode.key == "cards") then
                Cards.SetActive(mode.key == "cards")
            end
        end)
        b:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
            GameTooltip:SetText(mode.text, 1, 1, 1)
            GameTooltip:AddLine(mode.tip, 0.7, 0.7, 0.7, true)
            GameTooltip:Show()
        end)
        b:SetScript("OnLeave", function() GameTooltip:Hide() end)
        bar.buttons[i] = b
    end

    bar.edges = CreateOutline(bar, "OVERLAY")
    bar.divider = bar:CreateTexture(nil, "OVERLAY")
    bar.divider:SetTexture(WHITE)
    bar.divider:SetWidth(1)
    bar.divider:SetPoint("TOP", bar, "TOP", 0, 0)
    bar.divider:SetPoint("BOTTOM", bar, "BOTTOM", 0, 0)

    f.viewToggle = bar
    Cards.PaintToggle(bar)
    bar:SetShown(f.currentTab == "characters")
    return bar
end

-- --------------------------------------------------------------------------
-- Gear recording
-- --------------------------------------------------------------------------
-- The logged-in character's equipment is saved on login and whenever it
-- changes, so the info panel can show every character's gear:
--   PVPHUB_DB[charKey].gear[slotID] = { link, ilvl, quality, icon, name,
--                                       enchant, gems = { gemItemID, ... } }
-- Alts show what they wore the last time they were played.

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
    events:RegisterUnitEvent("UNIT_INVENTORY_CHANGED", "player") -- enchants and gems
    events:SetScript("OnEvent", function(_, event)
        -- Login: give item data a moment to load. Changes come in bursts
        -- (a whole gear set swaps at once), so they're gathered for a second.
        Schedule(event == "PLAYER_ENTERING_WORLD" and 3 or 1)
    end)
end
