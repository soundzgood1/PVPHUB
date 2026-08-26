-- PVPHUB Compatibility Layer
--
-- Thin wrappers around WoW APIs that Blizzard has moved into a C_ namespace
-- and left behind only as deprecated globals. Those globals live in the
-- Blizzard_Deprecated* addons, every one of which starts with:
--
--     if not GetCVarBool("loadDeprecationFallbacks") then return; end
--
-- so they vanish the moment a player turns that CVar off, and Blizzard's own
-- TOC for them says "They will be removed at the next expansion." Calling the
-- canonical C_ function first means PVPHUB keeps working in both cases.
--
-- This file MUST stay first in the .toc load order: every other file aliases
-- PVPHUB.Compat at its own load time, which only works if this has already run.
-- It deliberately depends on nothing else in the addon.

local _, PVPHUB = ...

PVPHUB.Compat = {}
local Compat = PVPHUB.Compat

-- Index of the player's active specialization (1-4), or nil.
-- Canonical: C_SpecializationInfo.GetSpecialization
function Compat.GetSpecIndex()
    if C_SpecializationInfo and C_SpecializationInfo.GetSpecialization then
        return C_SpecializationInfo.GetSpecialization()
    end
    if GetSpecialization then
        return GetSpecialization()
    end
    return nil
end

-- Full spec info for a spec INDEX (not a specID — that's GetSpecializationInfoByID,
-- which is still a regular global in 12.1 and needs no wrapper).
-- Returns the same values as the original: id, name, description, icon, role, classFile
-- Canonical: C_SpecializationInfo.GetSpecializationInfo
function Compat.GetSpecInfo(specIndex)
    if not specIndex then return nil end
    if C_SpecializationInfo and C_SpecializationInfo.GetSpecializationInfo then
        return C_SpecializationInfo.GetSpecializationInfo(specIndex)
    end
    if GetSpecializationInfo then
        return GetSpecializationInfo(specIndex)
    end
    return nil
end

-- Convenience: resolve straight to a valid specID, or nil.
-- Guards against specID == 0, which is truthy in Lua and has burned this
-- addon before (see the explicit > 0 check in UpdateCurrencyData).
function Compat.GetCurrentSpecID()
    local idx = Compat.GetSpecIndex()
    if not idx then return nil end
    local ok, specID = pcall(Compat.GetSpecInfo, idx)
    if ok and specID and specID > 0 then
        return specID
    end
    return nil
end

-- Count of an item in the player's bags.
-- Canonical: C_Item.GetItemCount
function Compat.GetItemCount(itemID, includeBank, includeUses, includeReagentBank)
    if C_Item and C_Item.GetItemCount then
        return C_Item.GetItemCount(itemID, includeBank, includeUses, includeReagentBank)
    end
    if GetItemCount then
        return GetItemCount(itemID, includeBank, includeUses, includeReagentBank)
    end
    return 0
end

-- Highest battlefield queue slot index.
-- MAX_BATTLEFIELD_QUEUES no longer exists in 12.1 (zero occurrences in the
-- entire Blizzard UI source); Blizzard iterates with GetMaxBattlefieldID().
-- The literal 3 is only a last-resort floor, not the expected path.
function Compat.GetMaxBattlefieldQueues()
    if GetMaxBattlefieldID then
        local n = GetMaxBattlefieldID()
        if n and n > 0 then return n end
    end
    return MAX_BATTLEFIELD_QUEUES or 3
end
