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
--   UI.CreateRail(...)               tabs: icons with a sliding highlight
--   UI.AddToolFrame(frame, ...)      the main window toolbar's control frames
--   UI.Slide(frame, to, apply)       the eased slide the switches use
--   UI.SkinWindow(frame)             square backdrop -> rounded window shell
--   UI.RefreshTheme()                repaint after a theme change (ApplyTheme)
-- Rounded shapes come from core (PVPHUB.CreateRoundedShape); the switch
-- and slider use their own textures (media/switch_*.tga, slider_track.tga).

local _, PVPHUB = ...

local UI = {}
PVPHUB.UI = UI

local MEDIA = "Interface\\AddOns\\PVPHUB\\media\\"

local switches = {}   -- every skinned switch, for theme changes
local buttons  = {}   -- every skinned button, likewise

local function Lighten(c, k)
    return math.min(1, c * k + 0.08)
end

-- The theme's highlight color, shared by every control here (switches that
-- are on, slider fills, buttons, hover circles) and the card view's toggle
-- and chips, so they all match the selected theme: its title color, the
-- theme's signature color (blue, red, purple, ...). The Dark theme's is a
-- near-white grey, so it gets a softer light grey that still stands apart
-- from the dark "off" track.
local NEUTRAL = { 0.78, 0.78, 0.8 }
local function ThemeColor()
    local colors = PVPHUB.currentColors
    local c = (colors and (colors.TITLE_COLOR or colors.ACCENT_LINE)) or { 0.8, 0.3, 0.5 }
    local hi = math.max(c[1], c[2], c[3])
    local lo = math.min(c[1], c[2], c[3])
    if hi - lo < 0.15 then return NEUTRAL end
    return c
end
UI.ThemeColor = ThemeColor

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
-- Pill shape
-- --------------------------------------------------------------------------
-- A fully rounded pill filling a frame (round ends of half its height),
-- cut from the smooth switch_track texture in three slices so it stretches
-- to any width. No masks, so no stray edge lines at any size (masked
-- rounded shapes showed a thin line along their outer edge on small
-- pills). Returns an object with SetVertexColor and SetGradient; set the
-- frame's height before creating it.

local PILL_L, PILL_R = 2 / 64, 62 / 64   -- the pill inside switch_track.tga
local PILL_CAP = 16 / 64                 -- one round end is 16 of its 64 texels

-- The slices of a pill or panel, colored and shown as one
local Slices = {}
Slices.__index = Slices
function Slices:SetVertexColor(...)
    for _, tex in ipairs(self) do tex:SetVertexColor(...) end
end
function Slices:SetGradient(...)
    for _, tex in ipairs(self) do tex:SetGradient(...) end
end
function Slices:SetShown(shown)
    for _, tex in ipairs(self) do tex:SetShown(shown) end
end

function UI.CreatePill(frame, layer, sublevel)
    local function Slice(left, right)
        local tex = frame:CreateTexture(nil, layer, nil, sublevel)
        tex:SetTexture(MEDIA .. "switch_track")
        tex:SetTexCoord(left, right, 0, 1)
        return tex
    end
    local capW = frame:GetHeight() / 2
    local l = Slice(PILL_L, PILL_L + PILL_CAP)
    local m = Slice(PILL_L + PILL_CAP, PILL_R - PILL_CAP)
    local r = Slice(PILL_R - PILL_CAP, PILL_R)
    l:SetPoint("TOPLEFT"); l:SetPoint("BOTTOMLEFT"); l:SetWidth(capW)
    r:SetPoint("TOPRIGHT"); r:SetPoint("BOTTOMRIGHT"); r:SetWidth(capW)
    m:SetPoint("TOPLEFT", l, "TOPRIGHT")
    m:SetPoint("BOTTOMRIGHT", r, "BOTTOMLEFT")
    return setmetatable({ l, m, r }, Slices)
end

-- --------------------------------------------------------------------------
-- Rounded panel
-- --------------------------------------------------------------------------
-- A rounded rectangle filling a frame, in nine slices of a 64x64 texture
-- whose corners are 24 texels: the corners keep their size (corner units
-- on screen), the edges and the middle stretch. kind "fill" is the solid
-- shape, "ring" only its thin outline, so a border can sit on a see-through
-- fill (a masked shape behind the fill would show through it). No masks,
-- so no stray edge lines. See make_panel.js for the textures.

