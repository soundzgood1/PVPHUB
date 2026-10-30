-- PVPHUB Season tab (7.0)
--
-- The whole roster's season at a glance, top to bottom:
--   header       season name, one line of context, the season menu (the
--                current season or one from the season archive, seasons.lua)
--   key numbers  games, win rate, best rating, characters
--   brackets     one comparable row per bracket (games, W-L, win rate, best);
--                hover a row for every character's share | season titles
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
local HEADER_H       = 44
local KPI_H          = 70
local KPI_COUNT      = 5     -- games, win rate, best rating, characters, MVP
local ROW_H          = 24    -- bracket row
local TITLE_ROW_H    = 50
local CHIP_H         = 22    -- class chip in the roster
local ROSTER_ROW_H   = 18    -- character in the roster's expanded list
local TWO_COLUMN_MIN = 640   -- narrower than this: the titles go below the brackets
local MAX_CLASSES    = 13

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

local function PaintPanel(p, gold)
    if gold then
        p.bg:SetVertexColor(0.3, 0.22, 0.04, 0.42)
    else
        local c = PVPHUB.currentColors
        local base = (c and c.WINDOW_BG) or { 0.08, 0.05, 0.05 }
        p.bg:SetVertexColor(base[1] * 1.6, base[2] * 1.6, base[3] * 1.6, 0.55)
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

local function CreateHeader(content)
    w.title = NewText(content, 17)
    w.title:SetPoint("TOPLEFT", 0, 0)
    w.title:SetTextColor(1, 0.82, 0, 1)
    w.sub = Muted(NewText(content, 11))
    w.sub:SetPoint("TOPLEFT", w.title, "BOTTOMLEFT", 0, -5)

    -- Where the numbers come from, behind a small "i"
    w.info = CreateFrame("Button", nil, content)
    w.info:SetSize(14, 14)
    w.info:SetPoint("LEFT", w.sub, "RIGHT", 6, 0)
    local icon = w.info:CreateTexture(nil, "ARTWORK")
    icon:SetAllPoints()
    icon:SetTexture("Interface\\common\\help-i")
    TooltipFor(w.info, function()
        GameTooltip:SetText("Where these numbers come from", 1, 0.82, 0)
        GameTooltip:AddLine("Games, win rates and best ratings come from the game and cover the whole season, as of each character's last login.", 1, 1, 1, true)
        GameTooltip:AddLine("Most played spec counts the matches PVPHUB recorded, so only those since it was installed.", 0.7, 0.7, 0.7, true)
    end)

    w.seasonBtn = CreateFrame("Button", nil, content, "UIPanelButtonTemplate")
    w.seasonBtn:SetSize(170, 22)
    w.seasonBtn:SetPoint("TOPRIGHT", content, "TOPRIGHT", 0, -4)
    w.seasonBtn:SetScript("OnClick", function(self) Tab.OpenSeasonMenu(self) end)
    if PVPHUB.UI then PVPHUB.UI.SkinButton(w.seasonBtn) end
end

