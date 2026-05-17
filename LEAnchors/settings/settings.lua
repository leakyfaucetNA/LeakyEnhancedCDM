-- settings.lua
-- Native settings panel for LEAnchors. Mirrors LECONT's theme + primitives.
-- Two top-level tabs: Anchors / Custom Triggers. Each tab has a scrollable
-- list of user-added items with an "+ Add" button.

local _, ns = ...

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
local TAB_H    = 26
local LEFT_W   = 260
local ROW_H    = 30
local PAD      = 8

-- -------------------------------------------------- --
--  State                                             --
-- -------------------------------------------------- --

local frame
local currentTab          = 1     -- 1 = Anchors, 2 = Custom Triggers
local currentScope        = "profile"  -- "profile" | "global"  (only meaningful for tab 1)
local selectedID                       -- itemID currently being edited
local anchorEditorInnerTab = 1         -- inner tab within the anchor editor: 1 = Anchor, 2 = Load Conditions

-- Resolve the active item store based on currentTab + currentScope. Custom
-- triggers always live in the per-character profile; anchors switch between
-- profile (character-specific) and global (account-wide with load conditions).
local function GetActiveItemStore()
    if currentTab == 1 and currentScope == "global" then
        return LEANC.db.global.items
    end
    return LEANC.db.profile.items
end

-- -------------------------------------------------- --
--  Theme primitives                                  --
-- -------------------------------------------------- --

