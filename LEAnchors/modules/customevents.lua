-- customevents.lua
-- User-defined trigger events. Each item subscribes to one or more WoW events,
-- evaluates a user-provided trigger function, and on success broadcasts a
-- user-named message via WeakAuras.ScanEvents + LEANC:SendMessage so other
-- addons / WeakAuras can react. Untrigger fires by timer or by a second
-- user function.
--
-- The display side (icons / sounds / textures) is NOT included here — those
-- are deferred to consumer addons (or future LEAnchors iterations). Keeping
-- this module focused on the trigger pipeline mirrors LECDM's events.lua
-- shape and avoids coupling to a textures module that doesn't yet exist.

local _, ns = ...

local string_format = string.format

-- Debug-gated formatter. Skips string.format and the lpmsg dispatch when
-- debug is off so the OnEvent path stays cheap.
local function dlog(fmt, ...)
    if not ns.debug then return end
    if select("#", ...) > 0 then
        ns.lpmsg(string_format(fmt, ...), "DEBUG")
    else
        ns.lpmsg(fmt, "DEBUG")
    end
end

-- Active registrations: [itemID] = { itemID, triggerFn, untriggerFn,
--                                     timerHandle, active, item }
local activeEvents = {}

-- Event-keyed dispatch tables. Built once in SetupCustomEvents — OnEvent
-- looks up [event] and walks only the regs that actually subscribe. This
-- avoids the prior O(N) scan over every activeEvents entry per event tick
-- (which mattered for noisy events like COMBAT_LOG_EVENT_UNFILTERED).
local triggerIndex   = {}
local untriggerIndex = {}

local eventFrame = CreateFrame("Frame")

-- -------------------------------------------------- --
--  String helpers                                    --
-- -------------------------------------------------- --

