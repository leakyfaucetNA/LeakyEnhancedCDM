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

local C_DANGER = {0.65, 0.20, 0.20, 1}

local function MakeDangerButton(parent, text, w, h)
    local b = MakeButton(parent, text, w, h)
    b:SetBackdropColor(unpack(C_DANGER))
    b:SetScript("OnEnter", function(s) s:SetBackdropColor(0.85, 0.30, 0.30, 1) end)
    b:SetScript("OnLeave", function(s) s:SetBackdropColor(unpack(C_DANGER)) end)
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
        -- Modern ColorPickerFrame (post-Dragonflight) uses `opacity` as ALPHA
        -- directly (1 = opaque, 0 = transparent). The pre-DF convention flipped
        -- it to transparency; using that convention here inverts the slider.
        local info = {
            swatchFunc = function()
                local nr, ng, nb = ColorPickerFrame:GetColorRGB()
                b.rgba[1], b.rgba[2], b.rgba[3] = nr, ng, nb
                tex:SetVertexColor(nr, ng, nb, b.rgba[4])
                if cb then cb(unpack(b.rgba)) end
            end,
            opacityFunc = function()
                b.rgba[4] = ColorPickerFrame:GetColorAlpha() or 1
                tex:SetVertexColor(b.rgba[1], b.rgba[2], b.rgba[3], b.rgba[4])
                if cb then cb(unpack(b.rgba)) end
            end,
            cancelFunc = function(prev)
                b.rgba[1], b.rgba[2], b.rgba[3], b.rgba[4] =
                    prev.r or 1, prev.g or 1, prev.b or 1, prev.opacity or 1
                tex:SetVertexColor(unpack(b.rgba))
                if cb then cb(unpack(b.rgba)) end
            end,
            hasOpacity = true,
            opacity    = a or 1,
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

-- Refresh tracking modules after config edits. UpdateTrackerState flips the
-- aura / CD trackers on or off depending on whether any matching configs
-- exist, so adding or clearing configs takes effect immediately.
local function RefreshAll()
    if not LECDM or not LECDM.db then return end
    if ns.UpdateTrackerState then ns.UpdateTrackerState() end
    ns.SetupGlows(LECDM)
    ns.SetupSounds(LECDM)
    ns.SetupEvents(LECDM)
    if ns.SetupTexts then ns.SetupTexts(LECDM) end
end

-- -------------------------------------------------- --
--  Delete-with-confirm                               --
-- -------------------------------------------------- --

-- Single StaticPopup shared by every sub-module's Delete button. Data-driven
-- message and callback so the same dialog works for Glow/Sound/Event/Text.
StaticPopupDialogs["LECDM_DELETE_SUBMODULE"] = {
    text         = "Delete this %s?\n\nThis cannot be undone.",
    button1      = YES,
    button2      = NO,
    timeout      = 0,
    whileDead    = true,
    hideOnEscape = true,
    preferredIndex = 3,
    OnAccept = function(_, data)
        if data and data.onConfirm then data.onConfirm() end
    end,
}

-- Show the confirm popup for a sub-module. Caller passes the kind string
-- (for the prompt) and the callback to run on YES.
local function ConfirmDeleteSubmodule(kind, onConfirm)
    StaticPopup_Show("LECDM_DELETE_SUBMODULE", kind, nil, { onConfirm = onConfirm })
end

-- Actual deletion: remove from the right sub-table, collapse the row if it
-- was expanded, rebuild lookups and the accordion.
local function DeleteSubmodule(item, kind, uid)
    if kind == "Glow"  then item.glows  = item.glows  or {}; item.glows[uid]  = nil end
    if kind == "Sound" then item.sounds = item.sounds or {}; item.sounds[uid] = nil end
    if kind == "Event" then item.events = item.events or {}; item.events[uid] = nil end
    if kind == "Text"  then item.texts  = item.texts  or {}; item.texts[uid]  = nil end
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

-- Append a red Delete button to a sub-module panel, centered at the bottom.
-- Returns the new y offset (already decremented for the button row + padding).
local function AppendDeleteButton(p, y, kind, item, uid)
    y = y - 4
    local del = MakeDangerButton(p, "Delete " .. kind, 180, 24)
    del:SetPoint("TOP", p, "TOP", 0, y)
    del:SetScript("OnClick", function()
        ConfirmDeleteSubmodule(kind, function()
            DeleteSubmodule(item, kind, uid)
            if expandedUID == uid then expandedUID = nil end
            RefreshAll()
            BuildSubmoduleList()
        end)
    end)
    return y - 28
end

-- Build glow options panel.
local function CreateGlowPanel(parent, gc, itemSpellID, item, uid)
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

    -- ---- Target picker ----
    -- Dedupe per-map by entry table ref (maps store the same entry under both
    -- base and override name keys).
    local function collectMap(map)
        local seen, out = {}, {}
        for name, entry in pairs(map) do
            if entry._lecSpellID and not seen[entry] then
                seen[entry] = true
                out[#out + 1] = { name = name, entry = entry }
            end
        end
        return out
    end

    -- Build name-collision count so "(Aura)"/"(CD)" suffix only appears when a
    -- spell name exists in both maps.
    local function buildNameCount(auraList, cdList)
        local nameCount = {}
        for _, rec in ipairs(auraList) do nameCount[rec.name] = (nameCount[rec.name] or 0) + 1 end
        for _, rec in ipairs(cdList)   do nameCount[rec.name] = (nameCount[rec.name] or 0) + 1 end
        return nameCount
    end

    -- Resolve what to display in the collapsed dropdown for the current frameKey.
    local function TargetLabel()
        if gc.customTarget then return "(custom)" end
        if not gc.frameKey or gc.frameKey == false then return "(this spell's frame)" end
        if type(gc.frameKey) == "number" then
            local auraList = collectMap(ns.auraFrameMap or {})
            local cdList   = collectMap(ns.cdFrameMap   or {})
            local nameCount = buildNameCount(auraList, cdList)
            for _, rec in ipairs(auraList) do
                if rec.entry._lecSpellID == gc.frameKey then
                    return (nameCount[rec.name] or 0) > 1 and rec.name .. " (Aura)" or rec.name
                end
            end
            for _, rec in ipairs(cdList) do
                if rec.entry._lecSpellID == gc.frameKey then
                    return (nameCount[rec.name] or 0) > 1 and rec.name .. " (CD)" or rec.name
                end
            end
            return tostring(gc.frameKey)
        end
        return tostring(gc.frameKey)
    end

    Row(p, y, "Target")
    local tgt = MakeDropdown(p, 220, 22)
    tgt:SetPoint("TOPLEFT", PAD + 108, y + 4)
    tgt:SetValue(TargetLabel())

    -- Custom-target textbox (only shown when gc.customTarget is true).
    local customEdit
    if gc.customTarget then
        customEdit = MakeEdit(p, 160, 22)
        customEdit:SetPoint("LEFT", tgt, "RIGHT", 6, 0)
        customEdit.edit:SetText(tostring(gc.frameKey or ""))
        customEdit.edit:SetScript("OnEditFocusLost", function(e)
            gc.frameKey = e:GetText()
            RefreshAll()
        end)
    end

    tgt:SetScript("OnClick", function(s)
        local auraList = collectMap(ns.auraFrameMap or {})
        local cdList   = collectMap(ns.cdFrameMap   or {})
        local nameCount = buildNameCount(auraList, cdList)

        local items = {
            { label = "(this spell's frame)", value = false    },
            { label = "(custom)",             value = "__custom__" },
        }
        local function add(rec, suffix)
            local label = (nameCount[rec.name] or 0) > 1
                          and (rec.name .. " " .. suffix)
                          or rec.name
            items[#items + 1] = { label = label, value = rec.entry._lecSpellID }
        end
        for _, rec in ipairs(auraList) do add(rec, "(Aura)") end
        for _, rec in ipairs(cdList)   do add(rec, "(CD)") end

        -- Keep the two sentinel rows pinned at the top, sort the rest alphabetically.
        table.sort(items, function(a, b)
            if a.value == false then return true end
            if b.value == false then return false end
            if a.value == "__custom__" then return true end
            if b.value == "__custom__" then return false end
            return tostring(a.label) < tostring(b.label)
        end)

        s:Open(items, function(v, l)
            if v == false then
                gc.customTarget = nil
                gc.frameKey = nil
            elseif v == "__custom__" then
                gc.customTarget = true
                gc.frameKey = ""
            else
                gc.customTarget = nil
                gc.frameKey = v
            end
            tgt:SetValue(l)
            RefreshAll()
            -- Rebuild so the custom-target textbox appears or disappears.
            if BuildSubmoduleList then BuildSubmoduleList() end
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
        s:Open(items, function(v)
            gc.glowType = v; gtype:SetValue(v); RefreshAll()
            -- Rebuild so the type-specific advanced fields swap.
            if BuildSubmoduleList then BuildSubmoduleList() end
        end)
    end)

    -- Preview toggle. Transient — never saved; cleared on OnHide below.
    local previewing = false
    local previewBtn = MakeButton(p, "Preview", 70, 22)
    previewBtn:SetPoint("LEFT", gtype, "RIGHT", 8, 0)
    local function stopPreview()
        if not previewing then return end
        previewing = false
        if ns.PreviewGlow then ns.PreviewGlow(gc, itemSpellID, false) end
        previewBtn.text:SetText("Preview")
    end
    previewBtn:SetScript("OnClick", function()
        if previewing then
            stopPreview()
        else
            previewing = true
            if ns.PreviewGlow then ns.PreviewGlow(gc, itemSpellID, true) end
            previewBtn.text:SetText("Stop")
        end
    end)
    -- Auto-stop on any hide: panel collapse, window close, tab change, etc.
    p:HookScript("OnHide", stopPreview)

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

    -- ---- Advanced toggle + per-type tuning ----
    Row(p, y, "Advanced")
    local adv = MakeCheck(p)
    adv:SetPoint("TOPLEFT", PAD + 108, y + 4)
    adv:SetChecked(gc.advanced == true)
    adv.onChanged = function(v)
        gc.advanced = v and true or nil
        if BuildSubmoduleList then BuildSubmoduleList() end
    end
    y = y - 30

    if gc.advanced then
        -- Small factories so each advanced row is one line at the call site.
        -- No SetNumeric: it blocks "-" and "." characters, breaking negative
        -- offsets and decimal frequencies. tonumber() handles both on submit.
        local function numRow(label, field, default)
            Row(p, y, label)
            local eb = MakeEdit(p, 70, 22)
            eb:SetPoint("TOPLEFT", PAD + 108, y + 4)
            eb.edit:SetText(tostring(gc[field] or default))
            eb.edit:SetScript("OnEditFocusLost", function(e)
                local n = tonumber(e:GetText())
                gc[field] = n or default
                RefreshAll()
                if previewing and ns.PreviewGlow then
                    ns.PreviewGlow(gc, itemSpellID, false)
                    ns.PreviewGlow(gc, itemSpellID, true)
                end
            end)
            y = y - 30
        end
        local function boolRow(label, field)
            Row(p, y, label)
            local c = MakeCheck(p)
            c:SetPoint("TOPLEFT", PAD + 108, y + 4)
            c:SetChecked(gc[field] == true)
            c.onChanged = function(v)
                gc[field] = v and true or nil
                RefreshAll()
                if previewing and ns.PreviewGlow then
                    ns.PreviewGlow(gc, itemSpellID, false)
                    ns.PreviewGlow(gc, itemSpellID, true)
                end
            end
            y = y - 30
        end

        local gType = gc.glowType or "Pixel"
        if gType == "Pixel" then
            numRow("Lines",      "lines",  8)
            numRow("Frequency",  "freq",   0.25)
            numRow("Length",     "length", 8)
            numRow("Thickness",  "th",     2)
            boolRow("Border",    "border")
            numRow("X Offset",   "xOff",   0)
            numRow("Y Offset",   "yOff",   0)
        elseif gType == "AutoCast" then
            numRow("Particles",  "particles", 4)
            numRow("Frequency",  "freq",      0.125)
            numRow("Scale",      "scale",     1)
            numRow("X Offset",   "xOff",      0)
            numRow("Y Offset",   "yOff",      0)
        elseif gType == "Proc" then
            boolRow("Start Anim", "startAnim")
            numRow("Duration",   "duration", 1)
            numRow("X Offset",   "xOff",     0)
            numRow("Y Offset",   "yOff",     0)
        elseif gType == "Button" then
            boolRow("Start Anim", "startAnim")
            numRow("X Offset",   "xOff", 0)
            numRow("Y Offset",   "yOff", 0)
        end
    end

    y = AppendDeleteButton(p, y, "Glow", item, uid)
    p:SetHeight(-y + PAD)
    return p
end

local function CreateSoundPanel(parent, sc, item, uid)
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

    y = AppendDeleteButton(p, y, "Sound", item, uid)
    p:SetHeight(-y + PAD)
    return p
end

local function CreateEventPanel(parent, ec, item, uid)
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

    y = AppendDeleteButton(p, y, "Event", item, uid)
    p:SetHeight(-y + PAD)
    return p
end

local ANCHOR_POINTS = {
    "TOPLEFT", "TOP", "TOPRIGHT",
    "LEFT",    "CENTER", "RIGHT",
    "BOTTOMLEFT", "BOTTOM", "BOTTOMRIGHT",
}

local function CreateTextPanel(parent, tc, uid, itemSpellID, item)
    local p = MakePanel(parent, C_PANEL, C_BDR)
    local y = -PAD

    Row(p, y, "Name")
    local nameE = MakeEdit(p, 220, 22)
    nameE:SetPoint("TOPLEFT", PAD + 108, y + 4)
    nameE.edit:SetText(tc.name or "")
    nameE.edit:SetScript("OnEditFocusLost", function(e) tc.name = e:GetText() end)
    y = y - 30

    Row(p, y, "Enabled")
    local en = MakeCheck(p)
    en:SetPoint("TOPLEFT", PAD + 108, y + 4)
    en:SetChecked(tc.enabled ~= false)
    en.onChanged = function(v) tc.enabled = v; RefreshAll() end

    -- Preview button — writes the preview-value editbox contents (default "1")
    -- to the frame using the current config so the user can see anchor, font,
    -- color, and size choices. Auto-stops on hide (panel collapse, settings
    -- close, etc.).
    local stateKey = "__preview_" .. tostring(uid or 0) .. "_" .. tostring(itemSpellID or 0)
    local previewing = false
    local previewBtn = MakeButton(p, "Preview", 70, 22)
    previewBtn:SetPoint("LEFT", en, "RIGHT", 80, 0)

    local previewValE = MakeEdit(p, 60, 22)
    previewValE:SetPoint("LEFT", previewBtn, "RIGHT", 6, 0)
    previewValE.edit:SetText("1")
    local function getPreviewValue()
        local t = previewValE.edit:GetText()
        if not t or t == "" then return "1" end
        return t
    end

    local function stopPreview()
        if not previewing then return end
        previewing = false
        if ns.PreviewText then ns.PreviewText(tc, stateKey, false) end
        previewBtn.text:SetText("Preview")
    end
    local function startPreview()
        previewing = true
        if ns.PreviewText then ns.PreviewText(tc, stateKey, true, getPreviewValue()) end
        previewBtn.text:SetText("Stop")
    end
    previewBtn:SetScript("OnClick", function()
        if previewing then stopPreview() else startPreview() end
    end)
    p:HookScript("OnHide", stopPreview)

    -- Any config change during preview: refresh so positional/font changes apply.
    local function refreshPreview()
        if previewing and ns.PreviewText then
            ns.PreviewText(tc, stateKey, true, getPreviewValue())
        end
    end
    -- Changing the preview number while previewing updates the text live.
    previewValE.edit:SetScript("OnTextChanged", function() refreshPreview() end)
    y = y - 30

    Row(p, y, "Hide at 0")
    local hz = MakeCheck(p)
    hz:SetPoint("TOPLEFT", PAD + 108, y + 4)
    hz:SetChecked(tc.hideAtZero ~= false)
    hz.onChanged = function(v) tc.hideAtZero = v; RefreshAll() end
    y = y - 30

    -- ---- Anchor frame picker ----
    -- Mirrors the glow target dropdown: "(custom)" + unique entries from
    -- auraFrameMap + cdFrameMap with "(Aura)"/"(CD)" suffix when a name
    -- collides across the two maps.
    local function collectAnchorMap(map)
        local seen, out = {}, {}
        for name, entry in pairs(map) do
            if entry._lecSpellID and not seen[entry] then
                seen[entry] = true
                out[#out + 1] = { name = name, entry = entry }
            end
        end
        return out
    end
    local function buildAnchorNameCount(auraList, cdList)
        local nameCount = {}
        for _, rec in ipairs(auraList) do nameCount[rec.name] = (nameCount[rec.name] or 0) + 1 end
        for _, rec in ipairs(cdList)   do nameCount[rec.name] = (nameCount[rec.name] or 0) + 1 end
        return nameCount
    end

    local function anchorLabel()
        if tc.anchorCustom then return "(custom)" end
        if not tc.anchorFrame or tc.anchorFrame == "" then return "UIParent" end
        if type(tc.anchorFrame) == "number" then
            local auraList = collectAnchorMap(ns.auraFrameMap or {})
            local cdList   = collectAnchorMap(ns.cdFrameMap   or {})
            local nameCount = buildAnchorNameCount(auraList, cdList)
            for _, rec in ipairs(auraList) do
                if rec.entry._lecSpellID == tc.anchorFrame then
                    return (nameCount[rec.name] or 0) > 1 and rec.name .. " (Aura)" or rec.name
                end
            end
            for _, rec in ipairs(cdList) do
                if rec.entry._lecSpellID == tc.anchorFrame then
                    return (nameCount[rec.name] or 0) > 1 and rec.name .. " (CD)" or rec.name
                end
            end
            return tostring(tc.anchorFrame)
        end
        return tostring(tc.anchorFrame)
    end

    Row(p, y, "Anchor Frame")
    local anc = MakeDropdown(p, 220, 22)
    anc:SetPoint("TOPLEFT", PAD + 108, y + 4)
    anc:SetValue(anchorLabel())

    -- Custom-frame textbox, visible only when anchorCustom is true.
    if tc.anchorCustom then
        local afE = MakeEdit(p, 160, 22)
        afE:SetPoint("LEFT", anc, "RIGHT", 6, 0)
        afE.edit:SetText(tostring(tc.anchorFrame or ""))
        afE.edit:SetScript("OnEditFocusLost", function(e)
            tc.anchorFrame = e:GetText()
            RefreshAll(); refreshPreview()
        end)
    end

    anc:SetScript("OnClick", function(s)
        local auraList = collectAnchorMap(ns.auraFrameMap or {})
        local cdList   = collectAnchorMap(ns.cdFrameMap   or {})
        local nameCount = buildAnchorNameCount(auraList, cdList)

        local items = {
            { label = "UIParent",  value = "UIParent"   },
            { label = "(custom)",  value = "__custom__" },
        }
        local function add(rec, suffix)
            local label = (nameCount[rec.name] or 0) > 1
                          and (rec.name .. " " .. suffix)
                          or rec.name
            items[#items + 1] = { label = label, value = rec.entry._lecSpellID }
        end
        for _, rec in ipairs(auraList) do add(rec, "(Aura)") end
        for _, rec in ipairs(cdList)   do add(rec, "(CD)") end

        table.sort(items, function(a, b)
            if a.value == "UIParent"   then return true  end
            if b.value == "UIParent"   then return false end
            if a.value == "__custom__" then return true  end
            if b.value == "__custom__" then return false end
            return tostring(a.label) < tostring(b.label)
        end)

        s:Open(items, function(v, l)
            if v == "__custom__" then
                tc.anchorCustom = true
                tc.anchorFrame  = ""
            elseif v == "UIParent" then
                tc.anchorCustom = nil
                tc.anchorFrame  = "UIParent"
            else
                tc.anchorCustom = nil
                tc.anchorFrame  = v
            end
            anc:SetValue(l)
            RefreshAll(); refreshPreview()
            if BuildSubmoduleList then BuildSubmoduleList() end
        end)
    end)
    y = y - 30

    local function pointDropdown(label, field, default)
        Row(p, y, label)
        local dd = MakeDropdown(p, 140, 22)
        dd:SetPoint("TOPLEFT", PAD + 108, y + 4)
        dd:SetValue(tc[field] or default)
        dd:SetScript("OnClick", function(s)
            local items = {}
            for _, pt in ipairs(ANCHOR_POINTS) do
                items[#items + 1] = { label = pt, value = pt }
            end
            s:Open(items, function(v)
                tc[field] = v; dd:SetValue(v)
                RefreshAll(); refreshPreview()
            end)
        end)
        y = y - 30
    end

    -- Anchor point on our text is always CENTER — simpler UX, and any
    -- positioning the user wants is expressed via Relative Point + offsets.
    tc.point = "CENTER"
    pointDropdown("Relative Point", "relativePoint", "CENTER")

    -- Frame strata: controls which UI layer the text renders in. HIGH by
    -- default so it sits above most world-ui and unit frames.
    local STRATA_LIST = {
        "BACKGROUND", "LOW", "MEDIUM", "HIGH",
        "DIALOG",     "FULLSCREEN", "FULLSCREEN_DIALOG", "TOOLTIP",
    }
    Row(p, y, "Strata")
    local strataDD = MakeDropdown(p, 180, 22)
    strataDD:SetPoint("TOPLEFT", PAD + 108, y + 4)
    strataDD:SetValue(tc.strata or "HIGH")
    strataDD:SetScript("OnClick", function(s)
        local items = {}
        for _, st in ipairs(STRATA_LIST) do items[#items + 1] = { label = st, value = st } end
        s:Open(items, function(v, l)
            tc.strata = v; strataDD:SetValue(l)
            RefreshAll(); refreshPreview()
        end)
    end)
    y = y - 30

    -- No SetNumeric: it blocks "-" and "." characters, breaking negative
    -- offsets. tonumber() handles both on submit.
    local function numRow(label, field, default)
        Row(p, y, label)
        local eb = MakeEdit(p, 70, 22)
        eb:SetPoint("TOPLEFT", PAD + 108, y + 4)
        eb.edit:SetText(tostring(tc[field] or default))
        eb.edit:SetScript("OnEditFocusLost", function(e)
            local n = tonumber(e:GetText())
            tc[field] = n or default
            RefreshAll(); refreshPreview()
        end)
        y = y - 30
    end

    numRow("X Offset",  "x", 0)
    numRow("Y Offset",  "y", 0)

    -- Font picker from LSM's "font" channel.
    Row(p, y, "Font")
    local fontDD = MakeDropdown(p, 200, 22)
    fontDD:SetPoint("TOPLEFT", PAD + 108, y + 4)
    fontDD:SetValue(tostring(tc.font or "(default)"))
    fontDD:SetScript("OnClick", function(s)
        local items = { { label = "(default)", value = "__default__" } }
        local list = LSM and LSM:List("font") or {}
        for _, name in ipairs(list) do
            items[#items + 1] = { label = name, value = name }
        end
        s:Open(items, function(v, l)
            if v == "__default__" then tc.font = nil
            else tc.font = v end
            fontDD:SetValue(l)
            RefreshAll(); refreshPreview()
        end)
    end)
    y = y - 30

    numRow("Font Size", "fontSize", 18)

    Row(p, y, "Color")
    local rgba = tc.rgba or {1, 1, 1, 1}
    tc.rgba = rgba
    local sw = MakeColorSwatch(p, rgba, function(r, g, b_, a)
        tc.rgba = {r, g, b_, a}
        RefreshAll(); refreshPreview()
    end)
    sw:SetPoint("TOPLEFT", PAD + 108, y + 2)
    y = y - 30

    y = AppendDeleteButton(p, y, "Text", item, uid)
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

        local del = MakeDangerButton(row, "x", 22, 18)
        del:SetPoint("RIGHT", -6, 0)
        del:SetScript("OnClick", function()
            ConfirmDeleteSubmodule(kind, function()
                DeleteSubmodule(item, kind, uid)
                if expandedUID == uid then expandedUID = nil end
                RefreshAll()
                BuildSubmoduleList()
            end)
        end)

        row:SetScript("OnClick", function()
            if expandedUID == uid then expandedUID = nil else expandedUID = uid end
            BuildSubmoduleList()
        end)

        table.insert(subRows, row)
        yOff = yOff - (SUB_H + 4)

        if expandedUID == uid then
            local panel
            if kind == "Glow"  then panel = CreateGlowPanel(subContent, sc, spellID, item, uid) end
            if kind == "Sound" then panel = CreateSoundPanel(subContent, sc, item, uid) end
            if kind == "Event" then panel = CreateEventPanel(subContent, sc, item, uid) end
            if kind == "Text"  then panel = CreateTextPanel(subContent, sc, uid, spellID, item) end
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
    if item.texts then
        for uid, tc in pairs(item.texts) do AddSubRow("Text", uid, tc) end
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
    elseif kind == "Text" then
        item.texts = item.texts or {}
        item.texts[uid] = {
            name          = "Stack Text",
            enabled       = true,
            hideAtZero    = true,
            anchorFrame   = "UIParent",
            point         = "CENTER",
            relativePoint = "CENTER",
            x             = 0,
            y             = 0,
            fontSize      = 18,
            fontOutline   = "OUTLINE",
            rgba          = {1, 1, 1, 1},
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
    -- Text sub-module is aura-only (displays stack count). Hidden on CD items.
    local addText  = MakeAccentButton(rightHeader, "+Text",  60, 22)
    addText:SetPoint("LEFT", addEvent, "RIGHT", 6, 0)

    addGlow:SetScript("OnClick",  function() AddSubmodule("Glow")  end)
    addSound:SetScript("OnClick", function() AddSubmodule("Sound") end)
    addEvent:SetScript("OnClick", function() AddSubmodule("Event") end)
    addText:SetScript("OnClick",  function() AddSubmodule("Text")  end)

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

        -- +Text only makes sense for auras (stack count). Hide on CDs.
        if selectedCat == "auras" then addText:Show() else addText:Hide() end
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

-- Combat lockout: opening the settings window while the player is in combat
-- is blocked. The request is queued — when PLAYER_REGEN_ENABLED fires we
-- honor it. Toggle/Close calls during combat short-circuit cleanly.
local combatQueueFrame = CreateFrame("Frame")
local pendingAction  -- "open" | "toggle" | nil

local function FlushPendingAction()
    local action = pendingAction
    pendingAction = nil
    if action == "open" then
        BuildFrame():Show()
    elseif action == "toggle" then
        local f = BuildFrame()
        if f:IsShown() then f:Hide() else f:Show() end
    end
end

combatQueueFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
combatQueueFrame:SetScript("OnEvent", function(_, event)
    if event == "PLAYER_REGEN_ENABLED" and pendingAction then
        FlushPendingAction()
    end
end)

local function DeferOrRunNow(action)
    if InCombatLockdown() then
        pendingAction = action
        ns.lpmsg("Settings: deferred until combat ends")
    else
        pendingAction = nil
        if action == "open" then
            BuildFrame():Show()
        elseif action == "toggle" then
            local f = BuildFrame()
            if f:IsShown() then f:Hide() else f:Show() end
        end
    end
end

function ns.OpenSettings()
    DeferOrRunNow("open")
end

function ns.CloseSettings()
    -- Close is safe in combat (Hide is allowed) and also cancels any pending
    -- open so the window doesn't spring back open on PLAYER_REGEN_ENABLED.
    pendingAction = nil
    if frame then frame:Hide() end
end

function ns.ToggleSettings()
    -- If the window is already shown, we can always close it safely.
    if frame and frame:IsShown() then
        pendingAction = nil
        frame:Hide()
        return
    end
    DeferOrRunNow("toggle")
end
