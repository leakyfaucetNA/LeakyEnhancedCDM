-- auras.lua
-- Tracks active auras via CDM viewer hooks (additions/updates) and UNIT_AURA (removals).
-- CDM pool viewers fire OnAcquireItemFrame when handing out a display frame. We hook that,
-- then hook SetAuraInstanceInfo on each acquired frame to read the safe cooldownInfo.spellID.
-- UNIT_AURA spellIDs are secret; only used here for removal and full-update reconciliation.
-- Other modules subscribe via ns.AuraTracker:On/Off and read ns.aurasDB / ns.reverseLookup.

local _, ns = ...

local pairs, ipairs, next, wipe = pairs, ipairs, next, wipe

local VIEWER_NAMES = {
    "EssentialCooldownViewer",
    "BuffIconCooldownViewer",
    "BuffBarCooldownViewer",
    "UtilityCooldownViewer",
}

-- Private state
local trackedUnits  = {}  -- [unit] = true
local hookedFrames  = {}  -- [frame] = true  — guards against double-hooking pool frames
local hookedViewers = {}  -- [viewerName] = true  — retry nil viewers on subsequent Init calls

-- Public data (read-only for consumers)
ns.aurasDB       = {}  -- [unit][instanceID] = { spellID, name, auraInstanceID, cdmInstance, _lastSeen }
ns.reverseLookup = {}  -- [spellID][instanceID] = unit  (non-nil entry = spell currently active)

-- Internal callbacks
local callbacks = {
    LEC_AURA_ADDED   = {},
    LEC_AURA_REMOVED = {},
    LEC_AURA_UPDATED = {},
}

local function FireEvent(event, ...)
    local handlers = callbacks[event]
    if not handlers then return end
    for _, fn in pairs(handlers) do fn(...) end
end

-- Read the safe display-side spellID from a CDM pool frame.
-- cooldownInfo.spellID is the CDM display value and is not tainted.
-- cooldownID nil means the frame has been released back to the pool.
local function GetFrameSpellID(frame)
    if not frame.cooldownInfo or not frame.cooldownID then return nil end
    return frame.cooldownInfo.spellID
end

-- -------------------------------------------------- --
--  Core aura DB operations                           --
-- -------------------------------------------------- --

local function RemoveAura(unit, instanceID)
    local unitDB = ns.aurasDB[unit]
    if not unitDB then return end
    local entry = unitDB[instanceID]
    if not entry then return end
    local sid = entry.spellID
    unitDB[instanceID] = nil
    if ns.reverseLookup[sid] then
        ns.reverseLookup[sid][instanceID] = nil
        if not next(ns.reverseLookup[sid]) then
            ns.reverseLookup[sid] = nil
        end
    end
    ns.lpmsg(sid .. " " .. (entry.name or "?") .. " removed", "DEBUG")
    FireEvent("LEC_AURA_REMOVED", unit, instanceID, sid)
end

local function AddAura(unit, instanceID, spellID, name, cdmAuraInstance)
    if not spellID then return end
    ns.aurasDB[unit] = ns.aurasDB[unit] or {}
    local existing = ns.aurasDB[unit][instanceID]
    if existing then
        if existing.spellID == spellID then
            -- Same aura refreshed (stack change, duration refresh) — update and notify.
            if cdmAuraInstance then existing.cdmInstance = cdmAuraInstance end
            existing._lastSeen = GetTime()
            FireEvent("LEC_AURA_UPDATED", unit, instanceID, spellID, existing)
            return
        end
        RemoveAura(unit, instanceID)  -- instanceID reused by a different spell
    end
    local entry = {
        spellID      = spellID,
        name         = name,
        auraInstanceID = instanceID,
        _lastSeen    = GetTime(),
    }
    if cdmAuraInstance then entry.cdmInstance = cdmAuraInstance end
    ns.aurasDB[unit][instanceID] = entry
    ns.reverseLookup[spellID] = ns.reverseLookup[spellID] or {}
    ns.reverseLookup[spellID][instanceID] = unit
    ns.lpmsg(spellID .. " " .. (name or "?") .. " added", "DEBUG")
    FireEvent("LEC_AURA_ADDED", unit, instanceID, spellID, entry)
