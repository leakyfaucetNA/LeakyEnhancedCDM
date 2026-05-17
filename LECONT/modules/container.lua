-- container.lua
-- Standalone aura containers using Blizzard's C_UnitAuras API.
-- Each container tracks a unit + filter and displays up to N aura icons via a
-- shared frame pool. All aura data is read through secret-safe APIs only:
--   C_UnitAuras.GetAuraDataByIndex                — index iteration, no compares
--   C_UnitAuras.GetAuraDispelTypeColor (curve)    — secret dispel type → plain color
--   C_UnitAuras.GetAuraDuration                   — cooldown duration object
--   C_UnitAuras.GetAuraApplicationDisplayCount    — stack count as display string
-- No reads of auraData.applications, .duration, .expirationTime as numbers.

local _, ns = ...

local pairs, ipairs, wipe = pairs, ipairs, wipe
local CreateFrame      = CreateFrame
local CreateFramePool  = CreateFramePool
local C_UnitAuras      = C_UnitAuras
local GetTime          = GetTime

local LSM = LibStub and LibStub("LibSharedMedia-3.0", true)

-- Resolve a font name (LSM key or fallback) to a path; never returns nil so
-- SetFont always succeeds even when LSM media isn't registered.
local function ResolveFontPath(name)
    if name and LSM then
        local p = LSM:Fetch("font", name)
        if p then return p end
    end
    return STANDARD_TEXT_FONT or "Fonts\\FRIZQT__.TTF"
end

-- All active containers keyed by itemID
local containers = {}
local pendingAnchors = {}  -- [itemID] = { frameName, selfPoint, anchorPoint, xOff, yOff }

-- Shared event frame for UNIT_AURA + UNIT_TARGET (target/focus changes)
local eventFrame = CreateFrame("Frame")
local trackedUnits = {}  -- [unit] = { [containerID] = true }

eventFrame:SetScript("OnEvent", function(_, event, unit)
    if event == "UNIT_TARGET" then
        if trackedUnits["target"] then
            for cID in pairs(trackedUnits["target"]) do
                local c = containers[cID]
                if c then c:Refresh() end
            end
        end
        if trackedUnits["focus"] then
            for cID in pairs(trackedUnits["focus"]) do
                local c = containers[cID]
                if c then c:Refresh() end
            end
        end
        return
    end

    -- UNIT_AURA
    if not trackedUnits[unit] then return end
    for cID in pairs(trackedUnits[unit]) do
        local c = containers[cID]
        if c then c:Refresh() end
    end
end)

-- -------------------------------------------------- --
--  Icon frame pool                                   --
-- -------------------------------------------------- --

local function IconResetter(_, frame)
    frame:Hide()
    frame:ClearAllPoints()
    if frame.icon     then frame.icon:SetTexture(nil) end
    if frame.cooldown then frame.cooldown:Clear() end
    if frame.count    then frame.count:SetText("") end
    if frame.border   then frame.border:Hide() end
    frame._auraInstanceID = nil
    frame._spellID = nil
end

local iconPool = CreateFramePool("Button", UIParent, "BackdropTemplate", IconResetter)

local BORDER_SOLID    = "SOLID"
local BORDER_BLIZZARD = "BLIZZARD"

-- Default dispel colors (used when no global override and no per-container
-- override are present). Keys are the integer dispel-type values used by the
-- secret-safe ColorCurve API; names match Blizzard's DEBUFF_DISPLAY_INFO
-- table (Magic/Curse/Disease/Poison/Bleed/None) from AuraUtil.lua.
ns.DEFAULT_DISPEL_COLORS = {
    [0] = {0.80, 0.00, 0.00, 1},  -- None / Enrage / unknown
    [1] = {0.20, 0.60, 1.00, 1},  -- Magic
    [2] = {0.60, 0.00, 1.00, 1},  -- Curse
    [3] = {0.60, 0.40, 0.00, 1},  -- Disease
    [4] = {0.00, 0.60, 0.00, 1},  -- Poison
    [5] = {1.00, 0.20, 0.20, 1},  -- Bleed
}

-- Atlas names per dispel type, mirroring Blizzard's DEBUFF_DISPLAY_INFO at
-- Blizzard_FrameXMLUtil/AuraUtil.lua. dispelAtlas variants include the small
-- dispel-type icon overlay; basicAtlas variants are just the colored border.
ns.DISPEL_ATLASES = {
    [0] = { basic = "ui-debuff-border-default-noicon", dispel = nil },
    [1] = { basic = "ui-debuff-border-magic-noicon",   dispel = "ui-debuff-border-magic-icon"   },
    [2] = { basic = "ui-debuff-border-curse-noicon",   dispel = "ui-debuff-border-curse-icon"   },
    [3] = { basic = "ui-debuff-border-disease-noicon", dispel = "ui-debuff-border-disease-icon" },
    [4] = { basic = "ui-debuff-border-poison-noicon",  dispel = "ui-debuff-border-poison-icon"  },
    [5] = { basic = "ui-debuff-border-bleed-noicon",   dispel = "ui-debuff-border-bleed-icon"   },
}

-- Resolve effective dispel colors for a container: per-container overrides win,
-- then global db.global.dispelColors, then DEFAULT_DISPEL_COLORS. Each call
-- returns a fresh table — caller can mutate without affecting source tables.
local function ResolveDispelColors(cData)
    local globals = (LECONT and LECONT.db and LECONT.db.global and LECONT.db.global.dispelColors) or {}
    local overrides = cData and cData.dispelColors or {}
    local out = {}
    for k, def in pairs(ns.DEFAULT_DISPEL_COLORS) do
        local c = overrides[k] or globals[k] or def
        out[k] = { c[1] or 1, c[2] or 1, c[3] or 1, c[4] or 1 }
    end
    return out
