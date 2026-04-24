local _, ns = ...

LECDM = LibStub("AceAddon-3.0"):NewAddon("LECDM", "AceHook-3.0", "AceEvent-3.0", "AceConsole-3.0")

local ADB = LibStub("AceDB-3.0")

-- -------------------------------------------------- --
--  Utilities                                         --
-- -------------------------------------------------- --

local uidCounter = 0
function ns.GenerateUID()
    uidCounter = uidCounter + 1
    return tostring(time()) .. "_" .. uidCounter
end

ns.LogBuffer = {}

function ns.lpmsg(msg, category)
    local isDebug = (category == "DEBUG")
    local rawDebug = ns.DEBUG or (LECDM.db and LECDM.db.profile.debug)
    local debugMode = (rawDebug == true) and "on" or rawDebug

    if isDebug then
        if debugMode == "full" then
            print("|cffff9900[LECDM]|r " .. tostring(msg))
        end
    else
        print("|cff00fbffLECDM:|r " .. tostring(msg))
    end

    if not debugMode then return end

    local entry = string.format("[%0.2f] [%s] %s", debugprofilestop(), category or "INFO", tostring(msg))
    table.insert(ns.LogBuffer, entry)
    if #ns.LogBuffer > 3000 then table.remove(ns.LogBuffer, 1) end
end

function ns.GetSpellName(id)
    if not id then return nil end
    local info = C_Spell.GetSpellInfo(id)
    return info and info.name or nil
end

-- -------------------------------------------------- --
--  Public API                                        --
-- -------------------------------------------------- --

-- Other addons can access this via:
--     local LECDM = LibStub("AceAddon-3.0"):GetAddon("LECDM", true)
--     if LECDM and LECDM.API then
--         local frame = LECDM.API.GetFrame("aura", "Spiritfont")
--     end
--
-- Or directly via the global `LECDM.API.GetFrame(kind, name)`.
LECDM.API = LECDM.API or {}