end

local function WipeUnit(unit)
    local unitDB = ns.aurasDB[unit]
    if not unitDB then return end
    for instanceID, entry in pairs(unitDB) do
        local sid = entry.spellID
        if ns.reverseLookup[sid] then
            ns.reverseLookup[sid][instanceID] = nil
            if not next(ns.reverseLookup[sid]) then ns.reverseLookup[sid] = nil end
        end
        FireEvent("LEC_AURA_REMOVED", unit, instanceID, sid)
    end
    wipe(unitDB)
end

-- -------------------------------------------------- --
--  CDM viewer hooking                                --
-- -------------------------------------------------- --

local function HookFrame(viewer, frame)
    if not frame then return end

    local map = ns.GetMapForViewer(viewer)
    if map == ns.auraFrameMap and frame.SetAuraInstanceInfo then
        -- Aura viewer frame — hook SetAuraInstanceInfo; fires each time aura data is written.
        if hookedFrames[frame] then return end
        hookedFrames[frame] = true
        ns.lpmsg("HookFrame: aura frame from " .. tostring(viewer:GetName()), "DEBUG")
        hooksecurefunc(frame, "SetAuraInstanceInfo", function(self, cdmAuraInstance)
            if not cdmAuraInstance or not cdmAuraInstance.auraInstanceID then return end
            local unit = self.auraDataUnit
            if not unit or not trackedUnits[unit] then return end
            local spellID = GetFrameSpellID(self)
            if not spellID then return end
            local name = ns.GetSpellName(spellID)
            ns.UpdateMapFrame(spellID, self, viewer)
            AddAura(unit, cdmAuraInstance.auraInstanceID, spellID, name, cdmAuraInstance)
        end)
    else
        -- Cooldown viewer frame.
        -- Install transition hooks FIRST (on frame.Cooldown — persistent, survives
        -- pool reuse). Must happen unconditionally: pool frames are often acquired
        -- with cooldownID=nil, and by the time CDM assigns a spell to them the
        -- acquisition callback has already run.
        if ns.HookCDFrame then ns.HookCDFrame(frame) end

        -- Capture frame-ref + spellID separately; this requires cooldownID to be set.
        local function CaptureCooldownFrame()
            if not frame.cooldownID then return end
            local info = C_CooldownViewer.GetCooldownViewerCooldownInfo(frame.cooldownID)
            if info and info.spellID and info.spellID > 0 then
                ns.UpdateMapFrame(info.spellID, frame, viewer)
                ns.lpmsg("HookFrame: cooldown frame spellID=" .. info.spellID, "DEBUG")
            end
        end
        if frame.cooldownID then
            CaptureCooldownFrame()
        else
            C_Timer.After(0, CaptureCooldownFrame)
        end
    end
end

local function HookViewer(viewer)
    if not viewer then return end
    if not viewer.OnAcquireItemFrame then
        ns.lpmsg("HookViewer: " .. tostring(viewer:GetName()) .. " has no OnAcquireItemFrame", "DEBUG")
        return
    end
    ns.lpmsg("HookViewer: " .. tostring(viewer:GetName()), "DEBUG")
    hooksecurefunc(viewer, "OnAcquireItemFrame", HookFrame)
    for _, child in ipairs({viewer:GetChildren()}) do
        HookFrame(viewer, child)
    end
end

-- -------------------------------------------------- --
--  UNIT_AURA handler                                 --
-- -------------------------------------------------- --

-- Removals and full-update reconciliation only — additions come through the CDM hook.
--
-- isFullUpdate race: CDM also listens to UNIT_AURA and calls SetAuraInstanceInfo for every
-- currently-displayed aura. Handler order is not guaranteed. Fix: don't wipe immediately.
-- Stamp _lastSeen = GetTime() in AddAura. After one tick, remove only entries whose
-- _lastSeen predates the snapshot timestamp — those CDM never re-confirmed.
-- GetTime() is identical for all handlers firing within the same frame tick, so ordering
-- between our hook and the CDM's handler becomes irrelevant.

