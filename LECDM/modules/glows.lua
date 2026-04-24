local _, ns = ...

local pairs, next, wipe, type = pairs, next, wipe, type
local GetSpecialization   = GetSpecialization
local GetSpecializationInfo = GetSpecializationInfo
local InCombatLockdown    = InCombatLockdown
local UnitClass           = UnitClass

local LCG = LibStub("LibCustomGlow-1.0")

-- State
local pendingChanges    = {}   -- [spellID] = isActive — flushed next tick
local glowOverlays      = {}   -- [cdmFrame] = overlayFrame — UIParent-parented LCG targets
local scheduledThisTick = false
local hasReseeded       = false
local pendingReseed     = false
local activeItemLookup  = {}   -- [spellID] = { [itemID] = item }

-- -------------------------------------------------- --
--  Load Conditions                                   --
-- -------------------------------------------------- --

function ns.ShouldLoad(lc)
    if not lc then return true end
    if lc.class then
        local _, playerClass = UnitClass("player")
        if lc.class ~= playerClass then return false end
    end
    if lc.specIDs and next(lc.specIDs) then
        local idx = GetSpecialization()
        local cur = idx and GetSpecializationInfo(idx) or 0
        if not lc.specIDs[cur] then return false end
    end
    if lc.inCombat == true  and not InCombatLockdown() then return false end
    if lc.inCombat == false and     InCombatLockdown() then return false end
    return true
end

local function MergeLoadConditions(ownLC, db, parentGroupID)
    local merged = {}
    if ownLC then
        if ownLC.specIDs and next(ownLC.specIDs) then merged.specIDs = ownLC.specIDs end
        if ownLC.inCombat ~= nil then merged.inCombat = ownLC.inCombat end
        if ownLC.class then merged.class = ownLC.class end
    end
    local groupID = parentGroupID
    while groupID do
        local group = db.profile.groups[groupID]
        if not group then break end
        local glc = group.loadConditions
        if glc then
            if not merged.specIDs and glc.specIDs and next(glc.specIDs) then merged.specIDs = glc.specIDs end
            if merged.inCombat == nil and glc.inCombat ~= nil then merged.inCombat = glc.inCombat end
            if not merged.class and glc.class then merged.class = glc.class end
        end
        groupID = group.parentGroup
    end
    return merged
end

function ns.ShouldLoadItem(db, itemID)
    local item = db.profile.items[itemID]
    if not item or item.enabled == false then return false end

    -- Spec filter: items are created per-spec in the settings UI (GetOrCreateItem
    -- stamps item.specID). Without this check, items configured for other specs
    -- would still load on the current spec, resulting in duplicate glows/sounds/
    -- events/texts firing for the same spell.
    if item.specID then
        local activeIdx = GetSpecialization and GetSpecialization()
        local activeSpec = activeIdx and GetSpecializationInfo and GetSpecializationInfo(activeIdx)
        if activeSpec and item.specID ~= activeSpec then return false end
    end

    local groupID = item.parentGroup
    while groupID do
        local group = db.profile.groups[groupID]
        if not group or group.enabled == false then return false end
        groupID = group.parentGroup
    end
    return ns.ShouldLoad(MergeLoadConditions(item.loadConditions, db, item.parentGroup))
end

-- Build spellID → { [itemID] = item } for all currently-loadable aura/cooldown trigger items.
-- Registers under both the configured spell ID and any talent override ID so that
-- talent swaps (e.g. Word of Glory ↔ Eternal Flame) match regardless of which ID was saved.
function ns.BuildActiveItemLookup(db)
    local lookup = {}
    local function Register(sid, itemID, item)
        if not sid or sid == 0 then return end
        lookup[sid] = lookup[sid] or {}
        lookup[sid][itemID] = item
    end
    for itemID, item in pairs(db.profile.items) do
        if (item.type == "auraTrigger" or item.type == "cdTrigger") and ns.ShouldLoadItem(db, itemID) then
            local spellID = item.spellID
            if spellID then
                Register(spellID, itemID, item)
                local overrideID = C_Spell.GetOverrideSpell(spellID)
                if overrideID and overrideID ~= spellID then
                    Register(overrideID, itemID, item)
                end
                -- If the configured spell IS an override, also register the base spell ID
                for _, map in ipairs({ ns.cdFrameMap, ns.auraFrameMap }) do
                    for _, entry in pairs(map) do
                        if entry._lecOverrideID == spellID and entry._lecSpellID ~= spellID then
                            Register(entry._lecSpellID, itemID, item)
                        end
                    end
                end
            end
        end
    end
    return lookup