local function CreateKPIs(content)
    w.kpi = NewPanel(content)
    w.kpi:SetHeight(KPI_H)
    w.kpiCells, w.kpiSeps = {}, {}
    for i = 1, KPI_COUNT do
        local cell = CreateFrame("Frame", nil, w.kpi)
        cell:SetHeight(KPI_H)
        cell.label = Muted(NewText(cell, 11))
        cell.label:SetPoint("TOPLEFT", PAD, -10)
        cell.value = NewText(cell, 20)
        cell.value:SetPoint("TOPLEFT", PAD, -25)
        cell.sub = Muted(NewText(cell, 11))
        cell.sub:SetPoint("TOPLEFT", PAD, -51)
        w.kpiCells[i] = cell
        if i > 1 then
            local sep = w.kpi:CreateTexture(nil, "ARTWORK")
            sep:SetTexture("Interface\\Buttons\\WHITE8x8")
            sep:SetVertexColor(1, 1, 1, 0.07)
            sep:SetWidth(1)
            w.kpiSeps[i] = sep
        end
    end
    -- Win rate gets a bar between its value and its W-L line
    w.winBar = NewBar(w.kpiCells[2], 4)
    w.winBar:SetPoint("TOPLEFT", PAD, -49)
    w.kpiCells[2].sub:ClearAllPoints()
    w.kpiCells[2].sub:SetPoint("TOPLEFT", PAD, -56)

    -- MVP: hover for the five most played characters
    local mvp = w.kpiCells[KPI_COUNT]
    mvp:EnableMouse(true)
    TooltipFor(mvp, function(self)
        GameTooltip:SetText("Most played this season", 1, 0.82, 0)
        for i = 1, math.min(5, #(self.players or {})) do
            local pl = self.players[i]
            GameTooltip:AddDoubleLine(string.format("%d.  %s", i, CharName(pl.key, true)),
                string.format("%s games  ·  %s", Count(pl.played), WinText(pl.won / pl.played)),
                1, 1, 1, 0.85, 0.85, 0.85)
        end
    end)
end

local function CreateBrackets(content)
    local p = NewPanel(content)
    w.brackets = p
    p.heading = NewText(p, 12)
    p.heading:SetPoint("TOPLEFT", PAD, -10)
    p.heading:SetTextColor(1, 0.82, 0, 1)
    p.heading:SetText("Brackets")

    p.cols = {}
    for _, key in ipairs({ "bracket", "games", "wl", "win", "best" }) do
        p.cols[key] = Muted(NewText(p, 11))
    end
    p.cols.bracket:SetText("Bracket")
    p.cols.games:SetText("Games")
    p.cols.wl:SetText("W – L")
    p.cols.win:SetText("Win rate")
    p.cols.best:SetText("Best")
    p.cols.games:SetJustifyH("RIGHT")
    p.cols.wl:SetJustifyH("RIGHT")
    p.cols.best:SetJustifyH("RIGHT")

    p.line = p:CreateTexture(nil, "ARTWORK")
    p.line:SetTexture("Interface\\Buttons\\WHITE8x8")
    p.line:SetVertexColor(1, 1, 1, 0.07)
    p.line:SetHeight(1)

    p.rows = {}
    for i = 1, #PVPHUB._BRACKET_META do
        local row = CreateFrame("Button", nil, p)
        row:SetHeight(ROW_H)
        local hl = row:CreateTexture(nil, "HIGHLIGHT")
        hl:SetAllPoints()
        hl:SetTexture("Interface\\Buttons\\WHITE8x8")
        hl:SetVertexColor(1, 1, 1, 0.05)
        row.icon = row:CreateTexture(nil, "ARTWORK")
        row.icon:SetSize(14, 14)
        row.icon:SetPoint("LEFT", 2, 0)
        row.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        row.label = NewText(row, 12)
        row.label:SetPoint("LEFT", row.icon, "RIGHT", 6, 0)
        row.games = NewText(row, 12)
        row.games:SetJustifyH("RIGHT")
        row.wl = NewText(row, 12)
        row.wl:SetJustifyH("RIGHT")
        row.bar = NewBar(row, 4)
        row.pct = NewText(row, 11)
        row.best = NewText(row, 12)
        row.best:SetJustifyH("RIGHT")
        TooltipFor(row, function(self)
            local bt = self.data
            GameTooltip:SetText(bt.meta.label, 1, 0.82, 0)
            GameTooltip:AddLine("Games per character this season", 0.7, 0.7, 0.7)
            table.sort(bt.chars, function(a, b) return a.s.played > b.s.played end)
            for _, c in ipairs(bt.chars) do
                GameTooltip:AddDoubleLine(CharName(c.key, true),
                    string.format("%d games  ·  %s  ·  best %s", c.s.played, WinText(c.s.won / c.s.played), Rating(c.s.best)),
                    1, 1, 1, 0.85, 0.85, 0.85)
            end
        end)
        p.rows[i] = row
    end

    p.hint = Muted(NewText(p, 11))
    p.hint:SetText("Hover a bracket for each character's games")
    p.empty = Muted(NewText(p, 12))
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
        row.name = NewText(row, 12)
        row.name:SetPoint("TOPLEFT", 0, 0)
        row.name:SetText(meta.name)
        row.value = NewText(row, 12)
        row.value:SetPoint("TOPRIGHT", 0, 0)
        row.value:SetJustifyH("RIGHT")
        row.bar = NewBar(row, 6)
        row.bar:SetPoint("TOPLEFT", 0, -18)
        row.who = NewText(row, 11)
        row.who:SetPoint("TOPLEFT", 0, -29)

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

local function ClassName(token)
    return (LOCALIZED_CLASS_NAMES_MALE and LOCALIZED_CLASS_NAMES_MALE[token]) or token
end

local function ClassIcon(tex, token)
    local path = PVPHUB._CLASS_ICON_PATHS and PVPHUB._CLASS_ICON_PATHS[token]
    tex:SetTexture(path)
    tex:SetTexCoord(0.08, 0.92, 0.08, 0.92)
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
    TooltipFor(r, function(self)
        local pl = self.player
        GameTooltip:SetText(CharName(pl.key, true))
        GameTooltip:AddDoubleLine("Games", Count(pl.played) .. "  ·  " .. WinText(pl.won / math.max(1, pl.played)), 0.7, 0.7, 0.7, 1, 1, 1)
        if pl.main then GameTooltip:AddDoubleLine("Plays most", BracketLabel(pl.main), 0.7, 0.7, 0.7, 1, 1, 1) end
        if pl.bestMeta then
            GameTooltip:AddDoubleLine("Best rating", Rating(pl.best) .. "  |cff8f8c99" .. BracketLabel(pl.bestMeta) .. "|r", 0.7, 0.7, 0.7, 1, 1, 1)
        end
    end)
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

-- --------------------------------------------------------------------------
-- Painting
-- --------------------------------------------------------------------------

-- "Midnight Season 2"; an archived season with the expansion it was played in
local function SeasonLabel(season, archived)
    if archived and PVPHUB.Seasons then return PVPHUB.Seasons.Name(season) end
    return (PVPHUB._GetSeasonDisplayName and PVPHUB._GetSeasonDisplayName(season)) or "This season"
end

local function PaintHeader(d, season, archived, width)
    w.title:SetText(SeasonLabel(season, archived) .. (archived and "  |cff888888(archive)|r" or ""))
    local n = d.chars
    w.sub:SetText(string.format("%d character%s with rated games%s", n, n == 1 and "" or "s",
        archived and " that season" or " this season"))

    local past = PVPHUB.Seasons and PVPHUB.Seasons.Summary() or {}
    local hasPast = false
    for _, s in ipairs(past) do
        if s.season ~= CurrentSeason() then hasPast = true end
    end
    w.seasonBtn:SetText(archived and SeasonLabel(season, true) or "Current season")
    w.seasonBtn:SetShown(hasPast or archived)
    w.title:SetWidth(math.max(100, width - (w.seasonBtn:IsShown() and 190 or 0)))
end

local function PaintKPIs(d, top, width)
    local p = w.kpi
    PaintPanel(p)
    p:ClearAllPoints()
    p:SetPoint("TOPLEFT", Tab.content, "TOPLEFT", 0, -top)
    p:SetWidth(width)
    local cellW = width / KPI_COUNT
    for i, cell in ipairs(w.kpiCells) do
        cell:ClearAllPoints()
        cell:SetPoint("TOPLEFT", p, "TOPLEFT", (i - 1) * cellW, 0)
        cell:SetWidth(cellW)
        if w.kpiSeps[i] then
            w.kpiSeps[i]:ClearAllPoints()
            w.kpiSeps[i]:SetPoint("TOPLEFT", p, "TOPLEFT", (i - 1) * cellW, -10)
            w.kpiSeps[i]:SetPoint("BOTTOMLEFT", p, "BOTTOMLEFT", (i - 1) * cellW, 10)
        end
    end

    local c = w.kpiCells
    c[1].label:SetText("Games")
    c[1].value:SetText("|cffffffff" .. Count(d.played) .. "|r")
    c[1].sub:SetText("all brackets")

    local pct = d.played > 0 and d.won / d.played or 0
    local r, g, b = WinColor(pct)
    c[2].label:SetText("Win rate")
    c[2].value:SetText(d.played > 0 and math.floor(pct * 100 + 0.5) .. "%" or "—")
    c[2].value:SetTextColor(r, g, b, 1)
    PaintBar(w.winBar, cellW - PAD * 2, pct, r, g, b)
    w.winBar:SetShown(d.played > 0)
    c[2].sub:SetText(d.played > 0 and string.format("|cff5fd17a%s|r – |cffff6b6b%s|r", Count(d.won), Count(d.lost)) or "")

    c[3].label:SetText("Best rating")
    if d.best then
        c[3].value:SetText(Rating(d.best.rating))
        c[3].sub:SetText(CharName(d.best.char) .. "  |cff8f8c99· " .. BracketLabel(d.best.meta) .. "|r")
    else
        c[3].value:SetText("|cff555555—|r")
        c[3].sub:SetText("")
    end
    c[3].sub:SetWidth(cellW - PAD * 2)

    c[4].label:SetText("Characters")
    c[4].value:SetText("|cffffffff" .. d.chars .. "|r")
    c[4].sub:SetText("with rated games")

    -- MVP: the most played character, with its games and main bracket
    local mvp = d.players[1]
    c[5].label:SetText("MVP")
    c[5].players = d.players
    if mvp then
        c[5].value:SetText(CharName(mvp.key))
        c[5].sub:SetText(string.format("%s games  |cff8f8c99· %s|r", Count(mvp.played), BracketLabel(mvp.main)))
    else
        c[5].value:SetText("|cff555555—|r")
        c[5].sub:SetText("")
    end
    c[5].value:SetWidth(cellW - PAD * 2)
    c[5].sub:SetWidth(cellW - PAD * 2)
    return top + KPI_H
end

-- Returns the panel's height
local function PaintBrackets(d, archived, top, x, width)
    local p = w.brackets
    PaintPanel(p)
    p:ClearAllPoints()
    p:SetPoint("TOPLEFT", Tab.content, "TOPLEFT", x, -top)
    p:SetWidth(width)

    local list = {}
    for _, bt in pairs(d.brackets) do list[#list + 1] = bt end
    table.sort(list, function(a, b) return a.played > b.played end)

    local iw = width - PAD * 2
    local col = {
        games = iw * 0.46, wl = iw * 0.63,     -- right edges
        bar = iw * 0.67, barW = iw * 0.13,     -- left edge, width
        best = iw,                             -- right edge
    }

    local y = 32
    p.cols.bracket:SetPoint("TOPLEFT", PAD + 2, -y)
    p.cols.games:SetPoint("TOPRIGHT", p, "TOPLEFT", PAD + col.games, -y)
    p.cols.wl:SetPoint("TOPRIGHT", p, "TOPLEFT", PAD + col.wl, -y)
    p.cols.win:SetPoint("TOPLEFT", PAD + col.bar, -y)
    p.cols.best:SetPoint("TOPRIGHT", p, "TOPLEFT", PAD + col.best, -y)
    for _, fs in pairs(p.cols) do fs:SetShown(#list > 0) end
    y = y + 18
    p.line:ClearAllPoints()
    p.line:SetPoint("TOPLEFT", PAD, -y)
    p.line:SetPoint("TOPRIGHT", -PAD, -y)
    p.line:SetShown(#list > 0)
    y = y + 2

    for i, row in ipairs(p.rows) do
        local bt = list[i]
        row:SetShown(bt ~= nil)
        if bt then
            row.data = bt
            row:ClearAllPoints()
            row:SetPoint("TOPLEFT", PAD, -y)
            row:SetWidth(iw)
            row.icon:SetTexture(bt.meta.icon)
            row.label:SetText(BracketLabel(bt.meta))
            row.games:ClearAllPoints()
            row.games:SetPoint("RIGHT", row, "LEFT", col.games, 0)
            row.games:SetText("|cffffffff" .. Count(bt.played) .. "|r")
            row.wl:ClearAllPoints()
            row.wl:SetPoint("RIGHT", row, "LEFT", col.wl, 0)
            row.wl:SetText(string.format("|cff5fd17a%s|r–|cffff6b6b%s|r", Count(bt.won), Count(bt.lost)))
            local pct = bt.played > 0 and bt.won / bt.played or 0
            local r, g, b = WinColor(pct)
            row.bar:ClearAllPoints()
            row.bar:SetPoint("LEFT", row, "LEFT", col.bar, 0)
            PaintBar(row.bar, col.barW, pct, r, g, b)
            row.pct:ClearAllPoints()
            row.pct:SetPoint("LEFT", row.bar, "RIGHT", 6, 0)
            row.pct:SetText(WinText(pct))
            row.best:ClearAllPoints()
            row.best:SetPoint("RIGHT", row, "LEFT", col.best, 0)
            row.best:SetText(Rating(bt.best))
            y = y + ROW_H
        end
    end

    p.empty:SetShown(#list == 0)
    p.hint:SetShown(#list > 0)
    if #list == 0 then
        p.empty:ClearAllPoints()
        p.empty:SetPoint("TOPLEFT", PAD, -36)
        p.empty:SetText(archived and "No rated games archived for this season."
            or "No rated games recorded this season yet.")
        y = 60
    else
        y = y + 6
        p.hint:ClearAllPoints()
        p.hint:SetPoint("TOPLEFT", PAD, -y)
        y = y + 18
    end
    return y
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
        row.who:SetWidth(iw)

        if t.earned then
            row.value:SetText("|cffffd100Earned|r")
            PaintBar(row.bar, iw, 1, 1, 0.82, 0)
            local when = EarnedDate(t.tp)
            row.who:SetText(CharName(t.char) .. (when and ("  |cff8f8c99· " .. when .. "|r") or ""))
        else
            local required = t.required > 0 and t.required or nil
            local pct = required and math.min(1, t.current / required) or 0
            row.value:SetText(required and string.format("|cffffffff%d / %d|r", math.min(t.current, required), required) or "|cff555555—|r")
            PaintBar(row.bar, iw, pct, ProgressColor(pct))
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

    PaintHeader(d, season, archived, width)
    local y = PaintKPIs(d, HEADER_H, width) + GAP

    local h
    if width >= TWO_COLUMN_MIN then
        local leftW = math.floor((width - GAP) * 0.62)
        local rightW = width - GAP - leftW
        local hb = PaintBrackets(d, archived, y, 0, leftW)
        local ht = PaintTitles(d, archived, y, leftW + GAP, rightW)
        h = math.max(hb, ht)
        w.brackets:SetHeight(h)
        w.titles:SetHeight(h)
        y = y + h + GAP
    else
        h = PaintBrackets(d, archived, y, 0, width)
        w.brackets:SetHeight(h)
        y = y + h + GAP
        h = PaintTitles(d, archived, y, 0, width)
        w.titles:SetHeight(h)
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
    CreateHeader(content)
    CreateKPIs(content)
    CreateBrackets(content)
    CreateTitles(content)
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
