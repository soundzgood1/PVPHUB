-- PVPHUB - PvP Übersicht für alle Charaktere
-- core.lua

-- Constants and Configuration
local CURRENCY_IDS = {
    honor = 1792,
    conquest = 1602,
}

local BLOODY_TOKENS_ID = 2123
local BLOODSTONE_ITEM_ID = 215236

-- Color Themes
local COLOR_THEMES = {
    BLUE = {
        WINDOW_BG = {0.05, 0.08, 0.12, 0.95},
    COLUMN_WIDTHS = {
        character = 220,
        standard = 120,
        delete = 60
    },
    COLORS = {} -- Will be set by GetCurrentTheme()
}

local PVPHUB_CONSTANTS = {
    COMPACT_WINDOW = {
        BASE_WIDTH = 160, -- Width for character name column
        COLUMN_WIDTH = 85, -- Width per rating column (increased for better spacing)
        ROW_HEIGHT = 20,
        MIN_WIDTH = 200, -- Minimum window width
    }
}

local RATING_TIERS = {
    {rating = 2700, color = "|cffff69b4", name = "Elite"}, -- Pink
    {rating = 2400, color = "|cffff8000", name = "Gladiator"}, -- Orange
    {rating = 2100, color = "|cffa335ee", name = "Duelist"}, -- Purple
    {rating = 1800, color = "|cff0070dd", name = "Rival"}, -- Blue
    {rating = 0, color = "|cffffffff", name = "Unranked"} -- White for everything below 1800
}

local CURRENCY_TIER_COLORS = {
    {threshold = 0.95, color = "|cffff0000"},
    {threshold = 0.8, color = "|cffff8000"},
    {threshold = 0.6, color = "|cffffff00"},
    {threshold = 0.4, color = "|cff80ff00"},
    {threshold = 0, color = "|cff00ff00"}
}

local COLUMN_HEADERS = {
    { text = "Character", key = "character", icon = "" },
    { text = "|T1455894:14|t Honor", key = "honor" },
    { text = "|T1523630:14|t Conquest", key = "conquest" },
    { text = "|T134128:14|t Bloodstones", key = "bloodstones" },
    { text = "|TInterface\\Icons\\achievement_arena_2v2_1:14|t 2v2", key = "rating2v2" },
    { text = "|TInterface\\Icons\\achievement_arena_3v3_1:14|t 3v3", key = "rating3v3" },
    { text = "|TInterface\\Icons\\ability_dualwield:14|t Shuffle", key = "ratingShuffle" },
    { text = "|TInterface\\Icons\\achievement_bg_killxenemies_generalsroom:14|t Blitz", key = "ratingBlitz" },
    { text = "", key = "delete", hideHeader = true } -- No header for delete column
}

local PVP_BRACKETS = {
    { id = 1, key = "rating2v2" },
    { id = 2, key = "rating3v3" },
    { id = 7, key = "ratingShuffle" },
    { id = 9, key = "ratingBlitz" },
}

local DISPLAY_NAMES = {
    honor = "Honor",
    conquest = "Conquest",
    bloodstones = "Bloodstones",
    rating2v2 = "2v2",
    rating3v3 = "3v3",
    ratingShuffle = "Shuffle",
    ratingBlitz = "Blitz",
}

-- Global Variables
PVPHUB_DB = PVPHUB_DB or {}
PVPHUB_IGNORED = PVPHUB_IGNORED or {}
PVPHUB_SETTINGS = PVPHUB_SETTINGS or {
    visibleColumns = {
        character = true,
        honor = true,
        conquest = true,
        bloodstones = true,
        rating2v2 = true,
        rating3v3 = true,
        ratingShuffle = true,
        ratingBlitz = true,
        delete = true
    },
    compactMode = {
        enabled = false,
        selectedChars = {},
        showRatings = {
            rating2v2 = true,
            rating3v3 = true,
            ratingShuffle = true,
            ratingBlitz = false
        }
    },
    colorTheme = "RED", -- Default theme
    welcomeShown = false -- Track if welcome popup has been shown
}

local addonName, PVPHUB = ...
PVPHUB.selectedChar = nil
PVPHUB.frame = CreateFrame("Frame")

-- Utility Functions
local function GetCurrentTheme()
    local selectedTheme = PVPHUB_SETTINGS.colorTheme or "RED"
    return COLOR_THEMES[selectedTheme] or COLOR_THEMES.RED
end

local function ApplyTheme()
    UI_CONSTANTS.COLORS = GetCurrentTheme()
end

local function RefreshAllWindows()
    -- Refresh main window if it exists
    if PVPHUB.window then
        -- Update main window colors
        PVPHUB.window:SetBackdropColor(unpack(UI_CONSTANTS.COLORS.WINDOW_BG))
        PVPHUB.window:SetBackdropBorderColor(unpack(UI_CONSTANTS.COLORS.WINDOW_BORDER))
        
        -- Update glow frame if it exists
        local glowFrame = PVPHUB.window:GetChildren()
        for i = 1, select("#", PVPHUB.window:GetChildren()) do
            local child = select(i, PVPHUB.window:GetChildren())
            if child:GetObjectType() == "Frame" and child:GetBackdrop() then
                child:SetBackdropBorderColor(unpack(UI_CONSTANTS.COLORS.WINDOW_GLOW))
                break
            end
        end
        
        -- Update title color
        if PVPHUB.window.title then
            PVPHUB.window.title:SetTextColor(unpack(UI_CONSTANTS.COLORS.TITLE_COLOR))
        end
        
        -- Update scale buttons
        if PVPHUB.window.scaleButtons then
            for _, btn in ipairs(PVPHUB.window.scaleButtons) do
                if btn.scaleValue == PVPHUB.window.currentScale then
                    btn.bg:SetVertexColor(unpack(UI_CONSTANTS.COLORS.SCALE_BUTTON_SELECTED))
                else
                    btn.bg:SetVertexColor(unpack(UI_CONSTANTS.COLORS.SCALE_BUTTON_BG))
                end
            end
        end
        
        -- Update summary text color
        if PVPHUB.window.summaryText then
            PVPHUB.window.summaryText:SetTextColor(unpack(UI_CONSTANTS.COLORS.SUMMARY_TEXT))
        end
        
        -- Update theme dropdown text
        if PVPHUB.window.themeDropdown then
            local themeNames = { BLUE = "Blue", RED = "Red", DARK = "Dark", UNIVERSE = "Universe" }
            local currentTheme = PVPHUB_SETTINGS.colorTheme or "RED"
            UIDropDownMenu_SetText(PVPHUB.window.themeDropdown, themeNames[currentTheme] or "Theme")
        end
        
        -- Update decorative lines
        if PVPHUB.window.titleLine then
            PVPHUB.window.titleLine:SetVertexColor(unpack(UI_CONSTANTS.COLORS.ACCENT_LINE))
        end
        
        if PVPHUB.window.summaryTopLine then
            PVPHUB.window.summaryTopLine:SetVertexColor(unpack(UI_CONSTANTS.COLORS.SUMMARY_LINE))
        end
        
        -- Refresh content to update headers and row backgrounds
        if PVPHUB.window.UpdateContent then
            PVPHUB.window:UpdateContent()
        end
    end
    
    -- Refresh compact window if it exists
    if PVPHUB.compactWindow then
        PVPHUB.compactWindow:SetBackdropColor(unpack(UI_CONSTANTS.COLORS.COMPACT_BG))
        PVPHUB.compactWindow:SetBackdropBorderColor(unpack(UI_CONSTANTS.COLORS.COMPACT_BORDER))
        
        -- Update compact scale buttons
        if PVPHUB.compactWindow.scaleButtons then
            for _, btn in ipairs(PVPHUB.compactWindow.scaleButtons) do
                if btn.scaleValue == PVPHUB.compactWindow.currentScale then
                    btn.bg:SetVertexColor(unpack(UI_CONSTANTS.COLORS.SCALE_BUTTON_SELECTED))
                else
                    btn.bg:SetVertexColor(unpack(UI_CONSTANTS.COLORS.SCALE_BUTTON_BG))
                end
            end
        end
        
        -- Refresh compact window content
        if PVPHUB.UpdateCompactWindow then
            PVPHUB:UpdateCompactWindow()
        end
    end
    
    -- Refresh settings window if it exists
    if PVPHUB.compactSettingsWindow then
        PVPHUB.compactSettingsWindow:SetBackdropColor(unpack(UI_CONSTANTS.COLORS.SETTINGS_BG))
        PVPHUB.compactSettingsWindow:SetBackdropBorderColor(unpack(UI_CONSTANTS.COLORS.SETTINGS_BORDER))
        
        -- Update settings window title
        if PVPHUB.compactSettingsWindow.title then
            PVPHUB.compactSettingsWindow.title:SetTextColor(unpack(UI_CONSTANTS.COLORS.TITLE_COLOR))
        end
    end
end

-- Initialize theme immediately after function definition
ApplyTheme()

local function GetFullName()
    local name, realm = UnitName("player")
    realm = realm or GetRealmName()
    return name .. "-" .. realm
end

local function GetRatingColor(rating)
    -- Handle ratings below 1800 - all white
    if rating < 1800 then
        return "|cffffffff"
    end
    
    -- Find the appropriate tier and calculate gradient
    for i, tier in ipairs(RATING_TIERS) do
        if rating >= tier.rating then
            -- If we're at the highest tier or this is the last tier, use the tier color
            if i == 1 or i == #RATING_TIERS then
                return tier.color
            end
            
            -- Calculate gradient between this tier and the next one
            local nextTier = RATING_TIERS[i - 1]
            local progress = (rating - tier.rating) / (nextTier.rating - tier.rating)
            
            -- Extract RGB values from hex colors
            local function hexToRgb(colorStr)
                -- Extract the 6-character hex code from WoW color format "|cffRRGGBB"
                local hex = colorStr:match("|cff(%x%x%x%x%x%x)")
                if not hex or #hex ~= 6 then
                    -- Fallback to white if parsing fails
                    return 1, 1, 1
                end
                
                local r = tonumber(hex:sub(1, 2), 16) / 255
                local g = tonumber(hex:sub(3, 4), 16) / 255
                local b = tonumber(hex:sub(5, 6), 16) / 255
                return r, g, b
            end
            
            local r1, g1, b1 = hexToRgb(tier.color)
            local r2, g2, b2 = hexToRgb(nextTier.color)
            
            -- Linear interpolation
            local r = r1 + (r2 - r1) * progress
            local g = g1 + (g2 - g1) * progress
            local b = b1 + (b2 - b1) * progress
            
            -- Convert back to hex
            local function rgbToHex(r, g, b)
                return string.format("|cff%02x%02x%02x", 
                    math.floor(r * 255 + 0.5),
                    math.floor(g * 255 + 0.5),
                    math.floor(b * 255 + 0.5))
            end
            
            return rgbToHex(r, g, b)
        end
    end
    return "|cffffffff"
end

local function GetCurrencyColor(amount, currencyType)
    local currencyID = CURRENCY_IDS[currencyType]
    local cap = nil
    
    if currencyID then
        local currencyInfo = C_CurrencyInfo.GetCurrencyInfo(currencyID)
        if currencyInfo and currencyInfo.maxQuantity > 0 then
            cap = currencyInfo.maxQuantity
        end
    elseif currencyType == "bloodstones" then
        cap = 1000
    end
    
    if not cap or cap == 0 then
        return "|cffffffff"
    end
    
    local percentage = amount / cap
    for _, tier in ipairs(CURRENCY_TIER_COLORS) do
        if percentage >= tier.threshold then
            return tier.color
        end
    end
    return "|cffffffff"
end

-- Helper function to get spec info and shuffle ratings
local function GetShuffleDisplayInfo(data, charKey)
    local shuffleData = data.ratingShuffle
    
    -- Handle legacy single-rating format
    if type(shuffleData) == "number" then
        return shuffleData, nil, 1, shuffleData
    end
    
    -- Handle new multi-spec format
    if type(shuffleData) == "table" then
        local currentSpecRating = 0
        local highestRating = 0
        local specCount = 0
        local currentSpecID = data.specID or data.lastActiveSpecID
        local highestSpecID = nil
        local displaySpecID = currentSpecID
        
        -- Count specs and find highest rating (only count specs with rating > 0)
        for specID, rating in pairs(shuffleData) do
            if rating > 0 then
                specCount = specCount + 1
                if rating > highestRating then
                    highestRating = rating
                    highestSpecID = specID
                end
                
                -- Get current spec rating
                if specID == currentSpecID then
                    currentSpecRating = rating
                end
            end
        end
        
        -- If current spec has no rating or spec not found, fall back to highest rating
        if currentSpecRating == 0 and highestRating > 0 then
            currentSpecRating = highestRating
            displaySpecID = highestSpecID
        end
        
        return currentSpecRating, displaySpecID, specCount, highestRating
    end
    
    return 0, nil, 0, 0
end

local function CreateCharacterName(entry
    local data = entry.data
    local class = data.class or "PRIEST"
    local color = RAID_CLASS_COLORS[class] or NORMAL_FONT_COLOR
    
    -- Spec icon
    local specIcon = ""
    if data.specID then
        local _, _, _, icon = GetSpecializationInfoByID(data.specID)
        if icon then
            specIcon = "|T" .. icon .. ":14|t "
        end
    end
    
    local coloredName = string.format("%s|c%s%s|r", specIcon, color.colorStr or "ffffffff", entry.char)
    
    -- Add indicator for current character
    if entry.char == GetFullName() then
        coloredName = "|TInterface\\Common\\Indicator-Green:12|t " .. coloredName
    end
    
    return coloredName
end

-- Data Update Functions
local function UpdateCurrencyData()
    local charKey = GetFullName()
    print("[PVPHUB DEBUG] UpdateCurrencyData called for", charKey)
    if PVPHUB_IGNORED[charKey] then return end
    PVPHUB_DB[charKey] = PVPHUB_DB[charKey] or {}

    -- Update currencies
    for currencyType, id in pairs(CURRENCY_IDS) do
        local info = C_CurrencyInfo.GetCurrencyInfo(id)
        PVPHUB_DB[charKey][currencyType] = info and info.quantity or 0
        print("[PVPHUB DEBUG] Currency", currencyType, "=", PVPHUB_DB[charKey][currencyType])
    end

    -- Update bloody tokens
    local bloodyInfo = C_CurrencyInfo.GetCurrencyInfo(BLOODY_TOKENS_ID)
    PVPHUB_DB[charKey].bloodytokens = bloodyInfo and bloodyInfo.quantity or 0
    print("[PVPHUB DEBUG] Bloody tokens =", PVPHUB_DB[charKey].bloodytokens)

    -- Update bloodstones
    PVPHUB_DB[charKey].bloodstones = GetItemCount(BLOODSTONE_ITEM_ID) or 0
    print("[PVPHUB DEBUG] Bloodstones =", PVPHUB_DB[charKey].bloodstones)

    -- Update character info
    local specIndex = GetSpecialization()
    if specIndex then
        local specID = GetSpecializationInfo(specIndex)
        PVPHUB_DB[charKey].specID = specID
        -- Store the last active spec for shuffle rating display
        PVPHUB_DB[charKey].lastActiveSpecID = specID
    end

    local _, class = UnitClass("player")
    local race = select(2, UnitRace("player"))
    local gender = UnitSex("player")
    PVPHUB_DB[charKey].gender = gender
    PVPHUB_DB[charKey].class = class
    PVPHUB_DB[charKey].race = race
end

local function UpdatePvPRatings()
    local charKey = GetFullName()
    print("[PVPHUB DEBUG] UpdatePvPRatings called for", charKey)
    PVPHUB_DB[charKey] = PVPHUB_DB[charKey] or {}

    for _, bracket in ipairs(PVP_BRACKETS) do
        local rating = GetPersonalRatedInfo(bracket.id)
        rating = rating or 0

        -- Fallback for Solo Shuffle
        if bracket.id == 4 and rating == 0 and C_PvP.GetSoloShufflePersonalRating then
            local fallback = C_PvP.GetSoloShufflePersonalRating()
            if fallback and fallback > 0 then
                rating = fallback
            end
        end

        -- Special handling for Solo Shuffle (bracket.id == 7) to store per-spec
        if bracket.key == "ratingShuffle" then
            local currentSpecID = PVPHUB_DB[charKey].specID
            if currentSpecID then
                -- Initialize as table if it doesn't exist or is a number
                if type(PVPHUB_DB[charKey][bracket.key]) ~= "table" then
                    PVPHUB_DB[charKey][bracket.key] = {}
                end
                
                -- Store rating for current spec (including 0)
                PVPHUB_DB[charKey][bracket.key][currentSpecID] = rating
                print("[PVPHUB DEBUG] PvP rating for Shuffle (spec", currentSpecID, ") =", rating)
            elseif not PVPHUB_DB[charKey][bracket.key] then
                -- Initialize as empty table if nothing exists
                PVPHUB_DB[charKey][bracket.key] = {}
            end
        else
            -- Regular brackets store single rating
            PVPHUB_DB[charKey][bracket.key] = rating
            print("[PVPHUB DEBUG] PvP rating for", bracket.key, "=", rating)
        end
    end

    -- Print update message
    if not PVPHUB.lastRatingUpdate or PVPHUB.lastRatingUpdate ~= charKey then
        local _, class = UnitClass("player")
        local color = RAID_CLASS_COLORS[class] or NORMAL_FONT_COLOR
        local coloredName = string.format("|c%s%s|r", color.colorStr or "ffffffff", charKey)
        print("|cffff0000[PVPHUB]|r PvP ratings updated for " .. coloredName)
        PVPHUB.lastRatingUpdate = charKey
    end
end

local function UpdateAllData()
    if PVPHUB.window and PVPHUB.window:IsShown() and PVPHUB.window.UpdateContent then
        PVPHUB.window:UpdateContent()
    end
    UpdateCurrencyData()
    C_Timer.After(4, UpdatePvPRatings)
end

PVPHUB.frame:RegisterEvent("PLAYER_LOGIN")
PVPHUB.frame:RegisterEvent("CURRENCY_DISPLAY_UPDATE")
PVPHUB.frame:RegisterEvent("PLAYER_ENTERING_WORLD")
PVPHUB.frame:RegisterEvent("PVP_RATED_STATS_UPDATE")
PVPHUB.frame:RegisterEvent("BAG_UPDATE_DELAYED")
PVPHUB.frame:RegisterEvent("BAG_UPDATE")
PVPHUB.frame:RegisterEvent("ADDON_LOADED")

PVPHUB.frame:SetScript("OnEvent", function(self, event, ...)
    print("[PVPHUB DEBUG] Event triggered:", event)
    if event == "ADDON_LOADED" then
        local addonName = ...
        if addonName == "PVPHUB" then
            -- Initialize settings if they don't exist
            PVPHUB_SETTINGS = PVPHUB_SETTINGS or {
                visibleColumns = {
                    character = true,
                    honor = true,
                    conquest = true,
                    bloodstones = true,
                    rating2v2 = true,
                    rating3v3 = true,
                    ratingShuffle = true,
                    ratingBlitz = true,
                    delete = true
                },
                compactMode = {
                    enabled = false,
                    selectedChars = {},
                    showRatings = {
                        rating2v2 = true,
                        rating3v3 = true,
                        ratingShuffle = true,
                        ratingBlitz = false
                    }
                },
                colorTheme = "RED", -- Default theme
                welcomeShown = false -- Track if welcome popup has been shown
            }
            -- Ensure colorTheme exists (for backwards compatibility)
            if not PVPHUB_SETTINGS.colorTheme then
                PVPHUB_SETTINGS.colorTheme = "RED"
            end
            -- Apply the selected theme
            ApplyTheme()
            RefreshAllWindows()
            -- Ensure compactMode exists (for backwards compatibility)
            if not PVPHUB_SETTINGS.compactMode then
                PVPHUB_SETTINGS.compactMode = {
                    enabled = false,
                    selectedChars = {},
                    showRatings = {
                        rating2v2 = true,
                        rating3v3 = true,
                        ratingShuffle = true,
                        ratingBlitz = false
                    }
                }
            end
            -- Ensure all columns exist in settings (for backwards compatibility)
            local defaultColumns = {
                character = true,
                honor = true,
                conquest = true,
                bloodstones = true,
                rating2v2 = true,
                rating3v3 = true,
                ratingShuffle = true,
                ratingBlitz = true,
                delete = true
            }
            for column, default in pairs(defaultColumns) do
                if PVPHUB_SETTINGS.visibleColumns[column] == nil then
                    PVPHUB_SETTINGS.visibleColumns[column] = default
                end
            end
            -- Check for first-time user and show welcome popup
            if not PVPHUB_SETTINGS.welcomeShown then
                -- Delay the popup slightly to ensure UI is loaded
                C_Timer.After(1, function()
                    PVPHUB:ShowWelcomePopup()
                end)
            end
            -- Check for first-time user (welcome popup)
            if not PVPHUB_SETTINGS.welcomeShown then
                PVPHUB:ShowWelcomePopup()
            end
        end
    elseif event == "BAG_UPDATE" or event == "CURRENCY_DISPLAY_UPDATE" then
        print("[PVPHUB DEBUG] Handling BAG_UPDATE or CURRENCY_DISPLAY_UPDATE")
        UpdateCurrencyData()
        if PVPHUB.window and PVPHUB.window:IsShown() and PVPHUB.window.UpdateContent then
            print("[PVPHUB DEBUG] Updating main window content after currency/item update")
            PVPHUB.window:UpdateContent()
        end
        if PVPHUB.compactWindow and PVPHUB.compactWindow:IsShown() and PVPHUB.UpdateCompactWindow then
            print("[PVPHUB DEBUG] Updating compact window content after currency/item update")
            PVPHUB:UpdateCompactWindow()
        end
    elseif event == "PVP_RATED_STATS_UPDATE" then
        print("[PVPHUB DEBUG] Handling PVP_RATED_STATS_UPDATE")
        UpdatePvPRatings()
        if PVPHUB.window and PVPHUB.window:IsShown() and PVPHUB.window.UpdateContent then
            print("[PVPHUB DEBUG] Updating main window content after PvP rating update")
            PVPHUB.window:UpdateContent()
        end
        if PVPHUB.compactWindow and PVPHUB.compactWindow:IsShown() and PVPHUB.UpdateCompactWindow then
            print("[PVPHUB DEBUG] Updating compact window content after PvP rating update")
            PVPHUB:UpdateCompactWindow()
        end
    else
        print("[PVPHUB DEBUG] Handling other event:", event)
        UpdateAllData()
        if PVPHUB.window and PVPHUB.window:IsShown() and PVPHUB.window.UpdateContent then
            print("[PVPHUB DEBUG] Updating main window content after UpdateAllData")
            PVPHUB.window:UpdateContent()
        end
        if PVPHUB.compactWindow and PVPHUB.compactWindow:IsShown() and PVPHUB.UpdateCompactWindow then
            print("[PVPHUB DEBUG] Updating compact window content after UpdateAllData")
            PVPHUB:UpdateCompactWindow()
        end
    end
end)

-- Add debug prints to UpdateCurrencyData
local function UpdateCurrencyData()
    local charKey = GetFullName()
    print("[PVPHUB DEBUG] UpdateCurrencyData called for", charKey)
    if PVPHUB_IGNORED[charKey] then return end
    PVPHUB_DB[charKey] = PVPHUB_DB[charKey] or {}

    -- Update currencies
    for currencyType, id in pairs(CURRENCY_IDS) do
        local info = C_CurrencyInfo.GetCurrencyInfo(id)
        PVPHUB_DB[charKey][currencyType] = info and info.quantity or 0
        print("[PVPHUB DEBUG] Currency", currencyType, "=", PVPHUB_DB[charKey][currencyType])
    end

    -- Update bloody tokens
    local bloodyInfo = C_CurrencyInfo.GetCurrencyInfo(BLOODY_TOKENS_ID)
    PVPHUB_DB[charKey].bloodytokens = bloodyInfo and bloodyInfo.quantity or 0
    print("[PVPHUB DEBUG] Bloody tokens =", PVPHUB_DB[charKey].bloodytokens)

    -- Update bloodstones
    PVPHUB_DB[charKey].bloodstones = GetItemCount(BLOODSTONE_ITEM_ID) or 0
    print("[PVPHUB DEBUG] Bloodstones =", PVPHUB_DB[charKey].bloodstones)

    -- Update character info
    local specIndex = GetSpecialization()
    if specIndex then
        local specID = GetSpecializationInfo(specIndex)
        PVPHUB_DB[charKey].specID = specID
        -- Store the last active spec for shuffle rating display
        PVPHUB_DB[charKey].lastActiveSpecID = specID
    end

    local _, class = UnitClass("player")
    local race = select(2, UnitRace("player"))
    local gender = UnitSex("player")
    PVPHUB_DB[charKey].gender = gender
    PVPHUB_DB[charKey].class = class
    PVPHUB_DB[charKey].race = race
end

-- Add debug prints to UpdatePvPRatings
local function UpdatePvPRatings()
    local charKey = GetFullName()
    print("[PVPHUB DEBUG] UpdatePvPRatings called for", charKey)
    PVPHUB_DB[charKey] = PVPHUB_DB[charKey] or {}

    for _, bracket in ipairs(PVP_BRACKETS) do
        local rating = GetPersonalRatedInfo(bracket.id)
        rating = rating or 0

        -- Fallback for Solo Shuffle
        if bracket.id == 4 and rating == 0 and C_PvP.GetSoloShufflePersonalRating then
            local fallback = C_PvP.GetSoloShufflePersonalRating()
            if fallback and fallback > 0 then
                rating = fallback
            end
        end

        -- Special handling for Solo Shuffle (bracket.id == 7) to store per-spec
        if bracket.key == "ratingShuffle" then
            local currentSpecID = PVPHUB_DB[charKey].specID
            if currentSpecID then
                -- Initialize as table if it doesn't exist or is a number
                if type(PVPHUB_DB[charKey][bracket.key]) ~= "table" then
                    PVPHUB_DB[charKey][bracket.key] = {}
                end
                
                -- Store rating for current spec (including 0)
                PVPHUB_DB[charKey][bracket.key][currentSpecID] = rating
                print("[PVPHUB DEBUG] PvP rating for Shuffle (spec", currentSpecID, ") =", rating)
            elseif not PVPHUB_DB[charKey][bracket.key] then
                -- Initialize as empty table if nothing exists
                PVPHUB_DB[charKey][bracket.key] = {}
            end
        else
            -- Regular brackets store single rating
            PVPHUB_DB[charKey][bracket.key] = rating
            print("[PVPHUB DEBUG] PvP rating for", bracket.key, "=", rating)
        end
    end

    -- Print update message
    if not PVPHUB.lastRatingUpdate or PVPHUB.lastRatingUpdate ~= charKey then
        local _, class = UnitClass("player")
        local color = RAID_CLASS_COLORS[class] or NORMAL_FONT_COLOR
        local coloredName = string.format("|c%s%s|r", color.colorStr or "ffffffff", charKey)
        print("|cffff0000[PVPHUB]|r PvP ratings updated for " .. coloredName)
        PVPHUB.lastRatingUpdate = charKey
    end
end

local function UpdateAllData()
    if PVPHUB.window and PVPHUB.window:IsShown() and PVPHUB.window.UpdateContent then
        PVPHUB.window:UpdateContent()
    end
    UpdateCurrencyData()
    C_Timer.After(4, UpdatePvPRatings)
end

PVPHUB.frame:RegisterEvent("PLAYER_LOGIN")
PVPHUB.frame:RegisterEvent("CURRENCY_DISPLAY_UPDATE")
PVPHUB.frame:RegisterEvent("PLAYER_ENTERING_WORLD")
PVPHUB.frame:RegisterEvent("PVP_RATED_STATS_UPDATE")
PVPHUB.frame:RegisterEvent("BAG_UPDATE_DELAYED")
PVPHUB.frame:RegisterEvent("BAG_UPDATE")
PVPHUB.frame:RegisterEvent("ADDON_LOADED")

PVPHUB.frame:SetScript("OnEvent", function(self, event, ...)
    print("[PVPHUB DEBUG] Event triggered:", event)
    if event == "ADDON_LOADED" then
        local addonName = ...
        if addonName == "PVPHUB" then
            -- Initialize settings if they don't exist
            PVPHUB_SETTINGS = PVPHUB_SETTINGS or {
                visibleColumns = {
                    character = true,
                    honor = true,
                    conquest = true,
                    bloodstones = true,
                    rating2v2 = true,
                    rating3v3 = true,
                    ratingShuffle = true,
                    ratingBlitz = true,
                    delete = true
                },
                compactMode = {
                    enabled = false,
                    selectedChars = {},
                    showRatings = {
                        rating2v2 = true,
                        rating3v3 = true,
                        ratingShuffle = true,
                        ratingBlitz = false
                    }
                },
                colorTheme = "RED", -- Default theme
                welcomeShown = false -- Track if welcome popup has been shown
            }
            -- Ensure colorTheme exists (for backwards compatibility)
            if not PVPHUB_SETTINGS.colorTheme then
                PVPHUB_SETTINGS.colorTheme = "RED"
            end
            -- Apply the selected theme
            ApplyTheme()
            RefreshAllWindows()
            -- Ensure compactMode exists (for backwards compatibility)
            if not PVPHUB_SETTINGS.compactMode then
                PVPHUB_SETTINGS.compactMode = {
                    enabled = false,
                    selectedChars = {},
                    showRatings = {
                        rating2v2 = true,
                        rating3v3 = true,
                        ratingShuffle = true,
                        ratingBlitz = false
                    }
                }
            end
            -- Ensure all columns exist in settings (for backwards compatibility)
            local defaultColumns = {
                character = true,
                honor = true,
                conquest = true,
                bloodstones = true,
                rating2v2 = true,
                rating3v3 = true,
                ratingShuffle = true,
                ratingBlitz = true,
                delete = true
            }
            for column, default in pairs(defaultColumns) do
                if PVPHUB_SETTINGS.visibleColumns[column] == nil then
                    PVPHUB_SETTINGS.visibleColumns[column] = default
                end
            end
            -- Check for first-time user and show welcome popup
            if not PVPHUB_SETTINGS.welcomeShown then
                -- Delay the popup slightly to ensure UI is loaded
                C_Timer.After(1, function()
                    PVPHUB:ShowWelcomePopup()
                end)
            end
            -- Check for first-time user (welcome popup)
            if not PVPHUB_SETTINGS.welcomeShown then
                PVPHUB:ShowWelcomePopup()
            end
        end
    elseif event == "BAG_UPDATE" or event == "CURRENCY_DISPLAY_UPDATE" then
        print("[PVPHUB DEBUG] Handling BAG_UPDATE or CURRENCY_DISPLAY_UPDATE")
        UpdateCurrencyData()
        if PVPHUB.window and PVPHUB.window:IsShown() and PVPHUB.window.UpdateContent then
            print("[PVPHUB DEBUG] Updating main window content after currency/item update")
            PVPHUB.window:UpdateContent()
        end
        if PVPHUB.compactWindow and PVPHUB.compactWindow:IsShown() and PVPHUB.UpdateCompactWindow then
            print("[PVPHUB DEBUG] Updating compact window content after currency/item update")
            PVPHUB:UpdateCompactWindow()
        end
    elseif event == "PVP_RATED_STATS_UPDATE" then
        print("[PVPHUB DEBUG] Handling PVP_RATED_STATS_UPDATE")
        UpdatePvPRatings()
        if PVPHUB.window and PVPHUB.window:IsShown() and PVPHUB.window.UpdateContent then
            print("[PVPHUB DEBUG] Updating main window content after PvP rating update")
            PVPHUB.window:UpdateContent()
        end
        if PVPHUB.compactWindow and PVPHUB.compactWindow:IsShown() and PVPHUB.UpdateCompactWindow then
            print("[PVPHUB DEBUG] Updating compact window content after PvP rating update")
            PVPHUB:UpdateCompactWindow()
        end
    else
        print("[PVPHUB DEBUG] Handling other event:", event)
        UpdateAllData()
        if PVPHUB.window and PVPHUB.window:IsShown() and PVPHUB.window.UpdateContent then
            print("[PVPHUB DEBUG] Updating main window content after UpdateAllData")
            PVPHUB.window:UpdateContent()
        end
        if PVPHUB.compactWindow and PVPHUB.compactWindow:IsShown() and PVPHUB.UpdateCompactWindow then
            print("[PVPHUB DEBUG] Updating compact window content after UpdateAllData")
            PVPHUB:UpdateCompactWindow()
        end
    end
end)

SLASH_PVPHUB1 = "/pvphub"
SLASH_PVPHUB2 = "/pvphub streamer"
SLASH_PVPHUB3 = "/pvphub compact"
SlashCmdList["PVPHUB"] = function(msg
    local args = {strsplit(" ", msg or "")}
    local command = args[1] and string.lower(args[1]) or ""
    
    if command == "compact" or command == "streamer" then
        if PVPHUB.compactWindow and PVPHUB.compactWindow:IsShown() then
            PVPHUB.compactWindow:Hide()
        else
            PVPHUB:CreateCompactWindow()
        end
        return
    end
    
    if PVPHUB.window and PVPHUB.window:IsShown() then
        PVPHUB.window:Hide()
        return
    end

    if not PVPHUB.window then
        -- Always refresh data before showing window
        UpdateCurrencyData()
        UpdatePvPRatings()
        -- Create window frame
        local f = CreateFrame("Frame", "PVPHUBWindow", UIParent, "BackdropTemplate")
        
        -- Modern dark theme
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
        
        f:SetFrameStrata("DIALOG")
        f:SetSize(UI_CONSTANTS.WINDOW_WIDTH, UI_CONSTANTS.WINDOW_HEIGHT)
        f:SetPoint("CENTER")
        
        -- Add a subtle glow effect around the window
        local glowFrame = CreateFrame("Frame", nil, f, "BackdropTemplate")
        glowFrame:SetBackdrop({
            bgFile = "Interface\\Buttons\\WHITE8x8",
            edgeFile = "Interface\\Buttons\\WHITE8x8",
            tile = false,
            edgeSize = 8,
            insets = { left = -8, right = -8, top = -8, bottom = -8 }
        })
        glowFrame:SetBackdropColor(0, 0, 0, 0)
        glowFrame:SetBackdropBorderColor(unpack(UI_CONSTANTS.COLORS.WINDOW_GLOW)) -- Themed glow
        glowFrame:SetPoint("TOPLEFT", f, "TOPLEFT", -8, 8)
        glowFrame:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", 8, -8)
        glowFrame:SetFrameLevel(f:GetFrameLevel() - 1)

        -- Modern close button
        local closeButton = CreateFrame("Button", nil, f, "UIPanelCloseButton")
        closeButton:SetPoint("TOPRIGHT", f, "TOPRIGHT", -5, -5)

        -- Create scroll frame with classic WoW styling
        local scrollFrame = CreateFrame("ScrollFrame", "PVPHUBScrollFrame", f, "UIPanelScrollFrameTemplate")
        scrollFrame:SetPoint("TOPLEFT", f, "TOPLEFT", 20, -95) -- Adjusted for higher greeting
        scrollFrame:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -45, 55) -- Adjusted space for size buttons
        
        -- Keep the classic WoW scrollbar - remove custom styling
        -- The UIPanelScrollFrameTemplate already provides the classic look

        -- Create content frame inside scroll frame
        local contentFrame = CreateFrame("Frame", "PVPHUBContentFrame", scrollFrame)
        contentFrame:SetSize(UI_CONSTANTS.CONTENT_WIDTH, 1)
        scrollFrame:SetScrollChild(contentFrame)

        f.scrollFrame = scrollFrame
        f.contentFrame = contentFrame

        -- Initialize variables
        PVPHUB.sortKey = PVPHUB.sortKey or "highestRating"
        f.currentScale = 1.0
        f.scaleButtons = {}
        f.headers = {}
        f.rows = {}
        f.rowBackgrounds = {}

        -- Scale selection buttons (cleaned up positioning)
        -- Scale options
        local scaleOptions = {
            { text = "S", value = 0.75, tooltip = "Small (75%)" },
            { text = "M", value = 1.0, tooltip = "Medium (100%)" },
            { text = "L", value = 1.25, tooltip = "Large (125%)" },
            { text = "XL", value = 1.5, tooltip = "Extra Large (150%)" }
        }
        
        f.scaleButtons = {}
        f.currentScale = 1.0
        
        for i, option in ipairs(scaleOptions) do
            local btn = CreateFrame("Button", nil, f)
            btn:SetSize(24, 20)
            btn:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -120 + (i * 25), 17) -- Aligned with label
            
            -- Button background
            local bg = btn:CreateTexture(nil, "BACKGROUND")
            bg:SetAllPoints()
            bg:SetTexture("Interface\\Buttons\\WHITE8x8")
            bg:SetVertexColor(unpack(UI_CONSTANTS.COLORS.SCALE_BUTTON_BG))
            btn.bg = bg
            
            -- Button text
            local text = btn:CreateFontString(nil, "OVERLAY", "GameFontNormal")
            text:SetPoint("CENTER")
            text:SetText(option.text)
            text:SetTextColor(1, 0.8, 0.9, 1)
            text:SetFont("Fonts\\FRIZQT__.TTF", 10, "OUTLINE")
            btn.text = text
            
            -- Set initial state
            if option.value == f.currentScale then
                bg:SetVertexColor(unpack(UI_CONSTANTS.COLORS.SCALE_BUTTON_SELECTED)) -- Highlight current selection
                text:SetTextColor(1, 1, 1, 1)
            end
            
            btn.scaleValue = option.value
            btn.optionText = option.text
            
            -- Button interactions
            btn:SetScript("OnEnter", function(self)
                if self.scaleValue ~= f.currentScale then
                    self.bg:SetVertexColor(unpack(UI_CONSTANTS.COLORS.SCALE_BUTTON_HOVER)) -- Hover effect
                end
                GameTooltip:SetOwner(self, "ANCHOR_CURSOR")
                GameTooltip:SetText(option.tooltip, 1, 1, 1)
                GameTooltip:Show()
            end)
            
            btn:SetScript("OnLeave", function(self)
                if self.scaleValue ~= f.currentScale then
                    self.bg:SetVertexColor(unpack(UI_CONSTANTS.COLORS.SCALE_BUTTON_BG)) -- Normal state
                end
                GameTooltip:Hide()
            end)
            
            btn:SetScript("OnClick", function(self)
                -- Update all buttons to normal state
                for _, button in ipairs(f.scaleButtons) do
                    button.bg:SetVertexColor(unpack(UI_CONSTANTS.COLORS.SCALE_BUTTON_BG))
                    button.text:SetTextColor(1, 0.8, 0.9, 1)
                end
                
                -- Highlight selected button
                self.bg:SetVertexColor(unpack(UI_CONSTANTS.COLORS.SCALE_BUTTON_SELECTED))
                self.text:SetTextColor(1, 1, 1, 1)
                
                -- Apply scale
                f.currentScale = self.scaleValue
                f:SetScale(self.scaleValue)
                if f.UpdateContent then f:UpdateContent() end
            end)
            
            table.insert(f.scaleButtons, btn)
        end
        f:SetMovable(true)
        f:EnableMouse(true)
        f:RegisterForDrag("LeftButton")
        f:SetScript("OnDragStart", function(self)
            self:StartMoving()
        end)
        f:SetScript("OnDragStop", f.StopMovingOrSizing)

        -- Modern title with gradient effect
        f.title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
        f.title:SetPoint("TOPLEFT", f, "TOPLEFT", 15, -15)
        f.title:SetText("PVPHUB")
        f.title:SetFont("Fonts\\FRIZQT__.TTF", 22, "OUTLINE")
        f.title:SetTextColor(unpack(UI_CONSTANTS.COLORS.TITLE_COLOR))
        
        -- Author credit in top left corner
        f.author = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        f.author:SetPoint("TOPLEFT", f, "TOPLEFT", 15, -35)
        f.author:SetText("|cffBBBBBBby soundz|r")
        f.author:SetFont("Fonts\\FRIZQT__.TTF", 11, "OUTLINE")
        f.author:SetTextColor(0.7, 0.7, 0.7, 1) -- Subtle gray color
        
        -- Add greeting with BattleNet account name
        f.greeting = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        f.greeting:SetPoint("TOP", f, "TOP", 0, -35)
        f.greeting:SetFont("Fonts\\FRIZQT__.TTF", 16, "OUTLINE")
        
        -- Get BattleNet account name and class color
        local battleTag = select(2, BNGetInfo()) or ""
        local accountName = ""
        if battleTag and battleTag ~= "" then
            -- Extract name part before the # (e.g., "PlayerName#1234" -> "PlayerName")
            accountName = string.match(battleTag, "([^#]+)")
        end
        
        -- Get current character's class color
        local _, class = UnitClass("player")
        local classColor = RAID_CLASS_COLORS[class] or NORMAL_FONT_COLOR
        local colorStr = classColor.colorStr or "ffffffff"
        
        if accountName and accountName ~= "" then
            f.greeting:SetText("|c" .. colorStr .. "Welcome back, " .. accountName .. "!|r")
        else
            -- Fallback to character name if BattleTag not available
            local playerName = UnitName("player")
            f.greeting:SetText("|c" .. colorStr .. "Welcome back, " .. (playerName or "Champion") .. "!|r")
        end
        
        -- Add a subtle line under the greeting
        local titleLine = f:CreateTexture(nil, "ARTWORK")
        titleLine:SetTexture("Interface\\Buttons\\WHITE8x8")
        titleLine:SetVertexColor(unpack(UI_CONSTANTS.COLORS.ACCENT_LINE))
        titleLine:SetSize(200, 2)
        titleLine:SetPoint("TOP", f.greeting, "BOTTOM", 0, -5)
        f.titleLine = titleLine



        local dropdown = CreateFrame("Frame", "PVPHUBSortDropdown", f, "UIDropDownMenuTemplate")
        dropdown:SetPoint("TOPRIGHT", f, "TOPRIGHT", -20, -10)
        UIDropDownMenu_SetWidth(dropdown, 140)
        -- Set dropdown text to the current sort option, always prefixed with 'Sort: '
        local sortDisplayNames = {
            highestRating = "Highest Rating",
            honor = "Honor",
            conquest = "Conquest",
            bloodstones = "Vicious Bloodstones",
            rating2v2 = "2v2 Rating",
            rating3v3 = "3v3 Rating",
            ratingShuffle = "Shuffle Rating",
            ratingBlitz = "Blitz Rating",
        }
        UIDropDownMenu_SetText(dropdown, "Sort: " .. (sortDisplayNames[PVPHUB.sortKey or "highestRating"] or "Sort by"))

        local function OnClick(self)
            PVPHUB.sortKey = self.value
            UIDropDownMenu_SetText(dropdown, "Sort: " .. (sortDisplayNames[self.value] or (self.value or "")))
            if PVPHUB.window and PVPHUB.window.UpdateContent then
                PVPHUB.window:UpdateContent()
            end
        end

        UIDropDownMenu_Initialize(dropdown, function(self, level, menuList)
            for _, option in ipairs({
                { text = "Highest Rating",      value = "highestRating" },
                { text = "Honor",               value = "honor" },
                { text = "Conquest",            value = "conquest" },
                { text = "Vicious Bloodstones", value = "bloodstones" },
                { text = "2v2 Rating",          value = "rating2v2" },
                { text = "3v3 Rating",          value = "rating3v3" },
                { text = "Shuffle Rating",      value = "ratingShuffle" },
                { text = "Blitz Rating",        value = "ratingBlitz" },
            }) do
                local info = UIDropDownMenu_CreateInfo()
                info.text = option.text
                info.value = option.value
                info.func = OnClick
                UIDropDownMenu_AddButton(info)
            end
        end)

        -- Streamer Mode Toggle Button (positioned close to scale buttons)
        local compactToggleBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
        compactToggleBtn:SetSize(110, 22)
        compactToggleBtn:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -150, 17) -- Positioned closer to scale buttons
        compactToggleBtn:SetText("Streamer Mode")
        compactToggleBtn:SetScript("OnClick", function()
            -- Hide main window and show compact window
            f:Hide()
            PVPHUB:CreateCompactWindow()
        end)
        compactToggleBtn:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_CURSOR")
            GameTooltip:SetText("Switch to Streamer Mode", 1, 1, 1)
            GameTooltip:AddLine("Opens a streamlined window perfect for streaming", 0.7, 0.7, 0.7, true)
            GameTooltip:Show()
        end)
        compactToggleBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

        -- Column Visibility Dropdown
        local columnDropdown = CreateFrame("Frame", "PVPHUBColumnDropdown", f, "UIDropDownMenuTemplate")
        columnDropdown:SetPoint("TOPRIGHT", f, "TOPRIGHT", -180, -10)
        UIDropDownMenu_SetWidth(columnDropdown, 140)
        UIDropDownMenu_SetText(columnDropdown, "Columns")

        -- Theme Selection Dropdown
        local themeDropdown = CreateFrame("Frame", "PVPHUBThemeDropdown", f, "UIDropDownMenuTemplate")
        themeDropdown:SetPoint("TOPRIGHT", f, "TOPRIGHT", -340, -10)
        UIDropDownMenu_SetWidth(themeDropdown, 120)
        
        -- Set current theme text with simplified names
        local themeNames = { BLUE = "Blue", RED = "Red", DARK = "Dark", UNIVERSE = "Universe" }
        local currentTheme = PVPHUB_SETTINGS.colorTheme or "RED"
        UIDropDownMenu_SetText(themeDropdown, themeNames[currentTheme] or "Theme")
        
        -- Store reference for refresh function
        f.themeDropdown = themeDropdown

        local function OnThemeSelect(self)
            PVPHUB_SETTINGS.colorTheme = self.value
            ApplyTheme()
            RefreshAllWindows()
            
            -- Show brief confirmation message
            print("|cffff0000[PVPHUB]|r Theme changed to " .. self.value .. "!")
        end

        UIDropDownMenu_Initialize(themeDropdown, function(self, level, menuList)
            local themes = {
                { text = "Blue", value = "BLUE" },
                { text = "Red", value = "RED" },
                { text = "Dark", value = "DARK" },
                { text = "Universe", value = "UNIVERSE" },
            }
            
            for _, theme in ipairs(themes) do
                local info = UIDropDownMenu_CreateInfo()
                info.text = theme.text
                info.value = theme.value
                info.func = OnThemeSelect
                info.checked = PVPHUB_SETTINGS.colorTheme == theme.value
                UIDropDownMenu_AddButton(info)
            end
        end)

        local function OnColumnToggle(self)
            PVPHUB_SETTINGS.visibleColumns[self.value] = not PVPHUB_SETTINGS.visibleColumns[self.value]
            if PVPHUB.window and PVPHUB.window.UpdateContent then
                PVPHUB.window:UpdateContent()
            end
        end

        UIDropDownMenu_Initialize(columnDropdown, function(self, level, menuList)
            local columns = {
                { text = "Character",     value = "character",     alwaysVisible = true },
                { text = "Honor",         value = "honor" },
                { text = "Conquest",      value = "conquest" },
                { text = "Bloodstones",   value = "bloodstones" },
                { text = "2v2 Rating",    value = "rating2v2" },
                { text = "3v3 Rating",    value = "rating3v3" },
                { text = "Shuffle Rating", value = "ratingShuffle" },
                { text = "Blitz Rating",  value = "ratingBlitz" },
                { text = "Delete",        value = "delete",        alwaysVisible = true },
            }
            
            for _, column in ipairs(columns) do
                local info = UIDropDownMenu_CreateInfo()
                info.text = column.text
                info.value = column.value
                info.func = column.alwaysVisible and nil or OnColumnToggle
                info.checked = PVPHUB_SETTINGS.visibleColumns[column.value]
                info.isNotRadio = true
                info.keepShownOnClick = true
                info.disabled = column.alwaysVisible
                UIDropDownMenu_AddButton(info)
            end
        end)

        -- Initialize headers with dynamic positioning  
        local visibleHeaders = {}
        f.xOffsets = {}
        local currentOffset = 30
        
        for _, header in ipairs(COLUMN_HEADERS) do
            if PVPHUB_SETTINGS.visibleColumns[header.key] then
                table.insert(visibleHeaders, header)
                table.insert(f.xOffsets, currentOffset)
                
                if header.key == "character" then
                    currentOffset = currentOffset + UI_CONSTANTS.COLUMN_WIDTHS.character
                elseif header.key == "delete" then
                    currentOffset = currentOffset + UI_CONSTANTS.COLUMN_WIDTHS.delete
                else
                    currentOffset = currentOffset + UI_CONSTANTS.COLUMN_WIDTHS.standard
                end
            end
        end

        f.headers = {}
        for i, header in ipairs(visibleHeaders) do
            -- Skip creating header for delete column
            if not header.hideHeader then
                local h = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
                h:SetPoint("TOPLEFT", f, "TOPLEFT", f.xOffsets[i], -80)
                h:SetTextColor(1, 0.85, 0.1)
                h:SetText(header.text)
                table.insert(f.headers, h)
            end
        end

        function f:UpdateContent()
            -- Clear existing UI elements
            for _, element in ipairs({f.rows, f.rowBackgrounds}) do
                if element then
                    for _, item in ipairs(element) do
                        if item.Hide then item:Hide() end
                        if item.SetParent then item:SetParent(nil) end
                    end
                end
            end
            f.rows = {}
            f.rowBackgrounds = {}
            
            -- Clear children from content frame
            local children = {f.contentFrame:GetChildren()}
            for _, child in ipairs(children) do
                if child.Hide then child:Hide() end
                if child.SetParent then child:SetParent(nil) end
            end

            -- Recreate headers dynamically
            if f.headers then 
                for _, h in ipairs(f.headers) do 
                    h:Hide() 
                    h:SetParent(nil)
                end 
            end
            f.headers = {}
            
            -- Create dynamic headers and calculate offsets
            local visibleHeaders = {}
            f.xOffsets = {}
            local currentOffset = 30
            
            for _, header in ipairs(COLUMN_HEADERS) do
                if PVPHUB_SETTINGS.visibleColumns[header.key] then
                    table.insert(visibleHeaders, header)
                    table.insert(f.xOffsets, currentOffset)
                    
                    if header.key == "character" then
                        currentOffset = currentOffset + UI_CONSTANTS.COLUMN_WIDTHS.character
                    elseif header.key == "delete" then
                        currentOffset = currentOffset + UI_CONSTANTS.COLUMN_WIDTHS.delete
                    else
                        currentOffset = currentOffset + UI_CONSTANTS.COLUMN_WIDTHS.standard
                    end
                end
            end

            -- Create headers with modern styling
            for i, header in ipairs(visibleHeaders) do
                -- Skip creating header for delete column
                if not header.hideHeader then
                    local h = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
                    h:SetPoint("TOPLEFT", f, "TOPLEFT", f.xOffsets[i], -80)
                    h:SetTextColor(unpack(UI_CONSTANTS.COLORS.HEADER_COLOR))
                    h:SetText(header.text)
                    h:SetFont("Fonts\\FRIZQT__.TTF", 14, "OUTLINE")
                    table.insert(f.headers, h)
                    
                    -- Add header separator line
                    local headerLine = f:CreateTexture(nil, "ARTWORK")
                    headerLine:SetTexture("Interface\\Buttons\\WHITE8x8")
                    headerLine:SetVertexColor(unpack(UI_CONSTANTS.COLORS.HEADER_LINE))
                    headerLine:SetSize(100, 1)
                    headerLine:SetPoint("TOPLEFT", h, "BOTTOMLEFT", 0, -3)
                    table.insert(f.headers, headerLine)
                end
            end

            -- Sort and prepare character data
            local sortKey = PVPHUB.sortKey or "honor"
            local sorted = {}
            for char, data in pairs(PVPHUB_DB) do
                if type(data) == "table" then
                    table.insert(sorted, { char = char, data = data })
                end
            end
            table.sort(sorted, function(a, b)
                local function getHighestRating(entry)
                    local d = entry.data
                    local maxRating = 0
                    -- Consider all rating brackets
                    for _, k in ipairs({"rating2v2", "rating3v3", "ratingBlitz"}) do
                        if type(d[k]) == "number" and d[k] > maxRating then
                            maxRating = d[k]
                        end
                    end
                    -- Handle Shuffle (can be table or number)
                    local shuffle = d.ratingShuffle
                    if type(shuffle) == "number" then
                        if shuffle > maxRating then maxRating = shuffle end
                    elseif type(shuffle) == "table" then
                        for _, v in pairs(shuffle) do
                            if v > maxRating then maxRating = v end
                        end
                    end
                    return maxRating
                end
                if sortKey == "highestRating" then
                    return getHighestRating(a) > getHighestRating(b)
                else
                    local aVal = a.data[sortKey]
                    local bVal = b.data[sortKey]
                    -- Handle shuffle rating sorting
                    if sortKey == "ratingShuffle" then
                        if type(aVal) == "table" then
                            local maxA = 0
                            for _, rating in pairs(aVal) do
                                if rating > maxA then maxA = rating end
                            end
                            aVal = maxA
                        end
                        if type(bVal) == "table" then
                            local maxB = 0
                            for _, rating in pairs(bVal) do
                                if rating > maxB then maxB = rating end
                            end
                            bVal = maxB
                        end
                    end
                    return (aVal or 0) > (bVal or 0)
                end
            end)

            local totalHonor, totalConquest = 0, 0
            local contentHeight = 0
            local currentChar = GetFullName()

            -- Create character rows
            for row, entry in ipairs(sorted) do
                local y = -(row * UI_CONSTANTS.ROW_HEIGHT)
                contentHeight = math.max(contentHeight, math.abs(y) + UI_CONSTANTS.ROW_HEIGHT)

                -- Create row background highlighting
                if entry.char == currentChar then
                    -- Current character highlighting
                    local currentBG = f.contentFrame:CreateTexture(nil, "ARTWORK")
                    currentBG:SetColorTexture(unpack(UI_CONSTANTS.COLORS.CURRENT_CHAR_BG))
                    currentBG:SetPoint("TOPLEFT", f.contentFrame, "TOPLEFT", 0, y)
                    currentBG:SetSize(UI_CONSTANTS.CONTENT_WIDTH, 24)
                    currentBG:SetDrawLayer("BACKGROUND")
                    table.insert(f.rowBackgrounds, currentBG)
                    
                    -- Add left border for current character
                    local leftBorder = f.contentFrame:CreateTexture(nil, "ARTWORK")
                    leftBorder:SetTexture("Interface\\Buttons\\WHITE8x8")
                    leftBorder:SetVertexColor(unpack(UI_CONSTANTS.COLORS.CURRENT_CHAR_BORDER))
                    leftBorder:SetPoint("TOPLEFT", f.contentFrame, "TOPLEFT", 0, y)
                    leftBorder:SetSize(3, 24)
                    leftBorder:SetDrawLayer("BACKGROUND", 1)
                    table.insert(f.rowBackgrounds, leftBorder)
                elseif PVPHUB.selectedChar == entry.char then
                    -- Selected character highlighting
                    local selBG = f.contentFrame:CreateTexture(nil, "ARTWORK")
                    selBG:SetColorTexture(unpack(UI_CONSTANTS.COLORS.SELECTED_CHAR_BG))
                    selBG:SetPoint("TOPLEFT", f.contentFrame, "TOPLEFT", 0, y)
                    selBG:SetSize(UI_CONSTANTS.CONTENT_WIDTH, 24)
                    selBG:SetDrawLayer("BACKGROUND")
                    table.insert(f.rowBackgrounds, selBG)
                end

                -- Create row data
                local data = entry.data
                local coloredName = CreateCharacterName(entry)
                
                local function coloredRating(val)
                    return string.format("%s%d|r", GetRatingColor(val), val)
                end
                
                local function coloredCurrency(val, currencyType)
                    return string.format("%s%d|r", GetCurrencyColor(val, currencyType), val)
                end
                
                -- Special handling for Shuffle ratings
                local function getShuffleDisplay(data, charKey)
                    local currentRating, currentSpecID, specCount, highestRating = GetShuffleDisplayInfo(data, charKey)
                    
                    -- Show current spec rating without icon (icon is already in character name)
                    local display = coloredRating(currentRating)
                    
                    -- Add indicator for multiple specs
                    if specCount > 1 then
                        display = display .. " |TInterface\\Common\\FavoritesIcon:12|t"
                    end
                    
                    return display
                end

                local allValues = {
                    { value = coloredName, key = "character" },
                    { value = coloredCurrency(data.honor or 0, "honor"), key = "honor" },
                    { value = coloredCurrency(data.conquest or 0, "conquest"), key = "conquest" },
                    { value = coloredCurrency(data.bloodstones or 0, "bloodstones"), key = "bloodstones" },
                    { value = coloredRating(data.rating2v2 or 0), key = "rating2v2" },
                    { value = coloredRating(data.rating3v3 or 0), key = "rating3v3" },
                    { value = getShuffleDisplay(data, entry.char), key = "ratingShuffle" },
                    { value = coloredRating(data.ratingBlitz or 0), key = "ratingBlitz" },
                    { value = "X", key = "delete" }
                }
                
                -- Filter values based on visible columns
                local values = {}
                for _, item in ipairs(allValues) do
                    if PVPHUB_SETTINGS.visibleColumns[item.key] then
                        table.insert(values, { value = item.value, key = item.key })
                    end
                end

                totalHonor = totalHonor + (data.honor or 0)
                totalConquest = totalConquest + (data.conquest or 0)

                -- Create hover highlight
                local hoverBG = f.contentFrame:CreateTexture(nil, "BACKGROUND")
                hoverBG:SetTexture("Interface\\Buttons\\WHITE8x8")
                hoverBG:SetVertexColor(unpack(UI_CONSTANTS.COLORS.HOVER_BG))
                hoverBG:SetPoint("TOPLEFT", f.contentFrame, "TOPLEFT", 0, y)
                hoverBG:SetSize(UI_CONSTANTS.CONTENT_WIDTH, 24)
                hoverBG:Hide()
                table.insert(f.rowBackgrounds, hoverBG)

                -- Create column content
                for i, item in ipairs(values) do
                    local val = item.value
                    local key = item.key
                    
                    local txt = f.contentFrame:CreateFontString(nil, "OVERLAY", "GameFontWhite")
                    txt:SetPoint("TOPLEFT", f.contentFrame, "TOPLEFT", f.xOffsets[i] - 20, y - 6)
                    txt:SetText(val)
                    txt:SetFont("Fonts\\FRIZQT__.TTF", 13, "OUTLINE")
                    
                    -- Create hover area
                    local hoverBtn = CreateFrame("Button", nil, f.contentFrame)
                    hoverBtn:SetPoint("TOPLEFT", f.contentFrame, "TOPLEFT", f.xOffsets[i] - 20, y)
                    
                    if key == "character" then
                        hoverBtn:SetSize(200, 24)
                    elseif key == "delete" then
                        hoverBtn:SetSize(40, 24)
                    else
                        hoverBtn:SetSize(100, 24)
                    end
                    
                    hoverBtn:SetFrameLevel(f.contentFrame:GetFrameLevel() + 5)
                    hoverBtn.charName = entry.char
                    
                    -- Hover scripts
                    hoverBtn:SetScript("OnEnter", function() 
                        hoverBG:Show()
                        -- Show tooltip only for shuffle ratings
                        if key == "ratingShuffle" then
                            local shuffleData = data.ratingShuffle
                            if type(shuffleData) == "table" then
                                local specCount = 0
                                local specsWithRating = {}
                                
                                -- Count specs with ratings > 0
                                for specID, rating in pairs(shuffleData) do
                                    if rating > 0 then
                                        specCount = specCount + 1
                                        table.insert(specsWithRating, {specID = specID, rating = rating})
                                    end
                                end
                                
                                -- Only show tooltip if there are multiple specs with ratings > 0
                                if specCount > 1 then
                                    GameTooltip:SetOwner(hoverBtn, "ANCHOR_CURSOR")
                                    GameTooltip:SetText(entry.char .. " - Solo Shuffle Ratings", 1, 1, 1)
                                    GameTooltip:AddLine(" ", 1, 1, 1) -- Empty line
                                    
                                    -- Sort by rating (highest first)
                                    table.sort(specsWithRating, function(a, b) return a.rating > b.rating end)
                                    
                                    -- Add each spec to tooltip
                                    for _, spec in ipairs(specsWithRating) do
                                        local specID, rating = spec.specID, spec.rating
                                        local _, specName, _, iconPath = GetSpecializationInfoByID(specID)
                                        
                                        if specName then
                                            local coloredRating = GetRatingColor(rating) .. rating .. "|r"
                                            local specIcon = iconPath and "|T" .. iconPath .. ":16|t " or ""
                                            
                                            -- Highlight current spec
                                            if specID == data.specID then
                                                GameTooltip:AddLine(specIcon .. specName .. ": " .. coloredRating .. " |cff00ff00(Current)|r", 1, 1, 1)
                                            else
                                                GameTooltip:AddLine(specIcon .. specName .. ": " .. coloredRating, 0.9, 0.9, 0.9)
                                            end
                                        end
                                    end
                                    
                                    GameTooltip:Show()
                                end
                            elseif type(shuffleData) == "number" and shuffleData > 0 then
                                -- Handle legacy single rating format
                                GameTooltip:SetOwner(hoverBtn, "ANCHOR_CURSOR")
                                GameTooltip:SetText(entry.char .. " - Solo Shuffle Rating", 1, 1, 1)
                                GameTooltip:AddLine(" ", 1, 1, 1) -- Empty line
                                
                                local coloredRating = GetRatingColor(shuffleData) .. shuffleData .. "|r"
                                local specIcon = ""
                                if data.specID then
                                    local _, _, _, iconPath = GetSpecializationInfoByID(data.specID)
                                    if iconPath then
                                        specIcon = "|T" .. iconPath .. ":16|t "
                                    end
                                end
                                
                                GameTooltip:AddLine(specIcon .. "Rating: " .. coloredRating, 1, 1, 1)
                                GameTooltip:Show()
                            end
                        end
                    end)
                    hoverBtn:SetScript("OnLeave", function() 
                        hoverBG:Hide()
                        GameTooltip:Hide()
                    end)
                    
                    -- Character selection
                    if key == "character" then
                        hoverBtn:SetScript("OnClick", function(self, button)
                            if button == "LeftButton" then
                                PVPHUB.selectedChar = self.charName
                                f:UpdateContent()
                            end
                        end)
                    end
                    
                    -- Delete button handling
                    if key == "delete" then
                        txt:SetText("")
                        
                        local deleteBtn = CreateFrame("Button", nil, f.contentFrame)
                        deleteBtn:SetPoint("TOPLEFT", f.contentFrame, "TOPLEFT", f.xOffsets[i] - 18, y - 1)
                        deleteBtn:SetSize(24, 24)
                        deleteBtn:SetFrameLevel(f.contentFrame:GetFrameLevel() + 10)
                        
                        deleteBtn:SetNormalTexture("Interface\\Buttons\\UI-Panel-MinimizeButton-Up")
                        deleteBtn:SetPushedTexture("Interface\\Buttons\\UI-Panel-MinimizeButton-Down")
                        deleteBtn:SetHighlightTexture("Interface\\Buttons\\UI-Panel-MinimizeButton-Highlight")
                        
                        deleteBtn.charName = entry.char
                        
                        deleteBtn:SetScript("OnClick", function(self, button)
                            if button == "LeftButton" then
                                local charToDelete = self.charName
                                local dialogName = "PVPHUB_REMOVE_CHARACTER_" .. GetTime()
                                StaticPopupDialogs[dialogName] = {
                                    text = "Remove character '" .. charToDelete .. "' from the list?",
                                    button1 = "Yes",
                                    button2 = "Cancel",
                                    OnAccept = function()
                                        PVPHUB_DB[charToDelete] = nil
                                        C_Timer.After(0.1, function()
                                            if f.UpdateContent then f:UpdateContent() end
                                        end)
                                    end,
                                    timeout = 0,
                                    whileDead = true,
                                    hideOnEscape = true,
                                    preferredIndex = 3,
                                }
                                StaticPopup_Show(dialogName)
                            end
                        end)
                        
                        hoverBtn:Hide()
                        deleteBtn:SetScript("OnEnter", function() hoverBG:Show() end)
                        deleteBtn:SetScript("OnLeave", function() hoverBG:Hide() end)
                    end

                    table.insert(f.rows, txt)
                end -- End of for i, item in ipairs(values) do
            end

            -- Set content frame height
            f.contentFrame:SetHeight(math.max(contentHeight, 100))

            -- Create/update summary
            if not f.summaryTopLine then
                f.summaryTopLine = f:CreateTexture(nil, "ARTWORK")
                f.summaryTopLine:SetTexture("Interface\\Buttons\\WHITE8x8")
                f.summaryTopLine:SetVertexColor(unpack(UI_CONSTANTS.COLORS.SUMMARY_LINE))
                f.summaryTopLine:SetSize(UI_CONSTANTS.CONTENT_WIDTH, 1)
                f.summaryTopLine:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 20, 47)
            else
                f.summaryTopLine:SetVertexColor(unpack(UI_CONSTANTS.COLORS.SUMMARY_LINE))
            end

            if not f.summaryText then
                f.summaryText = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
                f.summaryText:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 25, 27)
                f.summaryText:SetTextColor(unpack(UI_CONSTANTS.COLORS.SUMMARY_TEXT))
                f.summaryText:SetFont("Fonts\\FRIZQT__.TTF", 13, "OUTLINE")
            else
                -- Update summary text color when theme changes
                f.summaryText:SetTextColor(unpack(UI_CONSTANTS.COLORS.SUMMARY_TEXT))
            end
            
            local summaryColor = UI_CONSTANTS.COLORS.SUMMARY_TEXT
            local summaryColorHex = string.format("|cff%02x%02x%02x", 
                math.floor(summaryColor[1] * 255), 
                math.floor(summaryColor[2] * 255), 
                math.floor(summaryColor[3] * 255))
            f.summaryText:SetText(string.format("Total Honor: %s%d|r    Total Conquest: %s%d|r", 
                summaryColorHex, totalHonor, summaryColorHex, totalConquest))
        end

        PVPHUB.window = f
        tinsert(UISpecialFrames, f:GetName())
        f:UpdateContent()
    else
        PVPHUB.window:Show()
    end
