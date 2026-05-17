-- utils.lua
-- Shared helpers used across LEAnchors modules.

local _, ns = ...

-- -------------------------------------------------- --
--  UID generator                                     --
-- -------------------------------------------------- --

local uidCounter = 0
function ns.GenerateUID()
    uidCounter = uidCounter + 1
    return tostring(time()) .. "_" .. uidCounter
end

-- -------------------------------------------------- --
--  Logger                                            --
-- -------------------------------------------------- --

ns.LogBuffer = {}

-- Cached debug mode. Hot-path callers branch on this upvalue instead of
-- chasing LEANC.db.profile.debug each time, and the build-the-string cost
-- at DEBUG call sites can be skipped entirely when this is nil.
-- Values: nil (off), "on" (record + non-DEBUG prints), "full" (also prints DEBUG).
ns.debug = nil

function ns.UpdateDebugMode()
    local raw = ns.DEBUG or (LEANC and LEANC.db and LEANC.db.profile.debug)
    ns.debug = ((raw == true) and "on") or raw or nil
end

function ns.lpmsg(msg, category)
    local mode = ns.debug
    local isDebug = (category == "DEBUG")

    if isDebug then
        if mode == "full" then
            print("|cffff9900[LEANC]|r " .. tostring(msg))
        end
    else
        print("|cff00fbffLEANC:|r " .. tostring(msg))
    end

    if not mode then return end

    local entry = string.format("[%0.2f] [%s] %s", debugprofilestop(), category or "INFO", tostring(msg))
    table.insert(ns.LogBuffer, entry)
    if #ns.LogBuffer > 3000 then table.remove(ns.LogBuffer, 1) end
end

-- -------------------------------------------------- --
--  Frame lookup                                      --
-- -------------------------------------------------- --

-- Resolve a frame name string to its global frame, or nil if not loaded.
-- Stage 1: just _G[name]. Future iterations may add CDM-style lookups.
function ns.SafeGetFrame(name)
    if not name or type(name) ~= "string" or name == "" then return nil end
    if name == "UIParent" then return UIParent end
    return _G[name]
end
