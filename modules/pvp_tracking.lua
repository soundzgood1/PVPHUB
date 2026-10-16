-- PVPHUB PvP Tracking Module
-- Dedicated frame for persisting PvP ratings and bracket statistics.
-- Stores comprehensive per-bracket data (rating, wins, losses, season stats)
-- into PVPHUB_DB and captures a pre-match snapshot for delta tracking.
--
-- DB layout this module writes:
--   PVPHUB_DB[charKey].bracketStats[bracketKey]  -- rich stat snapshot (new)
--   PVPHUB_DB[charKey][bracketKey]               -- legacy flat/per-spec keys (UI reads these)
--   PVPHUB_DB[charKey].preMatchSnap              -- pre-match baseline for delta display

local _, PVPHUB = ...

PVPHUB.PvPTracking = {}

-- --------------------------------------------------------------------------
-- Constants
-- --------------------------------------------------------------------------

-- playedIdx / wonIdx are the select() positions from GetPersonalRatedInfo().
-- They differ per bracket (Solo Shuffle returns counts at higher indices).
local BRACKETS = {
    { id = 1, key = "rating2v2",     playedIdx = 4,  wonIdx = 5  },
    { id = 2, key = "rating3v3",     playedIdx = 4,  wonIdx = 5  },
    { id = 4, key = "ratingRBG",     playedIdx = 4,  wonIdx = 5  },
    { id = 7, key = "ratingShuffle", playedIdx = 12, wonIdx = 13 },
    { id = 9, key = "ratingBlitz",   playedIdx = 4,  wonIdx = 5  },
}

-- --------------------------------------------------------------------------
-- Helpers
-- --------------------------------------------------------------------------

local function N(v)
    return tonumber(v) or 0
end

local function GetCurrentCharKey()
    local name, realm = UnitName("player")
    realm = realm or GetRealmName()
    if not name or name == "" then return nil end
    if not realm or realm == "" then realm = "Unknown" end
    return name .. "-" .. realm
end

-- Deprecated-API safe (see modules/compat.lua).
local GetCurrentSpecID = PVPHUB.Compat.GetCurrentSpecID

-- --------------------------------------------------------------------------
-- Recent rating changes
-- --------------------------------------------------------------------------
-- After a match the windows show the change next to the new rating ("+18")
-- for a few minutes, and the cell blinks when it first appears. Kept for the
-- session only. Recorded here because SaveBracketStats is the first code to
-- write a new rating; anything that writes later sees no difference.

local RATING_CHANGE_SECONDS = 180  -- how long "+18" stays next to the rating
local RATING_FLASH_SECONDS  = 2.5  -- a change this fresh makes the cell blink

PVPHUB._ratingChanges = PVPHUB._ratingChanges or {}

local function RatingChangeKey(bracketKey, specID)
    return bracketKey .. ":" .. tostring(specID or 0)
end

-- Records oldRating -> newRating for a character's bracket (and spec, for
-- Shuffle/Blitz). Nothing is recorded without a real previous rating, so a
-- first rating or a freshly picked spec doesn't show up as "+1800".
function PVPHUB.NoteRatingChange(charKey, bracketKey, specID, oldRating, newRating)
    oldRating, newRating = tonumber(oldRating), tonumber(newRating)
    if not charKey or not oldRating or not newRating then return end
    if oldRating <= 0 or newRating == oldRating then return end

    local byChar = PVPHUB._ratingChanges[charKey] or {}
    PVPHUB._ratingChanges[charKey] = byChar
    local key = RatingChangeKey(bracketKey, specID)
    local now = GetTime()
    local delta = newRating - oldRating
    -- Several updates within the window (e.g. back-to-back games) add up.
    local previous = byChar[key]
    if previous and now - previous.at <= RATING_CHANGE_SECONDS then
        delta = delta + previous.delta
    end
    byChar[key] = { delta = delta, at = now }

    -- The data doesn't change again when the badge expires, so the
    -- windows' "unchanged, skip the rebuild" check has to be bypassed.
    C_Timer.After(RATING_CHANGE_SECONDS + 0.5, function()
        PVPHUB._mainRenderSig, PVPHUB._compactRenderSig = nil, nil
        if PVPHUB.RefreshUI then PVPHUB.RefreshUI() end
    end)
end

-- Returns delta, secondsAgo, recordedAt for a change still worth showing,
-- or nil. specID is the spec whose rating the caller displays (nil for
-- 2v2/3v3/RBG).
function PVPHUB.GetRecentRatingChange(charKey, bracketKey, specID)
    local byChar = PVPHUB._ratingChanges[charKey]
    local change = byChar and byChar[RatingChangeKey(bracketKey, specID)]
    if not change then return nil end
    local age = GetTime() - change.at
    if age > RATING_CHANGE_SECONDS then return nil end
    return change.delta, age, change.at
