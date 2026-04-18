-- cooldowns.lua
-- CDTracker: fires LEC_CD_USED when the player casts a tracked spell,
-- LEC_CD_READY when CDM calls Clear() on the spell's Cooldown widget.
--
-- Per ArcUI's note: frame.Cooldown:Clear fires "at exact CD expiry moment,
-- very low frequency (~16x vs 693 SPELL_UPDATE_COOLDOWN events)". CDM calls
-- Clear when it decides the real cooldown is done — natural expiry OR mid-GCD
-- proc reset — so hooking it gives us instant, precise READY signals without
-- polling, event handling, or tainted field reads.
--
-- USED  — UNIT_SPELLCAST_SUCCEEDED (unit-filtered to "player").
-- READY — hooksecurefunc(frame.Cooldown, "Clear"), guarded by cdStateDB so only
--         spells we saw the player cast produce a READY event.

local _, ns = ...

ns.cdStateDB = {}

local callbacks = {
    LEC_CD_USED  = {},
    LEC_CD_READY = {},
}

local function FireEvent(event, spellID)
    local handlers = callbacks[event]
    if not handlers then return end
    for _, fn in pairs(handlers) do fn(spellID) end
end

local function FireUsed(spellID, entryName)
    if not spellID or spellID == 0 then return end
    if ns.cdStateDB[spellID] then return end
    ns.cdStateDB[spellID] = true
    ns.lpmsg("CD USED: " .. spellID .. " (" .. (entryName or "?") .. ")", "DEBUG")
    FireEvent("LEC_CD_USED", spellID)
end

local function FireReady(spellID, entryName)
    if not spellID or spellID == 0 then return end
    if not ns.cdStateDB[spellID] then return end
    ns.cdStateDB[spellID] = nil
    ns.lpmsg("CD READY: " .. spellID .. " (" .. (entryName or "?") .. ")", "DEBUG")
    FireEvent("LEC_CD_READY", spellID)
end

-- -------------------------------------------------- --
-- Frame → tracked spell resolution                   --
-- -------------------------------------------------- --

local function ResolveTrackedFromFrame(frame)
    local ci = frame.cooldownInfo
    if not ci then return nil end
    local liveSpellID = ci.overrideSpellID or ci.spellID
    if not liveSpellID then return nil end
    for _, entry in pairs(ns.cdFrameMap) do
        if entry._lecSpellID == liveSpellID
           or entry._lecOverrideID == liveSpellID then
            return entry._lecSpellID, entry
        end
    end
end

-- Match a cast spellID to a cdFrameMap entry via direct ID, then by spell name,
-- then via the cast spellID's own GetOverrideSpell chain. Handles talent
-- overrides that make the cast spellID differ from both _lecSpellID and
-- _lecOverrideID.
local function MatchCast(castSpellID)
    for _, entry in pairs(ns.cdFrameMap) do
        if entry._lecSpellID == castSpellID or entry._lecOverrideID == castSpellID then
            return entry
        end
    end
    local name = C_Spell.GetSpellName(castSpellID)
    if name and ns.cdFrameMap[name] then
        return ns.cdFrameMap[name]
    end
    local chained = C_Spell.GetOverrideSpell and C_Spell.GetOverrideSpell(castSpellID)
    if chained and chained ~= castSpellID then
        for _, entry in pairs(ns.cdFrameMap) do
            if entry._lecSpellID == chained or entry._lecOverrideID == chained then
                return entry
            end
        end
    end
end

-- -------------------------------------------------- --
-- Per-frame hook                                     --
-- -------------------------------------------------- --

local hookedCooldowns = {}

local hookedFrames = {}

function ns.HookCDFrame(frame)
    if not frame then return end

    -- Path 1: CDM calls frame.Cooldown:Clear when the visible spiral is done.
    -- Catches natural expiry and delayed proc-reset signals. Low frequency.
    local cd = frame.Cooldown or frame.cooldown
    if cd and cd.Clear and not hookedCooldowns[cd] then
        hookedCooldowns[cd] = true
        ns.lpmsg("HookCDFrame: hooking Cooldown:Clear", "DEBUG")
        hooksecurefunc(cd, "Clear", function()
            local sid, entry = ResolveTrackedFromFrame(frame)
            if sid and entry then FireReady(sid, entry._lecName) end
        end)
    end

    -- Path 2: OnSpellUpdateCooldownEvent fires after CDM has processed the
    -- SPELL_UPDATE_COOLDOWN event for this frame. At that moment cdInfo.isOnGCD
    -- is up-to-date: isOnGCD=true means the cooldown currently reported IS the
    -- GCD (real CD is done, only GCD remains). Combined with the cdStateDB
    -- guard — we only fire READY if we previously saw the spell get cast —
    -- this gives us instant mid-GCD proc-reset detection.
    --
    -- cdInfo.isOnGCD is safe to compare (ArcUI reads it the same way); only
    -- startTime/duration/isOnActualCooldown taint.
    if frame.OnSpellUpdateCooldownEvent and not hookedFrames[frame] then
        hookedFrames[frame] = true
        ns.lpmsg("HookCDFrame: hooking OnSpellUpdateCooldownEvent", "DEBUG")
        hooksecurefunc(frame, "OnSpellUpdateCooldownEvent", function(self)
            local sid, entry = ResolveTrackedFromFrame(self)
            if not sid or not entry then return end
            if not ns.cdStateDB[sid] then return end

            local activeID = sid
            if entry._lecOverrideID and C_Spell.GetOverrideSpell
               and C_Spell.GetOverrideSpell(sid) == entry._lecOverrideID then
                activeID = entry._lecOverrideID
            end

            local cdInfo = C_Spell.GetSpellCooldown(activeID)
            if cdInfo and cdInfo.isOnGCD == true then
                FireReady(sid, entry._lecName)
            end
        end)
    end
end

-- -------------------------------------------------- --
-- Events                                             --
-- -------------------------------------------------- --

local eventFrame = CreateFrame("Frame")

eventFrame:SetScript("OnEvent", function(_, event, _, _, spellID)
    if event ~= "UNIT_SPELLCAST_SUCCEEDED" then return end
    if not spellID then return end
    local entry = MatchCast(spellID)
    if not entry then return end
    FireUsed(entry._lecSpellID, entry._lecName)
end)

-- -------------------------------------------------- --
-- Public CDTracker                                   --
-- -------------------------------------------------- --

ns.CDTracker = {
    On = function(_, event, key, fn)
        if callbacks[event] then callbacks[event][key] = fn end
    end,

    Off = function(_, event, key)
        if callbacks[event] then callbacks[event][key] = nil end
    end,

    SeedState = function()
        wipe(ns.cdStateDB)
    end,

    Init = function()
        ns.lpmsg("Lifecycle: CDTracker:Init", "DEBUG")
        eventFrame:UnregisterAllEvents()
        eventFrame:RegisterUnitEvent("UNIT_SPELLCAST_SUCCEEDED", "player")
        for _, entry in pairs(ns.cdFrameMap) do
            if entry.frame then ns.HookCDFrame(entry.frame) end
        end
    end,

    Reset = function()
        eventFrame:UnregisterAllEvents()
        wipe(ns.cdStateDB)
        callbacks.LEC_CD_USED  = {}
        callbacks.LEC_CD_READY = {}
    end,
}
