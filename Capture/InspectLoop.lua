-- Capture/InspectLoop.lua
-- Priority-queue scheduled NotifyInspect rotation.
-- One tick every INSPECT_MIN_INTERVAL_S seconds. Each tick: advance queue,
-- issue one NotifyInspect if a target is due, or no-op.

local ALC = _G.ALC
local I = {}
ALC.Capture.InspectLoop = I

local C = ALC.Core.Constants

I.inFlight = nil       -- { guid = ..., started_at = ... }
I.lastTickAt = 0
I.ticker = nil         -- OnUpdate handler

local function now()
    return GetTime()
end

local function canInspectUnit(unit)
    return UnitExists(unit)
       and UnitIsVisible(unit)
       and UnitIsConnected(unit)
       and not UnitCanAttack("player", unit)
       and not UnitCanAttack(unit, "player")
       and CanInspect(unit)
       and UnitClass(unit) ~= nil
       and CheckInteractDistance(unit, 4)  -- 28y Follow range
end

local function resolveUnit(guid)
    if not guid then return nil end
    -- Raid roster (priority for in-raid inspects)
    for i = 1, (GetNumRaidMembers() or 0) do
        local u = "raid" .. i
        if UnitGUID(u) == guid then return u end
    end
    -- Party
    for i = 1, (GetNumPartyMembers() or 0) do
        local u = "party" .. i
        if UnitGUID(u) == guid then return u end
    end
    -- Solo / out-of-group fallback: target / mouseover / focus
    -- Important for /alc inspect-now to work outside a party.
    for _, u in ipairs({ "target", "mouseover", "focus" }) do
        if UnitExists(u) and UnitGUID(u) == guid then return u end
    end
    return nil
end

-- Pick the next GUID to inspect. Priority rules:
--   1. Roster members with no cache entry at all (first-inspect wins)
--   2. Raiders not yet captured for the current boss (if boss known)
--   3. Smallest next_scan_at otherwise
local function pickNext()
    local cache = ALC.Capture.InspectCache.snapshot()
    local nowSec = time()
    local currentBoss = ALC.Capture.EncounterTracker
                        and ALC.Capture.EncounterTracker.getCurrentBoss()

    -- Rule 1: missing roster entries (raid + party). Skip self - in raids,
    -- raid1..raidN includes the player; CanInspect(self) returns false so
    -- attempting to inspect self burns a tick and dirties inspect_gate_fail.
    local selfGuid = UnitGUID("player")
    for i = 1, (GetNumRaidMembers() or 0) do
        local u = "raid" .. i
        local guid = UnitGUID(u)
        if guid and guid ~= selfGuid and not cache[guid] then
            return guid
        end
    end
    for i = 1, (GetNumPartyMembers() or 0) do
        local u = "party" .. i
        local guid = UnitGUID(u)
        if guid and guid ~= selfGuid and not cache[guid] then
            return guid
        end
    end

    -- Rule 2: prefer raiders we haven't captured for this (boss, pull) tuple.
    -- Pulling the same boss again (e.g., wipe-retry) bumps pullId, so we
    -- still re-capture even though boss name didn't change.
    if currentBoss then
        local currentPullId = ALC.Capture.EncounterTracker
                              and ALC.Capture.EncounterTracker.getCurrentPullId()
                              or 0
        for guid, entry in pairs(cache) do
            if not entry.inspect_unavailable
               and (entry.backoff_until or 0) <= nowSec
               and (entry.captured_for_boss ~= currentBoss
                    or entry.captured_for_pull_id ~= currentPullId) then
                return guid
            end
        end
    end

    -- Rule 3: smallest next_scan_at among entries actually due now. Without
    -- the next_scan_at <= nowSec gate, the loop re-inspects freshly-captured
    -- party members every tick (their next_scan_at is 5min in the future but
    -- still the smallest in the cache).
    --
    -- When no boss is currently tracked (heroic dungeons not in BossRegistry,
    -- world content, or EncounterTracker silently failing), we fall back to a
    -- shorter 60s rescan window so we don't sit on stale data. Raid contexts
    -- keep the 5-min schedule because Rule 2 already forces fresh captures
    -- on every boss transition.
    local nobossRescanS = C.INSPECT_NOBOSS_RESCAN_MS / 1000
    local bestGuid, bestKey = nil, math.huge
    for guid, entry in pairs(cache) do
        if not entry.inspect_unavailable
           and (entry.backoff_until or 0) <= nowSec then
            local nextDue = entry.next_scan_at or 0
            if not currentBoss and entry.last_success_at then
                nextDue = math.min(nextDue, entry.last_success_at + nobossRescanS)
            end
            if nextDue <= nowSec then
                local key = entry.next_scan_at or 0
                if key < bestKey then
                    bestKey = key
                    bestGuid = guid
                end
            end
        end
    end
    return bestGuid
