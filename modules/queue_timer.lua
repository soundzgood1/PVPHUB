-- PVPHUB Queue Timer Module
-- Displays a live, draggable arena queue timer widget in PVPHUB style.
-- Shows queue name, average wait time, and elapsed time in queue.

local _, PVPHUB = ...

PVPHUB.QueueTimer = {}

-- --------------------------------------------------------------------------
-- Helpers
-- --------------------------------------------------------------------------

-- Returns the currently selected visual style: "pvphub" (default, themed
-- chrome) or "simple" (flat dark card, see PVPHUB.QueueTimer style docs).
local function GetQueueTimerStyle()
    return (PVPHUB_SETTINGS and PVPHUB_SETTINGS.queueTimer and PVPHUB_SETTINGS.queueTimer.style) or "pvphub"
end

-- Format a duration given in seconds into "X min Y sec" or "Y sec"
local function FormatQueueDuration(totalSeconds)
    if not totalSeconds or totalSeconds < 0 then return "< 1 min" end
    local mins = math.floor(totalSeconds / 60)
    if mins < 1 then
        return "< 1 min"
    end
    return string.format("%d min", mins)
end

-- Format elapsed seconds as M:SS (e.g. "2:34") so the display ticks every second.
local function FormatElapsedExact(totalSeconds)
    if not totalSeconds or totalSeconds < 0 then totalSeconds = 0 end
    local mins = math.floor(totalSeconds / 60)
    local secs = totalSeconds % 60
    return string.format("%d:%02d", mins, secs)
end

-- Format seconds as "X min Y sec" / "Y sec" — the spelled-out format used by
-- the "Detail" style (matches its reference mockup).
local function FormatDurationLong(totalSeconds)
    if not totalSeconds or totalSeconds < 0 then totalSeconds = 0 end
    local mins = math.floor(totalSeconds / 60)
    local secs = totalSeconds % 60
    if mins > 0 then
        return string.format("%d min %d sec", mins, secs)
    end
    return string.format("%d sec", secs)
end

-- Format seconds as "Xm" (whole minutes only) — the terse format used by
-- the "Compact" style's single-line summary.
local function FormatMinutesShort(totalSeconds)
    if not totalSeconds or totalSeconds < 0 then return "<1m" end
    local mins = math.floor(totalSeconds / 60)
    if mins < 1 then return "<1m" end
    return mins .. "m"
end

local TICK_DOTS = { ".", "..", "..." }

-- Small right-pointing arrow used in the "Detail" style's MMR line
-- ("2672 -> 2638"). An atlas texture rather than a Unicode arrow glyph,
-- since FRIZQT__.TTF has no glyph for U+2192 and silently drops it.
local ARROW_MARKUP = CreateAtlasMarkup("common-icon-forwardarrow", 10, 10)

-- English-only fallback map for edge cases not covered by queueType detection.
local QUEUE_NAME_MAP = {
    ["Solo Shuffle: All Arenas"] = "Shuffle",
    ["3v3 Arenas"]               = "3v3",
    ["2v2 Arenas"]               = "2v2",
    ["Blitz Battleground"]       = "Blitz BG",
    ["BlitzBattleground"]        = "Blitz BG",
    ["Rated Battleground Blitz"] = "Blitz BG",
    ["Random Battleground"]      = "Random BG",
    ["Random Epic Battleground"] = "Epic BG",
}

-- Locale-independent battleground IDs mapped to short names.
-- These IDs are stable integers regardless of client language.
local BG_ID_SHORT_NAMES = {
    [1]  = "AV",          -- Alterac Valley
    [2]  = "WSG",         -- Warsong Gulch
    [3]  = "AB",          -- Arathi Basin
    [7]  = "EotS",        -- Eye of the Storm
    [8]  = "Strand",      -- Strand of the Ancients
    [9]  = "IoC",         -- Isle of Conquest
    [10] = "IoC",         -- Isle of Conquest (alt ID)
    [15] = "Gilneas",     -- Battle for Gilneas
    [16] = "Twin Peaks",  -- Twin Peaks
    [17] = "SSM",         -- Silvershard Mines
    [18] = "ToK",         -- Temple of Kotmogu
    [20] = "DWG",         -- Deepwind Gorge
    [30] = "Ashran",      -- Ashran
    [32] = "S.Shore",     -- Seething Shore
    [34] = "DWG",         -- Deepwind Gorge (alt ID)
}

-- Built at runtime from C_PvP.GetBattlegroundInfo() — keys are localised BG names
-- in whatever language the client uses; values are our short names.
-- Populated by BuildBGNameMap() on ADDON_LOADED.
local BG_LOCALIZED_NAME_MAP = {}

local function BuildBGNameMap()
    if not GetNumBattlegroundTypes or not C_PvP or not C_PvP.GetBattlegroundInfo then return end
    for i = 1, GetNumBattlegroundTypes() do
        local info = C_PvP.GetBattlegroundInfo(i)
        if info and info.name and info.name ~= "" then
            if info.isRandom then
                -- Classify random queues by player count — locale-independent
                BG_LOCALIZED_NAME_MAP[info.name] = (info.maxPlayers >= 30) and "Epic BG" or "Random BG"
            elseif info.battlegroundID then
                local short = BG_ID_SHORT_NAMES[info.battlegroundID]
                if short then
                    BG_LOCALIZED_NAME_MAP[info.name] = short
                end
            end
        end
    end
end

-- Per-queue-type icon textures (keyed on short display name)
local QUEUE_ICON_MAP = {
    ["2v2"]        = "Interface\\Icons\\Achievement_Arena_2v2_1",
    ["3v3"]        = "Interface\\Icons\\Achievement_Arena_3v3_1",
    ["Shuffle"]    = "Interface\\Icons\\Achievement_Arena_5v5_1",
    ["Blitz BG"]   = "Interface\\Icons\\Achievement_BG_winAV",
    ["Rated BG"]   = "Interface\\Icons\\achievement_pvp_a_15",
    ["Random BG"]  = "Interface\\Icons\\Achievement_BG_WinEY",
    ["Epic BG"]    = "Interface\\Icons\\Achievement_BG_killx_flags_EY",
    ["AV"]         = "Interface\\Icons\\Achievement_BG_winAV",
    ["WSG"]        = "Interface\\Icons\\Achievement_BG_returnXflags_def_WSG",
    ["AB"]         = "Interface\\Icons\\Achievement_BG_winAB",
    ["EotS"]       = "Interface\\Icons\\Achievement_BG_WinEY",
    ["IoC"]        = "Interface\\Icons\\Achievement_BG_IC_general",
    ["DWG"]        = "Interface\\Icons\\Achievement_BG_winAB",
    ["Twin Peaks"] = "Interface\\Icons\\Achievement_BG_returnXflags_def_WSG",
    ["ToK"]        = "Interface\\Icons\\Achievement_BG_winAB",
    ["SSM"]        = "Interface\\Icons\\Achievement_BG_winAB",
    ["Ashran"]     = "Interface\\Icons\\Achievement_Zone_Ashran",
}

-- Maps a short queue display name to the PVPHUB_DB bracket key.
local DISPLAY_NAME_TO_BRACKET_KEY = {
    ["Shuffle"]  = "ratingShuffle",
    ["3v3"]      = "rating3v3",
    ["2v2"]      = "rating2v2",
    ["Blitz BG"] = "ratingBlitz",
    ["Rated BG"] = "ratingRBG",
}

