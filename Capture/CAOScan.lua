-- Capture/CAOScan.lua
-- Reads Ascension CharacterAdvancement state for the local player using
-- the real API surface (validated 2026-04-24 against live BB client).
--
-- Source of truth: _G.C_CharacterAdvancement (126 functions on Bronzebeard)
-- and the static data tables (CHARACTER_ADVANCEMENT_NODES / _TALENTS / _SPELLS).
-- These are NOT the CAO_Known / CAO_Talent_Ranks globals that REToolbox
-- documents - those don't exist on current Bronzebeard.

local ALC = _G.ALC
local C = {}
ALC.Capture.CAOScan = C

local function CA()
    return _G.C_CharacterAdvancement
end

-- Active specialization. Returns the spec ID (Ascension's internal ID, not
-- the spec slot index). Use GetSpecializationInfo(slotIndex) for friendly name.
function C.readActiveSpec()
    local api = CA()
    if api and type(api.GetActiveSpecID) == "function" then
        local ok, id = pcall(api.GetActiveSpecID)
        if ok then return id end
    end
    -- Fallback to top-level API
    if type(_G.GetSpecialization) == "function" then
        local ok, id = pcall(_G.GetSpecialization)
        if ok then return id end
    end
    return nil
end

-- Friendly metadata for the active spec. Returns name + role.
-- GetSpecialization() returns the spec ID (e.g. 64) which is NOT a valid
-- index for GetSpecializationInfo. Use C_CharacterAdvancement.GetActiveSpecID
-- which returns the slot index (1-3) compatible with GetSpecializationInfo.
function C.readActiveSpecInfo()
    if type(_G.GetSpecializationInfo) ~= "function" then return nil end

    local activeSlot = 1
    local CA = _G.C_CharacterAdvancement
    if CA and type(CA.GetActiveSpecID) == "function" then
        local ok, slot = pcall(CA.GetActiveSpecID)
        if ok and type(slot) == "number" and slot >= 1 and slot <= 3 then
            activeSlot = slot
        end
    end

    -- GetSpecializationInfo returns: (id, name, description, icon, role)
    -- pcall prepends ok status, so we capture 6 values total.
    local ok, id, name, _desc, _icon, role = pcall(_G.GetSpecializationInfo, activeSlot)
    if not ok then return nil end
    return {
        name       = name,
        role       = role,
        slot_index = activeSlot,
        spec_id    = id,  -- redundant with readActiveSpec() but useful for cross-check
    }
end