end

-- " +18" in green / " -12" in red, for appending to a rating.
function PVPHUB.FormatRatingDelta(delta)
    if delta > 0 then
        return string.format(" |cff40ff40+%d|r", delta)
    end
    return string.format(" |cffff5050%d|r", delta)
end

-- True when a change is fresh enough that its cell should blink.
function PVPHUB.IsRatingChangeFresh(age)
    return age ~= nil and age < RATING_FLASH_SECONDS
end

-- Blinks a region three times. The animation is created once per region
-- and reused.
function PVPHUB.FlashRegion(region)
    if not region or not region.CreateAnimationGroup then return end
    local flash = region._pvphubFlash
    if not flash then
        flash = region:CreateAnimationGroup()
        for i = 1, 3 do
            local out = flash:CreateAnimation("Alpha")
            out:SetFromAlpha(1); out:SetToAlpha(0.2)
            out:SetDuration(0.16); out:SetOrder(i * 2 - 1)
            local back = flash:CreateAnimation("Alpha")
            back:SetFromAlpha(0.2); back:SetToAlpha(1)
            back:SetDuration(0.16); back:SetOrder(i * 2)
        end
        region._pvphubFlash = flash
    end
    flash:Stop()
    flash:Play()
end

-- --------------------------------------------------------------------------
-- Data persistence
-- --------------------------------------------------------------------------

-- SaveBracketStats: reads GetPersonalRatedInfo for every rated bracket and
-- writes results to PVPHUB_DB.  Two parallel writes happen on every call:
--   1) .bracketStats[key]  — full snapshot with wins/losses/season context
--   2) [key] (flat or per-spec table) — legacy field the UI already reads
--
-- Follows Blizzard's own ConquestFrame_Update pattern: one GetPersonalRatedInfo
-- call per bracket, all return values unpacked in one shot.
-- Return values (from Blizzard source):
--   rating, seasonBest, weeklyBest, seasonPlayed, seasonWon,
--   weeklyPlayed, weeklyWon, lastWeeksBest, hasWon, pvpTier, ranking,
--   roundsSeasonPlayed, roundsSeasonWon, roundsWeeklyPlayed, roundsWeeklyWon
local function SaveBracketStats(charKey)
    if not PVPHUB_DB or not charKey then return end
    -- Never write until the server has confirmed fresh data for this session.
    -- This blocks: (1) cross-character cache bleed at login, (2) stale data from
    -- timer-based calls that fire before PVP_RATED_STATS_UPDATE, and (3) the
    -- brief window after PVP_MATCH_COMPLETE before the server sends new stats.
    if not PVPHUB._pvpCacheReady then return end

    PVPHUB_DB[charKey]              = PVPHUB_DB[charKey]             or {}
    PVPHUB_DB[charKey].bracketStats = PVPHUB_DB[charKey].bracketStats or {}

    local season = (C_PvP.GetUIDisplaySeason and C_PvP.GetUIDisplaySeason()) or 0
    local specID = GetCurrentSpecID()
    local now    = GetServerTime()

    -- Stamp which season the values written below belong to. The flat legacy
    -- rating fields (rating2v2/ratingShuffle/...) carry no season of their own,
    -- so this tag is what lets the UI tell current data from last season's
    -- without having to delete anything — see IsSeasonDataCurrent in core.lua.
    -- Only stamped once the server has confirmed fresh data for this session
    -- (guaranteed by the _pvpCacheReady check above).
    if season > 0 then
        PVPHUB_DB[charKey].seasonTag = season
    end

    for _, b in ipairs(BRACKETS) do
        -- Single call per bracket, like Blizzard's ConquestFrame_Update
        local ok, rating, seasonBest, weeklyBest, seasonPlayed, seasonWon,
              weeklyPlayed, weeklyWon, lastWeeksBest, hasWon, pvpTier, ranking,
              roundsSeasonPlayed, roundsSeasonWon =
                pcall(GetPersonalRatedInfo, b.id)

        if ok then
            rating           = N(rating)
            local played     = N(b.playedIdx == 12 and roundsSeasonPlayed or seasonPlayed)
            local won        = N(b.wonIdx    == 13 and roundsSeasonWon    or seasonWon)

            -- Rich snapshot: per-spec for Shuffle/Blitz, flat for Arena.
            -- GetPersonalRatedInfo returns the CURRENT spec's rounds for bracket 7/9,
            -- so we key by specID so every spec gets its own accurate seasonal record.
            if (b.key == "ratingShuffle" or b.key == "ratingBlitz") and specID and PVPHUB._pvpCacheReady then
                local bsTable = PVPHUB_DB[charKey].bracketStats[b.key]
                -- Migrate: discard old flat structure (had a direct .rating key at top level)
                if type(bsTable) ~= "table" or bsTable.rating ~= nil then
                    bsTable = {}
                    PVPHUB_DB[charKey].bracketStats[b.key] = bsTable
                end
                bsTable[specID] = {
                    rating      = rating,
                    played      = played,
                    won         = won,
                    lost        = played - won,
                    seasonBest  = N(seasonBest),
                    pvpTier     = pvpTier,
                    season      = season,
                    lastUpdated = now,
                }
            elseif b.key ~= "ratingShuffle" and b.key ~= "ratingBlitz" then
                PVPHUB_DB[charKey].bracketStats[b.key] = {
                    rating      = rating,
                    played      = played,
                    won         = won,
                    lost        = played - won,
                    seasonBest  = N(seasonBest),
                    weeklyBest  = N(weeklyBest),
                    pvpTier     = pvpTier,
                    ranking     = ranking,
                    season      = season,
                    lastUpdated = now,
                }
            end

            -- Sync legacy keys so the existing UI continues to work unchanged.
            if b.key == "ratingShuffle" or b.key == "ratingBlitz" then
                if type(PVPHUB_DB[charKey][b.key]) ~= "table" then
                    PVPHUB_DB[charKey][b.key] = {}
                end
                -- Only write per-spec rating once _pvpCacheReady confirms the server has
                -- pushed fresh data for THIS character session.  This blocks both:
                --   1) spec-change stale cache (first PVP_RATED_STATS_UPDATE may carry old data)
                --   2) cross-character stale cache (previous character's data persists across
                --      the login screen until the server sends a new PVP_RATED_STATS_UPDATE)
                if specID and PVPHUB._pvpCacheReady then
                    PVPHUB.NoteRatingChange(charKey, b.key, specID, PVPHUB_DB[charKey][b.key][specID], rating)
                    PVPHUB_DB[charKey][b.key][specID] = rating
                end
            else
                -- Guard 2v2/3v3 writes the same way: only write after server confirms
                -- fresh data for this session (prevents cross-character cache bleed).
                if PVPHUB._pvpCacheReady then
                    PVPHUB.NoteRatingChange(charKey, b.key, nil, PVPHUB_DB[charKey][b.key], rating)
                    PVPHUB_DB[charKey][b.key] = rating
                end
            end
        end
    end