-- Returns the last recorded MMR (number > 0) for a given queue display name,
-- or nil when none is stored yet.
local function GetStoredMMR(displayName)
    local bracketKey = DISPLAY_NAME_TO_BRACKET_KEY[displayName]
    if not bracketKey then return nil end
    if not PVPHUB_DB then return nil end

    local name, realm = UnitName("player")
    realm = realm or GetRealmName()
    if not name or name == "" then return nil end
    if not realm or realm == "" then realm = "Unknown" end
    local charKey = name .. "-" .. realm

    local charData = PVPHUB_DB[charKey]
    if not charData then return nil end

    -- Resolve current spec ID (deprecated-API safe, see modules/compat.lua)
    local specID = PVPHUB.Compat.GetCurrentSpecID()

    -- Primary: per-spec MMR stored by the MMR tracker (actual MMR, not CR)
    local lastKnown = charData.lastKnownMMR and charData.lastKnownMMR[bracketKey]
    if lastKnown then
        -- Try current spec first
        local entry = specID and lastKnown[specID]
        if entry and entry.mmr and entry.mmr > 0 then
            return entry.mmr
        end
        -- Fall back to the most-recently recorded spec for this bracket
        local bestTs, bestMMR = 0, nil
        for _, e in pairs(lastKnown) do
            if type(e) == "table" and e.mmr and e.mmr > 0 then
                local ts = e.timestamp or 0
                if ts > bestTs then bestTs = ts; bestMMR = e.mmr end
            end
        end
        if bestMMR then return bestMMR end
    end

    -- Secondary fallback: flat mmrData (written by arena TrackMMRChange)
    local mmrData = charData.mmrData and charData.mmrData[bracketKey]
    if mmrData and mmrData.mmr and mmrData.mmr > 0 then
        return mmrData.mmr
    end

    return nil
end

-- Returns { pre, post, change } from the most recently recorded match in
-- mmrHistory for this queue's bracket, or nil if there's no current-season
-- match to show. Used by the "Detail" style's "MMR: X → Y (±N)" line.
local function GetLastMMRChange(displayName)
    local bracketKey = DISPLAY_NAME_TO_BRACKET_KEY[displayName]
    if not bracketKey then return nil end
    if not PVPHUB_DB then return nil end

    local name, realm = UnitName("player")
    realm = realm or GetRealmName()
    if not name or name == "" then return nil end
    if not realm or realm == "" then realm = "Unknown" end
    local charKey = name .. "-" .. realm

    local charData = PVPHUB_DB[charKey]
    if not charData or not charData.mmrHistory or not charData.mmrHistory[bracketKey] then return nil end

    local history = charData.mmrHistory[bracketKey]
    local entry = history[#history]
    if not entry or not entry.preMatchMMR or not entry.postMatchMMR then return nil end

    -- Ignore stale data left over from a prior PvP season.
    local currentSeason = (C_PvP and C_PvP.GetUIDisplaySeason and C_PvP.GetUIDisplaySeason()) or 0
    if currentSeason > 0 and entry.season and entry.season ~= currentSeason then
        return nil
    end

    return { pre = entry.preMatchMMR, post = entry.postMatchMMR, change = entry.mmrChange or (entry.postMatchMMR - entry.preMatchMMR) }
end

-- Builds the "Detail" style's MMR line text: prefers the last match's
-- before/after change ("MMR: 2672 → 2638 (-34)"), falling back to just the
-- last known MMR ("MMR: 2672") when no match history exists yet. Returns nil
-- when there's nothing to show (e.g. an unrated queue).
local function BuildMMRLineText(displayName)
    local change = GetLastMMRChange(displayName)
    if change and change.pre and change.post and change.pre > 0 and change.post > 0 then
        local delta      = change.change or (change.post - change.pre)
        local deltaColor = delta >= 0 and "|cff40ff40" or "|cffff4040"
        local sign        = delta >= 0 and "+" or ""
        return string.format("MMR: %d %s %d %s(%s%d)|r", change.pre, ARROW_MARKUP, change.post, deltaColor, sign, delta)
    end
    local mmr = GetStoredMMR(displayName)
    if mmr then
        return "MMR: " .. mmr
    end
    return nil
end

-- Build a friendly display name for a queue slot.
-- queueType is the locale-independent string from GetBattlefieldStatus (6th return value).
-- mapName is used for BG identification via the runtime-built locale map.
local function GetQueueDisplayName(mapName, teamSize, queueType, registeredMatch)
    -- Primary: queueType is locale-independent for every rated/special bracket
    if queueType then
        if queueType == "RATEDSHUFFLE"  then return "Shuffle" end
        if queueType == "RATEDSOLORBG"  then return "Blitz BG" end
        if queueType == "BRAWLSHUFFLE"  then return "Brawl" end
        if queueType == "BRAWLSOLORBG"  then return "Brawl BG" end
        if queueType == "WARGAME"       then return "War Game" end
        if queueType == "ARENASKIRMISH" then
            -- Skirmish can match into either 2v2 or 3v3 regardless of role, so
            -- don't display a specific team size — just "Skirmish".
            return "Skirmish"
        end
        if queueType == "ARENA" then
            if teamSize == 2 then return "2v2" end
            if teamSize == 3 then return "3v3" end
        end
        if queueType == "BATTLEGROUND" then
            if registeredMatch then return "Rated BG" end
            -- For unrated BGs, fall through to mapName lookup below
        end
    end
    -- Secondary: locale-independent teamSize for plain arenas when queueType absent
    if teamSize == 2 then return "2v2" end
    if teamSize == 3 then return "3v3" end
    -- Tertiary: runtime-built table of localised BG names (works for all clients)
    if mapName and mapName ~= "" then
        if BG_LOCALIZED_NAME_MAP[mapName] then return BG_LOCALIZED_NAME_MAP[mapName] end
        -- Last resort: English-only fallback map
        if QUEUE_NAME_MAP[mapName] then return QUEUE_NAME_MAP[mapName] end
        for pattern, short in pairs(QUEUE_NAME_MAP) do
            if string.find(mapName, pattern, 1, true) then return short end
        end
        return mapName
    end
    return "PvP Queue"
end

-- Sound options for the match-ready alert.
-- All IDs are SOUNDKIT integer constants — played via PlaySound(id, channel).
PVPHUB.QueueTimer.SOUND_OPTIONS = {
    { label = "None"                  , id = nil    },
    { label = "PvP Queue Ready"       , id = 8459   }, -- SOUNDKIT.PVP_THROUGH_QUEUE
    { label = "Raid Warning"          , id = 8959   }, -- SOUNDKIT.RAID_WARNING
    { label = "Ready Check"           , id = 8960   }, -- SOUNDKIT.READY_CHECK
    { label = "Alarm Clock 1"         , id = 18871  }, -- SOUNDKIT.ALARM_CLOCK_WARNING_1
    { label = "Alarm Clock 2"         , id = 12867  }, -- SOUNDKIT.ALARM_CLOCK_WARNING_2
    { label = "Alarm Clock 3"         , id = 12889  }, -- SOUNDKIT.ALARM_CLOCK_WARNING_3
    { label = "Boss Emote Warning"    , id = 12197  }, -- SOUNDKIT.RAID_BOSS_EMOTE_WARNING
    { label = "BG Countdown Start"    , id = 25477  }, -- SOUNDKIT.UI_BATTLEGROUND_COUNTDOWN_TIMER
    { label = "BG Countdown Finished" , id = 25478  }, -- SOUNDKIT.UI_BATTLEGROUND_COUNTDOWN_FINISHED
    { label = "Quest Complete"        , id = 878    }, -- SOUNDKIT.IG_QUEST_LIST_COMPLETE
    { label = "Auto Quest Complete"   , id = 23404  }, -- SOUNDKIT.UI_AUTO_QUEST_COMPLETE
    { label = "Order Hall Talent"     , id = 73281  }, -- SOUNDKIT.UI_ORDERHALL_TALENT_READY_CHECK
    { label = "PvP Prestige Rank Up"  , id = 77003  }, -- SOUNDKIT.UI_PVP_HONOR_PRESTIGE_RANK_UP
    { label = "Raid Boss Defeated"    , id = 50111  }, -- SOUNDKIT.UI_RAID_BOSS_DEFEATED
}

-- Play the configured match-ready sound (once per transition into READY).
--
-- This used to implement the volume setting by temporarily scaling the
-- Sound_SFXVolume CVar down and restoring it from a C_Timer two seconds later.
-- That could leave the player's game permanently quieter: a /reload, logout or
-- disconnect inside those two seconds skipped the restore, and because the
-- pre-scaling value only lived in a session-local, the next press captured the
-- ALREADY-reduced value as its "original" and scaled again — compounding
-- toward silence across sessions. A queue pop is exactly when people zone or
-- reload, so it was reachable in normal play.
--
-- PlaySound's own volume is not adjustable, so the setting is now honoured the
-- only way that stays inside our own domain: full volume, or not at all.
-- SOUND_VOLUME_THRESHOLD is the point below which we treat the setting as
-- "off" rather than silently playing at full blast.
local SOUND_VOLUME_THRESHOLD = 25

local function PlayMatchReadySound()
    local soundKey = PVPHUB_SETTINGS and PVPHUB_SETTINGS.queueTimer and PVPHUB_SETTINGS.queueTimer.readySound
    if soundKey == nil then soundKey = "PvP Queue Ready" end  -- default
    if soundKey == "None" then return end

    local volume = (PVPHUB_SETTINGS.queueTimer and PVPHUB_SETTINGS.queueTimer.readySoundVolume)
    if volume == nil then volume = 100 end
    if volume < SOUND_VOLUME_THRESHOLD then return end

    for _, opt in ipairs(PVPHUB.QueueTimer.SOUND_OPTIONS) do
        if opt.label == soundKey and opt.id then
            PlaySound(opt.id, "SFX")
            return
        end
    end
end

-- One-time repair for anyone whose Sound_SFXVolume was left scaled down by the
-- bug described above. The old code never persisted the original value, so we
-- can't restore an exact number — but we can stop it compounding, and a stuck
-- value is silent-failure territory the player would otherwise never connect
-- back to this addon. Only warns; never changes the CVar behind their back.
local function WarnIfSFXVolumeLooksStuck()
    if PVPHUB_SETTINGS.sfxVolumeWarningShown then return end
    local vol = tonumber(GetCVar("Sound_SFXVolume"))
    local hadScaling = PVPHUB_SETTINGS.queueTimer
                       and PVPHUB_SETTINGS.queueTimer.readySoundVolume
                       and PVPHUB_SETTINGS.queueTimer.readySoundVolume < 100
    if hadScaling and vol and vol < 0.25 then
        PVPHUB_SETTINGS.sfxVolumeWarningShown = true
        print("|cffFFD100[PVPHUB]|r Your Sound Effects volume is very low (" .. math.floor(vol * 100) ..
              "%). An older version of PVPHUB's queue-ready sound could leave it that way. " ..
              "You can reset it under Options > Sound. This notice won't show again.")
    end
end

-- --------------------------------------------------------------------------
-- Resize frame width to fit content
-- --------------------------------------------------------------------------

-- Measures how tall a row needs to be to fit its three text lines snugly,
-- so unused rows don't leave dead space below the last row's text.
local function ComputeRowHeight(row)
    if row.compactLine:IsShown() then
        return 6 + (row.compactLine:GetStringHeight() or 14) + 6
    end
    local nameH = (row.nameLabel:GetStringHeight()) or 16
    local mmrH  = row.mmrLine:IsShown() and ((row.mmrLine:GetStringHeight() or 13) + 3) or 0
    local avgH  = (row.avgLabel:GetStringHeight())  or 13
    local inQH  = (row.inQLabel:GetStringHeight())  or 13
    return 6 + nameH + mmrH + 3 + avgH + 2 + inQH + 6
end

-- GetStringWidth()-based auto-sizing kept under-measuring the "Compact"
-- style's single line (it compounds with OUTLINE-font glyph overflow and
-- multiple embedded |cAARRGGBB...|r color segments — worse the longer/more
-- colored the line, e.g. a READY line with both a colored name and colored
-- "READY"/accept-timer text). Rather than keep chasing that, compact gets a
-- hardcoded width comfortably wide for its realistic worst case
-- ("Shuffle   READY   Accept 27s") — a fixed, always-correct card instead of
-- a snug-but-occasionally-wrong one.
local COMPACT_CARD_WIDTH = 200