end

-- -------------------------------------------------- --
--  Threshold Detection (stacks + charges)            --
-- -------------------------------------------------- --
--
-- Same StatusBar-based trick for both aura stack counts and CD charge counts.
-- The secret value (aura.applications or spellCharges.currentCharges) is fed
-- into a StatusBar via SetValue — no read or compare of the value itself.
-- GetStatusBarTexture():IsShown() then returns a plain boolean we can branch
-- on without tainting, answering "is the value at or above minVal+1?".
--
-- Two independent source tables keep stacks and charges from interfering.
-- Auras come from LEC_AURA_ADDED/UPDATED; charges come from SPELL_UPDATE_CHARGES.

local thresholdDisabled = false
local detectorUID       = 0

local sources = {
    stack  = { cache = {}, bars = {} },  -- [spellID][minVal] = bar;  cache[spellID] = value
    charge = { cache = {}, bars = {} },
}

local function CreateDetector(source, spellID, minVal)
    detectorUID = detectorUID + 1
    local bar = CreateFrame("StatusBar", "LECDMThresholdDetector_" .. detectorUID, UIParent)
    bar:SetSize(1, 1)
    bar:SetPoint("TOPLEFT", UIParent, "TOPLEFT", -500, 500)
    bar:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
    bar:SetAlpha(0)
    bar:Show()
    bar:SetMinMaxValues(minVal, minVal + 1)
    bar:SetValue(source.cache[spellID] or 0)
    return bar
end

local function GetDetector(source, spellID, minVal)
    source.bars[spellID] = source.bars[spellID] or {}
    if not source.bars[spellID][minVal] then
        source.bars[spellID][minVal] = CreateDetector(source, spellID, minVal)
    end
    return source.bars[spellID][minVal]
end

local function UpdateSource(source, spellID, secretValue)
    if thresholdDisabled then return end
    source.cache[spellID] = secretValue
    if source.bars[spellID] then
        for _, bar in pairs(source.bars[spellID]) do bar:SetValue(secretValue) end
    end
end

local function ClearSource(source, spellID)
    source.cache[spellID] = nil
    if source.bars[spellID] then
        for _, bar in pairs(source.bars[spellID]) do bar:SetValue(0) end
    end
end

local function CheckBar(source, spellID, minVal)
    if thresholdDisabled then return true end
    -- Use GetStatusBarTexture():GetWidth() rather than :IsShown(). IsShown
    -- continues to return true at zero width in current WoW versions, so it
    -- doesn't actually distinguish "value above min" from "value at min".
    -- GetWidth collapses to 0 when SetValue == min, which IS the signal we
    -- want. Width is a plain number (not secret) even when fed a secret value.
    local width = GetDetector(source, spellID, minVal):GetStatusBarTexture():GetWidth() or 0
    local result = width > 0.01
    if issecretvalue and issecretvalue(result) then
        thresholdDisabled = true
        ns.lpmsg("Threshold detection unavailable — update your triggers to remove thresholds.")
        return true
    end
    return result
end

