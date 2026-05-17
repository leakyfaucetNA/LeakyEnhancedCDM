-- bars.lua
-- Aura-only duration progress bars.
--
-- Per-bar config (item.bars[uid]):
--   enabled, name
--   Bar:        width, height, barTexture, barColor
--   Background: bgTexture, bgColor
--   Border:     borderThickness, borderColor
--   Anchor:     point, relativePoint, anchorFrame, anchorCustom, x, y, strata
--   Expiring:   expireAt (seconds), barExpiringColor
--   Texts:      nameText = { enabled, font, fontSize, fontOutline, color,
--                            useExpiringColor, expiringColor }
--               durText  = same shape
--
-- One container per (spellID, itemID, uid). OnUpdate drives bar:SetValue and
-- duration-text formatting. expiringColor cuts in when remaining < expireAt.

local _, ns = ...

local LSM = LibStub("LibSharedMedia-3.0")

-- [spellID] = { [itemID] = item }
local barItemLookup = {}

-- [stateKey] = { container, bar, bgTex, nameFS, durFS, _exp, _dur, _bc, _key, _expiringActive }
-- stateKey = spellID .. "_" .. itemID .. "_" .. uid
local barFrames = {}

local STRATA_VALUES = {
    BACKGROUND = true, LOW = true, MEDIUM = true, HIGH = true,
    DIALOG = true, FULLSCREEN = true, FULLSCREEN_DIALOG = true, TOOLTIP = true,
}

-- Default font/texture fallbacks — match texts.lua's robustness fix so size
-- and face edits always apply even when no LSM media is registered.
local function ResolveFont(name)
    if name and LSM then
        local p = LSM:Fetch("font", name)
        if p then return p end
    end
    return STANDARD_TEXT_FONT or "Fonts\\FRIZQT__.TTF"
end

local function ResolveStatusBar(name)
    if name and LSM then
        local p = LSM:Fetch("statusbar", name)
        if p then return p end
    end
    return "Interface\\TargetingFrame\\UI-StatusBar"
end

local function ResolveBackground(name)
    if name and LSM then
        local p = LSM:Fetch("background", name) or LSM:Fetch("statusbar", name)
        if p then return p end
    end
    return "Interface\\Buttons\\WHITE8x8"
end

-- Mirrors texts.lua: number key → CDM frame; string → global or UIParent.
local function ResolveAnchor(key)
    if not key or key == "" then return UIParent end
    if type(key) == "number" then
        local entry
        for _, map in ipairs({ ns.auraFrameMap or {}, ns.cdFrameMap or {} }) do
            for _, e in pairs(map) do
                if e._lecSpellID == key or e._lecOverrideID == key then
                    entry = e; break
                end
            end
            if entry then break end
        end
        if entry and entry.frame then return entry.frame end
        return UIParent
    end
    local g = _G[key]
    if g then return g end
    return UIParent
end

-- -------------------------------------------------- --
--  Frame Construction                                --
-- -------------------------------------------------- --

local function MakeFontText(parent)
    -- Use a known FontObject template so the FontString starts with a valid
    -- font even before EnsureBarFrame's SetFont call lands. Without a template,
    -- any SetText call on a FontString that hasn't had SetFont yet throws
    -- "FontString:SetText(): Font not set".
    local fs = parent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    fs:SetDrawLayer("OVERLAY", 7)
    return fs
end

