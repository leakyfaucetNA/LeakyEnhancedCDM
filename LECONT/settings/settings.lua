-- settings.lua
-- Native settings panel for LECONT. Themed scrollbar/slider widgets, tabbed
-- per-container editor (Icon / Text / Position / Load Conditions), and a
-- separate Global panel for default dispel colors.

local _, ns = ...

local LSM = LibStub and LibStub("LibSharedMedia-3.0", true)

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
local C_DANGER   = {0.65, 0.20, 0.20, 1}
local C_ROWACC   = {0.45, 0.45, 0.95, 0.55}

local TITLE_H  = 28
local LEFT_W   = 240
local ROW_H    = 30
local PAD      = 8
local TAB_H    = 26

-- -------------------------------------------------- --
--  Module state                                      --
-- -------------------------------------------------- --

local frame
local selectedID         -- itemID of the container being edited
local currentView        = "container"  -- "container" | "global"
local currentTab         = 1            -- editor tab index (1..4)
-- Preview state is owned by each container engine (c.previewing). The settings
-- UI just calls Preview()/StopPreview() to drive the focused-preview model.

-- -------------------------------------------------- --
--  Theme primitives                                  --
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
    function c:SetChecked(v) if v then fill:Show() else fill:Hide() end end
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
    eb:SetScript("OnEnterPressed",  eb.ClearFocus)
    holder.edit = eb
    return holder
end

-- Color swatch: opens Blizzard's ColorPickerFrame with modern alpha (opacity=alpha).
local function MakeColorSwatch(parent, initial, cb)
    local b = CreateFrame("Button", nil, parent, "BackdropTemplate")
    SetBD(b, C_ELEM, C_BDR)
    b:SetSize(40, 18)
    local tex = b:CreateTexture(nil, "OVERLAY")
    tex:SetTexture(TEX)
    tex:SetPoint("TOPLEFT", 2, -2)
    tex:SetPoint("BOTTOMRIGHT", -2, 2)
    tex:SetVertexColor(initial[1] or 1, initial[2] or 1, initial[3] or 1, initial[4] or 1)
    b.tex  = tex
    b.rgba = { initial[1] or 1, initial[2] or 1, initial[3] or 1, initial[4] or 1 }

    function b:SetRGBA(rgba)
        self.rgba = { rgba[1] or 1, rgba[2] or 1, rgba[3] or 1, rgba[4] or 1 }
        tex:SetVertexColor(unpack(self.rgba))
    end

    b:SetScript("OnClick", function()
        local r, g, bl, a = unpack(b.rgba)
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
            r = r, g = g, b = bl,
        }
        if ColorPickerFrame.SetupColorPickerAndShow then
            ColorPickerFrame:SetupColorPickerAndShow(info)
        else
            ColorPickerFrame.func        = info.swatchFunc
            ColorPickerFrame.opacityFunc = info.opacityFunc
            ColorPickerFrame.cancelFunc  = info.cancelFunc
            ColorPickerFrame.hasOpacity  = true
            ColorPickerFrame.opacity     = a or 1
            ColorPickerFrame:SetColorRGB(r, g, bl)
            ColorPickerFrame:Hide(); ColorPickerFrame:Show()
        end
    end)
    return b
end

-- Themed horizontal slider with custom backdrop + thumb. Returns the slider
-- which behaves like a standard WoW Slider widget.
local function MakeThemedSlider(parent, w, h, min, max, step, value, onChange)
    local s = CreateFrame("Slider", nil, parent, "BackdropTemplate")
    SetBD(s, C_ELEM, C_BDR)
    s:SetSize(w or 160, h or 14)
    s:SetMinMaxValues(min or 0, max or 100)
    s:SetValueStep(step or 1)
    s:SetObeyStepOnDrag(true)
    s:SetOrientation("HORIZONTAL")
    s:SetValue(value or 0)

    local thumb = s:CreateTexture(nil, "OVERLAY")
    thumb:SetTexture(TEX)
    thumb:SetVertexColor(unpack(C_ACCENT))
    thumb:SetSize(8, (h or 14) + 6)
    s:SetThumbTexture(thumb)

    if onChange then
        s:SetScript("OnValueChanged", function(_, v)
            onChange(math.floor(v + 0.5))
        end)
    end
    return s
end

-- Themed vertical scroll. Builds a ScrollFrame + custom Slider acting as the
-- scrollbar; sync is automatic on content size changes.
local function MakeThemedScroll(parent)
    local scroll = CreateFrame("ScrollFrame", nil, parent)

    local content = CreateFrame("Frame", nil, scroll)
    content:SetSize(1, 1)
    scroll:SetScrollChild(content)

    local bar = CreateFrame("Slider", nil, scroll, "BackdropTemplate")
    SetBD(bar, C_PANEL, C_BDR)
    bar:SetWidth(12)
    bar:SetOrientation("VERTICAL")
    bar:SetMinMaxValues(0, 0)
    bar:SetValueStep(1)
    bar:SetObeyStepOnDrag(false)
    bar:SetValue(0)
    bar:SetPoint("TOPRIGHT",    scroll, "TOPRIGHT",     0, 0)
    bar:SetPoint("BOTTOMRIGHT", scroll, "BOTTOMRIGHT",  0, 0)

    local thumb = bar:CreateTexture(nil, "OVERLAY")
    thumb:SetTexture(TEX)
    thumb:SetVertexColor(unpack(C_ACCENT))
    thumb:SetSize(10, 30)
    bar:SetThumbTexture(thumb)

    bar:SetScript("OnValueChanged", function(_, v)
        scroll:SetVerticalScroll(v)
    end)

    local function UpdateRange()
        local h = (content:GetHeight() or 0) - (scroll:GetHeight() or 0)
        if h < 0 then h = 0 end
        bar:SetMinMaxValues(0, h)
        if h > 0 then bar:Show() else bar:Hide(); bar:SetValue(0) end
    end
    content:HookScript("OnSizeChanged", UpdateRange)
    scroll:HookScript("OnSizeChanged",  UpdateRange)

    scroll:EnableMouseWheel(true)
    scroll:SetScript("OnMouseWheel", function(_, delta)
        local _, maxV = bar:GetMinMaxValues()
        local cur = bar:GetValue()
        bar:SetValue(math.max(0, math.min(maxV, cur - delta * 30)))
    end)

    return scroll, content, bar
end

-- -------------------------------------------------- --
--  Dropdown popup (shared, single)                   --
-- -------------------------------------------------- --

-- Shared dropdown popup with internal scrollframe + themed slider so long
-- lists (anchor frames, font lists, etc.) don't grow off-screen.
local DROP_ROW_H        = 22
local DROP_VISIBLE_ROWS = 10

