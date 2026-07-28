-- Capture/PrimaryStatScan.lua
-- Per-pull roster sweep of GetUnitPrimaryStat, cached by player GUID.
--
-- WHY THIS EXISTS
-- Classless (Season 10) characters are all class "Hero" with no meaningful
-- spec, so the only build axis a player picks is their PATH - Strength /
-- Agility / Intelligence / Healing / Duality. The server currently infers that
-- from a permanent marker aura in the combat log, but the aura only fires when
-- it is APPLIED (login / zone-in / respec), so roughly three quarters of the
-- rows it produces are forward-filled rather than observed. Reading the value
-- straight off the client turns inference into direct observation.
--
-- WHY IT DOES NOT USE THE INSPECT QUEUE
-- GetUnitPrimaryStat(unit) is a plain unit-data read. Unlike gear, it needs no
-- NotifyInspect round-trip, does not touch the single global inspect buffer,
-- and therefore does not have to stand down while the character pane or an
-- inspect window is open. So it does not join InspectLoop's one-at-a-time
-- rotation - it sweeps the WHOLE unresolved roster on each tick instead, which
-- converges far faster than gear capture can.
--
-- It does reuse InspectLoop's roster map (GUID -> unit token), because that is
-- already maintained on roster change and is exactly the input this needs.
--
-- CACHE SCOPE IS PER PULL, DELIBERATELY
-- The path is per-encounter mutable: players genuinely respec between bosses
-- (prod darkmoon has characters ranked under two different paths in one night).
-- A session-scoped cache would resolve someone on the first pull and then
-- report that stale path for the rest of the raid - worse than not capturing
-- them at all, because it would look like confident direct observation while
-- being wrong. So the cache is keyed on EncounterTracker.pullId and resets
-- whenever the pull changes.
--
-- nil IS "NOT YET", NEVER "NO PATH"
-- Out-of-range / not-yet-loaded units return nil. A nil never writes and never
-- evicts - the GUID simply stays in the unresolved set and is retried next
-- tick. Once the unresolved set empties, the sweep stops entirely until the
-- next pull, so a resolved raid costs nothing.

local ALC = _G.ALC
local P = {}
ALC.Capture.PrimaryStatScan = P

-- Enum.PrimaryStat int -> stable token. Mirrors LocalScan.PRIMARY_STAT_TOKENS;
-- both are kept in step by hand because the two capture paths are independent.
-- id 5 (stamina) is in the enum but is NOT a selectable path
-- (GetPrimaryStatInfo(5) returns nothing in game), so it should never be seen;
-- it is mapped only so a surprise value still resolves to a token.
local PRIMARY_STAT_TOKENS = {
    [1] = "strength",
    [2] = "agility",
    [3] = "intellect",
    [4] = "spirit",
    [5] = "stamina",
    [6] = "duality",
}

P.pullId = nil       -- pull the current cache belongs to
P.resolved = {}      -- GUID -> { id = <int>, token = <string> }
P.unresolved = {}    -- GUID -> true (still to read)

local function api()
    return type(_G.GetUnitPrimaryStat) == "function" and _G.GetUnitPrimaryStat or nil
end

-- True once every roster member has a value, i.e. nothing left to do.
function P.isComplete()
    return next(P.unresolved) == nil
end

-- (Re)seed the unresolved set from InspectLoop's roster map. Called on pull
-- change and on roster change, so someone who joins mid-fight is picked up.
function P.reseed()
    local loop = ALC.Capture and ALC.Capture.InspectLoop
    local byGuid = loop and loop.unitByGuid or nil
    if not byGuid then return end
    for guid in pairs(byGuid) do
        if not P.resolved[guid] then
            P.unresolved[guid] = true
        end
    end
end

-- Drop everything and start over. The pull boundary is the whole point of this
-- module: see the cache-scope note in the header.
function P.resetForPull(pullId)
    P.pullId = pullId
    P.resolved = {}
    P.unresolved = {}
    P.reseed()
end

-- One sweep over the unresolved remainder. Cheap and self-silencing: it exits
-- immediately once nothing is unresolved, and never re-reads a resolved GUID.
function P.tick()
    local get = api()
    if not get then return end

    local ET = ALC.Capture and ALC.Capture.EncounterTracker
    local pullId = ET and ET.getCurrentPullId and ET.getCurrentPullId() or 0
    if pullId ~= P.pullId then
        P.resetForPull(pullId)
    end

    if P.isComplete() then return end

    local loop = ALC.Capture and ALC.Capture.InspectLoop
    local byGuid = loop and loop.unitByGuid or nil
    if not byGuid then return end

    for guid in pairs(P.unresolved) do
        local unit = byGuid[guid]
        if unit then
            local ok, stat = pcall(get, unit)
            -- Only a real value clears the GUID. Errors and nil leave it queued.
            if ok and stat and stat ~= 0 then
                P.resolved[guid] = { id = stat, token = PRIMARY_STAT_TOKENS[stat] }
                P.unresolved[guid] = nil
            end
        else
            -- Unit token vanished (left the group): stop chasing it.
            P.unresolved[guid] = nil
        end
    end
end

-- Roster changed mid-pull - fold any newcomers into the unresolved set without
-- discarding what we already resolved for everyone else.
function P.onRosterChange()
    P.reseed()
end

-- Read-side accessor for the snapshot pipeline: the path this player was on
-- for the CURRENT pull, or nil if we never got a value.
-- Returns { id, token } or nil.
function P.get(guid)
    if not guid then return nil end
    return P.resolved[guid]
end

return P