local function ResizeToContent(f)
    local maxW = 150
    local scale = f:GetScale() or 1.0
    -- Safety margin applied to every measured (non-compact) line: a
    -- proportional factor plus a flat buffer, to absorb OUTLINE-font glyph
    -- overflow and multi-color-segment measurement drift.
    local function Measure(...)
        local total = 0
        for _, fs in ipairs({...}) do
            total = total + fs:GetStringWidth()
        end
        return (total / scale) * 1.12 + 14
    end

    for _, row in ipairs(f.slotRows or {}) do
        if row:IsShown() then
            if row.compactLine:IsShown() then
                maxW = math.max(maxW, COMPACT_CARD_WIDTH)
            else
                maxW = math.max(maxW, 10 + Measure(row.nameLabel))
                maxW = math.max(maxW, 10 + Measure(row.avgLabel, row.avgValue) + 5)
                maxW = math.max(maxW, 10 + Measure(row.inQLabel, row.inQValue) + 5)
                if row.mmrLine:IsShown() then
                    maxW = math.max(maxW, 10 + Measure(row.mmrLine))
                end
            end
        end
    end
    -- Always fit the current content exactly (grows AND shrinks) so the card
    -- never carries leftover width from a wider line that's no longer shown
    -- (e.g. the MMR line disappearing, or a READY state's shorter text).
    f:SetWidth(maxW)
end

-- --------------------------------------------------------------------------
-- Frame creation
-- --------------------------------------------------------------------------

function PVPHUB.QueueTimer:CreateFrame()
    if self.frame then return end

    local frame = CreateFrame("Frame", "PVPHUBQueueTimerFrame", UIParent, "BackdropTemplate")
    frame:SetFrameStrata("LOW")
    frame:SetClampedToScreen(true)
    frame:SetSize(220, 57)

    -- Restore saved position or default to top-center area
    if PVPHUB_SETTINGS and PVPHUB_SETTINGS.queueTimerPos then
        local p = PVPHUB_SETTINGS.queueTimerPos
        frame:SetPoint(p.point or "TOP", UIParent, p.relativePoint or "TOP", p.x or 0, p.y or -200)
    else
        frame:SetPoint("TOPRIGHT", UIParent, "TOPRIGHT", -250, -200)
    end

    -- Backdrop
    frame:SetBackdrop({
        bgFile   = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile     = false,
        tileSize = 16,
        edgeSize = 12,
        insets   = { left = 3, right = 3, top = 3, bottom = 3 },
    })

    -- Dragging (left button) + right-click context menu
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", function(f)
        f:StopMovingOrSizing()
        PVPHUB_SETTINGS = PVPHUB_SETTINGS or {}
        local point, _, relPoint, x, y = f:GetPoint()
        PVPHUB_SETTINGS.queueTimerPos = { point = point, relativePoint = relPoint, x = x, y = y }
    end)

    -- ---- Header bar ----
    local header = CreateFrame("Frame", nil, frame)
    header:SetPoint("TOPLEFT",  frame, "TOPLEFT",  3, -3)
    header:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -3, -3)
    header:SetHeight(22)
    frame.header = header

    local headerBg = header:CreateTexture(nil, "BACKGROUND")
    headerBg:SetAllPoints(header)
    frame.headerBg = headerBg

    local separator = frame:CreateTexture(nil, "ARTWORK")
    separator:SetHeight(1)
    separator:SetPoint("TOPLEFT",  header, "BOTTOMLEFT",  0, -1)
    separator:SetPoint("TOPRIGHT", header, "BOTTOMRIGHT", 0, -1)
    frame.separator = separator

    -- Queue icon
    local icon = header:CreateTexture(nil, "ARTWORK")
    icon:SetSize(16, 16)
    icon:SetPoint("LEFT", header, "LEFT", 5, 0)
    icon:SetTexture("Interface\\Icons\\Achievement_Arena_3v3_1")
    frame.icon = icon

    -- Queue name label
    local nameLabel = header:CreateFontString(nil, "OVERLAY")
    nameLabel:SetFont("Fonts\\FRIZQT__.TTF", 13, "OUTLINE")
    nameLabel:SetPoint("LEFT",  icon,   "RIGHT", 5, 0)
    nameLabel:SetPoint("RIGHT", header, "RIGHT", -5, 0)
    nameLabel:SetJustifyH("LEFT")
    nameLabel:SetWordWrap(false)
    nameLabel:SetNonSpaceWrap(false)
    nameLabel:SetText("Queue")
    frame.nameLabel = nameLabel

    -- ---- Body ----
    local body = CreateFrame("Frame", nil, frame)
    body:SetPoint("TOPLEFT",     header, "BOTTOMLEFT",  0,  0)
    body:SetPoint("BOTTOMRIGHT", frame,  "BOTTOMRIGHT", -3, 3)
    frame.body = body

    local maxRows = PVPHUB.Compat.GetMaxBattlefieldQueues()
    frame.slotRows = {}
    for i = 1, maxRows do
        local ROW_H = 56
        local row = CreateFrame("Frame", nil, body)
        row:SetHeight(ROW_H)
        if i == 1 then
            row:SetPoint("TOPLEFT",  body, "TOPLEFT",  0, -3)
            row:SetPoint("TOPRIGHT", body, "TOPRIGHT", 0, -3)
        else
            row:SetPoint("TOPLEFT",  frame.slotRows[i-1], "BOTTOMLEFT",  0, -1)
            row:SetPoint("TOPRIGHT", frame.slotRows[i-1], "BOTTOMRIGHT", 0, -1)
        end

        -- Row highlight band: two textures forming a fade-in-from-left,
        -- fade-out-to-right band (same technique as the tooltip row highlight).
        local bandLeft = row:CreateTexture(nil, "BACKGROUND")
        bandLeft:SetTexture("Interface\\Buttons\\WHITE8x8")
        bandLeft:SetPoint("TOPLEFT",     row, "TOPLEFT", 0, 0)
        bandLeft:SetPoint("BOTTOMRIGHT", row, "BOTTOM",  0, 0)
        bandLeft:Hide()
        row.bandLeft = bandLeft

        local bandRight = row:CreateTexture(nil, "BACKGROUND")
        bandRight:SetTexture("Interface\\Buttons\\WHITE8x8")
        bandRight:SetPoint("TOPLEFT",     row, "TOP",         0, 0)
        bandRight:SetPoint("BOTTOMRIGHT", row, "BOTTOMRIGHT", 0, 0)
        bandRight:Hide()
        row.bandRight = bandRight

        -- Queue name. No RIGHT anchor: any second point pins this to the
        -- row's CURRENT width, which lets a fixed-width box clip the text's
        -- tail instead of the card growing to fit it — the card is sized to
        -- the text (via ResizeToContent/GetStringWidth), not the other way
        -- around, so nothing here should ever constrain its own width.
        local nameLabel = row:CreateFontString(nil, "OVERLAY")
        nameLabel:SetFont("Fonts\\FRIZQT__.TTF", 13, "OUTLINE")
        nameLabel:SetPoint("TOPLEFT", row, "TOPLEFT", 10, -6)
        nameLabel:SetJustifyH("LEFT")
        nameLabel:SetWordWrap(false)
        nameLabel:SetNonSpaceWrap(false)
        row.nameLabel = nameLabel

        -- "MMR: X → Y (±N)" line — only populated/shown by the "Detail"
        -- style; sits between the name and the avg-wait line when present.
        local mmrLine = row:CreateFontString(nil, "OVERLAY")
        mmrLine:SetFont("Fonts\\FRIZQT__.TTF", 11, "OUTLINE")
        mmrLine:SetPoint("TOPLEFT", nameLabel, "BOTTOMLEFT", 0, -3)
        mmrLine:SetJustifyH("LEFT")
        mmrLine:Hide()
        row.mmrLine = mmrLine

        -- Single-line summary used by the "Compact" style:
        -- "Name (MMR)   Avg Xm   Q M:SS" — everything on one row.
        local compactLine = row:CreateFontString(nil, "OVERLAY")
        compactLine:SetFont("Fonts\\FRIZQT__.TTF", 12, "OUTLINE")
        compactLine:SetPoint("TOPLEFT", row, "TOPLEFT", 10, -6)
        compactLine:SetJustifyH("LEFT")
        compactLine:SetWordWrap(false)
        compactLine:SetNonSpaceWrap(false)
        compactLine:Hide()
        row.compactLine = compactLine

        -- "Avg Wait:" sub-line
        local avgLabel = row:CreateFontString(nil, "OVERLAY")
        avgLabel:SetFont("Fonts\\FRIZQT__.TTF", 11, "OUTLINE")
        avgLabel:SetPoint("TOPLEFT", nameLabel, "BOTTOMLEFT", 0, -3)
        avgLabel:SetText("Avg Wait:")
        row.avgLabel = avgLabel

        local avgValue = row:CreateFontString(nil, "OVERLAY")
        avgValue:SetFont("Fonts\\FRIZQT__.TTF", 11, "OUTLINE")
        avgValue:SetPoint("LEFT", avgLabel, "RIGHT", 5, 0)
        avgValue:SetText("--")
        row.avgValue = avgValue

        -- "In Queue:" sub-line
        local inQLabel = row:CreateFontString(nil, "OVERLAY")
        inQLabel:SetFont("Fonts\\FRIZQT__.TTF", 11, "OUTLINE")
        inQLabel:SetPoint("TOPLEFT", avgLabel, "BOTTOMLEFT", 0, -2)
        inQLabel:SetText("In Queue:")
        row.inQLabel = inQLabel

        local inQValue = row:CreateFontString(nil, "OVERLAY")
        inQValue:SetFont("Fonts\\FRIZQT__.TTF", 11, "OUTLINE")
        inQValue:SetPoint("LEFT", inQLabel, "RIGHT", 5, 0)
        inQValue:SetText("--")
        row.inQValue = inQValue

        local divider = row:CreateTexture(nil, "ARTWORK")
        divider:SetHeight(1)
        divider:SetPoint("BOTTOMLEFT",  row, "BOTTOMLEFT",   8, 0)
        divider:SetPoint("BOTTOMRIGHT", row, "BOTTOMRIGHT", -8, 0)
        divider:SetColorTexture(1, 1, 1, 0.08)
        row.divider = divider

        -- Match history tooltip on hover (rated brackets only)
        row:SetScript("OnEnter", function(self)
            if self.currentDisplayName and PVPHUB.ShowQueueBracketTooltip then
                PVPHUB:ShowQueueBracketTooltip(self, self.currentDisplayName)
            end
        end)
        row:SetScript("OnLeave", function()
            GameTooltip:Hide()
            if PVPHUBRatingTooltip then PVPHUBRatingTooltip:Hide() end
        end)

        -- Propagate drag to the parent frame so the widget remains draggable
        -- even though the rows intercept mouse events for tooltip handling.
        row:SetScript("OnMouseDown", function(self, btn)
            if btn == "LeftButton" then
                frame:StartMoving()
            end
        end)
        row:SetScript("OnMouseUp", function()
            frame:StopMovingOrSizing()
            PVPHUB_SETTINGS = PVPHUB_SETTINGS or {}
            local point, _, relPoint, x, y = frame:GetPoint()
            PVPHUB_SETTINGS.queueTimerPos = { point = point, relativePoint = relPoint, x = x, y = y }
        end)

        row:Hide()
        frame.slotRows[i] = row
    end

    frame:Hide()
    self.frame = frame
    self:_ScaleFonts()
    -- Theme is applied externally after currentColors is ready