-- Generic threshold check. `assumeWhenEmpty` is the value to assume when the
-- cache has no data yet (1 for stacks because an active aura has ≥1 stack by
-- definition; 0 for charges because an unknown-state charge spell shouldn't
-- trigger a positive "≥N charges" threshold).
local function IsThresholdMet(source, spellID, threshold, comparison, assumeWhenEmpty)
    if not threshold or threshold <= 0 then return true end
    if thresholdDisabled then return true end
    comparison = comparison or ">="

    local function compare(value)
        if comparison == ">=" then return value >= threshold
        elseif comparison == ">"  then return value >  threshold
        elseif comparison == "<"  then return value <  threshold
        elseif comparison == "<=" then return value <= threshold
        elseif comparison == "="  then return value == threshold
        else return true end
    end

    if not source.cache[spellID] then
        return compare(assumeWhenEmpty or 0)
    end

    -- When CheckBar(0) is false the fed value is at (or below) the
    -- assume-when-empty baseline — stacks=1 (active aura always ≥1),
    -- charges=0. Fall back to direct compare.
    if not CheckBar(source, spellID, 0) then
        return compare(assumeWhenEmpty or 0)
    end

    if comparison == ">=" then return CheckBar(source, spellID, threshold - 1)
    elseif comparison == ">"  then return CheckBar(source, spellID, threshold)
    elseif comparison == "<"  then return not CheckBar(source, spellID, threshold - 1)
    elseif comparison == "<=" then return not CheckBar(source, spellID, threshold)
    elseif comparison == "="  then return CheckBar(source, spellID, threshold - 1)
                                     and not CheckBar(source, spellID, threshold)
    else return true end
end

-- Public facades preserved for clarity at call sites.
local function UpdateSpellStacks(spellID, secretApps)  UpdateSource(sources.stack, spellID, secretApps) end
local function ClearSpellStacks(spellID)               ClearSource(sources.stack, spellID) end
local function IsStackThresholdMet(spellID, threshold, comparison)
    return IsThresholdMet(sources.stack, spellID, threshold, comparison, 1)
end

local function UpdateSpellCharges(spellID, secretCharges) UpdateSource(sources.charge, spellID, secretCharges) end
local function ClearSpellCharges(spellID)                 ClearSource(sources.charge, spellID) end
local function IsChargeThresholdMet(spellID, threshold, comparison)
    return IsThresholdMet(sources.charge, spellID, threshold, comparison, 0)
end

-- -------------------------------------------------- --
--  ResolveGlowTarget                                 --
-- -------------------------------------------------- --

-- Given a spell ID (number) or frame name (string), return the live CDM pool frame.
-- cooldownID non-nil = frame is active. Stale refs trigger a one-shot reseed + retry.
-- Live-scan the CDM viewers for a pool frame currently displaying spellID.
-- Used as a fallback when the cached entry.frame is nil (CDM addon reparented
-- frames out of the viewer hierarchy before we captured them).
local VIEWER_NAMES_SCAN = {
    "EssentialCooldownViewer", "UtilityCooldownViewer",
    "BuffIconCooldownViewer",  "BuffBarCooldownViewer",
}
local function LiveScanForSpellID(spellID)
    for _, name in ipairs(VIEWER_NAMES_SCAN) do
        local viewer = _G[name]
        if viewer then
            for _, child in ipairs({ viewer:GetChildren() }) do
                local ci = child.cooldownInfo
                if ci and (ci.spellID == spellID or ci.overrideSpellID == spellID) then
                    return child
                end
            end
        end
    end
end

-- Relaxed cooldownID gate: some CDM addons (ArcUI etc.) reparent pool frames
-- out of the native viewer hierarchy, which can leave frame.cooldownID
-- transient/nil even for spells that always display. Accept any cached
-- entry.frame and fall back to a live viewer scan before giving up.
local function ResolveGlowTarget(frameKey)
    if type(frameKey) == "number" then
        local entry
        for _, map in ipairs({ ns.cdFrameMap, ns.auraFrameMap }) do
            for _, e in pairs(map) do
                if e._lecSpellID == frameKey or e._lecOverrideID == frameKey then
                    entry = e; break
                end
            end
            if entry then break end
        end

        if entry and entry.frame then return entry.frame end

        local scanned = LiveScanForSpellID(frameKey)
        if scanned then
            if entry then entry.frame = scanned end  -- backfill cache
            return scanned
        end

        if entry and not hasReseeded then
            hasReseeded = true
            ns.lpmsg("ResolveGlowTarget: missing frame spellID=" .. frameKey .. ", reseeding", "DEBUG")
            ns.AuraTracker:SeedFrames()
            if entry.frame then return entry.frame end
            if not pendingReseed then
                pendingReseed = true
                C_Timer.After(0.5, function()
                    pendingReseed = false
                    ns.AuraTracker:SeedFrames()
                    ns.RefreshAllGlows()
                end)
            end
        end
        return nil
    end

    -- String key — direct global or CDM spell name
    local g = _G[frameKey]
    if g then return g end
    local entry = ns.cdFrameMap[frameKey] or ns.auraFrameMap[frameKey]
    if entry and entry.frame then return entry.frame end
    if entry and not hasReseeded then
        hasReseeded = true
        ns.lpmsg("ResolveGlowTarget: missing frame '" .. frameKey .. "', reseeding", "DEBUG")
        ns.AuraTracker:SeedFrames()
        if entry.frame then return entry.frame end
        if not pendingReseed then
            pendingReseed = true
            C_Timer.After(0.5, function()
                pendingReseed = false
                ns.AuraTracker:SeedFrames()
                ns.RefreshAllGlows()
            end)
        end
    end