-- Returns the live CDM pool frame that corresponds to the given spell name
-- from the aura or CD map, or nil if not found. Spell name matching is exact
-- (Blizzard's C_Spell.GetSpellName value). Accepts either the base name or
-- an override name (e.g. "Word of Glory" or "Eternal Flame") — the map stores
-- both as keys to the same entry.
--
-- Returned frame is a live CDM pool frame parented under its viewer. The
-- caller SHOULD treat it as read-only / anchor-target only; parenting or
-- mutating it risks taint. Use it like the glow overlay pattern:
--     CreateFrame("Frame", nil, UIParent):SetPoint("CENTER", frame, "CENTER")
--
-- The frame ref may be hidden if the spell isn't currently displayed; check
-- :IsShown() if that matters to your use case.
--
-- @param kind  "aura" | "cd"  (aliases: "auras", "cds", "cooldown")
-- @param name  spell name string
-- @return Frame|nil
function LECDM.API.GetFrame(kind, name)
    if type(kind) ~= "string" or type(name) ~= "string" or name == "" then
        return nil
    end

    local map
    if kind == "aura" or kind == "auras" then
        map = ns.auraFrameMap
    elseif kind == "cd" or kind == "cds" or kind == "cooldown" or kind == "cooldowns" then
        map = ns.cdFrameMap
    end
    if not map then return nil end

    local entry = map[name]
    if entry and entry.frame then return entry.frame end
    return nil
end

-- Does the saved DB have any enabled+loadable item of the given type that has
-- at least one configured sub-module (glow/sound/event)? Used to skip the
-- associated tracker's event registration and frame hooks when nothing is
-- listening — no UNIT_AURA chatter on an addon with no aura configs, no
-- UNIT_SPELLCAST_SUCCEEDED chatter when no CD configs.
local function HasConfigsOfType(itemType)
    if not LECDM or not LECDM.db or not ns.ShouldLoadItem then return false end
    for itemID, item in pairs(LECDM.db.profile.items) do
        if item.type == itemType and ns.ShouldLoadItem(LECDM.db, itemID) then
            if (item.glows  and next(item.glows))
               or (item.sounds and next(item.sounds))
               or (item.events and next(item.events))
               or (item.texts  and next(item.texts)) then
                return true
            end
        end
    end
    return false
end

function ns.HasAuraConfigs() return HasConfigsOfType("auraTrigger") end
function ns.HasCDConfigs()   return HasConfigsOfType("cdTrigger")   end

-- Reconcile tracker state with current configs. Called from SetupAddon and
-- whenever the settings UI edits items.
function ns.UpdateTrackerState()
    local hasAura = ns.HasAuraConfigs()
    local hasCD   = ns.HasCDConfigs()
    if hasAura then
        ns.AuraTracker:Init({"player"})
        ns.AuraTracker:SeedFrames()
    else
        ns.AuraTracker:Reset()
    end
    if hasCD then
        ns.CDTracker:Init()
        ns.CDTracker:SeedState()
    else
        ns.CDTracker:Reset()
    end
    ns.lpmsg("TrackerState: aura=" .. tostring(hasAura) .. " cd=" .. tostring(hasCD), "DEBUG")
end

-- -------------------------------------------------- --
--  Setup                                             --
-- -------------------------------------------------- --

local executionDepth = 0

function ns.SetupAddon(addon)
    if executionDepth > 0 then
        ns.lpmsg("Skip: SetupAddon already in progress", "DEBUG")
        return
    end

    ns.lpmsg("Lifecycle: SetupAddon", "DEBUG")

    if InCombatLockdown() then
        if addon._isWaitingForCombat then return end
        addon._isWaitingForCombat = true
        ns.lpmsg("In Combat -> Delaying until combat ends", "DEBUG")
        addon:RegisterEvent("PLAYER_REGEN_ENABLED", function()
            addon._isWaitingForCombat = nil
            addon:UnregisterEvent("PLAYER_REGEN_ENABLED")
            ns.SetupAddon(addon)
        end)
        return
    end

    executionDepth = executionDepth + 1

    -- Maps are always built (settings UI reads them for spell lists). Tracker
    -- init is deferred to UpdateTrackerState which skips it when nothing is
    -- configured for that tracker type.
    ns.BuildSpellMap()
    ns.BuildAuraMap()
    ns.UpdateTrackerState()
    ns.SetupGlows(addon)
    ns.SetupSounds(addon)
    ns.SetupEvents(addon)
    ns.SetupTexts(addon)

    executionDepth = executionDepth - 1
    ns.lpmsg("Lifecycle: SetupAddon complete", "DEBUG")
end

-- -------------------------------------------------- --
--  DB Defaults                                       --
-- -------------------------------------------------- --

local defaults = {
    profile = {
        schemaVersion = 1,
        items  = {},  -- [itemID] = { type, spellID, enabled, loadConditions, glows, sounds, events }
        groups = {},  -- [groupID] = { name, enabled, order, loadConditions }
        debug  = false,
    }
}

-- -------------------------------------------------- --
--  Lifecycle Events                                  --
-- -------------------------------------------------- --

function LECDM:PLAYER_ENTERING_WORLD()
    ns.isInitialLoad = true
    ns.SetupAddon(self)

    C_Timer.After(2, function()
        ns.isInitialLoad = false
        ns.lpmsg("Post-load CDM map rebuild", "DEBUG")
        ns.BuildSpellMap()
        ns.BuildAuraMap()
        ns.AuraTracker:SeedFrames()
        ns.CDTracker:SeedState()
    end)
end

function LECDM:PLAYER_SPECIALIZATION_CHANGED() ns.SetupAddon(self) end
function LECDM:PLAYER_TALENT_UPDATE()          ns.SetupAddon(self) end
function LECDM:GROUP_ROSTER_UPDATE()           ns.SetupAddon(self) end

-- -------------------------------------------------- --
--  Initialization                                    --
-- -------------------------------------------------- --

function LECDM:OnInitialize()
    self.db = ADB:New("LECDMdb", defaults, true)
    self:RegisterEvent("PLAYER_ENTERING_WORLD")
    self:RegisterEvent("PLAYER_SPECIALIZATION_CHANGED")
    self:RegisterEvent("PLAYER_TALENT_UPDATE")
    self:RegisterEvent("GROUP_ROSTER_UPDATE")
end

function LECDM:OnEnable()
    self:RegisterChatCommand("lecdm", "SlashCommand")
    self:RegisterChatCommand("lec", "SlashCommand")
    ns.lpmsg("Loaded type /lec or /lecdm for options")
end

-- -------------------------------------------------- --
--  Slash Commands                                    --
-- -------------------------------------------------- --

function LECDM:SlashCommand(arg)
    if arg == "" or arg == "config" or arg == "options" then
        ns.ToggleSettings()
    elseif arg == "reset" then
        ns.lpmsg("Reinitializing...")
        ns.SetupAddon(self)
    elseif arg == "debug" or arg:sub(1, 5) == "debug" then
        local sub = arg:match("debug%s+(%S+)")
        if sub then
            self.db.profile.debug = (sub == "off") and false or sub
        else
            local cur = self.db.profile.debug
            self.db.profile.debug = (not cur and "on") or (cur == "on" and "full") or false
        end
        local d = self.db.profile.debug
        local status = (d == "on" and "|cff00ff00ON|r") or (d == "full" and "|cff00ff00FULL|r") or "|cffff0000OFF|r"
        ns.lpmsg("Debug: " .. status)
    elseif arg == "maps" then
        local cdCount, auraCount = 0, 0
        for _ in pairs(ns.cdFrameMap)   do cdCount   = cdCount   + 1 end
        for _ in pairs(ns.auraFrameMap) do auraCount = auraCount + 1 end
        ns.lpmsg("cdFrameMap: " .. cdCount .. "  auraFrameMap: " .. auraCount)
    else
        ns.lpmsg("Commands: config | reset | debug [on|full|off] | maps")
    end
end
