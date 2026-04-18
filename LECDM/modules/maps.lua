local _, ns = ...

ns.auraFrameMap  = {}  -- [spellName] → { _lecSpellID, _lecName, frame }  (TrackedBuff + TrackedBar)
ns.cdFrameMap    = {}  -- [spellName] → { _lecSpellID, _lecName, frame }  (Essential + Utility)
ns.FrameRegistry = {}  -- frames with active glows — used to clean up on reset

local COOLDOWN_CATEGORIES = { Enum.CooldownViewerCategory.Essential,  Enum.CooldownViewerCategory.Utility    }
local AURA_CATEGORIES     = { Enum.CooldownViewerCategory.TrackedBuff, Enum.CooldownViewerCategory.TrackedBar }

local VIEWER_MAP_LOOKUP = {
    EssentialCooldownViewer = "cd",
    UtilityCooldownViewer   = "cd",
    BuffIconCooldownViewer  = "aura",
    BuffBarCooldownViewer   = "aura",
}

-- Resolve a viewer frame (or name string) to its map table.
function ns.GetMapForViewer(viewer)
    local name = type(viewer) == "string" and viewer or (viewer.GetName and viewer:GetName() or "")
    local key = VIEWER_MAP_LOOKUP[name]
    if key == "cd"   then return ns.cdFrameMap   end
    if key == "aura" then return ns.auraFrameMap end
end

-- Write a live pool frame ref into the correct map entry for spellID.
-- Matches on _lecSpellID or _lecOverrideID to handle talent swaps (e.g. Word of Glory → Eternal Flame).
-- If no entry matches (proc buff variant with a different ID), registers a dynamic entry.
function ns.UpdateMapFrame(spellID, frame, viewer)
    local target = ns.GetMapForViewer(viewer)
    if not target then return end
    for _, entry in pairs(target) do
        if entry._lecSpellID == spellID or entry._lecOverrideID == spellID then
            entry.frame = frame
            return
        end
    end
    -- No match — proc buff ID differs from the category-registered base spell ID.
    local name = C_Spell.GetSpellName(spellID) or ("Spell " .. spellID)
    local key = name .. "_" .. spellID
    if not target[key] then
        target[key] = { _lecSpellID = spellID, _lecName = name, _lecDynamic = true }
        ns.lpmsg("UpdateMapFrame: dynamic entry spellID=" .. spellID .. " (" .. name .. ")", "DEBUG")
    end
    target[key].frame = frame
end

-- Return the live CDM pool frame for an active aura (cooldownID non-nil = in-pool).
function ns.FindAuraFrame(spellID)
    if not spellID then return nil end
    for _, entry in pairs(ns.auraFrameMap) do
        if entry._lecSpellID == spellID and entry.frame and entry.frame.cooldownID then
            return entry.frame
        end
    end
end

-- Return the live CDM pool frame for an active cooldown.
function ns.FindCooldownFrame(spellID)
    if not spellID then return nil end
    for _, entry in pairs(ns.cdFrameMap) do
        if entry._lecSpellID == spellID and entry.frame and entry.frame.cooldownID then
            return entry.frame
        end
    end
end

-- Populate dest with metadata entries for the given CDM categories.
-- Also stores talent override IDs and adds alias entries keyed by the override name.
local function BuildCategoryMap(categories, dest)
    if not C_CooldownViewer.IsCooldownViewerAvailable() then
        ns.lpmsg("BuildCategoryMap: CDM not available", "DEBUG")
        return
    end
    for _, cat in ipairs(categories) do
        local ids = C_CooldownViewer.GetCooldownViewerCategorySet(cat)
        if ids then
            for _, cooldownID in ipairs(ids) do
                local info = C_CooldownViewer.GetCooldownViewerCooldownInfo(cooldownID)
                if info and info.spellID and info.spellID > 0 then
                    local spellID = info.spellID
                    local name = C_Spell.GetSpellName(spellID) or ("Spell " .. spellID)
                    local entry = { _lecSpellID = spellID, _lecName = name }

                    local overrideID = C_Spell.GetOverrideSpell(spellID)
                    if overrideID and overrideID ~= spellID then
                        entry._lecOverrideID = overrideID
                        local overrideName = C_Spell.GetSpellName(overrideID)
                        if overrideName and overrideName ~= name then
                            dest[overrideName] = entry
                        end
                    end

                    dest[name] = entry
                end
            end
        end
    end
end

function ns.BuildSpellMap()
    ns.lpmsg("Lifecycle: BuildSpellMap", "DEBUG")
    wipe(ns.cdFrameMap)
    BuildCategoryMap(COOLDOWN_CATEGORIES, ns.cdFrameMap)
    ns.lpmsg("Lifecycle: BuildSpellMap done", "DEBUG")
end

function ns.BuildAuraMap()
    ns.lpmsg("Lifecycle: BuildAuraMap", "DEBUG")
    wipe(ns.auraFrameMap)
    BuildCategoryMap(AURA_CATEGORIES, ns.auraFrameMap)
    ns.lpmsg("Lifecycle: BuildAuraMap done", "DEBUG")
end
