-- utils.lua
-- Small shared helpers used across LECONT modules.

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

function ns.lpmsg(msg, category)
    local isDebug = (category == "DEBUG")
    local rawDebug = ns.DEBUG or (LECONT and LECONT.db and LECONT.db.profile.debug)
    local debugMode = (rawDebug == true) and "on" or rawDebug

    if isDebug then
        if debugMode == "full" then
            print("|cffff9900[LECONT]|r " .. tostring(msg))
        end
    else
        print("|cff00fbffLECONT:|r " .. tostring(msg))
    end

    if not debugMode then return end

    local entry = string.format("[%0.2f] [%s] %s", debugprofilestop(), category or "INFO", tostring(msg))
    table.insert(ns.LogBuffer, entry)
    if #ns.LogBuffer > 3000 then table.remove(ns.LogBuffer, 1) end
end

-- -------------------------------------------------- --
--  Frame lookup                                      --
-- -------------------------------------------------- --

-- Resolve a frame name (string) to its global frame, or nil.
-- Stage 1: simple _G[name] only. Future stages may add CDM_/dummy lookups
-- like LeakyAuras' SafeGetFrame.
function ns.SafeGetFrame(name)
    if not name or type(name) ~= "string" or name == "" then return nil end
    if name == "UIParent" then return UIParent end
    return _G[name]
end