end

-- Schedule next scan time for a cache entry based on outcome
local function scheduleNext(entry, outcome)
    local nowSec = time()
    if outcome == "success" then
        entry.failure_streak = 0
        entry.partial_attempts = nil  -- reset on a fully-successful capture
        entry.last_success_at = nowSec
        entry.next_scan_at = nowSec + (C.INSPECT_RESCAN_MS / 1000)
        ALC.Core.Metrics.inc("inspect_success")
    elseif outcome == "partial" then
        -- The inspect succeeded but the captured CI is missing CAO or mystic
        -- data (race: client-side state hadn't populated by the time the
        -- INSPECT_CHARACTER_ADVANCEMENT_RESULT event arrived). Retry quickly.
        -- Don't bump failure_streak; this isn't a server-side failure.
        entry.last_success_at = nowSec  -- count it; we DID get partial data
        entry.next_scan_at = nowSec + 5
        ALC.Core.Metrics.inc("inspect_partial")
    elseif outcome == "timeout" then
        entry.failure_streak = (entry.failure_streak or 0) + 1
        local backoff = math.min(C.INSPECT_BACKOFF_MAX_S, 2 ^ entry.failure_streak)
        entry.backoff_until = nowSec + backoff
        entry.next_scan_at = entry.backoff_until
        -- No sticky `inspect_unavailable` flag - backoff (capped at
        -- INSPECT_BACKOFF_MAX_S = 60s) already throttles retries. A live raid
        -- has plenty of transient causes for inspect failure (stealth, LoS,
        -- zoned through a portal); permanently giving up after 3 misses
        -- would silently skip raiders for the rest of the run.
        ALC.Core.Metrics.inc("inspect_timeout")
    elseif outcome == "gate_fail" then
        -- Not a real failure; try again soon when proximity changes
        entry.next_scan_at = nowSec + 10
        ALC.Core.Metrics.inc("inspect_gate_fail")
    end
end

-- Event-driven finalize. INSPECT_TALENT_READY signals stock 3.3.5 inspect
-- (gear / vanilla talents / arena teams). Then we wait for two Ascension-
-- specific events to land before reading CAO + mystic data:
--   INSPECT_CHARACTER_ADVANCEMENT_RESULT -- C_CharacterAdvancement.InspectUnit response
--   MYSTIC_ENCHANT_INSPECT_RESULT        -- C_MysticEnchant.Inspect response
--
-- Event-driven finalize completes as soon as INSPECT_TALENT_READY +
-- INSPECT_CHARACTER_ADVANCEMENT_RESULT + MYSTIC_ENCHANT_INSPECT_RESULT
-- have all fired (vs the prior fixed timer); falls back to a 3s
-- "have-talent-but-not-CA/ME" cutoff so peers with failed/missing
-- Ascension inspects still get partial data captured.

