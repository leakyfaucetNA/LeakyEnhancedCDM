-- anchors.lua
-- Frame anchoring engine. Ported from LeakyAuras with namespace adjustments.
-- Anchoring frames can taint the anchored frame and cause Blocked errors —
-- mitigations are in place but not 100% reliable on protected frames.

local _, ns = ...

local pairs, ipairs, wipe = pairs, ipairs, wipe
local math_floor = math.floor
local string_format = string.format
local LibStub    = LibStub

-- Debug-gated formatter. Skips both the string.format call and the
-- ns.lpmsg dispatch when debug mode is off, which keeps the per-item
-- ParseAnchors loop branch-free on the hot path.
local function dlog(fmt, ...)
    if not ns.debug then return end
    if select("#", ...) > 0 then
        ns.lpmsg(string_format(fmt, ...), "DEBUG")
    else
        ns.lpmsg(fmt, "DEBUG")
    end
end

-- State
local isAnchoring = false

-- Frames that have already had reparse hooks installed (SetPoint /
-- OnSizeChanged). Used by both source-frame hooking (SetupAnchors) and
-- destination-frame hooking (safe anchors, installed inside ParseAnchors).
local hookedSizeChanged = {}
local hookedDestSetPoint = {}

-- Frames that failed resolution during ParseAnchors — watched by a CreateFrame
-- hook so we can re-anchor when the target's owning addon creates them.
-- Values are GetTime() timestamps; entries expire after PENDING_TTL seconds.
local pendingFrames = {}
local pendingAnchorRefresh = false
local PENDING_TTL = 60
local PENDING_RETRY_INTERVAL = 2
local pendingRetryTicker = nil
-- Frames we've already shown a user-visible "unresolved" error for. Cleared
-- when the frame eventually resolves, so a fresh failure later prints again.
local erroredFrames = {}

-- Set to true whenever ParseAnchors bails on InCombatLockdown. A dedicated
-- frame listens for PLAYER_REGEN_ENABLED and re-runs ParseAnchors if this
-- flag is set, so a dest that moved during combat (and would otherwise
-- leave the source pinned to its pre-combat position) gets re-anchored as
-- soon as the player drops out of combat lockdown.
local combatDeferred = false
local combatEndFrame = CreateFrame("Frame")
combatEndFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
combatEndFrame:SetScript("OnEvent", function()
    if not combatDeferred then return end
    combatDeferred = false
    ns.ParseAnchors()
end)

-- A frame is "anchor-usable" when it has either a parent or a position. Some
-- addons reparent their frames to nil (dead state) but leave the global ref;
-- SafeGetFrame returns truthy for those, which would let us anchor source to
-- a ghost frame. Treat such frames as missing.
local function IsAnchorTargetUsable(frame)
    if not frame then return false end
    if type(frame) ~= "table" then return false end
    if not frame.GetLeft or not frame.GetParent then return false end
    if frame:GetParent() or frame:GetLeft() then return true end
    return false
end

local function ScheduleParseAnchors(delay)
    if pendingAnchorRefresh then return end
    pendingAnchorRefresh = true
    C_Timer.After(delay or 0.2, function()
        pendingAnchorRefresh = false
        ns.ParseAnchors()
    end)
end

-- Drop a pending entry and surface a user-visible error (once per frame).
local function ExpirePendingFrame(frameName)
    pendingFrames[frameName] = nil
    if erroredFrames[frameName] then return end
    erroredFrames[frameName] = true
    ns.lpmsg("Anchors: could not resolve frame '" .. frameName
        .. "' after " .. PENDING_TTL
        .. "s — check the frame name or ensure its owning addon is loaded.")
end

-- Periodic retry. The CreateFrame hook below catches frames created after our
-- first attempt, but doesn't fire for frames that already exist but aren't
-- yet "usable" (e.g. created but not parented/positioned). The ticker polls
-- those at PENDING_RETRY_INTERVAL while anything is pending, and self-cancels
-- when the queue empties.
local function StartPendingRetryLoop()
    if pendingRetryTicker then return end
    if not next(pendingFrames) then return end
    pendingRetryTicker = C_Timer.NewTicker(PENDING_RETRY_INTERVAL, function()
        if not next(pendingFrames) then
            if pendingRetryTicker then pendingRetryTicker:Cancel() end
            pendingRetryTicker = nil
            return
        end
        local now = GetTime()
        for frameName, ts in pairs(pendingFrames) do
            if now - ts > PENDING_TTL then
                ExpirePendingFrame(frameName)
            else
                local f = ns.SafeGetFrame(frameName)
                if IsAnchorTargetUsable(f) then
                    ScheduleParseAnchors(0.1)
                    return
                end
            end
        end
    end)