local function SplitCSV(str)
    local out = {}
    if not str or str == "" then return out end
    for tok in str:gmatch("[^,]+") do
        local trimmed = tok:match("^%s*(.-)%s*$")
        if trimmed ~= "" then out[#out + 1] = trimmed end
    end
    return out
end

-- Compile a user-provided Lua function source. Expects code that evaluates to
-- a `function(event, ...) ... return bool end`. Returns the function or nil
-- + error string for diagnostics.
local function CompileFunc(code)
    if not code or code == "" then return nil end
    local fn, err = loadstring("return " .. code)
    if not fn then return nil, err end
    local ok, result = pcall(fn)
    if not ok then return nil, result end
    if type(result) ~= "function" then return nil, "Code must return a function" end
    return result
end

-- -------------------------------------------------- --
--  Broadcast helpers                                 --
-- -------------------------------------------------- --

local function FireBroadcast(messageName, ...)
    if not messageName or messageName == "" then return end
    dlog("CustomEvent FIRE: %s", messageName)
    if WeakAuras and WeakAuras.ScanEvents then
        WeakAuras.ScanEvents(messageName, ...)
    end
    if M33kAuras and M33kAuras.ScanEvents then
        M33kAuras.ScanEvents(messageName, ...)
    end
    if LEANC and LEANC.SendMessage then
        LEANC:SendMessage(messageName, ...)
    end
end

-- -------------------------------------------------- --
--  Trigger / untrigger flow                          --
-- -------------------------------------------------- --

local function FireTrigger(reg, item, itemID, event, ...)
    if reg.active then return end
    reg.active = true
    FireBroadcast(item.messageName or item.name or itemID, event, ...)
    dlog("CustomEvent ACTIVATE: %s", item.name or itemID)
end

local function FireUntrigger(reg, item, itemID)
    if not reg.active then return end
    reg.active = false
    local untriggerName = item.untriggerMessageName
    if untriggerName and untriggerName ~= "" then
        FireBroadcast(untriggerName)
    end
    dlog("CustomEvent DEACTIVATE: %s", item.name or itemID)
end

local function StartUntrigger(reg, item, itemID)
    local mode = item.untriggerMode or "timer"
    if mode == "timer" then
        local duration = tonumber(item.untriggerTimer) or 5
        if reg.timerHandle then reg.timerHandle:Cancel() end
        reg.timerHandle = C_Timer.NewTimer(duration, function()
            reg.timerHandle = nil
            FireUntrigger(reg, item, itemID)
        end)
    end
    -- mode == "function" is handled inline in OnEvent below
end

local function OnEvent(_, event, ...)
    local triggers = triggerIndex[event]
    if triggers then
        for i = 1, #triggers do
            local reg  = triggers[i]
            local item = reg.item
            if item and reg.triggerFn then
                local ok, result = pcall(reg.triggerFn, event, ...)
                if ok and result then
                    FireTrigger(reg, item, reg.itemID, event, ...)
                    StartUntrigger(reg, item, reg.itemID)
                elseif not ok then
                    dlog("CustomEvent '%s' trigger error: %s",
                        item.name or reg.itemID, tostring(result))
                end
            end
        end
    end

    -- Function-mode untrigger pass. Items only land in untriggerIndex when
    -- their untriggerMode is "function", so no mode check is needed here.
    local untriggers = untriggerIndex[event]
    if untriggers then
        for i = 1, #untriggers do
            local reg  = untriggers[i]
            local item = reg.item
            if item and reg.untriggerFn and reg.active then
                local ok, result = pcall(reg.untriggerFn, event, ...)
                if ok and result then
                    FireUntrigger(reg, item, reg.itemID)
                elseif not ok then
                    dlog("CustomEvent '%s' untrigger error: %s",
                        item.name or reg.itemID, tostring(result))
                end
            end
        end
    end
end
eventFrame:SetScript("OnEvent", OnEvent)

-- -------------------------------------------------- --
--  Setup / Teardown                                  --
-- -------------------------------------------------- --

local function TeardownAll()
    for _, reg in pairs(activeEvents) do
        if reg.timerHandle then reg.timerHandle:Cancel() end
    end
    eventFrame:UnregisterAllEvents()
    wipe(activeEvents)
    wipe(triggerIndex)
    wipe(untriggerIndex)
end

function ns.SetupCustomEvents(addon)
    TeardownAll()
    local items = addon.db.profile.items
    if not items then return end

    local registered = {}
    for itemID, item in pairs(items) do
        if item.type == "customEvent" and item.enabled ~= false and ns.ShouldLoadItem(addon.db, itemID) then
            local eventName = item.eventName
            if eventName and eventName ~= "" then
                local triggerFn, terr = CompileFunc(item.triggerFunc)
                if not triggerFn then
                    dlog("CustomEvent '%s' trigger compile error: %s", item.name or itemID, terr or "empty")
                end

                local untriggerFn
                if item.untriggerMode == "function" and item.untriggerFunc then
                    local uerr
                    untriggerFn, uerr = CompileFunc(item.untriggerFunc)
                    if not untriggerFn then
                        dlog("CustomEvent '%s' untrigger compile error: %s", item.name or itemID, uerr or "empty")
                    end
                end

                local triggerSet = {}
                for _, e in ipairs(SplitCSV(eventName)) do triggerSet[e] = true end

                local untriggerSet = {}
                if item.untriggerMode == "function" then
                    local s = item.untriggerEvent
                    if s and s ~= "" then
                        for _, e in ipairs(SplitCSV(s)) do untriggerSet[e] = true end
                    else
                        -- Default: same as trigger events
                        for e in pairs(triggerSet) do untriggerSet[e] = true end
                    end
                end

                local reg = {
                    itemID      = itemID,
                    item        = item,
                    triggerFn   = triggerFn,
                    untriggerFn = untriggerFn,
                    active      = false,
                }
                activeEvents[itemID] = reg

                for e in pairs(triggerSet) do
                    local bucket = triggerIndex[e]
                    if not bucket then
                        bucket = {}
                        triggerIndex[e] = bucket
                    end
                    bucket[#bucket + 1] = reg
                    if not registered[e] then
                        eventFrame:RegisterEvent(e)
                        registered[e] = true
                    end
                end
                for e in pairs(untriggerSet) do
                    local bucket = untriggerIndex[e]
                    if not bucket then
                        bucket = {}
                        untriggerIndex[e] = bucket
                    end
                    bucket[#bucket + 1] = reg
                    if not registered[e] then
                        eventFrame:RegisterEvent(e)
                        registered[e] = true
                    end
                end

                dlog("CustomEvent registered: %s on %s", item.name or itemID, eventName)
            end
        end
    end
end

function ns.StopAllCustomEvents()
    TeardownAll()
end

-- Iterate user-added custom event items for the settings UI list.
-- Returns ordered { itemID, item } sorted by name.
function ns.GetCustomEventList()
    local out = {}
    if not LEANC or not LEANC.db then return out end
    local items = LEANC.db.profile.items or {}
    for itemID, item in pairs(items) do
        if item.type == "customEvent" then
            out[#out + 1] = { itemID = itemID, item = item }
        end
    end
    table.sort(out, function(a, b) return (a.item.name or "") < (b.item.name or "") end)
    return out
end
