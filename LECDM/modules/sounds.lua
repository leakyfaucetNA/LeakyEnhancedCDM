-- sounds.lua
-- Plays sounds on aura/cooldown trigger events.
-- Subscribes independently to LEC_AURA_ADDED/REMOVED and LEC_CD_READY/USED.
--
-- Per-trigger sound config (item.sounds.onAdd, .onRemove, .onReady, .onUsed):
--   enabled        bool
--   soundName      string|number  — file path or SOUNDKIT ID
--   channel        string         — "Master"|"SFX"|"Music"|"Ambience"  (default "Master")
--   repeatMode     string         — "once"|"count"|"loop"
--   repeatCount    number         — total plays when repeatMode = "count"
--   repeatInterval number         — seconds between repeats (count/loop, min 0.1s)

local _, ns = ...

local LSM = LibStub("LibSharedMedia-3.0")

-- [stateKey] = { timer = handle }
-- stateKey = spellID .. "_" .. itemID .. "_" .. triggerKey
local soundState = {}

-- [spellID] = { [itemID] = item }
local soundItemLookup = {}

-- -------------------------------------------------- --
--  Playback                                          --
-- -------------------------------------------------- --

local function PlaySnd(soundName, channel)
    if not soundName or soundName == "" then return end
    local ch = channel or "Master"
    if type(soundName) == "number" then
        PlaySound(soundName, ch)
    else
        local path = LSM:Fetch("sound", soundName) or soundName
        PlaySoundFile(path, ch)
    end
end

local function StopRepeat(stateKey)
    local state = soundState[stateKey]
    if state and state.timer then
        state.timer:Cancel()
    end
    soundState[stateKey] = nil
end

local function StartSound(stateKey, sc)
    StopRepeat(stateKey)
    if not sc.soundName or sc.soundName == "" then return end

    PlaySnd(sc.soundName, sc.channel)

    local mode     = sc.repeatMode or "once"
    local interval = math.max(sc.repeatInterval or 1.0, 0.1)

    if mode == "count" then
        local total = (sc.repeatCount or 1) - 1  -- already played once above
        if total <= 0 then return end

        soundState[stateKey] = {}
        local function RepeatPlay()
            if not soundState[stateKey] then return end
            PlaySnd(sc.soundName, sc.channel)
            total = total - 1
            if total <= 0 then
                soundState[stateKey] = nil
            else
                soundState[stateKey].timer = C_Timer.NewTimer(interval, RepeatPlay)
            end
        end
        soundState[stateKey].timer = C_Timer.NewTimer(interval, RepeatPlay)

    elseif mode == "loop" then
        soundState[stateKey] = {}
        local function LoopPlay()
            if not soundState[stateKey] then return end
            PlaySnd(sc.soundName, sc.channel)
            soundState[stateKey].timer = C_Timer.NewTimer(interval, LoopPlay)
        end
        soundState[stateKey].timer = C_Timer.NewTimer(interval, LoopPlay)
    end
    -- "once" falls through with no timer
end

-- -------------------------------------------------- --
--  Trigger Dispatch                                  --
-- -------------------------------------------------- --

-- "Only at Full Charges" gate — toggle is UI-restricted to cdTrigger items
-- because aura applications are secret. Defensive type check anyway.
local function GatePassed(item, sc, spellID)
    if not sc.triggerAtFull then return true end
    if item.type ~= "cdTrigger" then return true end
    return ns.ChargeTracker and ns.ChargeTracker:IsAtFull(spellID)
end

-- item.sounds = { [uid] = { name, enabled, triggerOn, soundName, channel, repeatMode, ... } }
local function ProcessSound(spellID, triggerKey)
    local items = soundItemLookup[spellID]
    if not items then return end
    for itemID, item in pairs(items) do
        if type(item.sounds) == "table" then
            for uid, sc in pairs(item.sounds) do
                if sc.triggerOn == triggerKey and sc.enabled ~= false and sc.soundName
                   and GatePassed(item, sc, spellID) then
                    local stateKey = tostring(spellID) .. "_" .. itemID .. "_" .. uid
                    StartSound(stateKey, sc)
                end
            end
        end
    end
end