local function ApplyTextConfig(fs, tcfg, defaultText, isExpiring)
    -- Always set the font first — even when disabled — so any subsequent
    -- SetText call (e.g. SetText("") in RenderBar's disabled branch) succeeds.
    local fontPath = ResolveFont(tcfg and tcfg.font)
    local fontSize = (tcfg and tcfg.fontSize) or 12
    local outline  = (tcfg and tcfg.fontOutline) or "OUTLINE"
    fs:SetFont(fontPath, fontSize, outline)

    if not tcfg or tcfg.enabled == false then
        fs:Hide()
        return
    end
    fs:Show()
    local c
    if isExpiring and tcfg.useExpiringColor and tcfg.expiringColor then
        c = tcfg.expiringColor
    else
        c = tcfg.color or {1, 1, 1, 1}
    end
    fs:SetTextColor(c[1] or 1, c[2] or 1, c[3] or 1, c[4] or 1)
    if defaultText then fs:SetText(defaultText) end
end

local function FormatDuration(remaining, decimals)
    if remaining <= 0 then return "" end
    if remaining >= 60 then
        return string.format("%d:%02d", math.floor(remaining / 60), math.floor(remaining % 60))
    end
    local d = tonumber(decimals)
    if not d or d < 0 then d = 1 end
    if d <= 0 then
        return string.format("%d", math.floor(remaining))
    elseif d == 1 then
        return string.format("%.1f", remaining)
    else
        return string.format("%.2f", remaining)
    end
end

-- Bars are exposed as named global frames so other addons / WeakAuras can
-- anchor to them. Name derivation, in order:
--   1. bc.frameName, if already cached on the config (stable forever).
--   2. Otherwise: "LECDMBar_" + sanitized bc.name, then suffix _2/_3/...
--      if that global is already taken. Result is cached back on bc.frameName.
--
-- Renaming the bar after first creation does NOT update the frame's global
-- name — frames can't be renamed in WoW and silently changing the name would
-- break any anchors the user has wired up. To rename the frame, edit
-- bc.frameName directly or delete & recreate the bar.
local function SanitizeFrameSegment(name)
    if not name or name == "" then return "Bar" end
    local clean = name:gsub("%s+", ""):gsub("[^%w_]", "")
    if clean == "" then clean = "Bar" end
    if clean:match("^%d") then clean = "Bar" .. clean end
    return clean
end

local function ResolveBarFrameName(bc)
    if bc.frameName and bc.frameName ~= "" then return bc.frameName end
    local base = "LECDMBar_" .. SanitizeFrameSegment(bc.name or "Aura Bar")
    local candidate, i = base, 2
    while _G[candidate] do
        candidate = base .. "_" .. i
        i = i + 1
    end
    bc.frameName = candidate
    return candidate
end
ns.ResolveBarFrameName = ResolveBarFrameName

-- -------------------------------------------------- --
--  Match Width: live target tracking + retry         --
-- -------------------------------------------------- --
--
-- The target frame may not be sized (or may not exist yet) when EnsureBarFrame
-- runs — anchor addons can register frames after we do, and frames don't
-- always have a final size until a layout pass completes. Strategy:
--
--   1. Try to apply immediately. If the target exists with a positive width,
--      we're done for now and we register an OnSizeChanged hook so later
--      resizes flow through to the bar.
--   2. If the target is missing or zero-width, fall back to bc.width and
--      retry on a timer (1s × 10 attempts). Once we get a hit we register the
--      hook and stop retrying.
--
-- HookScript is additive, so changing matchWidthFrame in settings can leave
-- stale hooks on the previous target — but the hook callback always reads
-- bc fresh, so the stale call just re-applies the current configuration.
-- _lecMatchHookedTargets dedupes per-container so we don't stack hooks across
-- repeated SetupBars cycles.
local ApplyMatchWidth  -- forward decl so the helpers can call it

local function GetMatchWidthTarget(bc)
    if not bc.matchWidth then return nil end
    if bc.matchWidthMode == "custom" and bc.matchWidthFrame and bc.matchWidthFrame ~= "" then
        return _G[bc.matchWidthFrame]
    end
    return ResolveAnchor(bc.anchorFrame)
end

local function HookMatchWidthTarget(container, bc, target)
    if not target or not target.HookScript then return end
    container._lecMatchHookedTargets = container._lecMatchHookedTargets or {}
    if container._lecMatchHookedTargets[target] then return end
    container._lecMatchHookedTargets[target] = true
    target:HookScript("OnSizeChanged", function()
        ApplyMatchWidth(container, bc)
    end)
end

local function ScheduleMatchWidthRetry(container, bc, attempts)
    if attempts <= 0 then return end
    container._lecMatchRetryPending = (container._lecMatchRetryPending or 0) + 1
    C_Timer.After(1, function()
        container._lecMatchRetryPending = container._lecMatchRetryPending - 1
        if not bc.matchWidth then return end  -- user turned it off mid-retry
        if ApplyMatchWidth(container, bc) then return end
        ScheduleMatchWidthRetry(container, bc, attempts - 1)
    end)
end

-- Set container width based on bc, registering the live-tracking hook on
-- success. Returns true when a width was applied from a live target,
-- false when we had to fall back to bc.width.
ApplyMatchWidth = function(container, bc)
    local h = bc.height or 20
    if not bc.matchWidth then
        container:SetSize(bc.width or 200, h)
        return true
    end
    local target = GetMatchWidthTarget(bc)
    if target and target.GetWidth then
        local tw = target:GetWidth()
        if tw and tw > 0 then
            container:SetSize(tw, h)
            HookMatchWidthTarget(container, bc, target)
            return true
        end
    end
    -- Target not ready: fall back to configured width and schedule a retry,
    -- unless one is already pending so we don't spawn duplicate chains.
    container:SetSize(bc.width or 200, h)
    if (container._lecMatchRetryPending or 0) == 0 then
        ScheduleMatchWidthRetry(container, bc, 10)
    end
    return false
end

local function EnsureBarFrame(stateKey, bc)
    local entry = barFrames[stateKey]
    if not entry then
        local container = CreateFrame("Frame", ResolveBarFrameName(bc), UIParent, "BackdropTemplate")
        container:SetSize(bc.width or 200, bc.height or 20)
        container:Hide()

        local bar = CreateFrame("StatusBar", nil, container)
        bar:SetMinMaxValues(0, 1)
        bar:SetValue(1)

        local nameFS = MakeFontText(bar)
        local durFS  = MakeFontText(bar)

        entry = {
            container = container,
            bar       = bar,
            nameFS    = nameFS,
            durFS     = durFS,
        }
        barFrames[stateKey] = entry
    end

    local container, bar = entry.container, entry.bar
    local nameFS, durFS  = entry.nameFS, entry.durFS

    -- Strata
    local strata = bc.strata
    if not (strata and STRATA_VALUES[strata]) then strata = "HIGH" end
    container:SetFrameStrata(strata)

    -- Size — Match Width can override the configured width by reading the
    -- target frame's GetWidth at render time. Height is always user-controlled.
    -- Live updates and late-loading addons are handled by ApplyMatchWidth
    -- below: a one-shot OnSizeChanged hook keeps us in sync if the target
    -- resizes, and a timer retry covers the case where the target's addon
    -- hasn't finished laying out by the time SetupBars runs.
    ApplyMatchWidth(container, bc)

    -- Backdrop (bg texture + border edge)
    local thick = math.max(0, tonumber(bc.borderThickness or 1) or 1)
    container:SetBackdrop({
        bgFile   = ResolveBackground(bc.bgTexture or "Solid"),
        edgeFile = (thick > 0) and "Interface\\Buttons\\WHITE8x8" or nil,
        edgeSize = (thick > 0) and thick or 1,
        insets   = { left = thick, right = thick, top = thick, bottom = thick },
    })
    local bg = bc.bgColor or {0, 0, 0, 0.7}
    container:SetBackdropColor(bg[1] or 0, bg[2] or 0, bg[3] or 0, bg[4] or 0.7)
    local bd = bc.borderColor or {0, 0, 0, 1}
    container:SetBackdropBorderColor(bd[1] or 0, bd[2] or 0, bd[3] or 0, bd[4] or 1)

    -- Anchor to the resolved frame using configured points.
    container:ClearAllPoints()
    container:SetPoint(
        bc.point or "CENTER",
        ResolveAnchor(bc.anchorFrame),
        bc.relativePoint or "CENTER",
        bc.x or 0,
        bc.y or 0
    )

    -- Bar fits inside the border insets.
    bar:ClearAllPoints()
    bar:SetPoint("TOPLEFT",     thick, -thick)
    bar:SetPoint("BOTTOMRIGHT", -thick, thick)
    bar:SetStatusBarTexture(ResolveStatusBar(bc.barTexture or "Blizzard"))
    local fill = bc.barColor or {0, 1, 0, 1}
    bar:SetStatusBarColor(fill[1] or 0, fill[2] or 1, fill[3] or 0, fill[4] or 1)

    -- Text positioning: configurable per text (point on the FontString,
    -- relativePoint on the bar, and x/y offsets). Single-point anchoring lets
    -- the text width follow its content rather than spanning a fixed half.
    local function placeText(fs, tcfg, defPoint, defRel, defX)
        fs:ClearAllPoints()
        local p   = (tcfg and tcfg.point)         or defPoint
        local rp  = (tcfg and tcfg.relativePoint) or defRel
        local xo  = (tcfg and tonumber(tcfg.x))   or defX
        local yo  = (tcfg and tonumber(tcfg.y))   or 0
        fs:SetPoint(p, bar, rp, xo, yo)
    end
    placeText(nameFS, bc.nameText, "LEFT",  "LEFT",   4)
    placeText(durFS,  bc.durText,  "RIGHT", "RIGHT", -4)

    -- Initial text config (non-expiring state). Live OnUpdate flips colors
    -- once remaining drops below bc.expireAt.
    ApplyTextConfig(nameFS, bc.nameText, nil, false)
    ApplyTextConfig(durFS,  bc.durText,  nil, false)

    entry._bc = bc
    entry._expiringActive = false
    return entry
end

-- -------------------------------------------------- --
--  Per-bar OnUpdate                                  --
-- -------------------------------------------------- --

local function ApplyExpiring(entry, expiring)
    if entry._expiringActive == expiring then return end
    entry._expiringActive = expiring
    local bc = entry._bc
    -- Bar color: only flip when expiring is enabled (nil/true = enabled to
    -- preserve previous behavior; false = keep normal color throughout).
    if bc.useExpiringColor ~= false then
        if expiring then
            local c = bc.barExpiringColor or {1, 0, 0, 1}
            entry.bar:SetStatusBarColor(c[1] or 1, c[2] or 0, c[3] or 0, c[4] or 1)
        else
            local c = bc.barColor or {0, 1, 0, 1}
            entry.bar:SetStatusBarColor(c[1] or 0, c[2] or 1, c[3] or 0, c[4] or 1)
        end
    end
    -- Apply expiring/normal color to each text that opted in.
    if bc.nameText and bc.nameText.useExpiringColor then
        local c = expiring and (bc.nameText.expiringColor or {1, 0, 0, 1}) or (bc.nameText.color or {1, 1, 1, 1})
        entry.nameFS:SetTextColor(c[1] or 1, c[2] or 1, c[3] or 1, c[4] or 1)
    end
    if bc.durText and bc.durText.useExpiringColor then
        local c = expiring and (bc.durText.expiringColor or {1, 0, 0, 1}) or (bc.durText.color or {1, 1, 1, 1})
        entry.durFS:SetTextColor(c[1] or 1, c[2] or 1, c[3] or 1, c[4] or 1)
    end
end

local function BarOnUpdate(self, elapsed)
    self._t = (self._t or 0) + elapsed
    if self._t < 0.05 then return end  -- throttle ~20Hz
    self._t = 0
    local entry = self._lecEntry
    if not entry then return end
    local now = GetTime()
    local remaining = (entry._exp or 0) - now
    local duration = entry._dur or 0
    if duration <= 0 or remaining <= 0 then
        self:SetScript("OnUpdate", nil)
        -- LEC_AURA_REMOVED will arrive shortly and call RenderBar(nil) which
        -- handles both the showWhenInactive and hidden paths. Until then,
        -- collapse to the inactive look so we don't show 0/full briefly.
        if entry._bc.showWhenInactive then
            entry._exp = 0
            entry._dur = 0
            entry.bar:SetValue(0)
            entry.durFS:SetText("")
            ApplyExpiring(entry, false)
        else
            entry.container:Hide()
        end
        return
    end
    entry.bar:SetValue(remaining / duration)
    local dt = entry._bc.durText
    if dt and dt.enabled ~= false then
        entry.durFS:SetText(FormatDuration(remaining, dt.decimals))
    end
    local expireAt = entry._bc.expireAt or 3
    ApplyExpiring(entry, remaining < expireAt)
end

-- -------------------------------------------------- --
--  Trigger Dispatch                                  --
-- -------------------------------------------------- --

-- Render a single bar in one of three states:
--   auraData ~= nil       → active (drain animation via OnUpdate)
--   auraData == nil with bc.showWhenInactive → inactive but visible (empty bar)
--   otherwise             → hidden
local function RenderBar(spellID, itemID, uid, bc, auraData)
    local stateKey = tostring(spellID) .. "_" .. itemID .. "_" .. uid

    if not auraData and not bc.showWhenInactive then
        -- Hidden state: only touch existing frame if it's around.
        local entry = barFrames[stateKey]
        if entry then
            entry.bar:SetScript("OnUpdate", nil)
            entry.container:Hide()
        end
        return
    end

    local entry = EnsureBarFrame(stateKey, bc)

    local resolvedName = (auraData and auraData.name)
        or (C_Spell.GetSpellName and C_Spell.GetSpellName(spellID))
        or ""

    if bc.nameText and bc.nameText.enabled ~= false then
        entry.nameFS:SetText(resolvedName)
    else
        entry.nameFS:SetText("")
    end

    if auraData then
        -- Secret-value audit (12.0+ aura API):
        --   auraData.expirationTime — plain. Blizzard CDM compares & subtracts
        --     it directly (CooldownViewer.lua:493, 820, 1158).
        --   auraData.duration       — plain. Same.
        --   auraData.name           — plain. Used by Blizzard tooltips.
        --   auraData.applications   — SECRET, intentionally not read here.
        -- The fields we touch must stay plain for Blizzard's own CDM to render;
        -- the issecretvalue check below is defensive against a future patch.
        local exp = auraData.expirationTime
        local dur = auraData.duration
        if issecretvalue and (issecretvalue(exp) or issecretvalue(dur)) then
            entry._exp = 0
            entry._dur = 0
            entry.bar:SetValue(1)
            entry.durFS:SetText("")
            ApplyExpiring(entry, false)
            entry.bar._lecEntry = entry
            entry.bar._t = 0
            entry.bar:SetScript("OnUpdate", nil)  -- no live drain without plain timestamps
            entry.container:Show()
            return
        end
        entry._exp = exp or 0
        entry._dur = dur or 0
        -- Compute current progress immediately. Aura refreshes (LEC_AURA_UPDATED
        -- fires every time the aura is reapplied — including refreshes
        -- triggered by other casts via the CDM's instance hooks) will re-enter
        -- this branch many times. SetValue(1) here would flash the bar to full
        -- between the call and the next OnUpdate tick (~50ms).
        local now = GetTime()
        local remaining = entry._exp - now
        if entry._dur > 0 and remaining > 0 then
            entry.bar:SetValue(remaining / entry._dur)
            local dt = bc.durText
            if dt and dt.enabled ~= false then
                entry.durFS:SetText(FormatDuration(remaining, dt.decimals))
            else
                entry.durFS:SetText("")
            end
            local expireAt = bc.expireAt or 3
            ApplyExpiring(entry, remaining < expireAt)
        else
            -- Infinite duration (0/0) — keep bar full, no duration text.
            entry.bar:SetValue(1)
            entry.durFS:SetText("")
            ApplyExpiring(entry, false)
        end
        entry.bar._lecEntry = entry
        entry.bar._t = 0
        entry.bar:SetScript("OnUpdate", BarOnUpdate)
    else
        -- Inactive-but-visible: empty bar, no duration text, non-expiring color.
        entry._exp = 0
        entry._dur = 0
        entry.bar:SetScript("OnUpdate", nil)
        entry.durFS:SetText("")
        entry.bar:SetValue(0)
        ApplyExpiring(entry, false)
    end

    entry.container:Show()
end

local function ProcessBars(spellID, auraData)
    local items = barItemLookup[spellID]
    if not items then return end
    for itemID, item in pairs(items) do
        if type(item.bars) == "table" then
            for uid, bc in pairs(item.bars) do
                if bc.enabled ~= false then
                    RenderBar(spellID, itemID, uid, bc, auraData)
                end
            end
        end
    end
end

local function ClearBars(spellID)
    local items = barItemLookup[spellID]
    if not items then return end
    for itemID, item in pairs(items) do
        if type(item.bars) == "table" then
            for uid, bc in pairs(item.bars) do
                if bc.enabled ~= false then
                    -- Falls back to "inactive visible" if the bar opted in,
                    -- otherwise hides via RenderBar's nil-auraData path.
                    RenderBar(spellID, itemID, uid, bc, nil)
                end
            end
        end
    end
end

-- Drop the cached frame entry for one bar so the next SetupBars pass creates
-- a fresh frame from the current bc.frameName. Used by the editor's
-- "Regenerate" action; doesn't destroy the old global (WoW frames can't be
-- destroyed), but the new global takes over the name on next CreateFrame.
function ns.ReleaseBarFrame(spellID, itemID, uid)
    if not spellID or not itemID or not uid then return end
    local stateKey = tostring(spellID) .. "_" .. itemID .. "_" .. uid
    local entry = barFrames[stateKey]
    if entry then
        entry.bar:SetScript("OnUpdate", nil)
        entry.container:Hide()
        barFrames[stateKey] = nil
    end
end

-- -------------------------------------------------- --
--  AuraTracker Callbacks                             --
-- -------------------------------------------------- --

local function OnAuraAdded(unit, instanceID, spellID)
    if unit ~= "player" then return end
    local auraData = C_UnitAuras.GetAuraDataByAuraInstanceID(unit, instanceID)
    ProcessBars(spellID, auraData)
end

local function OnAuraUpdated(unit, instanceID, spellID)
    if unit ~= "player" then return end
    local auraData = C_UnitAuras.GetAuraDataByAuraInstanceID(unit, instanceID)
    ProcessBars(spellID, auraData)
end

local function OnAuraRemoved(unit, _, spellID)
    if unit ~= "player" then return end
    -- Aura may still be active via another instance; if so, refresh from the remaining.
    if ns.reverseLookup and ns.reverseLookup[spellID] then
        local remainingID = next(ns.reverseLookup[spellID])
        if remainingID then
            local remainingUnit = ns.reverseLookup[spellID][remainingID]
            local auraData = C_UnitAuras.GetAuraDataByAuraInstanceID(remainingUnit, remainingID)
            ProcessBars(spellID, auraData)
            return
        end
    end
    ClearBars(spellID)
end

-- -------------------------------------------------- --
--  Setup / Teardown                                  --
-- -------------------------------------------------- --

local function BuildBarItemLookup(db)
    local lookup = {}
    for itemID, item in pairs(db.profile.items) do
        if item.type == "auraTrigger" and item.bars and ns.ShouldLoadItem(db, itemID) then
            local spellID = item.spellID
            if spellID then
                lookup[spellID] = lookup[spellID] or {}
                lookup[spellID][itemID] = item
            end
        end
    end
    return lookup
end

function ns.SetupBars(addon)
    ns.lpmsg("Lifecycle: SetupBars", "DEBUG")
    ns.StopAllBars()

    barItemLookup = BuildBarItemLookup(addon.db)
    if not next(barItemLookup) then
        ns.lpmsg("Lifecycle: SetupBars — no bar configs", "DEBUG")
        return
    end

    ns.AuraTracker:On("LEC_AURA_ADDED",   "bars", OnAuraAdded)
    ns.AuraTracker:On("LEC_AURA_UPDATED", "bars", OnAuraUpdated)
    ns.AuraTracker:On("LEC_AURA_REMOVED", "bars", OnAuraRemoved)

    -- Seed initial render. For each bar config:
    --   aura currently up → render active using current aura data
    --   aura down, showWhenInactive → render empty/visible
    --   aura down, no showWhenInactive → RenderBar no-ops (already hidden)
    for spellID, items in pairs(barItemLookup) do
        local instances = ns.reverseLookup and ns.reverseLookup[spellID]
        local liveAuraData
        if instances then
            local instanceID = next(instances)
            if instanceID then
                local unit = instances[instanceID]
                liveAuraData = C_UnitAuras.GetAuraDataByAuraInstanceID(unit, instanceID)
            end
        end
        for itemID, item in pairs(items) do
            if type(item.bars) == "table" then
                for uid, bc in pairs(item.bars) do
                    if bc.enabled ~= false then
                        RenderBar(spellID, itemID, uid, bc, liveAuraData)
                    end
                end
            end
        end
    end
    ns.lpmsg("Lifecycle: SetupBars done", "DEBUG")
end

function ns.StopAllBars()
    ns.AuraTracker:Off("LEC_AURA_ADDED",   "bars")
    ns.AuraTracker:Off("LEC_AURA_UPDATED", "bars")
    ns.AuraTracker:Off("LEC_AURA_REMOVED", "bars")
    for _, entry in pairs(barFrames) do
        entry.bar:SetScript("OnUpdate", nil)
        entry.container:Hide()
    end
    wipe(barItemLookup)
end

-- Preview: simulate a 10s aura draining. duration default 10s if not provided.
function ns.PreviewBar(bc, stateKey, on, durationSeconds, spellName)
    if on then
        local entry = EnsureBarFrame(stateKey, bc)
        local now = GetTime()
        local dur = tonumber(durationSeconds) or 10
        entry._exp = now + dur
        entry._dur = dur
        if bc.nameText and bc.nameText.enabled ~= false then
            entry.nameFS:SetText(spellName or "Preview")
        else
            entry.nameFS:SetText("")
        end
        entry.bar:SetValue(1)
        entry.container:Show()
        entry.bar._lecEntry = entry
        entry.bar._t = 0
        entry.bar:SetScript("OnUpdate", BarOnUpdate)
    else
        local entry = barFrames[stateKey]
        if entry then
            entry.bar:SetScript("OnUpdate", nil)
            entry.container:Hide()
        end
    end
end
