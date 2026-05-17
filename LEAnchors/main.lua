local _, ns = ...

LEANC = LibStub("AceAddon-3.0"):NewAddon("LEAnchors",
    "AceEvent-3.0", "AceConsole-3.0", "AceHook-3.0", "AceTimer-3.0")

local ADB = LibStub("AceDB-3.0")

-- -------------------------------------------------- --
--  Defaults                                          --
-- -------------------------------------------------- --

local defaults = {
    -- Global (account-wide) anchors and groups. Items here apply to every
    -- character that loads this addon, gated by item.loadConditions (class /
    -- specIDs / inCombat). Profile-scope items below are character-specific.
    global = {
        items  = {},  -- [itemID] = { type = "anchor", loadConditions = {...}, ... }
        groups = {},
    },
    profile = {
        schemaVersion = 1,
        items  = {},  -- [itemID] = { type = "anchor"|"customEvent", ... }
        groups = {},
        debug  = false,
    },
}

-- -------------------------------------------------- --
--  Per-character profile migration                   --
-- -------------------------------------------------- --

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
        addon:RegisterEvent("PLAYER_REGEN_ENABLED", function()
            addon._isWaitingForCombat = nil
            addon:UnregisterEvent("PLAYER_REGEN_ENABLED")
            ns.SetupAddon(addon)
        end)
        return
    end

    executionDepth = executionDepth + 1
    ns.SetupAnchors(addon)
    ns.SetupCustomEvents(addon)
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

function LEANC:PLAYER_ENTERING_WORLD()         ns.SetupAddon(self) end
function LEANC:PLAYER_SPECIALIZATION_CHANGED() ScheduleSetup(self) end
function LEANC:PLAYER_TALENT_UPDATE()          ScheduleSetup(self) end
function LEANC:TRAIT_CONFIG_UPDATED()          ScheduleSetup(self) end

-- -------------------------------------------------- --
--  Initialization                                    --
-- -------------------------------------------------- --

function LEANC:OnInitialize()
    self.db = ADB:New("LEANCdb", defaults, "Default")
    MigrateToCharacterProfile(self.db)
    ns.UpdateDebugMode()
    self:RegisterEvent("PLAYER_ENTERING_WORLD")
    self:RegisterEvent("PLAYER_SPECIALIZATION_CHANGED")
    self:RegisterEvent("PLAYER_TALENT_UPDATE")
    self:RegisterEvent("TRAIT_CONFIG_UPDATED")
end

function LEANC:OnEnable()
    self:RegisterChatCommand("lea", "SlashCommand")
    ns.lpmsg("Loaded \194\183 type /lea for options")
end

-- -------------------------------------------------- --
--  Slash Commands                                    --
-- -------------------------------------------------- --

function LEANC:SlashCommand(arg)
    if arg == "" or arg == "config" or arg == "options" then
        if ns.ToggleSettings then ns.ToggleSettings() end
    elseif arg == "reset" then
        -- Snapshot the pre-reset state for debugging stuck-anchor reports.
        -- Stashed on the addon table so it survives the rest of the slash
        -- handler and is /dump-able from chat (/dump LEANC._lastResetSnapshot).
        -- Also appended to ns.LogBuffer with a fixed marker line so it shows
        -- up in /lea status-style scans even when debug mode is off.
        local snap = ns.SnapshotAnchorState and ns.SnapshotAnchorState() or nil
        self._lastResetSnapshot = snap
        if ns.LogBuffer and snap then
            ns.LogBuffer[#ns.LogBuffer + 1] = string.format(
                "[%0.2f] [RESET] /lea reset invoked — pre-reset snapshot saved (items=%d savedState=%d pending=%d errored=%d isAnchoring=%s)",
                debugprofilestop(),
                #snap.items,
                (function() local n=0 for _ in pairs(snap.savedState)    do n=n+1 end return n end)(),
                (function() local n=0 for _ in pairs(snap.pendingFrames) do n=n+1 end return n end)(),
                #snap.erroredFrames,
                tostring(snap.flags.isAnchoring))
        end
        ns.lpmsg("Reset: snapshot saved to LEANC._lastResetSnapshot. Reinitializing...")

        -- Full reset: restore every anchored source back to its saved
        -- points, wipe pending/errored frame tracking, cancel the retry
        -- ticker, and clear the re-entrancy/debounce flags so a stuck
        -- ParseAnchors state can recover. Then re-run setup, which
        -- captures fresh saved state and re-anchors from current
        -- destination positions.
        if ns.StopAllAnchors      then ns.StopAllAnchors()      end
        if ns.StopAllCustomEvents then ns.StopAllCustomEvents() end
        ns.SetupAddon(self)
    elseif arg == "status" then
        ns.PrintAnchorStatus(self)
    elseif arg == "dump" then
        if ns.ShowAnchorDump then
            ns.ShowAnchorDump()
        else
            ns.lpmsg("Dump UI not available.")
        end
    elseif arg == "debug" or arg:sub(1, 5) == "debug" then
        local sub = arg:match("debug%s+(%S+)")
        if sub then
            self.db.profile.debug = (sub == "off") and false or sub
        else
            local cur = self.db.profile.debug
            self.db.profile.debug = (not cur and "on") or (cur == "on" and "full") or false
        end
        ns.UpdateDebugMode()
        local d = self.db.profile.debug
        local status = (d == "on" and "|cff00ff00ON|r") or (d == "full" and "|cff00ff00FULL|r") or "|cffff0000OFF|r"
        ns.lpmsg("Debug: " .. status)
    else
        ns.lpmsg("Commands: config | reset | status | dump | debug [on|full|off]")
    end
end
