-- Transport/SavedVarFlush.lua
-- Belt-and-suspenders persistence. Snapshots every known combatant's CI
-- into ALC_SessionLog at encounter boundaries. Never writes mid-combat.

local ALC = _G.ALC
local F = {}
ALC.Transport.SavedVarFlush = F

local function ensureLog()
    _G.ALC_SessionLog = _G.ALC_SessionLog or {}
end

local function currentEncounterBucket(sessionId, boundaryTs)
    ensureLog()
    ALC_SessionLog[sessionId] = ALC_SessionLog[sessionId] or { encounters = {} }
    local key = tostring(boundaryTs)
    ALC_SessionLog[sessionId].encounters[key] = ALC_SessionLog[sessionId].encounters[key] or {
        zone = GetZoneText() or "Unknown",
        boundary_ts = boundaryTs,
        combatants = {},
    }
    return ALC_SessionLog[sessionId].encounters[key]
end

-- Called on PLAYER_REGEN_ENABLED in raid instance (encounter end)
function F.flushEncounter(boundaryTs)
    local sessionId = (_G.ALC_LocalState or {}).session_id
    if not sessionId then return end

    local bucket = currentEncounterBucket(sessionId, boundaryTs)
    local nowMs = time() * 1000

    for guid, entry in pairs(ALC.Capture.InspectCache.snapshot()) do
        if entry.ci then
            local freshness = nowMs - (entry.ci.captured_at or nowMs)
            bucket.combatants[guid] = {
                ci = entry.ci,
                received_via = entry.received_via or "unknown",
                received_at = nowMs,
                freshness_at_encounter_start_ms = freshness,
            }
        end
    end

    F.pruneOldSessions()
end

-- Retention: drop sessions older than SESSION_LOG_MAX_DAYS
function F.pruneOldSessions()
    local cutoff = time() - (ALC.Core.Constants.SESSION_LOG_MAX_DAYS * 24 * 3600)
    ensureLog()
    for sessionId, sessionData in pairs(ALC_SessionLog) do
        local keepAny = false
        for key, enc in pairs(sessionData.encounters or {}) do
            if (enc.boundary_ts or 0) / 1000 < cutoff then
                sessionData.encounters[key] = nil
            else
                keepAny = true
            end
        end
        if not keepAny then
            ALC_SessionLog[sessionId] = nil
        end
    end
end