local dropPopup, dropCatcher, dropScroll, dropScrollChild, dropBar
local function GetDropPopup()
    if dropPopup then return dropPopup, dropScroll, dropScrollChild, dropBar end

    dropCatcher = CreateFrame("Button", nil, UIParent)
    dropCatcher:SetAllPoints(UIParent)
    dropCatcher:SetFrameStrata("FULLSCREEN_DIALOG")
    dropCatcher:RegisterForClicks("AnyUp")
    dropCatcher:Hide()
    dropCatcher:SetScript("OnClick", function() if dropPopup then dropPopup:Hide() end end)

    dropPopup = CreateFrame("Frame", "LECONTDropPopup", UIParent, "BackdropTemplate")
    SetBD(dropPopup, C_PANEL, C_BDR)
    dropPopup:SetFrameStrata("FULLSCREEN_DIALOG")
    dropPopup:SetFrameLevel(dropCatcher:GetFrameLevel() + 10)
    dropPopup:Hide()
    dropPopup.rows = {}
    dropPopup:SetScript("OnShow", function() dropCatcher:Show() end)
    dropPopup:SetScript("OnHide", function() dropCatcher:Hide() end)

    dropScroll = CreateFrame("ScrollFrame", nil, dropPopup)
    dropScroll:SetPoint("TOPLEFT",     2,  -2)
    dropScroll:SetPoint("BOTTOMRIGHT", -2,  2)
    dropScrollChild = CreateFrame("Frame", nil, dropScroll)
    dropScrollChild:SetSize(1, 1)
    dropScroll:SetScrollChild(dropScrollChild)

    -- Themed vertical slider — only attached/sized when row count exceeds
    -- DROP_VISIBLE_ROWS; otherwise hidden so short lists look clean.
    dropBar = CreateFrame("Slider", nil, dropScroll, "BackdropTemplate")
    SetBD(dropBar, C_PANEL, C_BDR)
    dropBar:SetWidth(10)
    dropBar:SetOrientation("VERTICAL")
    dropBar:SetMinMaxValues(0, 0)
    dropBar:SetValueStep(1)
    dropBar:SetObeyStepOnDrag(false)
    dropBar:SetPoint("TOPRIGHT",    dropScroll, "TOPRIGHT",     0, 0)
    dropBar:SetPoint("BOTTOMRIGHT", dropScroll, "BOTTOMRIGHT",  0, 0)
    local thumb = dropBar:CreateTexture(nil, "OVERLAY")
    thumb:SetTexture(TEX); thumb:SetVertexColor(unpack(C_ACCENT)); thumb:SetSize(8, 24)
    dropBar:SetThumbTexture(thumb)
    dropBar:SetScript("OnValueChanged", function(_, v) dropScroll:SetVerticalScroll(v) end)

    dropScroll:EnableMouseWheel(true)
    dropScroll:SetScript("OnMouseWheel", function(_, delta)
        local _, maxV = dropBar:GetMinMaxValues()
        if maxV <= 0 then return end
        local cur = dropBar:GetValue()
        dropBar:SetValue(math.max(0, math.min(maxV, cur - delta * DROP_ROW_H)))
    end)

    return dropPopup, dropScroll, dropScrollChild, dropBar
end

local function MakeDropdown(parent, w, h)
    local dd = CreateFrame("Button", nil, parent, "BackdropTemplate")
    SetBD(dd, C_ELEM, C_BDR)
    dd:SetSize(w or 160, h or 22)
    local fs = dd:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    fs:SetPoint("LEFT", 6, 0)
    fs:SetTextColor(unpack(C_TEXT))
    dd.text = fs
    local arrow = dd:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    arrow:SetPoint("RIGHT", -6, 0)
    arrow:SetText("v")
    arrow:SetTextColor(unpack(C_DIM))
    dd:SetScript("OnEnter", function(s) s:SetBackdropColor(unpack(C_HOVER)) end)
    dd:SetScript("OnLeave", function(s) s:SetBackdropColor(unpack(C_ELEM)) end)
    function dd:SetValue(text) fs:SetText(tostring(text or "")) end
    function dd:Open(items, onSelect)
        local p, scroll, child, bar = GetDropPopup()
        for _, row in ipairs(p.rows) do row:Hide() end

        local padX = 6
        local maxW = self:GetWidth()
        for i, item in ipairs(items) do
            local row = p.rows[i]
            if not row then
                row = CreateFrame("Button", nil, child, "BackdropTemplate")
                SetBD(row, C_ELEM, C_BDR)
                row:SetHeight(DROP_ROW_H)
                local rfs = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
                rfs:SetPoint("LEFT", padX, 0); rfs:SetTextColor(unpack(C_TEXT))
                row.text = rfs
                row:SetScript("OnEnter", function(s) s:SetBackdropColor(unpack(C_HOVER)) end)
                row:SetScript("OnLeave", function(s) s:SetBackdropColor(unpack(C_ELEM)) end)
                p.rows[i] = row
            end
            row:SetParent(child)  -- defensive in case of pool reuse across popups
            row:ClearAllPoints()
            row:SetPoint("TOPLEFT",  child, "TOPLEFT",  0, -(i - 1) * DROP_ROW_H)
            row:SetPoint("TOPRIGHT", child, "TOPRIGHT", 0, -(i - 1) * DROP_ROW_H)
            row.text:SetText(item.label)
            row:SetScript("OnClick", function()
                p:Hide()
                if onSelect then onSelect(item.value, item.label) end
            end)
            row:Show()
            local tw = row.text:GetStringWidth() + padX * 2 + 16
            if tw > maxW then maxW = tw end
        end

        local total = #items
        local visible = math.min(total, DROP_VISIBLE_ROWS)
        local needsScroll = total > DROP_VISIBLE_ROWS
        local popupW = maxW + (needsScroll and 12 or 0)
        local popupH = visible * DROP_ROW_H + 4

        child:SetSize(maxW, total * DROP_ROW_H)

        if needsScroll then
            bar:SetMinMaxValues(0, (total - DROP_VISIBLE_ROWS) * DROP_ROW_H)
            bar:SetValue(0)
            bar:Show()
        else
            bar:Hide(); bar:SetMinMaxValues(0, 0); bar:SetValue(0)
        end
        scroll:SetVerticalScroll(0)

        p:ClearAllPoints()
        p:SetPoint("TOPLEFT", self, "BOTTOMLEFT", 0, -2)
        p:SetSize(popupW, popupH)
        p:Show()
    end
    return dd
end

-- -------------------------------------------------- --
--  Tab bar                                           --
-- -------------------------------------------------- --

local function MakeTabBar(parent, tabs, initial, onSelect)
    local bar = CreateFrame("Frame", nil, parent)
    bar:SetHeight(TAB_H)
    local buttons = {}
    local active  = initial or 1
    local function refresh()
        for i, b in ipairs(buttons) do
            if i == active then
                b:SetBackdropColor(unpack(C_ACCENT))
                b.text:SetTextColor(1, 1, 1, 1)
            else
                b:SetBackdropColor(unpack(C_ELEM))
                b.text:SetTextColor(unpack(C_TEXT))
            end
        end
    end
    for i, name in ipairs(tabs) do
        local b = MakeButton(bar, name, 130, TAB_H - 2)
        b:SetPoint("LEFT", (i - 1) * 132, 0)
        -- MakeButton's default OnEnter/OnLeave reset backdrop to HOVER/ELEM,
        -- which stomps the active-tab accent color on mouseover. Override so
        -- OnLeave restores ACCENT when this button is the active tab.
        b:SetScript("OnEnter", function(s)
            if i ~= active then s:SetBackdropColor(unpack(C_HOVER)) end
        end)
        b:SetScript("OnLeave", function(s)
            if i == active then
                s:SetBackdropColor(unpack(C_ACCENT))
            else
                s:SetBackdropColor(unpack(C_ELEM))
            end
        end)
        b:SetScript("OnClick", function()
            active = i; refresh()
            if onSelect then onSelect(i, name) end
        end)
        buttons[i] = b
    end
    refresh()
    function bar:Activate(i)
        active = i; refresh()
        if onSelect then onSelect(i, tabs[i]) end
    end
    function bar:GetActive() return active end
    return bar
end

-- -------------------------------------------------- --
--  Helpers                                           --
-- -------------------------------------------------- --

local function Row(parent, yOff, label, labelW)
    local fs = MakeLabel(parent, label, nil, C_DIM)
    fs:SetPoint("TOPLEFT", PAD, yOff)
    fs:SetWidth(labelW or 110)
    fs:SetJustifyH("LEFT")
    return fs
end

-- Forward decl: ApplyPreviewState is defined further down but RefreshAll +
-- the setting-mutation closures (built before it) need to call it. Without
-- this the closures resolved the name as a global and the call became nil.
local ApplyPreviewState

