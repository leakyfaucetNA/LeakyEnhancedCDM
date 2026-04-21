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
--  Stack Detection                                   --
-- -------------------------------------------------- --

local stackDetectionDisabled = false
local stackDetectorUID       = 0
local stackDetectors         = {}  -- [spellID][minVal] = StatusBar
local cachedApplications     = {}  -- [spellID] = applications (secret value)

local function CreateStackDetector(spellID, minVal)
    stackDetectorUID = stackDetectorUID + 1
    local bar = CreateFrame("StatusBar", "LECDMStackDetector_" .. stackDetectorUID, UIParent)
    bar:SetSize(1, 1)
    bar:SetPoint("TOPLEFT", UIParent, "TOPLEFT", -500, 500)
    bar:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
    bar:SetAlpha(0)
    bar:Show()
    bar:SetMinMaxValues(minVal, minVal + 1)
    bar:SetValue(cachedApplications[spellID] or 0)
    return bar
end

local function GetStackDetector(spellID, minVal)
    stackDetectors[spellID] = stackDetectors[spellID] or {}
    if not stackDetectors[spellID][minVal] then
        stackDetectors[spellID][minVal] = CreateStackDetector(spellID, minVal)
    end
    return stackDetectors[spellID][minVal]
end

local function UpdateSpellStacks(spellID, secretApps)
    if stackDetectionDisabled then return end
    cachedApplications[spellID] = secretApps
    if stackDetectors[spellID] then
        for _, bar in pairs(stackDetectors[spellID]) do bar:SetValue(secretApps) end
    end
end

local function ClearSpellStacks(spellID)
    cachedApplications[spellID] = nil
    if stackDetectors[spellID] then
        for _, bar in pairs(stackDetectors[spellID]) do bar:SetValue(0) end
    end
end

local function CheckStackBar(spellID, minVal)
    if stackDetectionDisabled then return true end
    local result = GetStackDetector(spellID, minVal):GetStatusBarTexture():IsShown()
    if issecretvalue(result) then
        stackDetectionDisabled = true
        ns.lpmsg("Stack detection unavailable — update your triggers to remove stack thresholds.")
        return true
    end
    return result
end

local function IsStackThresholdMet(spellID, threshold, comparison)
    if not threshold or threshold <= 0 then return true end
    if stackDetectionDisabled then return true end
    comparison = comparison or ">="

    if not cachedApplications[spellID] then
        -- No cached data yet — assume 1 stack and compare
        local stacks = 1
        if comparison == ">=" then return stacks >= threshold
        elseif comparison == ">" then return stacks > threshold
        elseif comparison == "<" then return stacks < threshold
        elseif comparison == "<=" then return stacks <= threshold
        elseif comparison == "=" then return stacks == threshold
        else return true end
    end

    -- Single-stack auras: CheckStackBar(0) is false when only 1 stack is present
    if not CheckStackBar(spellID, 0) then
        local stacks = 1
        if comparison == ">=" then return stacks >= threshold
        elseif comparison == ">" then return stacks > threshold
        elseif comparison == "<" then return stacks < threshold
        elseif comparison == "<=" then return stacks <= threshold
        elseif comparison == "=" then return stacks == threshold
        else return true end
    end

    if comparison == ">=" then return CheckStackBar(spellID, threshold - 1)
    elseif comparison == ">" then return CheckStackBar(spellID, threshold)
    elseif comparison == "<" then return not CheckStackBar(spellID, threshold - 1)
    elseif comparison == "<=" then return not CheckStackBar(spellID, threshold)
    elseif comparison == "=" then return CheckStackBar(spellID, threshold - 1) and not CheckStackBar(spellID, threshold)
    else return true end
end

-- -------------------------------------------------- --
--  ResolveGlowTarget                                 --
-- -------------------------------------------------- --