local function SetBD(f, bg, bdr)
    f:SetBackdrop({
        bgFile = TEX, edgeFile = TEX, edgeSize = 1,
        insets = { left = 1, right = 1, top = 1, bottom = 1 },
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
    fs:SetPoint("CENTER"); fs:SetText(text or ""); fs:SetTextColor(unpack(C_TEXT))
    b.text = fs
    b:SetScript("OnEnter", function(s) s:SetBackdropColor(unpack(C_HOVER)) end)
    b:SetScript("OnLeave", function(s) s:SetBackdropColor(unpack(C_ELEM))  end)
    return b
end

local function MakeAccentButton(parent, text, w, h)
    local b = MakeButton(parent, text, w, h)
    b:SetBackdropColor(unpack(C_ACCENT))
    b:SetScript("OnEnter", function(s) s:SetBackdropColor(0.55, 0.55, 1.0, 1) end)
    b:SetScript("OnLeave", function(s) s:SetBackdropColor(unpack(C_ACCENT))   end)
    return b
end

local function MakeDangerButton(parent, text, w, h)
    local b = MakeButton(parent, text, w, h)
    b:SetBackdropColor(unpack(C_DANGER))
    b:SetScript("OnEnter", function(s) s:SetBackdropColor(0.85, 0.30, 0.30, 1) end)
    b:SetScript("OnLeave", function(s) s:SetBackdropColor(unpack(C_DANGER))    end)
    return b
end

local function MakeCheck(parent)
    local c = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    SetBD(c, C_ELEM, C_BDR); c:SetSize(18, 18); c:EnableMouse(true)
    local fill = c:CreateTexture(nil, "OVERLAY")
    fill:SetTexture(TEX)
    fill:SetPoint("TOPLEFT", 3, -3); fill:SetPoint("BOTTOMRIGHT", -3, 3)
    fill:SetVertexColor(unpack(C_ACCENT)); fill:Hide()
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
    SetBD(holder, C_ELEM, C_BDR); holder:SetSize(w or 160, h or 22)
    local eb = CreateFrame("EditBox", nil, holder)
    eb:SetPoint("TOPLEFT", 6, -3); eb:SetPoint("BOTTOMRIGHT", -6, 3)
    eb:SetAutoFocus(false); eb:SetFontObject("GameFontNormal")
    eb:SetTextColor(unpack(C_TEXT))
    eb:SetScript("OnEscapePressed", eb.ClearFocus)
    eb:SetScript("OnEnterPressed",  eb.ClearFocus)
    holder.edit = eb
    return holder
end

-- Multiline edit box for Lua trigger / untrigger function bodies.
local function MakeMultilineEdit(parent, w, h)
    local holder = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    SetBD(holder, C_ELEM, C_BDR); holder:SetSize(w or 360, h or 80)
    local scroll = CreateFrame("ScrollFrame", nil, holder, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 6, -3); scroll:SetPoint("BOTTOMRIGHT", -22, 3)
    local eb = CreateFrame("EditBox", nil, scroll)
    eb:SetMultiLine(true)
    eb:SetSize(w - 28, h - 6)
    eb:SetAutoFocus(false)
    eb:SetFontObject("GameFontHighlightSmall")
    eb:SetTextColor(unpack(C_TEXT))
    eb:SetScript("OnEscapePressed", eb.ClearFocus)
    eb:SetMaxLetters(0)
    scroll:SetScrollChild(eb)
    holder.edit = eb
    return holder
end

-- -------------------------------------------------- --
--  Themed dropdown popup with scroll                 --
-- -------------------------------------------------- --

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

    dropPopup = CreateFrame("Frame", "LEANCDropPopup", UIParent, "BackdropTemplate")
    SetBD(dropPopup, C_PANEL, C_BDR)
    dropPopup:SetFrameStrata("FULLSCREEN_DIALOG")
    dropPopup:SetFrameLevel(dropCatcher:GetFrameLevel() + 10)
    dropPopup:Hide(); dropPopup.rows = {}
    dropPopup:SetScript("OnShow", function() dropCatcher:Show() end)
    dropPopup:SetScript("OnHide", function() dropCatcher:Hide() end)

    dropScroll = CreateFrame("ScrollFrame", nil, dropPopup)
    dropScroll:SetPoint("TOPLEFT", 2, -2); dropScroll:SetPoint("BOTTOMRIGHT", -2, 2)
    dropScrollChild = CreateFrame("Frame", nil, dropScroll); dropScrollChild:SetSize(1, 1)
    dropScroll:SetScrollChild(dropScrollChild)

    dropBar = CreateFrame("Slider", nil, dropScroll, "BackdropTemplate")
    SetBD(dropBar, C_PANEL, C_BDR)
    dropBar:SetWidth(10); dropBar:SetOrientation("VERTICAL")
    dropBar:SetMinMaxValues(0, 0); dropBar:SetValueStep(1); dropBar:SetObeyStepOnDrag(false)
    dropBar:SetPoint("TOPRIGHT", dropScroll, "TOPRIGHT", 0, 0)
    dropBar:SetPoint("BOTTOMRIGHT", dropScroll, "BOTTOMRIGHT", 0, 0)
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
    SetBD(dd, C_ELEM, C_BDR); dd:SetSize(w or 160, h or 22)
    local fs = dd:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    fs:SetPoint("LEFT", 6, 0); fs:SetTextColor(unpack(C_TEXT))
    dd.text = fs
    local arrow = dd:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    arrow:SetPoint("RIGHT", -6, 0); arrow:SetText("v"); arrow:SetTextColor(unpack(C_DIM))
    dd:SetScript("OnEnter", function(s) s:SetBackdropColor(unpack(C_HOVER)) end)
    dd:SetScript("OnLeave", function(s) s:SetBackdropColor(unpack(C_ELEM))  end)
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
                SetBD(row, C_ELEM, C_BDR); row:SetHeight(DROP_ROW_H)
                local rfs = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
                rfs:SetPoint("LEFT", padX, 0); rfs:SetTextColor(unpack(C_TEXT))
                row.text = rfs
                row:SetScript("OnEnter", function(s) s:SetBackdropColor(unpack(C_HOVER)) end)
                row:SetScript("OnLeave", function(s) s:SetBackdropColor(unpack(C_ELEM))  end)
                p.rows[i] = row
            end
            row:SetParent(child)
            row:ClearAllPoints()
            row:SetPoint("TOPLEFT",  child, "TOPLEFT",  0, -(i - 1) * DROP_ROW_H)
            row:SetPoint("TOPRIGHT", child, "TOPRIGHT", 0, -(i - 1) * DROP_ROW_H)
            row.text:SetText(item.label)
            row:SetScript("OnClick", function()
                p:Hide(); if onSelect then onSelect(item.value, item.label) end
            end)
            row:Show()
            local tw = row.text:GetStringWidth() + padX * 2 + 16
            if tw > maxW then maxW = tw end
        end
        local total = #items
        local visible = math.min(total, DROP_VISIBLE_ROWS)
        local needsScroll = total > DROP_VISIBLE_ROWS
        child:SetSize(maxW, total * DROP_ROW_H)
        if needsScroll then
            bar:SetMinMaxValues(0, (total - DROP_VISIBLE_ROWS) * DROP_ROW_H)
            bar:SetValue(0); bar:Show()
        else
            bar:Hide(); bar:SetMinMaxValues(0, 0); bar:SetValue(0)
        end
        scroll:SetVerticalScroll(0)
        p:ClearAllPoints()
        p:SetPoint("TOPLEFT", self, "BOTTOMLEFT", 0, -2)
        p:SetSize(maxW + (needsScroll and 12 or 0), visible * DROP_ROW_H + 4)
        p:Show()
    end
    return dd
end

-- -------------------------------------------------- --
--  Themed scroll frame                               --
-- -------------------------------------------------- --

local function MakeThemedScroll(parent)
    local scroll = CreateFrame("ScrollFrame", nil, parent)
    local content = CreateFrame("Frame", nil, scroll)
    content:SetSize(1, 1); scroll:SetScrollChild(content)

    local bar = CreateFrame("Slider", nil, scroll, "BackdropTemplate")
    SetBD(bar, C_PANEL, C_BDR); bar:SetWidth(12); bar:SetOrientation("VERTICAL")
    bar:SetMinMaxValues(0, 0); bar:SetValueStep(1); bar:SetObeyStepOnDrag(false)
    bar:SetPoint("TOPRIGHT", scroll, "TOPRIGHT", 0, 0)
    bar:SetPoint("BOTTOMRIGHT", scroll, "BOTTOMRIGHT", 0, 0)
    local thumb = bar:CreateTexture(nil, "OVERLAY")
    thumb:SetTexture(TEX); thumb:SetVertexColor(unpack(C_ACCENT)); thumb:SetSize(10, 30)
    bar:SetThumbTexture(thumb)
    bar:SetScript("OnValueChanged", function(_, v) scroll:SetVerticalScroll(v) end)

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
--  Themed context menu                               --
-- -------------------------------------------------- --

local ctxMenu, ctxCatcher
local function GetCtxMenu()
    if ctxMenu then return ctxMenu end
    ctxCatcher = CreateFrame("Button", nil, UIParent)
    ctxCatcher:SetAllPoints(UIParent)
    ctxCatcher:SetFrameStrata("FULLSCREEN_DIALOG")
    ctxCatcher:RegisterForClicks("AnyUp")
    ctxCatcher:Hide()
    ctxCatcher:SetScript("OnClick", function() if ctxMenu then ctxMenu:Hide() end end)

    ctxMenu = CreateFrame("Frame", nil, UIParent, "BackdropTemplate")
    SetBD(ctxMenu, C_PANEL, C_BDR)
    ctxMenu:SetFrameStrata("FULLSCREEN_DIALOG")
    ctxMenu:SetFrameLevel(ctxCatcher:GetFrameLevel() + 10)
    ctxMenu:Hide()
    ctxMenu.rows = {}
    ctxMenu:SetScript("OnShow", function() ctxCatcher:Show() end)
    ctxMenu:SetScript("OnHide", function() ctxCatcher:Hide() end)
    return ctxMenu
end

-- Show a small themed context menu at cursor with the given items
-- ({ {label, func}, ... }).
local function ShowContextMenu(items)
    local m = GetCtxMenu()
    for _, r in ipairs(m.rows) do r:Hide() end

    local rowH, padX = 22, 8
    local maxW = 120
    for i, item in ipairs(items) do
        local row = m.rows[i]
        if not row then
            row = CreateFrame("Button", nil, m, "BackdropTemplate")
            SetBD(row, C_ELEM, C_BDR)
            row:SetHeight(rowH)
            local fs = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
            fs:SetPoint("LEFT", padX, 0); fs:SetTextColor(unpack(C_TEXT))
            row.text = fs
            row:SetScript("OnEnter", function(s) s:SetBackdropColor(unpack(C_HOVER)) end)
            row:SetScript("OnLeave", function(s) s:SetBackdropColor(unpack(C_ELEM))  end)
            m.rows[i] = row
        end
        row.text:SetText(item.label)
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT",  m, "TOPLEFT",   2, -(2 + (i - 1) * rowH))
        row:SetPoint("TOPRIGHT", m, "TOPRIGHT", -2, -(2 + (i - 1) * rowH))
        row:SetScript("OnClick", function()
            m:Hide()
            if item.func then item.func() end
        end)
        row:Show()
        local tw = row.text:GetStringWidth() + padX * 2
        if tw > maxW then maxW = tw end
    end

    -- Position at cursor. GetCursorPosition returns screen pixels; convert
    -- to UIParent's effective scale so anchor offsets line up.
    local x, y = GetCursorPosition()
    local scale = UIParent:GetEffectiveScale()
    x, y = x / scale, y / scale
    m:ClearAllPoints()
    m:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", x, y)
    m:SetSize(maxW, #items * rowH + 4)
    m:Show()
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
        local b = MakeButton(bar, name, 150, TAB_H - 2)
        b:SetPoint("LEFT", (i - 1) * 152, 0)
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

local function RefreshAll()
    if not LEANC or not LEANC.db then return end
    if ns.SetupAnchors then ns.SetupAnchors(LEANC) end
    if ns.SetupCustomEvents then ns.SetupCustomEvents(LEANC) end
end

local ANCHOR_POINTS = {
    "TOPLEFT", "TOP", "TOPRIGHT", "LEFT", "CENTER", "RIGHT",
    "BOTTOMLEFT", "BOTTOM", "BOTTOMRIGHT",
}

local function NewAnchorDefaults()
    return {
        type         = "anchor",
        name         = "New Anchor",
        enabled      = true,
        sourceFrame  = "",
        destFrame    = "UIParent",
        sourcePoint  = "CENTER",
        destPoint    = "CENTER",
        xOffset      = 0,
        yOffset      = 0,
        safeAnchor   = false,
        setParent    = false,
        matchWidth   = false,
        widthMethod  = "fixed",       -- "fixed" | "twopoint"
        widthMode    = "DEST",        -- "DEST" | "CUSTOM"
        widthCustomFrame = "",
        widthOffset  = 0,
        leftOffset   = 0,
        rightOffset  = 0,
        tpAnchorVertical = "CENTER",
    }
end

local function NewCustomEventDefaults()
    return {
        type                  = "customEvent",
        name                  = "New Custom Trigger",
        enabled               = true,
        eventName             = "",         -- comma-separated WoW event names
        triggerFunc           = "function(event, ...)\n    return true\nend",
        untriggerMode         = "timer",    -- "timer" | "function"
        untriggerTimer        = 5,
        untriggerEvent        = "",
        untriggerFunc         = "function(event, ...)\n    return true\nend",
        messageName           = "",         -- broadcast on trigger
        untriggerMessageName  = "",         -- broadcast on untrigger
    }
end

-- -------------------------------------------------- --
--  Editor: forward decl + helpers                    --
-- -------------------------------------------------- --

local rightPanel, rightScroll, rightContent
local listContent, listRows = nil, {}
local LIST_ROW_H = 28

local BuildEditor          -- forward
local RefreshList          -- forward

local function ClearChildren(parent)
    for _, child in ipairs({ parent:GetChildren() }) do
        child:Hide(); child:SetParent(nil)
    end
    for _, region in ipairs({ parent:GetRegions() }) do
        if region.SetText then region:SetText("") end
        region:Hide()
    end
end

-- -------------------------------------------------- --
--  Anchor editor                                     --
-- -------------------------------------------------- --

-- Build the "Anchor" inner-tab content: source/dest frames, points, offsets,
-- match-width settings, delete. Renders starting at yStart and returns the
-- final y offset.
local function BuildAnchorMainTab(p, item, itemID, yStart)
    local y = yStart

    local function strRow(label, field, default, w)
        Row(p, y, label)
        local eb = MakeEdit(p, w or 240, 22)
        eb:SetPoint("TOPLEFT", PAD + 120, y + 4)
        eb.edit:SetText(tostring(item[field] or default or ""))
        eb.edit:SetScript("OnEditFocusLost", function(e)
            item[field] = e:GetText(); RefreshAll()
            if RefreshList then RefreshList() end
        end)
        y = y - ROW_H
    end
    local function numRow(label, field, default, w)
        Row(p, y, label)
        local eb = MakeEdit(p, w or 80, 22)
        eb:SetPoint("TOPLEFT", PAD + 120, y + 4)
        eb.edit:SetText(tostring(item[field] or default or 0))
        eb.edit:SetScript("OnEditFocusLost", function(e)
            item[field] = tonumber(e:GetText()) or default or 0; RefreshAll()
        end)
        y = y - ROW_H
    end
    local function checkRow(label, field, helpText)
        Row(p, y, label)
        local c = MakeCheck(p)
        c:SetPoint("TOPLEFT", PAD + 120, y + 4)
        c:SetChecked(item[field] == true)
        c.onChanged = function(v)
            item[field] = v and true or false
            RefreshAll()
            if BuildEditor then BuildEditor(item, itemID) end
        end
        if helpText then
            local lbl = MakeLabel(p, helpText, nil, C_DIM)
            lbl:SetPoint("LEFT", c, "RIGHT", 8, 0)
        end
        y = y - ROW_H
    end
    local function pointDD(label, field, default)
        Row(p, y, label)
        local dd = MakeDropdown(p, 160, 22)
        dd:SetPoint("TOPLEFT", PAD + 120, y + 4)
        dd:SetValue(item[field] or default)
        dd:SetScript("OnClick", function(s)
            local items = {}
            for _, pt in ipairs(ANCHOR_POINTS) do items[#items + 1] = { label = pt, value = pt } end
            s:Open(items, function(v) item[field] = v; dd:SetValue(v); RefreshAll() end)
        end)
        y = y - ROW_H
    end

    strRow("Name", "name", "")
    Row(p, y, "Enabled")
    local en = MakeCheck(p)
    en:SetPoint("TOPLEFT", PAD + 120, y + 4)
    en:SetChecked(item.enabled ~= false)
    en.onChanged = function(v)
        item.enabled = v; RefreshAll(); if RefreshList then RefreshList() end
    end
    y = y - ROW_H

    strRow("Source Frame", "sourceFrame", "",         260)
    strRow("Dest Frame",   "destFrame",   "UIParent", 260)
    pointDD("Source Point", "sourcePoint", "CENTER")
    pointDD("Dest Point",   "destPoint",   "CENTER")
    numRow("X Offset", "xOffset", 0)
    numRow("Y Offset", "yOffset", 0)

    checkRow("Safe Anchor", "safeAnchor",
        "Position via UIParent BOTTOMLEFT (avoids taint on protected frames)")
    checkRow("Set Parent",  "setParent", "Reparent source to dest")
    checkRow("Match Width", "matchWidth", "Resize source to match a frame's width")

    if item.matchWidth then
        Row(p, y, "Width Method")
        local mdd = MakeDropdown(p, 160, 22)
        mdd:SetPoint("TOPLEFT", PAD + 120, y + 4)
        local methodLabel = item.widthMethod == "twopoint" and "Two-Point" or "Fixed"
        mdd:SetValue(methodLabel)
        mdd:SetScript("OnClick", function(s)
            s:Open({
                { label = "Fixed (Width + Offset)", value = "fixed" },
                { label = "Two-Point (LEFT/RIGHT)", value = "twopoint" },
            }, function(v, l)
                item.widthMethod = v; mdd:SetValue(l); RefreshAll()
                if BuildEditor then BuildEditor(item, itemID) end
            end)
        end)
        y = y - ROW_H

        if item.widthMethod == "twopoint" then
            Row(p, y, "Vertical")
            local vdd = MakeDropdown(p, 160, 22)
            vdd:SetPoint("TOPLEFT", PAD + 120, y + 4)
            vdd:SetValue(item.tpAnchorVertical or "CENTER")
            vdd:SetScript("OnClick", function(s)
                s:Open({
                    { label = "TOP",    value = "TOP" },
                    { label = "CENTER", value = "CENTER" },
                    { label = "BOTTOM", value = "BOTTOM" },
                }, function(v) item.tpAnchorVertical = v; vdd:SetValue(v); RefreshAll() end)
            end)
            y = y - ROW_H
            numRow("Left Offset",  "leftOffset",  0)
            numRow("Right Offset", "rightOffset", 0)
        else
            Row(p, y, "Width Source")
            local wmdd = MakeDropdown(p, 160, 22)
            wmdd:SetPoint("TOPLEFT", PAD + 120, y + 4)
            local label = item.widthMode == "CUSTOM" and "Custom Frame" or "Dest Frame"
            wmdd:SetValue(label)
            wmdd:SetScript("OnClick", function(s)
                s:Open({
                    { label = "Dest Frame",   value = "DEST" },
                    { label = "Custom Frame", value = "CUSTOM" },
                }, function(v, l)
                    item.widthMode = v; wmdd:SetValue(l); RefreshAll()
                    if BuildEditor then BuildEditor(item, itemID) end
                end)
            end)
            y = y - ROW_H

            if item.widthMode == "CUSTOM" then
                strRow("Custom Frame", "widthCustomFrame", "", 240)
            end
            numRow("Width Offset", "widthOffset", 0)
        end
    end

    -- Delete
    y = y - 8
    local del = MakeDangerButton(p, "Delete Anchor", 200, 26)
    del:SetPoint("TOP", p, "TOP", 0, y)
    del:SetScript("OnClick", function()
        StaticPopupDialogs["LEANC_DELETE_ITEM"] = {
            text = "Delete '" .. (item.name or itemID) .. "'?\n\nThis cannot be undone.",
            button1 = YES, button2 = NO,
            timeout = 0, whileDead = true, hideOnEscape = true,
            OnAccept = function()
                GetActiveItemStore()[itemID] = nil
                selectedID = nil
                if RefreshList then RefreshList() end
                ClearChildren(rightContent)
                RefreshAll()
            end,
        }
        StaticPopup_Show("LEANC_DELETE_ITEM")
    end)
    y = y - 32
    return y
end

-- Build the "Load Conditions" inner-tab content: combat tri-state + a grid of
-- spec checkboxes laid out one row per class, with the class atlas icon on
-- the left and (spec icon + checkbox) pairs running horizontally.
local function BuildAnchorLoadConditionsTab(p, item, itemID, yStart)
    local y = yStart

    item.loadConditions = item.loadConditions or {}
    local lc = item.loadConditions

    -- Combat tri-state
    Row(p, y, "Combat")
    local function combatLabel()
        if lc.inCombat == true  then return "|cff00ff00In Combat|r"      end
        if lc.inCombat == false then return "|cffff4444Not In Combat|r"  end
        return "|cff808080Any|r"
    end
    local cbBtn = MakeButton(p, combatLabel(), 200, 22)
    cbBtn:SetPoint("TOPLEFT", PAD + 120, y + 4)
    cbBtn:SetScript("OnClick", function()
        if     lc.inCombat == nil  then lc.inCombat = true
        elseif lc.inCombat == true then lc.inCombat = false
        else                            lc.inCombat = nil end
        cbBtn.text:SetText(combatLabel())
        RefreshAll()
    end)
    y = y - ROW_H

    y = y - 6
    local hint = MakeLabel(p, "Specs (empty = loads in all specs)", nil, C_DIM)
    hint:SetPoint("TOPLEFT", PAD, y); y = y - 22

    -- Build the class/spec grid. One row per class:
    --   [class icon] | [spec icon][cb]  [spec icon][cb]  [spec icon][cb] ...
    -- Class atlases are named "classicon-<lowercase token>". Spec icons come
    -- from GetSpecializationInfoForClassID's 4th return (FileDataID).
    local ICON   = 24
    local CB     = 18
    local SLOT_W = ICON + 4 + CB + 12  -- one spec slot's width
    local ROW_GAP = 6

    local numClasses = (GetNumClasses and GetNumClasses()) or 0
    local classes = {}
    for i = 1, numClasses do
        local name, file, classID = GetClassInfo(i)
        if file and classID then
            classes[#classes + 1] = { name = name, token = file, classID = classID }
        end
    end
    table.sort(classes, function(a, b) return a.name < b.name end)

    for _, cls in ipairs(classes) do
        local rowY = y - 2

        -- Class icon (atlas)
        local classIcon = p:CreateTexture(nil, "ARTWORK")
        classIcon:SetSize(ICON, ICON)
        classIcon:SetPoint("TOPLEFT", PAD, rowY)
        -- SetAtlas accepts class atlas names; falls back gracefully if missing.
        classIcon:SetAtlas("classicon-" .. cls.token:lower())

        -- Iterate specs for this class
        local specs = {}
        local n = GetNumSpecializationsForClassID and GetNumSpecializationsForClassID(cls.classID) or 0
        for i = 1, n do
            local specID, specName, _, iconID = GetSpecializationInfoForClassID(cls.classID, i)
            if specID then
                specs[#specs + 1] = { specID = specID, name = specName, iconID = iconID }
            end
        end

        for idx, spec in ipairs(specs) do
            local slotX = PAD + ICON + 8 + (idx - 1) * SLOT_W

            local specTex = p:CreateTexture(nil, "ARTWORK")
            specTex:SetSize(ICON, ICON)
            specTex:SetPoint("TOPLEFT", slotX, rowY)
            if spec.iconID then specTex:SetTexture(spec.iconID) end
            -- Trim Blizzard icon edge for a slightly cleaner look
            specTex:SetTexCoord(0.08, 0.92, 0.08, 0.92)

            local cb = MakeCheck(p)
            cb:SetPoint("LEFT", specTex, "RIGHT", 4, 0)
            cb:SetChecked(lc.specIDs and lc.specIDs[spec.specID] or false)
            cb.onChanged = function(v)
                lc.specIDs = lc.specIDs or {}
                if v then lc.specIDs[spec.specID] = true else lc.specIDs[spec.specID] = nil end
                if not next(lc.specIDs) then lc.specIDs = nil end
                RefreshAll()
            end

            -- Tooltip on hover so the user can confirm which spec they're picking.
            specTex:SetParent(p)  -- keep texture as a child
            local tip = CreateFrame("Frame", nil, p)
            tip:SetAllPoints(specTex); tip:EnableMouse(true)
            tip:SetScript("OnEnter", function()
                GameTooltip:SetOwner(tip, "ANCHOR_RIGHT")
                GameTooltip:SetText(cls.name .. " — " .. (spec.name or "?"), 1, 1, 1)
                GameTooltip:Show()
            end)
            tip:SetScript("OnLeave", function() GameTooltip:Hide() end)
        end

        y = rowY - ICON - ROW_GAP
    end

    return y
end

local function BuildAnchorEditor(p, item, itemID)
    -- Inner tab bar: Anchor / Load Conditions. State is preserved at the
    -- module level (anchorEditorInnerTab) so navigating other UI parts and
    -- coming back keeps the same tab visible.
    local innerBar = MakeTabBar(p, { "Anchor", "Load Conditions" },
        anchorEditorInnerTab,
        function(idx)
            anchorEditorInnerTab = idx
            if BuildEditor then BuildEditor(item, itemID) end
        end)
    innerBar:SetPoint("TOPLEFT",  PAD, -PAD)
    innerBar:SetPoint("TOPRIGHT", -PAD, -PAD)

    local contentY = -PAD - TAB_H - 6
    local y
    if anchorEditorInnerTab == 2 then
        y = BuildAnchorLoadConditionsTab(p, item, itemID, contentY)
    else
        y = BuildAnchorMainTab(p, item, itemID, contentY)
    end

    p:SetHeight(math.max(1, -y + PAD))
end

-- -------------------------------------------------- --
--  Custom Trigger editor                             --
-- -------------------------------------------------- --

local function BuildCustomEventEditor(p, item, itemID)
    local y = -PAD

    local function strRow(label, field, default, w)
        Row(p, y, label)
        local eb = MakeEdit(p, w or 240, 22)
        eb:SetPoint("TOPLEFT", PAD + 120, y + 4)
        eb.edit:SetText(tostring(item[field] or default or ""))
        eb.edit:SetScript("OnEditFocusLost", function(e)
            item[field] = e:GetText(); RefreshAll()
            if RefreshList then RefreshList() end
        end)
        y = y - ROW_H
    end

    local function multilineRow(label, field, default, h)
        Row(p, y, label)
        local eb = MakeMultilineEdit(p, 360, h or 80)
        eb:SetPoint("TOPLEFT", PAD + 120, y + 4)
        eb.edit:SetText(tostring(item[field] or default or ""))
        eb.edit:SetScript("OnEditFocusLost", function(e)
            item[field] = e:GetText(); RefreshAll()
        end)
        y = y - (h or 80) - 8
    end

    local function numRow(label, field, default)
        Row(p, y, label)
        local eb = MakeEdit(p, 80, 22)
        eb:SetPoint("TOPLEFT", PAD + 120, y + 4)
        eb.edit:SetText(tostring(item[field] or default or 0))
        eb.edit:SetScript("OnEditFocusLost", function(e)
            item[field] = tonumber(e:GetText()) or default or 0; RefreshAll()
        end)
        y = y - ROW_H
    end

    strRow("Name", "name", "")
    -- Enabled
    Row(p, y, "Enabled")
    local en = MakeCheck(p)
    en:SetPoint("TOPLEFT", PAD + 120, y + 4)
    en:SetChecked(item.enabled ~= false)
    en.onChanged = function(v)
        item.enabled = v; RefreshAll(); if RefreshList then RefreshList() end
    end
    y = y - ROW_H

    strRow("Event(s)",     "eventName", "", 300)
    local hint = MakeLabel(p,
        "Comma-separated WoW events (e.g. UNIT_SPELLCAST_SUCCEEDED, PLAYER_REGEN_DISABLED)",
        nil, C_DIM)
    hint:SetPoint("TOPLEFT", PAD + 120, y + 4)
    y = y - 18

    multilineRow("Trigger Func", "triggerFunc",
        "function(event, ...)\n    return true\nend", 70)

    -- Untrigger mode
    Row(p, y, "Untrigger")
    local mdd = MakeDropdown(p, 160, 22)
    mdd:SetPoint("TOPLEFT", PAD + 120, y + 4)
    local mode = item.untriggerMode or "timer"
    mdd:SetValue(mode == "function" and "Function" or "Timer")
    mdd:SetScript("OnClick", function(s)
        s:Open({
            { label = "Timer",    value = "timer" },
            { label = "Function", value = "function" },
        }, function(v, l)
            item.untriggerMode = v; mdd:SetValue(l); RefreshAll()
            if BuildEditor then BuildEditor(item, itemID) end
        end)
    end)
    y = y - ROW_H

    if mode == "timer" then
        numRow("Timer (sec)", "untriggerTimer", 5)
    else
        strRow("Untrigger Event(s)", "untriggerEvent", "", 300)
        multilineRow("Untrigger Func", "untriggerFunc",
            "function(event, ...)\n    return true\nend", 70)
    end

    strRow("Trigger Message",   "messageName",          "", 240)
    strRow("Untrigger Message", "untriggerMessageName", "", 240)
    local msgHint = MakeLabel(p,
        "Broadcast names — WeakAuras.ScanEvents + LEANC:SendMessage receive these.",
        nil, C_DIM)
    msgHint:SetPoint("TOPLEFT", PAD + 120, y + 4)
    y = y - 18

    -- Delete
    y = y - 8
    local del = MakeDangerButton(p, "Delete Custom Trigger", 220, 26)
    del:SetPoint("TOP", p, "TOP", 0, y)
    del:SetScript("OnClick", function()
        StaticPopupDialogs["LEANC_DELETE_ITEM"] = {
            text = "Delete '" .. (item.name or itemID) .. "'?\n\nThis cannot be undone.",
            button1 = YES, button2 = NO,
            timeout = 0, whileDead = true, hideOnEscape = true,
            OnAccept = function()
                GetActiveItemStore()[itemID] = nil
                selectedID = nil
                if RefreshList then RefreshList() end
                ClearChildren(rightContent)
                RefreshAll()
            end,
        }
        StaticPopup_Show("LEANC_DELETE_ITEM")
    end)
    y = y - 32

    p:SetHeight(math.max(1, -y + PAD))
end

-- -------------------------------------------------- --
--  Editor dispatch                                   --
-- -------------------------------------------------- --

BuildEditor = function(item, itemID)
    if not rightContent then return end
    ClearChildren(rightContent)
    if not item then return end
    if item.type == "anchor" then
        BuildAnchorEditor(rightContent, item, itemID)
    elseif item.type == "customEvent" then
        BuildCustomEventEditor(rightContent, item, itemID)
    end
end

-- -------------------------------------------------- --
--  Left list (per-tab)                               --
-- -------------------------------------------------- --

local function GetTabItemType()
    return (currentTab == 1) and "anchor" or "customEvent"
end

-- Move an anchor item between profile (Character) and global (Global) stores.
-- Auto-switches the visible sub-tab to where the item landed so the user can
-- immediately see and edit it.
local function MoveAnchorBetweenScopes(itemID)
    if currentTab ~= 1 then return end  -- anchors only
    local srcStore = GetActiveItemStore()
    local item = srcStore[itemID]
    if not item then return end

    local moveToGlobal = (currentScope == "profile")
    local destStore = moveToGlobal and LEANC.db.global.items or LEANC.db.profile.items

    destStore[itemID] = item
    srcStore[itemID]  = nil

    -- Global anchors need a loadConditions table to be editable. Profile
    -- anchors don't need it but leaving it intact when moving back is fine.
    if moveToGlobal then item.loadConditions = item.loadConditions or {} end

    currentScope = moveToGlobal and "global" or "profile"
    if subTabBar then subTabBar:Activate(moveToGlobal and 2 or 1) end
    -- subTabBar:Activate fires its onSelect which clears selectedID and
    -- refreshes the list. Restore selection on the moved item so the editor
    -- opens directly on it in the new scope.
    selectedID = itemID
    RefreshList()
    BuildEditor(item, itemID)
    RefreshAll()
end

RefreshList = function()
    if not listContent then return end
    for _, r in ipairs(listRows) do r:Hide() end

    local typeKey = GetTabItemType()
    local items   = LEANC and LEANC.db and GetActiveItemStore() or {}
    local sorted  = {}
    for itemID, item in pairs(items) do
        if item.type == typeKey then
            sorted[#sorted + 1] = { itemID = itemID, item = item }
        end
    end
    table.sort(sorted, function(a, b) return (a.item.name or "") < (b.item.name or "") end)

    for i, rec in ipairs(sorted) do
        local row = listRows[i]
        if not row then
            row = CreateFrame("Button", nil, listContent, "BackdropTemplate")
            SetBD(row, C_PANEL, C_BDR); row:SetHeight(LIST_ROW_H)
            local txt = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
            txt:SetPoint("LEFT", 8, 0); txt:SetTextColor(unpack(C_TEXT))
            row.text = txt
            row:SetScript("OnEnter", function(s) if selectedID ~= s._itemID then s:SetBackdropColor(unpack(C_HOVER)) end end)
            row:SetScript("OnLeave", function(s) if selectedID ~= s._itemID then s:SetBackdropColor(unpack(C_PANEL)) end end)
            row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
            row:SetScript("OnClick", function(s, button)
                if button == "RightButton" then
                    -- Right-click context menu: only meaningful on Anchors tab
                    -- where there's a Character/Global distinction.
                    if currentTab ~= 1 then return end
                    local label = (currentScope == "profile")
                        and "Move to Global"
                        or  "Move to Character"
                    ShowContextMenu({
                        { label = label, func = function() MoveAnchorBetweenScopes(s._itemID) end },
                    })
                    return
                end
                -- New anchor selected → reset inner tab so user always lands
                -- on the main Anchor tab, not whichever tab was last viewed
                -- for a different anchor.
                if selectedID ~= s._itemID then anchorEditorInnerTab = 1 end
                selectedID = s._itemID
                RefreshList()
                local item = GetActiveItemStore()[s._itemID]
                if item then BuildEditor(item, s._itemID) end
            end)
            listRows[i] = row
        end
        row._itemID = rec.itemID
        row.text:SetText(rec.item.name or rec.itemID)
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT",  listContent, "TOPLEFT",  0, -(i - 1) * (LIST_ROW_H + 2))
        row:SetPoint("TOPRIGHT", listContent, "TOPRIGHT", 0, -(i - 1) * (LIST_ROW_H + 2))
        if selectedID == rec.itemID then row:SetBackdropColor(unpack(C_ROWACC))
        else row:SetBackdropColor(unpack(C_PANEL)) end
        row:Show()
    end
    listContent:SetHeight(math.max(1, #sorted * (LIST_ROW_H + 2)))
end

-- -------------------------------------------------- --
--  Frame layout                                      --
-- -------------------------------------------------- --

-- Forward decl so SwitchToTab can flip its visibility; the bar itself is
-- created inside BuildFrame below.
local subTabBar

local function SwitchToTab(idx)
    currentTab = idx
    selectedID = nil
    ClearChildren(rightContent)
    -- Sub-tabs (Character/Global) only apply to the Anchors top-level tab.
    if subTabBar then
        if currentTab == 1 then subTabBar:Show() else subTabBar:Hide() end
    end
    RefreshList()
end

local function BuildFrame()
    if frame then return frame end

    frame = CreateFrame("Frame", "LEAnchorsSettings", UIParent, "BackdropTemplate")
    SetBD(frame, C_BG, C_BDR)
    frame:SetSize(900, 620); frame:SetPoint("CENTER")
    frame:SetMovable(true);  frame:EnableMouse(true)
    frame:SetClampedToScreen(true)
    frame:SetFrameStrata("HIGH"); frame:Hide()

    -- Title bar
    local title = MakePanel(frame, C_PANEL, C_BDR)
    title:SetPoint("TOPLEFT"); title:SetPoint("TOPRIGHT")
    title:SetHeight(TITLE_H)
    title:EnableMouse(true); title:RegisterForDrag("LeftButton")
    title:SetScript("OnDragStart", function() frame:StartMoving() end)
    title:SetScript("OnDragStop",  function() frame:StopMovingOrSizing() end)
    local titleText = MakeLabel(title, "LEAnchors \194\183 Anchors + Custom Triggers", 14, C_ACCENT)
    titleText:SetPoint("LEFT", 10, 0)
    local close = MakeButton(title, "X", 24, 20)
    close:SetPoint("RIGHT", -4, 0)
    close:SetScript("OnClick", function() frame:Hide() end)

    -- Top tab bar (Anchors / Custom Triggers)
    local tabBar = MakeTabBar(frame, { "Anchors", "Custom Triggers" }, currentTab, function(idx) SwitchToTab(idx) end)
    tabBar:SetPoint("TOPLEFT",  0, -TITLE_H)
    tabBar:SetPoint("TOPRIGHT", 0, -TITLE_H)

    -- Anchor scope sub-tab bar (Character / Global). Shown only while the
    -- top-level Anchors tab is active. Toggling clears the current selection
    -- since each store has its own item set.
    subTabBar = MakeTabBar(frame, { "Character", "Global" },
        (currentScope == "global") and 2 or 1,
        function(idx)
            currentScope = (idx == 2) and "global" or "profile"
            selectedID = nil
            ClearChildren(rightContent)
            RefreshList()
        end)
    subTabBar:SetPoint("TOPLEFT",  0, -(TITLE_H + TAB_H))
    subTabBar:SetPoint("TOPRIGHT", 0, -(TITLE_H + TAB_H))
    if currentTab ~= 1 then subTabBar:Hide() end

    -- Left panel: list + Add button
    local left = MakePanel(frame, C_PANEL, C_BDR)
    left:SetPoint("TOPLEFT",    0, -(TITLE_H + TAB_H * 2))
    left:SetPoint("BOTTOMLEFT", 0, 0)
    left:SetWidth(LEFT_W)

    local addBtn = MakeAccentButton(left, "+ Add", LEFT_W - 16, 24)
    addBtn:SetPoint("TOP", 0, -PAD)
    addBtn:SetScript("OnClick", function()
        local id = ns.GenerateUID()
        local item
        if currentTab == 1 then item = NewAnchorDefaults()
        else                    item = NewCustomEventDefaults() end
        GetActiveItemStore()[id] = item
        selectedID = id
        anchorEditorInnerTab = 1  -- always open new anchor on the main tab
        RefreshList()
        BuildEditor(item, id)
        RefreshAll()
    end)

    local listScroll, listContent_ = MakeThemedScroll(left)
    listScroll:SetPoint("TOPLEFT",     PAD, -(PAD + 24 + 4))
    listScroll:SetPoint("BOTTOMRIGHT", -PAD, PAD)
    listContent = listContent_
    listContent:SetWidth(LEFT_W - PAD * 2 - 14)

    -- Right panel: editor area
    rightPanel = MakePanel(frame, C_PANEL, C_BDR)
    rightPanel:SetPoint("TOPLEFT",     LEFT_W, -(TITLE_H + TAB_H * 2))
    rightPanel:SetPoint("BOTTOMRIGHT", 0, 0)

    rightScroll, rightContent = MakeThemedScroll(rightPanel)
    rightScroll:SetPoint("TOPLEFT",     0, 0)
    rightScroll:SetPoint("BOTTOMRIGHT", -2, 0)
    rightContent:SetWidth(rightPanel:GetWidth() - 16)
    rightPanel:HookScript("OnSizeChanged", function() rightContent:SetWidth(rightPanel:GetWidth() - 16) end)

    frame:SetScript("OnShow", function()
        RefreshList()
        if selectedID and GetActiveItemStore()[selectedID] then
            BuildEditor(GetActiveItemStore()[selectedID], selectedID)
        end
    end)
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

-- -------------------------------------------------- --
--  /lea dump — state dump window                     --
-- -------------------------------------------------- --

-- Format an anchor-state snapshot (from ns.SnapshotAnchorState) as plain
-- text suitable for the dump window.
local function FormatSnapshot(snap)
    if not snap then return "(no snapshot available)" end
    local lines = {}
    local function add(s)         lines[#lines + 1] = s or "" end
    local function addf(fmt, ...) lines[#lines + 1] = string.format(fmt, ...) end

    addf("Time: %s  (t=%.2f)", snap.date or "?", snap.timestamp or 0)
    add("")

    add("Flags:")
    local fkeys = {}
    for k in pairs(snap.flags or {}) do fkeys[#fkeys + 1] = k end
    table.sort(fkeys)
    for _, k in ipairs(fkeys) do
        addf("  %-22s = %s", k, tostring(snap.flags[k]))
    end

    local pcount = 0
    for _ in pairs(snap.pendingFrames or {}) do pcount = pcount + 1 end
    addf("")
    addf("Pending Frames: (%d)", pcount)
    if pcount == 0 then add("  (none)") end
    for name, info in pairs(snap.pendingFrames or {}) do
        addf("  %s  (age=%.1fs)", name, info.ageSec or 0)
    end

    addf("")
    addf("Errored Frames: (%d)", #(snap.erroredFrames or {}))
    if #(snap.erroredFrames or {}) == 0 then add("  (none)") end
    for _, name in ipairs(snap.erroredFrames or {}) do addf("  %s", name) end

    local sp = (snap.hooked and snap.hooked.setPoint) or {}
    addf("")
    addf("Hooked SetPoint: (%d)", #sp)
    if #sp == 0 then add("  (none)") end
    for _, name in ipairs(sp) do addf("  %s", name) end

    local sc = (snap.hooked and snap.hooked.onSize) or {}
    addf("")
    addf("Hooked OnSizeChanged: (%d)", #sc)
    if #sc == 0 then add("  (none)") end
    for _, name in ipairs(sc) do addf("  %s", name) end

    local scount = 0
    for _ in pairs(snap.savedState or {}) do scount = scount + 1 end
    addf("")
    addf("Saved Frame State: (%d)", scount)
    if scount == 0 then add("  (none)") end
    for name, st in pairs(snap.savedState or {}) do
        addf("  %s:", name)
        addf("    parent = %s", tostring(st.parent))
        addf("    width  = %s", tostring(st.width))
        if st.points then
            for i, pt in ipairs(st.points) do
                local relTo = pt[2]
                local relName = (type(relTo) == "table" and relTo.GetName and relTo:GetName())
                              or tostring(relTo)
                addf("    point[%d] = %s @ %s::%s  (%.0f, %.0f)",
                    i, tostring(pt[1]), relName, tostring(pt[3]), pt[4] or 0, pt[5] or 0)
            end
        end
    end

    addf("")
    addf("Items: (%d)", #(snap.items or {}))
    if #(snap.items or {}) == 0 then add("  (none)") end
    for _, it in ipairs(snap.items or {}) do
        addf("  [%s] '%s'  (id=%s)", it.scope, it.name, it.itemID)
        addf("    enabled=%s shouldLoad=%s safeAnchor=%s",
            tostring(it.enabled), tostring(it.shouldLoad), tostring(it.safeAnchor))
        addf("    source=%s (exists=%s)  dest=%s (exists=%s)",
            tostring(it.sourceFrame), tostring(it.sourceExists),
            tostring(it.destFrame),   tostring(it.destExists))
        if it.sourceRect then
            addf("    sourceRect: left=%.0f bottom=%.0f w=%.0f h=%.0f",
                it.sourceRect.left, it.sourceRect.bottom,
                it.sourceRect.width, it.sourceRect.height)
        end
        if it.destRect then
            addf("    destRect:   left=%.0f bottom=%.0f w=%.0f h=%.0f",
                it.destRect.left, it.destRect.bottom,
                it.destRect.width, it.destRect.height)
        end
    end

    return table.concat(lines, "\n")
end

-- Lazy-built dump window. EditBox is selectable so Ctrl+A / Ctrl+C copy
-- the contents; ESC and the Close button hide it.
local dumpFrame
local function BuildDumpFrame()
    if dumpFrame then return dumpFrame end

    dumpFrame = CreateFrame("Frame", "LEANCDumpFrame", UIParent, "BackdropTemplate")
    SetBD(dumpFrame, C_BG, C_BDR)
    dumpFrame:SetSize(720, 540)
    dumpFrame:SetPoint("CENTER")
    dumpFrame:SetFrameStrata("FULLSCREEN_DIALOG")
    dumpFrame:SetFrameLevel(100)
    dumpFrame:EnableMouse(true)
    dumpFrame:SetMovable(true)
    dumpFrame:RegisterForDrag("LeftButton")
    dumpFrame:SetScript("OnDragStart", dumpFrame.StartMoving)
    dumpFrame:SetScript("OnDragStop",  dumpFrame.StopMovingOrSizing)
    dumpFrame:Hide()

    local title = MakeLabel(dumpFrame, "LEAnchors State Dump", 14, C_TEXT)
    title:SetPoint("TOP", 0, -10)

    local hint = MakeLabel(dumpFrame,
        "Click in the box, then Ctrl+A to select all, Ctrl+C to copy.",
        nil, C_DIM)
    hint:SetPoint("TOP", title, "BOTTOM", 0, -4)

    local holder = CreateFrame("Frame", nil, dumpFrame, "BackdropTemplate")
    SetBD(holder, C_PANEL, C_BDR)
    holder:SetPoint("TOPLEFT", 12, -48)
    holder:SetPoint("BOTTOMRIGHT", -12, 44)

    local scroll = CreateFrame("ScrollFrame", nil, holder, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 6, -6)
    scroll:SetPoint("BOTTOMRIGHT", -28, 6)

    local eb = CreateFrame("EditBox", nil, scroll)
    eb:SetMultiLine(true)
    eb:SetFontObject("ChatFontNormal")
    eb:SetWidth(holder:GetWidth() - 40)
    eb:SetAutoFocus(false)
    eb:SetTextColor(unpack(C_TEXT))
    eb:SetMaxLetters(0)
    eb:SetScript("OnEscapePressed", function() dumpFrame:Hide() end)
    scroll:SetScrollChild(eb)
    dumpFrame.editBox = eb

    holder:HookScript("OnSizeChanged", function(_, w)
        eb:SetWidth((w or holder:GetWidth()) - 40)
    end)

    local close = MakeButton(dumpFrame, "Close", 90, 26)
    close:SetPoint("BOTTOM", 0, 12)
    close:SetScript("OnClick", function() dumpFrame:Hide() end)

    return dumpFrame
end

function ns.ShowAnchorDump()
    local f = BuildDumpFrame()
    local live  = ns.SnapshotAnchorState and ns.SnapshotAnchorState()
    local saved = LEANC and LEANC._lastResetSnapshot
    local text  = "=== LIVE STATE ===\n\n" .. FormatSnapshot(live)
    if saved then
        text = text
            .. "\n\n\n=== PRE-RESET SNAPSHOT (most recent /lea reset) ===\n\n"
            .. FormatSnapshot(saved)
    end
    f.editBox:SetText(text)
    f.editBox:SetCursorPosition(0)
    f:Show()
end