end

ns.ResolveGlowTarget = ResolveGlowTarget

-- -------------------------------------------------- --
--  Overlay Management                                --
-- -------------------------------------------------- --

-- CDM frames are tainted — glows must target a UIParent-parented overlay anchored to them.
local function GetOrCreateGlowOverlay(targetFrame)
    local overlay = glowOverlays[targetFrame]
    if overlay then return overlay end

    local ratio = targetFrame:GetEffectiveScale() / UIParent:GetEffectiveScale()
    local w = (targetFrame:GetWidth() or 36) * ratio
    local h = (targetFrame:GetHeight() or 36) * ratio

    local f = CreateFrame("Frame", nil, UIParent)
    f:SetSize(w, h)
    f:SetPoint("CENTER", targetFrame, "CENTER", 0, 0)
    f:SetFrameLevel(200)
    f._lecKeys    = {}
    f._lecName    = targetFrame._lecName
    f._lecSpellID = targetFrame._lecSpellID
    glowOverlays[targetFrame] = f
    return f
end

local function UpdateOverlaySize(overlay, targetFrame)
    local ratio = targetFrame:GetEffectiveScale() / UIParent:GetEffectiveScale()
    local w, h = targetFrame:GetWidth(), targetFrame:GetHeight()
    if w and h and w > 0 and h > 0 then overlay:SetSize(w * ratio, h * ratio) end
end

-- -------------------------------------------------- --
--  Glow Toggle                                       --
-- -------------------------------------------------- --

local GLOW_TYPES = { "Pixel", "AutoCast", "Button", "Proc" }

function ns.StopAllLcgTypes(target, key)
    if key then
        if target._lecKeys and target._lecKeys[key] then
            local stopFn = target._lecKeys[key] .. "Glow_Stop"
            if LCG[stopFn] then LCG[stopFn](target, key) end
            target._lecKeys[key] = nil
        else
            for _, gt in ipairs(GLOW_TYPES) do
                local stopFn = gt .. "Glow_Stop"
                if LCG[stopFn] then LCG[stopFn](target, key) end
            end
        end
        return
    end
    if target._lecKeys then
        for k, gt in pairs(target._lecKeys) do
            local stopFn = gt .. "Glow_Stop"
            if LCG[stopFn] then LCG[stopFn](target, k) end
        end
        wipe(target._lecKeys)
    end
    for _, gt in ipairs(GLOW_TYPES) do
        local stopFn = gt .. "Glow_Stop"
        if LCG[stopFn] then LCG[stopFn](target, "LECDM") end
    end
end