end

-- --------------------------------------------------------------------------
-- Font / layout scaling
-- --------------------------------------------------------------------------

-- Scales all fonts and row positions proportionally to the current frame height.
-- Base height is 80px (matches the default 12/13pt sizes).
--
-- Font FAMILY follows the Appearance tab's selected font (PVPHUB._ResolveFontPath,
-- exported from core.lua) same as everywhere else in the addon except Streamer
-- Mode. Called both on resize and from core.lua's ApplyFontChanges() so an open
-- Queue Timer window updates immediately when the user picks a new font.
function PVPHUB.QueueTimer:_ScaleFonts()
    local f = self.frame
    if not f then return end
    local outline = (PVPHUB_SETTINGS and PVPHUB_SETTINGS.queueTimer and PVPHUB_SETTINGS.queueTimer.fontOutline == false) and "" or "OUTLINE"
    local path = PVPHUB._ResolveFontPath and PVPHUB._ResolveFontPath() or "Fonts\\FRIZQT__.TTF"
    f.nameLabel:SetFont(path, 13, outline)
    for _, row in ipairs(f.slotRows or {}) do
        row.nameLabel:SetFont(path, 13, outline)
        row.mmrLine:SetFont(path, 11, outline)
        row.compactLine:SetFont(path, 12, outline)
        row.avgLabel:SetFont(path, 11, outline)
        row.avgValue:SetFont(path, 11, outline)
        row.inQLabel:SetFont(path, 11, outline)
        row.inQValue:SetFont(path, 11, outline)
    end
end