local eventFrame = CreateFrame("Frame")
eventFrame:SetScript("OnEvent", function(_, event, unit, info)
    if event ~= "UNIT_AURA" then return end
    if not trackedUnits[unit] then return end

    -- info.isFullUpdate is a SECRET VALUE in 12.0+ (per TwintopInsanityBar's
    -- handler at Functions/Aura.lua:80). Branching on it directly taints
    -- execution. Guard with issecretvalue and treat the secret case as "not
    -- full update" — the addedAuras / updatedAuraInstanceIDs / removedAura-
    -- InstanceIDs payloads below still drive the normal reconciliation path,
    -- so we don't lose state when we skip the snapshot pass.
    local isFull = info and info.isFullUpdate
    if issecretvalue and issecretvalue(isFull) then isFull = false end
    if not info or isFull then
        local updateTime = GetTime()
        local unitDB = ns.aurasDB[unit]
        local snapshot = {}
        if unitDB then
            for instanceID in pairs(unitDB) do snapshot[instanceID] = true end
        end
        C_Timer.After(0, function()
            for instanceID in pairs(snapshot) do
                local entry = ns.aurasDB[unit] and ns.aurasDB[unit][instanceID]
                if not entry or (entry._lastSeen or 0) < updateTime then
                    RemoveAura(unit, instanceID)
                end
            end
        end)
        return
    end

    if info.removedAuraInstanceIDs then
        for _, instanceID in ipairs(info.removedAuraInstanceIDs) do
            RemoveAura(unit, instanceID)
        end
    end

    -- Stack count changes — CDM's SetAuraInstanceInfo hook will have already updated
    -- the cdmInstance on the entry; just fire the update event for downstream consumers.
    if info.updatedAuraInstanceIDs then
        for _, instanceID in ipairs(info.updatedAuraInstanceIDs) do
            local unitDB = ns.aurasDB[unit]
            if unitDB and unitDB[instanceID] then
                local entry = unitDB[instanceID]
                FireEvent("LEC_AURA_UPDATED", unit, instanceID, entry.spellID, entry)
            end
        end
    end
end)

-- -------------------------------------------------- --
--  Public AuraTracker                                --
-- -------------------------------------------------- --

