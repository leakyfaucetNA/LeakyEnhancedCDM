-- settings.lua
-- Native-WoW settings panel for LECDM. No AceGUI — uses CreateFrame + BackdropTemplate
-- so the look matches DandersFrames (dark charcoal w/ purple accent).
--
-- Layout:
--   [TitleBar]
--   [SpecBar: 40x40 spec icons — active spec has blue border]
--   [Left panel]    [Right panel]
--    Auras / CDs     Enable  +Glow +Sound +Event
--    spell list       sub-module accordion (one expanded at a time)

local _, ns = ...

local LSM = LibStub("LibSharedMedia-3.0")

-- -------------------------------------------------- --
--  Theme                                             --
-- -------------------------------------------------- --

local TEX        = "Interface\\Buttons\\WHITE8x8"
local C_BG       = {0.08, 0.08, 0.08, 0.95}
local C_PANEL    = {0.12, 0.12, 0.12, 1}
local C_ELEM     = {0.18, 0.18, 0.18, 1}
local C_BDR      = {0.25, 0.25, 0.25, 1}
local C_ACCENT   = {0.45, 0.45, 0.95, 1}
local C_HOVER    = {0.22, 0.22, 0.22, 1}
local C_TEXT     = {0.90, 0.90, 0.90, 1}
local C_DIM      = {0.60, 0.60, 0.60, 1}
local C_ROWACC   = {0.45, 0.45, 0.95, 0.55}  -- sub-module row (semi-transparent accent)

local TITLE_H  = 28
local SPEC_H   = 54
local LEFT_W   = 260
local ROW_H    = 48
local SUB_H    = 32
local PAD      = 8

-- -------------------------------------------------- --
--  State                                             --
-- -------------------------------------------------- --

local frame
local selectedSpecID
local selectedCat   = "auras"    -- "auras" | "cds"
local selectedKey              -- spell map key (entry._lecName)
local expandedUID              -- open sub-module uid in right panel

-- -------------------------------------------------- --
--  Primitive helpers                                 --
-- -------------------------------------------------- --

local function SetBD(f, bg, bdr)
    f:SetBackdrop({
        bgFile   = TEX,
        edgeFile = TEX,
        edgeSize = 1,
        insets   = { left = 1, right = 1, top = 1, bottom = 1 },
    })
    f:SetBackdropColor(unpack(bg))
    f:SetBackdropBorderColor(unpack(bdr or C_BDR))
end

local function MakePanel(parent, bg, bdr)
    local f = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    SetBD(f, bg or C_PANEL, bdr or C_BDR)
    return f
end

local function MakeLabel(parent, text, size, color)
    local fs = parent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    if size then
        local font = fs:GetFont()
        fs:SetFont(font, size, "")
    end
    fs:SetText(text or "")
    fs:SetTextColor(unpack(color or C_TEXT))
    return fs
end

local function MakeButton(parent, text, w, h)
    local b = CreateFrame("Button", nil, parent, "BackdropTemplate")
    SetBD(b, C_ELEM, C_BDR)
    b:SetSize(w or 70, h or 22)
    local fs = b:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    fs:SetPoint("CENTER")
    fs:SetText(text or "")
    fs:SetTextColor(unpack(C_TEXT))
    b.text = fs
    b:SetScript("OnEnter", function(s) s:SetBackdropColor(unpack(C_HOVER)) end)
    b:SetScript("OnLeave", function(s) s:SetBackdropColor(unpack(C_ELEM)) end)
    return b
end

local function MakeAccentButton(parent, text, w, h)
    local b = MakeButton(parent, text, w, h)
    b:SetBackdropColor(unpack(C_ACCENT))
    b:SetScript("OnEnter", function(s) s:SetBackdropColor(0.55, 0.55, 1.0, 1) end)
    b:SetScript("OnLeave", function(s) s:SetBackdropColor(unpack(C_ACCENT)) end)
    return b
end

local function MakeCheck(parent)
    local c = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    SetBD(c, C_ELEM, C_BDR)
    c:SetSize(18, 18)
    c:EnableMouse(true)

    local fill = c:CreateTexture(nil, "OVERLAY")
    fill:SetTexture(TEX)
    fill:SetPoint("TOPLEFT", 3, -3)
    fill:SetPoint("BOTTOMRIGHT", -3, 3)
    fill:SetVertexColor(unpack(C_ACCENT))
    fill:Hide()
    c.fill = fill

    function c:SetChecked(v)
        if v then fill:Show() else fill:Hide() end
    end
    function c:GetChecked() return fill:IsShown() end

    c:SetScript("OnMouseUp", function(s, btn)
        if btn ~= "LeftButton" then return end
        s:SetChecked(not s:GetChecked())
        if s.onChanged then s.onChanged(s:GetChecked()) end
    end)
    return c
end

local function MakeEdit(parent, w, h)
    local holder = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    SetBD(holder, C_ELEM, C_BDR)
    holder:SetSize(w or 160, h or 22)

    local eb = CreateFrame("EditBox", nil, holder)
    eb:SetPoint("TOPLEFT", 6, -3)
    eb:SetPoint("BOTTOMRIGHT", -6, 3)
    eb:SetAutoFocus(false)
    eb:SetFontObject("GameFontNormal")
    eb:SetTextColor(unpack(C_TEXT))
    eb:SetScript("OnEscapePressed", eb.ClearFocus)
    eb:SetScript("OnEnterPressed", eb.ClearFocus)
    holder.edit = eb
    return holder
end

-- Shared dropdown popup — only one dropdown open at a time.
-- Closes on: item click, owner re-click, or click outside (via clickCatcher).
-- Mouseover-based close was dropped because the 2px gap between owner and popup
-- briefly has the mouse over neither frame, triggering an instant close.
-- Scrolls when items exceed DROP_VISIBLE_ROWS.
local DROP_ROW_H        = 22
local DROP_VISIBLE_ROWS = 13