-- Applies saved opacity to the background texture only (real-time safe).
function PVPHUB.QueueTimer:ApplyOpacity()
    if not self.frame then return end
    local f = self.frame
    local alpha = (PVPHUB_SETTINGS and PVPHUB_SETTINGS.queueTimer and PVPHUB_SETTINGS.queueTimer.opacity) or 0.95

    local style = GetQueueTimerStyle()
    if style == "simple" or style == "compact" then
        f:SetBackdropColor(0.05, 0.05, 0.06, alpha)
        if f.Background then f.Background:SetVertexColor(0.05, 0.05, 0.06, alpha) end
        f:SetBackdropBorderColor(1, 1, 1, 0.18 * alpha)
        return
    end

    local colors = (PVPHUB.currentColors and next(PVPHUB.currentColors) and PVPHUB.currentColors) or {}
    local bg = colors.WINDOW_BG or { 0.08, 0.05, 0.05, 0.95 }
    f:SetBackdropColor(bg[1], bg[2], bg[3], alpha)
    if f.Background then
        f.Background:SetVertexColor(bg[1], bg[2], bg[3], alpha)
    end
    local border = colors.WINDOW_BORDER or { 0.35, 0.2, 0.25, 0.8 }
    f:SetBackdropBorderColor(border[1], border[2], border[3], alpha)
end

-- Applies the saved scale to the frame.
-- Optionally accepts a scale value directly to avoid any settings-lookup delay.
function PVPHUB.QueueTimer:ApplyScale(scale)
    if not self.frame then return end
    scale = scale or (PVPHUB_SETTINGS and PVPHUB_SETTINGS.queueTimerScale) or 1.0
    self.frame:SetScale(scale)
end

-- --------------------------------------------------------------------------
-- Theme application
-- --------------------------------------------------------------------------

-- Applies the PVPHUB color theme to the frame chrome (backdrop, border, header).
function PVPHUB.QueueTimer:ApplyTheme()
    if not self.frame then return end
    self:_ApplyColors()
end

-- Kept for backward-compatibility; per-row READY colouring is handled in Update().
function PVPHUB.QueueTimer:ApplyReadyTheme()
    self:ApplyTheme()
end

-- Internal: applies theme colors to frame chrome only (not per-row content).
function PVPHUB.QueueTimer:_ApplyColors()
    local f = self.frame
    local alpha = (PVPHUB_SETTINGS and PVPHUB_SETTINGS.queueTimer and PVPHUB_SETTINGS.queueTimer.opacity) or 0.95

    -- "Detail" / "Compact" styles: flat dark card, no theme accent colors at all.
    local style = GetQueueTimerStyle()
    if style == "simple" or style == "compact" then
        f:SetBackdropColor(0.05, 0.05, 0.06, alpha)
        if f.Background then f.Background:SetVertexColor(0.05, 0.05, 0.06, alpha) end
        f:SetBackdropBorderColor(1, 1, 1, 0.18 * alpha)
        f.headerBg:SetColorTexture(0, 0, 0, 0)
        f.separator:SetColorTexture(1, 1, 1, 0.08 * alpha)
        f.nameLabel:SetTextColor(1, 1, 1, 1)
        return
    end

    local colors = (PVPHUB.currentColors and next(PVPHUB.currentColors) and PVPHUB.currentColors)
                   or {}

    local bg = colors.WINDOW_BG or { 0.08, 0.05, 0.05, 0.95 }
    f:SetBackdropColor(bg[1], bg[2], bg[3], alpha)
    if f.Background then
        f.Background:SetVertexColor(bg[1], bg[2], bg[3], alpha)
    end

    local border = colors.WINDOW_BORDER or { 0.35, 0.2, 0.25, 0.8 }
    f:SetBackdropBorderColor(border[1], border[2], border[3], alpha)

    local accent = colors.ACCENT_LINE or { 0.8, 0.3, 0.5, 0.8 }
    f.headerBg:SetColorTexture(accent[1] * 0.4, accent[2] * 0.4, accent[3] * 0.4, 0.55 * alpha)
    f.separator:SetColorTexture(accent[1], accent[2], accent[3], 0.5 * alpha)

    f.nameLabel:SetTextColor(1, 0.82, 0, 1)  -- fixed yellow for readability
end

-- Colors a single slot row: green READY highlight or normal theme colors.
function PVPHUB.QueueTimer:_ApplyRowColors(row, isReady)
    local alpha = (PVPHUB_SETTINGS and PVPHUB_SETTINGS.queueTimer and PVPHUB_SETTINGS.queueTimer.opacity) or 0.95
    local style = GetQueueTimerStyle()

    -- "Compact" style: one line, no bands. Most of the color already lives
    -- inline in the string (yellow name, green READY) — this just sets the
    -- base color for the unembedded parts ("Avg", "Q", separators).
    if style == "compact" then
        row.bandLeft:Hide()
        row.bandRight:Hide()
        if isReady then
            row.compactLine:SetTextColor(0.55, 0.85, 0.55, 1)
        else
            row.compactLine:SetTextColor(0.85, 0.85, 0.88, 1)
        end
        return
    end

    -- "Detail" style: no highlight bands, monochrome text.
    if style == "simple" then
        row.bandLeft:Hide()
        row.bandRight:Hide()
        if isReady then
            row.nameLabel:SetTextColor(0.35, 1.0, 0.40, 1)
            row.mmrLine:SetTextColor(0.55, 0.85, 0.55, 1)
            row.avgLabel:SetTextColor(0.55, 0.85, 0.55, 1)
            row.avgValue:SetTextColor(0.55, 0.85, 0.55, 1)
            row.inQLabel:SetTextColor(0.55, 0.85, 0.55, 1)
            row.inQValue:SetTextColor(0.55, 0.85, 0.55, 1)
        else
            row.nameLabel:SetTextColor(1, 0.82, 0, 1)  -- yellow bracket name
            row.mmrLine:SetTextColor(0.75, 0.75, 0.78, 1)
            row.avgLabel:SetTextColor(0.65, 0.65, 0.68, 1)
            row.avgValue:SetTextColor(0.85, 0.85, 0.88, 1)
            row.inQLabel:SetTextColor(0.65, 0.65, 0.68, 1)
            row.inQValue:SetTextColor(0.85, 0.85, 0.88, 1)
        end
        return
    end

    local colors = (PVPHUB.currentColors and next(PVPHUB.currentColors) and PVPHUB.currentColors)
                   or {}
    if isReady then
        local cFull = CreateColor(0.05, 0.35, 0.05, 0.55 * alpha)
        local cNone = CreateColor(0.05, 0.35, 0.05, 0)
        row.bandLeft:SetGradient("HORIZONTAL", cNone, cFull)
        row.bandRight:SetGradient("HORIZONTAL", cFull, cNone)
        row.bandLeft:Show()
        row.bandRight:Show()
        row.nameLabel:SetTextColor(0.2, 1, 0.2, 1)
        row.avgLabel:SetTextColor(0.5, 0.9, 0.5, 1)
        row.avgValue:SetTextColor(0.2, 1, 0.2, 1)
        row.inQLabel:SetTextColor(0.5, 0.9, 0.5, 1)
        row.inQValue:SetTextColor(0.2, 1, 0.2, 1)
    else
        local accent = (PVPHUB.currentColors and PVPHUB.currentColors.ACCENT_LINE) or { 0.8, 0.3, 0.5, 0.8 }
        local cFull = CreateColor(accent[1], accent[2], accent[3], 0.18 * alpha)
        local cNone = CreateColor(accent[1], accent[2], accent[3], 0)
        row.bandLeft:SetGradient("HORIZONTAL", cNone, cFull)
        row.bandRight:SetGradient("HORIZONTAL", cFull, cNone)
        row.bandLeft:Show()
        row.bandRight:Show()
        row.nameLabel:SetTextColor(1, 0.82, 0, 1)  -- fixed yellow for readability
        local dim = { 0.7, 0.7, 0.7, 1 }
        row.avgLabel:SetTextColor(dim[1], dim[2], dim[3], 1)
        row.inQLabel:SetTextColor(dim[1], dim[2], dim[3], 1)
        local val = colors.HEADER_COLOR or { 1, 1, 1, 1 }
        row.avgValue:SetTextColor(val[1], val[2], val[3], 1)
        row.inQValue:SetTextColor(val[1], val[2], val[3], 1)
    end
