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

local function GetCurrentSpecID()
    local idx = GetSpecialization()
    if not idx then return nil end
    local ok, specID = pcall(GetSpecializationInfo, idx)
    return (ok and specID and specID > 0) and specID or nil
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
                    PVPHUB_DB[charKey][b.key][specID] = rating
                end
            else
                -- Guard 2v2/3v3 writes the same way: only write after server confirms
                -- fresh data for this session (prevents cross-character cache bleed).
                if PVPHUB._pvpCacheReady then
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
-- Dedicated event frame
-- --------------------------------------------------------------------------

local pvpTrackingFrame = CreateFrame("Frame")

pvpTrackingFrame:RegisterEvent("ADDON_LOADED")
pvpTrackingFrame:RegisterEvent("PLAYER_LOGIN")
pvpTrackingFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
pvpTrackingFrame:RegisterEvent("PVP_RATED_STATS_UPDATE")
pvpTrackingFrame:RegisterEvent("PVP_MATCH_ACTIVE")
pvpTrackingFrame:RegisterEvent("PVP_MATCH_INACTIVE")
pvpTrackingFrame:RegisterEvent("PVP_MATCH_COMPLETE")
pvpTrackingFrame:RegisterEvent("PLAYER_SPECIALIZATION_CHANGED")

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
        end)

    elseif event == "PLAYER_LOGIN" then
        C_Timer.After(3, function()
            local key = GetCurrentCharKey()
            if not key then return end
            RequestRatedInfo()
            SaveBracketStats(key)
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
            if key then SaveBracketStats(key) end
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
PVPHUB.PvPTracking.frame            = pvpTrackingFrame
PVPHUB.PvPTracking.SaveBracketStats = SaveBracketStats