-- Apply or remove a glow on a CDM frame.
-- Always routes through a UIParent overlay to avoid taint.
-- Stops any existing glow for the key before starting a new one —
-- skipping this causes ProcGlow animations to stack on refresh.
function ns.ToggleGlow(target, config, isNowActive)
    local gType    = config.glowType or "Pixel"
    local k        = config.key or "LECDM"
    local fLevel   = config.frameLevel or 20
    local lcgType  = (gType == "Button") and "Proc" or gType

    local glowTarget
    if config.safeGlow or (isNowActive and not target:IsShown()) then
        glowTarget = GetOrCreateGlowOverlay(target)
    else
        glowTarget = target
    end
    if not glowTarget then return end

    if not glowTarget._lecKeys then glowTarget._lecKeys = {} end
    ns.FrameRegistry[glowTarget] = true

    -- Idempotency short-circuit: skip if the glow is already in the requested
    -- state with the same type. Prior behavior restarted the glow on every
    -- call which (a) produced the "STOP/START" debug spam and (b) caused
    -- visible stuttering when an already-active glow got re-evaluated every
    -- frame during UNIT_AURA storms. Proc-style re-triggers still work
    -- because they either change lcgType or go through a full stop first
    -- (isNowActive=false, then true).
    local currentType = glowTarget._lecKeys[k]
    if isNowActive and currentType == lcgType then
        if config.safeGlow then UpdateOverlaySize(glowTarget, target) end
        return
    end
    if not isNowActive and not currentType then
        return
    end

    if isNowActive then
        ns.lpmsg("Glow START: " .. (target._lecName or "?") .. " type=" .. gType .. " key=" .. k, "DEBUG")
        if config.safeGlow then UpdateOverlaySize(glowTarget, target) end

        if currentType then
            local stopFn = currentType .. "Glow_Stop"
            if LCG[stopFn] then LCG[stopFn](glowTarget, k) end
        end

        if lcgType == "Pixel" then
            LCG.PixelGlow_Start(glowTarget, config.rgba, config.lines, config.freq,
                config.length, config.th, config.xOff, config.yOff, config.border, k, fLevel)
        elseif lcgType == "AutoCast" then
            LCG.AutoCastGlow_Start(glowTarget, config.rgba, config.particles, config.freq,
                config.scale, config.xOff, config.yOff, k, fLevel)
        elseif lcgType == "Proc" then
            LCG.ProcGlow_Start(glowTarget, {
                color      = config.rgba,
                frameLevel = fLevel,
                startAnim  = config.startAnim,
                xOffset    = config.xOff,
                yOffset    = config.yOff,
                duration   = (gType == "Button") and 0 or (config.duration or 1),
                key        = k,
            })
        end
        glowTarget._lecKeys[k] = lcgType
    else
        ns.lpmsg("Glow STOP: " .. (target._lecName or "?") .. " key=" .. k, "DEBUG")
        local stopFn = currentType .. "Glow_Stop"
        if LCG[stopFn] then LCG[stopFn](glowTarget, k) end
        glowTarget._lecKeys[k] = nil
    end
end

-- -------------------------------------------------- --
--  shouldGlow Helper                                 --
-- -------------------------------------------------- --

local function ComputeShouldGlow(isEnabled, isPreview, isInverse, isActive, threshold, comparison, spellID, thresholdFn)
    if not isEnabled then return false end
    if ns.isConfigOpen and not isPreview then return false end
    if isPreview then return true end
    local active = isInverse and (not isActive) or isActive
    if active and not isInverse and threshold and threshold > 0 and spellID and thresholdFn then
        active = thresholdFn(spellID, threshold, comparison)
    end
    return active
end

-- -------------------------------------------------- --
--  Trigger Pipeline                                  --
-- -------------------------------------------------- --

-- Trigger → inverse mapping. Active-state triggers (aura present, CD ready)
-- glow directly; "absent-state" triggers (aura removed, CD used) glow when
-- the spell is in the opposite state — that's what "inverse" encodes.
local INVERSE_TRIGGERS = { onRemove = true, onUsed = true }

local function ProcessGlowTrigger(item, spellID, isActive)
    if type(item.glows) == "table" then
        -- Threshold source depends on the item type: aura items check stack
        -- counts via applications; CD items check charge counts.
        local thresholdFn = (item.type == "cdTrigger") and IsChargeThresholdMet
                                                       or IsStackThresholdMet
        for uid, gc in pairs(item.glows) do
            if gc.enabled ~= false then
                -- frameKey=nil means "use this spell's own frame" (the default
                -- target choice in the settings UI). Fall back to the item's
                -- spellID so the resolver has something to look up.
                local target = ResolveGlowTarget(gc.frameKey or spellID)
                if target then
                    local inverse = INVERSE_TRIGGERS[gc.triggerOn] == true
                    local shouldGlow = ComputeShouldGlow(
                        true, gc.preview or false,
                        inverse,
                        isActive, gc.showAtStacks, gc.stackComparison, spellID,
                        thresholdFn)
                    gc.spellID  = spellID
                    gc.safeGlow = true  -- CDM frames always need UIParent overlay
                    gc.key      = uid   -- use UID as the LCG key so instances don't collide
                    ns.ToggleGlow(target, gc, shouldGlow)
                else
                    ns.lpmsg("ProcessGlowTrigger: frame not found uid=" .. uid, "DEBUG")
                end
            end
        end
    end

