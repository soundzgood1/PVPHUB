-- PVPHUB Manage Characters (7.0)
--
-- Cleaning up characters PVPHUB has stored, in one place:
--   * Server transfers. A transfer gives a character a new GUID, so the
--     GUID rename migration in core can't follow it and the old entry stays
--     behind. When a character logs in, entries with the same name and class
--     on another realm that haven't been played since it first appeared are
--     likely its old self: PVPHUB asks once whether to merge them
--     (StaticPopup "PVPHUB_TRANSFER_MERGE"; "Not the same" is remembered).
--   * The Manage Characters window (Settings > Advanced): every stored
--     character, hidden ones too, with last seen and hints ("probably moved
--     to ...", "not seen in 60+ days"); merge, hide or delete, one at a time
--     or several at once.
--
-- Rules (after the data losses of v6.6.x): nothing is merged or deleted
-- without asking, a backup snapshot is taken first (Manage Backups can bring
-- it back), and a merge only fills in what the kept entry is missing.

local _, PVPHUB = ...

local Chars = {}
PVPHUB.Characters = Chars

local STALE_DAYS = 60

local function Print(msg)
    if PVPHUB._PVPHubPrint then PVPHUB._PVPHubPrint(msg) else print(msg) end
end

local function NameOf(key) return key:match("^([^%-]+)") or key end
local function RealmOf(key) return key:match("%-(.+)$") or "" end

local function IsCharKey(key, data)
    return type(data) == "table" and key ~= "settings" and key:find("-", 1, true) ~= nil
end

local function ClassColored(key, text)
    local data = PVPHUB_DB and PVPHUB_DB[key]
    local c = data and data.class and RAID_CLASS_COLORS[data.class:upper()]
    return c and c:WrapTextInColorCode(text or key) or (text or key)
end

local function Copy(value)
    if type(value) ~= "table" then return value end
    local t = {}
    for k, v in pairs(value) do t[k] = Copy(v) end
    return t
end

local function Refresh()
    local f = PVPHUB.window
    if f and f.UpdateContent then f:UpdateContent() end
    if PVPHUB.compactWindow and PVPHUB.UpdateCompactWindow then PVPHUB:UpdateCompactWindow() end
    if Chars.window and Chars.window:IsShown() then Chars.Render() end
end

-- --------------------------------------------------------------------------
-- Transfer suggestions
-- --------------------------------------------------------------------------

local function Dismissed()
    PVPHUB_SETTINGS.transferDismissed = PVPHUB_SETTINGS.transferDismissed or {}
    return PVPHUB_SETTINGS.transferDismissed
end

function Chars.Dismiss(fromKey, toKey)
    Dismissed()[fromKey .. ">" .. toKey] = true
end

-- Is oldKey probably newKey before a server transfer? Same name and class
-- on another realm, not the same GUID (that's a rename, which core merges
-- by itself), not a higher level, and not played since newKey first
-- appeared, so two live characters that share a name are left alone
-- (once "Not the same" was picked, never again).
local function LooksLikeTransfer(oldKey, newKey)
    if oldKey == newKey or RealmOf(oldKey) == RealmOf(newKey) then return false end
    if NameOf(oldKey):lower() ~= NameOf(newKey):lower() then return false end
    local old, new = PVPHUB_DB[oldKey], PVPHUB_DB[newKey]
    if not (IsCharKey(oldKey, old) and IsCharKey(newKey, new)) then return false end
    if old.class and new.class and old.class:upper() ~= new.class:upper() then return false end
    if old.guid and new.guid and old.guid == new.guid then return false end
    if (old.level or 0) > 0 and (new.level or 0) > 0 and old.level > new.level then return false end
    local newSince = new.firstSeen or new.lastSeen
    if old.lastSeen and newSince and old.lastSeen > newSince then return false end
    if Dismissed()[oldKey .. ">" .. newKey] then return false end
    return true
end

-- The character oldKey probably became, or nil
function Chars.MovedTo(oldKey)
    local best
    for key, data in pairs(PVPHUB_DB) do
        if IsCharKey(key, data) and LooksLikeTransfer(oldKey, key) then
            if not best or (data.lastSeen or 0) > (PVPHUB_DB[best].lastSeen or 0) then best = key end
        end
    end
    return best
end

-- Entries that are probably earlier selves of newKey, most recent first
function Chars.EarlierSelves(newKey)
    local list = {}
    for key, data in pairs(PVPHUB_DB) do
        if IsCharKey(key, data) and LooksLikeTransfer(key, newKey) then list[#list + 1] = key end
    end
    table.sort(list, function(a, b) return (PVPHUB_DB[a].lastSeen or 0) > (PVPHUB_DB[b].lastSeen or 0) end)
    return list
end

-- --------------------------------------------------------------------------
-- Merge and delete
-- --------------------------------------------------------------------------

local function RemoveFromList(list, key)
    if type(list) ~= "table" then return end
    for i = #list, 1, -1 do
        if list[i] == key then table.remove(list, i) end
    end
end

-- Takes a character out of everything that refers to it by name. With
-- keepKey, places that should follow the character (its group, its place
-- in Custom Order) go to keepKey instead, if keepKey has none of its own.
local function Forget(key, keepKey)
    local s = PVPHUB_SETTINGS

    -- Hidden
    if s.hiddenCharacters then
        RemoveFromList(s.hiddenCharacters, key)
        if PVPHUB._RebuildHiddenSet then PVPHUB._RebuildHiddenSet() end
    end
    if s.hiddenChars then s.hiddenChars[key] = nil end

    -- Groups: keepKey joins the old one's group when it's in none yet
    local groups = s.characterGroups and s.characterGroups.groups
    if type(groups) == "table" then
        local oldGroup
        for i, g in ipairs(groups) do
            for _, k in ipairs(g.characters or {}) do
                if k == key and not g.isDefault then oldGroup = i end
            end
            RemoveFromList(g.characters, key)
        end
        if keepKey and oldGroup and PVPHUB._GetCharacterGroup and PVPHUB._MoveCharacterToGroup then
            local current = groups[PVPHUB._GetCharacterGroup(keepKey) or 0]
            if not current or current.isDefault then PVPHUB._MoveCharacterToGroup(keepKey, oldGroup) end
        end
    end

    -- Custom Order: keepKey takes the old place if it has none
    if type(s.customOrder) == "table" then
        local hasKeep = false
        for _, k in ipairs(s.customOrder) do if k == keepKey then hasKeep = true end end
        for i, k in ipairs(s.customOrder) do
            if k == key then
                if keepKey and not hasKeep then
                    s.customOrder[i] = keepKey
                    hasKeep = true
                else
                    s.customOrder[i] = false
                end
            end
        end
        RemoveFromList(s.customOrder, false)
    end

    -- Streamer Mode, pins, card view choices
    local cm = s.compactMode
    if cm then
        if type(cm.selectedChars) == "table" then
            local had = false
            for _, k in ipairs(cm.selectedChars) do if k == key then had = true end end
            RemoveFromList(cm.selectedChars, key)
            if keepKey and had then
                local present = false
                for _, k in ipairs(cm.selectedChars) do if k == keepKey then present = true end end
                if not present then table.insert(cm.selectedChars, keepKey) end
            end
        end
        if type(cm.pinnedSpecs) == "table" then
            if keepKey and cm.pinnedSpecs[key] and not cm.pinnedSpecs[keepKey] then
                cm.pinnedSpecs[keepKey] = cm.pinnedSpecs[key]
            end
            cm.pinnedSpecs[key] = nil
        end
    end
    local mw = s.mainWindow
    if mw then
        if mw.pinnedCharacter == key then mw.pinnedCharacter = keepKey end
        if type(mw.ratingTiles) == "table" then
            if keepKey and mw.ratingTiles[key] and not mw.ratingTiles[keepKey] then
                mw.ratingTiles[keepKey] = mw.ratingTiles[key]
            end
            mw.ratingTiles[key] = nil
        end
    end

    PVPHUB_DB[key] = nil
end

-- Merges fromKey into toKey: match history joined (no duplicates), every
-- field toKey doesn't have copied over (note, gear, ...), group and Custom
-- Order place carried over, archived seasons moved; then fromKey is gone.
function Chars.Merge(fromKey, toKey)
    local from, to = PVPHUB_DB[fromKey], PVPHUB_DB[toKey]
    if not (IsCharKey(fromKey, from) and IsCharKey(toKey, to)) or fromKey == toKey then return end
    if PVPHUB._SnapshotWipeBackup then PVPHUB._SnapshotWipeBackup("merging " .. fromKey .. " into " .. toKey) end

    -- Match history, oldest first, each match once
    if type(from.mmrHistory) == "table" then
        to.mmrHistory = to.mmrHistory or {}
        for bracketKey, matches in pairs(from.mmrHistory) do
            if type(matches) == "table" then
                local list = to.mmrHistory[bracketKey] or {}
                local seen = {}
                for _, m in ipairs(list) do seen[(m.timestamp or 0) .. ":" .. (m.rating or 0)] = true end
                for _, m in ipairs(matches) do
                    local id = (m.timestamp or 0) .. ":" .. (m.rating or 0)
                    if not seen[id] then
                        list[#list + 1] = Copy(m)
                        seen[id] = true
                    end
                end
                table.sort(list, function(a, b) return (a.timestamp or 0) < (b.timestamp or 0) end)
                to.mmrHistory[bracketKey] = list
            end
        end
    end

    -- Everything else only where toKey has nothing; never its identity
    for k, v in pairs(from) do
        if to[k] == nil and k ~= "guid" and k ~= "lastSeen" and k ~= "firstSeen" then
            to[k] = Copy(v)
        end
    end
    if (to.note == nil or to.note == "") and from.note and from.note ~= "" then to.note = from.note end

    if PVPHUB.Seasons and PVPHUB.Seasons.MergeCharacter then PVPHUB.Seasons.MergeCharacter(fromKey, toKey) end
    Forget(fromKey, toKey)
    Print(string.format("|cff00ff00[PVPHUB]|r %s merged into %s.", fromKey, ClassColored(toKey)))
    Refresh()
end

-- Deletes characters for good (after a backup)
function Chars.Delete(keys)
    local list = {}
    for _, key in ipairs(keys) do
        if IsCharKey(key, PVPHUB_DB[key]) then list[#list + 1] = key end
    end
    if #list == 0 then return end
    if PVPHUB._SnapshotWipeBackup then
        PVPHUB._SnapshotWipeBackup(#list == 1 and ("deleting " .. list[1]) or ("deleting " .. #list .. " characters"))
    end
    for _, key in ipairs(list) do Forget(key) end
    Print(string.format("|cff00ff00[PVPHUB]|r Deleted %s. Manage Backups can bring %s back.",
        #list == 1 and list[1] or (#list .. " characters"), #list == 1 and "it" or "them"))
    Refresh()
end

StaticPopupDialogs["PVPHUB_TRANSFER_MERGE"] = {
    text = "%s looks like it moved to %s.\n\nMove its match history, note and group over and remove the old entry? A backup is taken first.",
    button1 = "Merge",
    button2 = "Later",
    button3 = "Not the same",
    OnAccept = function(_, data) Chars.Merge(data.from, data.to) end,
    OnAlt = function(_, data)
        Chars.Dismiss(data.from, data.to)
        if Chars.window and Chars.window:IsShown() then Chars.Render() end
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
}

StaticPopupDialogs["PVPHUB_CHARS_MERGE"] = {
    text = "Merge %s into %s?\n\nIts match history, note and group move over (nothing the second one already has is replaced), then the old entry is removed. A backup is taken first.",
    button1 = "Merge",
    button2 = "Cancel",
    OnAccept = function(_, data) Chars.Merge(data.from, data.to) end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
}

StaticPopupDialogs["PVPHUB_CHARS_DELETE"] = {
    text = "Permanently delete %s?\n\nA backup is taken first, so Settings > Advanced > Manage Backups can bring it back.",
    button1 = "Delete",
    button2 = "Cancel",
    OnAccept = function(_, data)
        Chars.Delete(data.keys)
        if Chars.selected then wipe(Chars.selected) end
        if Chars.window and Chars.window:IsShown() then Chars.Render() end
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
}

function Chars.AskMerge(fromKey, toKey)
    StaticPopup_Show("PVPHUB_CHARS_MERGE", ClassColored(fromKey), ClassColored(toKey), { from = fromKey, to = toKey })
end

function Chars.AskDelete(keys)
    if #keys == 0 then return end
    local what = #keys == 1 and ClassColored(keys[1]) or (#keys .. " characters")
    StaticPopup_Show("PVPHUB_CHARS_DELETE", what, nil, { keys = keys })
end

-- At login: note when this character was first seen, then (outside combat
-- and instances) ask about one earlier self, if there is one
local events = CreateFrame("Frame")
events:RegisterEvent("PLAYER_ENTERING_WORLD")
events:SetScript("OnEvent", function(self, _, isInitialLogin, isReload)
    if not (isInitialLogin or isReload) then return end
    C_Timer.After(8, function()
        local me = PVPHUB._GetFullName and PVPHUB._GetFullName()
        local data = me and PVPHUB_DB and PVPHUB_DB[me]
        if not IsCharKey(me or "", data) then return end
        data.firstSeen = data.firstSeen or GetServerTime()
        if data.level == nil or data.level == 0 then data.level = UnitLevel("player") end
        if InCombatLockdown() or IsInInstance() then return end
        local old = Chars.EarlierSelves(me)[1]
        if old then
            StaticPopup_Show("PVPHUB_TRANSFER_MERGE", ClassColored(old), ClassColored(me), { from = old, to = me })
        end
    end)
end)

-- --------------------------------------------------------------------------
-- Manage Characters window
-- --------------------------------------------------------------------------

local W, H = 600, 480
local ROW_H = 38

Chars.selected = {}   -- [charKey] = true, for "Delete selected"

local function NewText(parent, size)
    local fs = parent:CreateFontString(nil, "OVERLAY")
    PVPHUB._RegisterTrackedFont(fs, size, "OUTLINE")
    fs:SetShadowColor(0, 0, 0, 0.8)
    fs:SetShadowOffset(1, -1)
    fs:SetJustifyH("LEFT")
    fs:SetWordWrap(false)
    return fs
end

local function SmallButton(parent, text, width, danger)
    local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    b:SetSize(width, 20)
    b:SetText(text)
    b.pvpDanger = danger
    if PVPHUB.UI then PVPHUB.UI.SkinButton(b, danger and "danger" or nil) end
    return b
end

local function LastSeenText(lastSeen)
    if not lastSeen then return "|cff666666never seen|r" end
    local days = math.floor((GetServerTime() - lastSeen) / 86400)
    if days <= 0 then return "|cff44ff44seen today|r" end
    if days == 1 then return "|cffccff44seen yesterday|r" end
    if days < 7 then return string.format("|cffffaa22seen %d days ago|r", days) end
    return string.format("|cffff6644seen %d days ago|r", days)
end

-- Every stored character with what the window shows about it, suggestions
-- first, then long unseen ones, then by last seen
local function Collect(query)
    local me = PVPHUB._GetFullName and PVPHUB._GetFullName()
    local now = GetServerTime()
    local list = {}
    for key, data in pairs(PVPHUB_DB) do
        if IsCharKey(key, data) and (query == "" or key:lower():find(query, 1, true)) then
            local e = { key = key, data = data, me = key == me }
            e.movedTo = Chars.MovedTo(key)
            e.hidden = PVPHUB._IsCharacterHidden and PVPHUB._IsCharacterHidden(key)
            e.stale = data.lastSeen and (now - data.lastSeen) > STALE_DAYS * 86400
            e.rank = e.movedTo and 0 or (e.stale and 1 or 2)
            list[#list + 1] = e
        end
    end
    table.sort(list, function(a, b)
        if a.rank ~= b.rank then return a.rank < b.rank end
        return (a.data.lastSeen or 0) > (b.data.lastSeen or 0)
    end)
    return list
end

local function OpenRowMenu(row)
    local e = row.entry
    if not e or not MenuUtil then return end
    MenuUtil.CreateContextMenu(row.more, function(_, root)
        root:CreateTitle(ClassColored(e.key))
        if not e.me then
            local merge = root:CreateButton("Merge into")
            local targets = {}
            for key, data in pairs(PVPHUB_DB) do
                if IsCharKey(key, data) and key ~= e.key
                   and (not data.class or not e.data.class or data.class:upper() == e.data.class:upper()) then
                    targets[#targets + 1] = key
                end
            end
            table.sort(targets, function(a, b)
                if (a == e.movedTo) ~= (b == e.movedTo) then return a == e.movedTo end
                return a < b
            end)
            for _, key in ipairs(targets) do
                merge:CreateButton(ClassColored(key) .. (key == e.movedTo and "  |cffffd100(suggested)|r" or ""),
                    function() Chars.AskMerge(e.key, key) end)
            end
            if #targets == 0 then merge:CreateTitle("|cff888888No other character of this class|r") end
        end
        if e.hidden then
            root:CreateButton("Show in the list again", function()
                PVPHUB._UnhideCharacter(e.key)
                Chars.Render()
            end)
        elseif not e.me then
            root:CreateButton("Hide from the list", function()
                PVPHUB._HideCharacter(e.key)
                Chars.Render()
            end)
        end
        if e.movedTo then
            root:CreateButton("Not a transfer", function()
                Chars.Dismiss(e.key, e.movedTo)
                Chars.Render()
            end)
        end
        if not e.me then
            root:CreateDivider()
            root:CreateButton("|cffff4040Delete|r", function() Chars.AskDelete({ e.key }) end)
        end
    end)
end

local function CreateRow(parent)
    local row = CreateFrame("Button", nil, parent)
    row:SetHeight(ROW_H)
    row.band = row:CreateTexture(nil, "BACKGROUND")
    row.band:SetAllPoints()
    row.band:SetTexture("Interface\\Buttons\\WHITE8x8")
    local hl = row:CreateTexture(nil, "HIGHLIGHT")
    hl:SetAllPoints()
    hl:SetTexture("Interface\\Buttons\\WHITE8x8")
    hl:SetVertexColor(1, 1, 1, 0.05)

    row.name = NewText(row, 13)
    row.name:SetPoint("TOPLEFT", 10, -5)
    row.realm = NewText(row, 11)
    row.realm:SetPoint("TOPLEFT", row.name, "BOTTOMLEFT", 0, -2)
    row.info = NewText(row, 11)
    row.info:SetPoint("TOPLEFT", 210, -6)
    row.flag = NewText(row, 11)
    row.flag:SetPoint("TOPLEFT", row.info, "BOTTOMLEFT", 0, -3)

    row.more = SmallButton(row, "...", 30)
    row.more:SetPoint("RIGHT", -8, 0)
    row.more:SetScript("OnClick", function() OpenRowMenu(row) end)
    row.merge = SmallButton(row, "Merge", 64)
    row.merge:SetPoint("RIGHT", row.more, "LEFT", -6, 0)
    row.merge:SetScript("OnClick", function()
        local e = row.entry
        if e and e.movedTo then Chars.AskMerge(e.key, e.movedTo) end
    end)

    -- Clicking a row selects it for "Delete selected"; not your own character
    row:SetScript("OnClick", function(self)
        local e = self.entry
        if not e or e.me then return end
        Chars.selected[e.key] = not Chars.selected[e.key] or nil
        Chars.Render()
    end)
    return row
end

local function PaintRow(row, e, i, width)
    row.entry = e
    row:SetWidth(width)
    local selected = Chars.selected[e.key]
    if selected then
        row.band:SetVertexColor(1, 0.82, 0, 0.16)
    else
        row.band:SetVertexColor(1, 1, 1, (i % 2 == 0) and 0.03 or 0)
    end

    row.name:SetText(ClassColored(e.key, NameOf(e.key)) .. (e.me and "  |cff888888(you)|r" or ""))
    row.realm:SetText("|cff999999" .. RealmOf(e.key) .. "|r")
    local level = (e.data.level or 0) > 0 and ("|cffccccccLevel " .. e.data.level .. "|r  ·  ") or ""
    row.info:SetText(level .. LastSeenText(e.data.lastSeen))

    local flags = {}
    if e.movedTo then flags[#flags + 1] = "|cffffd100Probably moved to " .. RealmOf(e.movedTo) .. "|r" end
    if e.hidden then flags[#flags + 1] = "|cff888888Hidden|r" end
    if e.stale and not e.movedTo then flags[#flags + 1] = string.format("|cffff8040Not seen in %d+ days|r", STALE_DAYS) end
    row.flag:SetText(table.concat(flags, "   "))

    row.merge:SetShown(e.movedTo ~= nil)
end

local function CreateWindow()
    local win = CreateFrame("Frame", "PVPHUBManageCharactersWindow", UIParent)
    win:SetSize(W, H)
    win:SetPoint("CENTER")
    win:SetFrameStrata("DIALOG")
    win:SetMovable(true)
    win:EnableMouse(true)
    win:RegisterForDrag("LeftButton")
    win:SetClampedToScreen(true)
    win:SetScript("OnDragStart", win.StartMoving)
    win:SetScript("OnDragStop", win.StopMovingOrSizing)
    tinsert(UISpecialFrames, "PVPHUBManageCharactersWindow")
    if PVPHUB.UI then PVPHUB.UI.SkinWindow(win) end

    local title = NewText(win, 15)
    title:SetPoint("TOP", 0, -16)
    title:SetJustifyH("CENTER")
    title:SetText("|cffffd100Manage Characters|r")

    local note = NewText(win, 11)
    note:SetPoint("TOP", 0, -38)
    note:SetWidth(W - 60)
    note:SetWordWrap(true)
    note:SetJustifyH("CENTER")
    note:SetText("|cff999999Every character PVPHUB has stored, hidden ones too. Merge an old entry into the character it became after a server transfer, or remove characters you don't need. A backup is taken before every change.|r")

    local close = CreateFrame("Button", nil, win, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", -6, -6)
    close:SetScript("OnClick", function() win:Hide() end)
    if PVPHUB.UI then PVPHUB.UI.SkinCloseButton(close) end

    local search = CreateFrame("EditBox", nil, win, "SearchBoxTemplate")
    search:SetSize(220, 20)
    search:SetPoint("TOPLEFT", 26, -80)
    search:SetAutoFocus(false)
    search:HookScript("OnTextChanged", function() Chars.Render() end)
    win.search = search

    win.count = NewText(win, 11)
    win.count:SetPoint("TOPRIGHT", -24, -84)
    win.count:SetJustifyH("RIGHT")

    local scroll = CreateFrame("ScrollFrame", nil, win, "ScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 16, -110)
    scroll:SetPoint("BOTTOMRIGHT", -30, 52)
    if PVPHUB._ApplyModernScrollbarStyling then PVPHUB._ApplyModernScrollbarStyling(scroll, PVPHUB.currentColors) end
    if PVPHUB.EnableSmoothScroll then PVPHUB.EnableSmoothScroll(scroll, 40) end
    local content = CreateFrame("Frame", nil, scroll)
    content:SetSize(W - 46, 1)
    scroll:SetScrollChild(content)
    win.scroll, win.content, win.rows = scroll, content, {}

    win.empty = NewText(content, 12)
    win.empty:SetPoint("TOP", 0, -30)
    win.empty:SetText("|cff888888No characters match.|r")

    win.deleteSelected = SmallButton(win, "Delete selected", 150, true)
    win.deleteSelected:SetHeight(24)
    win.deleteSelected:SetPoint("BOTTOMLEFT", 20, 16)
    win.deleteSelected:SetScript("OnClick", function()
        local keys = {}
        for key in pairs(Chars.selected) do keys[#keys + 1] = key end
        table.sort(keys)
        Chars.AskDelete(keys)
    end)

    win.hint = NewText(win, 10)
    win.hint:SetPoint("LEFT", win.deleteSelected, "RIGHT", 12, 0)
    win.hint:SetText("|cff777777Click rows to select them|r")

    local done = SmallButton(win, "Close", 90)
    done:SetHeight(24)
    done:SetPoint("BOTTOMRIGHT", -20, 16)
    done:SetScript("OnClick", function() win:Hide() end)

    win:SetScript("OnHide", function() wipe(Chars.selected) end)
    win:Hide()
    Chars.window = win
    return win
end

function Chars.Render()
    local win = Chars.window
    if not win then return end
    -- Drop selections of characters that are gone
    for key in pairs(Chars.selected) do
        if not PVPHUB_DB[key] then Chars.selected[key] = nil end
    end

    local query = (win.search:GetText() or ""):lower()
    local list = Collect(query)
    local width = win.content:GetWidth()
    local suggestions, selected = 0, 0
    for i, e in ipairs(list) do
        local row = win.rows[i] or CreateRow(win.content)
        win.rows[i] = row
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", 0, -(i - 1) * ROW_H)
        PaintRow(row, e, i, width)
        row:Show()
        if e.movedTo then suggestions = suggestions + 1 end
    end
    for i = #list + 1, #win.rows do win.rows[i]:Hide() end
    for _ in pairs(Chars.selected) do selected = selected + 1 end
    win.content:SetHeight(math.max(1, #list * ROW_H))
    win.empty:SetShown(#list == 0)

    win.count:SetText(string.format("|cff999999%d characters|r%s", #list,
        suggestions > 0 and string.format("  |cffffd100· %d possible transfer%s|r", suggestions, suggestions == 1 and "" or "s") or ""))
    win.deleteSelected:SetText(selected > 0 and ("Delete selected (" .. selected .. ")") or "Delete selected")
    -- Enable/Disable rather than SetEnabled: the UI kit repaints on those
    if selected > 0 then win.deleteSelected:Enable() else win.deleteSelected:Disable() end
end

-- Opens the window; with charKey, filtered to that character
function Chars.Open(charKey)
    local win = Chars.window or CreateWindow()
    win:Show()
    win.search:SetText(charKey and NameOf(charKey) or "")
    Chars.Render()
end