-- All known CAO spells. Returns a list of spell IDs.
function C.readKnown()
    local api = CA()
    if not api then return {} end
    if type(api.GetKnownSpells) == "function" then
        local ok, spells = pcall(api.GetKnownSpells)
        if ok and type(spells) == "table" then
            local out = {}
            for _, spellId in pairs(spells) do
                out[#out + 1] = spellId
            end
            return out
        end
    end
    return {}
end

-- All known CAO talent entries with their ranks. Returns a flat map of
-- entry_id -> rank.
function C.readTalentRanks()
    local api = CA()
    if not api then return {} end
    local out = {}
    if type(api.GetKnownTalentEntries) == "function" then
        local ok, entries = pcall(api.GetKnownTalentEntries)
        if ok and type(entries) == "table" then
            for _, entry in pairs(entries) do
                if entry and entry.id and api.GetTalentRankByID then
                    local _ok, rank = pcall(api.GetTalentRankByID, entry.id)
                    if _ok and rank then
                        out[entry.id] = rank
                    end
                end
            end
        end
    end
    return out
end

-- Investment summary: AE (Ascension Essence) and TE (Talent Essence) totals.
function C.readInvestment()
    local api = CA()
    if not api then return nil end
    local out = {}
    if type(api.GetGlobalAEInvestment) == "function" then
        local ok, ae = pcall(api.GetGlobalAEInvestment)
        if ok then out.global_ae = ae end
    end
    if type(api.GetGlobalTEInvestment) == "function" then
        local ok, te = pcall(api.GetGlobalTEInvestment)
        if ok then out.global_te = te end
    end
    return out
end

-- Vanilla talent points per tab (for non-CAO content / hybrid characters).
-- Argument isInspect=true reads from inspected unit instead of player.
function C.readVanillaTalents(isInspect)
    local result = {}
    local numTabs = GetNumTalentTabs and GetNumTalentTabs(isInspect) or 0
    for tab = 1, numTabs do
        local tabInfo = { tab = tab, ranks = {} }
        local numTalents = GetNumTalents and GetNumTalents(tab, isInspect) or 0
        for idx = 1, numTalents do
            local _, _, _, _, rank = GetTalentInfo(tab, idx, isInspect)
            tabInfo.ranks[idx] = rank or 0
        end
        result[#result + 1] = tabInfo
    end
    return result
end

-- Read inspected unit's CAO state. Caller must ensure both InspectUnit was
-- called AND the INSPECT_CHARACTER_ADVANCEMENT_RESULT event has fired (or
-- enough delay elapsed) before invoking. Returns nil if inspect data is
-- unavailable; otherwise a struct with active spec, unlocked specs, and the
-- per-talent rank map for default classes (or full build entries for hero).
--
-- Canonical pattern from patch-B Ascension_InspectUI/Panels/InspectBuildPanel.lua:
--   - GetInspectInfo(unit) -> (activeSpec, unlockedSpecs[])
--   - IsDefaultClass(unit) branches: default uses tab iteration, hero uses
--     GetInspectedBuild(unit, specID) directly
--   - UnitKnownID(unit, entry.ID, specID) and UnitTalentRankByID(unit, entry.ID, specID)
--     both take THREE args - the third is the active spec slot from GetInspectInfo
-- Unified CAO read for any unit. For "player" we get spec via GetActiveSpecID;
-- for inspected units via GetInspectInfo. Talent iteration uses the canonical
-- 3-arg UnitKnownID/UnitTalentRankByID signature that works for both.
-- Returns { spec_idx, unlocked_specs?, ca_known?, ca_talent_ranks?,
-- ca_talent_max_ranks?, hero_build? } or nil.
function C.readCAOForUnit(unit)
    local api = CA()
    if not api then return nil end

    local activeSpec, unlockedSpecs
    if unit == "player" then
        if type(api.GetActiveSpecID) == "function" then
            local ok, id = pcall(api.GetActiveSpecID)
            if ok then activeSpec = id end
        end
    else
        if type(api.GetInspectInfo) ~= "function" then return nil end
        local ok, a, b = pcall(api.GetInspectInfo, unit)
        if ok then activeSpec, unlockedSpecs = a, b end
    end
    if not activeSpec then return nil end

    local out = {
        spec_idx = activeSpec,
        unlocked_specs = type(unlockedSpecs) == "table" and unlockedSpecs or nil,
    }

    local _, classFile = UnitClass(unit)
    local isHero = (_G.IsHeroClass and _G.IsHeroClass(unit)) or classFile == "HERO"
    local isDefault = _G.IsDefaultClass and _G.IsDefaultClass(unit)

    -- Hero classes: GetInspectedBuild works for both "player" and inspected
    -- units, so the same call covers both. For default classes we iterate
    -- the class+spec talent tables.
    if isHero or not isDefault then
        if type(api.GetInspectedBuild) == "function" then
            local bok, entries = pcall(api.GetInspectedBuild, unit, activeSpec)
            if bok and type(entries) == "table" then
                local build = {}
                for i, entry in ipairs(entries) do
                    if entry and entry.EntryId then
                        build[#build + 1] = {
                            entry_id = entry.EntryId,
                            rank = entry.Rank,
                        }
                    end
                end
                out.hero_build = build
            end
        end
    end

    local CASO = _G.CHARACTER_ADVANCEMENT_CLASS_SPEC_ORDER
    local CAU = _G.CharacterAdvancementUtil
    if isDefault and CASO and CAU and classFile and CASO[classFile]
       and type(api.GetTalentsByClass) == "function"
       and type(api.UnitKnownID) == "function"
       and type(api.UnitTalentRankByID) == "function" then
        local ranks = {}     -- entry_id -> rank
        local maxRanks = {}  -- entry_id -> max_rank
        local known = {}     -- list of entry_ids the unit has unlocked
        for tabID = 1, 3 do
            local spec = CASO[classFile][tabID]
            local dbcClass = CAU.GetClassDBCByFile and CAU.GetClassDBCByFile(classFile)
            local dbcSpec = CAU.GetSpecDBCByFile and CAU.GetSpecDBCByFile(spec)
            if dbcClass and dbcSpec then
                local tok, tabEntries = pcall(api.GetTalentsByClass, dbcClass, dbcSpec, true)
                if tok and type(tabEntries) == "table" then
                    for _, entry in ipairs(tabEntries) do
                        if entry and entry.ID then
                            local kok, isKnown = pcall(api.UnitKnownID, unit, entry.ID, activeSpec)
                            if kok and isKnown then
                                known[#known + 1] = entry.ID
                                local rok, rank, maxRank = pcall(api.UnitTalentRankByID, unit, entry.ID, activeSpec)
                                if rok and type(rank) == "number" and rank > 0 then
                                    ranks[entry.ID] = rank
                                    if type(maxRank) == "number" then
                                        maxRanks[entry.ID] = maxRank
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
        out.ca_known = known
        out.ca_talent_ranks = ranks
        out.ca_talent_max_ranks = maxRanks
    end

    return out
end

-- Backwards-compat alias for the inspect-side caller.
function C.readInspectedCAO(unit)
    return C.readCAOForUnit(unit)
end