local dropPopup, dropScroll, dropScrollChild, clickCatcher
local function GetDropPopup()
    if dropPopup then return dropPopup end

    clickCatcher = CreateFrame("Button", nil, UIParent)
    clickCatcher:SetAllPoints(UIParent)
    clickCatcher:SetFrameStrata("FULLSCREEN_DIALOG")
    clickCatcher:RegisterForClicks("AnyUp")
    clickCatcher:Hide()
    -- Rows are children of dropPopup (frame level +10 above catcher) so row clicks
    -- beat catcher clicks. Catcher only fires when user clicks anywhere else — which
    -- is the signal to close. Owner re-click also closes (no reopen) — toggle behavior.
    clickCatcher:SetScript("OnClick", function()
        if dropPopup then dropPopup:Hide() end
    end)

    dropPopup = CreateFrame("Frame", "LECDMDropPopup", UIParent, "BackdropTemplate")
    SetBD(dropPopup, C_PANEL, C_BDR)
    dropPopup:SetFrameStrata("FULLSCREEN_DIALOG")
    dropPopup:SetFrameLevel(clickCatcher:GetFrameLevel() + 10)
    dropPopup:Hide()
    dropPopup.rows = {}
    dropPopup:SetScript("OnShow", function() clickCatcher:Show() end)
    dropPopup:SetScript("OnHide", function() clickCatcher:Hide() end)

    dropScroll = CreateFrame("ScrollFrame", nil, dropPopup)
    dropScroll:SetPoint("TOPLEFT",     dropPopup, "TOPLEFT",      1,  -1)
    dropScroll:SetPoint("BOTTOMRIGHT", dropPopup, "BOTTOMRIGHT", -1,   1)
    dropScroll:EnableMouseWheel(true)
    dropScroll:SetScript("OnMouseWheel", function(self, delta)
        local maxScroll = math.max(0, (dropScrollChild:GetHeight() or 0) - (self:GetHeight() or 0))
        local new = math.max(0, math.min(maxScroll, (self:GetVerticalScroll() or 0) - delta * DROP_ROW_H))
        self:SetVerticalScroll(new)
    end)

    dropScrollChild = CreateFrame("Frame", nil, dropScroll)
    dropScrollChild:SetSize(1, 1)
    dropScroll:SetScrollChild(dropScrollChild)

    return dropPopup
end