end

-- --------------------------------------------------------------------------
-- Data update
-- --------------------------------------------------------------------------

function PVPHUB.QueueTimer:Update()
    if not self.frame then return end

    -- Respect the "Show Queue Timer" toggle in settings
    -- (bypassed when preview mode is active so the user can still see the widget)
    if PVPHUB_SETTINGS and PVPHUB_SETTINGS.queueTimerEnabled == false and not self._previewOverride then
        self:Hide()
        return
    end

    -- Hide inside arenas/battlegrounds when configured (default: hidden)
    if not (PVPHUB_SETTINGS and PVPHUB_SETTINGS.queueTimer and PVPHUB_SETTINGS.queueTimer.hideInInstances == false) then
        local inInstance, instanceType = IsInInstance()
        if inInstance and (instanceType == "pvp" or instanceType == "arena") then
            if self.frame then self.frame:Hide() end
            return
        end
    end

    -- Collect ALL active queue slots
    self.confirmTimes = self.confirmTimes or {}
    local activeSlots = {}
    local maxSlots = PVPHUB.Compat.GetMaxBattlefieldQueues()
    for i = 1, maxSlots do
        local status, mapName, teamSize, registeredMatch, suspendedQueue, queueType = GetBattlefieldStatus(i)
        if status == "confirm" or status == "queued" then
            table.insert(activeSlots, {
                index           = i,
                status          = status,
                mapName         = mapName,
                teamSize        = teamSize,
                registeredMatch = registeredMatch,
                queueType       = queueType,
                elapsed         = GetBattlefieldTimeWaited(i) or 0,
            })
        else
            self.confirmTimes[i] = nil  -- clear expired confirm tracking
        end
    end

    if #activeSlots == 0 then
        if self._testMode then
            self:_ShowTestPreview()
            return
        end
        self:Hide()
        return
    end

    self:Show()

    -- Sort: confirm (READY) first, then by elapsed time descending
    table.sort(activeSlots, function(a, b)
        if a.status == "confirm" and b.status ~= "confirm" then return true end
        if b.status == "confirm" and a.status ~= "confirm" then return false end
        return a.elapsed > b.elapsed
    end)

    -- Header is always hidden; body fills the entire frame
    self.frame.header:Hide()
    self.frame.separator:Hide()
    self.frame.body:ClearAllPoints()
    self.frame.body:SetPoint("TOPLEFT",     self.frame, "TOPLEFT",     3, -3)
    self.frame.body:SetPoint("BOTTOMRIGHT", self.frame, "BOTTOMRIGHT", -3,  3)
    local r1 = self.frame.slotRows[1]
    if r1 then
        r1:ClearAllPoints()
        r1:SetPoint("TOPLEFT",  self.frame.body, "TOPLEFT",  0, 0)
        r1:SetPoint("TOPRIGHT", self.frame.body, "TOPRIGHT", 0, 0)
    end

    -- Advance the tick counter used for the animated dots indicator
    self.frame._tickCount = ((self.frame._tickCount or 0) + 1) % 3
    local dots = TICK_DOTS[self.frame._tickCount + 1]

    -- Populate slot rows
    local anyReady = false
    for i, slot in ipairs(activeSlots) do
        local row = self.frame.slotRows[i]
        if not row then break end

        local style = GetQueueTimerStyle()
        local displayName = GetQueueDisplayName(slot.mapName, slot.teamSize, slot.queueType, slot.registeredMatch)
        row.currentDisplayName = displayName  -- used by OnEnter tooltip

        local isReady = (slot.status == "confirm")
        if isReady then anyReady = true end
        local inQSec = math.floor(slot.elapsed / 1000)

        row.avgLabel:ClearAllPoints()

        if style == "compact" then
            -- Everything on one line, as minimal as possible.
            row.mmrLine:Hide()
            row.nameLabel:Hide()
            row.avgLabel:Hide()
            row.avgValue:Hide()
            row.inQLabel:Hide()
            row.inQValue:Hide()
            row.compactLine:Show()

            if isReady then
                if not self.confirmTimes[slot.index] then
                    self.confirmTimes[slot.index] = GetTime()
                    PlayMatchReadySound()
                end
                local remaining = math.ceil(math.max(0, 28 - (GetTime() - self.confirmTimes[slot.index])))
                row.compactLine:SetText(string.format("|cffffd100%s|r   |cff40ff40READY|r   Accept %ds", displayName, remaining))
            else
                self.confirmTimes[slot.index] = nil
                local estMs  = GetBattlefieldEstimatedWaitTime(slot.index) or 0
                local avgShort = estMs > 0 and FormatMinutesShort(math.floor(estMs / 1000)) or "<1m"
                local mmr = GetStoredMMR(displayName)
                local mmrPart = mmr and string.format(" |cffaaaaaa(%d)|r", mmr) or ""
                row.compactLine:SetText(string.format("|cffffd100%s|r%s   Avg %s   Q %s", displayName, mmrPart, avgShort, FormatElapsedExact(inQSec)))
            end
        else
            row.compactLine:Hide()
            row.nameLabel:Show()
            row.avgLabel:Show()
            row.avgValue:Show()
            row.inQLabel:Show()
            row.inQValue:Show()

            -- Name line + MMR line differ per style: "pvphub" inlines a static
            -- "(X MMR)" suffix on the name; "simple" gets its own before/after
            -- delta line (or is hidden entirely when there's nothing to show).
            if style == "simple" then
                row.nameLabel:SetText(displayName)
                local mmrText = BuildMMRLineText(displayName)
                if mmrText then
                    row.mmrLine:SetText(mmrText)
                    row.mmrLine:Show()
                    row.avgLabel:SetPoint("TOPLEFT", row.mmrLine, "BOTTOMLEFT", 0, -3)
                else
                    row.mmrLine:Hide()
                    row.avgLabel:SetPoint("TOPLEFT", row.nameLabel, "BOTTOMLEFT", 0, -3)
                end
            else
                row.mmrLine:Hide()
                row.avgLabel:SetPoint("TOPLEFT", row.nameLabel, "BOTTOMLEFT", 0, -3)
                local mmr = GetStoredMMR(displayName)
                local mmrSuffix = mmr and string.format(" |cffaaaaaa(%d MMR)|r", mmr) or ""
                row.nameLabel:SetText(displayName .. mmrSuffix)
            end

            if isReady then
                if not self.confirmTimes[slot.index] then
                    self.confirmTimes[slot.index] = GetTime()
                    -- First tick this slot became READY — play the alert sound
                    PlayMatchReadySound()
                end
                local remaining = math.ceil(math.max(0, 28 - (GetTime() - self.confirmTimes[slot.index])))
                if style == "simple" then
                    row.avgLabel:SetText("Accept:")
                    row.avgValue:SetText(remaining .. " sec")
                    row.inQLabel:SetText("Q:")
                    row.inQValue:SetText(FormatDurationLong(inQSec))
                else
                    row.avgLabel:SetText("Accept in:")
                    row.avgValue:SetText(remaining .. " sec")
                    row.inQLabel:SetText("In Queue:")
                    row.inQValue:SetText(FormatElapsedExact(inQSec))
                end
            else
                self.confirmTimes[slot.index] = nil
                local estMs  = GetBattlefieldEstimatedWaitTime(slot.index) or 0
                if style == "simple" then
                    row.avgLabel:SetText("Avg:")
                    row.avgValue:SetText(estMs > 0 and FormatDurationLong(math.floor(estMs / 1000)) or "< 1 min")
                    row.inQLabel:SetText("Q:")
                    row.inQValue:SetText(FormatDurationLong(inQSec))
                else
                    row.avgLabel:SetText("Avg Wait:")
                    row.avgValue:SetText(estMs > 0 and FormatQueueDuration(math.floor(estMs / 1000)) or "< 1 min")
                    row.inQLabel:SetText("In Queue:")
                    row.inQValue:SetText(FormatElapsedExact(inQSec) .. dots)
                end
            end
        end

        self:_ApplyRowColors(row, isReady)
        -- Show divider only between rows, not after the last active one
        row.divider:SetShown(i < #activeSlots)
        row:Show()
    end

    -- Hide unused rows
    for i = #activeSlots + 1, #self.frame.slotRows do
        self.frame.slotRows[i]:Hide()
    end

    -- Row/frame sizing is deferred one frame: GetStringWidth()/GetStringHeight()
    -- can still report the PREVIOUS text's metrics if queried in the same tick
    -- SetText() just changed them (the layout pass hasn't run yet), which made
    -- the card intermittently render narrower than the text it was showing.
    -- Waiting a frame guarantees accurate measurements before we size anything.
    C_Timer.After(0, function()
        if not self.frame or not self.frame:IsShown() then return end

        for i = 1, #activeSlots do
            local row = self.frame.slotRows[i]
            if row then row:SetHeight(ComputeRowHeight(row)) end
        end

        -- Auto-size frame height to the actual (snug) row heights, not a flat
        -- per-row constant — avoids leaving dead space below the last row.
        local totalRowHeight = 0
        for i = 1, #activeSlots do
            totalRowHeight = totalRowHeight + self.frame.slotRows[i]:GetHeight()
        end
        self.frame:SetHeight(totalRowHeight + math.max(0, #activeSlots - 1) * 1 + 6)

        self:ApplyOpacity()
        ResizeToContent(self.frame)

        -- When any slot is READY, paint the entire frame chrome green,
        -- scaled by the user's opacity setting. At 0% opacity only green
        -- fonts remain (backdrop is fully transparent).
        if anyReady then
            local alpha = (PVPHUB_SETTINGS and PVPHUB_SETTINGS.queueTimer and PVPHUB_SETTINGS.queueTimer.opacity) or 0.95
            local readyStyle = GetQueueTimerStyle()
            if readyStyle == "simple" or readyStyle == "compact" then
                self.frame:SetBackdropColor(0.03, 0.09, 0.03, alpha)
                self.frame:SetBackdropBorderColor(0.30, 0.85, 0.30, 0.45 * alpha)
                self.frame.headerBg:SetColorTexture(0, 0, 0, 0)
                self.frame.separator:SetColorTexture(0.30, 0.85, 0.30, 0.25 * alpha)
            else
                self.frame:SetBackdropColor(0.02, 0.14, 0.02, alpha)
                self.frame:SetBackdropBorderColor(0.15, 0.9, 0.15, alpha)
                self.frame.headerBg:SetColorTexture(0.04, 0.30, 0.04, 0.55 * alpha)
                self.frame.separator:SetColorTexture(0.2, 1, 0.2, 0.5 * alpha)
            end
        end
    end)
end

-- --------------------------------------------------------------------------
-- Show / Hide
-- --------------------------------------------------------------------------

function PVPHUB.QueueTimer:Show()
    if not self.frame then self:CreateFrame() end
    PVPHUB_SETTINGS = PVPHUB_SETTINGS or {}
    self.frame:Show()
    self:StartTick()
end

function PVPHUB.QueueTimer:Hide()
    self:StopTick()
    if self.frame then
        self.frame:Hide()
    end
end

-- --------------------------------------------------------------------------
-- Settings preview / test mode
-- --------------------------------------------------------------------------

-- Show a fake queue row so setting changes (size, opacity, etc.) are visible
-- without needing to be in an actual PvP queue.
function PVPHUB.QueueTimer:_ShowTestPreview()
    if not self.frame then self:CreateFrame() end

    self.frame.header:Hide()
    self.frame.separator:Hide()
    self.frame.body:ClearAllPoints()
    self.frame.body:SetPoint("TOPLEFT",     self.frame, "TOPLEFT",     3, -3)
    self.frame.body:SetPoint("BOTTOMRIGHT", self.frame, "BOTTOMRIGHT", -3,  3)
    local r1 = self.frame.slotRows[1]
    if r1 then
        r1:ClearAllPoints()
        r1:SetPoint("TOPLEFT",  self.frame.body, "TOPLEFT",  0, 0)
        r1:SetPoint("TOPRIGHT", self.frame.body, "TOPRIGHT", 0, 0)
    end

    local row = self.frame.slotRows[1]
    if row then
        row.avgLabel:ClearAllPoints()
        local style = GetQueueTimerStyle()
        if style == "compact" then
            row.mmrLine:Hide()
            row.nameLabel:Hide()
            row.avgLabel:Hide()
            row.avgValue:Hide()
            row.inQLabel:Hide()
            row.inQValue:Hide()
            row.compactLine:Show()
            row.compactLine:SetText("|cffffd1002v2|r |cffaaaaaa(1850)|r   Avg 3m   Q 1:23")
        else
            row.compactLine:Hide()
            row.nameLabel:Show()
            row.avgLabel:Show()
            row.avgValue:Show()
            row.inQLabel:Show()
            row.inQValue:Show()
            if style == "simple" then
                row.nameLabel:SetText("2v2")
                row.mmrLine:SetText(string.format("MMR: 1850 %s 1875 |cff40ff40(+25)|r", ARROW_MARKUP))
                row.mmrLine:Show()
                row.avgLabel:SetPoint("TOPLEFT", row.mmrLine, "BOTTOMLEFT", 0, -3)
                row.avgLabel:SetText("Avg:")
                row.avgValue:SetText("3 min 12 sec")
                row.inQLabel:SetText("Q:")
                row.inQValue:SetText("1 min 23 sec")
            else
                row.mmrLine:Hide()
                row.avgLabel:SetPoint("TOPLEFT", row.nameLabel, "BOTTOMLEFT", 0, -3)
                row.nameLabel:SetText("2v2  |cffaaaaaa(1850 MMR)|r")
                row.avgLabel:SetText("Avg Wait:")
                row.avgValue:SetText("3 min")
                row.inQLabel:SetText("In Queue:")
                row.inQValue:SetText("1:23.")
            end
        end
        self:_ApplyRowColors(row, false)
        row.divider:Hide()
        row:Show()
    end

    for i = 2, #self.frame.slotRows do
        self.frame.slotRows[i]:Hide()
    end

    self.frame:Show()

    -- Deferred one frame so GetStringWidth()/GetStringHeight() reflect the
    -- text just set above rather than stale pre-update metrics (see Update()).
    C_Timer.After(0, function()
        if not self.frame or not row then return end
        row:SetHeight(ComputeRowHeight(row))
        self.frame:SetHeight(row:GetHeight() + 6)
        self:ApplyOpacity()
        ResizeToContent(self.frame)
    end)
end

-- Shows a single "no active queue" row so the widget can be positioned even
-- when nothing is queued. Uses a real slot row (the header is hidden by
-- Update(), so anything written there is invisible).
function PVPHUB.QueueTimer:_ShowPlaceholder()
    if not self.frame then self:CreateFrame() end
    local f = self.frame

    f.header:Hide()
    f.separator:Hide()
    f.body:ClearAllPoints()
    f.body:SetPoint("TOPLEFT",     f, "TOPLEFT",      3, -3)
    f.body:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -3,  3)

    local row = f.slotRows[1]
    if row then
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT",  f.body, "TOPLEFT",  0, 0)
        row:SetPoint("TOPRIGHT", f.body, "TOPRIGHT", 0, 0)
        row.currentDisplayName = nil
        row.mmrLine:Hide()
        row.nameLabel:Hide()
        row.avgLabel:Hide()
        row.avgValue:Hide()
        row.inQLabel:Hide()
        row.inQValue:Hide()
        row.divider:Hide()
        row.compactLine:Show()
        row.compactLine:SetText("|cffaaaaaaNo active queue|r")
        self:_ApplyRowColors(row, false)
        row:Show()
    end
    for i = 2, #f.slotRows do f.slotRows[i]:Hide() end

    f:Show()
    C_Timer.After(0, function()
        if not self.frame or not row then return end
        row:SetHeight(ComputeRowHeight(row))
        self.frame:SetHeight(row:GetHeight() + 6)
        self:ApplyOpacity()
        ResizeToContent(self.frame)
    end)
end

-- Play the configured match-ready sound at the current volume setting.
function PVPHUB.QueueTimer:PlayReadySound()
    PlayMatchReadySound()
end

-- Toggle preview mode on/off. Returns the new state (true = preview active).
function PVPHUB.QueueTimer:TogglePreview()
    self._testMode = not self._testMode

    if self._testMode then
        if PVPHUB_SETTINGS and PVPHUB_SETTINGS.queueTimerEnabled == false then
            -- Temporarily allow show even if the master toggle is off,
            -- so the user can still preview the widget visually.
            self._previewOverride = true
        end
        if not self.frame then self:CreateFrame() end
        self:_ShowTestPreview()
        self:StartTick()
    else
        self._previewOverride = nil
        -- Only hide if there is no real queue active
        local hasRealQueue = false
        local maxSlots = PVPHUB.Compat.GetMaxBattlefieldQueues()
        for i = 1, maxSlots do
            local status = GetBattlefieldStatus(i)
            if status == "confirm" or status == "queued" then
                hasRealQueue = true
                break
            end
        end
        if not hasRealQueue then
            self:StopTick()
            if self.frame then self.frame:Hide() end
        end
    end

    return self._testMode
end

-- Called when settings close; ensures preview is cleaned up.
function PVPHUB.QueueTimer:StopPreview()
    if self._testMode then
        self._testMode      = false
        self._previewOverride = nil
        local hasRealQueue  = false
        local maxSlots      = PVPHUB.Compat.GetMaxBattlefieldQueues()
        for i = 1, maxSlots do
            local status = GetBattlefieldStatus(i)
            if status == "confirm" or status == "queued" then
                hasRealQueue = true
                break
            end
        end
        if not hasRealQueue then
            self:StopTick()
            if self.frame then self.frame:Hide() end
        end
    end
end

-- --------------------------------------------------------------------------
-- Per-second ticker
-- --------------------------------------------------------------------------

function PVPHUB.QueueTimer:StartTick()
    if self.ticker then return end
    self.ticker = C_Timer.NewTicker(1, function()
        PVPHUB.QueueTimer:Update()
    end)
end

function PVPHUB.QueueTimer:StopTick()
    if self.ticker then
        self.ticker:Cancel()
        self.ticker = nil
    end
end

-- --------------------------------------------------------------------------
-- Event handling
-- --------------------------------------------------------------------------

local queueEventFrame = CreateFrame("Frame")
queueEventFrame:RegisterEvent("ADDON_LOADED")
queueEventFrame:RegisterEvent("UPDATE_BATTLEFIELD_STATUS")
queueEventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")

queueEventFrame:SetScript("OnEvent", function(self, event, arg1)
    -- Protect against addon conflicts and taint issues (mirrors PVPHUB.frame's
    -- main handler in PVPHUB_core.lua) so one bad event doesn't spam Lua errors.
    local success, errorMsg = pcall(function()
    if event == "PLAYER_ENTERING_WORLD" then
        -- Hide the queue timer immediately when zoning into a PvP instance.
        -- UPDATE_BATTLEFIELD_STATUS fires during zone-in with a 0.05 s delay, so
        -- IsInInstance() may not have updated yet when that callback runs, causing
        -- the timer to briefly appear and then vanish — the visible "flash" the user
        -- sees when loading into arena.  Hiding synchronously here closes that window.
        local inInstance, instanceType = IsInInstance()
        if inInstance and (instanceType == "pvp" or instanceType == "arena") then
            PVPHUB.QueueTimer:StopTick()
            if PVPHUB.QueueTimer.frame then
                PVPHUB.QueueTimer.frame:Hide()
            end
        end

        -- Re-resolve the font family here too, not just at ADDON_LOADED/creation.
        -- If the selected font is a LibSharedMedia font registered by a DIFFERENT
        -- addon, that addon's own ADDON_LOADED (which is when it registers with
        -- LSM) isn't guaranteed to have already run by the time ours fires and
        -- CreateFrame()/_ScaleFonts() resolves the font the first time - so it can
        -- silently fall back to the default font until something re-resolves it.
        -- PLAYER_ENTERING_WORLD fires once everyone's ADDON_LOADED has already run,
        -- so this is a safe, guaranteed-late point to correct that.
        if PVPHUB.QueueTimer.frame and PVPHUB.QueueTimer._ScaleFonts then
            PVPHUB.QueueTimer:_ScaleFonts()
        end

    elseif event == "ADDON_LOADED" and arg1 == "PVPHUB" then
        -- Build the locale-independent BG name map from the client's own BG list.
        -- Must be called after ADDON_LOADED so GetNumBattlegroundTypes is available.
        BuildBGNameMap()

        -- Create the frame now that saved variables are available.
        -- Defer ApplyTheme by one frame so PVPHUB_core.lua's ADDON_LOADED
        -- handler always runs first and populates currentColors with the
        -- correct saved theme before we paint the queue timer.
        PVPHUB.QueueTimer:CreateFrame()
        C_Timer.After(0, function()
            PVPHUB.QueueTimer:ApplyTheme()
        end)

        -- Initialise the enabled setting if not yet present
        PVPHUB_SETTINGS = PVPHUB_SETTINGS or {}
        if PVPHUB_SETTINGS.queueTimerEnabled == nil then
            PVPHUB_SETTINGS.queueTimerEnabled = true
        end
        if PVPHUB_SETTINGS.queueTimerScale == nil then
            PVPHUB_SETTINGS.queueTimerScale = 1.0
        end
        -- Initialise queue timer sub-settings
        if not PVPHUB_SETTINGS.queueTimer then
            PVPHUB_SETTINGS.queueTimer = {}
        end
        if PVPHUB_SETTINGS.queueTimer.opacity == nil then
            PVPHUB_SETTINGS.queueTimer.opacity = 0.95
        end
        if PVPHUB_SETTINGS.queueTimer.style == nil then
            PVPHUB_SETTINGS.queueTimer.style = "pvphub"
        end
        if PVPHUB_SETTINGS.queueTimer.fontOutline == nil then
            PVPHUB_SETTINGS.queueTimer.fontOutline = true
        end
        if PVPHUB_SETTINGS.queueTimer.hideInInstances == nil then
            PVPHUB_SETTINGS.queueTimer.hideInInstances = true
        end
        PVPHUB.QueueTimer:ApplyScale()
        WarnIfSFXVolumeLooksStuck()

        -- If somehow already queued when logging in, show immediately
        C_Timer.After(0.5, function()
            PVPHUB.QueueTimer:Update()
        end)

    elseif event == "UPDATE_BATTLEFIELD_STATUS" then
        -- Ensure frame exists before trying to update
        if not PVPHUB.QueueTimer.frame then
            PVPHUB.QueueTimer:CreateFrame()
        end

        C_Timer.After(0.05, function()
            -- Re-apply theme each time status updates (catches theme changes)
            PVPHUB.QueueTimer:ApplyTheme()
            PVPHUB.QueueTimer:Update()
        end)
    end
    end) -- End pcall

    if not success then
        print("|cffff0000[PVPHUB Error]|r Event handler error: " .. tostring(errorMsg))
    end
end)

-- --------------------------------------------------------------------------
-- Slash command integration  (/pvphub queue  or  /pvpqueue)
-- --------------------------------------------------------------------------

-- Toggles the same setting the Update() loop actually reads.
--
-- This used to write PVPHUB_SETTINGS.queueTimerHidden, which nothing ever read
-- back — so hiding the timer lasted only until the next UPDATE_BATTLEFIELD_STATUS
-- called Update() and showed it again. queueTimerEnabled is the flag Update()
-- checks, so the toggle now sticks (and stays in sync with the settings panel).
--
-- The "no active queue" branch also used to write into frame.nameLabel, which
-- lives in the header — and Update() hides the header unconditionally, so that
-- text was never visible. A real placeholder row is used instead.
SLASH_PVPHUBQUEUE1 = "/pvpqueue"
SlashCmdList["PVPHUBQUEUE"] = function()
    local QT = PVPHUB.QueueTimer
    if not QT.frame then QT:CreateFrame() end

    if PVPHUB_SETTINGS.queueTimerEnabled == false then
        PVPHUB_SETTINGS.queueTimerEnabled = true
        QT:Update()
        if not QT.frame:IsShown() then
            QT:_ShowPlaceholder()
        end
        print("|cffFFD100[PVPHUB]|r Queue timer enabled. Use /pvpqueue to toggle.")
    else
        PVPHUB_SETTINGS.queueTimerEnabled = false
        QT:Hide()
        print("|cffFFD100[PVPHUB]|r Queue timer hidden. Use /pvpqueue to bring it back.")
    end
end
