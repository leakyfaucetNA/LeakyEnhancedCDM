-- loadconditions.lua
-- Per-item / per-group load filters: class, specID, inCombat.
-- Mirrors LECDM's pattern so items load consistently across the addon suite.

local _, ns = ...

local pairs, next = pairs, next
local GetSpecialization     = GetSpecialization
local GetSpecializationInfo = GetSpecializationInfo
local InCombatLockdown      = InCombatLockdown
local UnitClass             = UnitClass

function ns.ShouldLoad(lc)
    if not lc then return true end
    if lc.class then
        local _, playerClass = UnitClass("player")
        if lc.class ~= playerClass then return false end
    end
    if lc.specIDs and next(lc.specIDs) then
        local idx = GetSpecialization()
        local cur = idx and GetSpecializationInfo(idx) or 0
        if not lc.specIDs[cur] then return false end
    end
    if lc.inCombat == true  and not InCombatLockdown() then return false end
    if lc.inCombat == false and     InCombatLockdown() then return false end
    return true
end

local function MergeLoadConditions(ownLC, db, parentGroupID)
    local merged = {}
    if ownLC then
        if ownLC.specIDs and next(ownLC.specIDs) then merged.specIDs = ownLC.specIDs end
        if ownLC.inCombat ~= nil then merged.inCombat = ownLC.inCombat end
        if ownLC.class then merged.class = ownLC.class end
    end
    local groupID = parentGroupID
    while groupID do
        local group = db.profile.groups and db.profile.groups[groupID]
        if not group then break end
        local glc = group.loadConditions
        if glc then
            if not merged.specIDs and glc.specIDs and next(glc.specIDs) then merged.specIDs = glc.specIDs end
            if merged.inCombat == nil and glc.inCombat ~= nil then merged.inCombat = glc.inCombat end
            if not merged.class and glc.class then merged.class = glc.class end
        end
        groupID = group.parentGroup
    end
    return merged
end

function ns.ShouldLoadItem(db, itemID)
    local item = db.profile.items[itemID]
    if not item or item.enabled == false then return false end

    -- Spec filter: items are created per-spec in the settings UI when specID
    -- is stamped. Without this check, items configured for other specs would
    -- load on the current spec too.
    if item.specID then
        local activeIdx  = GetSpecialization and GetSpecialization()
        local activeSpec = activeIdx and GetSpecializationInfo and GetSpecializationInfo(activeIdx)
        if activeSpec and item.specID ~= activeSpec then return false end
    end

    local groupID = item.parentGroup
    while groupID do
        local group = db.profile.groups and db.profile.groups[groupID]
        if not group or group.enabled == false then return false end
        groupID = group.parentGroup
    end
    return ns.ShouldLoad(MergeLoadConditions(item.loadConditions, db, item.parentGroup))
end