ns.AuraTracker = {
    -- Subscribe to an event.
    -- LEC_AURA_ADDED:   fn(unit, instanceID, spellID, entry)
    -- LEC_AURA_REMOVED: fn(unit, instanceID, spellID)
    -- LEC_AURA_UPDATED: fn(unit, instanceID, spellID, entry)
    On = function(_, event, key, fn)
        if callbacks[event] then callbacks[event][key] = fn end
    end,

    Off = function(_, event, key)
        if callbacks[event] then callbacks[event][key] = nil end
    end,

    -- Begin tracking units and hook CDM viewers.
    -- Safe to call again on spec/talent change; viewer hooks are installed once per viewer.
    Init = function(_, units)
        ns.lpmsg("Lifecycle: AuraTracker:Init", "DEBUG")
        eventFrame:UnregisterAllEvents()
        trackedUnits = {}
        for _, u in ipairs(units or {"player"}) do
            trackedUnits[u] = true
            eventFrame:RegisterUnitEvent("UNIT_AURA", u)
        end
        for _, name in ipairs(VIEWER_NAMES) do
            if not hookedViewers[name] then
                local viewer = _G[name]
                ns.lpmsg("Hooking viewer: " .. name .. " exists=" .. tostring(viewer ~= nil), "DEBUG")
                if viewer then
                    HookViewer(viewer)
                    hookedViewers[name] = true
                end
            end
        end

        -- Belt-and-suspenders: hook CooldownViewerMixin.OnAcquireItemFrame globally.
        -- Some CDM viewers resolve the method via metatable inheritance, so per-instance
        -- hooking can miss calls. The mixin-level hook catches every viewer that inherits
        -- from it. Guarded with hookedViewers["__mixin"] so we only install once.
        if not hookedViewers["__mixin"] and _G.CooldownViewerMixin
           and _G.CooldownViewerMixin.OnAcquireItemFrame then
            hookedViewers["__mixin"] = true
            hooksecurefunc(_G.CooldownViewerMixin, "OnAcquireItemFrame", HookFrame)
            ns.lpmsg("Hooked CooldownViewerMixin.OnAcquireItemFrame", "DEBUG")
        end

        -- Hook CooldownViewerItemDataMixin:SetCooldownID — fires every time CDM
        -- assigns (or re-assigns) a cooldownID to an item frame. OnAcquireItemFrame
        -- only catches NEW pool acquisitions; reassignment of an existing frame
        -- (CDM refresh, layout change, another addon reparenting pool frames
        -- before we hook the viewer) wouldn't reach our map otherwise. This
        -- catches every frame→spell binding regardless of parent or ordering.
        if not hookedViewers["__itemData"] and _G.CooldownViewerItemDataMixin
           and _G.CooldownViewerItemDataMixin.SetCooldownID then
            hookedViewers["__itemData"] = true
            hooksecurefunc(_G.CooldownViewerItemDataMixin, "SetCooldownID", function(itemFrame, newCdID)
                if not newCdID then return end
                local info = C_CooldownViewer.GetCooldownViewerCooldownInfo(newCdID)
                if not info or not info.spellID or info.spellID <= 0 then return end
                local spellID = info.spellID
                -- Update the matching entry in whichever map owns this spell.
                for _, map in ipairs({ ns.cdFrameMap, ns.auraFrameMap }) do
                    for _, entry in pairs(map) do
                        if entry._lecSpellID == spellID or entry._lecOverrideID == spellID then
                            entry.frame = itemFrame
                        end
                    end
                end
            end)
            ns.lpmsg("Hooked CooldownViewerItemDataMixin.SetCooldownID", "DEBUG")
        end
    end,

    -- Populate map frame refs from CDM frames already active when maps were built.
    -- Must be called after BuildSpellMap / BuildAuraMap so map entries exist to write into.
    SeedFrames = function()
        for _, name in ipairs(VIEWER_NAMES) do
            local viewer = _G[name]
            if viewer then
                local children = {viewer:GetChildren()}
                ns.lpmsg("SeedFrames: " .. name .. " children=" .. #children, "DEBUG")
                for _, child in ipairs(children) do
                    local spellID
                    local isAura = child.SetAuraInstanceInfo ~= nil
                    if isAura then
                        spellID = GetFrameSpellID(child)
                    elseif child.cooldownID then
                        local info = C_CooldownViewer.GetCooldownViewerCooldownInfo(child.cooldownID)
                        if info and info.spellID and info.spellID > 0 then
                            spellID = info.spellID
                        end
                    end
                    if spellID then
                        ns.lpmsg("SeedFrames: " .. name .. " spellID=" .. spellID
                            .. " isAura=" .. tostring(isAura), "DEBUG")
                        ns.UpdateMapFrame(spellID, child, name)
                    end
                end
            else
                ns.lpmsg("SeedFrames: " .. name .. " viewer nil", "DEBUG")
            end
        end
        ns.lpmsg("Lifecycle: AuraTracker:SeedFrames done", "DEBUG")
    end,

    -- Stop tracking, wipe all data, and clear all subscriptions.
    Reset = function()
        for unit in pairs(trackedUnits) do WipeUnit(unit) end
        wipe(ns.aurasDB)
        wipe(ns.reverseLookup)
        trackedUnits = {}
        eventFrame:UnregisterAllEvents()
        callbacks.LEC_AURA_ADDED   = {}
        callbacks.LEC_AURA_REMOVED = {}
        callbacks.LEC_AURA_UPDATED = {}
    end,
}
