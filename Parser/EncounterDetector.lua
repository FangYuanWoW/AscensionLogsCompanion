-- Parser/EncounterDetector.lua
-- Detects encounter boundaries on stock 3.3.5a Ascension client.
-- Ascension does not emit ENCOUNTER_START / ENCOUNTER_END (Legion era; not
-- backported). Sole mechanism is PLAYER_REGEN_DISABLED + raid instance proxy.

local ALC = _G.ALC
local E = {}
ALC.Parser.EncounterDetector = E

E.inEncounter = false
E.encounterStartTs = nil

local function inRaidInstance()
    local _, instType = IsInInstance()
    return instType == "raid"
end

local function onRegenDisabled()
    if not inRaidInstance() then return end
    if not E.inEncounter then
        E.inEncounter = true
        E.encounterStartTs = time() * 1000
        ALC.Core.Logger.debug("Encounter start (regen proxy)")
        if ALC.Transport.SpellFailedRelay then
            ALC.Transport.SpellFailedRelay.reevaluate()
        end
    end
end

local function onRegenEnabled()
    if E.inEncounter then
        E.inEncounter = false
        E.encounterStartTs = nil
    end
end

function E.start()
    ALC.RegisterEvent("PLAYER_REGEN_DISABLED", onRegenDisabled)
    ALC.RegisterEvent("PLAYER_REGEN_ENABLED", onRegenEnabled)
end
