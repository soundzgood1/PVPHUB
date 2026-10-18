-- PVPHUB UI kit
-- Shared modern controls, so every part of the addon looks the same and a
-- theme change applies everywhere at once. Each function restyles a control
-- that already exists and leaves its logic alone (GetChecked/SetChecked,
-- OnClick, tooltips), so call sites don't change:
--   UI.SkinSwitch(checkButton)       on/off checkbox -> pill switch
--   UI.SkinSlider(slider)            horizontal slider -> rounded track + knob
--   UI.SkinButton(button, "danger")  Blizzard red button -> rounded button
--   UI.SkinDescendants(frame)        the three above, for everything inside a frame
--   UI.SkinCloseButton(button)       red "X" -> thin "×" with a hover circle
--   UI.SkinWindow(frame)             square backdrop -> rounded window shell
--   UI.RefreshTheme()                repaint after a theme change (ApplyTheme)
-- Rounded shapes come from core (PVPHUB.CreateRoundedShape); the switch
-- and slider use their own textures (media/switch_*.tga, slider_track.tga).

local _, PVPHUB = ...

local UI = {}
PVPHUB.UI = UI

local switches = {}   -- every skinned switch, for theme changes
local buttons  = {}   -- every skinned button, likewise

local function Accent()
    local colors = PVPHUB.currentColors
    return (colors and colors.ACCENT_LINE) or { 0.8, 0.3, 0.5 }
end

local function Lighten(c, k)
    return math.min(1, c * k + 0.08)
end

-- The color of a switch that's on: the theme's accent, unless that's
-- (nearly) gray, like the Dark theme's; then PVPHUB gold, so on and off
-- don't differ by the knob's position alone.
local GOLD = { 1, 0.74, 0.1 }
local function OnColor()
    local ac = Accent()
    local hi = math.max(ac[1], ac[2], ac[3])
    local lo = math.min(ac[1], ac[2], ac[3])
    if hi - lo < 0.15 then return GOLD end
    return ac
end

-- Hooks a script so the hook survives a later SetScript of the same script.
-- SetScript drops earlier hooks, and callers often set OnEnter/OnLeave for
-- a tooltip after a control has been skinned (one hook per script and frame).
local function KeepHook(frame, script, fn)
    if not frame.pvpHooks then
        frame.pvpHooks = {}
        hooksecurefunc(frame, "SetScript", function(self, name)
            local hook = self.pvpHooks[name]
            if hook then self:HookScript(name, hook) end
        end)
    end
    frame.pvpHooks[script] = fn
    frame:HookScript(script, fn)
end

-- --------------------------------------------------------------------------
-- Pill switch
-- --------------------------------------------------------------------------
-- A rounded track with a round knob that slides right when on. The track
-- fills with the "on" color (see OnColor) when on. The check button keeps its size,
-- so nothing around it moves; its label sits right of the switch.

local SWITCH_W, SWITCH_H, KNOB = 30, 16, 12
local MEDIA = "Interface\\AddOns\\PVPHUB\\media\\"

local function KnobX(on)
    return on and (SWITCH_W - KNOB - 2) or 2
end

local function SwitchOnUpdate(sw, elapsed)
    local diff = sw.knobTarget - sw.knobX
    if math.abs(diff) < 0.3 then
        sw.knobX = sw.knobTarget
        sw:SetScript("OnUpdate", nil)
    else
        sw.knobX = sw.knobX + diff * math.min(1, elapsed * 16)
    end
    sw.knobFrame:ClearAllPoints()
    sw.knobFrame:SetPoint("LEFT", sw, "LEFT", sw.knobX, 0)
end

local function PaintSwitch(cb, instant)
    local sw = cb.pvpSwitch
    local on = cb:GetChecked() and true or false
    local enabled = cb:IsEnabled()
    local ac = OnColor()

    if on then
        sw.track:SetGradient("VERTICAL",
            CreateColor(ac[1] * 0.6, ac[2] * 0.6, ac[3] * 0.6, 1),
            CreateColor(Lighten(ac[1], 0.9), Lighten(ac[2], 0.9), Lighten(ac[3], 0.9), 1))
        sw.knob:SetVertexColor(1, 1, 1, 1)
    else
        sw.track:SetVertexColor(0.2, 0.2, 0.24, 1)
        sw.knob:SetVertexColor(0.72, 0.72, 0.76, 1)
    end
    sw:SetAlpha(enabled and 1 or 0.45)

    sw.knobTarget = KnobX(on)
    if instant or not sw.knobX then
        sw.knobX = sw.knobTarget
        SwitchOnUpdate(sw, 0)
    elseif sw.knobX ~= sw.knobTarget then
        sw:SetScript("OnUpdate", SwitchOnUpdate)
    end
