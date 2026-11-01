-- PVPHUB Season tab (7.0)
--
-- The whole roster's season at a glance, top to bottom:
--   hero         three tiles: the season (its name, characters and games,
--                the season menu: the current season or one from the season
--                archive, seasons.lua), the best rating, the win rate
--   brackets     a card per bracket: its icon, best rating, win rate and the
--                classes that played it; hover for every character's share
--   titles | top the season titles with their achievement icons, and the
--                best characters by rating, the most played one marked MVP
--   roster       classes played, most played spec, favourite bracket
--
-- Frames are built once and repainted on every render (core calls
-- f.RenderStatsFor after each match and on every visit to the tab).
-- This replaces f:CreateStatsFrame's old card layout in core, which stays
-- there unused until 7.0 ships so merges from main don't conflict.

local _, PVPHUB = ...

local Tab = {}
PVPHUB.SeasonTab = Tab

local GAP            = 10    -- between panels
local PAD            = 12    -- inside a panel
local HERO_H         = 92    -- the top row's tiles
-- The season tile's expansion logo. The logo files (2:1) have wide empty
-- margins left and right; LOGO_CROP cuts them off, the size keeps the
-- rest's proportions.
local LOGO_CROP      = { 0.12, 0.84 }
local LOGO_H         = 60
local LOGO_W         = math.floor(LOGO_H * 2 * (LOGO_CROP[2] - LOGO_CROP[1]))
local EMBLEM         = 52    -- its round Conquest emblem when there's no logo
local CARD_H         = 112   -- a bracket card
local FACE           = 18    -- a class icon on a bracket card
local MAX_FACES      = 4     -- class icons on a bracket card, "+N" for more
local TITLE_ROW_H    = 50
local TITLE_ICON     = 30
local TOP_ROW_H      = 36    -- a character in Top characters
local TOP_COUNT      = 5
local CHIP_H         = 22    -- class chip in the roster
local ROSTER_ROW_H   = 18    -- character in the roster's expanded list
local TWO_COLUMN_MIN = 640   -- narrower than this: titles and top characters stack
local MAX_CLASSES    = 13
local CONQUEST_ID    = 1602  -- the Conquest currency, whose emblem heads the season
local ICON_MASK      = "Interface\\CharacterFrame\\TempPortraitAlphaMask"

local PER_SPEC = { ratingShuffle = true, ratingBlitz = true }

-- Bracket names here; "Rated Battlegrounds" is too long for the table
local SHORT_LABEL = { ratingRBG = "Rated BGs" }
local function BracketLabel(meta) return SHORT_LABEL[meta.key] or meta.label end

Tab.season = nil   -- archived season shown; nil = the current one

local function CurrentSeason()
    return (C_PvP and C_PvP.GetUIDisplaySeason and C_PvP.GetUIDisplaySeason()) or 0
end

-- --------------------------------------------------------------------------
-- Data
-- --------------------------------------------------------------------------

-- One character's season in one bracket as { played, won, lost, best },
-- nil without games. Shuffle and Blitz are kept per spec and summed.
local function Summary(data, bracketKey, season)
    local bs = type(data.bracketStats) == "table" and data.bracketStats[bracketKey]
    if type(bs) ~= "table" then return nil end
    local function inSeason(s) return season == 0 or not s.season or s.season == season end
    local sum = { played = 0, won = 0, lost = 0, best = 0 }
    if PER_SPEC[bracketKey] then
        for _, s in pairs(bs) do
            if type(s) == "table" and inSeason(s) then
                sum.played = sum.played + (s.played or 0)
                sum.won    = sum.won + (s.won or 0)
                sum.lost   = sum.lost + (s.lost or 0)
                sum.best   = math.max(sum.best, s.seasonBest or 0)
            end
        end
    elseif inSeason(bs) then
        sum.played, sum.won, sum.lost, sum.best = bs.played or 0, bs.won or 0, bs.lost or 0, bs.seasonBest or 0
    end
    if sum.played <= 0 then return nil end
    return sum
end