-- Given a spell ID (number) or frame name (string), return the live CDM pool frame.
-- cooldownID non-nil = frame is active. Stale refs trigger a one-shot reseed + retry.
local function ResolveGlowTarget(frameKey)
    if type(frameKey) == "number" then
        local entry
        for _, map in ipairs({ ns.cdFrameMap, ns.auraFrameMap }) do
            for _, e in pairs(map) do
                if e._lecSpellID == frameKey then entry = e; break end
            end
            if entry then break end
        end

        if entry and entry.frame and entry.frame.cooldownID then return entry.frame end
        if entry and entry.frame and ns.isConfigOpen then return entry.frame end

        if entry and not hasReseeded then
            hasReseeded = true
            ns.lpmsg("ResolveGlowTarget: stale frame spellID=" .. frameKey .. ", reseeding", "DEBUG")
            ns.AuraTracker:SeedFrames()
            if entry.frame and entry.frame.cooldownID then return entry.frame end
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
    if entry and entry.frame and entry.frame.cooldownID then return entry.frame end
    if entry and entry.frame and ns.isConfigOpen then return entry.frame end
    if entry and not hasReseeded then
        hasReseeded = true
        ns.lpmsg("ResolveGlowTarget: stale frame '" .. frameKey .. "', reseeding", "DEBUG")
        ns.AuraTracker:SeedFrames()
        if entry.frame and entry.frame.cooldownID then return entry.frame end
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

    if isNowActive then
        ns.lpmsg("Glow START: " .. (target._lecName or "?") .. " type=" .. gType .. " key=" .. k, "DEBUG")
        if config.safeGlow then UpdateOverlaySize(glowTarget, target) end

        local currentType = glowTarget._lecKeys[k]
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
        local typeToStop = glowTarget._lecKeys and glowTarget._lecKeys[k]
        if typeToStop then
            local stopFn = typeToStop .. "Glow_Stop"
            if LCG[stopFn] then LCG[stopFn](glowTarget, k) end
        else
            for _, gt in ipairs(GLOW_TYPES) do
                local stopFn = gt .. "Glow_Stop"
                if LCG[stopFn] then LCG[stopFn](glowTarget, k) end
            end
        end
        if glowTarget._lecKeys then glowTarget._lecKeys[k] = nil end
    end
end

-- -------------------------------------------------- --
--  shouldGlow Helper                                 --
-- -------------------------------------------------- --

local function ComputeShouldGlow(isEnabled, isPreview, isInverse, isActive, stackThreshold, stackComparison, spellID)
    if not isEnabled then return false end
    if ns.isConfigOpen and not isPreview then return false end
    if isPreview then return true end
    local active = isInverse and (not isActive) or isActive
    if active and not isInverse and stackThreshold and stackThreshold > 0 and spellID then
        active = IsStackThresholdMet(spellID, stackThreshold, stackComparison)
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
        for uid, gc in pairs(item.glows) do
            if gc.enabled ~= false then
                local target = ResolveGlowTarget(gc.frameKey)
                if target then
                    local inverse = INVERSE_TRIGGERS[gc.triggerOn] == true
                    local shouldGlow = ComputeShouldGlow(
                        true, gc.preview or false,
                        inverse,
                        isActive, gc.showAtStacks, gc.stackComparison, spellID)
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

function ns.HardResetAllGlows()
    ns.lpmsg("Lifecycle: HardResetAllGlows", "DEBUG")
    ns.AuraTracker:Off("LEC_AURA_ADDED",   "glows")
    ns.AuraTracker:Off("LEC_AURA_REMOVED", "glows")
    ns.AuraTracker:Off("LEC_AURA_UPDATED", "glows")
    ns.CDTracker:Off("LEC_CD_USED",  "glows")
    ns.CDTracker:Off("LEC_CD_READY", "glows")

    for frame in pairs(ns.FrameRegistry) do
        if frame then ns.StopAllLcgTypes(frame, nil) end
    end
    wipe(ns.FrameRegistry)
    wipe(pendingChanges)

    for _, overlay in pairs(glowOverlays) do overlay:Hide() end
    wipe(glowOverlays)

    for _, detectors in pairs(stackDetectors) do
        for _, bar in pairs(detectors) do bar:Hide() end
    end
    wipe(stackDetectors)
    wipe(cachedApplications)
    wipe(activeItemLookup)
    ns.lpmsg("Lifecycle: HardResetAllGlows done", "DEBUG")
end

function ns.SetupGlows(addon)
    ns.lpmsg("Lifecycle: SetupGlows", "DEBUG")
    ns.HardResetAllGlows()
    wipe(pendingChanges)

    activeItemLookup = ns.BuildActiveItemLookup(addon.db)
    if not next(activeItemLookup) then
        ns.lpmsg("Lifecycle: SetupGlows — no active items", "DEBUG")
        return
    end

    ns.AuraTracker:On("LEC_AURA_ADDED",   "glows", OnAuraAdded)
    ns.AuraTracker:On("LEC_AURA_REMOVED", "glows", OnAuraRemoved)
    ns.AuraTracker:On("LEC_AURA_UPDATED", "glows", OnAuraUpdated)
    ns.CDTracker:On("LEC_CD_USED",  "glows", OnCDUsed)
    ns.CDTracker:On("LEC_CD_READY", "glows", OnCDReady)

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
        local isActive = ns.reverseLookup[spellID] ~= nil
        for _, item in pairs(itemsForSpell) do
            ProcessGlowTrigger(item, spellID, isActive)
        end
    end
end