local function RefreshAll()
    if not LECONT or not LECONT.db then return end
    if ns.SetupContainers then ns.SetupContainers(LECONT) end
    -- After SetupContainers rebuilds: re-establish the right preview mode
    -- based on selection state. Focused (selected only) wins over all-preview
    -- so settings changes don't un-focus the user's active edit target.
    if frame and frame:IsShown() then
        if selectedID and LECONT.db.profile.items[selectedID] then
            ApplyPreviewState(selectedID)
        elseif ns.PreviewAllContainers then
            ns.PreviewAllContainers()
        end
    end
end

local function NewContainerDefaults()
    return {
        type               = "container",
        name               = "New Container",
        enabled            = true,
        unit               = "player",
        filter             = "HELPFUL",
        maxAuras           = 8,
        iconSize           = 32,
        spacing            = 2,
        growDirection      = "RIGHT",
        wrapAfter          = 0,
        showCooldownSpiral = true,
        reverseSwipe       = false,
        sortDirection      = 0,  -- 0 = Normal (asc by expiration), 1 = Reverse (desc)
        hidePermanent      = false,  -- when true, auras with duration==0 are filtered out
        borderStyle        = "SOLID",
        borderSize         = 1,
        borderR            = 0, borderG = 0, borderB = 0,  -- defaults to black
        colorByDispel      = false,
        showDispelIcon     = true,        -- when borderStyle BLIZZARD, show with-icon atlas variant
        dispelColors       = nil,         -- nil = use global; populated when user overrides
        -- Text styles: override=false means use db.global.{stack,duration}Text.
        stackText          = { override = false, enabled = true },
        durationText       = { override = false, enabled = true },
        anchorFrame        = "UIParent",
        selfPoint          = "CENTER",
        anchorPoint        = "CENTER",
        xOffset            = 0,
        yOffset            = 0,
        strata             = "MEDIUM",
        iconAlpha          = 1,
        iconZoom           = 0,
        swipeR = 0, swipeG = 0, swipeB = 0, swipeA = 0.8,
        loadConditions     = {},          -- { specIDs = {[id]=true}, inCombat=bool, class="WARLOCK" }
    }
end

-- Focused-preview model: the currently-selected container previews; all
-- others stop. Called from BuildEditor + after every settings mutation so
-- the visible preview stays on the container the user is editing.
-- Assigned (not `local function`) to populate the forward-declared upvalue.
ApplyPreviewState = function(itemID)
    if not ns.containers then return end
    for cID, c in pairs(ns.containers) do
        if cID == itemID then
            if not c.previewing then c:Preview() end
        elseif c.previewing then
            c:StopPreview()
        end
    end
end

-- Stop ALL previews (used on settings frame Hide).
local function StopAllPreviews()
    if ns.StopAllContainerPreviews then ns.StopAllContainerPreviews() end
end