end

ns.ProcessGlowTrigger = ProcessGlowTrigger

-- Start or stop a preview glow for a single glow config, independent of live
-- aura/CD state. Used by the settings UI — preview uses its own LCG key so it
-- doesn't collide with a real glow on the same frame.
function ns.PreviewGlow(gc, spellID, on)
    if not gc then return end
    local target = ResolveGlowTarget(gc.frameKey or spellID)
    if not target then return end
    gc.spellID  = spellID
    gc.safeGlow = true
    gc.key      = "__preview__"
    ns.ToggleGlow(target, gc, on and true or false)
end

local function processChanges()
    scheduledThisTick = false
    hasReseeded       = false
    if ns.isInitialLoad then wipe(pendingChanges); return end

    local toProcess  = pendingChanges
    pendingChanges   = {}
    for spellID, isActive in pairs(toProcess) do
        local itemsForSpell = activeItemLookup[spellID]
        if itemsForSpell then
            for _, item in pairs(itemsForSpell) do
                ProcessGlowTrigger(item, spellID, isActive)
            end
        else
            ns.lpmsg("processChanges: no config for spellID " .. spellID, "DEBUG")
        end
    end
end

local function scheduleProcess()
    if not scheduledThisTick then
        scheduledThisTick = true
        C_Timer.After(0, processChanges)
    end
end

function ns.QueueGlowChange(spellID, isActive)
    pendingChanges[spellID] = isActive
    scheduleProcess()
end

-- -------------------------------------------------- --
--  AuraTracker Callbacks                             --
-- -------------------------------------------------- --

local function OnAuraAdded(unit, instanceID, spellID)
    if unit ~= "player" then return end
    local auraData = C_UnitAuras.GetAuraDataByAuraInstanceID(unit, instanceID)
    if auraData and auraData.applications then
        UpdateSpellStacks(spellID, auraData.applications)
    end
    pendingChanges[spellID] = true
    scheduleProcess()
end

local function OnAuraRemoved(unit, _, spellID)
    if unit ~= "player" then return end
    local isStillActive = ns.reverseLookup[spellID] ~= nil
    if isStillActive then
        local remainingID = next(ns.reverseLookup[spellID])
        if remainingID then
            local remainingUnit = ns.reverseLookup[spellID][remainingID]
            local auraData = C_UnitAuras.GetAuraDataByAuraInstanceID(remainingUnit, remainingID)
            if auraData and auraData.applications then
                UpdateSpellStacks(spellID, auraData.applications)
            end
        end
    else
        ClearSpellStacks(spellID)
    end
    pendingChanges[spellID] = isStillActive
    scheduleProcess()
end

local function OnCDUsed(spellID)
    pendingChanges[spellID] = false
    scheduleProcess()
end

local function OnCDReady(spellID)
    pendingChanges[spellID] = true
    scheduleProcess()
end

local function OnAuraUpdated(unit, instanceID, spellID)
    if unit ~= "player" then return end
    -- Only re-evaluate if any item for this spell has a stack threshold
    local itemsForSpell = activeItemLookup[spellID]
    if not itemsForSpell then return end
    local hasThreshold = false
    for _, item in pairs(itemsForSpell) do
        if item.glows then
            for _, gc in pairs(item.glows) do
                if gc.showAtStacks and gc.showAtStacks > 0 then hasThreshold = true; break end
            end
        end
        if hasThreshold then break end
    end
    if not hasThreshold then return end

    local auraData = C_UnitAuras.GetAuraDataByAuraInstanceID(unit, instanceID)
    if auraData and auraData.applications then
        UpdateSpellStacks(spellID, auraData.applications)
    end
    pendingChanges[spellID] = true
    scheduleProcess()
end

-- -------------------------------------------------- --
--  Public Setup / Teardown                           --
-- -------------------------------------------------- --