-- The characters counted: for the current season the same list the old tab
-- used (not hidden, with rated games); for an archived one every archived
-- character that isn't hidden, as it was that season (Seasons.View).
local function Characters(season, archived)
    local list = {}
    if archived then
        for _, charKey in ipairs(PVPHUB.Seasons.Characters(season)) do
            if not PVPHUB._IsCharacterHidden(charKey) then
                local view = PVPHUB.Seasons.View(charKey, season)
                if view then list[#list + 1] = { key = charKey, data = view } end
            end
        end
    else
        for _, charKey in ipairs(PVPHUB._GetStatsCharacterList()) do
            if type(PVPHUB_DB[charKey]) == "table" then
                list[#list + 1] = { key = charKey, data = PVPHUB_DB[charKey] }
            end
        end
    end
    return list
end

local function BuildData(season, archived)
    local d = {
        played = 0, won = 0, lost = 0, chars = 0,
        brackets = {},    -- [bracketKey] = { meta, played, won, lost, best, chars = { {key, s} } }
        classes = {},     -- [class] = { token, chars = { charKey } }
        specGames = {},   -- [specID] = games (Shuffle: rounds), from recorded matches
        titles = {},      -- [titleKey] = { current, required, char, earned, tp }
        players = {},     -- { key, class, played, won, main, best, bestMeta }, most games first
    }
    local chars = Characters(season, archived)

    for _, ch in ipairs(chars) do
        local hadGames = false
        local player = {
            key = ch.key, class = ch.data.class and ch.data.class:upper(),
            played = 0, won = 0, mainPlayed = 0, best = 0,
        }
        for _, meta in ipairs(PVPHUB._BRACKET_META) do
            local s = Summary(ch.data, meta.key, season)
            if s then
                hadGames = true
                player.played, player.won = player.played + s.played, player.won + s.won
                if s.played > player.mainPlayed then player.main, player.mainPlayed = meta, s.played end
                if s.best > player.best then player.best, player.bestMeta = s.best, meta end
                local bt = d.brackets[meta.key]
                if not bt then
                    bt = { meta = meta, played = 0, won = 0, lost = 0, best = 0, chars = {} }
                    d.brackets[meta.key] = bt
                end
                bt.played, bt.won, bt.lost = bt.played + s.played, bt.won + s.won, bt.lost + s.lost
                bt.best = math.max(bt.best, s.best)
                bt.chars[#bt.chars + 1] = { key = ch.key, s = s }
                d.played, d.won, d.lost = d.played + s.played, d.won + s.won, d.lost + s.lost
                if not d.best or s.best > d.best.rating then
                    d.best = { rating = s.best, char = ch.key, meta = meta }
                end
            end
        end

        if hadGames then
            d.chars = d.chars + 1
            d.players[#d.players + 1] = player
            local class = ch.data.class and ch.data.class:upper()
            if class then
                d.classes[class] = d.classes[class] or { token = class, chars = {} }
                table.insert(d.classes[class].chars, ch.key)
            end
            if type(ch.data.mmrHistory) == "table" then
                for _, matches in pairs(ch.data.mmrHistory) do
                    if type(matches) == "table" then
                        for _, m in ipairs(matches) do
                            if type(m) == "table" and (m.specID or 0) > 0
                               and (season == 0 or not m.season or m.season == season) then
                                local w = (m.roundsWon and m.roundsLost) and (m.roundsWon + m.roundsLost) or 1
                                d.specGames[m.specID] = (d.specGames[m.specID] or 0) + w
                            end
                        end
                    end
                end
            end
        end
    end

    -- Titles: whoever earned it, else whoever is closest. A live character
    -- not played since the season changed still holds last season's titles.
    local current = CurrentSeason()
    for _, meta in ipairs(PVPHUB._TITLE_META or {}) do
        local t = { current = 0, required = 0 }
        for _, ch in ipairs(chars) do
            local tag = ch.data.seasonTag
            local valid = archived or not tag or current == 0 or tag == current
            local tp = valid and type(ch.data.titleProgress) == "table" and ch.data.titleProgress[meta.key]
            if type(tp) == "table" and (tp.required or 0) > 0 then
                t.required = tp.required
                t.icon = t.icon or tp.icon   -- the achievement's own icon
                if tp.completed then
                    if not t.earned then t.earned, t.char, t.tp = true, ch.key, tp end
                elseif not t.earned and (tp.current or 0) > t.current then
                    t.current, t.char = tp.current, ch.key
                end
            end
        end
        d.titles[meta.key] = t
    end

    -- MVP: the character with the most games (Shuffle counts rounds, as
    -- everywhere in this tab)
    table.sort(d.players, function(a, b)
        if a.played ~= b.played then return a.played > b.played end
        return a.key < b.key
    end)
    return d
end

-- --------------------------------------------------------------------------
-- Helpers
-- --------------------------------------------------------------------------

local function NewText(parent, size)
    local fs = parent:CreateFontString(nil, "OVERLAY")
    PVPHUB._RegisterTrackedFont(fs, size, "OUTLINE")
    fs:SetShadowColor(0, 0, 0, 0.8)
    fs:SetShadowOffset(1, -1)
    fs:SetJustifyH("LEFT")
    fs:SetWordWrap(false)
    return fs
end

local function Muted(fs)
    fs:SetTextColor(0.56, 0.55, 0.6, 1)
    return fs
end

local function ClassColor(charKey)
    local data = PVPHUB_DB and PVPHUB_DB[charKey]
    local token = data and data.class and data.class:upper()
    return token and RAID_CLASS_COLORS[token]
end

-- "Name" (or "Name-Realm") in its class color
local function CharName(charKey, withRealm)
    local name = withRealm and charKey or (charKey:match("^([^%-]+)") or charKey)
    local c = ClassColor(charKey)
    return c and c:WrapTextInColorCode(name) or name
end

local function Rating(value)
    if not value or value <= 0 then return "|cff555555—|r" end
    return PVPHUB._GetRatingColor(value) .. value .. "|r"
end

local function Count(n)
    return PVPHUB._FormatNumber and PVPHUB._FormatNumber(n) or tostring(n)
end

-- Win rate color: green from 50%, yellow just below, orange under 45%
local function WinColor(pct)
    if pct >= 0.5 then return 0.37, 0.82, 0.48 end
    if pct >= 0.45 then return 0.9, 0.78, 0.29 end
    return 1, 0.6, 0.29
end

-- "58%" in its win rate color
local function WinText(pct)
    local r, g, b = WinColor(pct)
    return string.format("|cff%02x%02x%02x%d%%|r", r * 255, g * 255, b * 255, math.floor(pct * 100 + 0.5))
end

-- Title progress color, as the old tiles: red, orange, yellow, green
local function ProgressColor(pct)
    if pct >= 0.75 then return 0.2, 0.8, 0.25 end
    if pct >= 0.5 then return 0.9, 0.8, 0.1 end
    if pct >= 0.25 then return 0.95, 0.55, 0.1 end
    return 0.85, 0.2, 0.2
end

local function EarnedDate(tp)
    if not (tp and tp.earnedYear and tp.earnedMonth and tp.earnedDay) then return nil end
    local year = tp.earnedYear < 100 and (2000 + tp.earnedYear) or tp.earnedYear
    return PVPHUB._FormatTimestamp(time({ year = year, month = tp.earnedMonth, day = tp.earnedDay, hour = 12 }))
end

-- A rounded panel; gold = the season titles' warm tint
local function NewPanel(parent)
    local p = CreateFrame("Frame", nil, parent)
    p.bg = PVPHUB.CreateRoundedShape(p, "BACKGROUND", 0, 0, 10)
    p.bg:SetRounded(true)
    return p
end

-- The panels' color: the window's, a little lighter (r, g, b)
local function PanelColor()
    local c = PVPHUB.currentColors
    local base = (c and c.WINDOW_BG) or { 0.08, 0.05, 0.05 }
    return base[1] * 1.6, base[2] * 1.6, base[3] * 1.6
end

local function PaintPanel(p, gold)
    if gold then
        p.bg:SetVertexColor(0.3, 0.22, 0.04, 0.42)
    else
        local r, g, b = PanelColor()
        p.bg:SetVertexColor(r, g, b, 0.55)
    end
end

-- A thin rounded bar: a faint track and a fill of pct of its width
local function NewBar(parent, height)
    local bar = CreateFrame("Frame", nil, parent)
    bar:SetSize(100, height)
    bar.track = PVPHUB.UI.CreatePill(bar, "ARTWORK", 0)
    bar.fillFrame = CreateFrame("Frame", nil, bar)
    bar.fillFrame:SetSize(height, height)
    bar.fillFrame:SetPoint("LEFT")
    bar.fill = PVPHUB.UI.CreatePill(bar.fillFrame, "ARTWORK", 0)
    return bar
end

local function PaintBar(bar, width, pct, r, g, b)
    bar:SetWidth(width)
    bar.track:SetVertexColor(1, 1, 1, 0.1)
    local w = width * math.max(0, math.min(1, pct or 0))
    bar.fillFrame:SetShown(w >= 1)
    -- No narrower than its height, or the round ends would overlap
    bar.fillFrame:SetWidth(math.max(bar:GetHeight(), w))
    bar.fill:SetVertexColor(r, g, b, 1)
end

-- Small pill button (the titles' "Track", the roster's "Show characters"):
-- faint with grey text, gold-tinted with gold text while on (b.on);
-- brighter on hover, the text dips while pressed. Sized to its text.
local PILL_BTN_H = 16
local function PaintPillButton(b)
    if b.on then
        b.bg:SetVertexColor(1, 0.82, 0, b.hover and 0.4 or 0.28)
        b.text:SetText("|cffffd100" .. b.labelOn .. "|r")
    else
        b.bg:SetVertexColor(1, 1, 1, b.hover and 0.16 or 0.08)
        b.text:SetText((b.hover and "|cffffffff" or "|cffb4b1bc") .. b.labelOff .. "|r")
    end
    b:SetWidth(math.max(PILL_BTN_H * 2, math.floor(b.text:GetStringWidth() + 20)))
end

-- tooltip(self) fills the GameTooltip, onClick(self) does the work
local function NewPillButton(parent, labelOff, labelOn, onClick, tooltip)
    local b = CreateFrame("Button", nil, parent)
    b:SetSize(56, PILL_BTN_H)
    b.labelOff, b.labelOn = labelOff, labelOn
    b.bg = PVPHUB.UI.CreatePill(b, "BACKGROUND", 0)
    b.text = NewText(b, 10)
    b.text:SetPoint("CENTER", 0, 0)
    b.text:SetJustifyH("CENTER")
    b:SetScript("OnClick", onClick)
    b:SetScript("OnEnter", function(self)
        self.hover = true
        PaintPillButton(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        tooltip(self)
        GameTooltip:Show()
    end)
    b:SetScript("OnLeave", function(self)
        self.hover = false
        PaintPillButton(self)
        GameTooltip:Hide()
    end)
    b:SetScript("OnMouseDown", function(self) self.text:SetPoint("CENTER", 0, -1) end)
    b:SetScript("OnMouseUp", function(self) self.text:SetPoint("CENTER", 0, 0) end)
    PaintPillButton(b)
    return b
end

-- --------------------------------------------------------------------------
-- Widgets (built once)
-- --------------------------------------------------------------------------

local w = {}   -- every widget, by name

local function TooltipFor(frame, fill)
    frame:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        fill(self)
        GameTooltip:Show()
    end)
    frame:SetScript("OnLeave", function() GameTooltip:Hide() end)
end

local function ClassName(token)
    return (LOCALIZED_CLASS_NAMES_MALE and LOCALIZED_CLASS_NAMES_MALE[token]) or token
end

local function ClassIcon(tex, token)
    local path = PVPHUB._CLASS_ICON_PATHS and PVPHUB._CLASS_ICON_PATHS[token]
    tex:SetTexture(path)
    tex:SetTexCoord(0.08, 0.92, 0.08, 0.92)
end

-- A round icon in a thin ring (a panel ring whose corners are half its
-- size is a circle)
local function NewRoundIcon(parent, size)
    local h = CreateFrame("Frame", nil, parent)
    h:SetSize(size, size)
    h.icon = h:CreateTexture(nil, "ARTWORK")
    h.icon:SetPoint("TOPLEFT", 1, -1)
    h.icon:SetPoint("BOTTOMRIGHT", -1, 1)
    local mask = h:CreateMaskTexture()
    mask:SetTexture(ICON_MASK, "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
    mask:SetAllPoints(h.icon)
    h.icon:AddMaskTexture(mask)
    h.ring = PVPHUB.UI.CreatePanel(h, "ring", "OVERLAY", 0, size / 2)
    return h
end

-- Shows texture in the icon with its ring in r, g, b, a (hidden without
-- a texture)
local function PaintRoundIcon(h, texture, r, g, b, a)
    h:SetShown(texture ~= nil)
    if not texture then return end
    h.icon:SetTexture(texture)
    h.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    h.icon:SetDesaturated(false)
    h.ring:SetVertexColor(r or 1, g or 1, b or 1, a or 0.6)
end

-- A character's class icon in a ring of its class color
local function PaintClassFace(h, charKey)
    local data = PVPHUB_DB and PVPHUB_DB[charKey]
    local token = data and data.class and data.class:upper()
    local c = token and RAID_CLASS_COLORS[token]
    h:Show()
    ClassIcon(h.icon, token)
    h.icon:SetDesaturated(false)
    h.ring:SetVertexColor(c and c.r or 0.6, c and c.g or 0.6, c and c.b or 0.6, 0.9)
end

-- An expansion's logo (the login screen's), nil if the game has none for it
local function ExpansionLogo(level)
    if not (level and GetExpansionDisplayInfo) then return nil end
    local ok, info = pcall(GetExpansionDisplayInfo, level)
    return ok and info and info.logo or nil
end

-- The Conquest emblem, nil if the game doesn't hand it out
local function ConquestIcon()
    if not (C_CurrencyInfo and C_CurrencyInfo.GetCurrencyInfo) then return nil end
    local ok, info = pcall(C_CurrencyInfo.GetCurrencyInfo, CONQUEST_ID)
    return ok and info and info.iconFileID or nil
end

-- One character in a tooltip: games, main bracket, best rating
local function CharacterTooltip(pl)
    GameTooltip:SetText(CharName(pl.key, true))
    GameTooltip:AddDoubleLine("Games", Count(pl.played) .. "  ·  " .. WinText(pl.won / math.max(1, pl.played)), 0.7, 0.7, 0.7, 1, 1, 1)
    if pl.main then GameTooltip:AddDoubleLine("Plays most", BracketLabel(pl.main), 0.7, 0.7, 0.7, 1, 1, 1) end
    if pl.bestMeta then
        GameTooltip:AddDoubleLine("Best rating", Rating(pl.best) .. "  |cff8f8c99" .. BracketLabel(pl.bestMeta) .. "|r", 0.7, 0.7, 0.7, 1, 1, 1)
    end
end

-- The top row: the season, the best rating, the win rate
local function CreateHero(content)
    -- Season: the expansion's logo (or the Conquest emblem), the season's
    -- name, its characters and games, and the season menu. The text is
    -- placed when painted, right of whichever of the two is shown.
    local s = NewPanel(content)
    w.season = s
    s:SetHeight(HERO_H)
    s.logo = s:CreateTexture(nil, "ARTWORK")
    s.logo:SetSize(LOGO_W, LOGO_H)
    s.logo:SetPoint("LEFT", PAD, 0)
    s.emblem = NewRoundIcon(s, EMBLEM)
    s.emblem:SetPoint("LEFT", PAD, 0)
    w.title = NewText(s, 16)
    w.title:SetTextColor(1, 0.82, 0, 1)
    w.sub = Muted(NewText(s, 11))

    -- Where the numbers come from, behind a small "i" in the corner
    w.info = CreateFrame("Button", nil, s)
    w.info:SetSize(14, 14)
    w.info:SetPoint("TOPRIGHT", -10, -10)
    local icon = w.info:CreateTexture(nil, "ARTWORK")
    icon:SetAllPoints()
    icon:SetTexture("Interface\\common\\help-i")
    TooltipFor(w.info, function()
        GameTooltip:SetText("Where these numbers come from", 1, 0.82, 0)
        GameTooltip:AddLine("Games, win rates and best ratings come from the game and cover the whole season, as of each character's last login.", 1, 1, 1, true)
        GameTooltip:AddLine("Most played spec counts the matches PVPHUB recorded, so only those since it was installed.", 0.7, 0.7, 0.7, true)
    end)

    w.seasonBtn = CreateFrame("Button", nil, s, "UIPanelButtonTemplate")
    w.seasonBtn:SetSize(160, 20)
    w.seasonBtn:SetScript("OnClick", function(self) Tab.OpenSeasonMenu(self) end)
    if PVPHUB.UI then PVPHUB.UI.SkinButton(w.seasonBtn) end

    -- Best rating: the number big in its color, the bracket's icon, and
    -- who got it
    local b = NewPanel(content)
    w.best = b
    b:SetHeight(HERO_H)
    b.label = Muted(NewText(b, 11))
    b.label:SetPoint("TOPLEFT", PAD, -12)
    b.label:SetText("Best rating")
    b.value = NewText(b, 26)
    b.value:SetPoint("TOPLEFT", PAD, -28)
    b.bracket = NewRoundIcon(b, 40)
    b.bracket:SetPoint("TOPRIGHT", -PAD, -14)
    b.face = NewRoundIcon(b, 16)
    b.face:SetPoint("TOPLEFT", PAD, -64)
    b.who = NewText(b, 11)
    b.who:SetPoint("LEFT", b.face, "RIGHT", 6, 0)

    -- Win rate: the number, wins against losses as one bar, the games
    local v = NewPanel(content)
    w.win = v
    v:SetHeight(HERO_H)
    v.label = Muted(NewText(v, 11))
    v.label:SetPoint("TOPLEFT", PAD, -12)
    v.label:SetText("Win rate")
    v.games = Muted(NewText(v, 11))
    v.games:SetPoint("TOPRIGHT", -PAD, -12)
    v.games:SetJustifyH("RIGHT")
    v.value = NewText(v, 26)
    v.value:SetPoint("TOPLEFT", PAD, -28)
    v.bar = NewBar(v, 6)
    v.bar:SetPoint("TOPLEFT", PAD, -62)
    v.won = NewText(v, 11)
    v.won:SetPoint("TOPLEFT", PAD, -73)
    v.lost = NewText(v, 11)
    v.lost:SetPoint("TOPRIGHT", -PAD, -73)
    v.lost:SetJustifyH("RIGHT")
end

-- A card per bracket, tinted in the bracket's color; hover for every
-- character's games in it
local function CreateBracketCards(content)
    w.cards = {}
    for i = 1, #PVPHUB._BRACKET_META do
        local c = CreateFrame("Button", nil, content)
        c:SetHeight(CARD_H)
        c.bg = PVPHUB.CreateRoundedShape(c, "BACKGROUND", 0, 0, 10)
        c.bg:SetRounded(true)
        c.glow = PVPHUB.CreateRoundedShape(c, "BORDER", 0, 0, 10)
        c.glow:SetRounded(true)
        c.glow:SetVertexColor(1, 1, 1, 0.05)
        c.glow:Hide()

        c.icon = NewRoundIcon(c, 30)
        c.icon:SetPoint("TOPLEFT", PAD, -PAD)
        c.label = NewText(c, 12)
        c.label:SetPoint("LEFT", c.icon, "RIGHT", 8, 0)
        c.best = NewText(c, 22)
        c.best:SetPoint("TOPLEFT", PAD, -52)
        c.bestLabel = Muted(NewText(c, 10))
        c.bestLabel:SetPoint("BOTTOMLEFT", c.best, "BOTTOMRIGHT", 5, 2)
        c.bestLabel:SetText("best")
        c.bar = NewBar(c, 5)
        c.bar:SetPoint("TOPLEFT", PAD, -82)
        c.stats = NewText(c, 11)
        c.stats:SetPoint("TOPLEFT", PAD, -93)

        -- The classes that played it, overlapping like avatars
        c.faces = {}
        for f = 1, MAX_FACES do
            c.faces[f] = NewRoundIcon(c, FACE)
        end
        c.more = Muted(NewText(c, 10))
        c.more:SetJustifyH("RIGHT")

        c:SetScript("OnEnter", function(self)
            local bt = self.data
            if not bt then return end
            self.glow:Show()
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetText(bt.meta.label, 1, 0.82, 0)
            GameTooltip:AddLine("Games per character this season", 0.7, 0.7, 0.7)
            for _, ch in ipairs(bt.chars) do
                GameTooltip:AddDoubleLine(CharName(ch.key, true),
                    string.format("%d games  ·  %s  ·  best %s", ch.s.played, WinText(ch.s.won / ch.s.played), Rating(ch.s.best)),
                    1, 1, 1, 0.85, 0.85, 0.85)
            end
            GameTooltip:Show()
        end)
        c:SetScript("OnLeave", function(self)
            self.glow:Hide()
            GameTooltip:Hide()
        end)
        w.cards[i] = c
    end
end

local function CreateTitles(content)
    local p = NewPanel(content)
    w.titles = p
    p.heading = NewText(p, 12)
    p.heading:SetPoint("TOPLEFT", PAD, -10)
    p.heading:SetTextColor(1, 0.82, 0, 1)
    p.heading:SetText("Season titles")

    p.rows = {}
    for i, meta in ipairs(PVPHUB._TITLE_META or {}) do
        local row = CreateFrame("Frame", nil, p)
        row:SetHeight(TITLE_ROW_H)
        row:EnableMouse(true)
        row.meta = meta
        -- The title achievement's icon, ringed gold once earned
        row.icon = NewRoundIcon(row, TITLE_ICON)
        row.icon:SetPoint("TOPLEFT", 0, -2)
        local textX = TITLE_ICON + 10
        row.name = NewText(row, 12)
        row.name:SetPoint("TOPLEFT", textX, 0)
        row.name:SetText(meta.name)
        row.value = NewText(row, 12)
        row.value:SetPoint("TOPRIGHT", 0, 0)
        row.value:SetJustifyH("RIGHT")
        row.bar = NewBar(row, 6)
        row.bar:SetPoint("TOPLEFT", textX, -18)
        row.who = NewText(row, 11)
        row.who:SetPoint("TOPLEFT", textX, -29)

        -- Track: the floating title overlay (PVPHUB:UpdateTitleTracker),
        -- a pill button right after the title's name
        local track = NewPillButton(row, "Track", "Tracking", function()
            PVPHUB_SETTINGS.trackedTitles = PVPHUB_SETTINGS.trackedTitles or {}
            local t = PVPHUB_SETTINGS.trackedTitles
            t[meta.key] = not t[meta.key] or nil
            if PVPHUB.UpdateTitleTracker then PVPHUB:UpdateTitleTracker() end
            Tab.Render()
        end, function()
            GameTooltip:SetText("Track in a floating overlay", 1, 1, 1)
            GameTooltip:AddLine("Shows this title's progress in a small movable window, even with PVPHUB closed.", 0.7, 0.7, 0.7, true)
        end)
        track:SetPoint("LEFT", row.name, "RIGHT", 10, 0)
        track:SetFrameLevel(row:GetFrameLevel() + 2)
        row.track = track

        TooltipFor(row, function(self)
            GameTooltip:SetText(meta.name, 1, 0.82, 0)
            local req = not Tab.season and PVPHUB._GetTitleRequirementText(meta, self.data)
            if req then GameTooltip:AddLine(req, 0.9, 0.9, 0.9, true) end
            if meta.rewardText and meta.rewardText ~= "" then
                GameTooltip:AddLine("Reward: " .. meta.rewardText, 0.55, 0.8, 1, true)
            end
        end)
        p.rows[i] = row
    end
end

-- A character under an opened class: name and realm, its games and win
-- rate, best rating on the right; hover for its main bracket too
local function CreateCharRow(parent)
    local r = CreateFrame("Button", nil, parent)
    r:SetHeight(ROSTER_ROW_H)
    local hl = r:CreateTexture(nil, "HIGHLIGHT")
    hl:SetAllPoints()
    hl:SetTexture("Interface\\Buttons\\WHITE8x8")
    hl:SetVertexColor(1, 1, 1, 0.05)
    r.name = NewText(r, 12)
    r.name:SetPoint("LEFT", 6, 0)
    r.rating = NewText(r, 12)
    r.rating:SetPoint("RIGHT", -6, 0)
    r.rating:SetJustifyH("RIGHT")
    r.games = NewText(r, 11)
    r.games:SetPoint("RIGHT", -52, 0)
    r.games:SetJustifyH("RIGHT")
    TooltipFor(r, function(self) CharacterTooltip(self.player) end)
    return r
end

-- A class chip in its class color: stronger when its characters are open,
-- a little stronger on hover
local function PaintClassChip(chip)
    local c = RAID_CLASS_COLORS[chip.data.token]
    local open = Tab.rosterClass == chip.data.token
    local a = open and 0.42 or (chip.hover and 0.26 or 0.16)
    chip.bg:SetVertexColor(c and c.r or 1, c and c.g or 1, c and c.b or 1, a)
end

-- A class heading in the expanded list: icon, name in its color, count
local function CreateClassHead(parent)
    local h = CreateFrame("Frame", nil, parent)
    h:SetHeight(20)
    h.icon = h:CreateTexture(nil, "ARTWORK")
    h.icon:SetSize(16, 16)
    h.icon:SetPoint("LEFT", 0, 0)
    h.text = NewText(h, 12)
    h.text:SetPoint("LEFT", h.icon, "RIGHT", 6, 0)
    h.line = h:CreateTexture(nil, "ARTWORK")
    h.line:SetTexture("Interface\\Buttons\\WHITE8x8")
    h.line:SetHeight(1)
    h.line:SetPoint("BOTTOMLEFT", 0, -2)
    h.line:SetPoint("BOTTOMRIGHT", 0, -2)
    return h
end

local function CreateRoster(content)
    local p = NewPanel(content)
    w.roster = p

    p.heading = NewText(p, 12)
    p.heading:SetPoint("TOPLEFT", PAD, -10)
    p.heading:SetTextColor(1, 0.82, 0, 1)
    p.heading:SetText("Classes played")

    p.hint = Muted(NewText(p, 10))
    p.hint:SetPoint("TOPRIGHT", -PAD, -12)
    p.hint:SetJustifyH("RIGHT")
    p.hint:SetText("Click a class to see its characters")

    -- One chip per class: its icon on a pill in its color, and how many.
    -- Clicking one opens that class's characters right under the chips
    -- (Tab.rosterClass, one class at a time); clicking it again closes them.
    p.chips = {}
    for i = 1, MAX_CLASSES do
        local chip = CreateFrame("Button", nil, p)
        chip:SetSize(44, CHIP_H)
        chip.bg = PVPHUB.UI.CreatePill(chip, "ARTWORK", 0)
        chip.icon = chip:CreateTexture(nil, "OVERLAY")
        chip.icon:SetSize(16, 16)
        chip.icon:SetPoint("LEFT", 6, 0)
        chip.text = NewText(chip, 12)
        chip.text:SetPoint("LEFT", chip.icon, "RIGHT", 5, 0)
        chip:SetScript("OnClick", function(self)
            Tab.rosterClass = (Tab.rosterClass ~= self.data.token) and self.data.token or nil
            Tab.Render()
        end)
        chip:SetScript("OnEnter", function(self)
            self.hover = true
            PaintClassChip(self)
            local c = RAID_CLASS_COLORS[self.data.token]
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetText(ClassName(self.data.token), c and c.r or 1, c and c.g or 1, c and c.b or 1)
            GameTooltip:AddLine(Tab.rosterClass == self.data.token and "Click to close" or "Click to see its characters", 0.7, 0.7, 0.7)
            GameTooltip:Show()
        end)
        chip:SetScript("OnLeave", function(self)
            self.hover = false
            PaintClassChip(self)
            GameTooltip:Hide()
        end)
        p.chips[i] = chip
    end
    p.none = Muted(NewText(p, 12))
    p.none:SetText("—")

    p.divider = p:CreateTexture(nil, "ARTWORK")
    p.divider:SetTexture("Interface\\Buttons\\WHITE8x8")
    p.divider:SetVertexColor(1, 1, 1, 0.07)
    p.divider:SetHeight(1)
    p.charRows = {}

    p.specLabel = Muted(NewText(p, 11))
    p.specLabel:SetText("Most played spec")
    p.specIcon = p:CreateTexture(nil, "ARTWORK")
    p.specIcon:SetSize(16, 16)
    p.specIcon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    p.specValue = NewText(p, 12)

    p.favLabel = Muted(NewText(p, 11))
    p.favLabel:SetText("Favourite bracket")
    p.favIcon = p:CreateTexture(nil, "ARTWORK")
    p.favIcon:SetSize(16, 16)
    p.favIcon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    p.favValue = NewText(p, 12)
end

-- The best characters by rating: rank, class icon, name, the bracket of
-- their best rating, games and win rate, the rating; the most played one
-- wears an MVP badge
local function CreateTop(content)
    local p = NewPanel(content)
    w.top = p
    p.heading = NewText(p, 12)
    p.heading:SetPoint("TOPLEFT", PAD, -10)
    p.heading:SetTextColor(1, 0.82, 0, 1)
    p.heading:SetText("Top characters")
    p.hint = Muted(NewText(p, 10))
    p.hint:SetPoint("TOPRIGHT", -PAD, -12)
    p.hint:SetJustifyH("RIGHT")
    p.hint:SetText("by best rating")

    p.rows = {}
    for i = 1, TOP_COUNT do
        local r = CreateFrame("Button", nil, p)
        r:SetHeight(TOP_ROW_H)
        local hl = r:CreateTexture(nil, "HIGHLIGHT")
        hl:SetAllPoints()
        hl:SetTexture("Interface\\Buttons\\WHITE8x8")
        hl:SetVertexColor(1, 1, 1, 0.05)
        r.rank = Muted(NewText(r, 12))
        r.rank:SetPoint("LEFT", 0, 0)
        r.rank:SetWidth(14)
        r.rank:SetJustifyH("CENTER")
        r.face = NewRoundIcon(r, 26)
        r.face:SetPoint("LEFT", 20, 0)
        r.name = NewText(r, 12)
        r.name:SetPoint("TOPLEFT", r.face, "TOPRIGHT", 8, 0)
        r.bracket = r:CreateTexture(nil, "ARTWORK")
        r.bracket:SetSize(12, 12)
        r.bracket:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        r.bracket:SetPoint("BOTTOMLEFT", r.face, "BOTTOMRIGHT", 8, 0)
        r.sub = Muted(NewText(r, 10))
        r.sub:SetPoint("LEFT", r.bracket, "RIGHT", 4, 0)
        r.rating = NewText(r, 15)
        r.rating:SetPoint("RIGHT", -4, 0)
        r.rating:SetJustifyH("RIGHT")

        r.mvp = CreateFrame("Frame", nil, r)
        r.mvp:SetSize(30, 13)
        r.mvp:SetPoint("LEFT", r.name, "RIGHT", 6, 0)
        PVPHUB.UI.CreatePill(r.mvp, "ARTWORK", 0):SetVertexColor(1, 0.82, 0, 0.25)
        local mvpText = NewText(r.mvp, 9)
        mvpText:SetPoint("CENTER", 0, 0)
        mvpText:SetText("|cffffd100MVP|r")

        TooltipFor(r, function(self)
            CharacterTooltip(self.player)
            if self.mvp:IsShown() then
                GameTooltip:AddLine("MVP: the most games this season", 1, 0.82, 0)
            end
        end)
        p.rows[i] = r
    end
    p.empty = Muted(NewText(p, 12))
    p.empty:SetPoint("TOPLEFT", PAD, -36)
end

-- --------------------------------------------------------------------------
-- Painting
-- --------------------------------------------------------------------------

-- "Midnight Season 2"; an archived season with the expansion it was played in
local function SeasonLabel(season, archived)
    if archived and PVPHUB.Seasons then return PVPHUB.Seasons.Name(season) end
    return (PVPHUB._GetSeasonDisplayName and PVPHUB._GetSeasonDisplayName(season)) or "This season"
end

-- Places panels side by side from x = 0, widths in proportion to shares
local function Row(panels, shares, top, width)
    local total = 0
    for _, s in ipairs(shares) do total = total + s end
    local avail = width - GAP * (#panels - 1)
    local x = 0
    for i, p in ipairs(panels) do
        local pw = (i == #panels) and (width - x) or math.floor(avail * shares[i] / total)
        p:ClearAllPoints()
        p:SetPoint("TOPLEFT", Tab.content, "TOPLEFT", x, -top)
        p:SetWidth(pw)
        x = x + pw + GAP
    end
end

local function PaintHero(d, season, archived, top, width)
    Row({ w.season, w.best, w.win }, { 1.55, 1, 1 }, top, width)

    -- Season
    local s = w.season
    PaintPanel(s)
    -- The logo of the expansion the season belongs to (an archived season
    -- remembers it); the Conquest emblem if the game has no logo for it
    local level = (archived and PVPHUB.Seasons.Expansion(season))
        or (GetServerExpansionLevel and GetServerExpansionLevel())
        or (GetExpansionLevel and GetExpansionLevel())
    local logo = ExpansionLogo(level)
    s.logo:SetShown(logo ~= nil)
    if logo then
        s.logo:SetTexture(logo)
        s.logo:SetTexCoord(LOGO_CROP[1], LOGO_CROP[2], 0, 1)
        s.emblem:Hide()
    else
        PaintRoundIcon(s.emblem, ConquestIcon() or "Interface\\Icons\\achievement_arena_3v3_1", 1, 0.82, 0, 0.75)
    end
    -- The season menu only when there's another season to pick
    local past = PVPHUB.Seasons and PVPHUB.Seasons.Summary() or {}
    local hasPast = false
    for _, ps in ipairs(past) do
        if ps.season ~= CurrentSeason() then hasPast = true end
    end
    local menu = hasPast or archived

    -- Name, characters and games (and the menu) as one block, centered on
    -- the logo
    local textX = PAD + (logo and LOGO_W or EMBLEM) + 14
    local blockTop = math.floor((HERO_H - (menu and 62 or 36)) / 2)
    w.title:ClearAllPoints()
    w.title:SetPoint("TOPLEFT", s, "TOPLEFT", textX, -blockTop)
    w.sub:ClearAllPoints()
    w.sub:SetPoint("TOPLEFT", s, "TOPLEFT", textX, -(blockTop + 22))
    w.seasonBtn:ClearAllPoints()
    w.seasonBtn:SetPoint("TOPLEFT", s, "TOPLEFT", textX, -(blockTop + 42))
    local textW = s:GetWidth() - textX - PAD
    w.title:SetText(SeasonLabel(season, archived) .. (archived and "  |cff888888(archive)|r" or ""))
    w.title:SetWidth(textW - 22)   -- clear of the "i" in the corner
    local n = d.chars
    w.sub:SetText(string.format("%d character%s  ·  %s games", n, n == 1 and "" or "s", Count(d.played)))
    w.sub:SetWidth(textW)
    w.seasonBtn:SetText(archived and SeasonLabel(season, true) or "Current season")
    w.seasonBtn:SetShown(menu)
    w.seasonBtn:SetWidth(math.min(160, textW))

    -- Best rating
    local b = w.best
    PaintPanel(b)
    if d.best then
        local mc = d.best.meta.color
        b.value:SetText(Rating(d.best.rating))
        PaintRoundIcon(b.bracket, d.best.meta.icon, mc[1], mc[2], mc[3], 0.9)
        PaintClassFace(b.face, d.best.char)
        b.who:SetText(CharName(d.best.char) .. "  |cff8f8c99· " .. BracketLabel(d.best.meta) .. "|r")
    else
        b.value:SetText("|cff555555—|r")
        b.bracket:Hide()
        b.face:Hide()
        b.who:SetText("|cff777777No rated games yet|r")
    end
    b.who:SetWidth(b:GetWidth() - PAD * 2 - 22)

    -- Win rate: wins fill the bar in green, the rest of it is the losses
    local v = w.win
    PaintPanel(v)
    local iw = v:GetWidth() - PAD * 2
    if d.played > 0 then
        local pct = d.won / d.played
        local r, g, bl = WinColor(pct)
        v.value:SetText(math.floor(pct * 100 + 0.5) .. "%")
        v.value:SetTextColor(r, g, bl, 1)
        PaintBar(v.bar, iw, pct, 0.37, 0.82, 0.48)
        v.bar.track:SetVertexColor(1, 0.42, 0.42, 0.75)
        v.games:SetText(Count(d.played) .. " games")
        v.won:SetText("|cff5fd17a" .. Count(d.won) .. " won|r")
        v.lost:SetText("|cffff6b6b" .. Count(d.lost) .. " lost|r")
    else
        v.value:SetText("—")
        v.value:SetTextColor(0.33, 0.33, 0.33, 1)
        PaintBar(v.bar, iw, 0, 1, 1, 1)
        v.games:SetText("")
        v.won:SetText("")
        v.lost:SetText("")
    end
    return top + HERO_H
end


-- Played brackets first (most games first), then the rest in their usual
-- order, dimmed. Returns where the cards end.
local function PaintBracketCards(d, archived, top, width)
    local order = {}
    for i, meta in ipairs(PVPHUB._BRACKET_META) do
        order[i] = { meta = meta, bt = d.brackets[meta.key], index = i }
    end
    table.sort(order, function(a, b)
        local pa, pb = a.bt and a.bt.played or 0, b.bt and b.bt.played or 0
        if pa ~= pb then return pa > pb end
        return a.index < b.index
    end)

    local perRow = (width >= 700) and #order or 3
    local cardW = (width - GAP * (perRow - 1)) / perRow
    local pr, pg, pb = PanelColor()
    for i, c in ipairs(w.cards) do
        local meta, bt = order[i].meta, order[i].bt
        local mc = meta.color
        c.data = bt
        c:ClearAllPoints()
        c:SetPoint("TOPLEFT", Tab.content, "TOPLEFT",
            ((i - 1) % perRow) * (cardW + GAP), -(top + math.floor((i - 1) / perRow) * (CARD_H + GAP)))
        c:SetWidth(cardW)
        c.label:SetText(BracketLabel(meta))
        c.label:SetWidth(cardW - PAD * 2 - 38)
        PaintRoundIcon(c.icon, meta.icon, mc[1], mc[2], mc[3], bt and 0.9 or 0.4)
        c.icon.icon:SetDesaturated(not bt)

        local shown = 0
        if bt then
            -- The bracket's color glows in from the top
            c.bg:SetGradient("VERTICAL", CreateColor(pr, pg, pb, 0.6),
                CreateColor(pr + (mc[1] - pr) * 0.4, pg + (mc[2] - pg) * 0.4, pb + (mc[3] - pb) * 0.4, 0.75))
            c.best:SetText(Rating(bt.best))
            c.bestLabel:SetShown(bt.best > 0)
            local pct = bt.won / bt.played
            local r, g, b = WinColor(pct)
            PaintBar(c.bar, cardW - PAD * 2, pct, r, g, b)
            c.bar:Show()
            c.stats:SetText(string.format("|cffffffff%s|r |cff8f8c99games  ·|r %s", Count(bt.played), WinText(pct)))
            -- As many faces as fit right of the rating, "+N" for the rest
            table.sort(bt.chars, function(x, y) return x.s.played > y.s.played end)
            local step = FACE - 4
            local room = cardW - PAD * 2 - c.best:GetStringWidth() - 10
                - (c.bestLabel:IsShown() and c.bestLabel:GetStringWidth() + 5 or 0)
            shown = math.min(#bt.chars, MAX_FACES)
            while shown > 0 do
                local extra = #bt.chars - shown
                c.more:SetText(extra > 0 and ("+" .. extra) or "")
                local need = FACE + (shown - 1) * step + (extra > 0 and c.more:GetStringWidth() + 3 or 0)
                if need <= room then break end
                shown = shown - 1
            end
            for f = 1, shown do
                local face = c.faces[f]
                PaintClassFace(face, bt.chars[f].key)
                face:ClearAllPoints()
                face:SetPoint("TOPRIGHT", c, "TOPRIGHT", -PAD - (shown - f) * step, -54)
            end
            c.more:SetShown(shown > 0 and #bt.chars > shown)
            c.more:ClearAllPoints()
            if shown > 0 then c.more:SetPoint("RIGHT", c.faces[1], "LEFT", -3, 0) end
        else
            c.bg:SetVertexColor(pr, pg, pb, 0.4)
            c.best:SetText("|cff555555—|r")
            c.bestLabel:Hide()
            c.bar:Hide()
            c.stats:SetText("|cff666666No games " .. (archived and "that season" or "yet") .. "|r")
            c.more:Hide()
        end
        for f = shown + 1, MAX_FACES do c.faces[f]:Hide() end
        c:SetAlpha(bt and 1 or 0.7)
    end
    return top + math.ceil(#order / perRow) * (CARD_H + GAP) - GAP
end

local function PaintTitles(d, archived, top, x, width)
    local p = w.titles
    PaintPanel(p, true)
    p:ClearAllPoints()
    p:SetPoint("TOPLEFT", Tab.content, "TOPLEFT", x, -top)
    p:SetWidth(width)
    local iw = width - PAD * 2
    local tracked = PVPHUB_SETTINGS.trackedTitles or {}

    local y = 34
    for _, row in ipairs(p.rows) do
        local meta = row.meta
        local t = d.titles[meta.key] or { current = 0, required = 0 }
        row.data = t.tp or t
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", PAD, -y)
        row:SetWidth(iw)
        local barW = iw - (TITLE_ICON + 10)
        row.who:SetWidth(barW)

        local mc = meta.color
        PaintRoundIcon(row.icon, t.icon or meta.icon, mc[1], mc[2], mc[3], 0.6)
        if t.earned then
            row.icon.ring:SetVertexColor(1, 0.82, 0, 0.95)
            row.value:SetText("|cffffd100Earned|r")
            PaintBar(row.bar, barW, 1, 1, 0.82, 0)
            local when = EarnedDate(t.tp)
            row.who:SetText(CharName(t.char) .. (when and ("  |cff8f8c99· " .. when .. "|r") or ""))
        else
            local required = t.required > 0 and t.required or nil
            local pct = required and math.min(1, t.current / required) or 0
            row.icon.icon:SetDesaturated(t.current <= 0)
            row.value:SetText(required and string.format("|cffffffff%d / %d|r", math.min(t.current, required), required) or "|cff555555—|r")
            PaintBar(row.bar, barW, pct, ProgressColor(pct))
            row.who:SetText(t.char and CharName(t.char) or "|cff777777No progress yet|r")
        end

        -- Tracking only means something for the season being played
        row.track:SetShown(not archived)
        row.track.on = tracked[meta.key] and true or false
        PaintPillButton(row.track)
        y = y + TITLE_ROW_H
    end
    return y + 4
end

local function PaintRoster(d, top, width)
    local p = w.roster
    PaintPanel(p)
    p:ClearAllPoints()
    p:SetPoint("TOPLEFT", Tab.content, "TOPLEFT", 0, -top)
    p:SetWidth(width)
    local iw = width - PAD * 2

    -- Classes, most characters first; each with its players, most games first
    local classes = {}
    for _, cls in pairs(d.classes) do classes[#classes + 1] = cls end
    table.sort(classes, function(a, b)
        if #a.chars ~= #b.chars then return #a.chars > #b.chars end
        return a.token < b.token
    end)
    local playersOf = {}
    for _, pl in ipairs(d.players) do
        if pl.class then
            playersOf[pl.class] = playersOf[pl.class] or {}
            table.insert(playersOf[pl.class], pl)
        end
    end
    -- An opened class that isn't there any more (other season) closes
    if Tab.rosterClass and not playersOf[Tab.rosterClass] then Tab.rosterClass = nil end
    p.hint:SetShown(#classes > 0)

    -- Chips, wrapping to a new line when the panel is full
    local y = 34
    local cx, rowY = 0, y
    for i, chip in ipairs(p.chips) do
        local cls = classes[i]
        chip:SetShown(cls ~= nil)
        if cls then
            chip.data = cls
            PaintClassChip(chip)
            ClassIcon(chip.icon, cls.token)
            chip.text:SetText("|cffffffff" .. #cls.chars .. "|r")
            local cw = math.floor(6 + 16 + 5 + chip.text:GetStringWidth() + 10)
            if cx > 0 and cx + cw > iw then
                cx, rowY = 0, rowY + CHIP_H + 6
            end
            chip:SetWidth(cw)
            chip:ClearAllPoints()
            chip:SetPoint("TOPLEFT", p, "TOPLEFT", PAD + cx, -rowY)
            cx = cx + cw + 6
        end
    end
    p.none:SetShown(#classes == 0)
    p.none:ClearAllPoints()
    p.none:SetPoint("TOPLEFT", PAD, -y - 3)
    y = rowY + CHIP_H + 12

    -- The opened class: a heading, then its characters (most games first)
    -- in columns, filled top to bottom
    local open = Tab.rosterClass
    local list = open and playersOf[open] or {}
    p.divider:SetShown(open ~= nil)
    p.head = p.head or CreateClassHead(p)
    p.head:SetShown(open ~= nil)
    if open then
        local cc = RAID_CLASS_COLORS[open]
        p.head:ClearAllPoints()
        p.head:SetPoint("TOPLEFT", p, "TOPLEFT", PAD, -y)
        p.head:SetWidth(iw)
        ClassIcon(p.head.icon, open)
        p.head.text:SetText((cc and cc:WrapTextInColorCode(ClassName(open)) or ClassName(open))
            .. "  |cff8f8c99" .. #list .. (#list == 1 and " character" or " characters") .. "|r")
        p.head.line:SetVertexColor(cc and cc.r or 1, cc and cc.g or 1, cc and cc.b or 1, 0.3)
        y = y + 26

        local cols = (iw >= 520 and #list > 1) and 2 or 1
        local gap = 24
        local colW = math.floor((iw - gap * (cols - 1)) / cols)
        local perCol = math.ceil(#list / cols)
        for i, pl in ipairs(list) do
            local r = p.charRows[i] or CreateCharRow(p)
            p.charRows[i] = r
            local col = math.floor((i - 1) / perCol)
            local line = (i - 1) % perCol
            r.player = pl
            r:ClearAllPoints()
            r:SetPoint("TOPLEFT", p, "TOPLEFT", PAD + col * (colW + gap), -(y + line * ROSTER_ROW_H))
            r:SetWidth(colW)
            r.name:SetWidth(colW - 150)
            r.name:SetText(CharName(pl.key) .. "  |cff777777" .. (pl.key:match("%-(.+)$") or "") .. "|r")
            r.games:SetText(string.format("|cff8f8c99%s games ·|r %s", Count(pl.played), WinText(pl.won / math.max(1, pl.played))))
            r.rating:SetText(Rating(pl.best))
            r:Show()
        end
        y = y + perCol * ROSTER_ROW_H + 10
        p.divider:ClearAllPoints()
        p.divider:SetPoint("TOPLEFT", PAD, -y)
        p.divider:SetPoint("TOPRIGHT", -PAD, -y)
        y = y + 12
    end
    for i = #list + 1, #p.charRows do p.charRows[i]:Hide() end

    -- Most played spec (from recorded matches) and favourite bracket
    local specX, favX = PAD, PAD + iw * 0.5
    p.specLabel:ClearAllPoints()
    p.specLabel:SetPoint("TOPLEFT", p, "TOPLEFT", specX, -y)
    p.favLabel:ClearAllPoints()
    p.favLabel:SetPoint("TOPLEFT", p, "TOPLEFT", favX, -y)
    y = y + 18

    local bestSpec, bestGames = nil, 0
    for specID, games in pairs(d.specGames) do
        if games > bestGames then bestSpec, bestGames = specID, games end
    end
    local spec = bestSpec and PVPHUB._GetCachedSpecInfo(bestSpec)
    p.specIcon:ClearAllPoints()
    p.specIcon:SetPoint("TOPLEFT", p, "TOPLEFT", specX, -y)
    p.specIcon:SetShown(spec ~= nil and spec.icon ~= nil)
    if spec and spec.icon then p.specIcon:SetTexture(spec.icon) end
    p.specValue:ClearAllPoints()
    p.specValue:SetPoint("LEFT", p.specIcon, spec and spec.icon and "RIGHT" or "LEFT", spec and spec.icon and 6 or 0, 0)
    p.specValue:SetText(spec and string.format("|cffffffff%s|r  |cff8f8c99· %s games|r", spec.name or "?", Count(bestGames)) or "|cff555555—|r")

    local fav
    for _, bt in pairs(d.brackets) do
        if not fav or bt.played > fav.played then fav = bt end
    end
    p.favIcon:ClearAllPoints()
    p.favIcon:SetPoint("TOPLEFT", p, "TOPLEFT", favX, -y)
    p.favIcon:SetShown(fav ~= nil)
    if fav then p.favIcon:SetTexture(fav.meta.icon) end
    p.favValue:ClearAllPoints()
    p.favValue:SetPoint("LEFT", p.favIcon, fav and "RIGHT" or "LEFT", fav and 6 or 0, 0)
    p.favValue:SetText(fav and string.format("|cffffffff%s|r  |cff8f8c99· %d%%|r", BracketLabel(fav.meta),
        math.floor(fav.played / math.max(1, d.played) * 100 + 0.5)) or "|cff555555—|r")
    y = y + 26

    p:SetHeight(y)
    return top + y
end

-- Returns the panel's height
local function PaintTop(d, top, x, width)
    local p = w.top
    PaintPanel(p)
    p:ClearAllPoints()
    p:SetPoint("TOPLEFT", Tab.content, "TOPLEFT", x, -top)
    p:SetWidth(width)
    local iw = width - PAD * 2

    local list = {}
    for _, pl in ipairs(d.players) do
        if pl.best > 0 then list[#list + 1] = pl end
    end
    table.sort(list, function(a, b)
        if a.best ~= b.best then return a.best > b.best end
        return a.played > b.played
    end)
    local mvp = d.players[1]   -- most games first

    local y = 34
    for i, r in ipairs(p.rows) do
        local pl = list[i]
        r:SetShown(pl ~= nil)
        if pl then
            r.player = pl
            r:ClearAllPoints()
            r:SetPoint("TOPLEFT", PAD, -y)
            r:SetWidth(iw)
            r.rank:SetText(i)
            PaintClassFace(r.face, pl.key)
            r.name:SetText(CharName(pl.key))
            r.mvp:SetShown(pl == mvp)
            r.bracket:SetTexture(pl.bestMeta and pl.bestMeta.icon)
            r.sub:SetText(string.format("%s  ·  %s games  ·  %s", pl.bestMeta and BracketLabel(pl.bestMeta) or "",
                Count(pl.played), WinText(pl.won / math.max(1, pl.played))))
            r.sub:SetWidth(math.max(40, iw - 70 - 50))   -- clear of the rating
            r.rating:SetText(Rating(pl.best))
            y = y + TOP_ROW_H
        end
    end
    p.empty:SetShown(#list == 0)
    p.empty:SetText("No rated characters yet")
    if #list == 0 then y = 60 end
    return y + 6
end

function Tab.Render()
    local content = Tab.content
    if not content or not Tab.built then return end
    local width = content:GetWidth()
    if not width or width < 300 then width = 700 end
    width = width - 6   -- keep clear of the scroll bar

    local current = CurrentSeason()
    if Tab.season and (Tab.season == current or not PVPHUB.Seasons) then Tab.season = nil end
    local archived = Tab.season ~= nil
    local season = Tab.season or current
    local d = BuildData(season, archived)

    local y = PaintHero(d, season, archived, 0, width) + GAP
    y = PaintBracketCards(d, archived, y, width) + GAP

    local h
    if width >= TWO_COLUMN_MIN then
        local leftW = math.floor((width - GAP) / 2)
        local ht = PaintTitles(d, archived, y, 0, leftW)
        local hp = PaintTop(d, y, leftW + GAP, width - GAP - leftW)
        h = math.max(ht, hp)
        w.titles:SetHeight(h)
        w.top:SetHeight(h)
        y = y + h + GAP
    else
        h = PaintTitles(d, archived, y, 0, width)
        w.titles:SetHeight(h)
        y = y + h + GAP
        h = PaintTop(d, y, 0, width)
        w.top:SetHeight(h)
        y = y + h + GAP
    end

    y = PaintRoster(d, y, width)
    content:SetHeight(y + 10)
end

-- --------------------------------------------------------------------------
-- Season menu
-- --------------------------------------------------------------------------

function Tab.ShowSeason(season)
    Tab.season = season
    if Tab.scroll then Tab.scroll:SetVerticalScroll(0) end
    Tab.Render()
end

function Tab.OpenSeasonMenu(owner)
    if not MenuUtil or not PVPHUB.Seasons then return end
    local current = CurrentSeason()
    MenuUtil.CreateContextMenu(owner, function(_, root)
        root:CreateTitle("Show season")
        local function Add(text, season)
            root:CreateRadio(text,
                function() return Tab.season == season end,
                function()
                    Tab.ShowSeason(season)
                    return MenuResponse and MenuResponse.Close
                end)
        end
        Add("Current season  |cff888888" .. SeasonLabel(current) .. "|r", nil)
        for _, s in ipairs(PVPHUB.Seasons.Summary()) do
            if s.season ~= current then
                Add(string.format("%s  |cff888888%d characters|r", SeasonLabel(s.season, true), s.chars), s.season)
            end
        end
    end)
end

-- --------------------------------------------------------------------------
-- Building the tab (core's f:CreateStatsFrame hands over to this)
-- --------------------------------------------------------------------------

function Tab.Create(f)
    local container = CreateFrame("Frame", nil, f)
    container:SetPoint("TOPLEFT", f, "TOPLEFT", 20, -65)
    container:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -20, 85)

    local scroll = CreateFrame("ScrollFrame", nil, container, "ScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", container, "TOPLEFT", 0, -4)
    scroll:SetPoint("BOTTOMRIGHT", container, "BOTTOMRIGHT", -10, 0)
    PVPHUB._ApplyModernScrollbarStyling(scroll, PVPHUB.currentColors, PVPHUB._SCROLLBAR_NUDGE(f))
    PVPHUB.EnableSmoothScroll(scroll, 40)

    local content = CreateFrame("Frame", nil, scroll)
    content:SetSize(700, 400)
    scroll:SetScrollChild(content)

    Tab.content, Tab.scroll = content, scroll
    CreateHero(content)
    CreateBracketCards(content)
    CreateTitles(content)
    CreateTop(content)
    CreateRoster(content)
    Tab.built = true

    -- Only now: building can resolve the layout (a GetHeight in the button
    -- skin), which fires this, and a render before every panel exists
    -- broke on the missing ones
    scroll:SetScript("OnSizeChanged", function(_, width)
        content:SetWidth(width)
        if container:IsVisible() then Tab.Render() end
    end)

    f.statsFrame = container
    f.statsScrollFrame = scroll
    f.RenderStatsFor = Tab.Render
    Tab.Render()
end