-- Current class's specs (sorted by spec index). Used by Load Conditions tab.
local function GetCurrentClassSpecs()
    local out = {}
    local _, classToken, classID = UnitClass("player")
    if not classID then return out end
    local num = GetNumSpecializationsForClassID and GetNumSpecializationsForClassID(classID) or 0
    for i = 1, num do
        local specID, specName, _, icon, role = GetSpecializationInfoForClassID(classID, i)
        if specID and specName then
            out[#out + 1] = { specID = specID, name = specName, icon = icon, role = role, classToken = classToken }
        end
    end
    return out
end

-- -------------------------------------------------- --
--  Constants                                         --
-- -------------------------------------------------- --

local ANCHOR_POINTS = {
    "TOPLEFT", "TOP", "TOPRIGHT",
    "LEFT",    "CENTER", "RIGHT",
    "BOTTOMLEFT", "BOTTOM", "BOTTOMRIGHT",
}
local UNITS    = { "player", "target", "focus", "pet", "party1", "party2", "party3", "party4" }
local FILTERS  = {
    { label = "Buffs (HELPFUL)",                  value = "HELPFUL" },
    { label = "My Buffs (HELPFUL|PLAYER)",         value = "HELPFUL|PLAYER" },
    { label = "Debuffs (HARMFUL)",                value = "HARMFUL" },
    { label = "My Debuffs (HARMFUL|PLAYER)",       value = "HARMFUL|PLAYER" },
    { label = "Cancelable Buffs",                 value = "HELPFUL|CANCELABLE" },
}
local STRATAS  = { "BACKGROUND", "LOW", "MEDIUM", "HIGH", "DIALOG", "FULLSCREEN" }
local GROW_DIRS = { "RIGHT", "LEFT", "UP", "DOWN" }
local DISPEL_TYPES = {
    { key = 0, label = "None / Enrage" },
    { key = 1, label = "Magic" },
    { key = 2, label = "Curse" },
    { key = 3, label = "Disease" },
    { key = 4, label = "Poison" },
    { key = 5, label = "Bleed" },
}
local FONT_OUTLINES = { "NONE", "OUTLINE", "THICKOUTLINE", "MONOCHROME, OUTLINE" }

-- -------------------------------------------------- --
--  Tab content builders                              --
-- -------------------------------------------------- --

-- Forward decl so tab builders can request a tab rebuild (e.g. toggling the
-- "Override Colors" checkbox needs to show/hide swatch rows).
local ShowEditorTab

-- Forward decl for the centralized view-switch helper. Routing all show/hide
-- calls through one function ensures the editor and global panels never end
-- up showing simultaneously, regardless of which code path invokes the switch.
local SetView

local function BuildIconTab(p, item, itemID)
    local y = -PAD

    local function numRow(label, field, default)
        Row(p, y, label)
        local eb = MakeEdit(p, 80, 22)
        eb:SetPoint("TOPLEFT", PAD + 120, y + 4)
        eb.edit:SetText(tostring(item[field] or default))
        eb.edit:SetScript("OnEditFocusLost", function(e)
            local n = tonumber(e:GetText())
            item[field] = n or default; RefreshAll(); ApplyPreviewState(itemID)
        end)
        y = y - ROW_H
    end

    local function ddRow(label, items, currentValue, onPick)
        Row(p, y, label)
        local dd = MakeDropdown(p, 200, 22)
        dd:SetPoint("TOPLEFT", PAD + 120, y + 4)
        dd:SetValue(currentValue)
        dd:SetScript("OnClick", function(s)
            s:Open(items, function(v, l) dd:SetValue(l); onPick(v); RefreshAll(); ApplyPreviewState(itemID) end)
        end)
        y = y - ROW_H
        return dd
    end

    local function strDD(label, choices, currentValue, setter)
        local items = {}
        for _, v in ipairs(choices) do items[#items + 1] = { label = v, value = v } end
        return ddRow(label, items, currentValue, setter)
    end

    -- Unit + filter
    strDD("Unit", UNITS, item.unit or "player", function(v) item.unit = v end)

    -- Filter (preset list, doesn't rebuild editor — preview survives)
    do
        Row(p, y, "Filter")
        local dd = MakeDropdown(p, 240, 22)
        dd:SetPoint("TOPLEFT", PAD + 120, y + 4)
        local cur = item.filter or "HELPFUL"
        for _, f in ipairs(FILTERS) do if f.value == cur then cur = f.label end end
        dd:SetValue(cur)
        dd:SetScript("OnClick", function(s)
            s:Open(FILTERS, function(v, l)
                item.filter = v
                item.filterGroups = nil
                dd:SetValue(l); RefreshAll(); ApplyPreviewState(itemID)
            end)
        end)
        y = y - ROW_H
    end

    numRow("Max Auras", "maxAuras", 8)
    numRow("Icon Size", "iconSize", 32)
    numRow("Spacing",   "spacing",  2)

    strDD("Grow Direction", GROW_DIRS, item.growDirection or "RIGHT", function(v) item.growDirection = v end)
    numRow("Wrap After (0=off)", "wrapAfter", 0)

    -- Sort direction. Blizzard does the comparison internally on secret aura
    -- fields via C_UnitAuras.GetUnitAuras + UnitAuraSortDirection, so no
    -- secret-value taint hits us. Rule fixed to Expiration; user controls
    -- direction only.
    do
        Row(p, y, "Sort")
        local dd = MakeDropdown(p, 200, 22)
        dd:SetPoint("TOPLEFT", PAD + 120, y + 4)
        local SORTS = {
            { label = "Ascending (soonest first)", value = 0 },
            { label = "Descending (longest first)", value = 1 },
        }
        local cur = (item.sortDirection == 1) and SORTS[2].label or SORTS[1].label
        dd:SetValue(cur)
        dd:SetScript("OnClick", function(s)
            s:Open(SORTS, function(v, l)
                item.sortDirection = v; dd:SetValue(l)
                RefreshAll(); ApplyPreviewState(itemID)
            end)
        end)
        y = y - ROW_H
    end

    -- Hide permanent (no-duration) auras. Filtered post-fetch via plain
    -- compare on auraData.duration — same pattern Blizzard's UnitFrame uses
    -- (CompactArenaFrame.lua:527).
    Row(p, y, "Hide Permanent")
    local hp = MakeCheck(p)
    hp:SetPoint("TOPLEFT", PAD + 120, y + 4)
    hp:SetChecked(item.hidePermanent == true)
    hp.onChanged = function(v)
        item.hidePermanent = v and true or false
        RefreshAll(); ApplyPreviewState(itemID)
    end
    local hpLbl = MakeLabel(p, "Hide auras with no duration", nil, C_DIM)
    hpLbl:SetPoint("LEFT", hp, "RIGHT", 8, 0)
    y = y - ROW_H

    -- Strata
    strDD("Strata", STRATAS, item.strata or "MEDIUM", function(v) item.strata = v end)

    -- Show cooldown spiral
    Row(p, y, "Show Cooldown")
    local cd = MakeCheck(p)
    cd:SetPoint("TOPLEFT", PAD + 120, y + 4)
    cd:SetChecked(item.showCooldownSpiral ~= false)
    cd.onChanged = function(v) item.showCooldownSpiral = v and true or false; RefreshAll(); ApplyPreviewState(itemID) end
    y = y - ROW_H

    -- Reverse swipe toggle
    Row(p, y, "Reverse Swipe")
    local rs = MakeCheck(p)
    rs:SetPoint("TOPLEFT", PAD + 120, y + 4)
    rs:SetChecked(item.reverseSwipe == true)
    rs.onChanged = function(v) item.reverseSwipe = v and true or false; RefreshAll(); ApplyPreviewState(itemID) end
    y = y - ROW_H

    -- Border style + size + color
    strDD("Border Style", { "SOLID", "BLIZZARD" }, item.borderStyle or "SOLID", function(v) item.borderStyle = v end)
    numRow("Border Size", "borderSize", 1)
    Row(p, y, "Border Color")
    local sw = MakeColorSwatch(p, { item.borderR or 1, item.borderG or 1, item.borderB or 1, 1 }, function(r, g, b)
        item.borderR, item.borderG, item.borderB = r, g, b; RefreshAll(); ApplyPreviewState(itemID)
    end)
    sw:SetPoint("TOPLEFT", PAD + 120, y + 2)
    y = y - ROW_H

    -- Dispel section
    y = y - 6
    local dispelHdr = MakeLabel(p, "Dispel", nil, C_ACCENT)
    dispelHdr:SetPoint("TOPLEFT", PAD, y); y = y - 22

    -- Dispel overlay toggle — swaps borderStyle SOLID <-> BLIZZARD.
    Row(p, y, "Dispel Overlay")
    local dispelOv = MakeCheck(p)
    dispelOv:SetPoint("TOPLEFT", PAD + 120, y + 4)
    dispelOv:SetChecked(item.borderStyle == "BLIZZARD")
    dispelOv.onChanged = function(v)
        item.borderStyle = v and "BLIZZARD" or "SOLID"
        RefreshAll(); ApplyPreviewState(itemID)
    end
    local dispelOvLbl = MakeLabel(p, "Use Blizzard debuff border texture", nil, C_DIM)
    dispelOvLbl:SetPoint("LEFT", dispelOv, "RIGHT", 8, 0)
    y = y - ROW_H

    -- Color by dispel toggle
    Row(p, y, "Color by Dispel")
    local cbd = MakeCheck(p)
    cbd:SetPoint("TOPLEFT", PAD + 120, y + 4)
    cbd:SetChecked(item.colorByDispel == true)
    cbd.onChanged = function(v)
        item.colorByDispel = v and true or false
        RefreshAll(); ApplyPreviewState(itemID)
    end
    local cbdLbl = MakeLabel(p, "Tint border by dispel type", nil, C_DIM)
    cbdLbl:SetPoint("LEFT", cbd, "RIGHT", 8, 0)
    y = y - ROW_H

    -- Per-container dispel color override. Swatches are only rendered when
    -- override is on so the panel doesn't show greyed-out controls that imply
    -- the global colors are about to be edited.
    local function effectiveDispelColor(key)
        if item.dispelColors and item.dispelColors[key] then return item.dispelColors[key] end
        local g = LECONT.db.global.dispelColors
        if g and g[key] then return g[key] end
        return ns.DEFAULT_DISPEL_COLORS and ns.DEFAULT_DISPEL_COLORS[key] or {1, 1, 1, 1}
    end

    Row(p, y, "Override Colors")
    local ovTog = MakeCheck(p)
    ovTog:SetPoint("TOPLEFT", PAD + 120, y + 4)
    ovTog:SetChecked(item.dispelColors ~= nil)
    local ovLbl = MakeLabel(p, "Override global dispel colors", nil, C_DIM)
    ovLbl:SetPoint("LEFT", ovTog, "RIGHT", 8, 0)
    ovTog.onChanged = function(v)
        if v then
            -- Initialize override table from current effective values so the
            -- swatches don't snap to defaults visually on first reveal.
            item.dispelColors = {}
            for _, dt in ipairs(DISPEL_TYPES) do
                local c = effectiveDispelColor(dt.key)
                item.dispelColors[dt.key] = { c[1], c[2], c[3], c[4] or 1 }
            end
        else
            item.dispelColors = nil
        end
        RefreshAll(); ApplyPreviewState(itemID)
        -- Rebuild the Icon tab so the swatch rows appear/disappear.
        if ShowEditorTab then ShowEditorTab(1, item, itemID) end
    end
    y = y - ROW_H

    if item.dispelColors then
        for _, dt in ipairs(DISPEL_TYPES) do
            Row(p, y, dt.label)
            local s = MakeColorSwatch(p, effectiveDispelColor(dt.key), function(r, g, b, a)
                item.dispelColors = item.dispelColors or {}
                item.dispelColors[dt.key] = { r, g, b, a }
                RefreshAll(); ApplyPreviewState(itemID)
            end)
            s:SetPoint("TOPLEFT", PAD + 120, y + 2)
            y = y - ROW_H
        end
    end

    p:SetHeight(math.max(1, -y + PAD))
end

-- Generic per-text section. Renders the same controls used by both per-
-- container and global views. `tcfg` is the table that holds the actual
-- values; `opts.showOverride` adds the "Override Global" toggle at the top.
-- Returns the final y offset so the caller can chain sections.
local function BuildTextSection(p, y, header, tcfg, opts)
    opts = opts or {}
    local hdr = MakeLabel(p, header, nil, C_ACCENT)
    hdr:SetPoint("TOPLEFT", PAD, y); y = y - 22

    -- Override Global toggle (per-container only).
    if opts.showOverride then
        Row(p, y, "Override Global")
        local ov = MakeCheck(p)
        ov:SetPoint("TOPLEFT", PAD + 120, y + 4)
        ov:SetChecked(tcfg.override == true)
        ov.onChanged = function(v)
            tcfg.override = v and true or false
            RefreshAll()
            if opts.onRebuild then opts.onRebuild() end  -- rebuild tab to show/hide rows
        end
        local lbl = MakeLabel(p, "Use global text style when off", nil, C_DIM)
        lbl:SetPoint("LEFT", ov, "RIGHT", 8, 0)
        y = y - ROW_H
    end

    -- Enabled is always per-container — controls on/off independent of style override.
    if opts.showEnabled ~= false then
        Row(p, y, "Enabled")
        local en = MakeCheck(p)
        en:SetPoint("TOPLEFT", PAD + 120, y + 4)
        en:SetChecked(tcfg.enabled ~= false)
        en.onChanged = function(v)
            tcfg.enabled = v and true or false; RefreshAll()
            if opts.onPreview then opts.onPreview() end
        end
        y = y - ROW_H
    end

    -- Style rows: only render when override is on (per-container) or always (global).
    local renderStyle = (not opts.showOverride) or (tcfg.override == true)
    if not renderStyle then
        return y
    end

    -- Font (LSM)
    Row(p, y, "Font")
    local fontDD = MakeDropdown(p, 200, 22)
    fontDD:SetPoint("TOPLEFT", PAD + 120, y + 4)
    fontDD:SetValue(tcfg.font or "(default)")
    fontDD:SetScript("OnClick", function(s)
        local items = { { label = "(default)", value = "__default__" } }
        local list = LSM and LSM:List("font") or {}
        for _, name in ipairs(list) do items[#items + 1] = { label = name, value = name } end
        s:Open(items, function(v, l)
            tcfg.font = (v == "__default__") and nil or v
            fontDD:SetValue(l); RefreshAll()
            if opts.onPreview then opts.onPreview() end
        end)
    end)
    y = y - ROW_H

    Row(p, y, "Size")
    local sz = MakeEdit(p, 60, 22)
    sz:SetPoint("TOPLEFT", PAD + 120, y + 4)
    sz.edit:SetText(tostring(tcfg.fontSize or 12))
    sz.edit:SetScript("OnEditFocusLost", function(e)
        tcfg.fontSize = tonumber(e:GetText()) or 12; RefreshAll()
        if opts.onPreview then opts.onPreview() end
    end)
    y = y - ROW_H

    Row(p, y, "Outline")
    local olDD = MakeDropdown(p, 160, 22)
    olDD:SetPoint("TOPLEFT", PAD + 120, y + 4)
    olDD:SetValue(tcfg.fontOutline or "OUTLINE")
    olDD:SetScript("OnClick", function(s)
        local items = {}
        for _, ol in ipairs(FONT_OUTLINES) do items[#items + 1] = { label = ol, value = ol } end
        s:Open(items, function(v, l)
            tcfg.fontOutline = v; olDD:SetValue(l); RefreshAll()
            if opts.onPreview then opts.onPreview() end
        end)
    end)
    y = y - ROW_H

    Row(p, y, "Color")
    local col = MakeColorSwatch(p, tcfg.color or {1, 1, 1, 1}, function(r, g, b, a)
        tcfg.color = { r, g, b, a }; RefreshAll()
        if opts.onPreview then opts.onPreview() end
    end)
    col:SetPoint("TOPLEFT", PAD + 120, y + 2)
    y = y - ROW_H

    -- Position: text anchored to the parent icon at the chosen point with the
    -- same point on both ends (so TOPRIGHT means text's TOPRIGHT corner sits
    -- at icon's TOPRIGHT corner). Offsets fine-tune from there.
    Row(p, y, "Position")
    local posDD = MakeDropdown(p, 140, 22)
    posDD:SetPoint("TOPLEFT", PAD + 120, y + 4)
    posDD:SetValue(tcfg.position or (opts.defaultPosition or "CENTER"))
    posDD:SetScript("OnClick", function(s)
        local items = {}
        for _, pt in ipairs(ANCHOR_POINTS) do items[#items + 1] = { label = pt, value = pt } end
        s:Open(items, function(v, l)
            tcfg.position = v; posDD:SetValue(l); RefreshAll()
            if opts.onPreview then opts.onPreview() end
        end)
    end)
    y = y - ROW_H

    local function offsetRow(label, field, default)
        Row(p, y, label)
        local eb = MakeEdit(p, 70, 22)
        eb:SetPoint("TOPLEFT", PAD + 120, y + 4)
        eb.edit:SetText(tostring(tcfg[field] or default or 0))
        eb.edit:SetScript("OnEditFocusLost", function(e)
            tcfg[field] = tonumber(e:GetText()) or default or 0; RefreshAll()
            if opts.onPreview then opts.onPreview() end
        end)
        y = y - ROW_H
    end
    offsetRow("X Offset", "x", opts.defaultX)
    offsetRow("Y Offset", "y", opts.defaultY)

    return y
end

local function BuildTextTab(p, item, itemID)
    local y = -PAD

    item.stackText    = item.stackText    or { override = false, enabled = true }
    item.durationText = item.durationText or { override = false, enabled = true }

    local rebuild = function() if ShowEditorTab then ShowEditorTab(2, item, itemID) end end
    local preview = function() ApplyPreviewState(itemID) end

    y = BuildTextSection(p, y, "Stack Count Text", item.stackText, {
        showOverride    = true,
        onRebuild       = rebuild,
        onPreview       = preview,
        defaultPosition = "BOTTOMRIGHT",
        defaultX        = -2,
        defaultY        =  2,
    })
    y = y - 6
    y = BuildTextSection(p, y, "Duration Text", item.durationText, {
        showOverride    = true,
        onRebuild       = rebuild,
        onPreview       = preview,
        defaultPosition = "CENTER",
        defaultX        = 0,
        defaultY        = 0,
    })

    p:SetHeight(math.max(1, -y + PAD))
end

local function BuildPositionTab(p, item, itemID)
    local y = -PAD

    -- Anchor frame name
    Row(p, y, "Anchor Frame")
    local afE = MakeEdit(p, 240, 22)
    afE:SetPoint("TOPLEFT", PAD + 120, y + 4)
    afE.edit:SetText(tostring(item.anchorFrame or "UIParent"))
    afE.edit:SetScript("OnEditFocusLost", function(e)
        item.anchorFrame = e:GetText(); RefreshAll(); ApplyPreviewState(itemID)
    end)
    y = y - ROW_H

    -- Source point / Dest point
    local function pointRow(label, field, default)
        Row(p, y, label)
        local dd = MakeDropdown(p, 140, 22)
        dd:SetPoint("TOPLEFT", PAD + 120, y + 4)
        dd:SetValue(item[field] or default)
        dd:SetScript("OnClick", function(s)
            local items = {}
            for _, pt in ipairs(ANCHOR_POINTS) do items[#items + 1] = { label = pt, value = pt } end
            s:Open(items, function(v) item[field] = v; dd:SetValue(v); RefreshAll(); ApplyPreviewState(itemID) end)
        end)
        y = y - ROW_H
    end
    pointRow("Source Point", "selfPoint",   "CENTER")
    pointRow("Dest Point",   "anchorPoint", "CENTER")

    -- X / Y offset: [-] [slider] [+] [EditBox] all kept in sync.
    -- The +/- buttons step by 1 (matches slider's value step) for fine tuning
    -- when the slider's drag granularity isn't precise enough.
    local function offsetRow(label, field)
        Row(p, y, label)

        local minus = MakeButton(p, "-", 22, 22)
        minus:SetPoint("TOPLEFT", PAD + 120, y + 4)

        local slider = MakeThemedSlider(p, 200, 14, -800, 800, 1, item[field] or 0, nil)
        slider:SetPoint("LEFT", minus, "RIGHT", 6, -4)

        local plus = MakeButton(p, "+", 22, 22)
        plus:SetPoint("LEFT", slider, "RIGHT", 6, 4)

        local eb = MakeEdit(p, 60, 22)
        eb:SetPoint("LEFT", plus, "RIGHT", 6, 0)
        eb.edit:SetText(tostring(item[field] or 0))

        local function apply(v)
            item[field] = v
            eb.edit:SetText(tostring(v))
            if slider:GetValue() ~= v then slider:SetValue(v) end
            RefreshAll(); ApplyPreviewState(itemID)
        end
        slider:SetScript("OnValueChanged", function(_, v)
            local rounded = math.floor(v + 0.5)
            if rounded ~= item[field] then apply(rounded) end
        end)
        eb.edit:SetScript("OnEditFocusLost", function(e)
            local n = tonumber(e:GetText()) or 0
            apply(n)
        end)
        minus:SetScript("OnClick", function() apply((item[field] or 0) - 1) end)
        plus:SetScript("OnClick",  function() apply((item[field] or 0) + 1) end)

        y = y - ROW_H
    end
    offsetRow("X Offset", "xOffset")
    offsetRow("Y Offset", "yOffset")

    p:SetHeight(math.max(1, -y + PAD))
end

local function BuildLoadConditionsTab(p, item, itemID)
    local y = -PAD

    item.loadConditions = item.loadConditions or {}
    local lc = item.loadConditions

    -- Combat tri-state (cycle: nil → true → false → nil)
    Row(p, y, "Combat")
    local function combatLabel()
        if lc.inCombat == true  then return "|cff00ff00In Combat|r" end
        if lc.inCombat == false then return "|cffff4444Not In Combat|r" end
        return "|cff808080Any|r"
    end
    local cbBtn = MakeButton(p, combatLabel(), 200, 22)
    cbBtn:SetPoint("TOPLEFT", PAD + 120, y + 4)
    cbBtn:SetScript("OnClick", function()
        if lc.inCombat == nil      then lc.inCombat = true
        elseif lc.inCombat == true then lc.inCombat = false
        else                            lc.inCombat = nil end
        cbBtn.text:SetText(combatLabel())
        RefreshAll()
    end)
    y = y - ROW_H

    -- Spec multi-select (current class only, per user spec)
    y = y - 6
    local specHdr = MakeLabel(p, "Specs (current class)", nil, C_ACCENT)
    specHdr:SetPoint("TOPLEFT", PAD, y); y = y - 22

    local hint = MakeLabel(p, "No specs selected = loads in all specs", nil, C_DIM)
    hint:SetPoint("TOPLEFT", PAD, y); y = y - 22

    for _, spec in ipairs(GetCurrentClassSpecs()) do
        Row(p, y, "Spec " .. spec.name, 160)
        local cb = MakeCheck(p)
        cb:SetPoint("TOPLEFT", PAD + 160, y + 4)
        cb:SetChecked(lc.specIDs and lc.specIDs[spec.specID] or false)
        cb.onChanged = function(v)
            lc.specIDs = lc.specIDs or {}
            if v then lc.specIDs[spec.specID] = true else lc.specIDs[spec.specID] = nil end
            if not next(lc.specIDs) then lc.specIDs = nil end
            RefreshAll()
        end
        y = y - ROW_H
    end

    p:SetHeight(math.max(1, -y + PAD))
end

-- -------------------------------------------------- --
--  Editor host (tab bar + content panel)             --
-- -------------------------------------------------- --

local editorTabBar, editorContent, editorScroll, editorScrollBar
local editorTabPanels = {}  -- [idx] = panel frame

local function ClearTabPanel(panel)
    if not panel then return end
    for _, child in ipairs({ panel:GetChildren() }) do
        child:Hide(); child:SetParent(nil)
    end
    for _, region in ipairs({ panel:GetRegions() }) do
        if region.SetText then region:SetText("") end
        region:Hide()
    end
end

ShowEditorTab = function(idx, item, itemID)
    -- Hide all existing tab panels first
    for _, panel in pairs(editorTabPanels) do panel:Hide() end

    -- Lazy-create the requested tab panel and rebuild its content from item
    local panel = editorTabPanels[idx]
    if not panel then
        panel = CreateFrame("Frame", nil, editorContent)
        panel:SetPoint("TOPLEFT")
        panel:SetPoint("TOPRIGHT")
        panel:SetHeight(1)
        editorTabPanels[idx] = panel
    end
    -- Width must match editorContent so child SetPoint("TOPRIGHT") works.
    panel:SetPoint("TOPRIGHT", 0, 0)
    ClearTabPanel(panel)

    if     idx == 1 then BuildIconTab(panel, item, itemID)
    elseif idx == 2 then BuildTextTab(panel, item, itemID)
    elseif idx == 3 then BuildPositionTab(panel, item, itemID)
    elseif idx == 4 then BuildLoadConditionsTab(panel, item, itemID)
    end

    panel:Show()
    editorContent:SetHeight(panel:GetHeight())
end

-- Editor "header" row: Name, Enabled, Preview, Delete. Lives above the tab bar.
local editorHeader, headerName, headerEnabled, headerPreviewBtn, headerDelBtn

local function RebuildHeaderForItem(item, itemID)
    if not editorHeader then return end
    headerName.edit:SetText(item.name or "")
    headerName.edit:SetScript("OnEditFocusLost", function(e)
        item.name = e:GetText()
        if ns.RefreshContainerList then ns.RefreshContainerList() end
        RefreshAll()
    end)
    headerEnabled:SetChecked(item.enabled ~= false)
    headerEnabled.onChanged = function(v) item.enabled = v; RefreshAll() end

    -- Preview button reads/writes the engine's c.previewing directly. Default
    -- is ON (selected container is auto-previewed in focused mode); button
    -- toggles to show real auras instead.
    local function syncBtnLabel()
        local c = ns.GetContainer and ns.GetContainer(itemID)
        headerPreviewBtn.text:SetText((c and c.previewing) and "Stop" or "Preview")
    end
    syncBtnLabel()
    headerPreviewBtn:SetScript("OnClick", function()
        local c = ns.GetContainer and ns.GetContainer(itemID)
        if not c then return end
        if c.previewing then c:StopPreview() else c:Preview() end
        syncBtnLabel()
    end)

    headerDelBtn:SetScript("OnClick", function()
        StaticPopupDialogs["LECONT_DELETE_CONTAINER"] = {
            text         = "Delete container '" .. (item.name or itemID) .. "'?\n\nThis cannot be undone.",
            button1      = YES, button2 = NO,
            timeout = 0, whileDead = true, hideOnEscape = true,
            OnAccept = function()
                LECONT.db.profile.items[itemID] = nil
                selectedID = nil
                if ns.RefreshContainerList then ns.RefreshContainerList() end
                RefreshAll()
            end,
        }
        StaticPopup_Show("LECONT_DELETE_CONTAINER")
    end)
end

local function BuildEditor(item, itemID)
    -- Defensive: assert the container view layout via the single SetView
    -- helper. Every entry into BuildEditor lands here regardless of which
    -- code path called it.
    if SetView then SetView("container") end

    RebuildHeaderForItem(item, itemID)
    if editorTabBar then editorTabBar:Activate(currentTab) end
    -- ShowEditorTab is invoked by tabBar:Activate via its onSelect callback.
    -- That gives us "free" tab refresh after every BuildEditor call.
    ApplyPreviewState(itemID)
end

-- -------------------------------------------------- --
--  Container list (left side)                        --
-- -------------------------------------------------- --

local listRows = {}
local listContent
local LIST_ROW_H = 28

function ns.RefreshContainerList()
    for _, r in ipairs(listRows) do r:Hide() end
    local items = LECONT and LECONT.db and LECONT.db.profile.items or {}
    local sorted = {}
    for itemID, item in pairs(items) do
        if item.type == "container" then
            sorted[#sorted + 1] = { itemID = itemID, item = item }
        end
    end
    table.sort(sorted, function(a, b) return (a.item.name or "") < (b.item.name or "") end)

    for i, rec in ipairs(sorted) do
        local row = listRows[i]
        if not row then
            row = CreateFrame("Button", nil, listContent, "BackdropTemplate")
            SetBD(row, C_PANEL, C_BDR)
            row:SetHeight(LIST_ROW_H)
            local txt = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
            txt:SetPoint("LEFT", 8, 0); txt:SetTextColor(unpack(C_TEXT))
            row.text = txt
            row:SetScript("OnEnter", function(s) if selectedID ~= s._itemID then s:SetBackdropColor(unpack(C_HOVER)) end end)
            row:SetScript("OnLeave", function(s) if selectedID ~= s._itemID then s:SetBackdropColor(unpack(C_PANEL)) end end)
            row:SetScript("OnClick", function(s)
                selectedID = s._itemID
                if SetView then SetView("container") end
                ns.RefreshContainerList()
                if LECONT.db.profile.items[s._itemID] then
                    BuildEditor(LECONT.db.profile.items[s._itemID], s._itemID)
                end
            end)
            listRows[i] = row
        end
        row._itemID = rec.itemID
        row.text:SetText(rec.item.name or rec.itemID)
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT",  listContent, "TOPLEFT",  0, -(i - 1) * (LIST_ROW_H + 2))
        row:SetPoint("TOPRIGHT", listContent, "TOPRIGHT", 0, -(i - 1) * (LIST_ROW_H + 2))
        if selectedID == rec.itemID and currentView == "container" then
            row:SetBackdropColor(unpack(C_ROWACC))
        else
            row:SetBackdropColor(unpack(C_PANEL))
        end
        row:Show()
    end
    listContent:SetHeight(math.max(1, #sorted * (LIST_ROW_H + 2)))
end

-- -------------------------------------------------- --
--  Global Settings panel                             --
-- -------------------------------------------------- --

local globalPanel, globalContent, globalTabBar
local globalCurrentTab = 1  -- 1=Dispel Colors, 2=Stack Text, 3=Duration Text
local BuildGlobalPanel       -- forward decl so reset-button OnClick can see it

-- Hidden trash frame for ClearChildren. SetParent(nil) in modern WoW silently
-- reparents to UIParent, so the supposedly-orphaned children remain visible
-- in UI space and overlay any subsequent UI changes. Reparenting them under a
-- permanently-hidden frame puts them in a parent chain whose Hidden state
-- they inherit, guaranteeing they don't render.
local trashFrame
local function GetTrashFrame()
    if trashFrame then return trashFrame end
    trashFrame = CreateFrame("Frame", nil, UIParent)
    trashFrame:Hide()
    trashFrame:SetSize(1, 1)
    return trashFrame
end

local function ClearChildren(parent)
    local trash = GetTrashFrame()
    for _, child in ipairs({ parent:GetChildren() }) do
        child:Hide()
        child:ClearAllPoints()
        child:SetParent(trash)
    end
    for _, region in ipairs({ parent:GetRegions() }) do
        if region.SetText then region:SetText("") end
        region:Hide()
    end
end

-- Single source of truth for which panel is on screen. Hides each widget
-- explicitly rather than relying on the parent chain — some frame state
-- (especially scrollchildren after reparenting) doesn't reliably inherit
-- parent visibility, which produced the overlay bug.
SetView = function(view)
    currentView = view
    if view == "global" then
        if editorHeader  then editorHeader:Hide() end
        if editorTabBar  then editorTabBar:Hide() end
        if editorScroll  then editorScroll:Hide() end
        if editorContent then editorContent:Hide() end
        if globalPanel   then globalPanel:Show() end
        if globalTabBar  then globalTabBar:Show() end
        if globalContent then globalContent:Show() end
    else
        if globalPanel   then globalPanel:Hide() end
        if globalTabBar  then globalTabBar:Hide() end
        if globalContent then globalContent:Hide() end
        if editorHeader  then editorHeader:Show() end
        if editorTabBar  then editorTabBar:Show() end
        if editorScroll  then editorScroll:Show() end
        if editorContent then editorContent:Show() end
    end
end

local function BuildGlobalDispelTab(p)
    local y = -PAD
    local sub = MakeLabel(p,
        "Account-wide defaults. Used when a container has 'Color by Dispel' on and no per-container override.",
        nil, C_DIM)
    sub:SetPoint("TOPLEFT", PAD, y)
    sub:SetWidth(p:GetWidth() - PAD * 2)
    sub:SetWordWrap(true); sub:SetJustifyH("LEFT")
    y = y - 36

    LECONT.db.global.dispelColors = LECONT.db.global.dispelColors or {}
    local gColors = LECONT.db.global.dispelColors

    for _, dt in ipairs(DISPEL_TYPES) do
        Row(p, y, dt.label, 160)
        local cur = gColors[dt.key] or ns.DEFAULT_DISPEL_COLORS[dt.key] or {1, 1, 1, 1}
        local sw = MakeColorSwatch(p, cur, function(r, g, b, a)
            gColors[dt.key] = { r, g, b, a }
            RefreshAll()
        end)
        sw:SetPoint("TOPLEFT", PAD + 160, y + 2)
        y = y - ROW_H
    end

    y = y - 6
    local resetBtn = MakeDangerButton(p, "Reset to Blizzard defaults", 240, 24)
    resetBtn:SetPoint("TOPLEFT", PAD, y)
    resetBtn:SetScript("OnClick", function()
        for k, c in pairs(ns.DEFAULT_DISPEL_COLORS) do
            gColors[k] = { c[1], c[2], c[3], c[4] or 1 }
        end
        if BuildGlobalPanel then BuildGlobalPanel() end
        RefreshAll()
    end)
    y = y - 32
    p:SetHeight(math.max(1, -y + PAD))
end

local function BuildGlobalTextTab(p, which)
    LECONT.db.global.stackText    = LECONT.db.global.stackText    or {}
    LECONT.db.global.durationText = LECONT.db.global.durationText or {}
    local tcfg   = (which == "stack") and LECONT.db.global.stackText or LECONT.db.global.durationText
    local header = (which == "stack") and "Default Stack Text" or "Default Duration Text"
    local sub = MakeLabel(p,
        "Account-wide default. Containers use this style unless they enable 'Override Global' in their Text tab.",
        nil, C_DIM)
    sub:SetPoint("TOPLEFT", PAD, -PAD)
    sub:SetWidth(p:GetWidth() - PAD * 2)
    sub:SetWordWrap(true); sub:SetJustifyH("LEFT")
    local y = -PAD - 36
    y = BuildTextSection(p, y, header, tcfg, {
        showOverride    = false,
        showEnabled     = false,  -- enabled is per-container only
        onPreview       = function() end,
        defaultPosition = (which == "stack") and "BOTTOMRIGHT" or "CENTER",
        defaultX        = (which == "stack") and -2 or 0,
        defaultY        = (which == "stack") and  2 or 0,
    })
    p:SetHeight(math.max(1, -y + PAD))
end

BuildGlobalPanel = function()
    if not globalContent then return end
    -- Defensive: assert global view layout via SetView so entering global
    -- from any path lands in a consistent state.
    if SetView then SetView("global") end

    ClearChildren(globalContent)
    if globalCurrentTab == 1 then
        BuildGlobalDispelTab(globalContent)
    elseif globalCurrentTab == 2 then
        BuildGlobalTextTab(globalContent, "stack")
    elseif globalCurrentTab == 3 then
        BuildGlobalTextTab(globalContent, "duration")
    end
end

-- -------------------------------------------------- --
--  Frame layout                                      --
-- -------------------------------------------------- --

local function BuildFrame()
    if frame then return frame end

    frame = CreateFrame("Frame", "LECONTSettings", UIParent, "BackdropTemplate")
    SetBD(frame, C_BG, C_BDR)
    frame:SetSize(880, 620)
    frame:SetPoint("CENTER")
    frame:SetMovable(true); frame:EnableMouse(true)
    frame:SetClampedToScreen(true)
    frame:SetFrameStrata("HIGH")
    frame:Hide()

    -- Title bar
    local title = MakePanel(frame, C_PANEL, C_BDR)
    title:SetPoint("TOPLEFT");  title:SetPoint("TOPRIGHT")
    title:SetHeight(TITLE_H)
    title:EnableMouse(true); title:RegisterForDrag("LeftButton")
    title:SetScript("OnDragStart", function() frame:StartMoving() end)
    title:SetScript("OnDragStop",  function() frame:StopMovingOrSizing() end)

    local titleText = MakeLabel(title, "LECONT \194\183 Containers", 14, C_ACCENT)
    titleText:SetPoint("LEFT", 10, 0)

    local close = MakeButton(title, "X", 24, 20)
    close:SetPoint("RIGHT", -4, 0)
    close:SetScript("OnClick", function() frame:Hide() end)

    -- Left panel: container list + buttons
    local left = MakePanel(frame, C_PANEL, C_BDR)
    left:SetPoint("TOPLEFT",    0, -TITLE_H)
    left:SetPoint("BOTTOMLEFT", 0, 0)
    left:SetWidth(LEFT_W)

    local addBtn = MakeAccentButton(left, "+ Add Container", LEFT_W - 16, 24)
    addBtn:SetPoint("TOP", 0, -PAD)
    addBtn:SetScript("OnClick", function()
        local id = ns.GenerateUID()
        LECONT.db.profile.items[id] = NewContainerDefaults()
        selectedID = id
        SetView("container")
        ns.RefreshContainerList()
        BuildEditor(LECONT.db.profile.items[id], id)
        RefreshAll()
    end)

    local globalBtn = MakeButton(left, "Global Settings", LEFT_W - 16, 22)
    globalBtn:SetPoint("TOP", addBtn, "BOTTOM", 0, -4)
    globalBtn:SetScript("OnClick", function()
        SetView("global")
        BuildGlobalPanel()
        ns.RefreshContainerList()  -- re-tint list rows (deselect)
    end)

    local listScroll, listContent_, _ = MakeThemedScroll(left)
    listScroll:SetPoint("TOPLEFT",     PAD, -(PAD + 24 + 26 + 4))
    listScroll:SetPoint("BOTTOMRIGHT", -PAD, PAD)
    listContent = listContent_
    listContent:SetWidth(LEFT_W - PAD * 2 - 14)

    -- Right panel: header + tab bar + scrollable tab content; OR global content
    local right = MakePanel(frame, C_PANEL, C_BDR)
    right:SetPoint("TOPLEFT",     LEFT_W, -TITLE_H)
    right:SetPoint("BOTTOMRIGHT", 0, 0)

    -- Editor header (name + enabled + preview + delete)
    editorHeader = MakePanel(right, C_PANEL, C_BDR)
    editorHeader:SetPoint("TOPLEFT",  0, 0)
    editorHeader:SetPoint("TOPRIGHT", 0, 0)
    editorHeader:SetHeight(40)

    headerName = MakeEdit(editorHeader, 220, 22)
    headerName:SetPoint("LEFT", PAD, 0)

    headerEnabled = MakeCheck(editorHeader)
    headerEnabled:SetPoint("LEFT", headerName, "RIGHT", 12, 0)
    local enLbl = MakeLabel(editorHeader, "Enabled", nil, C_DIM)
    enLbl:SetPoint("LEFT", headerEnabled, "RIGHT", 6, 0)

    headerPreviewBtn = MakeButton(editorHeader, "Preview", 80, 22)
    headerPreviewBtn:SetPoint("LEFT", enLbl, "RIGHT", 16, 0)

    headerDelBtn = MakeDangerButton(editorHeader, "Delete", 80, 22)
    headerDelBtn:SetPoint("RIGHT", -PAD, 0)

    -- Tab bar
    editorTabBar = MakeTabBar(right, { "Icon", "Text", "Position", "Load Conditions" }, currentTab,
        function(idx)
            currentTab = idx
            if selectedID and LECONT.db.profile.items[selectedID] then
                ShowEditorTab(idx, LECONT.db.profile.items[selectedID], selectedID)
            end
        end)
    editorTabBar:SetPoint("TOPLEFT",  0, -40)
    editorTabBar:SetPoint("TOPRIGHT", 0, -40)

    -- Scrollable content for active tab
    editorScroll, editorContent, editorScrollBar = MakeThemedScroll(right)
    editorScroll:SetPoint("TOPLEFT",     0, -(40 + TAB_H))
    editorScroll:SetPoint("BOTTOMRIGHT", 0, 0)
    editorContent:SetWidth(right:GetWidth() - 16)
    right:HookScript("OnSizeChanged", function() editorContent:SetWidth(right:GetWidth() - 16) end)

    -- Global panel (overlays editor area, only one visible at a time)
    globalPanel = MakePanel(right, C_PANEL, C_BDR)
    globalPanel:SetPoint("TOPLEFT");  globalPanel:SetPoint("BOTTOMRIGHT")
    globalPanel:Hide()

    -- Tab bar at the top of the global panel: Dispel Colors / Stack Text / Duration Text
    globalTabBar = MakeTabBar(globalPanel,
        { "Dispel Colors", "Stack Text", "Duration Text" },
        globalCurrentTab,
        function(idx)
            globalCurrentTab = idx
            BuildGlobalPanel()
        end)
    globalTabBar:SetPoint("TOPLEFT",  0, 0)
    globalTabBar:SetPoint("TOPRIGHT", 0, 0)

    local gScroll, gContent, _ = MakeThemedScroll(globalPanel)
    gScroll:SetPoint("TOPLEFT",     0, -TAB_H)
    gScroll:SetPoint("BOTTOMRIGHT", 0, 0)
    globalContent = gContent
    globalContent:SetWidth(right:GetWidth() - 16)
    right:HookScript("OnSizeChanged", function() globalContent:SetWidth(right:GetWidth() - 16) end)

    -- Initial state
    frame:SetScript("OnShow", function()
        ns.RefreshContainerList()
        if currentView == "global" then
            BuildGlobalPanel()  -- internally calls SetView("global")
        else
            SetView("container")
            if selectedID and LECONT.db.profile.items[selectedID] then
                -- BuildEditor's ApplyPreviewState focuses preview on selected.
                BuildEditor(LECONT.db.profile.items[selectedID], selectedID)
            else
                -- No selection → preview every container so the user can
                -- visually identify them all (border + name label).
                if ns.PreviewAllContainers then ns.PreviewAllContainers() end
            end
        end
    end)
    frame:SetScript("OnHide", StopAllPreviews)

    return frame
end

-- -------------------------------------------------- --
--  Combat lockout                                    --
-- -------------------------------------------------- --

local pendingAction
local combatFrame = CreateFrame("Frame")
combatFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
combatFrame:SetScript("OnEvent", function()
    if pendingAction then
        local a = pendingAction; pendingAction = nil
        if a == "open"   then BuildFrame():Show() end
        if a == "toggle" then
            local f = BuildFrame()
            if f:IsShown() then f:Hide() else f:Show() end
        end
    end
end)

local function DeferOrRunNow(action)
    if InCombatLockdown() then
        pendingAction = action
        ns.lpmsg("Settings: deferred until combat ends")
    else
        pendingAction = nil
        if action == "open" then BuildFrame():Show()
        elseif action == "toggle" then
            local f = BuildFrame()
            if f:IsShown() then f:Hide() else f:Show() end
        end
    end
end

function ns.OpenSettings()   DeferOrRunNow("open")  end
function ns.ToggleSettings()
    if frame and frame:IsShown() then frame:Hide(); pendingAction = nil; return end
    DeferOrRunNow("toggle")
end
function ns.CloseSettings()
    pendingAction = nil
    if frame then frame:Hide() end
end