end

-- Compact Window Functions
function PVPHUB:CreateCompactWindow()
    if not PVPHUB.compactWindow then
        -- Always refresh data before showing compact window
        UpdateCurrencyData()
        UpdatePvPRatings()
        PVPHUB.compactWindow = CreateFrame("Frame", "PVPHUBCompactFrame", UIParent, "BackdropTemplate")
        PVPHUB.compactWindow:SetFrameStrata("BACKGROUND")
        
        -- Calculate initial width (will be updated dynamically)
        local initialWidth = PVPHUB_CONSTANTS.COMPACT_WINDOW.MIN_WIDTH
        local initialHeight = 80 -- Better initial height
        PVPHUB.compactWindow:SetWidth(initialWidth)
        PVPHUB.compactWindow:SetHeight(initialHeight)
        PVPHUB.compactWindow:SetPoint("TOPLEFT", 100, -100)
        PVPHUB.compactWindow:SetMovable(true)
        PVPHUB.compactWindow:EnableMouse(true)
        PVPHUB.compactWindow:RegisterForDrag("LeftButton")
        PVPHUB.compactWindow:SetScript("OnDragStart", PVPHUB.compactWindow.StartMoving)
        PVPHUB.compactWindow:SetScript("OnDragStop", PVPHUB.compactWindow.StopMovingOrSizing)
        
        -- Clean modern background
        PVPHUB.compactWindow:SetBackdrop({
            bgFile = "Interface\\Buttons\\WHITE8x8",
            edgeFile = "Interface\\Buttons\\WHITE8x8",
            tile = false,
            edgeSize = 1,
            insets = { left = 1, right = 1, top = 1, bottom = 1 }
        })
        PVPHUB.compactWindow:SetBackdropColor(unpack(UI_CONSTANTS.COLORS.COMPACT_BG))
        PVPHUB.compactWindow:SetBackdropBorderColor(unpack(UI_CONSTANTS.COLORS.COMPACT_BORDER))
        
        -- Character rows container (no scrollbar, dynamic sizing)
        PVPHUB.compactWindow.content = CreateFrame("Frame", nil, PVPHUB.compactWindow)
        PVPHUB.compactWindow.content:SetPoint("TOPLEFT", 8, -8)
        PVPHUB.compactWindow.content:SetSize(initialWidth - 16, 30) -- Initial size, will be updated dynamically
        
        -- Close button (repositioned to bottom)
        PVPHUB.compactWindow.closeBtn = CreateFrame("Button", nil, PVPHUB.compactWindow, "UIPanelCloseButton")
        PVPHUB.compactWindow.closeBtn:SetPoint("BOTTOMRIGHT", -3, 3)
        PVPHUB.compactWindow.closeBtn:SetSize(16, 16)
        PVPHUB.compactWindow.closeBtn:SetScript("OnClick", function() PVPHUB.compactWindow:Hide() end)
        
        -- Settings button (repositioned to bottom)
        PVPHUB.compactWindow.settingsBtn = CreateFrame("Button", nil, PVPHUB.compactWindow)
        PVPHUB.compactWindow.settingsBtn:SetSize(16, 16)
        PVPHUB.compactWindow.settingsBtn:SetPoint("BOTTOMRIGHT", -22, 3)
        PVPHUB.compactWindow.settingsBtn:SetNormalTexture("Interface\\Buttons\\UI-OptionsButton")
        PVPHUB.compactWindow.settingsBtn:SetScript("OnClick", function() PVPHUB:ShowCompactSettings() end)
        PVPHUB.compactWindow.settingsBtn:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_CURSOR")
            GameTooltip:SetText("Settings", 1, 1, 1)
            GameTooltip:Show()
        end)
        PVPHUB.compactWindow.settingsBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
        
        -- Scale buttons for compact window
        local scaleOptions = {
            { text = "S", value = 0.75, tooltip = "Small (75%)" },
            { text = "M", value = 1.0, tooltip = "Medium (100%)" },
            { text = "L", value = 1.25, tooltip = "Large (125%)" },
            { text = "XL", value = 1.5, tooltip = "Extra Large (150%)" }
        }
        
        PVPHUB.compactWindow.scaleButtons = {}
        PVPHUB.compactWindow.currentScale = 1.0
        
        for i, option in ipairs(scaleOptions) do
            local btn = CreateFrame("Button", nil, PVPHUB.compactWindow)
            btn:SetSize(18, 16)
            btn:SetPoint("BOTTOMRIGHT", PVPHUB.compactWindow, "BOTTOMRIGHT", -45 - ((#scaleOptions - i) * 20), 3)
            btn:SetFrameLevel(PVPHUB.compactWindow:GetFrameLevel() + 1)
            
            -- Button background
            local bg = btn:CreateTexture(nil, "BACKGROUND")
            bg:SetAllPoints()
            bg:SetTexture("Interface\\Buttons\\WHITE8x8")
            bg:SetVertexColor(unpack(UI_CONSTANTS.COLORS.SCALE_BUTTON_BG))
            btn.bg = bg
            
            -- Button text
            local text = btn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            text:SetPoint("CENTER")
            text:SetText(option.text)
            text:SetTextColor(1, 0.8, 0.9, 1)
            text:SetFont("Fonts\\FRIZQT__.TTF", 8, "OUTLINE")
            btn.text = text
            
            -- Set initial state
            if option.value == PVPHUB.compactWindow.currentScale then
                bg:SetVertexColor(unpack(UI_CONSTANTS.COLORS.SCALE_BUTTON_SELECTED)) -- Highlight current selection
                text:SetTextColor(1, 1, 1, 1)
            end
            
            btn.scaleValue = option.value
            btn.optionText = option.text
            
            -- Ensure button is visible
            btn:Show()
            
            -- Button interactions
            btn:SetScript("OnEnter", function(self)
                if self.scaleValue ~= PVPHUB.compactWindow.currentScale then
                    self.bg:SetVertexColor(unpack(UI_CONSTANTS.COLORS.SCALE_BUTTON_HOVER)) -- Hover effect
                end
                GameTooltip:SetOwner(self, "ANCHOR_CURSOR")
                GameTooltip:SetText(option.tooltip, 1, 1, 1)
                GameTooltip:Show()
            end)
            
            btn:SetScript("OnLeave", function(self)
                if self.scaleValue ~= PVPHUB.compactWindow.currentScale then
                    self.bg:SetVertexColor(unpack(UI_CONSTANTS.COLORS.SCALE_BUTTON_BG)) -- Normal state
                end
                GameTooltip:Hide()
            end)
            
            btn:SetScript("OnClick", function(self)
                -- Update all buttons to normal state
                for _, button in ipairs(PVPHUB.compactWindow.scaleButtons) do
                    button.bg:SetVertexColor(unpack(UI_CONSTANTS.COLORS.SCALE_BUTTON_BG))
                    button.text:SetTextColor(1, 0.8, 0.9, 1)
                end
                
                -- Highlight selected button
                self.bg:SetVertexColor(unpack(UI_CONSTANTS.COLORS.SCALE_BUTTON_SELECTED))
                self.text:SetTextColor(1, 1, 1, 1)
                
                -- Apply scale
                PVPHUB.compactWindow.currentScale = self.scaleValue
                PVPHUB.compactWindow:SetScale(self.scaleValue)
            end)
            
            table.insert(PVPHUB.compactWindow.scaleButtons, btn)
        end
        
        -- Full Mode Toggle Button (subtle text-only button)
        PVPHUB.compactWindow.fullModeBtn = CreateFrame("Button", nil, PVPHUB.compactWindow)
        PVPHUB.compactWindow.fullModeBtn:SetSize(60, 16)
        PVPHUB.compactWindow.fullModeBtn:SetPoint("BOTTOMLEFT", 5, 3)
        
        -- Create subtle text-only button
        local fullModeText = PVPHUB.compactWindow.fullModeBtn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        fullModeText:SetAllPoints()
        fullModeText:SetText("Full Mode")
        fullModeText:SetFont("Fonts\\FRIZQT__.TTF", 10)
        -- Use theme-based color for subtle appearance
        local subtleColor = UI_CONSTANTS.COLORS.SUMMARY_TEXT
        fullModeText:SetTextColor(subtleColor[1], subtleColor[2], subtleColor[3], 0.7) -- Theme color with reduced alpha
        PVPHUB.compactWindow.fullModeBtn.text = fullModeText
        
        PVPHUB.compactWindow.fullModeBtn:SetScript("OnClick", function()
            -- Hide compact window and show main window
            PVPHUB.compactWindow:Hide()
            SlashCmdList["PVPHUB"]()
        end)
        
        PVPHUB.compactWindow.fullModeBtn:SetScript("OnEnter", function(self)
            -- Make text more visible on hover using theme color
            local hoverColor = UI_CONSTANTS.COLORS.SUMMARY_TEXT
            self.text:SetTextColor(hoverColor[1], hoverColor[2], hoverColor[3], 1)
            GameTooltip:SetOwner(self, "ANCHOR_CURSOR")
            GameTooltip:SetText("Switch to Full Mode", 1, 1, 1)
            GameTooltip:AddLine("Opens the complete PVPHUB interface", 0.7, 0.7, 0.7, true)
            GameTooltip:Show()
        end)
        
        PVPHUB.compactWindow.fullModeBtn:SetScript("OnLeave", function(self)
            -- Return to subtle theme color
            local subtleColor = UI_CONSTANTS.COLORS.SUMMARY_TEXT
            self.text:SetTextColor(subtleColor[1], subtleColor[2], subtleColor[3], 0.7)
            GameTooltip:Hide()
        end)
        
        -- Add fade-away functionality for all buttons
        PVPHUB.compactWindow.fadeTimer = nil
        PVPHUB.compactWindow.fullModeBtn:SetAlpha(1)
        PVPHUB.compactWindow.closeBtn:SetAlpha(1)
        PVPHUB.compactWindow.settingsBtn:SetAlpha(1)
        -- Set initial alpha for scale buttons
        for _, btn in ipairs(PVPHUB.compactWindow.scaleButtons) do
            btn:SetAlpha(1)
        end
        
        local function startFadeTimer()
            if PVPHUB.compactWindow.fadeTimer then
                PVPHUB.compactWindow.fadeTimer:Cancel()
            end
            PVPHUB.compactWindow.fadeTimer = C_Timer.NewTimer(3, function()
                -- Fade out all buttons
                local fadeOut = CreateFrame("Frame")
                fadeOut.elapsed = 0
                fadeOut.duration = 1 -- 1 second fade
                fadeOut:SetScript("OnUpdate", function(self, elapsed)
                    self.elapsed = self.elapsed + elapsed
                    local progress = math.min(self.elapsed / self.duration, 1)
                    local alpha = 1 - progress
                    PVPHUB.compactWindow.fullModeBtn:SetAlpha(alpha)
                    PVPHUB.compactWindow.closeBtn:SetAlpha(alpha)
                    PVPHUB.compactWindow.settingsBtn:SetAlpha(alpha)
                    -- Fade scale buttons too
                    for _, btn in ipairs(PVPHUB.compactWindow.scaleButtons) do
                        btn:SetAlpha(alpha)
                    end
                    if progress >= 1 then
                        self:SetScript("OnUpdate", nil)
                    end
                end)
            end)
        end
        
        local function cancelFadeTimer()
            if PVPHUB.compactWindow.fadeTimer then
                PVPHUB.compactWindow.fadeTimer:Cancel()
                PVPHUB.compactWindow.fadeTimer = nil
            end
            -- Fade all buttons back in
            local fadeIn = CreateFrame("Frame")
            fadeIn.elapsed = 0
            fadeIn.duration = 0.3 -- Quick fade in
            fadeIn:SetScript("OnUpdate", function(self, elapsed)
                self.elapsed = self.elapsed + elapsed
                local progress = math.min(self.elapsed / self.duration, 1)
                PVPHUB.compactWindow.fullModeBtn:SetAlpha(progress)
                PVPHUB.compactWindow.closeBtn:SetAlpha(progress)
                PVPHUB.compactWindow.settingsBtn:SetAlpha(progress)
                -- Fade scale buttons back in too
                for _, btn in ipairs(PVPHUB.compactWindow.scaleButtons) do
                    btn:SetAlpha(progress)
                end
                if progress >= 1 then
                    self:SetScript("OnUpdate", nil)
                end
            end)
        end
        
        -- Set up window hover detection
        PVPHUB.compactWindow:SetScript("OnEnter", function()
            cancelFadeTimer()
        end)
        
        PVPHUB.compactWindow:SetScript("OnLeave", function()
            startFadeTimer()
        end)
        
        -- Start the initial fade timer
        startFadeTimer()
    end
    
    PVPHUB:UpdateCompactWindow()
    PVPHUB.compactWindow:Show()
end

function PVPHUB:UpdateCompactWindow()
    if not PVPHUB.compactWindow or not PVPHUB.compactWindow.content then return end
    
    -- Ensure compact mode settings exist
    if not PVPHUB_SETTINGS.compactMode then
        PVPHUB_SETTINGS.compactMode = {
            enabled = false,
            selectedChars = {},
            showRatings = {
                rating2v2 = true,
                rating3v3 = true,
                ratingShuffle = true,
                ratingBlitz = false
            }
        }
    end
    
    -- If no characters are selected, add current character by default
    if #PVPHUB_SETTINGS.compactMode.selectedChars == 0 then
        local currentChar = GetFullName()
        if currentChar and PVPHUB_DB[currentChar] then
            table.insert(PVPHUB_SETTINGS.compactMode.selectedChars, currentChar)
        end
    end
    
    -- Calculate dynamic window width based on visible columns
    local visibleRatingCount = 0
    for _, bracket in ipairs(PVP_BRACKETS) do
        if PVPHUB_SETTINGS.compactMode.showRatings[bracket.key] then
            visibleRatingCount = visibleRatingCount + 1
        end
    end
    
    local dynamicWidth = math.max(
        PVPHUB_CONSTANTS.COMPACT_WINDOW.MIN_WIDTH,
        PVPHUB_CONSTANTS.COMPACT_WINDOW.BASE_WIDTH + (visibleRatingCount * PVPHUB_CONSTANTS.COMPACT_WINDOW.COLUMN_WIDTH)
    )
    
    -- Update window and content width
    PVPHUB.compactWindow:SetWidth(dynamicWidth)
    PVPHUB.compactWindow.content:SetWidth(dynamicWidth - 16)
    
    -- Clear existing content
    for i, row in ipairs(PVPHUB.compactWindow.rows or {}) do
        row:Hide()
    end
    if PVPHUB.compactWindow.headers then
        for _, header in ipairs(PVPHUB.compactWindow.headers) do
            header:Hide()
        end
    end
    PVPHUB.compactWindow.rows = {}
    PVPHUB.compactWindow.headers = {}
    
    local yOffset = 0
    local rowHeight = PVPHUB_CONSTANTS.COMPACT_WINDOW.ROW_HEIGHT
    
    -- Create headers first
    local headerRow = CreateFrame("Frame", nil, PVPHUB.compactWindow.content)
    headerRow:SetSize(dynamicWidth - 16, rowHeight)
    headerRow:SetPoint("TOPLEFT", 0, -yOffset)
    
    -- Character header
    local charHeader = headerRow:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    charHeader:SetPoint("LEFT", 5, 0)
    charHeader:SetText("|cffFFD700Character|r")
    charHeader:SetFont("Fonts\\FRIZQT__.TTF", 10, "OUTLINE")
    
    -- Rating headers with dynamic positioning
    local headerData = {
        { key = "rating2v2", name = "2v2", icon = "|TInterface\\Icons\\achievement_arena_2v2_1:16|t" },
        { key = "rating3v3", name = "3v3", icon = "|TInterface\\Icons\\achievement_arena_3v3_1:16|t" },
        { key = "ratingShuffle", name = "Shuffle", icon = "|TInterface\\Icons\\ability_dualwield:16|t" },
        { key = "ratingBlitz", name = "Blitz", icon = "|TInterface\\Icons\\achievement_bg_killxenemies_generalsroom:16|t" }
    }
    
    local columnIndex = 0
    for _, header in ipairs(headerData) do
        if PVPHUB_SETTINGS.compactMode.showRatings[header.key] then
            local xPos = PVPHUB_CONSTANTS.COMPACT_WINDOW.BASE_WIDTH + (columnIndex * PVPHUB_CONSTANTS.COMPACT_WINDOW.COLUMN_WIDTH) - 5
            local headerText = headerRow:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            headerText:SetPoint("LEFT", xPos, 0)
            headerText:SetText("|cffFFD700" .. header.icon .. " " .. header.name .. "|r")
            headerText:SetFont("Fonts\\FRIZQT__.TTF", 9, "OUTLINE")
            columnIndex = columnIndex + 1
        end
    end
    
    table.insert(PVPHUB.compactWindow.headers, headerRow)
    yOffset = yOffset + rowHeight + 5  -- Extra space after header
    
    -- Only show selected characters and count them for dynamic sizing
    local visibleCharCount = 0
    for _, charKey in ipairs(PVPHUB_SETTINGS.compactMode.selectedChars) do
        local data = PVPHUB_DB[charKey]
        if data then
            local row = PVPHUB:CreateCompactCharacterRow(charKey, data, yOffset, dynamicWidth)
            if row then
                table.insert(PVPHUB.compactWindow.rows, row)
                yOffset = yOffset + rowHeight
                visibleCharCount = visibleCharCount + 1
            end
        end
    end
    
    -- Calculate dynamic window height based on content
    local headerHeight = rowHeight + 5 -- Header plus spacing
    local characterRowsHeight = visibleCharCount * rowHeight
    local buttonSpacing = 30 -- Space for Full Mode button
    local windowPadding = 16 -- Top and bottom padding
    
    local dynamicHeight = math.max(50, headerHeight + characterRowsHeight + buttonSpacing + windowPadding)
    
    -- Update window height dynamically
    PVPHUB.compactWindow:SetHeight(dynamicHeight)
    PVPHUB.compactWindow.content:SetSize(dynamicWidth - 16, yOffset)
end

function PVPHUB:CreateCompactCharacterRow(charKey, data, yOffset, windowWidth)
    local content = PVPHUB.compactWindow.content
    local row = CreateFrame("Frame", nil, content)
    row:SetSize((windowWidth or PVPHUB_CONSTANTS.COMPACT_WINDOW.MIN_WIDTH) - 16, PVPHUB_CONSTANTS.COMPACT_WINDOW.ROW_HEIGHT)
    row:SetPoint("TOPLEFT", 0, -yOffset)
    
    -- Character name (truncated if too long)
    local nameText = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    nameText:SetPoint("LEFT", 5, 0)
    nameText:SetWidth(PVPHUB_CONSTANTS.COMPACT_WINDOW.BASE_WIDTH - 15) -- Leave some padding
    nameText:SetJustifyH("LEFT")
    nameText:SetText(CreateCharacterName({char = charKey, data = data}))
    
    -- Ensure compact mode settings exist
    if not PVPHUB_SETTINGS.compactMode or not PVPHUB_SETTINGS.compactMode.showRatings then
        return row
    end
    
    -- Rating columns with dynamic positioning
    local columnIndex = 0
    for _, bracket in ipairs(PVP_BRACKETS) do
        if PVPHUB_SETTINGS.compactMode.showRatings[bracket.key] then
            local rating = data[bracket.key] or 0
            
            -- Handle shuffle ratings (table format)
            if bracket.key == "ratingShuffle" and type(rating) == "table" then
                local currentRating, _, _, _ = GetShuffleDisplayInfo(data, charKey)
                rating = currentRating or 0
            end
            
            local text = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            local xPos = PVPHUB_CONSTANTS.COMPACT_WINDOW.BASE_WIDTH + (columnIndex * PVPHUB_CONSTANTS.COMPACT_WINDOW.COLUMN_WIDTH) - 5
            text:SetPoint("LEFT", xPos, 0)
            text:SetText(GetRatingColor(rating) .. (rating > 0 and rating or "-") .. "|r")
            text:SetFont("Fonts\\FRIZQT__.TTF", 11)
            columnIndex = columnIndex + 1
        end
    end
    
    return row
end

function PVPHUB:ShowCompactSettings()
    if PVPHUB.compactSettingsWindow and PVPHUB.compactSettingsWindow:IsShown() then
        PVPHUB.compactSettingsWindow:Hide()
        return
    end
    
    if not PVPHUB.compactSettingsWindow then
        local f = CreateFrame("Frame", "PVPHUBCompactSettings", UIParent, "BackdropTemplate")
        f:SetFrameStrata("DIALOG")
        f:SetSize(450, 550)
        f:SetPoint("CENTER")
        f:SetMovable(true)
        f:EnableMouse(true)
        f:RegisterForDrag("LeftButton")
        f:SetScript("OnDragStart", f.StartMoving)
        f:SetScript("OnDragStop", f.StopMovingOrSizing)
        
        -- Modern clean background
        f:SetBackdrop({
            bgFile = "Interface\\Buttons\\WHITE8x8",
            edgeFile = "Interface\\Buttons\\WHITE8x8",
            tile = false,
            edgeSize = 1,
            insets = { left = 1, right = 1, top = 1, bottom = 1 }
        })
        f:SetBackdropColor(unpack(UI_CONSTANTS.COLORS.SETTINGS_BG))
        f:SetBackdropBorderColor(unpack(UI_CONSTANTS.COLORS.SETTINGS_BORDER))
        
        -- Title
        f.title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
        f.title:SetPoint("TOP", 0, -20)
        f.title:SetText("PVPHUB Compact Settings")
        f.title:SetFont("Fonts\\FRIZQT__.TTF", 16, "OUTLINE")
        f.title:SetTextColor(unpack(UI_CONSTANTS.COLORS.TITLE_COLOR))
        
        -- Close button
        f.closeBtn = CreateFrame("Button", nil, f, "UIPanelCloseButton")
        f.closeBtn:SetPoint("TOPRIGHT", -8, -8)
        f.closeBtn:SetScript("OnClick", function() f:Hide() end)
        
        -- Character selection section
        local charSectionBg = f:CreateTexture(nil, "ARTWORK")
        charSectionBg:SetTexture("Interface\\Buttons\\WHITE8x8")
        charSectionBg:SetVertexColor(0.18, 0.15, 0.15, 0.8)
        charSectionBg:SetPoint("TOPLEFT", 15, -55)
        charSectionBg:SetSize(420, 200)
        
        local charLabel = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        charLabel:SetPoint("TOPLEFT", 25, -65)
        charLabel:SetText("Characters to Display")
        charLabel:SetFont("Fonts\\FRIZQT__.TTF", 14, "OUTLINE")
        charLabel:SetTextColor(1, 0.9, 0.9, 1)
        
        f.charCheckboxes = {}
        f.charScrollFrame = CreateFrame("ScrollFrame", nil, f, "UIPanelScrollFrameTemplate")
        f.charScrollFrame:SetPoint("TOPLEFT", 25, -95) -- Moved up since no buttons
        f.charScrollFrame:SetSize(400, 150) -- Increased height since no buttons taking space
        
        f.charContent = CreateFrame("Frame", nil, f.charScrollFrame)
        f.charScrollFrame:SetScrollChild(f.charContent)
        f.charContent:SetSize(380, 200)
        
        function f:RefreshCharacterList()
            -- Clear existing checkboxes
            for _, checkbox in ipairs(self.charCheckboxes) do
                checkbox:Hide()
                checkbox:SetParent(nil)
            end
            self.charCheckboxes = {}
            
            -- Get current character and ensure it has data
            local currentChar = GetFullName()
            if currentChar and currentChar ~= "" then
                -- Make sure current character is in database with basic info
                PVPHUB_DB[currentChar] = PVPHUB_DB[currentChar] or {}
                if not PVPHUB_DB[currentChar].class then
                    local _, class = UnitClass("player")
                    local race = select(2, UnitRace("player"))
                    local gender = UnitSex("player")
                    PVPHUB_DB[currentChar].class = class
                    PVPHUB_DB[currentChar].race = race
                    PVPHUB_DB[currentChar].gender = gender
                end
            end
            
            -- Build character list from database (no duplicates possible)
            local charList = {}
            for charKey, data in pairs(PVPHUB_DB) do
                if type(data) == "table" and charKey and charKey ~= "" then
                    table.insert(charList, charKey)
                end
            end
            
            -- Sort character list
            table.sort(charList)
            
            local yPos = 0
            for i, charKey in ipairs(charList) do
                local checkbox = CreateFrame("CheckButton", nil, self.charContent, "UICheckButtonTemplate")
                checkbox:SetPoint("TOPLEFT", 10, -yPos)
                checkbox:SetSize(20, 20)
                checkbox:Show()
                
                local label = self.charContent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
                label:SetPoint("LEFT", checkbox, "RIGHT", 5, 0)
                label:Show()
                
                -- Get character data for class coloring and proper display
                local charData = PVPHUB_DB[charKey] or {}
                if charKey == currentChar then
                    -- Use current character info
                    local _, class = UnitClass("player")
                    charData.class = class
                end
                
                -- Create clean character name display
                local displayName = charKey
                if charData.class then
                    local color = RAID_CLASS_COLORS[charData.class] or NORMAL_FONT_COLOR
                    displayName = string.format("|c%s%s|r", color.colorStr or "ffffffff", charKey)
                end
                
                label:SetText(displayName)
                
                checkbox.charKey = charKey
                checkbox:SetScript("OnClick", function(self)
                    PVPHUB:ToggleCompactCharacter(self.charKey, self:GetChecked())
                end)
                
                -- Set initial state
                local isSelected = false
                for _, selected in ipairs(PVPHUB_SETTINGS.compactMode.selectedChars) do
                    if selected == charKey then
                        isSelected = true
                        break
                    end
                end
                checkbox:SetChecked(isSelected)
                
                table.insert(self.charCheckboxes, checkbox)
                yPos = yPos + 25
            end
            
            -- Update scroll content height
            self.charContent:SetHeight(math.max(200, yPos))
            
            -- Show message if no characters
            if #charList == 0 then
                if not self.noCharsLabel then
                    self.noCharsLabel = self.charContent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
                    self.noCharsLabel:SetPoint("TOPLEFT", 10, -10)
                    self.noCharsLabel:SetTextColor(0.7, 0.7, 0.7, 1)
                end
                self.noCharsLabel:SetText("No characters found. Click 'Load Data' to add your current character.")
                self.noCharsLabel:Show()
            elseif self.noCharsLabel then
                self.noCharsLabel:Hide()
            end
        end
        
        -- Initial character list population
        f:RefreshCharacterList()
        
        -- Rating selection section
        local ratingSectionBg = f:CreateTexture(nil, "ARTWORK")
        ratingSectionBg:SetTexture("Interface\\Buttons\\WHITE8x8")
        ratingSectionBg:SetVertexColor(0.15, 0.15, 0.18, 0.8)
        ratingSectionBg:SetPoint("TOPLEFT", 15, -270)
        ratingSectionBg:SetSize(420, 160)
        
        local ratingLabel = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        ratingLabel:SetPoint("TOPLEFT", 25, -280)
        ratingLabel:SetText("PvP Brackets to Display")
        ratingLabel:SetFont("Fonts\\FRIZQT__.TTF", 14, "OUTLINE")
        ratingLabel:SetTextColor(0.9, 0.9, 1, 1)
        
        f.ratingCheckboxes = {}
        local ratingData = {
            { key = "rating2v2", name = "2v2 Arena", icon = "|TInterface\\Icons\\achievement_arena_2v2_1:16|t" },
            { key = "rating3v3", name = "3v3 Arena", icon = "|TInterface\\Icons\\achievement_arena_3v3_1:16|t" },
            { key = "ratingShuffle", name = "Shuffle", icon = "|TInterface\\Icons\\ability_dualwield:16|t" },
            { key = "ratingBlitz", name = "Blitz", icon = "|TInterface\\Icons\\achievement_bg_killxenemies_generalsroom:16|t" }
        }
        
        local yPos = -310
        for i, bracket in ipairs(ratingData) do
            local checkbox = CreateFrame("CheckButton", nil, f, "UICheckButtonTemplate")
            checkbox:SetPoint("TOPLEFT", 35, yPos)
            checkbox:SetSize(20, 20)
            
            local label = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            label:SetPoint("LEFT", checkbox, "RIGHT", 8, 0)
            label:SetText(bracket.icon .. " " .. bracket.name)
            label:SetFont("Fonts\\FRIZQT__.TTF", 12)
            label:SetTextColor(0.9, 0.9, 1, 1)
            
            checkbox.bracketKey = bracket.key
            checkbox:SetScript("OnClick", function(self)
                PVPHUB:ToggleCompactRating(self.bracketKey, self:GetChecked())
            end)
            
            -- Set initial state
            checkbox:SetChecked(PVPHUB_SETTINGS.compactMode.showRatings[bracket.key])
            
            table.insert(f.ratingCheckboxes, checkbox)
            yPos = yPos - 30
        end
        
        -- Apply button
        local applyBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
        applyBtn:SetSize(100, 25)
        applyBtn:SetPoint("BOTTOM", 0, 20)
        applyBtn:SetText("Apply & Close")
        applyBtn:SetScript("OnClick", function()
            -- Update compact window if it's open
            if PVPHUB.compactWindow and PVPHUB.compactWindow:IsShown() then
                PVPHUB:UpdateCompactWindow()
            end
            f:Hide()
        end)
        
        PVPHUB.compactSettingsWindow = f
    end
    
    PVPHUB.compactSettingsWindow:Show()
end

function PVPHUB:ToggleCompactCharacter(charKey, enabled)
    if enabled then
        -- Add character if not already in list
        local found = false
        for _, selected in ipairs(PVPHUB_SETTINGS.compactMode.selectedChars) do
            if selected == charKey then
                found = true
                break
            end
        end
        if not found then
            table.insert(PVPHUB_SETTINGS.compactMode.selectedChars, charKey)
        end
    else
        -- Remove character from list
        for i, selected in ipairs(PVPHUB_SETTINGS.compactMode.selectedChars) do
            if selected == charKey then
                table.remove(PVPHUB_SETTINGS.compactMode.selectedChars, i)
                break
            end
        end
    end
    
    -- Update compact window if it's open
    if PVPHUB.compactWindow and PVPHUB.compactWindow:IsShown() then
        PVPHUB:UpdateCompactWindow()
    end
end

function PVPHUB:ToggleCompactRating(bracketKey, enabled)
    PVPHUB_SETTINGS.compactMode.showRatings[bracketKey] = enabled
    
    -- Update compact window if it's open
    if PVPHUB.compactWindow and PVPHUB.compactWindow:IsShown() then
        PVPHUB:UpdateCompactWindow()
    end
end

local mini = CreateFrame("Button", "PVPHUBMiniMapButton", Minimap)
mini:SetSize(32, 32)
mini:SetFrameStrata("LOW")
mini:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")
mini:SetPoint("TOPLEFT", Minimap, "TOPLEFT")
mini:SetNormalTexture("Interface\\AddOns\\PVPHUB\\PVPHUB.png")
mini:SetScript("OnClick", function()
    SlashCmdList["PVPHUB"]()
end)
mini:SetMovable(true)
mini:EnableMouse(true)
mini:RegisterForDrag("LeftButton")
mini:SetScript("OnDragStart", mini.StartMoving)
mini:SetScript("OnDragStop", mini.StopMovingOrSizing)

mini:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_CURSOR")
    GameTooltip:SetText("PVPHUB\nClick to open", 1, 1, 1)
    GameTooltip:Show()
end)
mini:SetScript("OnLeave", function() GameTooltip:Hide() end)

-- Welcome Popup Functions
function PVPHUB:ShowWelcomePopup()
    if not PVPHUB.compactWindow then
        PVPHUB.compactWindow = CreateFrame("Frame", "PVPHUBCompactFrame", UIParent, "BackdropTemplate")
        PVPHUB.compactWindow:SetFrameStrata("BACKGROUND")

        -- Calculate initial width (will be updated dynamically)
        local initialWidth = PVPHUB_CONSTANTS.COMPACT_WINDOW.MIN_WIDTH
        local initialHeight = 80 -- Better initial height
        PVPHUB.compactWindow:SetWidth(initialWidth)
        PVPHUB.compactWindow:SetHeight(initialHeight)
        PVPHUB.compactWindow:SetPoint("TOPLEFT", 100, -100)
        PVPHUB.compactWindow:SetMovable(true)
        PVPHUB.compactWindow:EnableMouse(true)
        PVPHUB.compactWindow:RegisterForDrag("LeftButton")
        PVPHUB.compactWindow:SetScript("OnDragStart", PVPHUB.compactWindow.StartMoving)
        PVPHUB.compactWindow:SetScript("OnDragStop", PVPHUB.compactWindow.StopMovingOrSizing)

        -- Clean modern background
        PVPHUB.compactWindow:SetBackdrop({
            insets = { left = 1, right = 1, top = 1, bottom = 1 }
        })
        PVPHUB.compactWindow:SetBackdropColor(unpack(UI_CONSTANTS.COLORS.COMPACT_BG))
        PVPHUB.compactWindow:SetBackdropBorderColor(unpack(UI_CONSTANTS.COLORS.COMPACT_BORDER))

        -- Character rows container (no scrollbar, dynamic sizing)
        PVPHUB.compactWindow.content = CreateFrame("Frame", nil, PVPHUB.compactWindow)
        PVPHUB.compactWindow.content:SetPoint("TOPLEFT", 8, -8)
        PVPHUB.compactWindow.content:SetSize(initialWidth - 16, 30) -- Initial size, will be updated dynamically

        -- Close button (repositioned to bottom)
        PVPHUB.compactWindow.closeBtn = CreateFrame("Button", nil, PVPHUB.compactWindow, "UIPanelCloseButton")
        PVPHUB.compactWindow.closeBtn:SetPoint("BOTTOMRIGHT", -3, 3)
        PVPHUB.compactWindow.closeBtn:SetSize(16, 16)

        -- Sorting: use same sortKey and logic as main window
        PVPHUB.compactWindow.sortKey = PVPHUB.sortKey or "highestRating"

        -- Unified update function for compact window
        function PVPHUB:UpdateCompactWindow()
            local sortKey = PVPHUB.sortKey or "highestRating"
            local sorted = {}
            for char, data in pairs(PVPHUB_DB) do
                if type(data) == "table" then
                    table.insert(sorted, { char = char, data = data })
                end
            end
            local function getHighestRating(entry)
                local d = entry.data
                local maxRating = 0
                for _, k in ipairs({"rating2v2", "rating3v3", "ratingBlitz"}) do
                    if type(d[k]) == "number" and d[k] > maxRating then
                        maxRating = d[k]
                    end
                end
                local shuffle = d.ratingShuffle
                if type(shuffle) == "number" then
                    if shuffle > maxRating then maxRating = shuffle end
                elseif type(shuffle) == "table" then
                    for _, v in pairs(shuffle) do
                        if v > maxRating then maxRating = v end
                    end
                end
                return maxRating
            end
            table.sort(sorted, function(a, b)
                if sortKey == "highestRating" then
                    return getHighestRating(a) > getHighestRating(b)
                else
                    local aVal = a.data[sortKey]
                    local bVal = b.data[sortKey]
                    if sortKey == "ratingShuffle" then
                        if type(aVal) == "table" then
                            local maxA = 0
                            for _, rating in pairs(aVal) do
                                if rating > maxA then maxA = rating end
                            end
                            aVal = maxA
                        end
                        if type(bVal) == "table" then
                            local maxB = 0
                            for _, rating in pairs(bVal) do
                                if rating > maxB then maxB = rating end
                            end
                            bVal = maxB
                        end
                    end
                    return (aVal or 0) > (bVal or 0)
                end
            end)
            -- ...existing code for rendering rows...
        end

        -- Call update on creation
        PVPHUB:UpdateCompactWindow()

        -- Live update: register for same events as main window
        PVPHUB.compactWindow.eventFrame = CreateFrame("Frame")
        local events = {
            "CURRENCY_DISPLAY_UPDATE",
            "PVP_RATED_STATS_UPDATE",
            "BAG_UPDATE_DELAYED",
            "BAG_UPDATE",
            "PLAYER_ENTERING_WORLD"
        }
        for _, event in ipairs(events) do
            PVPHUB.compactWindow.eventFrame:RegisterEvent(event)
        end
        PVPHUB.compactWindow.eventFrame:SetScript("OnEvent", function()
            UpdateAllData()
            PVPHUB:UpdateCompactWindow()
        end)

        startFadeTimer()
    end
    PVPHUB.compactWindow:Show()
end