local function finalizeInspect()
    local infl = I.inFlight
    if not infl or infl.finalized then return end
    infl.finalized = true

    local unit = infl.unit
    local ci   = infl.ci
    if unit and ci and UnitExists(unit) and UnitGUID(unit) == infl.guid then
        local secondCount = ALC.Capture.GearScan.populatedSlotCount(unit)
        if secondCount > (infl.firstSlotCount or 0) then
            ci.gear = ALC.Capture.GearScan.readGear(unit)
        end
        if ALC.Capture.MysticEnchantScan then
            ci.mystic_enchants = {
                applied  = ALC.Capture.MysticEnchantScan.readInspectedEnchants(unit),
                per_slot = ALC.Capture.MysticEnchantScan.readInspectedEnchantsPerSlot(unit),
            }
        end
        if ALC.Capture.CAOScan then
            ci.specialization = ci.specialization or {}
            local inspected = ALC.Capture.CAOScan.readCAOForUnit(unit)
            if inspected then
                ci.specialization.active_spec_idx     = inspected.spec_idx
                ci.specialization.unlocked_specs      = inspected.unlocked_specs
                ci.specialization.ca_known            = inspected.ca_known
                ci.specialization.ca_talent_ranks     = inspected.ca_talent_ranks
                ci.specialization.ca_talent_max_ranks = inspected.ca_talent_max_ranks
                ci.specialization.hero_build          = inspected.hero_build
            end
        end

        local entry = ALC.Capture.InspectCache.get(infl.guid) or {}
        entry.ci = ci
        entry.received_via = "inspect"
        local tracker = ALC.Capture.EncounterTracker
        entry.captured_for_boss     = tracker and tracker.getCurrentBoss() or nil
        entry.captured_for_pull_id  = tracker and tracker.getCurrentPullId() or 0
        if ci then
            ci.captured_for_boss    = entry.captured_for_boss
            ci.captured_for_pull_id = entry.captured_for_pull_id
        end

        -- Detect incomplete captures. When the CA event fires but the
        -- client hasn't populated GetInspectInfo data yet, readCAOForUnit
        -- returns nil and ci.specialization.active_spec_idx ends up nil.
        -- Same kind of race possible on mystic. Retry once, then accept.
        local missingCAO    = (ci and ci.specialization
                               and ci.specialization.active_spec_idx == nil)
        local missingMystic = (ci and (not ci.mystic_enchants
                                or not ci.mystic_enchants.applied
                                or #ci.mystic_enchants.applied == 0))
        local outcome = "success"
        if missingCAO or missingMystic then
            entry.partial_attempts = (entry.partial_attempts or 0) + 1
            if entry.partial_attempts <= 1 then
                outcome = "partial"
            end
            -- 2nd attempt also incomplete -> accept; back to normal schedule
        end
        scheduleNext(entry, outcome)
        ALC.Capture.InspectCache.set(infl.guid, entry)
        local cycleTime = GetTime() - infl.startedAt
        ALC.Core.Logger.debug(string.format("Captured CI for %s [boss=%s, ca=%s me=%s, %.2fs] outcome=%s%s",
            UnitName(unit) or infl.guid,
            tostring(entry.captured_for_boss),
            tostring(infl.gotCA), tostring(infl.gotMystic),
            cycleTime, outcome,
            (missingCAO and " missingCAO" or "") .. (missingMystic and " missingMystic" or "")))
    end

    ClearInspectPlayer()
    I.inFlight = nil
end

-- Called from event handlers AND tick(). Decides if we have enough data to
-- finalize: either all 3 events fired, OR INSPECT_TALENT_READY fired and 3s
-- has elapsed (CA/ME packets either landed or won't).
local function tryFinalize()
    local infl = I.inFlight
    if not infl or infl.finalized then return end
    if not infl.gotTalent then return end  -- need stock inspect first

    if (infl.gotCA and infl.gotMystic) or (GetTime() - infl.talentAt) >= 3.0 then
        finalizeInspect()
    end
end

local function onInspectReady()
    local infl = I.inFlight
    if not infl then return end
    local unit = resolveUnit(infl.guid)
    if not unit or UnitGUID(unit) ~= infl.guid then
        -- Target moved / roster changed before reply landed
        I.inFlight = nil
        ClearInspectPlayer()
        return
    end
    -- Build the CI now while gear/talents are fresh; CAO + mystic get
    -- merged in by finalizeInspect once their events fire (or 3s elapses).
    infl.unit = unit
    infl.ci = ALC.Capture.LocalScan.buildInspectCI(unit, _G.ALC_LocalState.session_id)
    infl.firstSlotCount = ALC.Capture.GearScan.populatedSlotCount(unit)
    infl.gotTalent = true
    infl.talentAt  = GetTime()
    tryFinalize()
end

local function onCAResult()
    local infl = I.inFlight
    if not infl then return end
    infl.gotCA = true
    tryFinalize()
end

local function onMysticResult()
    local infl = I.inFlight
    if not infl then return end
    infl.gotMystic = true
    tryFinalize()
end

-- Scheduler tick: called every INSPECT_MIN_INTERVAL_S
local function tick()
    if I.inFlight then
        local infl = I.inFlight
        local elapsed = now() - infl.startedAt

        -- Safety net: if events fired but tryFinalize wasn't called for
        -- some reason, finalize here. Cheap and idempotent.
        tryFinalize()
        if not I.inFlight then
            -- finalized; fall through to pickNext
        elseif not infl.gotTalent and elapsed > C.INSPECT_TIMEOUT_S then
            -- Hard timeout: never even got the basic INSPECT_TALENT_READY.
            -- Backoff this peer and try the next one.
            local entry = ALC.Capture.InspectCache.get(infl.guid) or {}
            scheduleNext(entry, "timeout")
            ALC.Capture.InspectCache.set(infl.guid, entry)
            ClearInspectPlayer()
            I.inFlight = nil
        else
            return  -- still waiting for current inspect
        end
    end

    local nextGuid = pickNext()
    if not nextGuid then return end

    local unit = resolveUnit(nextGuid)
    if not unit then
        -- Can't resolve GUID to any unit token right now (player out of
        -- range, target lost, etc.). Defer 30s so we don't burn CPU on
        -- this entry every tick.
        local entry = ALC.Capture.InspectCache.get(nextGuid)
        if entry then
            entry.next_scan_at = time() + 30
            ALC.Capture.InspectCache.set(nextGuid, entry)
        end
        return
    end

    local entry = ALC.Capture.InspectCache.get(nextGuid) or {}

    if not canInspectUnit(unit) then
        scheduleNext(entry, "gate_fail")
        ALC.Capture.InspectCache.set(nextGuid, entry)
        return
    end

    entry.last_attempt_at = time()
    entry.attempt_count = (entry.attempt_count or 0) + 1
    ALC.Capture.InspectCache.set(nextGuid, entry)

    I.inFlight = { guid = nextGuid, startedAt = now() }
    -- Stock 3.3.5 inspect for gear / talents / arena teams
    NotifyInspect(unit)
    -- Ascension-specific: trigger CAO inspect packet
    if _G.C_CharacterAdvancement and type(_G.C_CharacterAdvancement.InspectUnit) == "function" then
        pcall(_G.C_CharacterAdvancement.InspectUnit, unit)
    end
    -- Ascension-specific: trigger mystic enchant inspect packet
    if ALC.Capture.MysticEnchantScan then
        ALC.Capture.MysticEnchantScan.requestInspect(unit)
    end
    ALC.Core.Metrics.inc("inspect_sent")
end

function I.onRosterChange()
    -- Purge entries for players no longer in group (raid + party)
    local inRoster = { [UnitGUID("player")] = true }
    for i = 1, (GetNumRaidMembers() or 0) do
        local u = "raid" .. i
        local g = UnitGUID(u)
        if g then inRoster[g] = true end
    end
    for i = 1, (GetNumPartyMembers() or 0) do
        local u = "party" .. i
        local g = UnitGUID(u)
        if g then inRoster[g] = true end
    end
    for guid in pairs(ALC.Capture.InspectCache.snapshot()) do
        if not inRoster[guid] then
            ALC.Capture.InspectCache.delete(guid)
        end
    end
end

-- Event wiring
function I.start()
    ALC.RegisterEvent("INSPECT_TALENT_READY", onInspectReady)
    -- Ascension-specific inspect-result events. We treat any payload as
    -- "ack received" and finalize as soon as both have fired (or 3s
    -- after INSPECT_TALENT_READY, whichever comes first). The /alcv3
    -- probe (2026-04-25) confirmed both events fire reliably with
    -- result codes "CA_INSPECT_OK" / "RE_INSPECT_OK" within ~1.5s.
    ALC.RegisterEvent("INSPECT_CHARACTER_ADVANCEMENT_RESULT", onCAResult)
    ALC.RegisterEvent("MYSTIC_ENCHANT_INSPECT_RESULT", onMysticResult)
    ALC.RegisterEvent("RAID_ROSTER_UPDATE", I.onRosterChange)
    ALC.RegisterEvent("PARTY_MEMBERS_CHANGED", I.onRosterChange)

    -- OnUpdate-driven 2s tick
    local accum = 0
    I.ticker = ALC.frame
    I.ticker:HookScript("OnUpdate", function(self, elapsed)
        accum = accum + elapsed
        if accum >= C.INSPECT_MIN_INTERVAL_S then
            accum = 0
            tick()
        end
    end)

    ALC.Core.Logger.debug("InspectLoop started")
end

-- Manual trigger for /alc inspect-now
function I.inspectNow(unit)
    unit = unit or "target"
    if not UnitExists(unit) or not UnitIsPlayer(unit) then
        ALC.Core.Logger.warn("inspect-now: no player targeted")
        return
    end
    local guid = UnitGUID(unit)
    local entry = ALC.Capture.InspectCache.get(guid) or {}
    entry.next_scan_at = 0
    entry.backoff_until = 0
    entry.inspect_unavailable = false
    ALC.Capture.InspectCache.set(guid, entry)
    tick()
end
