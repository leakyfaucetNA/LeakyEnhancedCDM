-- texts.lua
-- Stand-alone floating stack-count text per tracked aura item.
--
-- Aura stack count (auraData.applications) is a SECRET value in 12.0+ — we
-- can't read it, but we CAN pass it straight through to FontString:SetText
-- which displays it. This mirrors the trick ArcUI uses.
--
-- The text frame is parented to UIParent (never to the CDM pool frame — same
-- taint-avoidance pattern the glow overlay uses). Position is configured via
-- an anchor frame name + point/relativePoint/offset so the user can hang it
-- off any global frame.
--
-- item.texts = {
--   [uid] = {
--     name, enabled,
--     hideAtZero,           -- bool — hide when no aura active
--     anchorFrame,          -- global frame name, default "UIParent"
--     point, relativePoint, -- default "CENTER" / "CENTER"
--     x, y,                 -- offset in pixels
--     fontSize,             -- default 18
--     fontOutline,          -- default "OUTLINE"
--     rgba,                 -- {r,g,b,a}, default white
--   }
-- }

local _, ns = ...

local LSM = LibStub and LibStub("LibSharedMedia-3.0", true) or nil

-- [spellID] = { [itemID] = item } — items with at least one text config
local textItemLookup = {}

-- [stateKey] = FontString  (stateKey = spellID .. "_" .. itemID .. "_" .. uid)
local textFrames = {}

-- -------------------------------------------------- --
--  Font-string lifecycle                             --
-- -------------------------------------------------- --

-- Resolve the anchor frame the way glows do: number = spellID → look up live
-- CDM frame; string = global frame name; nil/empty = UIParent. Anchoring a
-- UIParent-parented FontString to a CDM frame is safe (same pattern glow
-- overlays use — we never parent to the CDM frame, only SetPoint to it).
local function ResolveAnchor(key)
    if not key or key == "" then return UIParent end

    if type(key) == "number" then
        for _, map in ipairs({ ns.auraFrameMap or {}, ns.cdFrameMap or {} }) do
            for _, entry in pairs(map) do
                if entry._lecSpellID == key and entry.frame and entry.frame.cooldownID then
                    return entry.frame
                end
            end
        end
        return UIParent
    end

    local g = _G[key]
    if type(g) == "table" and g.GetObjectType then return g end
    return UIParent
end

-- Create or reuse a FontString for this state key and reapply its config.
-- Always re-applies anchor/font so settings-panel tweaks take effect instantly.
local function EnsureTextFrame(stateKey, tc)
    local fs = textFrames[stateKey]
    if not fs then
        fs = UIParent:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
        fs:SetDrawLayer("OVERLAY", 7)
        textFrames[stateKey] = fs
    end

    -- Anchor
    fs:ClearAllPoints()
    fs:SetPoint(
        tc.point or "CENTER",
        ResolveAnchor(tc.anchorFrame),
        tc.relativePoint or "CENTER",
        tc.x or 0,
        tc.y or 0
    )

    -- Font: prefer an LSM-registered font by name, fall back to whatever the
    -- FontString inherited from its font object.
    local fontPath
    if tc.font and LSM then
        fontPath = LSM:Fetch("font", tc.font)
    end
    if not fontPath then fontPath = fs:GetFont() end
    if fontPath then
        fs:SetFont(fontPath, tc.fontSize or 18, tc.fontOutline or "OUTLINE")
    end

    local rgba = tc.rgba or {1, 1, 1, 1}
    fs:SetTextColor(rgba[1] or 1, rgba[2] or 1, rgba[3] or 1, rgba[4] or 1)

    return fs
end

-- -------------------------------------------------- --
--  Trigger dispatch                                  --
-- -------------------------------------------------- --