local function ShowDropdown(owner, items, onPick)
    local pop = GetDropPopup()
    pop.owner = owner
    for _, r in ipairs(pop.rows) do r:Hide() end

    local rowW = math.max(owner:GetWidth(), 160)
    for i, it in ipairs(items) do
        local row = pop.rows[i]
        if not row then
            row = CreateFrame("Button", nil, dropScrollChild, "BackdropTemplate")
            SetBD(row, C_PANEL, C_PANEL)
            row.text = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
            row.text:SetPoint("LEFT", 8, 0)
            row:SetScript("OnEnter", function(s) s:SetBackdropColor(unpack(C_HOVER)) end)
            row:SetScript("OnLeave", function(s) s:SetBackdropColor(unpack(C_PANEL)) end)
            pop.rows[i] = row
        end
        row:SetSize(rowW, DROP_ROW_H)
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", 0, -(i - 1) * DROP_ROW_H)
        row.text:SetText(it.label)
        row.text:SetTextColor(unpack(C_TEXT))
        row:SetScript("OnClick", function()
            pop:Hide()
            if onPick then onPick(it.value, it.label) end
        end)
        row:Show()
    end

    local visible = math.min(#items, DROP_VISIBLE_ROWS)
    pop:SetSize(rowW + 2, visible * DROP_ROW_H + 2)
    dropScrollChild:SetSize(rowW, #items * DROP_ROW_H)
    dropScroll:SetVerticalScroll(0)
    pop:ClearAllPoints()
    pop:SetPoint("TOPLEFT", owner, "BOTTOMLEFT", 0, -2)
    pop:Show()
end

local function MakeDropdown(parent, w, h)
    local b = CreateFrame("Button", nil, parent, "BackdropTemplate")
    SetBD(b, C_ELEM, C_BDR)
    b:SetSize(w or 180, h or 22)
    b.text = b:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    b.text:SetPoint("LEFT", 8, 0)
    b.text:SetPoint("RIGHT", -18, 0)
    b.text:SetJustifyH("LEFT")
    b.text:SetTextColor(unpack(C_TEXT))

    local arrow = b:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    arrow:SetPoint("RIGHT", -6, 0)
    arrow:SetText("v")
    arrow:SetTextColor(unpack(C_DIM))

    b:SetScript("OnEnter", function(s) s:SetBackdropColor(unpack(C_HOVER)) end)
    b:SetScript("OnLeave", function(s) s:SetBackdropColor(unpack(C_ELEM)) end)

    function b:SetValue(label) self.text:SetText(label or "") end
    function b:Open(items, onPick) ShowDropdown(self, items, onPick) end
    return b
end

-- Click swatch opens ColorPickerFrame. cb(r,g,b,a) fires on any change/confirm.
local function MakeColorSwatch(parent, initial, cb)
    local b = CreateFrame("Button", nil, parent, "BackdropTemplate")
    SetBD(b, C_ELEM, C_BDR)
    b:SetSize(40, 18)
    local tex = b:CreateTexture(nil, "OVERLAY")
    tex:SetTexture(TEX)
    tex:SetPoint("TOPLEFT", 2, -2)
    tex:SetPoint("BOTTOMRIGHT", -2, 2)
    tex:SetVertexColor(initial[1] or 1, initial[2] or 1, initial[3] or 1, initial[4] or 1)
    b.tex = tex
    b.rgba = { initial[1] or 1, initial[2] or 1, initial[3] or 1, initial[4] or 1 }

    b:SetScript("OnClick", function()
        local r, g, b_, a = unpack(b.rgba)
        local info = {
            swatchFunc = function()
                local nr, ng, nb = ColorPickerFrame:GetColorRGB()
                b.rgba[1], b.rgba[2], b.rgba[3] = nr, ng, nb
                tex:SetVertexColor(nr, ng, nb, b.rgba[4])
                if cb then cb(unpack(b.rgba)) end
            end,
            opacityFunc = function()
                b.rgba[4] = 1 - (ColorPickerFrame:GetColorAlpha() or 0)
                tex:SetVertexColor(b.rgba[1], b.rgba[2], b.rgba[3], b.rgba[4])
                if cb then cb(unpack(b.rgba)) end
            end,
            cancelFunc = function(prev)
                b.rgba[1], b.rgba[2], b.rgba[3], b.rgba[4] =
                    prev.r or 1, prev.g or 1, prev.b or 1, 1 - (prev.opacity or 0)
                tex:SetVertexColor(unpack(b.rgba))
                if cb then cb(unpack(b.rgba)) end
            end,
            hasOpacity = true,
            opacity    = 1 - (a or 1),
            r = r, g = g, b = b_,
        }
        if ColorPickerFrame.SetupColorPickerAndShow then
            ColorPickerFrame:SetupColorPickerAndShow(info)
        else
            ColorPickerFrame.func = info.swatchFunc
            ColorPickerFrame.opacityFunc = info.opacityFunc
            ColorPickerFrame.cancelFunc  = info.cancelFunc
            ColorPickerFrame.hasOpacity  = true
            ColorPickerFrame.opacity     = info.opacity
            ColorPickerFrame:SetColorRGB(r, g, b_)
            ShowUIPanel(ColorPickerFrame)
        end
    end)
    return b
end

-- -------------------------------------------------- --
--  Data helpers                                      --
-- -------------------------------------------------- --

local function GetMap()
    return (selectedCat == "auras") and ns.auraFrameMap or ns.cdFrameMap
end

local function GetItemType()
    return (selectedCat == "auras") and "auraTrigger" or "cdTrigger"
end

local function FindItem(spellID, specID)
    if not spellID or not LECDM or not LECDM.db then return nil end
    for itemID, item in pairs(LECDM.db.profile.items) do
        if item.spellID == spellID
           and item.type == GetItemType()
           and (not specID or (item.specID == specID)) then
            return itemID, item
        end
    end
end

local function GetOrCreateItem(spellID, name)
    local existingID, existing = FindItem(spellID, selectedSpecID)
    if existing then return existingID, existing end

    local id = ns.GenerateUID()
    local item = {
        type     = GetItemType(),
        spellID  = spellID,
        specID   = selectedSpecID,
        name     = name,
        enabled  = true,
        glows    = {},
        sounds   = {},
        events   = {},
    }
    LECDM.db.profile.items[id] = item
    return id, item
end

-- Refresh tracking modules after config edits.
local function RefreshAll()
    if not LECDM or not LECDM.db then return end
    ns.SetupGlows(LECDM)
    ns.SetupSounds(LECDM)
    ns.SetupEvents(LECDM)
end

-- -------------------------------------------------- --
--  Option panels                                     --
-- -------------------------------------------------- --

local FRAMELEVEL_LABELS = { "Low (20)", "Normal (60)", "High (100)" }
local FRAMELEVEL_VALS   = { 20, 60, 100 }
local GLOW_TYPES        = { "Pixel", "AutoCast", "Proc", "Button" }
local CHANNELS          = { "Master", "SFX", "Music", "Ambience", "Dialog" }
local REPEAT_MODES      = { "once", "count", "loop" }

local function AuraTriggers()
    return { {label="On Aura Added", value="onAdd"}, {label="On Aura Removed", value="onRemove"} }
end
local function CDTriggers()
    return { {label="On CD Ready", value="onReady"}, {label="On CD Used", value="onUsed"} }
end

local function TriggersForType()
    return (selectedCat == "auras") and AuraTriggers() or CDTriggers()
end

local function Row(parent, yOff, label)
    local fs = MakeLabel(parent, label, nil, C_DIM)
    fs:SetPoint("TOPLEFT", PAD, yOff)
    fs:SetWidth(100)
    fs:SetJustifyH("LEFT")
    return fs
end

-- Forward-declared so option panels can request an accordion rebuild when a
-- field change needs to show/hide dependent widgets (e.g. repeat count/interval
-- only apply when repeat mode isn't "once").
local BuildSubmoduleList

-- Build glow options panel.
local function CreateGlowPanel(parent, gc)
    local p = MakePanel(parent, C_PANEL, C_BDR)
    local y = -PAD

    Row(p, y, "Name")
    local nameE = MakeEdit(p, 220, 22)
    nameE:SetPoint("TOPLEFT", PAD + 108, y + 4)
    nameE.edit:SetText(gc.name or "")
    nameE.edit:SetScript("OnEditFocusLost", function(e)
        gc.name = e:GetText()
    end)
    y = y - 30

    Row(p, y, "Enabled")
    local en = MakeCheck(p)
    en:SetPoint("TOPLEFT", PAD + 108, y + 4)
    en:SetChecked(gc.enabled ~= false)
    en.onChanged = function(v) gc.enabled = v; RefreshAll() end
    y = y - 30

    Row(p, y, "Trigger")
    local trig = MakeDropdown(p, 180, 22)
    trig:SetPoint("TOPLEFT", PAD + 108, y + 4)
    local function trigLabel(v)
        for _, it in ipairs(TriggersForType()) do if it.value == v then return it.label end end
        return v or ""
    end
    trig:SetValue(trigLabel(gc.triggerOn))
    trig:SetScript("OnClick", function(s)
        s:Open(TriggersForType(), function(v, l)
            gc.triggerOn = v; trig:SetValue(l); RefreshAll()
        end)
    end)
    y = y - 30

    Row(p, y, "Target")
    local tgt = MakeDropdown(p, 220, 22)
    tgt:SetPoint("TOPLEFT", PAD + 108, y + 4)
    tgt:SetValue(tostring(gc.frameKey or "(spell frame)"))
    tgt:SetScript("OnClick", function(s)
        local items = {}
        local map = GetMap()
        table.insert(items, { label = "(this spell's frame)", value = false })
        for key, entry in pairs(map) do
            if entry._lecSpellID then
                table.insert(items, { label = key, value = entry._lecSpellID })
            end
        end
        table.sort(items, function(a, b)
            if a.value == false then return true end
            if b.value == false then return false end
            return tostring(a.label) < tostring(b.label)
        end)
        s:Open(items, function(v, l)
            if v == false then
                gc.frameKey = gc.spellID or nil
            else
                gc.frameKey = v
            end
            tgt:SetValue(l); RefreshAll()
        end)
    end)
    y = y - 30

    Row(p, y, "Glow Type")
    local gtype = MakeDropdown(p, 140, 22)
    gtype:SetPoint("TOPLEFT", PAD + 108, y + 4)
    gtype:SetValue(gc.glowType or "Pixel")
    gtype:SetScript("OnClick", function(s)
        local items = {}
        for _, t in ipairs(GLOW_TYPES) do table.insert(items, {label=t, value=t}) end
        s:Open(items, function(v) gc.glowType = v; gtype:SetValue(v); RefreshAll() end)
    end)
    y = y - 30

    Row(p, y, "Color")
    local rgba = gc.rgba or {0.3, 0.8, 1.0, 1.0}
    gc.rgba = rgba
    local sw = MakeColorSwatch(p, rgba, function(r, g, b_, a)
        gc.rgba = {r, g, b_, a}; RefreshAll()
    end)
    sw:SetPoint("TOPLEFT", PAD + 108, y + 2)
    y = y - 30

    Row(p, y, "Frame Level")
    local fl = MakeDropdown(p, 140, 22)
    fl:SetPoint("TOPLEFT", PAD + 108, y + 4)
    local function flLabel(v)
        for i, vv in ipairs(FRAMELEVEL_VALS) do if vv == v then return FRAMELEVEL_LABELS[i] end end
        return tostring(v or 20)
    end
    fl:SetValue(flLabel(gc.frameLevel or 20))
    fl:SetScript("OnClick", function(s)
        local items = {}
        for i, lbl in ipairs(FRAMELEVEL_LABELS) do
            table.insert(items, { label = lbl, value = FRAMELEVEL_VALS[i] })
        end
        s:Open(items, function(v, l) gc.frameLevel = v; fl:SetValue(l); RefreshAll() end)
    end)
    y = y - 30

    Row(p, y, "Inverse")
    local inv = MakeCheck(p)
    inv:SetPoint("TOPLEFT", PAD + 108, y + 4)
    inv:SetChecked(gc.inverse == true)
    inv.onChanged = function(v) gc.inverse = v; RefreshAll() end
    y = y - 30

    p:SetHeight(-y + PAD)
    return p
end

local function CreateSoundPanel(parent, sc)
    local p = MakePanel(parent, C_PANEL, C_BDR)
    local y = -PAD

    Row(p, y, "Name")
    local nameE = MakeEdit(p, 220, 22)
    nameE:SetPoint("TOPLEFT", PAD + 108, y + 4)
    nameE.edit:SetText(sc.name or "")
    nameE.edit:SetScript("OnEditFocusLost", function(e) sc.name = e:GetText() end)
    y = y - 30

    Row(p, y, "Enabled")
    local en = MakeCheck(p)
    en:SetPoint("TOPLEFT", PAD + 108, y + 4)
    en:SetChecked(sc.enabled ~= false)
    en.onChanged = function(v) sc.enabled = v; RefreshAll() end
    y = y - 30

    Row(p, y, "Trigger")
    local trig = MakeDropdown(p, 180, 22)
    trig:SetPoint("TOPLEFT", PAD + 108, y + 4)
    local function trigLabel(v)
        for _, it in ipairs(TriggersForType()) do if it.value == v then return it.label end end
        return v or ""
    end
    trig:SetValue(trigLabel(sc.triggerOn))
    trig:SetScript("OnClick", function(s)
        s:Open(TriggersForType(), function(v, l)
            sc.triggerOn = v; trig:SetValue(l); RefreshAll()
        end)
    end)
    y = y - 30

    Row(p, y, "Sound")
    local snd = MakeDropdown(p, 220, 22)
    snd:SetPoint("TOPLEFT", PAD + 108, y + 4)
    snd:SetValue(tostring(sc.soundName or ""))
    snd:SetScript("OnClick", function(s)
        local items = {}
        local list = LSM:List("sound")
        for _, name in ipairs(list) do
            table.insert(items, { label = name, value = name })
        end
        s:Open(items, function(v) sc.soundName = v; snd:SetValue(v); RefreshAll() end)
    end)

    local preview = MakeButton(p, "Play", 50, 22)
    preview:SetPoint("LEFT", snd, "RIGHT", 6, 0)
    preview:SetScript("OnClick", function()
        if not sc.soundName or sc.soundName == "" then return end
        local path = LSM:Fetch("sound", sc.soundName) or sc.soundName
        PlaySoundFile(path, sc.channel or "Master")
    end)
    y = y - 30

    Row(p, y, "Channel")
    local ch = MakeDropdown(p, 120, 22)
    ch:SetPoint("TOPLEFT", PAD + 108, y + 4)
    ch:SetValue(sc.channel or "Master")
    ch:SetScript("OnClick", function(s)
        local items = {}
        for _, c in ipairs(CHANNELS) do table.insert(items, {label=c, value=c}) end
        s:Open(items, function(v) sc.channel = v; ch:SetValue(v) end)
    end)
    y = y - 30

    Row(p, y, "Repeat")
    local rm = MakeDropdown(p, 100, 22)
    rm:SetPoint("TOPLEFT", PAD + 108, y + 4)
    rm:SetValue(sc.repeatMode or "once")
    rm:SetScript("OnClick", function(s)
        local items = {}
        for _, m in ipairs(REPEAT_MODES) do table.insert(items, {label=m, value=m}) end
        s:Open(items, function(v)
            sc.repeatMode = v
            rm:SetValue(v)
            RefreshAll()
            -- Rebuild so count/interval show or hide to match the new mode.
            if BuildSubmoduleList then BuildSubmoduleList() end
        end)
    end)
    y = y - 30

    -- Count and interval only apply when repeating — sounds.lua ignores them in
    -- "once" mode, and cluttering the panel with disabled inputs isn't useful.
    if (sc.repeatMode or "once") ~= "once" then
        Row(p, y, "Count")
        local cnt = MakeEdit(p, 60, 22)
        cnt:SetPoint("TOPLEFT", PAD + 108, y + 4)
        cnt.edit:SetNumeric(true)
        cnt.edit:SetText(tostring(sc.repeatCount or 1))
        cnt.edit:SetScript("OnEditFocusLost", function(e)
            sc.repeatCount = tonumber(e:GetText()) or 1; RefreshAll()
        end)
        y = y - 30

        Row(p, y, "Interval (s)")
        local iv = MakeEdit(p, 60, 22)
        iv:SetPoint("TOPLEFT", PAD + 108, y + 4)
        iv.edit:SetText(tostring(sc.repeatInterval or 1))
        iv.edit:SetScript("OnEditFocusLost", function(e)
            sc.repeatInterval = tonumber(e:GetText()) or 1; RefreshAll()
        end)
        y = y - 30
    end

    p:SetHeight(-y + PAD)
    return p
end

local function CreateEventPanel(parent, ec)
    local p = MakePanel(parent, C_PANEL, C_BDR)
    local y = -PAD

    Row(p, y, "Name")
    local nameE = MakeEdit(p, 220, 22)
    nameE:SetPoint("TOPLEFT", PAD + 108, y + 4)
    nameE.edit:SetText(ec.name or "")
    nameE.edit:SetScript("OnEditFocusLost", function(e) ec.name = e:GetText() end)
    y = y - 30

    Row(p, y, "Enabled")
    local en = MakeCheck(p)
    en:SetPoint("TOPLEFT", PAD + 108, y + 4)
    en:SetChecked(ec.enabled ~= false)
    en.onChanged = function(v) ec.enabled = v; RefreshAll() end
    y = y - 30

    Row(p, y, "Trigger")
    local trig = MakeDropdown(p, 180, 22)
    trig:SetPoint("TOPLEFT", PAD + 108, y + 4)
    local function trigLabel(v)
        for _, it in ipairs(TriggersForType()) do if it.value == v then return it.label end end
        return v or ""
    end
    trig:SetValue(trigLabel(ec.triggerOn))
    trig:SetScript("OnClick", function(s)
        s:Open(TriggersForType(), function(v, l)
            ec.triggerOn = v; trig:SetValue(l); RefreshAll()
        end)
    end)
    y = y - 30

    Row(p, y, "Event Name")
    local evE = MakeEdit(p, 260, 22)
    evE:SetPoint("TOPLEFT", PAD + 108, y + 4)
    evE.edit:SetText(ec.eventName or "")
    evE.edit:SetScript("OnEditFocusLost", function(e)
        ec.eventName = e:GetText(); RefreshAll()
    end)
    y = y - 30

    p:SetHeight(-y + PAD)
    return p
end

-- -------------------------------------------------- --
--  Right panel — sub-module accordion                --
-- -------------------------------------------------- --

local rightPanel, rightHeader, subScroll, subContent
local subRows, subPanels = {}, {}

local function ClearRightContent()
    for _, r in ipairs(subRows)   do r:Hide() end
    for _, p in ipairs(subPanels) do p:Hide() end
    wipe(subRows); wipe(subPanels)
end

function BuildSubmoduleList()
    ClearRightContent()
    if not selectedKey then return end

    local map = GetMap()
    local entry = map[selectedKey]
    if not entry or not entry._lecSpellID then return end
    local spellID = entry._lecSpellID

    local _, item = FindItem(spellID, selectedSpecID)
    if not item then return end

    local rowIdx = 0
    local yOff   = 0

    local function AddSubRow(kind, uid, sc)
        rowIdx = rowIdx + 1
        local row = CreateFrame("Button", nil, subContent, "BackdropTemplate")
        SetBD(row, C_ROWACC, C_BDR)
        row:SetHeight(SUB_H)
        row:SetPoint("TOPLEFT", 0, yOff)
        row:SetPoint("TOPRIGHT", 0, yOff)
        row.text = row:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
        row.text:SetPoint("LEFT", 10, 0)
        row.text:SetText(kind .. ": " .. (sc.name or "(unnamed)"))
        row.text:SetTextColor(unpack(sc.enabled ~= false and C_TEXT or C_DIM))

        local del = MakeButton(row, "x", 22, 18)
        del:SetPoint("RIGHT", -6, 0)
        del:SetScript("OnClick", function()
            if kind == "Glow"  then item.glows[uid]  = nil end
            if kind == "Sound" then item.sounds[uid] = nil end
            if kind == "Event" then item.events[uid] = nil end
            if expandedUID == uid then expandedUID = nil end
            RefreshAll()
            BuildSubmoduleList()
        end)

        row:SetScript("OnClick", function()
            if expandedUID == uid then expandedUID = nil else expandedUID = uid end
            BuildSubmoduleList()
        end)

        table.insert(subRows, row)
        yOff = yOff - (SUB_H + 4)

        if expandedUID == uid then
            local panel
            if kind == "Glow"  then panel = CreateGlowPanel(subContent, sc) end
            if kind == "Sound" then panel = CreateSoundPanel(subContent, sc) end
            if kind == "Event" then panel = CreateEventPanel(subContent, sc) end
            panel:SetPoint("TOPLEFT", 0, yOff)
            panel:SetPoint("TOPRIGHT", 0, yOff)
            table.insert(subPanels, panel)
            yOff = yOff - (panel:GetHeight() + 6)
        end
    end

    if item.glows then
        for uid, gc in pairs(item.glows) do AddSubRow("Glow", uid, gc) end
    end
    if item.sounds then
        for uid, sc in pairs(item.sounds) do AddSubRow("Sound", uid, sc) end
    end
    if item.events then
        for uid, ec in pairs(item.events) do AddSubRow("Event", uid, ec) end
    end

    subContent:SetHeight(math.max(1, -yOff + 10))
end

local function AddSubmodule(kind)
    local map = GetMap()
    local entry = selectedKey and map[selectedKey]
    if not entry or not entry._lecSpellID then return end
    local spellID = entry._lecSpellID

    local _, item = GetOrCreateItem(spellID, entry._lecName)

    local uid = ns.GenerateUID()
    if kind == "Glow" then
        item.glows = item.glows or {}
        item.glows[uid] = {
            name       = "New Glow",
            enabled    = true,
            triggerOn  = (selectedCat == "auras") and "onAdd" or "onReady",
            glowType   = "Pixel",
            rgba       = {0.3, 0.8, 1.0, 1.0},
            frameLevel = 20,
        }
    elseif kind == "Sound" then
        item.sounds = item.sounds or {}
        item.sounds[uid] = {
            name        = "New Sound",
            enabled     = true,
            triggerOn   = (selectedCat == "auras") and "onAdd" or "onReady",
            channel     = "Master",
            repeatMode  = "once",
            repeatCount = 1,
            repeatInterval = 1,
        }
    elseif kind == "Event" then
        item.events = item.events or {}
        item.events[uid] = {
            name      = "New Event",
            enabled   = true,
            triggerOn = (selectedCat == "auras") and "onAdd" or "onReady",
            eventName = "",
        }
    end

    expandedUID = uid
    RefreshAll()
    BuildSubmoduleList()
end

-- -------------------------------------------------- --
--  Left panel — spell list                           --
-- -------------------------------------------------- --

local leftPanel, catAurasBtn, catCDsBtn, spellScroll, spellContent
local spellRows = {}

-- "Active" = item exists and is enabled. A disabled item still takes a slot in the
-- list but renders as dim/desaturated and sorts below active ones.
local function IsActive(spellID)
    if not spellID then return false end
    local _, item = FindItem(spellID, selectedSpecID)
    if not item then return false end
    if item.enabled == false then return false end
    return true
end

local function BuildSpellList()
    for _, r in ipairs(spellRows) do r:Hide() end
    wipe(spellRows)

    local sorted = {}

    -- CDM frame maps are built for the currently-active spec only. If the user
    -- is viewing a different spec in the settings UI, iterating those maps
    -- would show the WRONG spec's offerings. For non-active specs, only show
    -- spells already configured in the DB for that spec.
    local activeIdx    = GetSpecialization()
    local activeSpecID = activeIdx and GetSpecializationInfo(activeIdx) or nil
    local isActiveSpec = (selectedSpecID == activeSpecID)

    if isActiveSpec then
        local map = GetMap()
        -- Map has the same entry under both the base name and override name (e.g.
        -- "Word of Glory" and "Eternal Flame" point to one entry). Dedupe by table
        -- reference and display whichever spell is currently active.
        local seen = {}
        for _, entry in pairs(map) do
            if entry._lecSpellID and not seen[entry] then
                seen[entry] = true
                local baseID     = entry._lecSpellID
                local overrideID = C_Spell.GetOverrideSpell(baseID)
                local activeID   = (overrideID and overrideID ~= 0) and overrideID or baseID
                local info       = C_Spell.GetSpellInfo(activeID)
                local label      = (info and info.name) or entry._lecName or ""
                table.insert(sorted, {
                    key        = label,
                    entry      = entry,
                    activeID   = activeID,
                    configured = IsActive(baseID),
                })
            end
        end
    else
        -- Non-active spec — pull configured items from the DB for that spec.
        local itemType = GetItemType()
        local seenIDs  = {}
        for _, item in pairs(LECDM.db.profile.items) do
            if item.type == itemType
               and item.specID == selectedSpecID
               and item.spellID and not seenIDs[item.spellID] then
                seenIDs[item.spellID] = true
                local baseID = item.spellID
                local info   = C_Spell.GetSpellInfo(baseID)
                local label  = (info and info.name) or item.name or ("Spell " .. baseID)
                table.insert(sorted, {
                    key        = label,
                    entry      = { _lecSpellID = baseID, _lecName = label },
                    activeID   = baseID,
                    configured = item.enabled ~= false,
                })
            end
        end
    end
    -- Configured items first (alphabetical within each group)
    table.sort(sorted, function(a, b)
        if a.configured ~= b.configured then return a.configured end
        return a.key < b.key
    end)

    if ns.DEBUG or (LECDM.db and LECDM.db.profile.debug) then
        local summary = ""
        for _, rec in ipairs(sorted) do
            summary = summary .. rec.key .. "=" .. (rec.configured and "ON" or "off") .. "; "
        end
        ns.lpmsg("BuildSpellList: " .. summary, "DEBUG")
    end

    local y = 0
    for _, rec in ipairs(sorted) do
        local row = CreateFrame("Button", nil, spellContent, "BackdropTemplate")
        SetBD(row, C_PANEL, C_BDR)
        row:SetHeight(ROW_H)
        row:SetPoint("TOPLEFT", 0, y)
        row:SetPoint("TOPRIGHT", 0, y)

        local icon = row:CreateTexture(nil, "OVERLAY")
        icon:SetSize(ROW_H - 8, ROW_H - 8)
        icon:SetPoint("LEFT", 4, 0)
        local info = C_Spell.GetSpellInfo(rec.activeID)
        if info and info.iconID then icon:SetTexture(info.iconID) end

        local configured = rec.configured
        if configured then
            icon:SetDesaturated(false); icon:SetAlpha(1)
        else
            icon:SetDesaturated(true);  icon:SetAlpha(0.45)
        end

        local fs = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        fs:SetPoint("LEFT",  icon, "RIGHT", 8, 0)
        fs:SetPoint("RIGHT", row, "RIGHT", -6, 0)
        fs:SetJustifyH("LEFT")
        fs:SetJustifyV("MIDDLE")
        fs:SetWordWrap(true)
        fs:SetMaxLines(2)
        fs:SetText(rec.key)
        fs:SetTextColor(unpack(configured and C_TEXT or C_DIM))

        if rec.key == selectedKey then
            row:SetBackdropColor(unpack(C_HOVER))
            row:SetBackdropBorderColor(unpack(C_ACCENT))
        end

        row:SetScript("OnEnter", function(s)
            if rec.key ~= selectedKey then s:SetBackdropColor(unpack(C_HOVER)) end
        end)
        row:SetScript("OnLeave", function(s)
            if rec.key ~= selectedKey then s:SetBackdropColor(unpack(C_PANEL)) end
        end)
        row:SetScript("OnClick", function()
            selectedKey = rec.key
            expandedUID = nil
            BuildSpellList()
            BuildSubmoduleList()
            if rightHeader and rightHeader.Refresh then rightHeader.Refresh() end
        end)

        table.insert(spellRows, row)
        y = y - (ROW_H + 4)
    end

    spellContent:SetHeight(math.max(1, -y + 10))
end

-- -------------------------------------------------- --
--  Spec bar                                          --
-- -------------------------------------------------- --

local specBar, specButtons = nil, {}

local function BuildSpecBar()
    for _, b in ipairs(specButtons) do b:Hide() end
    wipe(specButtons)

    local numSpecs = GetNumSpecializations() or 0
    local activeIdx = GetSpecialization()
    local activeID = activeIdx and GetSpecializationInfo(activeIdx) or nil

    if not selectedSpecID then selectedSpecID = activeID end

    local x = PAD
    for i = 1, numSpecs do
        local sid, sname, _, sicon = GetSpecializationInfo(i)
        local b = CreateFrame("Button", nil, specBar, "BackdropTemplate")
        SetBD(b, C_ELEM, C_BDR)
        b:SetSize(40, 40)
        b:SetPoint("LEFT", x, 0)

        local tex = b:CreateTexture(nil, "ARTWORK")
        tex:SetPoint("TOPLEFT", 2, -2)
        tex:SetPoint("BOTTOMRIGHT", -2, 2)
        if sicon then tex:SetTexture(sicon) end

        if sid == activeID then
            tex:SetDesaturated(false); tex:SetAlpha(1)
        else
            tex:SetDesaturated(true);  tex:SetAlpha(0.5)
        end

        if sid == selectedSpecID then
            b:SetBackdropBorderColor(unpack(C_ACCENT))
        end

        b.tooltip = sname
        b:SetScript("OnEnter", function(s)
            GameTooltip:SetOwner(s, "ANCHOR_TOP")
            GameTooltip:SetText(sname or "", 1, 1, 1, 1, true)
            GameTooltip:Show()
        end)
        b:SetScript("OnLeave", function() GameTooltip:Hide() end)
        b:SetScript("OnClick", function()
            selectedSpecID = sid
            selectedKey    = nil
            expandedUID    = nil
            BuildSpecBar()
            BuildSpellList()
            BuildSubmoduleList()
            if rightHeader and rightHeader.Refresh then rightHeader.Refresh() end
        end)

        table.insert(specButtons, b)
        x = x + 44
    end
end

-- -------------------------------------------------- --
--  Window build                                      --
-- -------------------------------------------------- --

local function BuildFrame()
    if frame then return frame end

    frame = CreateFrame("Frame", "LECDMSettings", UIParent, "BackdropTemplate")
    frame:SetSize(1000, 680)
    frame:SetPoint("CENTER")
    SetBD(frame, C_BG, C_BDR)
    frame:SetFrameStrata("HIGH")
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:SetClampedToScreen(true)
    frame:Hide()

    -- Title bar
    local title = MakePanel(frame, C_PANEL, C_BDR)
    title:SetPoint("TOPLEFT", 0, 0)
    title:SetPoint("TOPRIGHT", 0, 0)
    title:SetHeight(TITLE_H)
    title:EnableMouse(true)
    title:RegisterForDrag("LeftButton")
    title:SetScript("OnDragStart", function() frame:StartMoving() end)
    title:SetScript("OnDragStop",  function() frame:StopMovingOrSizing() end)

    local titleText = MakeLabel(title, "LECDM — Enhanced CDM", 14, C_ACCENT)
    titleText:SetPoint("LEFT", 10, 0)

    local close = MakeButton(title, "X", 24, 20)
    close:SetPoint("RIGHT", -4, 0)
    close:SetScript("OnClick", function() frame:Hide() end)

    -- Spec bar
    specBar = MakePanel(frame, C_PANEL, C_BDR)
    specBar:SetPoint("TOPLEFT", 0, -TITLE_H)
    specBar:SetPoint("TOPRIGHT", 0, -TITLE_H)
    specBar:SetHeight(SPEC_H)

    -- Left panel
    leftPanel = MakePanel(frame, C_PANEL, C_BDR)
    leftPanel:SetPoint("TOPLEFT", 0, -(TITLE_H + SPEC_H))
    leftPanel:SetPoint("BOTTOMLEFT", 0, 0)
    leftPanel:SetWidth(LEFT_W)

    catAurasBtn = MakeAccentButton(leftPanel, "Auras", 70, 22)
    catAurasBtn:SetPoint("TOPLEFT", PAD, -PAD)
    catCDsBtn   = MakeButton(leftPanel, "CDs", 70, 22)
    catCDsBtn:SetPoint("LEFT", catAurasBtn, "RIGHT", 6, 0)

    -- Paint a category button and rewrite its hover scripts to match the state.
    -- MakeButton/MakeAccentButton bake in OnEnter/OnLeave that always restore
    -- the same base color, so without rewriting them the deselected color wins
    -- as soon as the mouse leaves the selected button.
    local function setCatButtonState(btn, selected)
        if selected then
            btn:SetBackdropColor(unpack(C_ACCENT))
            btn:SetScript("OnEnter", function(s) s:SetBackdropColor(0.55, 0.55, 1.0, 1) end)
            btn:SetScript("OnLeave", function(s) s:SetBackdropColor(unpack(C_ACCENT)) end)
        else
            btn:SetBackdropColor(unpack(C_ELEM))
            btn:SetScript("OnEnter", function(s) s:SetBackdropColor(unpack(C_HOVER)) end)
            btn:SetScript("OnLeave", function(s) s:SetBackdropColor(unpack(C_ELEM)) end)
        end
    end

    local function setCat(cat)
        selectedCat = cat
        selectedKey = nil
        expandedUID = nil
        setCatButtonState(catAurasBtn, cat == "auras")
        setCatButtonState(catCDsBtn,   cat == "cds")
        BuildSpellList()
        BuildSubmoduleList()
        if rightHeader and rightHeader.Refresh then rightHeader.Refresh() end
    end
    catAurasBtn:SetScript("OnClick", function() setCat("auras") end)
    catCDsBtn:SetScript("OnClick", function() setCat("cds") end)

    spellScroll = CreateFrame("ScrollFrame", nil, leftPanel, "UIPanelScrollFrameTemplate")
    spellScroll:SetPoint("TOPLEFT", PAD, -(PAD + 30))
    spellScroll:SetPoint("BOTTOMRIGHT", -(PAD + 18), PAD)
    spellContent = CreateFrame("Frame", nil, spellScroll)
    spellContent:SetSize(LEFT_W - PAD * 2 - 18, 10)
    spellScroll:SetScrollChild(spellContent)

    -- Right panel
    rightPanel = MakePanel(frame, C_PANEL, C_BDR)
    rightPanel:SetPoint("TOPLEFT", LEFT_W, -(TITLE_H + SPEC_H))
    rightPanel:SetPoint("BOTTOMRIGHT", 0, 0)

    rightHeader = MakePanel(rightPanel, C_PANEL, C_BDR)
    rightHeader:SetPoint("TOPLEFT", PAD, -PAD)
    rightHeader:SetPoint("TOPRIGHT", -PAD, -PAD)
    rightHeader:SetHeight(36)

    local enCheck = MakeCheck(rightHeader)
    enCheck:SetPoint("LEFT", 10, 0)
    local enLbl = MakeLabel(rightHeader, "Enable", nil, C_TEXT)
    enLbl:SetPoint("LEFT", enCheck, "RIGHT", 6, 0)

    local addGlow  = MakeAccentButton(rightHeader, "+Glow",  64, 22)
    addGlow:SetPoint("LEFT", enLbl, "RIGHT", 20, 0)
    local addSound = MakeAccentButton(rightHeader, "+Sound", 70, 22)
    addSound:SetPoint("LEFT", addGlow, "RIGHT", 6, 0)
    local addEvent = MakeAccentButton(rightHeader, "+Event", 64, 22)
    addEvent:SetPoint("LEFT", addSound, "RIGHT", 6, 0)

    addGlow:SetScript("OnClick",  function() AddSubmodule("Glow")  end)
    addSound:SetScript("OnClick", function() AddSubmodule("Sound") end)
    addEvent:SetScript("OnClick", function() AddSubmodule("Event") end)

    enCheck.onChanged = function(v)
        if not selectedKey then return end
        local entry = GetMap()[selectedKey]
        if not entry or not entry._lecSpellID then return end
        local _, item = GetOrCreateItem(entry._lecSpellID, entry._lecName)
        item.enabled = v and true or false
        ns.lpmsg("Enable toggle: " .. tostring(entry._lecName)
                 .. " spellID=" .. tostring(entry._lecSpellID)
                 .. " enabled=" .. tostring(item.enabled), "DEBUG")
        RefreshAll()
        BuildSpellList()
    end

    function rightHeader.Refresh()
        local has = false
        if selectedKey then
            local entry = GetMap()[selectedKey]
            if entry and entry._lecSpellID then
                local _, item = FindItem(entry._lecSpellID, selectedSpecID)
                if item and item.enabled ~= false then has = true end
            end
        end
        enCheck:SetChecked(has)
    end

    subScroll = CreateFrame("ScrollFrame", nil, rightPanel, "UIPanelScrollFrameTemplate")
    subScroll:SetPoint("TOPLEFT", rightHeader, "BOTTOMLEFT", 0, -PAD)
    subScroll:SetPoint("BOTTOMRIGHT", rightPanel, "BOTTOMRIGHT", -(PAD + 18), PAD)
    subContent = CreateFrame("Frame", nil, subScroll)
    subContent:SetSize(1, 10)
    subScroll:SetScrollChild(subContent)
    subScroll:SetScript("OnSizeChanged", function(_, w) subContent:SetWidth(w) end)

    frame:SetScript("OnShow", function()
        ns.isConfigOpen = true
        BuildSpecBar()
        setCat(selectedCat)
    end)
    frame:SetScript("OnHide", function()
        ns.isConfigOpen = false
        RefreshAll()
    end)

    return frame
end

-- -------------------------------------------------- --
--  Public API                                        --
-- -------------------------------------------------- --

function ns.OpenSettings()
    BuildFrame():Show()
end

function ns.CloseSettings()
    if frame then frame:Hide() end
end

function ns.ToggleSettings()
    local f = BuildFrame()
    if f:IsShown() then f:Hide() else f:Show() end
end