end
ns.ResolveDispelColors = ResolveDispelColors

-- Build a per-container ColorCurve from an integer→{r,g,b,a} table. Stored on
-- the container so we can rebuild on color-change without rebuilding all of
-- SetupContainers.
local function BuildDispelCurve(colors)
    if not (C_CurveUtil and C_CurveUtil.CreateColorCurve) then return nil end
    local curve = C_CurveUtil.CreateColorCurve()
    for k, c in pairs(colors) do
        curve:AddPoint(k, CreateColor(c[1] or 1, c[2] or 1, c[3] or 1, c[4] or 1))
    end
    return curve
end

-- Encode the dispel-type integer in the red channel of a ColorCurve. The
-- secret dispel-type value goes in, the curve laundering returns a plain
-- color whose red component IS the dispel type (0..5) — usable as a table
-- key for atlas lookup. Without this, we couldn't pick "magic atlas vs
-- bleed atlas" since auraData.dispelName is secret when non-nil.
local function BuildDispelIndexCurve()
    if not (C_CurveUtil and C_CurveUtil.CreateColorCurve) then return nil end
    local curve = C_CurveUtil.CreateColorCurve()
    for i = 0, 5 do
        -- Normalize to [0,1] so the curve doesn't clip. Decode via round(r*5).
        curve:AddPoint(i, CreateColor(i / 5, 0, 0, 1))
    end
    return curve
end

local function CreateEdge(f, sublevel)
    local t = f:CreateTexture(nil, "OVERLAY", nil, sublevel or 7)
    t:SetTexture("Interface\\BUTTONS\\WHITE8X8")
    t:Hide()
    return t
end

local function InitIconFrame(f)
    -- Dark background behind icon (visible through texcoord crop)
    local bg = f:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints(f)
    bg:SetColorTexture(0, 0, 0, 1)
    f.bg = bg

    -- Icon texture (inset 1px so border covers edges)
    local icon = f:CreateTexture(nil, "ARTWORK")
    icon:SetPoint("TOPLEFT",     f, "TOPLEFT",      1, -1)
    icon:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -1,  1)
    icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    f.icon = icon

    -- Cooldown spiral — matches icon inset
    local cd = CreateFrame("Cooldown", nil, f, "CooldownFrameTemplate")
    cd:SetAllPoints(f)
    cd:SetSwipeColor(0, 0, 0, 1)
    cd:SetDrawSwipe(true)
    cd:SetDrawBling(false)
    cd:SetEdgeColor(0, 0, 0, 1)
    cd:SetDrawEdge(false)
    cd:SetHideCountdownNumbers(false)
    cd:SetFrameLevel(f:GetFrameLevel() + 1)
    f.cooldown = cd

    -- Border overlay frame — sits above the cooldown so borders are always on top
    local borderFrame = CreateFrame("Frame", nil, f)
    borderFrame:SetAllPoints(f)
    borderFrame:SetFrameLevel(cd:GetFrameLevel() + 1)
    f.borderFrame = borderFrame

    -- Blizzard-style debuff border (hidden by default, shown for BLIZZARD style)
    local border = borderFrame:CreateTexture(nil, "OVERLAY")
    border:SetAllPoints()
    border:SetTexture("Interface\\Buttons\\UI-Debuff-Border")
    border:SetVertexColor(1, 1, 1, 1)
    border:Hide()
    f.border = border

    -- Solid border edges (one texture per side, sized to bd thickness)
    f.edgeTop    = CreateEdge(borderFrame)
    f.edgeBottom = CreateEdge(borderFrame)
    f.edgeLeft   = CreateEdge(borderFrame)
    f.edgeRight  = CreateEdge(borderFrame)

    -- Stack count (on border frame so it's above cooldown too)
    local count = borderFrame:CreateFontString(nil, "OVERLAY", "NumberFontNormal")
    count:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -2, 2)
    f.count = count
end

local function ApplyBorder(f, borderStyle, borderSize, r, g, b, a, atlas)
    borderSize = borderSize or 1
    r, g, b, a = r or 1, g or 1, b or 1, a or 1

    if borderStyle == BORDER_BLIZZARD then
        if atlas then
            f.border:SetAtlas(atlas)
        else
            f.border:SetTexture("Interface\\Buttons\\UI-Debuff-Border")
        end
        f.border:SetVertexColor(r, g, b, a)
        f.border:Show()
        f.edgeTop:Hide();    f.edgeBottom:Hide()
        f.edgeLeft:Hide();   f.edgeRight:Hide()
    else
        f.border:Hide()
        local bd = borderSize
        f.edgeTop:ClearAllPoints()
        f.edgeTop:SetPoint("TOPLEFT",  f, "TOPLEFT",  0, 0)
        f.edgeTop:SetPoint("TOPRIGHT", f, "TOPRIGHT", 0, 0)
        f.edgeTop:SetHeight(bd);    f.edgeTop:SetVertexColor(r, g, b, a);    f.edgeTop:Show()

        f.edgeBottom:ClearAllPoints()
        f.edgeBottom:SetPoint("BOTTOMLEFT",  f, "BOTTOMLEFT",  0, 0)
        f.edgeBottom:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", 0, 0)
        f.edgeBottom:SetHeight(bd); f.edgeBottom:SetVertexColor(r, g, b, a); f.edgeBottom:Show()

        f.edgeLeft:ClearAllPoints()
        f.edgeLeft:SetPoint("TOPLEFT",    f, "TOPLEFT",    0, 0)
        f.edgeLeft:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 0, 0)
        f.edgeLeft:SetWidth(bd);    f.edgeLeft:SetVertexColor(r, g, b, a);   f.edgeLeft:Show()

        f.edgeRight:ClearAllPoints()
        f.edgeRight:SetPoint("TOPRIGHT",    f, "TOPRIGHT",    0, 0)
        f.edgeRight:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", 0, 0)
        f.edgeRight:SetWidth(bd);   f.edgeRight:SetVertexColor(r, g, b, a);  f.edgeRight:Show()
    end