-- Called on aura added/updated — write the current stack count to each
-- configured text. Passing the secret `applications` value directly to SetText
-- displays it without tainting.
--
-- tc.showAsOne is a FALLBACK (not an override): many buffs don't report a
-- stack count at 1 but do once they reach 2+. When applications is present we
-- always show it through; when it's missing (nil) and the user opted in, we
-- display a literal "1" so a single-application aura still has a visible
-- indicator. The only interaction with auraData.applications is a truthy
-- check — no read, no compare, no arithmetic (all of which would taint a
-- secret number).
local function UpdateStack(spellID, unit, instanceID)
    local items = textItemLookup[spellID]
    if not items then return end
    local auraData = C_UnitAuras.GetAuraDataByAuraInstanceID(unit, instanceID)
    if not auraData then return end

    for itemID, item in pairs(items) do
        if type(item.texts) == "table" then
            for uid, tc in pairs(item.texts) do
                if tc.enabled ~= false then
                    local stateKey = tostring(spellID) .. "_" .. itemID .. "_" .. uid
                    local fs = EnsureTextFrame(stateKey, tc)
                    if auraData.applications then
                        -- SetText accepts numbers (including secret numbers);
                        -- the linter's signature is stale. NEVER coerce with
                        -- tostring — that would taint.
                        ---@diagnostic disable-next-line: param-type-mismatch
                        fs:SetText(auraData.applications)
                        fs:Show()
                    elseif tc.showAsOne then
                        fs:SetText("1")
                        fs:Show()
                    end
                end
            end
        end
    end
end

-- Called on aura removed (when no instances remain for the spell). hideAtZero
-- decides whether the text vanishes or displays "0".
local function ClearStack(spellID)
    local items = textItemLookup[spellID]
    if not items then return end
    for itemID, item in pairs(items) do
        if type(item.texts) == "table" then
            for uid, tc in pairs(item.texts) do
                local stateKey = tostring(spellID) .. "_" .. itemID .. "_" .. uid
                local fs = textFrames[stateKey]
                if fs then
                    if tc.hideAtZero then
                        fs:Hide()
                    else
                        fs:SetText("0")
                        EnsureTextFrame(stateKey, tc)  -- refresh anchor/font
                        fs:Show()
                    end
                end
            end
        end
    end
end

-- -------------------------------------------------- --
--  AuraTracker callbacks                             --
-- -------------------------------------------------- --

local function OnAuraAdded(unit, instanceID, spellID)
    if unit ~= "player" then return end
    UpdateStack(spellID, unit, instanceID)
end

local function OnAuraUpdated(unit, instanceID, spellID)
    if unit ~= "player" then return end
    UpdateStack(spellID, unit, instanceID)
end

local function OnAuraRemoved(unit, _, spellID)
    if unit ~= "player" then return end
    if ns.reverseLookup and ns.reverseLookup[spellID] then
        -- Another instance of the same spell is still active — do nothing here.
        -- ADDED/UPDATED for the remaining instance will keep the display correct.
        return
    end
    ClearStack(spellID)
end

-- -------------------------------------------------- --
--  Setup / Teardown                                  --
-- -------------------------------------------------- --

local function BuildTextItemLookup(db)
    local lookup = {}
    for itemID, item in pairs(db.profile.items) do
        if item.texts and ns.ShouldLoadItem(db, itemID) then
            local spellID = item.spellID
            if spellID then
                lookup[spellID] = lookup[spellID] or {}
                lookup[spellID][itemID] = item
            end
        end
    end
    return lookup
end

function ns.SetupTexts(addon)
    ns.lpmsg("Lifecycle: SetupTexts", "DEBUG")
    ns.StopAllTexts()

    textItemLookup = BuildTextItemLookup(addon.db)
    if not next(textItemLookup) then
        ns.lpmsg("Lifecycle: SetupTexts — no text configs", "DEBUG")
        return
    end

    ns.AuraTracker:On("LEC_AURA_ADDED",   "texts", OnAuraAdded)
    ns.AuraTracker:On("LEC_AURA_UPDATED", "texts", OnAuraUpdated)
    ns.AuraTracker:On("LEC_AURA_REMOVED", "texts", OnAuraRemoved)
    ns.lpmsg("Lifecycle: SetupTexts done", "DEBUG")
end

function ns.StopAllTexts()
    ns.AuraTracker:Off("LEC_AURA_ADDED",   "texts")
    ns.AuraTracker:Off("LEC_AURA_UPDATED", "texts")
    ns.AuraTracker:Off("LEC_AURA_REMOVED", "texts")
    for _, fs in pairs(textFrames) do fs:Hide() end
    wipe(textItemLookup)
end

-- Preview helper for the settings panel. Shows a literal number so the user
-- can see their anchor/font/color choices without the aura needing to be live.
function ns.PreviewText(tc, stateKey, on)
    if on then
        local fs = EnsureTextFrame(stateKey, tc)
        fs:SetText("1")
        fs:Show()
    else
        local fs = textFrames[stateKey]
        if fs then fs:Hide() end
    end
end
