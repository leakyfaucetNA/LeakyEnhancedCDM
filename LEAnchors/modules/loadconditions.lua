-- loadconditions.lua
-- Per-item / per-group load filters: class, specID, inCombat.
-- Mirrors LECDM/LECONT's pattern so items load consistently across the suite.

local _, ns = ...

local next = next
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
    local item = (db.profile.items and db.profile.items[itemID])
        or (db.global and db.global.items and db.global.items[itemID])
    return ns.ShouldLoadItemTable(db, item)
end

-- Same predicate but takes the item table directly. Useful when iterating
-- multiple stores (profile + global) where itemIDs may collide.
function ns.ShouldLoadItemTable(db, item)
    if not item or item.enabled == false then return false end

    if item.specID then
        local activeIdx  = GetSpecialization and GetSpecialization()
        local activeSpec = activeIdx and GetSpecializationInfo and GetSpecializationInfo(activeIdx)
        if activeSpec and item.specID ~= activeSpec then return false end
    end

    local groupID = item.parentGroup
    while groupID do
        local group = (db.profile.groups and db.profile.groups[groupID])
            or (db.global and db.global.groups and db.global.groups[groupID])
        if not group or group.enabled == false then return false end
        groupID = group.parentGroup
    end
    return ns.ShouldLoad(MergeLoadConditions(item.loadConditions, db, item.parentGroup))
end