local PANEL_CORNER = 24 / 64

-- A flat side (flat = { LEFT = true, ... }) takes the middle of the texture
-- where its corners and edge were: square corners on that side and, for a
-- ring, no outline there (a panel joined to something along that side).
-- Panels only; a pill's slices have no pvpCoords.
function Slices:SetFlat(flat)
    flat = flat or {}
    local a, z = PANEL_CORNER, 1 - PANEL_CORNER
    for _, tex in ipairs(self) do
        local l, r, t, b = unpack(tex.pvpCoords)
        if (flat.LEFT and l == 0) or (flat.RIGHT and r == 1) then l, r = a, z end
        if (flat.TOP and t == 0) or (flat.BOTTOM and b == 1) then t, b = a, z end
        tex:SetTexCoord(l, r, t, b)
    end
end

-- insets { left, top, right, bottom } shrink the shape inside the frame
-- (negative ones grow it past the frame's edges); flat as for SetFlat.
function UI.CreatePanel(frame, kind, layer, sublevel, corner, insets, flat)
    local file = MEDIA .. (kind == "ring" and "panel_ring" or "panel_fill")
    local il, it, ir, ib = 0, 0, 0, 0
    if insets then il, it, ir, ib = insets[1], insets[2], insets[3], insets[4] end
    local offsets = {
        TOPLEFT = { il, -it }, TOPRIGHT = { -ir, -it },
        BOTTOMLEFT = { il, ib }, BOTTOMRIGHT = { -ir, ib },
    }
    local a, z = PANEL_CORNER, 1 - PANEL_CORNER
    local parts = {}
    local function Part(left, right, top, bottom)
        local tex = frame:CreateTexture(nil, layer, nil, sublevel)
        tex:SetTexture(file)
        tex.pvpCoords = { left, right, top, bottom }   -- set by SetFlat below
        parts[#parts + 1] = tex
        return tex
    end
    local tl = Part(0, a, 0, a)
    local tr = Part(z, 1, 0, a)
    local bl = Part(0, a, z, 1)
    local br = Part(z, 1, z, 1)
    for point, tex in pairs({ TOPLEFT = tl, TOPRIGHT = tr, BOTTOMLEFT = bl, BOTTOMRIGHT = br }) do
        tex:SetPoint(point, frame, point, offsets[point][1], offsets[point][2])
        tex:SetSize(corner, corner)
    end
    local function Between(tex, from, fromPoint, to, toPoint)
        tex:SetPoint("TOPLEFT", from, fromPoint)
        tex:SetPoint("BOTTOMRIGHT", to, toPoint)
    end
    Between(Part(a, z, 0, a), tl, "TOPRIGHT", tr, "BOTTOMLEFT")      -- top edge
    Between(Part(a, z, z, 1), bl, "TOPRIGHT", br, "BOTTOMLEFT")      -- bottom edge
    Between(Part(0, a, a, z), tl, "BOTTOMLEFT", bl, "TOPRIGHT")      -- left edge
    Between(Part(z, 1, a, z), tr, "BOTTOMLEFT", br, "TOPRIGHT")      -- right edge
    if kind ~= "ring" then
        Between(Part(a, z, a, z), tl, "BOTTOMRIGHT", br, "TOPLEFT")  -- middle
    end
    local panel = setmetatable(parts, Slices)
    panel:SetFlat(flat)
    return panel
end

-- --------------------------------------------------------------------------
-- Sliding
-- --------------------------------------------------------------------------
-- UI.Slide(frame, to, apply, instant) moves a number (a knob's or a
-- highlight's x) from where it is to `to` in SLIDE_TIME, easing out, and
-- calls apply(x) every frame. A click often rebuilds a whole window in the
-- same frame (a tab, List/Cards, the Groups switch), and that long frame
-- used to swallow the animation, so the knob jumped instead of sliding:
-- each frame now counts for at most 1/30 s. Uses the frame's OnUpdate.

local SLIDE_TIME, SLIDE_MAX_STEP = 0.22, 1 / 30

local function SlideOnUpdate(frame, elapsed)
    local s = frame.pvpSlide
    s.t = s.t + math.min(elapsed, SLIDE_MAX_STEP)
    local p = math.min(1, s.t / SLIDE_TIME)
    s.value = s.from + (s.to - s.from) * (1 - (1 - p) ^ 3)
    s.apply(s.value)
    if p >= 1 then frame:SetScript("OnUpdate", nil) end
end

function UI.Slide(frame, to, apply, instant)
    local s = frame.pvpSlide
    if not s then
        s = {}
        frame.pvpSlide = s
    end
    s.apply = apply
    -- Jump: the first paint, a hidden frame (no OnUpdate runs), or already there
    if instant or s.value == nil or s.value == to or not frame:IsVisible() then
        s.value, s.to = to, to
        frame:SetScript("OnUpdate", nil)
        apply(to)
    elseif s.to ~= to or not frame:GetScript("OnUpdate") then
        s.from, s.to, s.t = s.value, to, 0
        frame:SetScript("OnUpdate", SlideOnUpdate)
    end
end

local function Mix(a, b, t)
    return a + (b - a) * t
end

-- --------------------------------------------------------------------------
-- Pill switch
-- --------------------------------------------------------------------------
-- A rounded track with a round knob that slides right when on. The track
-- fills with the "on" color (see ThemeColor) when on. The check button keeps its size,
-- so nothing around it moves; its label sits right of the switch.

local SWITCH_W, SWITCH_H, KNOB = 30, 16, 12
local KNOB_OFF, KNOB_ON = 2, SWITCH_W - KNOB - 2

-- Places the knob at x. The track and knob colors follow it, so the switch
-- fades from off to on while the knob slides instead of changing at once.
local function PlaceKnob(sw, x)
    sw.knobFrame:ClearAllPoints()
    sw.knobFrame:SetPoint("LEFT", sw, "LEFT", x, 0)
    local t = (x - KNOB_OFF) / (KNOB_ON - KNOB_OFF)
    local ac = sw.accent
    sw.bottom:SetRGBA(Mix(0.2, ac[1] * 0.6, t), Mix(0.2, ac[2] * 0.6, t), Mix(0.24, ac[3] * 0.6, t), 1)
    sw.top:SetRGBA(Mix(0.2, Lighten(ac[1], 0.9), t), Mix(0.2, Lighten(ac[2], 0.9), t),
        Mix(0.24, Lighten(ac[3], 0.9), t), 1)
    sw.track:SetGradient("VERTICAL", sw.bottom, sw.top)
    local k = Mix(0.72, 1, t)
    sw.knob:SetVertexColor(k, k, Mix(0.76, 1, t), 1)
end

local function PaintSwitch(cb, instant)
    local sw = cb.pvpSwitch
    sw.accent = ThemeColor()
    sw:SetAlpha(cb:IsEnabled() and 1 or 0.45)
    UI.Slide(sw, cb:GetChecked() and KNOB_ON or KNOB_OFF, sw.place, instant)
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
    sw.bottom, sw.top = CreateColor(0, 0, 0, 1), CreateColor(0, 0, 0, 1)
    sw.place = function(x) PlaceKnob(sw, x) end
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
-- Icon rail
-- --------------------------------------------------------------------------
-- A column of round icon buttons with a round highlight in the theme color
-- behind the selected one that slides over when it changes: the main
-- window's tabs. The rail is joined to the outside of the window's right
-- edge, `top` units below a rounded window's top (clear of its corner) or
-- flush with a square one's, and reads as part of the window: its
-- side toward the window is square and open, its fill continues the
-- window's background (gradient and opacity too; core's ApplyWindowBGColor
-- repaints it) and the window's border ring runs on round it. It follows
-- the "Rounded Frame" and "Window Glow" settings. Names show in a tooltip.
--   local rail = UI.CreateRail(window, items, onSelect, top)
--     items: { { key, text, icon, tip }, ... }; onSelect(key) on a click
--   rail:Select(key, instant)   moves the highlight, doesn't call onSelect
--   rail:Paint()                after a theme, rounding or glow change
--   rail:PaintFill()            after the window's background changes
--   rail.byKey[key]             an option's button (:Click() selects it)

local RAIL_PAD, RAIL_BUTTON, RAIL_GAP, RAIL_ICON = 5, 34, 4, 24
local RAIL_CORNER = 10
local RAIL_RING = 7   -- as wide as the window's border ring (core: f.borderTex)
local ROUND_MASK = "Interface\\CharacterFrame\\TempPortraitAlphaMask"
local JOINED = { LEFT = true }   -- the side on the window
local SQUARE = { LEFT = true, TOP = true, RIGHT = true, BOTTOM = true }
local rails = {}   -- for theme changes

-- Places the highlight y down from the rail's top. An icon gets its color
-- back as the highlight reaches it and fades to gray as it leaves.
local function PlaceRailThumb(rail, y)
    rail.thumbFrame:ClearAllPoints()
    rail.thumbFrame:SetPoint("TOP", rail, "TOP", 0, -y)
    for i, b in ipairs(rail.buttons) do
        local t = math.max(0, 1 - math.abs(y - rail.SlotY(i)) / (RAIL_BUTTON + RAIL_GAP))
        if b.hover then t = math.max(t, 0.7) end
        b.icon:SetAlpha(Mix(0.5, 1, t))
        b.icon:SetDesaturated(t < 0.5)
    end
end

-- The fill is the window's background over the rail's height, at the
-- alpha core last gave the window (window.bgAlpha; it changes with the
-- opacity setting and while the window fades in). A theme with
-- WINDOW_BG_TOP fades the window from WINDOW_BG at its top to
-- WINDOW_BG_TOP at its bottom: core's ApplyWindowBGColor hands that color
-- to SetGradient as the minimum, which a vertical gradient draws at the
-- bottom (despite the name). The rail copies what's on screen.
local function PaintRailFill(rail)
    local window = rail:GetParent()
    local colors = PVPHUB.currentColors or {}
    local bg = colors.WINDOW_BG or { 0.08, 0.05, 0.05, 0.95 }
    local low = colors.WINDOW_BG_TOP or bg
    local alpha = window.bgAlpha or bg[4]
    local lowAlpha = (low[4] or bg[4]) * (bg[4] > 0 and alpha / bg[4] or 0)
    local height = window:GetHeight()
    local function At(d)
        local p = height > 0 and math.max(0, math.min(1, d / height)) or 1
        return CreateColor(Mix(bg[1], low[1], p), Mix(bg[2], low[2], p), Mix(bg[3], low[3], p),
            Mix(alpha, lowAlpha, p))
    end
    rail.fill:SetGradient("VERTICAL", At(rail.top + rail:GetHeight()), At(rail.top))
end

-- The ring takes the window's border color and hides with its glow, the
-- place and corners follow its rounding, the highlight the theme color.
local function PaintRail(rail)
    local colors = PVPHUB.currentColors or {}
    local style = PVPHUB_SETTINGS and PVPHUB_SETTINGS.mainWindow or {}
    local rounded = style.roundedFrame ~= false
    rail.top = rounded and rail.roundedTop or 0
    rail:ClearAllPoints()
    rail:SetPoint("TOPLEFT", rail:GetParent(), "TOPRIGHT", 0, -rail.top)
    local border = colors.WINDOW_BORDER or { 0.3, 0.3, 0.38, 1 }
    rail.ring:SetVertexColor(border[1], border[2], border[3], (border[4] or 1) * 0.3)
    rail.ring:SetShown(style.showGlow ~= false)
    local sides = rounded and JOINED or SQUARE
    rail.fill:SetFlat(sides)
    rail.ring:SetFlat(sides)
    PaintRailFill(rail)
    local ac = ThemeColor()
    rail.thumb:SetGradient("VERTICAL",
        CreateColor(ac[1] * 0.55, ac[2] * 0.55, ac[3] * 0.55, 0.95),
        CreateColor(math.min(1, ac[1] * 0.9 + 0.1), math.min(1, ac[2] * 0.9 + 0.1), math.min(1, ac[3] * 0.9 + 0.1), 0.95))
end

function UI.CreateRail(window, items, onSelect, top)
    local rail = CreateFrame("Frame", nil, window)
    rail:SetSize(RAIL_BUTTON + RAIL_PAD * 2, RAIL_PAD * 2 + #items * RAIL_BUTTON + (#items - 1) * RAIL_GAP)
    rail.roundedTop, rail.top = top, top   -- placed by PaintRail
    rail.fill = UI.CreatePanel(rail, "fill", "BACKGROUND", 0, RAIL_CORNER)
    -- The ring is a larger shape behind the fill, like the window's. The
    -- window's own ring already covers the first RAIL_RING units beside the
    -- window, so this one starts after it (two rings on top of each other
    -- would show as a brighter patch).
    rail.ring = UI.CreatePanel(rail, "fill", "BACKGROUND", -1, RAIL_CORNER + RAIL_RING,
        { RAIL_RING, -RAIL_RING, -RAIL_RING, -RAIL_RING })
    rail.thumbFrame = CreateFrame("Frame", nil, rail)
    rail.thumbFrame:SetSize(RAIL_BUTTON, RAIL_BUTTON)
    rail.thumb = UI.CreatePill(rail.thumbFrame, "ARTWORK", 0)   -- as wide as tall: a circle

    function rail.SlotY(i) return RAIL_PAD + (i - 1) * (RAIL_BUTTON + RAIL_GAP) end
    local function Place(y) PlaceRailThumb(rail, y) end
    local function Repaint() Place(rail.pvpSlide and rail.pvpSlide.value or RAIL_PAD) end

    rail.buttons, rail.byKey = {}, {}
    for i, item in ipairs(items) do
        local b = CreateFrame("Button", nil, rail)
        b:SetSize(RAIL_BUTTON, RAIL_BUTTON)
        b:SetPoint("TOP", rail, "TOP", 0, -rail.SlotY(i))
        b:SetFrameLevel(rail.thumbFrame:GetFrameLevel() + 1)
        b.key = item.key

        b.icon = b:CreateTexture(nil, "ARTWORK")
        b.icon:SetSize(RAIL_ICON, RAIL_ICON)
        b.icon:SetPoint("CENTER")
        b.icon:SetTexture(item.icon)
        b.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        local mask = b:CreateMaskTexture()
        mask:SetTexture(ROUND_MASK, "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
        mask:SetAllPoints(b.icon)
        b.icon:AddMaskTexture(mask)

        b:SetScript("OnClick", function(self)
            rail:Select(self.key)
            if onSelect then onSelect(self.key) end
        end)
        b:SetScript("OnEnter", function(self)
            self.hover = true
            Repaint()
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetText(item.text, 1, 1, 1)
            if item.tip then GameTooltip:AddLine(item.tip, 0.7, 0.7, 0.7, true) end
            GameTooltip:Show()
        end)
        b:SetScript("OnLeave", function(self)
            self.hover = nil
            Repaint()
            GameTooltip:Hide()
        end)
        rail.buttons[i] = b
        rail.byKey[item.key] = b
    end

    function rail:Select(key, instant)
        for i, b in ipairs(self.buttons) do
            if b.key == key then
                UI.Slide(self, self.SlotY(i), Place, instant)
                return
            end
        end
    end
    function rail:Paint()
        PaintRail(self)
        Repaint()
    end
    function rail:PaintFill() PaintRailFill(self) end
    -- A themed gradient changes along the window's height
    window:HookScript("OnSizeChanged", function() PaintRailFill(rail) end)

    rails[#rails + 1] = rail
    PaintRail(rail)
    rail:Select(items[1] and items[1].key, true)
    return rail
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
    local ac = ThemeColor()
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
-- Replaces the red Blizzard button art with a rounded button in the theme
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
        base = ThemeColor()
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
    if not btn or btn.pvpRim or btn.pvpTool then return end
    btn.pvpVariant = variant

    -- Hide the Blizzard art: every texture the button has so far (its
    -- Left/Middle/Right pieces, the red hover highlight, pushed and disabled
    -- art). The template swaps them on press, hover and disable, so they're
    -- made transparent rather than removed (see SkinSwitch). This used to
    -- go through GetNormalTexture() & co. in one list; these buttons have
    -- no normal texture, so the list started with nil, the loop stopped at
    -- once and the red hover highlight stayed.
    for _, region in ipairs({ btn:GetRegions() }) do
        if region:GetObjectType() == "Texture" then
            region:SetAlpha(0)
        end
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
-- Toolbar frames
-- --------------------------------------------------------------------------
-- The thin rounded frame around each control in the main window's toolbar
-- (search, Groups, "+", Columns, Sort): a faint fill and outline that
-- brighten while the mouse is over the control, and an outline in the theme
-- color while its text box has focus.
--   UI.AddToolFrame(frame, insets, hoverFrame)  insets as in CreatePanel;
--                                               hoverFrame defaults to frame
--   UI.SkinToolButton(button)                   a Blizzard button as one
--   UI.SkinToolSearch(searchBox)                SearchBoxTemplate as one

local toolFrames = {}
local TOOL_CORNER = 6

local function PaintToolFrame(t)
    local lit = t.hover or t.focus
    t.fill:SetVertexColor(1, 1, 1, lit and 0.07 or 0.035)
    if t.focus then
        local ac = ThemeColor()
        t.ring:SetVertexColor(ac[1], ac[2], ac[3], 0.85)
    else
        t.ring:SetVertexColor(1, 1, 1, lit and 0.3 or 0.14)
    end
end

function UI.AddToolFrame(frame, insets, hoverFrame)
    local t = {
        fill = UI.CreatePanel(frame, "fill", "BACKGROUND", 1, TOOL_CORNER, insets),
        ring = UI.CreatePanel(frame, "ring", "BORDER", 1, TOOL_CORNER, insets),
    }
    hoverFrame = hoverFrame or frame
    KeepHook(hoverFrame, "OnEnter", function() t.hover = true; PaintToolFrame(t) end)
    KeepHook(hoverFrame, "OnLeave", function() t.hover = false; PaintToolFrame(t) end)
    if frame:GetObjectType() == "EditBox" then
        KeepHook(frame, "OnEditFocusGained", function() t.focus = true; PaintToolFrame(t) end)
        KeepHook(frame, "OnEditFocusLost", function() t.focus = false; PaintToolFrame(t) end)
    end
    toolFrames[#toolFrames + 1] = t
    PaintToolFrame(t)
    return t
end

function UI.SkinToolButton(btn)
    if not btn or btn.pvpTool or btn.pvpRim then return end
    -- The template's art goes, as in SkinButton
    for _, region in ipairs({ btn:GetRegions() }) do
        if region:GetObjectType() == "Texture" then
            region:SetAlpha(0)
        end
    end
    local f = ButtonFonts(true)
    btn:SetNormalFontObject(f.normal)
    btn:SetHighlightFontObject(f.normal)
    btn:SetDisabledFontObject(f.disabled)
    btn.pvpTool = UI.AddToolFrame(btn)
end

-- The template's box art goes (its magnifier and clear button stay); the
-- frame reaches 6 left of the box, where the art had the magnifier's room,
-- and 2 above and below, so a 20 high box matches 24 high controls.
function UI.SkinToolSearch(box)
    if not box or box.pvpTool then return end
    for _, region in ipairs({ box:GetRegions() }) do
        if region:GetObjectType() == "Texture" and region ~= box.searchIcon then
            region:SetAlpha(0)
        end
    end
    box.pvpTool = UI.AddToolFrame(box, { -6, -2, 0, -2 })
end

-- A dropdown styled by core's ApplyModernDropdownStyling: its square
-- background and 1 px border lines go, the frame takes their place. Its
-- box sits 22 in from the frame's left, 2 from its right and 5 from top
-- and bottom; the frame reaches 1 further up and down (24 high).
function UI.SkinToolDropdown(dd)
    if not dd or dd.pvpTool or ElvUI then return end
    if dd._pvpBg then dd._pvpBg:SetAlpha(0) end
    for _, line in ipairs(dd._pvpBorders or {}) do line:SetAlpha(0) end
    local btn = dd.Button or _G[(dd:GetName() or "") .. "Button"]
    dd.pvpTool = UI.AddToolFrame(dd, { 22, 4, 2, 4 }, btn)
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
    local ac = ThemeColor()
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
    for _, rail in ipairs(rails) do rail:Paint() end
    for _, t in ipairs(toolFrames) do PaintToolFrame(t) end
    for _, sl in ipairs(sliders) do PaintSlider(sl) end
    for _, btn in ipairs(closeButtons) do PaintClose(btn) end
    for _, win in ipairs(windows) do PaintWindow(win) end
    for _, btn in ipairs(buttons) do PaintButton(btn) end
end
