-- PVPHUB Themes Module
-- Re-applies the active theme's colors onto already-built window elements.
--
-- The theme color data itself (COLOR_THEMES) and the code that decides which
-- theme is active (ApplyTheme/GetCurrentTheme) live in PVPHUB_core.lua — that
-- version is authoritative and always wins for the main window, since it
-- shadows the global ApplyTheme for every call inside core.lua. This module
-- only updates the pieces core.lua's ApplyTheme delegates to it via
-- PVPHUB.Themes:UpdateAllWindows(), reading the already-resolved colors off
-- the shared _G.UI_CONSTANTS.COLORS table.

local _, PVPHUB = ...

-- Module namespace
PVPHUB.Themes = {}

-- Update all open windows with the current theme
function PVPHUB.Themes:UpdateAllWindows()
    if PVPHUB.window then
        self:UpdateWindow(PVPHUB.window)
    end
end

-- Update a specific window with current theme
function PVPHUB.Themes:UpdateWindow(frame)
    if not frame or not UI_CONSTANTS or not UI_CONSTANTS.COLORS then
        return
    end

    local opacity = PVPHUB_SETTINGS.windowOpacity or 0.95

    if frame.bgTex then
        local c = UI_CONSTANTS.COLORS.WINDOW_BG
        frame.bgTex:SetVertexColor(c[1], c[2], c[3], c[4] * opacity)
    end
    if frame.borderTex then
        local b = UI_CONSTANTS.COLORS.WINDOW_BORDER
        frame.borderTex:SetVertexColor(b[1], b[2], b[3], (b[4] or 1) * 0.3)
    end
    if frame.glowLayers then
        local g = UI_CONSTANTS.COLORS.WINDOW_GLOW
        local alphas = {0.25, 0.14, 0.07, 0.03}
        for i, tex in ipairs(frame.glowLayers) do
            tex:SetVertexColor(g[1], g[2], g[3], (alphas[i] or 0.05) * opacity)
        end
    end

    -- Update title
    if frame.title then
        frame.title:SetTextColor(unpack(UI_CONSTANTS.COLORS.TITLE_COLOR))
    end

    -- Update title line
    if frame.titleLine then
        frame.titleLine:SetVertexColor(unpack(UI_CONSTANTS.COLORS.ACCENT_LINE))
    end

    -- Update tabs
    self:UpdateTabs(frame)

    -- Update settings elements
    self:UpdateSettingsElements(frame)

    -- Update greeting elements
    self:UpdateGreetingElements(frame)
end

-- Update tab colors
function PVPHUB.Themes:UpdateTabs(frame)
    if not frame.tabs then return end

    for _, tab in ipairs(frame.tabs) do
        if tab.isActive then
            tab:SetBackdropColor(unpack(UI_CONSTANTS.COLORS.TAB_ACTIVE))
            if tab.text then
                tab.text:SetTextColor(unpack(UI_CONSTANTS.COLORS.TAB_ACTIVE_TEXT))
            end
        else
            tab:SetBackdropColor(unpack(UI_CONSTANTS.COLORS.TAB_INACTIVE))
            if tab.text then
                tab.text:SetTextColor(unpack(UI_CONSTANTS.COLORS.TAB_INACTIVE_TEXT))
            end
        end
    end
end

-- Update settings elements
function PVPHUB.Themes:UpdateSettingsElements(frame)
    if not frame.settingsFrame then return end

    -- Update settings titles
    if frame.settingsTitle then
        frame.settingsTitle:SetTextColor(unpack(UI_CONSTANTS.COLORS.TITLE_COLOR))
    end

    if frame.styleTitle then
        frame.styleTitle:SetTextColor(unpack(UI_CONSTANTS.COLORS.TITLE_COLOR))
    end

    -- Update subtitles
    local subtitles = {
        "fontsSubtitle", "themeSubtitle", "transparencySubtitle", "fontSizeLabel"
    }

    for _, subtitleName in ipairs(subtitles) do
        if frame[subtitleName] then
            frame[subtitleName]:SetTextColor(unpack(UI_CONSTANTS.COLORS.HEADER_COLOR))
        end
    end

    -- Update value labels
    if frame.fontSizeValueLabel then
        frame.fontSizeValueLabel:SetTextColor(unpack(UI_CONSTANTS.COLORS.HEADER_COLOR))
    end

    if frame.transparencyValueLabel then
        frame.transparencyValueLabel:SetTextColor(unpack(UI_CONSTANTS.COLORS.HEADER_COLOR))
    end
end

-- Update greeting elements
function PVPHUB.Themes:UpdateGreetingElements(frame)
    if not frame.greetingFrame then return end

    -- Update greeting title
    if frame.greetingTitle then
        frame.greetingTitle:SetTextColor(unpack(UI_CONSTANTS.COLORS.TITLE_COLOR))
    end

    -- Update greeting text
    if frame.greetingText then
        frame.greetingText:SetTextColor(unpack(UI_CONSTANTS.COLORS.HEADER_COLOR))
    end

    -- Update feature items
    if frame.featureItems then
        for _, item in ipairs(frame.featureItems) do
            if item.SetTextColor then
                item:SetTextColor(unpack(UI_CONSTANTS.COLORS.HEADER_COLOR))
            end
        end
    end
end