local function StopSound(spellID, triggerKey)
    local items = soundItemLookup[spellID]
    if not items then return end
    for itemID, item in pairs(items) do
        if type(item.sounds) == "table" then
            for uid, sc in pairs(item.sounds) do
                if sc.triggerOn == triggerKey then
                    local stateKey = tostring(spellID) .. "_" .. itemID .. "_" .. uid
                    StopRepeat(stateKey)
                end
            end
        end
    end
end

-- -------------------------------------------------- --
--  AuraTracker Callbacks                             --
-- -------------------------------------------------- --

local function OnAuraAdded(unit, _, spellID)
    if unit ~= "player" then return end
    ProcessSound(spellID, "onAdd")
end

local function OnAuraRemoved(unit, _, spellID)
    if unit ~= "player" then return end
    -- Stop any looping/repeating onAdd sound when the aura fades
    StopSound(spellID, "onAdd")
    ProcessSound(spellID, "onRemove")
end

-- -------------------------------------------------- --
--  CDTracker Callbacks                               --
-- -------------------------------------------------- --

local function OnCDReady(spellID)
    StopSound(spellID, "onUsed")
    ProcessSound(spellID, "onReady")
end

local function OnCDUsed(spellID)
    StopSound(spellID, "onReady")
    ProcessSound(spellID, "onUsed")
end

-- -------------------------------------------------- --
--  ChargeTracker Callbacks                           --
-- -------------------------------------------------- --

-- When the spell flips into/out of "full charges", any triggerAtFull-gated
-- sound config matching the spell's current state (ready vs. used) starts
-- or stops. cdStateDB is the source of truth for ready/used (truthy = used).
local function OnChargesFullChanged(spellID, isAtFull)
    local items = soundItemLookup[spellID]
    if not items then return end
    local currentTriggerKey = (ns.cdStateDB and ns.cdStateDB[spellID]) and "onUsed" or "onReady"
    for itemID, item in pairs(items) do
        if item.type == "cdTrigger" and type(item.sounds) == "table" then
            for uid, sc in pairs(item.sounds) do
                if sc.triggerAtFull and sc.triggerOn == currentTriggerKey
                   and sc.enabled ~= false and sc.soundName then
                    local stateKey = tostring(spellID) .. "_" .. itemID .. "_" .. uid
                    if isAtFull then
                        StartSound(stateKey, sc)
                    else
                        StopRepeat(stateKey)
                    end
                end
            end
        end
    end
end

-- -------------------------------------------------- --
--  Setup / Teardown                                  --
-- -------------------------------------------------- --

local function BuildSoundItemLookup(db)
    local lookup = {}
    for itemID, item in pairs(db.profile.items) do
        if item.sounds and ns.ShouldLoadItem(db, itemID) then
            local spellID = item.spellID
            if spellID then
                lookup[spellID] = lookup[spellID] or {}
                lookup[spellID][itemID] = item
            end
        end
    end
    return lookup
end

function ns.SetupSounds(addon)
    ns.lpmsg("Lifecycle: SetupSounds", "DEBUG")
    ns.StopAllSounds()

    soundItemLookup = BuildSoundItemLookup(addon.db)
    if not next(soundItemLookup) then
        ns.lpmsg("Lifecycle: SetupSounds — no sound configs", "DEBUG")
        return
    end

    ns.AuraTracker:On("LEC_AURA_ADDED",   "sounds", OnAuraAdded)
    ns.AuraTracker:On("LEC_AURA_REMOVED", "sounds", OnAuraRemoved)
    ns.CDTracker:On("LEC_CD_READY", "sounds", OnCDReady)
    ns.CDTracker:On("LEC_CD_USED",  "sounds", OnCDUsed)
    ns.ChargeTracker:On("LEC_CHARGES_FULL_CHANGED", "sounds", OnChargesFullChanged)
    ns.lpmsg("Lifecycle: SetupSounds done", "DEBUG")
end

function ns.StopAllSounds()
    ns.AuraTracker:Off("LEC_AURA_ADDED",   "sounds")
    ns.AuraTracker:Off("LEC_AURA_REMOVED", "sounds")
    ns.CDTracker:Off("LEC_CD_READY", "sounds")
    ns.CDTracker:Off("LEC_CD_USED",  "sounds")
    if ns.ChargeTracker then ns.ChargeTracker:Off("LEC_CHARGES_FULL_CHANGED", "sounds") end
    for stateKey in pairs(soundState) do
        StopRepeat(stateKey)
    end
    wipe(soundState)
    wipe(soundItemLookup)
end