end

hooksecurefunc("CreateFrame", function(_, name)
    if name and pendingFrames[name] then
        if GetTime() - pendingFrames[name] > PENDING_TTL then
            ExpirePendingFrame(name)
            return
        end
        dlog("Anchors: pending frame '%s' just created", name)
        pendingFrames[name] = nil
        ScheduleParseAnchors(0.2)
    end
end)

-- Saved original anchor state per frame name; restored on spec switch or when
-- an anchor item is disabled/removed.
local savedState = {}

local function SaveFrameState(frameName, frame)
    if savedState[frameName] then return end
    local state = { points = {} }
    local n = frame:GetNumPoints()
    for i = 1, n do
        local point, relTo, relPoint, x, y = frame:GetPoint(i)
        state.points[i] = { point, relTo, relPoint, x, y }
    end
    state.parent = frame:GetParent()
    state.width  = math_floor(frame:GetWidth() + 0.5)
    savedState[frameName] = state
end

local function RestoreFrameState(frameName)
    local state = savedState[frameName]
    if not state then return end
    local frame = ns.SafeGetFrame(frameName)
    if not frame then
        savedState[frameName] = nil
        return
    end

    -- Restore best-effort: clear all current points, then re-apply each saved
    -- point individually, skipping any whose relTo is a dead frame ref. If
    -- every saved point ends up skipped, fall back to anchoring at UIParent
    -- CENTER so the source frame doesn't end up unanchored & invisible.
    -- (Old logic aborted the entire restore on the first dead point, which
    -- left the source stuck in its anchored-to-dead-dest state when the user
    -- disabled the anchor.)
    frame:ClearAllPoints()
    local applied = 0
    for _, pt in ipairs(state.points) do
        local relTo = pt[2]
        local relToDead = relTo and type(relTo) == "table" and relTo.GetLeft
            and not relTo:GetLeft() and not relTo:GetParent()
        if not relToDead then
            frame:SetPoint(pt[1], pt[2], pt[3], pt[4], pt[5])
            applied = applied + 1
        end
    end
    if applied == 0 then
        dlog("Anchors: all saved points for '%s' had dead targets — falling back to UIParent CENTER", frameName)
        frame:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    end
    if state.parent then frame:SetParent(state.parent) end
    if state.width  then frame:SetWidth(state.width)   end
    savedState[frameName] = nil
end

-- Resolve our addon table lazily — module files load before main.lua.
local _LEANC
local function GetAddon()
    _LEANC = _LEANC or LibStub("AceAddon-3.0"):GetAddon("LEAnchors")
    return _LEANC
end

