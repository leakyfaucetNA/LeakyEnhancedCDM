-- events.lua
-- Fires user-named custom events when aura/cooldown state changes.
-- Primarily for WeakAuras interop via WeakAuras.ScanEvents().
-- Each item can independently enable/disable firing on each trigger type,
-- and the user specifies the event name string that gets broadcast.
--
-- Aura items  — onAdd, onRemove
-- CD items    — onReady, onUsed

local _, ns = ...

-- [spellID] = { [itemID] = item }  — built at setup time, only items with event configs
local eventItemLookup = {}

-- Fire the event to any loaded aura addon and via AceEvent SendMessage.
-- Supports WeakAuras and M33kAuras (WA fork with its own ScanEvents).
-- Any AceEvent addon can also subscribe via LECDM:RegisterMessage(eventName, callback).
local function FireCustomEvent(eventName, spellID)
    if not eventName or eventName == "" then return end
    ns.lpmsg("FireCustomEvent: " .. eventName .. " spellID=" .. tostring(spellID), "DEBUG")
    if WeakAuras and WeakAuras.ScanEvents then
        WeakAuras.ScanEvents(eventName, spellID)
    end
    if M33kAuras and M33kAuras.ScanEvents then
        M33kAuras.ScanEvents(eventName, spellID)
    end
    LECDM:SendMessage(eventName, spellID)
end

-- -------------------------------------------------- --
--  AuraTracker Callbacks                             --
-- -------------------------------------------------- --

-- "Only at Full Charges" gate — UI-restricted to cdTrigger items because aura
-- applications are secret. Defensive type check anyway.
local function GatePassed(item, ec, spellID)
    if not ec.triggerAtFull then return true end
    if item.type ~= "cdTrigger" then return true end
    return ns.ChargeTracker and ns.ChargeTracker:IsAtFull(spellID)
end

-- item.events = { [uid] = { name, enabled, triggerOn, eventName, triggerAtFull } }
local function FireItemEvents(items, spellID, triggerKey)
    if not items then return end
    for _, item in pairs(items) do
        if type(item.events) == "table" then
            for _, ec in pairs(item.events) do
                if ec.triggerOn == triggerKey and ec.enabled ~= false
                   and ec.eventName and ec.eventName ~= ""
                   and GatePassed(item, ec, spellID) then
                    FireCustomEvent(ec.eventName, spellID)
                end
            end
        end
    end
end

local function OnAuraAdded(unit, _, spellID)
    if unit ~= "player" then return end
    FireItemEvents(eventItemLookup[spellID], spellID, "onAdd")
end

local function OnAuraRemoved(unit, _, spellID)
    if unit ~= "player" then return end
    FireItemEvents(eventItemLookup[spellID], spellID, "onRemove")
end

-- -------------------------------------------------- --
--  Cooldown Callbacks                                --
-- -------------------------------------------------- --

local function OnCDReady(spellID)
    FireItemEvents(eventItemLookup[spellID], spellID, "onReady")
end

local function OnCDUsed(spellID)
    FireItemEvents(eventItemLookup[spellID], spellID, "onUsed")
end

-- -------------------------------------------------- --
--  ChargeTracker Callbacks                           --
-- -------------------------------------------------- --

-- On flip to full, fire any triggerAtFull event whose triggerOn matches the
-- spell's current state (ready vs. used). One-shot — no fire on flip-out.
local function OnChargesFullChanged(spellID, isAtFull)
    if not isAtFull then return end
    local items = eventItemLookup[spellID]
    if not items then return end
    local currentTriggerKey = (ns.cdStateDB and ns.cdStateDB[spellID]) and "onUsed" or "onReady"
    for _, item in pairs(items) do
        if item.type == "cdTrigger" and type(item.events) == "table" then
            for _, ec in pairs(item.events) do
                if ec.triggerAtFull and ec.triggerOn == currentTriggerKey
                   and ec.enabled ~= false and ec.eventName and ec.eventName ~= "" then
                    FireCustomEvent(ec.eventName, spellID)
                end
            end
        end
    end
end

-- -------------------------------------------------- --
--  Setup / Teardown                                  --
-- -------------------------------------------------- --

local function BuildEventItemLookup(db)
    local lookup = {}
    for itemID, item in pairs(db.profile.items) do
        if item.events and ns.ShouldLoadItem(db, itemID) then
            local spellID = item.spellID
            if spellID then
                lookup[spellID] = lookup[spellID] or {}
                lookup[spellID][itemID] = item
            end
        end
    end
    return lookup
end

function ns.SetupEvents(addon)
    ns.lpmsg("Lifecycle: SetupEvents", "DEBUG")
    ns.AuraTracker:Off("LEC_AURA_ADDED",   "events")
    ns.AuraTracker:Off("LEC_AURA_REMOVED", "events")
    wipe(eventItemLookup)

    eventItemLookup = BuildEventItemLookup(addon.db)
    if not next(eventItemLookup) then
        ns.lpmsg("Lifecycle: SetupEvents — no event configs", "DEBUG")
        return
    end

    ns.AuraTracker:On("LEC_AURA_ADDED",   "events", OnAuraAdded)
    ns.AuraTracker:On("LEC_AURA_REMOVED", "events", OnAuraRemoved)
    ns.CDTracker:On("LEC_CD_READY", "events", OnCDReady)
    ns.CDTracker:On("LEC_CD_USED",  "events", OnCDUsed)
    ns.ChargeTracker:On("LEC_CHARGES_FULL_CHANGED", "events", OnChargesFullChanged)
    ns.lpmsg("Lifecycle: SetupEvents done", "DEBUG")
end

function ns.StopAllEvents()
    ns.AuraTracker:Off("LEC_AURA_ADDED",   "events")
    ns.AuraTracker:Off("LEC_AURA_REMOVED", "events")
    ns.CDTracker:Off("LEC_CD_READY", "events")
    ns.CDTracker:Off("LEC_CD_USED",  "events")
    if ns.ChargeTracker then ns.ChargeTracker:Off("LEC_CHARGES_FULL_CHANGED", "events") end
    wipe(eventItemLookup)
end
