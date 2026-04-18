-- cooldowns.lua
-- CDTracker: fires LEC_CD_USED when the player casts a tracked spell,
-- LEC_CD_READY when the CDM's cooldown widget signals the CD is done.
--
-- USED — UNIT_SPELLCAST_SUCCEEDED (unit-filtered to "player"):
--   Precise, safe (not tainted), avoids the GCD false-positives and ArcUI noise
--   we'd get from hooking SetCooldown* on the Cooldown widget directly.
--   Populates ns.cdStateDB[spellID] = true.
--
-- READY — hooks on each CDM frame's Cooldown widget (Clear + OnCooldownDone):
--   Filtered by cdStateDB: only fire LEC_CD_READY when a spell we previously
--   saw get cast has now ended. This filters out the flood of Clear/Done calls
--   other addons (e.g. ArcUI's shadow-feed cycles) trigger on frames we didn't
--   put into the "on CD" state ourselves.
--
-- Zero tainted reads: spell identity comes from frame.cooldownInfo.spellID (safe);
-- timestamps and durations are never read.

local _, ns = ...

ns.cdStateDB = {}  -- [spellID] = true while the spell is tracked as on-CD

local callbacks = {
    LEC_CD_USED  = {},
    LEC_CD_READY = {},
}

local function FireEvent(event, spellID)
    local handlers = callbacks[event]
    if not handlers then return end
    for _, fn in pairs(handlers) do fn(spellID) end
end

-- -------------------------------------------------- --
-- State transitions                                  --
-- -------------------------------------------------- --

local function FireUsed(spellID, entryName)
    if not spellID or spellID == 0 then return end
    if ns.cdStateDB[spellID] then return end  -- dedup refreshes
    ns.cdStateDB[spellID] = true
    ns.lpmsg("CD USED: " .. spellID .. " (" .. (entryName or "?") .. ")", "DEBUG")
    FireEvent("LEC_CD_USED", spellID)
end

local function FireReady(spellID, entryName)
    if not spellID or spellID == 0 then return end
    if not ns.cdStateDB[spellID] then return end  -- only fire for spells we saw get cast
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

-- Resolve tracked spell for a spellID from a cast event.
local function ResolveTrackedFromCastID(castSpellID)
    for _, entry in pairs(ns.cdFrameMap) do
        if entry._lecSpellID == castSpellID
           or entry._lecOverrideID == castSpellID then
            return entry._lecSpellID, entry
        end
    end
end

-- -------------------------------------------------- --
-- Per-frame hooking (READY signals)                  --
-- -------------------------------------------------- --

local hookedCooldowns = {}

function ns.HookCDFrame(frame)
    if not frame then return end
    local cd = frame.Cooldown or frame.cooldown
    if not cd or hookedCooldowns[cd] then return end
    hookedCooldowns[cd] = true

    ns.lpmsg("HookCDFrame: installing READY hooks", "DEBUG")

    if cd.Clear then
        hooksecurefunc(cd, "Clear", function()
            local sid, entry = ResolveTrackedFromFrame(frame)
            if sid and entry then FireReady(sid, entry._lecName) end
        end)
    end

    cd:HookScript("OnCooldownDone", function()
        local sid, entry = ResolveTrackedFromFrame(frame)
        if sid and entry then FireReady(sid, entry._lecName) end
    end)
end

-- -------------------------------------------------- --
-- USED detection via UNIT_SPELLCAST_SUCCEEDED        --
-- -------------------------------------------------- --

local eventFrame = CreateFrame("Frame")

eventFrame:SetScript("OnEvent", function(_, event, _, _, spellID)
    if event ~= "UNIT_SPELLCAST_SUCCEEDED" then return end
    if not spellID then return end
    local sid, entry = ResolveTrackedFromCastID(spellID)
    if sid and entry then FireUsed(sid, entry._lecName) end
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