-- Install reparse hooks on a destination frame for safe-anchor items.
-- Safe anchors compute a one-shot UIParent position from dFrame:GetRect(),
-- so unlike a regular SetPoint(_, dest, _) anchor the source doesn't follow
-- when the destination moves or resizes. This is especially noticeable on
-- initial login when other addons defer their final layout pass: we anchor
-- to the temporary position, then never recompute when the dest settles.
-- Idempotent — safe to call repeatedly across ParseAnchors passes.
local function HookDestForSafeAnchor(frame)
    if not frame or type(frame) ~= "table" then return end
    -- Hook policy: install unconditionally (subject only to per-frame
    -- dedup so we don't accumulate hooks across ParseAnchors passes).
    -- No IsProtected bail, no addon:IsHooked bail, no isAnchoring bail
    -- in the callback. The only suppression is downstream in ParseAnchors,
    -- which respects InCombatLockdown. ScheduleParseAnchors debounces so
    -- SetPoint storms during init/gameplay coalesce into one re-parse.
    local addon = GetAddon()
    if frame.SetPoint and not hookedDestSetPoint[frame] then
        hookedDestSetPoint[frame] = true
        addon:SecureHook(frame, "SetPoint", function()
            ScheduleParseAnchors(0.05)
        end)
    end
    if not hookedSizeChanged[frame] then
        hookedSizeChanged[frame] = true
        frame:HookScript("OnSizeChanged", function()
            ScheduleParseAnchors(0.05)
        end)
    end
end

-- Anchor-point → (x,y) offset table. Used by safe-anchor mode which
-- translates a SetPoint(sPoint, dFrame, dPoint, x, y) call into a pure
-- BOTTOMLEFT/UIParent positioning that can't taint the target frame.
local function GetAnchorOffset(width, height, anchorPoint)
    local x, y = 0, 0
    if anchorPoint:find("RIGHT") then x = width
    elseif anchorPoint:find("LEFT") then x = 0
    else x = width / 2 end

    if anchorPoint:find("TOP") then y = height
    elseif anchorPoint:find("BOTTOM") then y = 0
    else y = height / 2 end
    return x, y
end

-- Apply an anchor. force=true (or sFrame protected) uses safe mode which
-- positions purely via UIParent BOTTOMLEFT to avoid taint propagation.
function ns.DoAnchor(sFrame, sPoint, dFrame, dPoint, xOffset, yOffset, force)
    if not sFrame or not dFrame then return end

    if force then
        local dLeft, dBottom, dWidth, dHeight = dFrame:GetRect()
        if not dLeft then return end

        local dOffsetX, dOffsetY = GetAnchorOffset(dWidth, dHeight, dPoint)
        local targetX = dLeft + dOffsetX
        local targetY = dBottom + dOffsetY

        local sWidth, sHeight = sFrame:GetSize()
        local sOffsetX, sOffsetY = GetAnchorOffset(sWidth, sHeight, sPoint)

        local finalX = (targetX - sOffsetX + xOffset)
        local finalY = (targetY - sOffsetY + yOffset)

        -- Convert from destination's scale into UIParent's scale.
        local dScale = dFrame:GetEffectiveScale()
        local uScale = UIParent:GetEffectiveScale()
        finalX = finalX * (dScale / uScale)
        finalY = finalY * (dScale / uScale)

        sFrame:ClearAllPoints()
        sFrame:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", finalX, finalY)
        dlog("Anchors: Anchored %s (safe)", sFrame:GetName() or "?")
    else
        sFrame:ClearAllPoints()
        sFrame:SetPoint(sPoint, dFrame, dPoint, xOffset, yOffset)
        dlog("Anchors: Anchored %s (regular)", sFrame:GetName() or "?")
    end
end

-- Iterate enabled anchor items and apply each. Restores any previously-
-- anchored source frame that's no longer covered by an active item.
-- Iterate every anchor item across both stores (profile + global). Yields
-- (itemID, data) pairs — itemIDs are namespaced enough that profile/global
-- don't collide in practice but the engine treats them by lookup, not key.
-- Used by SetupAnchors (cold path); ParseAnchors uses ProcessAnchorStore
-- directly to avoid the coroutine allocation on the hot path.
local function IterateAnchorItems(addonDB)
    local profileItems = addonDB and addonDB.profile and addonDB.profile.items or {}
    local globalItems  = addonDB and addonDB.global  and addonDB.global.items  or {}
    return coroutine.wrap(function()
        for itemID, data in pairs(profileItems) do
            if data.type == "anchor" then coroutine.yield(itemID, data) end
        end
        for itemID, data in pairs(globalItems) do
            if data.type == "anchor" then coroutine.yield(itemID, data) end
        end
    end)
end

-- Apply one anchor item's effects. Pulled out of ParseAnchors so the per-
-- item pcall passes a function reference (zero-alloc) instead of building
-- a fresh closure with five upvalues every iteration. With 20–50 anchors
-- and ParseAnchors re-running on every dest SetPoint during init, that
-- closure churn was the largest hot-path cost.
local function ApplyAnchorItem(itemID, data, activeFrames, claimed)
    local source = ns.SafeGetFrame(data.sourceFrame)
    local dest   = ns.SafeGetFrame(data.destFrame)

    local now = GetTime()
    if not source and data.sourceFrame and data.sourceFrame ~= "" then
        pendingFrames[data.sourceFrame] = pendingFrames[data.sourceFrame] or now
    end
    if not dest and data.destFrame and data.destFrame ~= "" then
        pendingFrames[data.destFrame] = pendingFrames[data.destFrame] or now
    end

    -- Require both frames to be usable (alive + positioned). Without this,
    -- anchoring to a dead/reparented frame leaves the source at (0, 0) or
    -- off-screen — visually "disappeared".
    if not IsAnchorTargetUsable(source) or not IsAnchorTargetUsable(dest) then
        dlog("Anchors: '%s' — source or dest not usable, skipping apply", data.name or itemID)
        return
    end

    SaveFrameState(data.sourceFrame, source)
    activeFrames[data.sourceFrame] = true
    claimed[data.sourceFrame]      = true

    ns.DoAnchor(source,
        data.sourcePoint or "CENTER",
        dest,
        data.destPoint   or "CENTER",
        data.xOffset or 0,
        data.yOffset or 0,
        data.safeAnchor)

    -- Safe anchors don't follow dest movement automatically. Hook the dest
    -- so we recompute when its owning addon finishes its deferred layout
    -- pass (the common cause of "off-screen on first login, fine after
    -- /reload").
    if data.safeAnchor then
        HookDestForSafeAnchor(dest)
    end

    if data.setParent then source:SetParent(dest) end

    if data.matchWidth then
        if data.widthMethod == "twopoint" then
            local vert = data.tpAnchorVertical or "CENTER"
            local lPoint, rPoint
            if     vert == "TOP"    then lPoint, rPoint = "TOPLEFT",    "TOPRIGHT"
            elseif vert == "BOTTOM" then lPoint, rPoint = "BOTTOMLEFT", "BOTTOMRIGHT"
            else                         lPoint, rPoint = "LEFT",       "RIGHT" end
            local lOff, rOff = data.leftOffset or 0, data.rightOffset or 0
            local yOff       = data.yOffset or 0
            source:ClearAllPoints()
            source:SetPoint("LEFT",  dest, lPoint, lOff, yOff)
            source:SetPoint("RIGHT", dest, rPoint, rOff, yOff)
        else
            local refFrame = dest
            if data.widthMode == "CUSTOM" and data.widthCustomFrame and data.widthCustomFrame ~= "" then
                refFrame = ns.SafeGetFrame(data.widthCustomFrame) or dest
            end
            if not data.originalWidth then
                data.originalWidth = math_floor(source:GetWidth() + 0.5)
            end
            local targetWidth = refFrame:GetWidth() + (data.widthOffset or 0)
            if targetWidth > 1 then source:SetWidth(targetWidth) end
        end
    elseif data.originalWidth then
        source:SetWidth(data.originalWidth)
        data.originalWidth = nil
    end
end

-- Process one items store (profile or global). Walks pairs() directly and
-- pcalls ApplyAnchorItem by reference — no per-iteration closure alloc.
local function ProcessAnchorStore(items, addonDB, activeFrames, claimed)
    if not items then return end
    for itemID, data in pairs(items) do
        if data.type == "anchor" then
            local enabled    = data.enabled ~= false
            local shouldLoad = enabled and ns.ShouldLoadItemTable(addonDB, data)
            if ns.debug then
                dlog("Anchors: '%s' enabled=%s shouldLoad=%s src=%s dst=%s",
                    data.name or itemID, tostring(enabled), tostring(shouldLoad),
                    data.sourceFrame or "?", data.destFrame or "?")
            end

            if shouldLoad and data.sourceFrame and claimed[data.sourceFrame] then
                dlog("Anchors: '%s' — source already claimed this pass, skipping",
                    data.name or itemID)
                shouldLoad = false
            end

            if shouldLoad then
                local ok, err = pcall(ApplyAnchorItem, itemID, data, activeFrames, claimed)
                if not ok then
                    dlog("Anchors: error applying [%s]: %s", data.name or itemID, tostring(err))
                end
            end
        end
    end
end

function ns.ParseAnchors()
    if InCombatLockdown() then
        -- Remember that a parse was wanted; combatEndFrame will re-fire us
        -- when PLAYER_REGEN_ENABLED hits so dests that moved during combat
        -- get reconciled.
        combatDeferred = true
        return
    end
    local addonDB = GetAddon().db
    if not addonDB then return end

    if isAnchoring then return end
    isAnchoring = true

    local activeFrames = {}
    -- Source-frame claim set. First anchor to apply to a given source wins;
    -- subsequent anchors targeting the same source are skipped this pass.
    -- Profile (per-character) items are processed before global items, so
    -- CHAR anchors implicitly take precedence over GLOBAL anchors on
    -- conflict — the right behavior when a character has a more-specific
    -- override of an account-wide default.
    local claimed = {}

    ProcessAnchorStore(addonDB.profile and addonDB.profile.items, addonDB, activeFrames, claimed)
    ProcessAnchorStore(addonDB.global  and addonDB.global.items,  addonDB, activeFrames, claimed)

    -- Restore frames no longer covered by any active anchor item.
    for frameName in pairs(savedState) do
        if not activeFrames[frameName] then
            dlog("Anchors: restoring '%s'", frameName)
            RestoreFrameState(frameName)
        end
    end

    isAnchoring = false

    -- A frame that successfully anchored this pass shouldn't keep its
    -- "errored" mark — if it ever goes missing again later, the user should
    -- see a fresh error.
    for frameName in pairs(activeFrames) do
        erroredFrames[frameName] = nil
    end

    -- Expire stale pending entries (TTL elapsed) and surface a user-visible
    -- error for each so the user knows the anchor is silently inactive.
    local now = GetTime()
    for frameName, ts in pairs(pendingFrames) do
        if now - ts > PENDING_TTL then
            ExpirePendingFrame(frameName)
        end
    end

    -- Keep polling while anything is still pending.
    StartPendingRetryLoop()
end

function ns.SetupAnchors(addon)
    wipe(pendingFrames)
    wipe(erroredFrames)
    if pendingRetryTicker then
        pendingRetryTicker:Cancel()
        pendingRetryTicker = nil
    end

    -- Run once now for immediate position, then again on a small schedule of
    -- deferred passes to catch other addons (ElvUI / CDM / ArcUI etc.) that
    -- only finalize their frame positions late in their own init cycle. The
    -- dest-side SetPoint hook (HookDestForSafeAnchor) is the primary safety
    -- net, but protected frames and frames already hooked by other addons
    -- can't be hooked by us — these retries cover that case.
    ns.ParseAnchors()
    C_Timer.After(0.5, ns.ParseAnchors)
    C_Timer.After(1,   ns.ParseAnchors)
    C_Timer.After(2,   ns.ParseAnchors)
    C_Timer.After(5,   ns.ParseAnchors)

    if not addon.db then return end

    for itemID, data in IterateAnchorItems(addon.db) do
        if data.enabled and ns.ShouldLoadItemTable(addon.db, data) and data.sourceFrame then
            local frame = ns.SafeGetFrame(data.sourceFrame)
            if frame and frame.SetPoint and not addon:IsHooked(frame, "SetPoint") then
                local isProtected = frame.IsProtected and frame:IsProtected()
                if not isProtected then
                    addon:SecureHook(frame, "SetPoint", function()
                        if isAnchoring then return end
                        ns.ParseAnchors()
                    end)
                    if data.matchWidth and not addon:IsHooked(frame, "SetWidth") then
                        addon:SecureHook(frame, "SetWidth", function()
                            if isAnchoring then return end
                            ns.ParseAnchors()
                        end)
                    end
                end
            end

            if data.matchWidth then
                local refName = (data.widthMode == "CUSTOM" and data.widthCustomFrame ~= "")
                    and data.widthCustomFrame or data.destFrame
                local refFrame = ns.SafeGetFrame(refName)
                if refFrame and not hookedSizeChanged[refFrame] then
                    hookedSizeChanged[refFrame] = true
                    refFrame:HookScript("OnSizeChanged", function()
                        if isAnchoring then return end
                        ns.ParseAnchors()
                    end)
                end
            end
        end
    end
end

function ns.StopAllAnchors()
    -- Restore every frame we've touched, then drop saved state.
    for frameName in pairs(savedState) do
        RestoreFrameState(frameName)
    end
    wipe(savedState)
    wipe(pendingFrames)
    wipe(erroredFrames)
    if pendingRetryTicker then
        pendingRetryTicker:Cancel()
        pendingRetryTicker = nil
    end
    -- Reset re-entrancy / debounce flags. A previous pass that errored
    -- mid-way could leave isAnchoring stuck true, which silently turns
    -- every subsequent ParseAnchors into a no-op. /lea reset routes
    -- through here to recover from that case.
    isAnchoring          = false
    pendingAnchorRefresh = false
    combatDeferred       = false
end

-- Snapshot the engine state for post-reset debugging. Returns a plain table
-- safe to /dump or serialize. Captures the bits that explain *why* an anchor
-- might be stuck: re-entrancy flags, what's pending/errored, which frames are
-- hooked, and per-item load + frame-existence + rect info.
function ns.SnapshotAnchorState()
    local snap = {
        timestamp = GetTime(),
        date      = date and date("%Y-%m-%d %H:%M:%S") or "?",
        flags     = {
            isAnchoring          = isAnchoring,
            pendingAnchorRefresh = pendingAnchorRefresh,
            combatDeferred       = combatDeferred,
            inCombat             = InCombatLockdown(),
            retryTickerActive    = pendingRetryTicker ~= nil,
        },
        savedState    = {},
        pendingFrames = {},
        erroredFrames = {},
        hooked        = { setPoint = {}, onSize = {} },
        items         = {},
    }

    for name, st in pairs(savedState) do
        snap.savedState[name] = {
            parent = (st.parent and st.parent.GetName and st.parent:GetName()) or tostring(st.parent),
            width  = st.width,
            points = st.points,
        }
    end

    local now = GetTime()
    for name, ts in pairs(pendingFrames) do
        snap.pendingFrames[name] = { firstSeen = ts, ageSec = now - ts }
    end
    for name in pairs(erroredFrames) do
        snap.erroredFrames[#snap.erroredFrames + 1] = name
    end

    for f in pairs(hookedDestSetPoint) do
        snap.hooked.setPoint[#snap.hooked.setPoint + 1] =
            (type(f) == "table" and f.GetName and f:GetName()) or tostring(f)
    end
    for f in pairs(hookedSizeChanged) do
        snap.hooked.onSize[#snap.hooked.onSize + 1] =
            (type(f) == "table" and f.GetName and f:GetName()) or tostring(f)
    end

    local addonDB = GetAddon().db
    if addonDB then
        local function dumpStore(label, store)
            if not store then return end
            for itemID, data in pairs(store) do
                if data.type == "anchor" then
                    local source = ns.SafeGetFrame(data.sourceFrame)
                    local dest   = ns.SafeGetFrame(data.destFrame)
                    local entry  = {
                        scope        = label,
                        itemID       = itemID,
                        name         = data.name or itemID,
                        enabled      = data.enabled ~= false,
                        shouldLoad   = ns.ShouldLoadItemTable(addonDB, data),
                        sourceFrame  = data.sourceFrame,
                        destFrame    = data.destFrame,
                        safeAnchor   = data.safeAnchor and true or false,
                        sourceExists = source ~= nil,
                        destExists   = dest ~= nil,
                    }
                    if source and source.GetRect then
                        local l, b, w, h = source:GetRect()
                        if l then entry.sourceRect = { left = l, bottom = b, width = w, height = h } end
                    end
                    if dest and dest.GetRect then
                        local l, b, w, h = dest:GetRect()
                        if l then entry.destRect = { left = l, bottom = b, width = w, height = h } end
                    end
                    snap.items[#snap.items + 1] = entry
                end
            end
        end
        dumpStore("CHAR",   addonDB.profile and addonDB.profile.items)
        dumpStore("GLOBAL", addonDB.global  and addonDB.global.items)
    end

    return snap
end

-- /lea status — print every anchor's current state to chat: which scope it
-- lives in, whether it's enabled, whether ShouldLoad currently passes given
-- this character's class/spec, and the saved load conditions.
function ns.PrintAnchorStatus(addon)
    local _, classToken = UnitClass("player")
    local specIdx = GetSpecialization and GetSpecialization()
    local specID  = specIdx and GetSpecializationInfo and GetSpecializationInfo(specIdx) or 0
    print(string.format("|cff00fbffLEANC:|r status — class=%s specID=%s", classToken or "?", tostring(specID)))

    local function dumpStore(label, store)
        if not store then return end
        for itemID, data in pairs(store) do
            if data.type == "anchor" then
                local enabled  = data.enabled ~= false
                local should   = enabled and ns.ShouldLoadItemTable(addon.db, data)
                local lc       = data.loadConditions or {}
                local specList = {}
                if lc.specIDs then
                    for sid in pairs(lc.specIDs) do specList[#specList + 1] = tostring(sid) end
                end
                local lcStr = string.format("class=%s specs=[%s] inCombat=%s",
                    tostring(lc.class), table.concat(specList, ","), tostring(lc.inCombat))
                print(string.format(
                    "  [%s] '%s' enabled=%s shouldLoad=%s src=%s dst=%s lc={%s}",
                    label, data.name or itemID, tostring(enabled), tostring(should),
                    data.sourceFrame or "?", data.destFrame or "?", lcStr))
            end
        end
    end
    dumpStore("CHAR",   addon.db.profile.items)
    dumpStore("GLOBAL", addon.db.global  and addon.db.global.items)
end