end

-- CapturePreMatchSnapshot: snapshot current ratings before a match starts so
-- we can compute an accurate before/after delta when the match ends.
local function CapturePreMatchSnapshot(charKey)
    if not PVPHUB_DB or not charKey then return end

    PVPHUB_DB[charKey] = PVPHUB_DB[charKey] or {}
    local snap = { timestamp = GetServerTime() }

    for _, b in ipairs(BRACKETS) do
        local ok, rating = pcall(GetPersonalRatedInfo, b.id)
        snap[b.key] = (ok and N(rating)) or 0
    end

    PVPHUB_DB[charKey].preMatchSnap = snap
end

-- --------------------------------------------------------------------------
-- Season title achievements (Legend / Strategist / Gladiator)
-- --------------------------------------------------------------------------
-- These are ordinary quantity achievements (e.g. "0/100 Rated Solo Shuffle
-- rounds won while at Elite rank") — Blizzard's server computes the count and
-- the Elite-rank gating itself, so we just read GetAchievementCriteriaInfo.
-- IDs are season-specific and must be updated at the start of each new season.
-- Verified against BetterBlizzFrames' live GladWinTracker implementation
-- (Wowhead's IDs for these lag behind a pre-launch renumbering and are wrong).
local TITLE_ACHIEVEMENTS = {
    legend     = { id = 62932, bracketKey = "ratingShuffle" }, -- Rated Solo Shuffle rounds won at Elite rank
    strategist = { id = 62950, bracketKey = "ratingBlitz"   }, -- Rated Battleground Blitz matches won at Elite rank
    gladiator  = { id = 62930, bracketKey = "rating3v3"     }, -- 3v3 games won at Elite rank
}

-- Scans all criteria for the achievement rather than assuming index 1, since
-- some achievements carry more than one criterion or none at all.
local function GetAchievementProgress(achievementID)
    local ok, num = pcall(GetAchievementNumCriteria, achievementID)
    if not ok or not num then return 0, 0 end
    for i = 1, num do
        local ok2, _, _, _, quantity, reqQuantity = pcall(GetAchievementCriteriaInfo, achievementID, i)
        if ok2 and reqQuantity and reqQuantity > 0 then
            return tonumber(quantity) or 0, reqQuantity
        end
    end
    return 0, 0
end

local function SaveTitleProgress(charKey)
    if not PVPHUB_DB or not charKey then return end
    PVPHUB_DB[charKey]               = PVPHUB_DB[charKey]               or {}
    PVPHUB_DB[charKey].titleProgress = PVPHUB_DB[charKey].titleProgress or {}

    for key, def in pairs(TITLE_ACHIEVEMENTS) do
        local ok, id, _, _, completed, month, day, year, description, _, icon, rewardText =
            pcall(GetAchievementInfo, def.id)
        if ok and id then
            local current, required = GetAchievementProgress(def.id)
            PVPHUB_DB[charKey].titleProgress[key] = {
                achievementID = def.id,
                bracketKey    = def.bracketKey,
                current       = current,
                required      = required,
                completed     = completed or (required > 0 and current >= required) or false,
                earnedMonth   = month,
                earnedDay     = day,
                earnedYear    = year,
                description   = description,
                icon          = icon,
                rewardText    = rewardText,
                lastUpdated   = GetServerTime(),
            }
        end
    end

    if PVPHUB.UpdateTitleTracker then PVPHUB:UpdateTitleTracker() end
end

-- --------------------------------------------------------------------------
-- Dedicated event frame
-- --------------------------------------------------------------------------

local _pendingTitleProgressSave = false
local pvpTrackingFrame = CreateFrame("Frame")

pvpTrackingFrame:RegisterEvent("ADDON_LOADED")
pvpTrackingFrame:RegisterEvent("PLAYER_LOGIN")
pvpTrackingFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
pvpTrackingFrame:RegisterEvent("PVP_RATED_STATS_UPDATE")
pvpTrackingFrame:RegisterEvent("PVP_MATCH_ACTIVE")
pvpTrackingFrame:RegisterEvent("PVP_MATCH_INACTIVE")
pvpTrackingFrame:RegisterEvent("PVP_MATCH_COMPLETE")
pvpTrackingFrame:RegisterEvent("PLAYER_SPECIALIZATION_CHANGED")
pvpTrackingFrame:RegisterEvent("CRITERIA_UPDATE")
pvpTrackingFrame:RegisterEvent("ACHIEVEMENT_EARNED")

pvpTrackingFrame:SetScript("OnEvent", function(self, event, arg1, arg2)
    -- Protect against addon conflicts and taint issues (mirrors PVPHUB.frame's
    -- main handler) — an uncaught error here would abort mid-handler and could
    -- leave _pvpCacheReady stuck on false, silently breaking rating tracking.
    local success, errorMsg = pcall(function()
    if event == "ADDON_LOADED" then
        -- SavedVariables are guaranteed ready at this point; do an initial
        -- fetch after a short delay so the server has time to respond.
        if arg1 ~= "PVPHUB" then return end
        C_Timer.After(2, function()
            local key = GetCurrentCharKey()
            if not key then return end
            -- RequestRatedInfo() is the real global Blizzard uses (ConquestFrame_OnLoad).
            -- It sends a server request and fires PVP_RATED_STATS_UPDATE when data arrives.
            RequestRatedInfo()
            SaveBracketStats(key)
            SaveTitleProgress(key)
        end)

    elseif event == "PLAYER_LOGIN" then
        C_Timer.After(3, function()
            local key = GetCurrentCharKey()
            if not key then return end
            RequestRatedInfo()
            SaveBracketStats(key)
            SaveTitleProgress(key)
        end)

    elseif event == "PLAYER_ENTERING_WORLD" then
        -- arg1 = isInitialLogin, arg2 = isReloadingUI (WoW 9.0+ API)
        -- Always block per-spec writes until the server confirms fresh data.
        -- We intentionally do NOT wipe stored per-spec tables here: the last
        -- known values are shown while waiting for PVP_RATED_STATS_UPDATE, which
        -- is far better UX than always showing 0 on login.
        -- PVP_RATED_STATS_UPDATE will overwrite any stale values once the server
        -- responds, and _pvpCacheReady ensures nothing gets written before that.
        PVPHUB._pvpCacheReady = false
        -- Fire two staggered requests: the first one often populates the client
        -- cache quickly; the second is a safety net for slow servers or new chars
        -- whose PVP_RATED_STATS_UPDATE never fired on a previous session.
        C_Timer.After(2, function()
            RequestRatedInfo()
        end)
        C_Timer.After(5, function()
            RequestRatedInfo()
        end)
        C_Timer.After(8, function()
            local key = GetCurrentCharKey()
            if key then SaveBracketStats(key) end
        end)

    elseif event == "PVP_RATED_STATS_UPDATE" then
        -- Server has pushed fresh stats for this character to the client cache.
        -- After a spec change, the first fire may still carry the OLD spec's data
        -- (the server races the client cache). We skip that first event and only
        -- accept the second, which is guaranteed to reflect the new spec.
        -- This is event-count-based so it is robust to any network latency.
        if PVPHUB._specChangePendingSkips and PVPHUB._specChangePendingSkips > 0 then
            PVPHUB._specChangePendingSkips = PVPHUB._specChangePendingSkips - 1
            -- Re-request to ensure a second event arrives even on slow servers
            RequestRatedInfo()
        else
            PVPHUB._pvpCacheReady = true
        end
        local key = GetCurrentCharKey()
        if key then SaveBracketStats(key) end

    elseif event == "CRITERIA_UPDATE" or event == "ACHIEVEMENT_EARNED" then
        -- CRITERIA_UPDATE fires for every achievement criterion in the game,
        -- not just PvP ones (leveling, gathering, etc. all trigger it too).
        -- Coalesce rapid-fire updates into a single deferred SaveTitleProgress
        -- instead of redoing the full per-title GetAchievementInfo/
        -- GetAchievementProgress pass (plus a SavedVariables write and UI
        -- update) on every one.
        if not _pendingTitleProgressSave then
            _pendingTitleProgressSave = true
            C_Timer.After(1, function()
                _pendingTitleProgressSave = false
                local key = GetCurrentCharKey()
                if key then SaveTitleProgress(key) end
            end)
        end

    elseif event == "PVP_MATCH_ACTIVE" then
        -- Rated match is starting; capture current ratings as a baseline
        -- before the server changes anything.
        C_Timer.After(0.5, function()
            local key = GetCurrentCharKey()
            if key then CapturePreMatchSnapshot(key) end
        end)

    elseif event == "PVP_MATCH_INACTIVE" or event == "PVP_MATCH_COMPLETE" then
        -- Match ended. Reset cache readiness immediately so SaveBracketStats
        -- (and UpdatePvPRatings in core) won't write stale pre-match data while
        -- waiting for the server to push fresh stats via PVP_RATED_STATS_UPDATE.
        PVPHUB._pvpCacheReady = false
        -- Request fresh stats from the server; PVP_RATED_STATS_UPDATE will fire
        -- once the server responds, set _pvpCacheReady=true, and call SaveBracketStats.
        C_Timer.After(1, function()
            RequestRatedInfo()
        end)
        -- Fallback save at 4 s in case PVP_RATED_STATS_UPDATE takes longer.
        -- SaveBracketStats returns early if _pvpCacheReady is still false.
        C_Timer.After(4, function()
            local key = GetCurrentCharKey()
            if key then
                SaveBracketStats(key)
                SaveTitleProgress(key)
            end
        end)

    elseif event == "PLAYER_SPECIALIZATION_CHANGED" then
        -- Skip the next PVP_RATED_STATS_UPDATE: it may still carry the OLD spec's
        -- data from the client cache. We use a counter so the guard is lag-agnostic.
        PVPHUB._specChangePendingSkips = 1
        -- Cache is untrustworthy until the server responds with fresh data for
        -- the new spec.  PVP_RATED_STATS_UPDATE will re-enable per-spec writes.
        PVPHUB._pvpCacheReady  = false
        -- Ask the server for fresh bracket stats for the new spec immediately.
        RequestRatedInfo()
        -- Re-request at 3.5s as a fallback in case the first response is slow.
        C_Timer.After(3.5, function()
            RequestRatedInfo()
        end)
    end
    end) -- End pcall

    if not success then
        print("|cffff0000[PVPHUB Error]|r Event handler error: " .. tostring(errorMsg))
    end
end)

-- Expose for external callers (e.g. slash commands, manual refresh buttons)
PVPHUB.PvPTracking.frame              = pvpTrackingFrame
PVPHUB.PvPTracking.SaveBracketStats   = SaveBracketStats
PVPHUB.PvPTracking.SaveTitleProgress  = SaveTitleProgress
PVPHUB.PvPTracking.TITLE_ACHIEVEMENTS = TITLE_ACHIEVEMENTS
