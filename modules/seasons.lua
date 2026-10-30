-- PVPHUB season archive (7.0)
--
-- Keeps every season's results per character for good: ratings, season
-- best and win/loss per bracket (and spec), season title progress and the
-- whole match history. The live data in PVPHUB_DB only holds the current
-- season: a character's first login in a new season overwrites its
-- ratings, and its first match there trims last season's match history.
-- Everything is copied in here before that happens, and kept up to date
-- while a season runs, so the final state is already saved when it ends.
--
-- Rules (learned from the v6.6.0-6.6.2 season wipe, see CHANGELOG v6.6.3):
--   * The archive only ever copies. Nothing here deletes or changes live data.
--   * Data is filed under the season it is tagged with (bracketStats.season,
--     match.season, seasonTag), never under "now". A new season's games
--     can't end up in an old season, and a wrongly detected season change
--     can't do any harm.
--   * An archived value is only replaced by one with at least as many games
--     (a title by at least as much progress); match history is merged.
--   * Season numbers <= 0 (the game hasn't sent them yet) are ignored.
--
-- Stored in PVPHUB_DB_ARCHIVE.seasons. That saved variable exists in 6.x as
-- well, and 6.x only touches its numbered backup entries, so the archive
-- survives starting a 6.x build; Reset All Data doesn't touch it either.
--
--   PVPHUB_DB_ARCHIVE.seasons[season] = {
--       expansion = GetExpansionLevel() when the season was first archived,
--       chars = { [charKey] = {
--           class,
--           brackets = { [bracketKey] = stats }   (Shuffle/Blitz: [bracketKey][specID] = stats),
--           titles   = { [titleKey] = progress },
--           history  = { [bracketKey] = { match, ... } },   oldest first
--       } },
--   }

local _, PVPHUB = ...

local Seasons = {}
PVPHUB.Seasons = Seasons

local PER_SPEC = { ratingShuffle = true, ratingBlitz = true }

local function CurrentSeason()
    local season = (C_PvP and C_PvP.GetUIDisplaySeason and C_PvP.GetUIDisplaySeason()) or 0
    if season <= 0 then
        season = (PVPHUB_SETTINGS and PVPHUB_SETTINGS.lastKnownSeasonID) or 0
    end
    return season
end
Seasons.CurrentSeason = CurrentSeason

local function Copy(value)
    if type(value) ~= "table" then return value end
    local t = {}
    for k, v in pairs(value) do t[k] = Copy(v) end
    return t
end

local function Store()
    if type(PVPHUB_DB_ARCHIVE) ~= "table" then PVPHUB_DB_ARCHIVE = {} end
    if type(PVPHUB_DB_ARCHIVE.seasons) ~= "table" then PVPHUB_DB_ARCHIVE.seasons = {} end
    return PVPHUB_DB_ARCHIVE.seasons
end

-- The current expansion. Season numbers count per expansion, so each
-- archived season remembers its expansion for its name.
local function ExpansionLevel()
    return (GetServerExpansionLevel and GetServerExpansionLevel())
        or (GetExpansionLevel and GetExpansionLevel()) or nil
end

-- An archived season's name, e.g. "Midnight Season 1"
function Seasons.Name(season)
    local s = Store()[season]
    local name = PVPHUB._GetSeasonDisplayName and PVPHUB._GetSeasonDisplayName(season, s and s.expansion)
    return name or ("Season " .. season)
end

-- The archive entry of one character in one season, created on first use
local function Entry(season, charKey, data)
    local store = Store()
    local s = store[season]
    if not s then
        s = { expansion = ExpansionLevel(), chars = {} }
        store[season] = s
    end
    local c = s.chars[charKey]
    if not c then
        c = { brackets = {}, titles = {}, history = {} }
        s.chars[charKey] = c
    end
    c.class = c.class or data.class
    return c
end

local function HasGames(stats)
    return type(stats) == "table" and ((stats.rating or 0) > 0 or (stats.played or 0) > 0)
end

-- Puts stats into slot[key] unless what's there has more games. The season
-- best is the higher of both.
local function MergeStats(slot, key, stats)
    local old = slot[key]
    if type(old) == "table" and (stats.played or 0) < (old.played or 0) then return end
    local best = math.max(stats.seasonBest or 0, type(old) == "table" and old.seasonBest or 0)
    slot[key] = Copy(stats)
    slot[key].seasonBest = best
end

-- Title progress has no season of its own. It belongs to the season the
-- character's stats were stamped with (seasonTag) in the same session.
-- For the character being played, title progress and tag are re-read at
-- different moments of a session, so two things are remembered per session:
local sessionTag = {}   -- [charKey] = its seasonTag before this session stamped one
local refreshed  = {}   -- [charKey] = true once its titles were re-read this session

local function SessionTag(charKey, data)
    if sessionTag[charKey] == nil then sessionTag[charKey] = data.seasonTag or 0 end
    return sessionTag[charKey]
end

-- Files title progress under season tag. A title is only replaced by more
-- progress, and an earned one stays earned.
local function SaveTitles(charKey, data, tag)
    if (tag or 0) <= 0 or type(data.titleProgress) ~= "table" then return end
    local titles = Entry(tag, charKey, data).titles
    for key, tp in pairs(data.titleProgress) do
        if type(tp) == "table" then
            local old = titles[key]
            if not old or tp.completed
               or (not old.completed and (tp.current or 0) >= (old.current or 0)) then
                titles[key] = Copy(tp)
            end
        end
    end
end

-- Called right before the played character's title progress is re-read.
-- The first time in a session, what's stored is still from its last
-- session: archive it under the tag that session had.
function Seasons.BeforeTitleRefresh(charKey)
    if refreshed[charKey] then return end
    local data = PVPHUB_DB and PVPHUB_DB[charKey]
    if type(data) == "table" then SaveTitles(charKey, data, SessionTag(charKey, data)) end
    refreshed[charKey] = true
end

-- Ratings and win/loss of every bracket (and spec), each filed under its own
-- season tag. withTitles = false skips title progress (see below).
function Seasons.SaveStats(charKey, withTitles)
    local data = PVPHUB_DB and PVPHUB_DB[charKey]
    if type(data) ~= "table" then return end
    SessionTag(charKey, data)   -- before anything this session stamps a new one

    if type(data.bracketStats) == "table" then
        for bracketKey, b in pairs(data.bracketStats) do
            if type(b) == "table" then
                if PER_SPEC[bracketKey] then
                    for specID, s in pairs(b) do
                        if type(specID) == "number" and HasGames(s) and (s.season or 0) > 0 then
                            local c = Entry(s.season, charKey, data)
                            c.brackets[bracketKey] = c.brackets[bracketKey] or {}
                            MergeStats(c.brackets[bracketKey], specID, s)
                        end
                    end
                elseif HasGames(b) and (b.season or 0) > 0 then
                    MergeStats(Entry(b.season, charKey, data).brackets, bracketKey, b)
                end
            end
        end
    end

    -- Titles (see SessionTag above). Another character's progress and tag
    -- are both from its last session. The played character's only belong
    -- together once this session has re-read its titles and stamped the
    -- current season; before that, BeforeTitleRefresh files them.
    if withTitles == false then return end
    local me = PVPHUB._GetFullName and PVPHUB._GetFullName()
    if charKey == me and (not refreshed[charKey] or (data.seasonTag or 0) ~= CurrentSeason()) then
        return
    end
    SaveTitles(charKey, data, data.seasonTag)
end

local function MatchKey(m)
    return (m.timestamp or 0) .. ":" .. (m.specID or 0) .. ":" .. (m.rating or 0)
end

-- Adds live matches to an archived list. A match already there is replaced
-- by the live copy, which may have gained fields since (rounds won/lost).
local function MergeMatches(archived, matches)
    local index = {}
    for i, m in ipairs(archived) do index[MatchKey(m)] = i end
    local added = false
    for _, m in ipairs(matches) do
        local key = MatchKey(m)
        if index[key] then
            archived[index[key]] = Copy(m)
        else
            archived[#archived + 1] = Copy(m)
            index[key] = #archived
            added = true
        end
    end
    if added then
        table.sort(archived, function(a, b) return (a.timestamp or 0) < (b.timestamp or 0) end)
    end
end

-- The match history of every bracket, each match filed under its own season.
-- Matches without a season number can't be placed and are left out.
function Seasons.SaveHistory(charKey)
    local data = PVPHUB_DB and PVPHUB_DB[charKey]
    if type(data) ~= "table" or type(data.mmrHistory) ~= "table" then return end
    for bracketKey, list in pairs(data.mmrHistory) do
        if type(list) == "table" then
            local bySeason = {}
            for _, m in ipairs(list) do
                if type(m) == "table" and (m.season or 0) > 0 then
                    bySeason[m.season] = bySeason[m.season] or {}
                    table.insert(bySeason[m.season], m)
                end
            end
            for season, matches in pairs(bySeason) do
                local c = Entry(season, charKey, data)
                c.history[bracketKey] = c.history[bracketKey] or {}
                MergeMatches(c.history[bracketKey], matches)
            end
        end
    end
end

function Seasons.ArchiveCharacter(charKey)
    Seasons.SaveStats(charKey)
    Seasons.SaveHistory(charKey)
end

-- Every stored character. Returns how many characters have archived data.
function Seasons.ArchiveAll()
    if type(PVPHUB_DB) ~= "table" then return 0 end
    for charKey, data in pairs(PVPHUB_DB) do
        if type(data) == "table" and charKey ~= "settings" then
            Seasons.ArchiveCharacter(charKey)
        end
    end
    local chars = {}
    for _, s in pairs(Store()) do
        for charKey in pairs(s.chars or {}) do chars[charKey] = true end
    end
    local n = 0
    for _ in pairs(chars) do n = n + 1 end
    return n
end

-- Archived seasons as { season, chars }, newest first (for the settings)
function Seasons.Summary()
    local list = {}
    for season, s in pairs(Store()) do
        local n = 0
        for _ in pairs(s.chars or {}) do n = n + 1 end
        list[#list + 1] = { season = season, chars = n }
    end
    table.sort(list, function(a, b) return a.season > b.season end)
    return list
end

-- Moves a character's archived seasons to another key (a server transfer
-- merged in Manage Characters, modules/characters.lua). Where both have a
-- season, match history is merged and the stats with more games win.
function Seasons.MergeCharacter(fromKey, toKey)
    for _, s in pairs(Store()) do
        local chars = s.chars or {}
        local from, to = chars[fromKey], chars[toKey]
        if from and not to then
            chars[toKey] = from
        elseif from and to then
            for bracketKey, b in pairs(from.brackets or {}) do
                if PER_SPEC[bracketKey] then
                    to.brackets[bracketKey] = to.brackets[bracketKey] or {}
                    for specID, st in pairs(b) do MergeStats(to.brackets[bracketKey], specID, st) end
                else
                    MergeStats(to.brackets, bracketKey, b)
                end
            end
            for key, tp in pairs(from.titles or {}) do
                local old = to.titles[key]
                if not old or tp.completed or (not old.completed and (tp.current or 0) >= (old.current or 0)) then
                    to.titles[key] = Copy(tp)
                end
            end
            for bracketKey, matches in pairs(from.history or {}) do
                to.history[bracketKey] = to.history[bracketKey] or {}
                MergeMatches(to.history[bracketKey], matches)
            end
        end
        chars[fromKey] = nil
    end
end

-- The characters archived for a season
function Seasons.Characters(season)
    local list = {}
    local s = Store()[season]
    for charKey in pairs(s and s.chars or {}) do list[#list + 1] = charKey end
    table.sort(list)
    return list
end

-- When a character last played in an archived season: its newest match,
-- else the newest stats update
local function LastPlayed(c)
    local last = 0
    for _, matches in pairs(c.history or {}) do
        local m = matches[#matches]
        if m and (m.timestamp or 0) > last then last = m.timestamp end
    end
    if last > 0 then return last end
    for _, b in pairs(c.brackets or {}) do
        if type(b) == "table" then
            if b.lastUpdated then
                last = math.max(last, b.lastUpdated)
            else
                for _, s in pairs(b) do
                    if type(s) == "table" then last = math.max(last, s.lastUpdated or 0) end
                end
            end
        end
    end
    return last
end

-- A character's past seasons (not the current one) as
-- { season = id, lastPlayed = time }, newest first
function Seasons.List(charKey)
    local list, current = {}, CurrentSeason()
    for season, s in pairs(Store()) do
        local c = s.chars and s.chars[charKey]
        if c and season ~= current then
            list[#list + 1] = { season = season, lastPlayed = LastPlayed(c) }
        end
    end
    table.sort(list, function(a, b) return a.season > b.season end)
    return list
end

-- A character's data as it was in an archived season, shaped like its live
-- data: archived ratings, titles and match history; everything that isn't
-- per season (class, race, gear, note, ...) from the live data.
function Seasons.View(charKey, season)
    local s = Store()[season]
    local c = s and s.chars and s.chars[charKey]
    local live = PVPHUB_DB and PVPHUB_DB[charKey]
    if not c or type(live) ~= "table" then return nil end
    return setmetatable({
        bracketStats  = c.brackets,
        mmrHistory    = c.history,
        titleProgress = c.titles,
        lastKnownMMR  = false,   -- the live one is this season's
    }, { __index = live })
end

-- Rescue what's still stored at login (a character not played since a
-- season ended still holds that season until its next login) and save the
-- played character's latest state at logout.
local events = CreateFrame("Frame")
events:RegisterEvent("PLAYER_LOGIN")
events:RegisterEvent("PLAYER_LOGOUT")
events:SetScript("OnEvent", function(_, event)
    if event == "PLAYER_LOGIN" then
        C_Timer.After(10, function() Seasons.ArchiveAll() end)
    else
        local me = PVPHUB._GetFullName and PVPHUB._GetFullName()
        if me then Seasons.ArchiveCharacter(me) end
    end
end)
