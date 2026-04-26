-- Capture/MysticEnchantScan.lua
-- Reads Ascension mystic enchant state via the PRESET-based API.
-- Validated 2026-04-24: real data flows out of MysticEnchantManagerUtil
-- when the active preset is queried. The MysticEnchantUtil.GetAppliedEnchants
-- function returns empty regardless of equipped state - it's the wrong API
-- for current Bronzebeard.
--
-- Mystic enchants on Ascension are PRESET-LEVEL, not gear-level. Each
-- character has multiple "presets" (named loadouts of enchants) and one
-- preset is "active" at a time. The active preset's enchants are what
-- buff the character.

local ALC = _G.ALC
local M = {}
ALC.Capture.MysticEnchantScan = M

local function MEM() return _G.MysticEnchantManagerUtil end
local function MEU() return _G.MysticEnchantUtil end
local function CME() return _G.C_MysticEnchant end

-- Returns the active preset's data: id, name, and the enchant array.
function M.readActivePreset()
    local mgr = MEM()
    if not mgr or type(mgr.GetActivePreset) ~= "function" then return nil end

    local ok, presetId = pcall(mgr.GetActivePreset)
    if not ok or type(presetId) ~= "number" then return nil end

    local name
    if type(mgr.GetPresetInfo) == "function" then
        local nameOk, info = pcall(mgr.GetPresetInfo, presetId)
        if nameOk then name = info end
    end

    local enchants = {}
    if type(mgr.GetPresetData) == "function" then
        local dataOk, data = pcall(mgr.GetPresetData, presetId)
        if dataOk and type(data) == "table" then
            -- The data is keyed by slot index 1..N with values being
            -- spell IDs (or 0 for empty slot).
            for slot, enchantId in pairs(data) do
                if type(enchantId) == "number" and enchantId ~= 0 then
                    enchants[#enchants + 1] = {
                        slot = slot,
                        enchant_id = enchantId,
                    }
                end
            end
        end
    end

    return {
        preset_id = presetId,
        preset_name = name,
        enchants = enchants,
    }
end

-- All enchant IDs from the active preset, flat list. Convenience wrapper.
function M.readAppliedEnchantIds()
    local active = M.readActivePreset()
    if not active or not active.enchants then return {} end
    local out = {}
    for _, e in ipairs(active.enchants) do
        out[#out + 1] = e.enchant_id
    end
    return out
end

-- Whether the local player has unlocked the mystic enchant tab UI.
function M.hasUnlockedTab()
    local util = MEU()
    if not util or type(util.HasUnlockedEnchantTab) ~= "function" then return false end
    local ok, val = pcall(util.HasUnlockedEnchantTab)
    return ok and val and true or false
end

-- Capacity info: { num_presets, max_presets, free_presets }
function M.readPresetCapacity()
    local mgr = MEM()
    if not mgr then return nil end
    local out = {}
    if type(mgr.GetNumPresets) == "function" then
        local ok, n = pcall(mgr.GetNumPresets)
        if ok then out.num_presets = n end
    end
    if type(mgr.GetMaxPresets) == "function" then
        local ok, n = pcall(mgr.GetMaxPresets)
        if ok then out.max_presets = n end
    end
    if type(mgr.GetFreePresets) == "function" then
        local ok, n = pcall(mgr.GetFreePresets)
        if ok then out.free_presets = n end
    end
    return out
end

-- Trigger an inspect of the unit's mystic enchant state. Must be followed
-- by a wait + read pattern; results land in client-side cache after.
-- Phase 1 wiring incomplete: we know C_MysticEnchant.Inspect(unit) fires
-- the request but the response surface is TBD.
function M.requestInspect(unit)
    local api = CME()
    if not api or type(api.Inspect) ~= "function" then return false end
    if api.CanInspect then
        local ok, can = pcall(api.CanInspect, unit)
        if not ok or not can then return false end
    end
    -- Second arg `true` per Ascension_InspectUI/InspectFrame.lua:190 and
    -- /alcv3 probe validation. Without it, the inspect request is fired
    -- but result never populates - GetAppliedEnchant returns 0 for all slots.
    local ok = pcall(api.Inspect, unit, true)
    return ok
end

-- Read inspected unit's mystic enchant preset. Phase 1 stub - currently
-- returns nil; real wiring requires reverse-engineering Blizzard_Ascension
-- InspectFrame source, where the inspect-side preset query lives.
function M.readInspectedPreset(unit)
    -- TODO Phase 1.5: figure out the inspect-side preset API
    return nil
end

-- Inspected applied enchants. Caller must ensure C_MysticEnchant.Inspect was
-- called AND the MYSTIC_ENCHANT_INSPECT_RESULT event has fired (or enough
-- delay elapsed) before invoking.
--
-- Canonical reader from patch-B FrameXML/Util/MysticEnchantUtil.lua: iterate
-- C_MysticEnchant.GetAppliedEnchant(unit, slot) for slot 1..NUM_MYSTIC_ENCHANT_SLOTS,
-- skipping 0/nil. Each returned spell ID resolves to enchant metadata via
-- C_MysticEnchant.GetEnchantInfoBySpell(spellID) -> { SpellName, Quality, ... }.
--
-- Returns flat list of spell IDs (matching the shape of M.readAppliedEnchantIds
-- for own-player use) so callers can treat both uniformly.
function M.readInspectedEnchants(unit)
    local cme = CME()
    if not cme or type(cme.GetAppliedEnchant) ~= "function" then return nil end
    local numSlots = _G.NUM_MYSTIC_ENCHANT_SLOTS or 19
    local out = {}
    for slot = 1, numSlots do
        local ok, spellId = pcall(cme.GetAppliedEnchant, unit, slot)
        if ok and type(spellId) == "number" and spellId ~= 0 then
            out[#out + 1] = spellId
        end
    end
    if #out == 0 then return nil end
    return out
end

-- Inspected enchants keyed by slot (mirrors per_slot shape in InspectLoop).
-- Returns map slot -> { spell_id, name?, quality? }. nil if nothing populated.
function M.readInspectedEnchantsPerSlot(unit)
    local cme = CME()
    if not cme or type(cme.GetAppliedEnchant) ~= "function" then return nil end
    local numSlots = _G.NUM_MYSTIC_ENCHANT_SLOTS or 19
    local out = {}
    local found = false
    for slot = 1, numSlots do
        local ok, spellId = pcall(cme.GetAppliedEnchant, unit, slot)
        if ok and type(spellId) == "number" and spellId ~= 0 then
            local entry = { spell_id = spellId }
            if type(cme.GetEnchantInfoBySpell) == "function" then
                local infoOk, info = pcall(cme.GetEnchantInfoBySpell, spellId)
                if infoOk and type(info) == "table" then
                    entry.name = info.SpellName
                    entry.quality = info.Quality
                end
            end
            out[slot] = entry
            found = true
        end
    end
    if not found then return nil end
    return out
end
