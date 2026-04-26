-- Capture/InspectCache.lua
-- In-memory cache of captured CIs keyed by player GUID.
-- Persisted to SavedVariablesPerCharacter (ALC_InspectCache) across sessions.

local ALC = _G.ALC
local IC = {}
ALC.Capture.InspectCache = IC

-- Rehydrate from SavedVariables on ADDON_LOADED.
function IC.rehydrate()
    _G.ALC_InspectCache = _G.ALC_InspectCache or {}
    -- Validate entries: drop anything with missing fields or older than 7 days
    local nowSec = time()
    local cutoff = nowSec - (7 * 24 * 3600)
    for guid, entry in pairs(_G.ALC_InspectCache) do
        if type(entry) ~= "table" or not entry.last_success_at or entry.last_success_at < cutoff then
            _G.ALC_InspectCache[guid] = nil
        end
    end
end

function IC.get(guid)
    return _G.ALC_InspectCache[guid]
end

function IC.set(guid, entry)
    _G.ALC_InspectCache[guid] = entry
    IC.evictIfNeeded()
end

function IC.delete(guid)
    _G.ALC_InspectCache[guid] = nil
end

function IC.age(guid)
    local e = _G.ALC_InspectCache[guid]
    if not e or not e.last_success_at then return nil end
    return time() - e.last_success_at
end

function IC.isStale(guid)
    local ageSec = IC.age(guid)
    if not ageSec then return true end
    return (ageSec * 1000) > ALC.Core.Constants.INSPECT_STALE_MS
end

-- LRU eviction by last_success_at when over the cap
function IC.evictIfNeeded()
    local cap = ALC.Core.Constants.INSPECT_CACHE_MAX_ENTRIES
    local entries = {}
    for guid, e in pairs(_G.ALC_InspectCache) do
        entries[#entries + 1] = { guid = guid, t = e.last_success_at or 0 }
    end
    if #entries <= cap then return end
    table.sort(entries, function(a, b) return a.t < b.t end)
    local toDrop = #entries - cap
    for i = 1, toDrop do
        _G.ALC_InspectCache[entries[i].guid] = nil
    end
end

-- Snapshot: shallow copy for iteration without mutating during scan
function IC.snapshot()
    local out = {}
    for guid, e in pairs(_G.ALC_InspectCache) do
        out[guid] = e
    end
    return out
end