end

function UI.SkinSwitch(cb)
    if not cb or cb.pvpSwitch then return end

    -- Hide the template's box and check mark. They're atlas textures that
    -- SetNormalTexture("") etc. don't remove (their edges stuck out above
    -- and below the switch), and the button shows and hides them by state,
    -- so every texture of the button is made transparent instead: state
    -- changes never touch alpha.
    for _, region in ipairs({ cb:GetRegions() }) do
        if region:GetObjectType() == "Texture" then
            region:SetAlpha(0)
        end
    end

    local sw = CreateFrame("Frame", nil, cb)
    sw:SetSize(SWITCH_W, SWITCH_H)
    sw:SetPoint("LEFT", cb, "LEFT", 0, 0)
    -- Track and knob are plain textures with smooth edges drawn into them
    -- (no rounded shapes and no outline: at this size mask edges and a
    -- 1 px outline ring showed as thin lines around the switch).
    -- The track file leaves 2 of its 64 texels free left and right, so
    -- the texture is a little wider than the switch.
    sw.track = sw:CreateTexture(nil, "ARTWORK")
    sw.track:SetTexture(MEDIA .. "switch_track")
    sw.track:SetSize(SWITCH_W * 64 / 60, SWITCH_H)
    sw.track:SetPoint("CENTER")

    sw.knobFrame = CreateFrame("Frame", nil, sw)
    sw.knobFrame:SetSize(KNOB, KNOB)
    sw.knob = sw.knobFrame:CreateTexture(nil, "OVERLAY")
    sw.knob:SetTexture(MEDIA .. "switch_knob")
    sw.knob:SetAllPoints()
    cb.pvpSwitch = sw

    -- Label right of the switch
    if cb.Text then
        cb.Text:ClearAllPoints()
        cb.Text:SetPoint("LEFT", cb, "LEFT", SWITCH_W + 8, 0)
    end

    -- Follow every way the state can change
    KeepHook(cb, "OnClick", function(self) PaintSwitch(self) end)
    KeepHook(cb, "OnShow", function(self) PaintSwitch(self, true) end)
    hooksecurefunc(cb, "SetChecked", function(self) PaintSwitch(self) end)
    hooksecurefunc(cb, "Enable", function(self) PaintSwitch(self, true) end)
    hooksecurefunc(cb, "Disable", function(self) PaintSwitch(self, true) end)

    switches[#switches + 1] = cb
    PaintSwitch(cb, true)
end

-- --------------------------------------------------------------------------
-- Slider
-- --------------------------------------------------------------------------
-- A thin rounded track, filled with the "on" color up to a round white
-- knob, which gets a soft halo on hover and while dragging. The slider
-- keeps doing the work (value, steps, dragging, its own scripts): its art
-- is hidden and the new parts are anchored to its (invisible) thumb, so
-- they follow it on their own.

local sliders = {}    -- every skinned slider, for theme changes
local SLIDER_KNOB, HALO = 12, 20
local CAP = 8 / 32    -- slider_track.tga: 32x16, the round ends 8 texels each

-- A pill as three slices (round cap, stretchable middle, round cap)
local function TrackPart(parent, sublevel, left, right, height)
    local tex = parent:CreateTexture(nil, "ARTWORK", nil, sublevel)
    tex:SetTexture(MEDIA .. "slider_track")
    tex:SetTexCoord(left, right, 0, 1)
    tex:SetHeight(height)
    return tex
end

local function PaintSlider(sl)
    local p = sl.pvpSlider
    local ac = OnColor()
    for _, tex in ipairs(p.back) do
        tex:SetVertexColor(0.2, 0.2, 0.24, 1)
    end
    for _, tex in ipairs(p.fill) do
        tex:SetGradient("VERTICAL",
            CreateColor(ac[1] * 0.6, ac[2] * 0.6, ac[3] * 0.6, 1),
            CreateColor(Lighten(ac[1], 0.9), Lighten(ac[2], 0.9), Lighten(ac[3], 0.9), 1))
    end
    local enabled = sl:IsEnabled()
    local halo = 0
    if enabled and p.pressed then halo = 0.4 elseif enabled and p.hover then halo = 0.22 end
    p.halo:SetVertexColor(ac[1], ac[2], ac[3], halo)
    p.frame:SetAlpha(enabled and 1 or 0.45)
    -- The thumb's size sets how far it travels; keep it the knob's size
    -- in case the template resets it
    sl:GetThumbTexture():SetSize(SLIDER_KNOB, SLIDER_KNOB)
end

-- Only horizontal sliders: the old scroll bars (UIPanelScrollFrameTemplate)
-- are vertical sliders too.
function UI.SkinSlider(sl)
    if not sl or sl.pvpSlider or sl:GetOrientation() ~= "HORIZONTAL" then return end
    local thumb = sl:GetThumbTexture()
    if not thumb then return end

    -- Hide the template's bar and thumb (see SkinSwitch for why alpha)
    for _, region in ipairs({ sl:GetRegions() }) do
        if region:GetObjectType() == "Texture" then
            region:SetAlpha(0)
        end
    end
    thumb:SetSize(SLIDER_KNOB, SLIDER_KNOB)

    -- The new parts live on a child frame (no mouse), so the disabled look
    -- can dim them all at once
    local p = { frame = CreateFrame("Frame", nil, sl) }
    p.frame:SetAllPoints()

    -- Thinner track on small sliders (the Streamer Mode toolbar's)
    local trackH = (sl:GetHeight() < 12) and 4 or 6
    local backL = TrackPart(p.frame, 0, 0, CAP, trackH)
    local backM = TrackPart(p.frame, 0, CAP, 1 - CAP, trackH)
    local backR = TrackPart(p.frame, 0, 1 - CAP, 1, trackH)
    backL:SetWidth(trackH / 2)
    backR:SetWidth(trackH / 2)
    backL:SetPoint("LEFT", sl, "LEFT", 0, 0)
    backR:SetPoint("RIGHT", sl, "RIGHT", 0, 0)
    backM:SetPoint("LEFT", backL, "RIGHT")
    backM:SetPoint("RIGHT", backR, "LEFT")

    -- Fill: from the left end to the knob's center (its end hides under it)
    local fillL = TrackPart(p.frame, 1, 0, CAP, trackH)
    local fillM = TrackPart(p.frame, 1, CAP, 1 - CAP, trackH)
    fillL:SetWidth(trackH / 2)
    fillL:SetPoint("LEFT", sl, "LEFT", 0, 0)
    fillM:SetPoint("LEFT", fillL, "RIGHT")
    fillM:SetPoint("RIGHT", thumb, "CENTER")

    p.halo = p.frame:CreateTexture(nil, "OVERLAY", nil, 0)
    p.halo:SetTexture(MEDIA .. "switch_knob")
    p.halo:SetSize(HALO, HALO)
    p.halo:SetPoint("CENTER", thumb, "CENTER")

    p.knob = p.frame:CreateTexture(nil, "OVERLAY", nil, 1)
    p.knob:SetTexture(MEDIA .. "switch_knob")
    p.knob:SetSize(SLIDER_KNOB, SLIDER_KNOB)
    p.knob:SetPoint("CENTER", thumb, "CENTER")

    p.back = { backL, backM, backR }
    p.fill = { fillL, fillM }
    sl.pvpSlider = p

    KeepHook(sl, "OnEnter", function(self) self.pvpSlider.hover = true; PaintSlider(self) end)
    KeepHook(sl, "OnLeave", function(self) self.pvpSlider.hover = false; PaintSlider(self) end)
    KeepHook(sl, "OnMouseDown", function(self) self.pvpSlider.pressed = true; PaintSlider(self) end)
    KeepHook(sl, "OnMouseUp", function(self) self.pvpSlider.pressed = false; PaintSlider(self) end)
    hooksecurefunc(sl, "Enable", function(self) PaintSlider(self) end)
    hooksecurefunc(sl, "Disable", function(self) PaintSlider(self) end)

    sliders[#sliders + 1] = sl
    PaintSlider(sl)
end

-- --------------------------------------------------------------------------
-- Rounded button
-- --------------------------------------------------------------------------
-- Replaces the red Blizzard button art with a rounded button in the accent
-- color: lighter on hover, darker while pressed, gray when disabled.
-- variant "danger" is red, for things like Reset All Data.

local fonts = {}
local function ButtonFonts(small)
    local key = small and "small" or "normal"
    if not fonts[key] then
        local base = small and GameFontNormalSmall or GameFontNormal
        local normal = CreateFont("PVPHUBUIButtonFont_" .. key)
        normal:CopyFontObject(base)
        normal:SetTextColor(1, 1, 1, 1)
        local disabled = CreateFont("PVPHUBUIButtonFontDisabled_" .. key)
        disabled:CopyFontObject(base)
        disabled:SetTextColor(0.55, 0.55, 0.58, 1)
        fonts[key] = { normal = normal, disabled = disabled }
    end
    return fonts[key]
end

local function PaintButton(btn)
    local state = btn.pvpButtonState or {}
    local base
    if btn.pvpVariant == "danger" then
        base = { 0.72, 0.16, 0.14 }
    else
        base = Accent()
    end

    local k = 0.55                          -- normal
    if not btn:IsEnabled() then
        btn.pvpRim:SetVertexColor(0.3, 0.3, 0.34, 0.7)
        btn.pvpFill:SetVertexColor(0.12, 0.12, 0.14, 0.9)
        return
    elseif state.pressed then
        k = 0.4
    elseif state.hover then
        k = 0.75
    end
    btn.pvpRim:SetVertexColor(Lighten(base[1], k + 0.35), Lighten(base[2], k + 0.35), Lighten(base[3], k + 0.35), 0.9)
    btn.pvpFill:SetGradient("VERTICAL",
        CreateColor(base[1] * k * 0.75, base[2] * k * 0.75, base[3] * k * 0.75, 0.96),
        CreateColor(Lighten(base[1], k), Lighten(base[2], k), Lighten(base[3], k), 0.96))
end

function UI.SkinButton(btn, variant)
    if not btn or btn.pvpRim then return end
    btn.pvpVariant = variant

    -- Hide the Blizzard art (the template swaps its pieces on press and
    -- disable, so they stay transparent instead of being removed)
    for _, key in ipairs({ "Left", "Middle", "Right" }) do
        if btn[key] then btn[key]:SetAlpha(0) end
    end
    for _, tex in ipairs({ btn:GetNormalTexture(), btn:GetPushedTexture(),
                           btn:GetDisabledTexture(), btn:GetHighlightTexture() }) do
        if tex then tex:SetAlpha(0) end
    end

    local radius = math.min(5, math.floor(btn:GetHeight() / 2))
    btn.pvpRim = PVPHUB.CreateRoundedShape(btn, "BACKGROUND", 0, 0, radius)
    btn.pvpFill = PVPHUB.CreateRoundedShape(btn, "BACKGROUND", 1, -1, radius - 1)
    btn.pvpRim:SetRounded(true)
    btn.pvpFill:SetRounded(true)

    -- White text in every state (the template would turn it gold)
    local f = ButtonFonts(btn:GetHeight() <= 20)
    btn:SetNormalFontObject(f.normal)
    btn:SetHighlightFontObject(f.normal)
    btn:SetDisabledFontObject(f.disabled)

    btn.pvpButtonState = {}
    KeepHook(btn, "OnEnter", function(self) self.pvpButtonState.hover = true; PaintButton(self) end)
    KeepHook(btn, "OnLeave", function(self) self.pvpButtonState.hover = false; self.pvpButtonState.pressed = false; PaintButton(self) end)
    KeepHook(btn, "OnMouseDown", function(self) self.pvpButtonState.pressed = true; PaintButton(self) end)
    KeepHook(btn, "OnMouseUp", function(self) self.pvpButtonState.pressed = false; PaintButton(self) end)
    hooksecurefunc(btn, "Enable", function(self) PaintButton(self) end)
    hooksecurefunc(btn, "Disable", function(self) PaintButton(self) end)

    buttons[#buttons + 1] = btn
    PaintButton(btn)
end

-- --------------------------------------------------------------------------
-- Close button
-- --------------------------------------------------------------------------
-- The red Blizzard "X" -> a thin smooth "×", gray, turning white on a soft
-- round backdrop in the "on" color on hover. Sized from the button, so it
-- fits the small Streamer Mode toolbar as well as the windows.

local closeButtons = {}
local LINE_TEXTURE = MEDIA .. "graph_line"   -- soft across its width, see cards.lua

local function CrossLine(btn, x1, y1, x2, y2)
    local line = btn:CreateLine(nil, "OVERLAY")
    line:SetTexture(LINE_TEXTURE)
    line:SetThickness(3)   -- the texture's solid core is about half of it
    if line.SetSnapToPixelGrid then
        line:SetSnapToPixelGrid(false)
        line:SetTexelSnappingBias(0)
    end
    line:SetStartPoint("CENTER", btn, x1, y1)
    line:SetEndPoint("CENTER", btn, x2, y2)
    return line
end

local function PaintClose(btn)
    local p = btn.pvpClose
    local ac = OnColor()
    local hover = p.hover and btn:IsEnabled()
    local c = hover and 1 or 0.72
    for _, line in ipairs(p.lines) do
        line:SetVertexColor(c, c, c, 1)
    end
    local a = 0
    if hover and p.pressed then a = 0.5 elseif hover then a = 0.32 end
    p.bg:SetVertexColor(ac[1], ac[2], ac[3], a)
end

function UI.SkinCloseButton(btn)
    if not btn or btn.pvpClose then return end

    -- Hide the template's art (see SkinSwitch for why alpha)
    for _, region in ipairs({ btn:GetRegions() }) do
        if region:GetObjectType() == "Texture" then
            region:SetAlpha(0)
        end
    end

    local size = math.min(btn:GetWidth(), btn:GetHeight())
    local p = {}
    p.bg = btn:CreateTexture(nil, "ARTWORK")
    p.bg:SetTexture(MEDIA .. "switch_knob")
    p.bg:SetSize(size * 0.85, size * 0.85)
    p.bg:SetPoint("CENTER")
    local h = size * 0.18
    p.lines = { CrossLine(btn, -h, h, h, -h), CrossLine(btn, -h, -h, h, h) }
    btn.pvpClose = p

    KeepHook(btn, "OnEnter", function(self) self.pvpClose.hover = true; PaintClose(self) end)
    KeepHook(btn, "OnLeave", function(self) self.pvpClose.hover = false; self.pvpClose.pressed = false; PaintClose(self) end)
    KeepHook(btn, "OnMouseDown", function(self) self.pvpClose.pressed = true; PaintClose(self) end)
    KeepHook(btn, "OnMouseUp", function(self) self.pvpClose.pressed = false; PaintClose(self) end)

    closeButtons[#closeButtons + 1] = btn
    PaintClose(btn)
end

-- --------------------------------------------------------------------------
-- Small window
-- --------------------------------------------------------------------------
-- Gives a small PVPHUB window (Manage Groups, Backups, Hidden Characters)
-- the main window's look instead of its square backdrop: a rounded
-- background in the theme's window colors inside the same soft border ring.
-- Uses the main window's field names (bgTex, borderTex), so core's
-- background painter works on it.

local windows = {}
local WINDOW_RADIUS, WINDOW_RING = 16, 5

local function PaintWindow(win)
    local colors = PVPHUB.currentColors
    if not colors or not colors.WINDOW_BG then return end
    PVPHUB._ApplyWindowBGColor(win, math.max(colors.WINDOW_BG[4] or 1, 0.95))
    local b = colors.WINDOW_BORDER or { 0.4, 0.4, 0.4, 1 }
    win.borderTex:SetVertexColor(b[1], b[2], b[3], (b[4] or 1) * 0.3)
end

function UI.SkinWindow(win)
    if not win or win.pvpWindow then return end
    win.pvpWindow = true
    if win.SetBackdrop then win:SetBackdrop(nil) end
    win.borderTex = PVPHUB.CreateRoundedShape(win, "BACKGROUND", -2, WINDOW_RING, WINDOW_RADIUS + WINDOW_RING)
    win.bgTex = PVPHUB.CreateRoundedShape(win, "BACKGROUND", -1, 0, WINDOW_RADIUS)
    win.borderTex:SetRounded(true)
    win.bgTex:SetRounded(true)
    windows[#windows + 1] = win
    PaintWindow(win)
end

-- --------------------------------------------------------------------------
-- Bulk and theme
-- --------------------------------------------------------------------------

-- Skins every check button and Blizzard panel button inside frame (the
-- Settings tab calls this once it's built). Blizzard panel buttons are the
-- ones with Left/Middle/Right art; dropdowns are frames, not buttons, and
-- are left alone.
function UI.SkinDescendants(frame)
    for _, child in ipairs({ frame:GetChildren() }) do
        local kind = child:GetObjectType()
        if kind == "CheckButton" then
            UI.SkinSwitch(child)
        elseif kind == "Slider" then
            UI.SkinSlider(child)
        elseif kind == "Button" and child.Left and child.Middle and child.Right then
            UI.SkinButton(child, child.pvpDanger and "danger" or nil)
        end
        UI.SkinDescendants(child)
    end
end

function UI.RefreshTheme()
    for _, cb in ipairs(switches) do PaintSwitch(cb, true) end
    for _, sl in ipairs(sliders) do PaintSlider(sl) end
    for _, btn in ipairs(closeButtons) do PaintClose(btn) end
    for _, win in ipairs(windows) do PaintWindow(win) end
    for _, btn in ipairs(buttons) do PaintButton(btn) end
end