-- Two paths feed our charge bars:
--
-- 1. SPELL_UPDATE_CHARGES event — fires for spells that have native charges
--    (maxCharges > 1). We iterate tracked CD items and refresh.
--
-- 2. CooldownViewerCooldownItemMixin:RefreshSpellChargeInfo hook — CDM's own
--    per-frame refresh method. Needed for spells whose "charges" come from
--    cast count instead of native charges (e.g. Mana Tea stacks). CDM itself
--    falls back to C_Spell.GetSpellCastCount(spellID) in this case, and we
--    mirror that fallback so our threshold bars see the same count.
--
-- Both paths call RefreshChargesForSpell, which tries GetSpellCharges first,
-- then GetSpellCastCount. Value is passed through SetValue on the StatusBar
-- without ever being read or compared.
local chargeEventFrame = CreateFrame("Frame")
local mixinChargeHooked = false

-- isActive depends on item type:
--   auraTrigger → aura currently applied (reverseLookup[spellID] non-nil)
--   cdTrigger   → spell currently ready to cast (not in cdStateDB)
-- Mixing these (e.g. reverseLookup for CD items) skips the threshold check
-- entirely because active=false short-circuits ComputeShouldGlow. That breaks
-- charge-threshold glows for CD spells that are passively holding charges
-- (Mana Tea etc.) — no LEC_CD_* event ever fires to refresh them.
local function IsItemActive(item, spellID)
    if item.type == "auraTrigger" then
        return ns.reverseLookup[spellID] ~= nil
    end
    return not ns.cdStateDB[spellID]
end

local function IsCDItem(spellID)
    local items = activeItemLookup[spellID]
    if not items then return false end
    for _, item in pairs(items) do
        if item.type == "cdTrigger" then return true end
    end
    return false
end

local function RefreshChargesForSpell(spellID)
    if not spellID then return end
    local info = C_Spell.GetSpellCharges and C_Spell.GetSpellCharges(spellID)
    if info and info.maxCharges and info.maxCharges > 1 and info.currentCharges then
        UpdateSpellCharges(spellID, info.currentCharges)
        return
    end
    -- Fallback for cast-count spells (Mana Tea, etc.).
    if C_Spell.GetSpellCastCount then
        local count = C_Spell.GetSpellCastCount(spellID)
        if count then
            UpdateSpellCharges(spellID, count)
        end
    end
end

local function RefreshAllCharges()
    if not LECDM or not LECDM.db then return end
    for spellID in pairs(activeItemLookup) do
        if IsCDItem(spellID) then
            RefreshChargesForSpell(spellID)
        end
    end
    ns.RefreshAllGlows()
end

-- UNIT_AURA on player is the fastest signal that a cast-count spell's hidden
-- stack aura changed — we see it before CDM's own refresh cycle propagates.
-- Throttle to one refresh per frame via a scheduled flag: UNIT_AURA can fire
-- several times in a single tick (one per aura event), so batching avoids N
-- redundant passes.
--
-- Short-circuit: UNIT_AURA refresh only matters for CD glows with a threshold.
-- `hasChargeThreshold` is recomputed once per SetupGlows and gates the handler
-- so idle configs pay zero cost even in UNIT_AURA-heavy combat.
local auraRefreshScheduled  = false
local hasChargeThreshold    = false

local function RecomputeHasChargeThreshold()
    hasChargeThreshold = false
    for _, items in pairs(activeItemLookup) do
        for _, item in pairs(items) do
            if item.type == "cdTrigger" and type(item.glows) == "table" then
                for _, gc in pairs(item.glows) do
                    if gc.showAtStacks and gc.showAtStacks > 0 then
                        hasChargeThreshold = true
                        return
                    end
                end
            end
        end
    end
end

local function ScheduleChargeRefresh()
    if not hasChargeThreshold then return end
    if auraRefreshScheduled then return end
    auraRefreshScheduled = true
    C_Timer.After(0, function()
        auraRefreshScheduled = false
        RefreshAllCharges()
    end)
end