end

-- -------------------------------------------------- --
--  Container object                                  --
-- -------------------------------------------------- --

local ContainerMT = {}
ContainerMT.__index = ContainerMT

-- Compute (anchor, x, y, parentAnchor) for the i-th icon given grow + wrap.
local function GetIconPosition(idx, size, spacing, growDir, wrapAfter)
    local col = idx
    local row = 0
    if wrapAfter and wrapAfter > 0 then
        col = idx % wrapAfter
        row = math.floor(idx / wrapAfter)
    end
    local stride = size + spacing
    local primary   = col * stride
    local secondary = row * stride

    if growDir == "RIGHT" then
        return "TOPLEFT",  primary, -secondary, "CENTER"
    elseif growDir == "LEFT" then
        return "TOPRIGHT", -primary, -secondary, "CENTER"
    elseif growDir == "DOWN" then
        return "TOPLEFT",   secondary, -primary, "CENTER"
    elseif growDir == "UP" then
        return "BOTTOMLEFT", secondary, primary, "CENTER"
    end
    return "TOPLEFT", primary, -secondary, "CENTER"
end

-- Query auras through the secret-safe index API. Dual-query subtraction:
--   include filter → fetch by index → collect
--   for each exclude token → fetch with (include + exclude) → remove from set
-- Avoids any boolean tests on tainted aura fields.
function ContainerMT:QueryAuras()
    -- Blizzard's GetUnitAuras returns a pre-sorted array based on sortRule +
    -- sortDirection enums. We preserve that ordering through dual-query
    -- subtraction by keeping the original include-list array and gating each
    -- entry via a set we mutate during the subtract phase. This sort path is
    -- secret-safe: the engine does the comparison internally on secret
    -- values, returning ordered AuraData where we only read plain fields
    -- (icon, auraInstanceID, spellID) directly.
    local sortRule      = self.sortRule      or 0  -- Enum.UnitAuraSortRule.Unsorted
    local sortDirection = self.sortDirection or 0  -- Enum.UnitAuraSortDirection.Normal
    local hidePerm      = self.hidePermanent

    -- Permanent auras have duration == 0 (and/or expirationTime == 0).
    -- auraData.duration is plain — Blizzard's own UnitFrame compares it
    -- directly (CompactArenaFrame.lua:527, TargetFrame.lua:618). Defensive
    -- issecretvalue guard for forward-compat: if some future patch tightens
    -- this field we treat unknown duration as "keep" rather than dropping.
    local function isPermanent(data)
        local dur = data and data.duration
        if dur == nil then return true end  -- missing → treat as permanent
        if issecretvalue and issecretvalue(dur) then return false end
        return dur <= 0
    end

    local results, seen = {}, {}
    for _, plan in ipairs(self.queryPlans) do
        local list = C_UnitAuras.GetUnitAuras(self.unit, plan.apiFilter, self.maxAuras, sortRule, sortDirection) or {}

        local ordered, alive = {}, {}
        for _, data in ipairs(list) do
            if not seen[data.auraInstanceID]
               and (not hidePerm or not isPermanent(data)) then
                ordered[#ordered + 1] = data
                alive[data.auraInstanceID] = true
            end
        end

        if plan.subtractFilters and #plan.subtractFilters > 0 then
            for _, subFilter in ipairs(plan.subtractFilters) do
                local subList = C_UnitAuras.GetUnitAuras(self.unit, subFilter, nil, 0, 0) or {}
                for _, data in ipairs(subList) do
                    alive[data.auraInstanceID] = nil
                end
            end
        end

        for _, data in ipairs(ordered) do
            if alive[data.auraInstanceID] then
                seen[data.auraInstanceID] = true
                results[#results + 1] = data
            end
        end
    end
    return results
end

-- Render current aura state to icons.
function ContainerMT:Refresh()
    if self.previewing then return end
    if not self.frame:IsShown() then return end

    local auras   = (self.queryPlans and #self.queryPlans > 0) and self:QueryAuras() or {}
    local max     = self.maxAuras
    local size    = self.iconSize
    local spacing = self.spacing
    local growDir = self.growDirection
    local spiral  = self.showCooldownSpiral
    local count   = math.min(#auras, max)

    -- Reuse existing icons by auraInstanceID to avoid restarting cooldown spirals.
    local existingByAura = {}
    for idx, f in ipairs(self.activeIcons) do
        if f._auraInstanceID then
            existingByAura[f._auraInstanceID] = { frame = f, index = idx }
        end
    end
    local reusedSet = {}
    for i = 1, count do
        local existing = existingByAura[auras[i].auraInstanceID]
        if existing then reusedSet[existing.index] = true end
    end
    for idx, f in ipairs(self.activeIcons) do
        if not reusedSet[idx] then iconPool:Release(f) end
    end
    wipe(self.activeIcons)

    for i = 1, count do
        local aura = auras[i]
        local existing = existingByAura[aura.auraInstanceID]
        local f
        if existing then
            f = existing.frame
        else
            f = iconPool:Acquire()
            if not f.icon then InitIconFrame(f) end
        end

        f:SetParent(self.frame)
        f:SetSize(size, size)
        f:SetFrameLevel(self.frame:GetFrameLevel() + 1)

        local anchor, xo, yo, parentAnchor = GetIconPosition(i - 1, size, spacing, growDir, self.wrapAfter)
        f:ClearAllPoints()
        f:SetPoint(anchor, self.frame, parentAnchor, xo, yo)

        f.icon:SetTexture(aura.icon)
        local z = self.iconZoom
        f.icon:SetTexCoord(z, 1 - z, z, 1 - z)

        -- Border color: dispel-type tint when colorByDispel is on; else
        -- use the container's plain configured RGB.
        local br, bg, bb, ba = self.borderR or 0, self.borderG or 0, self.borderB or 0, 1
        if self.colorByDispel and self.dispelCurve and C_UnitAuras.GetAuraDispelTypeColor then
            local color = C_UnitAuras.GetAuraDispelTypeColor(self.unit, aura.auraInstanceID, self.dispelCurve)
            if color then br, bg, bb, ba = color:GetRGBA() end
        end
        -- Dispel-overlay atlas — picked via the secret-safe index curve so we
        -- can pull the right per-type texture without reading auraData.dispelName.
        local atlas
        if self.borderStyle == BORDER_BLIZZARD and self.dispelIndexCurve and C_UnitAuras.GetAuraDispelTypeColor then
            local idxColor = C_UnitAuras.GetAuraDispelTypeColor(self.unit, aura.auraInstanceID, self.dispelIndexCurve)
            if idxColor then
                -- ColorMixin exposes .r/.g/.b/.a; the red channel encodes our
                -- normalized dispel-type index. Decode via round(r * 5).
                local idx = math.floor(((idxColor.r) or 0) * 5 + 0.5)
                local atlasInfo = ns.DISPEL_ATLASES[idx]
                if atlasInfo then
                    atlas = self.showDispelIcon and atlasInfo.dispel or atlasInfo.basic
                end
            end
        end
        ApplyBorder(f, self.borderStyle, self.borderSize, br, bg, bb, ba, atlas)

        if spiral then
            f.cooldown:SetReverse(self.reverseSwipe)
            f.cooldown:SetSwipeColor(self.swipeR, self.swipeG, self.swipeB, self.swipeA)
            local dtEnabled = not (self.durationText and self.durationText.enabled == false)
            f.cooldown:SetHideCountdownNumbers(not dtEnabled)
            -- Per-container CooldownFont — created on demand from effective
            -- duration-text settings so font/size/color tweaks land live.
            if self.cooldownFontName and f.cooldown.SetCountdownFont then
                f.cooldown:SetCountdownFont(self.cooldownFontName)
            end
            -- Reposition the cooldown countdown FontString against the icon.
            -- GetCountdownFontString is a public Cooldown API; we anchor with
            -- matching points on both sides so "TOP" means text-top sits at
            -- icon-top.
            if f.cooldown.GetCountdownFontString and self.durationText then
                local cdFS = f.cooldown:GetCountdownFontString()
                if cdFS then
                    local pt = self.durationText.position or "CENTER"
                    cdFS:ClearAllPoints()
                    cdFS:SetPoint(pt, f, pt, self.durationText.x or 0, self.durationText.y or 0)
                end
            end
            if not existing then
                local duration = C_UnitAuras.GetAuraDuration(self.unit, aura.auraInstanceID)
                if duration then
                    f.cooldown:SetCooldownFromDurationObject(duration)
                    f.cooldown:Show()
                else
                    f.cooldown:Hide()
                end
            end
        else
            f.cooldown:Clear()
            f.cooldown:Hide()
        end

        -- Stack count text — secret-safe display string. Style + position from
        -- stackText config (font, size, color, on/off, position, x, y).
        local stcfg = self.stackText
        if stcfg and stcfg.enabled == false then
            f.count:SetText("")
        else
            if stcfg then
                f.count:SetFont(
                    ResolveFontPath(stcfg.font),
                    stcfg.fontSize or 12,
                    stcfg.fontOutline or "OUTLINE"
                )
                local c = stcfg.color or {1, 1, 1, 1}
                f.count:SetTextColor(c[1] or 1, c[2] or 1, c[3] or 1, c[4] or 1)
                local pt = stcfg.position or "BOTTOMRIGHT"
                f.count:ClearAllPoints()
                f.count:SetPoint(pt, f, pt, stcfg.x or -2, stcfg.y or 2)
            end
            f.count:SetText(C_UnitAuras.GetAuraApplicationDisplayCount(self.unit, aura.auraInstanceID))
        end

        f._auraInstanceID = aura.auraInstanceID
        f._spellID = aura.spellID
        f:SetAlpha(self.iconAlpha)
        f:Show()
        self.activeIcons[#self.activeIcons + 1] = f
    end
end

-- Preview with placeholder icons from the player's spellbook. Useful in the
-- settings UI to position/size a container without a live aura present.
function ContainerMT:Preview()
    for _, f in ipairs(self.activeIcons) do iconPool:Release(f) end
    wipe(self.activeIcons)

    local placeholders = {}
    local spellBank = Enum.SpellBookSpellBank and Enum.SpellBookSpellBank.Player
    if spellBank then
        local numLines = C_SpellBook.GetNumSpellBookSkillLines() or 0
        for t = 1, numLines do
            if #placeholders >= self.maxAuras then break end
            local lineInfo = C_SpellBook.GetSpellBookSkillLineInfo(t)
            if lineInfo then
                local offset, n = lineInfo.itemIndexOffset, lineInfo.numSpellBookItems
                for j = offset + 1, offset + n do
                    if #placeholders >= self.maxAuras then break end
                    local info = C_SpellBook.GetSpellBookItemInfo(j, spellBank)
                    if info and info.spellID and info.iconID and not info.isPassive then
                        placeholders[#placeholders + 1] = {
                            icon = info.iconID,
                            duration = 10 + #placeholders * 5,
                            applications = (#placeholders % 3 == 0) and (#placeholders + 1) or 0,
                        }
                    end
                end
            end
        end
    end

    self.frame:Show()
    local size, spacing, growDir, spiral = self.iconSize, self.spacing, self.growDirection, self.showCooldownSpiral
    local now = GetTime()
    local cnt = math.min(#placeholders, self.maxAuras)
    for i = 1, cnt do
        local p = placeholders[i]
        local f = iconPool:Acquire()
        if not f.icon then InitIconFrame(f) end
        f:SetParent(self.frame); f:SetSize(size, size)
        f:SetFrameLevel(self.frame:GetFrameLevel() + 1)
        local anchor, xo, yo, parentAnchor = GetIconPosition(i - 1, size, spacing, growDir, self.wrapAfter)
        f:ClearAllPoints(); f:SetPoint(anchor, self.frame, parentAnchor, xo, yo)
        f.icon:SetTexture(p.icon)
        local z = self.iconZoom
        f.icon:SetTexCoord(z, 1 - z, z, 1 - z)
        -- Preview borders: cycle dispel types across placeholder icons so the
        -- user can see all configured dispel colors at once. i is 1-based.
        -- Magic→Curse→Disease→Poison→Bleed→None then repeat.
        local PREVIEW_DISPEL_CYCLE = { 1, 2, 3, 4, 5, 0 }
        local dispelIdx = PREVIEW_DISPEL_CYCLE[((i - 1) % #PREVIEW_DISPEL_CYCLE) + 1]
        local pr, pg, pb, pa = self.borderR or 0, self.borderG or 0, self.borderB or 0, 1
        if self.colorByDispel then
            local dispelDefaults = self.effectiveDispelColors or ns.DEFAULT_DISPEL_COLORS
            local mc = dispelDefaults[dispelIdx] or dispelDefaults[0]
            if mc then pr, pg, pb, pa = mc[1] or pr, mc[2] or pg, mc[3] or pb, mc[4] or pa end
        end
        local previewAtlas
        if self.borderStyle == BORDER_BLIZZARD then
            local atlasInfo = ns.DISPEL_ATLASES[dispelIdx]
            if atlasInfo then
                previewAtlas = self.showDispelIcon and atlasInfo.dispel or atlasInfo.basic
            end
        end
        ApplyBorder(f, self.borderStyle, self.borderSize, pr, pg, pb, pa, previewAtlas)
        if spiral and p.duration > 0 then
            f.cooldown:SetReverse(self.reverseSwipe)
            f.cooldown:SetSwipeColor(self.swipeR, self.swipeG, self.swipeB, self.swipeA)
            local dtEnabled = not (self.durationText and self.durationText.enabled == false)
            f.cooldown:SetHideCountdownNumbers(not dtEnabled)
            if self.cooldownFontName and f.cooldown.SetCountdownFont then
                f.cooldown:SetCountdownFont(self.cooldownFontName)
            end
            if f.cooldown.GetCountdownFontString and self.durationText then
                local cdFS = f.cooldown:GetCountdownFontString()
                if cdFS then
                    local pt = self.durationText.position or "CENTER"
                    cdFS:ClearAllPoints()
                    cdFS:SetPoint(pt, f, pt, self.durationText.x or 0, self.durationText.y or 0)
                end
            end
            f.cooldown:SetCooldown(now, p.duration)
            f.cooldown:Show()
        else
            f.cooldown:Clear(); f.cooldown:Hide()
        end
        local stcfg = self.stackText
        if stcfg and stcfg.enabled == false then
            f.count:SetText("")
        else
            if stcfg then
                f.count:SetFont(
                    ResolveFontPath(stcfg.font),
                    stcfg.fontSize or 12,
                    stcfg.fontOutline or "OUTLINE"
                )
                local c = stcfg.color or {1, 1, 1, 1}
                f.count:SetTextColor(c[1] or 1, c[2] or 1, c[3] or 1, c[4] or 1)
                local pt = stcfg.position or "BOTTOMRIGHT"
                f.count:ClearAllPoints()
                f.count:SetPoint(pt, f, pt, stcfg.x or -2, stcfg.y or 2)
            end
            f.count:SetText(p.applications > 1 and p.applications or "")
        end
        f:SetAlpha(self.iconAlpha)
        f:Show()
        self.activeIcons[#self.activeIcons + 1] = f
    end
    self.previewing = true
    self:ShowPreviewDecoration()
end

-- Build (lazily) the preview decoration: a thin border around the placeholder
-- icons plus a name label above. Parented to UIParent so it draws above the
-- normal container strata.
local PREVIEW_PAD = 3
local function EnsurePreviewDecoration(self)
    if self._previewBorder then return end

    local b = CreateFrame("Frame", nil, UIParent, "BackdropTemplate")
    b:SetFrameStrata("TOOLTIP")
    b:SetBackdrop({
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = 1,
    })
    b:SetBackdropBorderColor(0.45, 0.45, 0.95, 1)  -- accent
    b:Hide()
    self._previewBorder = b

    local label = b:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    label:SetPoint("BOTTOM", b, "TOP", 0, 2)
    label:SetTextColor(0.45, 0.45, 0.95, 1)
    label:SetText(self.name or self.id or "")
    self._previewLabel = label
end

-- Position the decoration around the actual on-screen bounding box of the
-- placeholder icons. Uses Get{Left,Right,Top,Bottom} which return UIParent-
-- relative pixel coordinates regardless of grow direction or wrap mode, so
-- one routine covers every layout.
function ContainerMT:ShowPreviewDecoration()
    if #self.activeIcons == 0 then return end
    EnsurePreviewDecoration(self)
    local first = self.activeIcons[1]

    -- If the layout pass hasn't flushed yet (icons just Show()n), GetLeft is
    -- nil. Defer one frame and retry — by then coords are valid.
    if not first:GetLeft() then
        C_Timer.After(0, function()
            if self.previewing then self:ShowPreviewDecoration() end
        end)
        return
    end

    local minX, maxX = first:GetLeft(), first:GetRight()
    local minY, maxY = first:GetBottom(), first:GetTop()
    for i = 2, #self.activeIcons do
        local f = self.activeIcons[i]
        local l, r, bot, t = f:GetLeft(), f:GetRight(), f:GetBottom(), f:GetTop()
        if l and r and bot and t then
            if l   < minX then minX = l   end
            if r   > maxX then maxX = r   end
            if bot < minY then minY = bot end
            if t   > maxY then maxY = t   end
        end
    end

    local b = self._previewBorder
    b:ClearAllPoints()
    b:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", minX - PREVIEW_PAD, minY - PREVIEW_PAD)
    b:SetPoint("TOPRIGHT",   UIParent, "BOTTOMLEFT", maxX + PREVIEW_PAD, maxY + PREVIEW_PAD)
    self._previewLabel:SetText(self.name or self.id or "")
    b:Show()
end

function ContainerMT:HidePreviewDecoration()
    if self._previewBorder then self._previewBorder:Hide() end
end

function ContainerMT:StopPreview()
    self.previewing = false
    self:HidePreviewDecoration()
    self:Refresh()
end

-- Rebuild eventFrame subscriptions for the current trackedUnits set. We use
-- global UNIT_AURA when any non-player unit is tracked because RegisterUnitEvent
-- doesn't fire reliably for transient units like "target" / "focus".
local function RebuildEventRegistrations()
    eventFrame:UnregisterAllEvents()
    local hasNonPlayer = false
    for unit in pairs(trackedUnits) do
        if unit ~= "player" then hasNonPlayer = true; break end
    end
    if hasNonPlayer then
        eventFrame:RegisterEvent("UNIT_AURA")
        eventFrame:RegisterUnitEvent("UNIT_TARGET", "player")
    else
        for unit in pairs(trackedUnits) do
            eventFrame:RegisterUnitEvent("UNIT_AURA", unit)
        end
    end
end

function ContainerMT:Enable()
    trackedUnits[self.unit] = trackedUnits[self.unit] or {}
    trackedUnits[self.unit][self.id] = true
    RebuildEventRegistrations()
    self.frame:Show()
    self:Refresh()
end

function ContainerMT:Disable()
    self.frame:Hide()
    for _, f in ipairs(self.activeIcons) do iconPool:Release(f) end
    wipe(self.activeIcons)
    self:HidePreviewDecoration()
    if trackedUnits[self.unit] then
        trackedUnits[self.unit][self.id] = nil
        if not next(trackedUnits[self.unit]) then
            trackedUnits[self.unit] = nil
        end
        RebuildEventRegistrations()
    end
end

function ContainerMT:Destroy()
    self:Disable()
    if self._previewBorder then self._previewBorder:Hide() end
    self.frame:Hide()
    self.frame:SetParent(nil)
    containers[self.id] = nil
end

-- -------------------------------------------------- --
--  Public API                                        --
-- -------------------------------------------------- --

-- config keys (all optional except id):
--   id, name, unit, filterGroups | filter (legacy string),
--   maxAuras, iconSize, spacing, growDirection, wrapAfter,
--   showCooldownSpiral, reverseSwipe, swipeR/G/B/A,
--   borderStyle ("SOLID"|"BLIZZARD"), borderSize, borderR/G/B,
--   iconAlpha, iconZoom
function ns.CreateContainer(config)
    if not config or not config.id then return end
    if containers[config.id] then
        ns.lpmsg("Container '" .. tostring(config.id) .. "' already exists", "DEBUG")
        return containers[config.id]
    end

    local id      = config.id
    local size    = config.iconSize or 32
    local maxA    = config.maxAuras or 8
    local spacing = config.spacing  or 2
    local growDir = config.growDirection or "RIGHT"

    local frameName = "LECONTContainer_" .. tostring(id)
    local frame = _G[frameName] or CreateFrame("Frame", frameName, UIParent)
    frame:SetParent(UIParent)
    frame:SetSize(1, 1)
    frame:ClearAllPoints()
    frame:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    frame:Hide()

    -- Build query plans from filterGroups. Legacy fallback: pipe-delimited
    -- filter string becomes a single include-only group.
    local filterGroups = config.filterGroups
    if not filterGroups then
        local filterStr = config.filter or "HELPFUL"
        local tokens = {}
        for token in filterStr:gmatch("[^|]+") do tokens[token] = "include" end
        filterGroups = { { tokens = tokens } }
    end

    local queryPlans, isHarmful = {}, false
    for _, group in ipairs(filterGroups) do
        local include, exclude = {}, {}
        for token, state in pairs(group.tokens) do
            if state == "include" then
                include[#include + 1] = token
                if token == "HARMFUL" then isHarmful = true end
            elseif state == "exclude" then
                exclude[#exclude + 1] = token
            end
        end
        if #include > 0 then
            table.sort(include)
            local apiFilter = table.concat(include, "|")
            local subtractFilters = {}
            for _, exToken in ipairs(exclude) do
                local sub = {}
                for _, inc in ipairs(include) do sub[#sub + 1] = inc end
                sub[#sub + 1] = exToken
                table.sort(sub)
                subtractFilters[#subtractFilters + 1] = table.concat(sub, "|")
            end
            queryPlans[#queryPlans + 1] = { apiFilter = apiFilter, subtractFilters = subtractFilters }
        end
    end
    if #queryPlans == 0 then
        queryPlans[1] = { apiFilter = "HELPFUL", subtractFilters = {} }
    end

    -- Effective dispel colors and curves. Per-container overrides win over
    -- global db.global.dispelColors, which wins over module defaults. Curves
    -- are rebuilt whenever this container is recreated (every SetupContainers
    -- cycle), so editing colors reflects automatically.
    local effectiveDispelColors = ResolveDispelColors(config)
    local dispelCurve_local     = BuildDispelCurve(effectiveDispelColors)
    local dispelIndexCurve      = BuildDispelIndexCurve()

    -- colorByDispel: explicit toggle; default true for HARMFUL (matches
    -- Blizzard's default debuff appearance), else false.
    local colorByDispel = config.colorByDispel
    if colorByDispel == nil then colorByDispel = isHarmful end

    -- Resolve effective duration-text style (global → container override).
    local function effectiveDuration()
        local g = (LECONT and LECONT.db and LECONT.db.global and LECONT.db.global.durationText) or {}
        local o = config.durationText or {}
        if o.override then
            return {
                enabled     = o.enabled ~= false,
                font        = o.font        or g.font,
                fontSize    = o.fontSize    or g.fontSize    or 14,
                fontOutline = o.fontOutline or g.fontOutline or "OUTLINE",
                color       = o.color       or g.color       or {1, 1, 1, 1},
                position    = o.position    or g.position    or "CENTER",
                x           = o.x           or g.x           or 0,
                y           = o.y           or g.y           or 0,
            }
        end
        return {
            enabled     = o.enabled ~= false,  -- on/off always per-container
            font        = g.font,
            fontSize    = g.fontSize    or 14,
            fontOutline = g.fontOutline or "OUTLINE",
            color       = g.color       or {1, 1, 1, 1},
            position    = g.position    or "CENTER",
            x           = g.x           or 0,
            y           = g.y           or 0,
        }
    end
    local effectiveDur = effectiveDuration()

    -- Per-container CooldownFont: a FontObject we own, configured per the
    -- effective duration-text settings. CreateFont returns the existing global
    -- if it already exists, so this is safe to re-run across rebuilds.
    local cooldownFontName = "LECONTCdFont_" .. tostring(id)
    local cooldownFont = _G[cooldownFontName] or CreateFont(cooldownFontName)
    cooldownFont:SetFont(
        ResolveFontPath(effectiveDur.font),
        effectiveDur.fontSize,
        effectiveDur.fontOutline
    )
    local cc = effectiveDur.color
    cooldownFont:SetTextColor(cc[1] or 1, cc[2] or 1, cc[3] or 1, cc[4] or 1)

    -- Stack-text effective config (global → container override). Same pattern.
    local function effectiveStack()
        local g = (LECONT and LECONT.db and LECONT.db.global and LECONT.db.global.stackText) or {}
        local o = config.stackText or {}
        if o.override then
            return {
                enabled     = o.enabled ~= false,
                font        = o.font        or g.font,
                fontSize    = o.fontSize    or g.fontSize    or 12,
                fontOutline = o.fontOutline or g.fontOutline or "OUTLINE",
                color       = o.color       or g.color       or {1, 1, 1, 1},
                position    = o.position    or g.position    or "BOTTOMRIGHT",
                x           = o.x           or g.x           or -2,
                y           = o.y           or g.y           or 2,
            }
        end
        return {
            enabled     = (o.enabled ~= false),
            font        = g.font,
            fontSize    = g.fontSize    or 12,
            fontOutline = g.fontOutline or "OUTLINE",
            color       = g.color       or {1, 1, 1, 1},
            position    = g.position    or "BOTTOMRIGHT",
            x           = g.x           or -2,
            y           = g.y           or 2,
        }
    end

    local c = setmetatable({
        id                   = id,
        name                 = config.name or id,
        frame                = frame,
        unit                 = config.unit or "player",
        queryPlans           = queryPlans,
        maxAuras             = maxA,
        iconSize             = size,
        spacing              = spacing,
        growDirection        = growDir,
        showCooldownSpiral   = config.showCooldownSpiral ~= false,
        borderStyle          = config.borderStyle or BORDER_SOLID,
        borderSize           = config.borderSize or 1,
        wrapAfter            = config.wrapAfter or 0,
        reverseSwipe         = config.reverseSwipe or false,
        swipeR               = config.swipeR or 0,
        swipeG               = config.swipeG or 0,
        swipeB               = config.swipeB or 0,
        swipeA               = config.swipeA or 0.8,
        iconAlpha            = config.iconAlpha or 1,
        iconZoom             = 0.08 * (1 + (config.iconZoom or 0)),
        borderR              = config.borderR or 0,
        borderG              = config.borderG or 0,
        borderB              = config.borderB or 0,
        colorByDispel        = colorByDispel,
        showDispelIcon       = config.showDispelIcon ~= false,  -- with-icon atlas variant
        -- Sort: Blizzard sorts auras internally via secret comparisons and
        -- returns plain ordered AuraData. Rule fixed to Expiration; user
        -- controls only direction (Normal = soonest first, Reverse = longest).
        sortRule             = (Enum and Enum.UnitAuraSortRule and Enum.UnitAuraSortRule.Expiration) or 3,
        sortDirection        = config.sortDirection or 0,  -- Enum.UnitAuraSortDirection.Normal
        hidePermanent        = config.hidePermanent and true or false,
        dispelCurve          = dispelCurve_local,
        dispelIndexCurve     = dispelIndexCurve,
        effectiveDispelColors = effectiveDispelColors,
        stackText            = effectiveStack(),
        durationText         = effectiveDur,
        cooldownFontName     = cooldownFontName,
        _isHarmfulFilter     = isHarmful,
        activeIcons          = {},
    }, ContainerMT)

    containers[id] = c
    return c
end

function ns.GetContainer(id) return containers[id] end

function ns.DestroyContainer(id)
    local c = containers[id]
    if c then c:Destroy() end
end

function ns.DestroyAllContainers()
    for _, c in pairs(containers) do c:Destroy() end
    wipe(containers)
end

-- Rebuild all containers from the saved config. Preserves preview state per
-- itemID so editor-open previews survive a RefreshAll cycle.
function ns.SetupContainers(addon)
    local wasPreviewing = {}
    for cID, c in pairs(containers) do
        if c.previewing then wasPreviewing[cID] = true end
    end

    for _, c in pairs(containers) do
        c.previewing = false
        c:Disable()
    end
    wipe(containers)

    local dbItems = addon.db.profile.items
    if not dbItems then return end

    for itemID, cData in pairs(dbItems) do
        if cData.type == "container" and cData.enabled ~= false and ns.ShouldLoadItem(addon.db, itemID) then
            local c = ns.CreateContainer({
                id                  = itemID,
                name                = cData.name or itemID,
                unit                = cData.unit or "player",
                filterGroups        = cData.filterGroups,
                filter              = cData.filter or "HELPFUL",
                maxAuras            = cData.maxAuras or 8,
                iconSize            = cData.iconSize or 32,
                spacing             = cData.spacing or 2,
                growDirection       = cData.growDirection or "RIGHT",
                showCooldownSpiral  = cData.showCooldownSpiral ~= false,
                borderStyle         = cData.borderStyle or BORDER_SOLID,
                borderSize          = cData.borderSize or 1,
                wrapAfter           = cData.wrapAfter or 0,
                reverseSwipe        = cData.reverseSwipe or false,
                swipeR              = cData.swipeR, swipeG = cData.swipeG,
                swipeB              = cData.swipeB, swipeA = cData.swipeA,
                iconAlpha           = cData.iconAlpha,
                iconZoom            = cData.iconZoom,
                borderR             = cData.borderR, borderG = cData.borderG, borderB = cData.borderB,
                colorByDispel       = cData.colorByDispel,
                showDispelIcon      = cData.showDispelIcon,  -- atlas variant w/ dispel-icon overlay
                sortDirection       = cData.sortDirection,
                hidePermanent       = cData.hidePermanent,
                dispelColors        = cData.dispelColors,    -- per-container override
                stackText           = cData.stackText,       -- { override, enabled, font, fontSize, fontOutline, color }
                durationText        = cData.durationText,    -- { override, enabled, font, fontSize, fontOutline, color }
            })
            if c then
                local anchorName  = cData.anchorFrame or "UIParent"
                local anchorFrame = ns.SafeGetFrame(anchorName)
                local selfPoint   = cData.selfPoint or "CENTER"
                local anchorPoint = cData.anchorPoint or "CENTER"
                c.frame:ClearAllPoints()
                c.frame:SetPoint(selfPoint, anchorFrame or UIParent, anchorPoint, cData.xOffset or 0, cData.yOffset or 0)
                c.frame:SetFrameStrata(cData.strata or "MEDIUM")
                c:Enable()

                if not anchorFrame and anchorName ~= "UIParent" then
                    pendingAnchors[itemID] = {
                        frameName   = anchorName,
                        selfPoint   = selfPoint,
                        anchorPoint = anchorPoint,
                        xOff        = cData.xOffset or 0,
                        yOff        = cData.yOffset or 0,
                    }
                end

                if wasPreviewing[itemID] then c:Preview() end
            end
        end
    end

    -- Retry pending anchors (target addon may load after us)
    if next(pendingAnchors) then
        local retries, maxRetries = 0, 5
        local function RetryPending()
            retries = retries + 1
            for itemID, info in pairs(pendingAnchors) do
                local resolved = ns.SafeGetFrame(info.frameName)
                if resolved then
                    local c = containers[itemID]
                    if c then
                        c.frame:ClearAllPoints()
                        c.frame:SetPoint(info.selfPoint, resolved, info.anchorPoint, info.xOff, info.yOff)
                        ns.lpmsg("Anchored container to " .. info.frameName .. " (retry " .. retries .. ")", "DEBUG")
                    end
                    pendingAnchors[itemID] = nil
                end
            end
            if next(pendingAnchors) and retries < maxRetries then
                C_Timer.After(1, RetryPending)
            elseif next(pendingAnchors) then
                for _, info in pairs(pendingAnchors) do
                    ns.lpmsg("Could not resolve anchor frame: " .. info.frameName, "DEBUG")
                end
                wipe(pendingAnchors)
            end
        end
        C_Timer.After(1, RetryPending)
    end

    ns.lpmsg("Lifecycle: SetupContainers done", "DEBUG")
end

function ns.StopAllContainerPreviews()
    for _, c in pairs(containers) do
        if c.previewing then c:StopPreview() end
    end
end

-- Activate previews on every currently-loaded container so the settings UI
-- can show all enabled containers at once (with border + name decoration).
-- Used by the settings frame's OnShow.
function ns.PreviewAllContainers()
    for _, c in pairs(containers) do
        c:Preview()
    end
end

ns.containers = containers
