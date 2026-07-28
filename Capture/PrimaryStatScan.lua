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
-- "NO VALUE" HAS THREE CAUSES, AND THEY ARE NOT THE SAME EVENT
-- The call can (a) THROW, (b) succeed and return nil for a Hero we cannot
-- currently track, or (c) succeed and return nil because the unit has no path
-- at all. Only (b) is worth retrying. (a) is bounded by MAX_ERRORS - a unit
-- that throws will keep throwing - and (c) is permanent. None of the three can
-- ever be mistaken for DATA: only a real value writes, so a failure never
-- files a player under a path they did not pick.
--
-- nil MEANS TWO DIFFERENT THINGS
-- For a HERO unit, nil means "not trackable yet" (out of range / not loaded):
-- it never writes and never evicts, the GUID stays queued and is retried next
-- tick. For a NON-HERO unit, nil means "has no path at all" and is permanent -
-- verified in game 2026-07-27, where a WARRIOR that was visible AND inside
-- inspect range still returned nil on every sample while a HERO party member
-- resolved 7/7. Non-Hero units are therefore dropped from the queue on sight
-- rather than retried; conflating the two would leave the unresolved set
-- permanently non-empty on every non-classless tenant (nobody is Hero on
-- BB/Epoch/CoA/Trium) and the sweep would never go quiet.
--
-- Once the unresolved set empties, the sweep stops entirely until the next
-- pull, so a resolved raid costs nothing.

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
P.errors = {}        -- GUID -> consecutive pcall failures this pull
P.stats = nil        -- per-pull counters, for diagnosing thin coverage

-- A unit whose read keeps THROWING is not the same as one that keeps
-- answering nil. nil is expected (out of range); an error is not, and
-- retrying it every tick for the whole pull just spins. Give up on a unit
-- after this many consecutive errors.
local MAX_ERRORS = 3

-- The sweep RIDES InspectLoop's 1s timer but must not inherit its CADENCE.
-- Those two loops have opposite shapes: inspect fires ONE NotifyInspect per
-- tick and is paced at 1s because it is a server round-trip that can be
-- throttled. This is a purely local read with nothing to throttle, but it
-- touches EVERY unresolved unit per pass - so at 1Hz an out-of-range player
-- would be polled ~300 times across a five-minute fight.
--
-- The value is static within a pull (the path can only change between
-- encounters), so the only question a retry answers is "has this player come
-- into range yet". Every few seconds is ample for that, and it cuts the work
-- by the same factor. Resolution speed is unaffected: anyone in range at the
-- pull is captured on the first pass.
local MIN_SWEEP_INTERVAL_S = 3.0
P.lastSweepAt = 0

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
    -- Sweep immediately on a new pull rather than waiting out the interval:
    -- the pull is exactly when the value matters most.
    P.lastSweepAt = 0
    P.resolved = {}
    P.unresolved = {}
    P.errors = {}
    -- Kept so a thin-coverage pull can be explained after the fact rather than
    -- guessed at: "nobody was in range" and "the API was erroring" look
    -- identical from the outside, which is exactly how the non-Hero bug hid.
    P.stats = { resolved = 0, errored = 0, dropped_non_hero = 0, dropped_error = 0 }
    P.reseed()
end

-- One sweep over the unresolved remainder. Cheap and self-silencing: it exits
-- immediately once nothing is unresolved, and never re-reads a resolved GUID.
function P.tick()
    local get = api()
    if not get then return end

    -- Own cadence, deliberately slower than the inspect rotation we ride.
    -- The pull check below still runs every tick, so a new pull resets the
    -- cache immediately rather than up to MIN_SWEEP_INTERVAL_S late.
    local nowT = GetTime()

    local ET = ALC.Capture and ALC.Capture.EncounterTracker
    local pullId = ET and ET.getCurrentPullId and ET.getCurrentPullId() or 0
    if pullId ~= P.pullId then
        P.resetForPull(pullId)
    end

    if P.isComplete() then return end

    -- Throttle the actual sweep (but never the pull-reset above).
    if (nowT - (P.lastSweepAt or 0)) < MIN_SWEEP_INTERVAL_S then return end
    P.lastSweepAt = nowT

    local loop = ALC.Capture and ALC.Capture.InspectLoop
    local byGuid = loop and loop.unitByGuid or nil
    if not byGuid then return end

    for guid in pairs(P.unresolved) do
        local unit = byGuid[guid]
        if unit then
            -- nil has TWO meanings, and conflating them is a bug: "not
            -- trackable yet" (retry) versus "this unit has no path at all"
            -- (never retry). Verified in game 2026-07-27: a WARRIOR unit that
            -- was visible AND inside inspect range still returned nil on every
            -- sample, while a HERO party member resolved 7/7.
            --
            -- Without this guard the unresolved set never empties on any
            -- non-classless tenant - nobody is Hero on BB/Epoch/CoA/Trium - so
            -- the sweep would walk the whole roster every tick forever and
            -- never go quiet. Drop non-Hero units instead of chasing them.
            local _, classToken = UnitClass(unit)
            if classToken ~= "HERO" then
                P.unresolved[guid] = nil
                if P.stats then
                    P.stats.dropped_non_hero = P.stats.dropped_non_hero + 1
                end
            else
                local ok, stat = pcall(get, unit)
                if not ok then
                    -- The call FAILED - distinct from it succeeding and saying
                    -- "nothing". Bound these: a unit that throws every tick
                    -- will keep throwing, and spinning on it buys nothing.
                    local n = (P.errors[guid] or 0) + 1
                    P.errors[guid] = n
                    if P.stats then P.stats.errored = P.stats.errored + 1 end
                    if n >= MAX_ERRORS then
                        P.unresolved[guid] = nil
                        if P.stats then
                            P.stats.dropped_error = P.stats.dropped_error + 1
                        end
                        ALC.Core.Logger.debug(
                            "PrimaryStatScan: giving up on " .. tostring(unit)
                            .. " after " .. n .. " errors: " .. tostring(stat))
                    end
                elseif stat and stat ~= 0 then
                    -- A real value: the only thing that ever writes.
                    P.resolved[guid] = { id = stat, token = PRIMARY_STAT_TOKENS[stat] }
                    P.unresolved[guid] = nil
                    P.errors[guid] = nil
                    if P.stats then P.stats.resolved = P.stats.resolved + 1 end
                end
                -- else: succeeded and returned nil = "not trackable yet" for a
                -- Hero. Expected, unbounded retry, no error counted.
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