chargeEventFrame:SetScript("OnEvent", function(_, event)
    if event == "SPELL_UPDATE_CHARGES" then
        RefreshAllCharges()
    elseif event == "UNIT_AURA" then
        ScheduleChargeRefresh()
    end
end)

-- Install the mixin hook once. Guarded so repeated SetupGlows calls don't stack
-- multiple wrappers on the same method.
local function EnsureMixinChargeHook()
    if mixinChargeHooked then return end
    local mixin = _G.CooldownViewerCooldownItemMixin
    if not mixin or not mixin.RefreshSpellChargeInfo then return end
    mixinChargeHooked = true
    hooksecurefunc(mixin, "RefreshSpellChargeInfo", function(self)
        local ci = self.cooldownInfo
        if not ci then return end
        local spellID = ci.overrideSpellID or ci.spellID
        if not spellID or not IsCDItem(spellID) then return end
        RefreshChargesForSpell(spellID)
        -- Only re-evaluate glows for this spell rather than all, to avoid
        -- stampeding on CDM's per-frame refresh cycles.
        local items = activeItemLookup[spellID]
        if items then
            for _, item in pairs(items) do
                ProcessGlowTrigger(item, spellID, IsItemActive(item, spellID))
            end
        end
    end)
end

function ns.HardResetAllGlows()
    ns.lpmsg("Lifecycle: HardResetAllGlows", "DEBUG")
    ns.AuraTracker:Off("LEC_AURA_ADDED",   "glows")
    ns.AuraTracker:Off("LEC_AURA_REMOVED", "glows")
    ns.AuraTracker:Off("LEC_AURA_UPDATED", "glows")
    ns.CDTracker:Off("LEC_CD_USED",  "glows")
    ns.CDTracker:Off("LEC_CD_READY", "glows")
    chargeEventFrame:UnregisterAllEvents()

    for frame in pairs(ns.FrameRegistry) do
        if frame then ns.StopAllLcgTypes(frame, nil) end
    end
    wipe(ns.FrameRegistry)
    wipe(pendingChanges)

    for _, overlay in pairs(glowOverlays) do overlay:Hide() end
    wipe(glowOverlays)

    for _, source in pairs(sources) do
        for _, detectors in pairs(source.bars) do
            for _, bar in pairs(detectors) do bar:Hide() end
        end
        wipe(source.bars)
        wipe(source.cache)
    end
    wipe(activeItemLookup)
    ns.lpmsg("Lifecycle: HardResetAllGlows done", "DEBUG")
end

function ns.SetupGlows(addon)
    ns.lpmsg("Lifecycle: SetupGlows", "DEBUG")
    ns.HardResetAllGlows()
    wipe(pendingChanges)

    activeItemLookup = ns.BuildActiveItemLookup(addon.db)
    RecomputeHasChargeThreshold()
    if not next(activeItemLookup) then
        ns.lpmsg("Lifecycle: SetupGlows — no active items", "DEBUG")
        return
    end

    ns.AuraTracker:On("LEC_AURA_ADDED",   "glows", OnAuraAdded)
    ns.AuraTracker:On("LEC_AURA_REMOVED", "glows", OnAuraRemoved)
    ns.AuraTracker:On("LEC_AURA_UPDATED", "glows", OnAuraUpdated)
    ns.CDTracker:On("LEC_CD_USED",  "glows", OnCDUsed)
    ns.CDTracker:On("LEC_CD_READY", "glows", OnCDReady)

    chargeEventFrame:RegisterEvent("SPELL_UPDATE_CHARGES")
    chargeEventFrame:RegisterUnitEvent("UNIT_AURA", "player")
    EnsureMixinChargeHook()
    RefreshAllCharges()  -- initial seed

    ns.RefreshAllGlows()
    ns.lpmsg("Lifecycle: SetupGlows done", "DEBUG")
end

function ns.StopAllGlows()
    for frame in pairs(ns.FrameRegistry) do
        if frame then ns.StopAllLcgTypes(frame, nil) end
    end
end

function ns.RefreshAllGlows()
    hasReseeded = false
    for spellID, itemsForSpell in pairs(activeItemLookup) do
        for _, item in pairs(itemsForSpell) do
            ProcessGlowTrigger(item, spellID, IsItemActive(item, spellID))
        end
    end
end
