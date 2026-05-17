local _, ns = ...

LECONT = LibStub("AceAddon-3.0"):NewAddon("LECONT", "AceEvent-3.0", "AceConsole-3.0")

local ADB = LibStub("AceDB-3.0")

-- -------------------------------------------------- --
--  Defaults                                          --
-- -------------------------------------------------- --

local defaults = {
    -- Global (account-wide) settings — shared across all characters/profiles.
    -- Per-container overrides win over these; these win over the hardcoded
    -- defaults baked into container.lua (ns.DEFAULT_DISPEL_COLORS).
    global = {
        dispelColors = {
            [0] = {0.80, 0.00, 0.00, 1},  -- None / Enrage / unknown
            [1] = {0.20, 0.60, 1.00, 1},  -- Magic
            [2] = {0.60, 0.00, 1.00, 1},  -- Curse
            [3] = {0.60, 0.40, 0.00, 1},  -- Disease
            [4] = {0.00, 0.60, 0.00, 1},  -- Poison
            [5] = {1.00, 0.20, 0.20, 1},  -- Bleed
        },
        -- Global text styles. Containers can opt to override per-text via
        -- bc.stackText.override / bc.durationText.override flags. When override
        -- is false (default) the container reads from these instead.
        stackText    = { font = nil, fontSize = 12, fontOutline = "OUTLINE", color = {1, 1, 1, 1} },
        durationText = { font = nil, fontSize = 14, fontOutline = "OUTLINE", color = {1, 1, 1, 1} },
    },
    profile = {
        schemaVersion = 1,
        items  = {},  -- [itemID] = { type = "container", name, enabled, unit, filterGroups, ... }
        groups = {},
        debug  = false,
    },
}

-- -------------------------------------------------- --
--  Per-character profile (mirrors LECDM behavior)    --
-- -------------------------------------------------- --
--
-- AceDB collapses defaultProfile=true to "Default" (AceDB-3.0.lua:271), so we
-- migrate each character to a "Name - Realm" profile on first load. Per-char
-- flag in db.char ensures migration runs exactly once per character.

local function GetCharProfileKey()
    local name  = UnitName("player")
    local realm = GetRealmName()
    if name and realm then return name .. " - " .. realm end
    return name or "Default"
end

local function MigrateToCharacterProfile(db)
    if db.char.charProfileMigrated then return end
    local charKey = GetCharProfileKey()
    local current = db:GetCurrentProfile()
    if current ~= charKey then
        local hadProfile = db.profiles[charKey] ~= nil
        db:SetProfile(charKey)
        if not hadProfile and current then
            db:CopyProfile(current, true)
        end
        ns.lpmsg("Profile migrated to character-specific: " .. charKey)
    end
    db.char.charProfileMigrated = true
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
    ns.SetupContainers(addon)
    executionDepth = executionDepth - 1
    ns.lpmsg("Lifecycle: SetupAddon complete", "DEBUG")
end

-- -------------------------------------------------- --
--  Lifecycle Events                                  --
-- -------------------------------------------------- --

local pendingSetup = false
local function ScheduleSetup(addon)
    if pendingSetup then return end
    pendingSetup = true
    C_Timer.After(0.1, function()
        pendingSetup = false
        ns.SetupAddon(addon)
    end)
end

function LECONT:PLAYER_ENTERING_WORLD()         ns.SetupAddon(self) end
function LECONT:PLAYER_SPECIALIZATION_CHANGED() ScheduleSetup(self) end
function LECONT:PLAYER_TALENT_UPDATE()          ScheduleSetup(self) end
function LECONT:TRAIT_CONFIG_UPDATED()          ScheduleSetup(self) end
function LECONT:SPELLS_CHANGED()                ScheduleSetup(self) end

-- -------------------------------------------------- --
--  Initialization                                    --
-- -------------------------------------------------- --

function LECONT:OnInitialize()
    self.db = ADB:New("LECONTdb", defaults, "Default")
    MigrateToCharacterProfile(self.db)
    self:RegisterEvent("PLAYER_ENTERING_WORLD")
    self:RegisterEvent("PLAYER_SPECIALIZATION_CHANGED")
    self:RegisterEvent("PLAYER_TALENT_UPDATE")
    self:RegisterEvent("TRAIT_CONFIG_UPDATED")
    self:RegisterEvent("SPELLS_CHANGED")
end

function LECONT:OnEnable()
    self:RegisterChatCommand("lecont", "SlashCommand")
    self:RegisterChatCommand("lec-c",  "SlashCommand")
    ns.lpmsg("Loaded — type /lecont for options")
end

-- -------------------------------------------------- --
--  Slash Commands                                    --
-- -------------------------------------------------- --

function LECONT:SlashCommand(arg)
    if arg == "" or arg == "config" or arg == "options" then
        if ns.ToggleSettings then ns.ToggleSettings() end
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
    else
        ns.lpmsg("Commands: config | reset | debug [on|full|off]")
    end
end
