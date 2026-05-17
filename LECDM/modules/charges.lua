-- charges.lua
-- Tracks "is this spell at full charges right now?" for CD-trigger items.
-- Mirrors ArcUI's glow-at-full behavior: only fires when currentCharges == maxCharges.
--
-- Plain-value implementation: C_Spell.GetSpellCharges returns currentCharges /
-- maxCharges as plain numbers, so we compare directly. No StatusBar trick, no
-- secret-value taint surface. Cast-count spells (Mana Tea-style) have no
-- exposed max, so they fall through to "unknown" and the toggle pass-through
-- via Refresh's nil return — see ComputeIsFull.
--
-- Other modules subscribe via ns.ChargeTracker:On("LEC_CHARGES_FULL_CHANGED", key, fn)
-- and read ns.chargeFullDB[spellID] for current state.

local _, ns = ...

local pairs, wipe = pairs, wipe
local C_Spell = C_Spell

-- Public read-only state
ns.chargeFullDB = {}  -- [spellID] = true | false   (nil = unknown / undeterminable)

-- Private state
local callbacks      = { LEC_CHARGES_FULL_CHANGED = {} }
local mixinHooked    = false
local trackedSpells  = {}  -- [spellID] = true — only refresh spells we care about

local eventFrame = CreateFrame("Frame")

local function FireEvent(event, ...)
    local handlers = callbacks[event]
    if not handlers then return end
    for _, fn in pairs(handlers) do fn(...) end
end

-- Plain-value compare: returns true if at full, false if not, nil if
-- undeterminable (no native charges, cast-count spell, or secret-tainted).
local function ComputeIsFull(spellID)
    if not spellID then return nil end
    local info = C_Spell.GetSpellCharges and C_Spell.GetSpellCharges(spellID)
    if not info then return nil end
    local cur, max = info.currentCharges, info.maxCharges
    if not cur or not max or max <= 1 then return nil end
    if issecretvalue and (issecretvalue(cur) or issecretvalue(max)) then
        return nil
    end
    return cur == max
end

local function Refresh(spellID)
    if not trackedSpells[spellID] then return end
    local newVal = ComputeIsFull(spellID)
    local oldVal = ns.chargeFullDB[spellID]
    if newVal == oldVal then return end
    ns.chargeFullDB[spellID] = newVal
    -- Only fire on real true/false transitions; nil → boolean shouldn't broadcast
    -- a meaningless "now false" since the toggle pass-through handles unknowns.
    FireEvent("LEC_CHARGES_FULL_CHANGED", spellID, newVal == true)
end

local function RefreshAllTracked()
    for spellID in pairs(trackedSpells) do
        Refresh(spellID)
    end
end

-- -------------------------------------------------- --
--  Feed channels                                     --
-- -------------------------------------------------- --

eventFrame:SetScript("OnEvent", function(_, event, unit, _, spellID)
    if event == "SPELL_UPDATE_CHARGES" then
        -- SPELL_UPDATE_CHARGES is global (no spell payload); refresh everything tracked.
        RefreshAllTracked()
    elseif event == "UNIT_SPELLCAST_SUCCEEDED" and unit == "player" then
        -- Per-spell hint: only refresh the cast spell if tracked.
        if spellID and trackedSpells[spellID] then Refresh(spellID) end
    end
end)

-- Mixin hook covers cast-count refresh cycles and any path SPELL_UPDATE_CHARGES
-- doesn't reach. Guarded so repeated SetupCharges calls don't stack wrappers.
local function EnsureMixinHook()
    if mixinHooked then return end
    local mixin = _G.CooldownViewerCooldownItemMixin
    if not mixin or not mixin.RefreshSpellChargeInfo then return end
    mixinHooked = true
    hooksecurefunc(mixin, "RefreshSpellChargeInfo", function(self)
        local ci = self.cooldownInfo
        if not ci then return end
        local spellID = ci.overrideSpellID or ci.spellID
        if spellID and trackedSpells[spellID] then Refresh(spellID) end
    end)
end

-- -------------------------------------------------- --
--  Public ChargeTracker                              --
-- -------------------------------------------------- --

ns.ChargeTracker = {
    On = function(_, event, key, fn)
        if callbacks[event] then callbacks[event][key] = fn end
    end,

    Off = function(_, event, key)
        if callbacks[event] then callbacks[event][key] = nil end
    end,

    -- Tell the tracker which spells to watch. Other modules call this when
    -- their config builds discover items with triggerAtFull set.
    Track = function(_, spellID)
        if not spellID then return end
        trackedSpells[spellID] = true
        Refresh(spellID)
    end,

    Untrack = function(_, spellID)
        if not spellID then return end
        trackedSpells[spellID] = nil
        ns.chargeFullDB[spellID] = nil
    end,

    IsAtFull = function(_, spellID)
        return ns.chargeFullDB[spellID] == true
    end,

    Init = function()
        ns.lpmsg("Lifecycle: ChargeTracker:Init", "DEBUG")
        eventFrame:UnregisterAllEvents()
        eventFrame:RegisterEvent("SPELL_UPDATE_CHARGES")
        eventFrame:RegisterUnitEvent("UNIT_SPELLCAST_SUCCEEDED", "player")
        EnsureMixinHook()
    end,

    SeedState = function()
        RefreshAllTracked()
    end,

    Reset = function()
        eventFrame:UnregisterAllEvents()
        wipe(trackedSpells)
        wipe(ns.chargeFullDB)
        callbacks.LEC_CHARGES_FULL_CHANGED = {}
    end,
}

-- -------------------------------------------------- --
--  Setup                                             --
-- -------------------------------------------------- --

-- Determine whether any loaded item with type cdTrigger has at least one
-- glow/sound/event config with triggerAtFull set. Skip channel registration
-- when nothing needs us — same pattern HasAuraConfigs uses.
local function HasFullChargeConfigs(db)
    if not ns.ShouldLoadItem then return false end
    for itemID, item in pairs(db.profile.items) do
        if item.type == "cdTrigger" and ns.ShouldLoadItem(db, itemID) then
            for _, group in ipairs({ item.glows, item.sounds, item.events }) do
                if type(group) == "table" then
                    for _, cfg in pairs(group) do
                        if cfg.triggerAtFull then return true end
                    end
                end
            end
        end
    end
    return false
end

function ns.SetupCharges(addon)
    ns.lpmsg("Lifecycle: SetupCharges", "DEBUG")
    ns.ChargeTracker:Reset()
    if not HasFullChargeConfigs(addon.db) then
        ns.lpmsg("Lifecycle: SetupCharges — no triggerAtFull configs", "DEBUG")
        return
    end
    ns.ChargeTracker:Init()
    -- Seed tracking set with every cdTrigger spell that has a triggerAtFull
    -- config, so future SPELL_UPDATE_CHARGES fires get translated correctly.
    for itemID, item in pairs(addon.db.profile.items) do
        if item.type == "cdTrigger" and item.spellID and ns.ShouldLoadItem(addon.db, itemID) then
            for _, group in ipairs({ item.glows, item.sounds, item.events }) do
                if type(group) == "table" then
                    for _, cfg in pairs(group) do
                        if cfg.triggerAtFull then
                            ns.ChargeTracker:Track(item.spellID)
                            break
                        end
                    end
                end
            end
        end
    end
    ns.ChargeTracker:SeedState()
    ns.lpmsg("Lifecycle: SetupCharges done", "DEBUG")
end
