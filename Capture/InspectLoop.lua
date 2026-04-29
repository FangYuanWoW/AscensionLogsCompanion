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

-- Transmog-visibility gate. When the user has C_Appearance.SetCanSeeAppearances
-- disabled, GetInventoryItemLink already returns the real (non-vanity) item,
-- so all the vanity-overlay capture work is pointless. Skip it to free up
-- inspect budget for raid coverage. When transmog viewing is on (default
-- WoW behavior), keep doing the full vanity capture path.
--
-- On Epoch, C_Appearance doesn't exist AND there's no transmog system at all
-- (verified 2026-04-28 via probe: zero divergence across all slots, no
-- C_VanityCollection / C_Wardrobe / C_Transmog / EpochTransmog globals). So
-- we short-circuit to false on the epoch profile to skip all vanity work.
local function transmogVisible()
    if ALC.Profile == "epoch" then return false end
    if type(_G.C_Appearance) ~= "table"
       or type(C_Appearance.CanSeeAppearances) ~= "function" then
        return true  -- API absent; assume worst case (transmog visible)
    end
    local ok, val = pcall(C_Appearance.CanSeeAppearances)
    return (ok and val) and true or false
end

-- Forward declaration: vanityPoll calls resolveUnit which is defined below.
-- Lua resolves locals lexically at parse time, so without this declaration
-- the reference would resolve to global _G.resolveUnit (nil) and crash at
-- first poll. Same gotcha that bit v0.1.7's broadcast/scheduleAnnounce; see
-- ascension-logs-companion-developer-guide.md "Forward declarations".
local resolveUnit

-- Lightweight vanity-divergence poll. Replaces the heavy "next_scan_at = +1s"
-- retry that re-fired full inspects. This only re-reads GetInventoryItemID
-- (a client-side cache lookup) and patches vanity_item_id onto the cached
-- gear entries when divergence newly appears.
--
-- Self-rescheduling: each poll either finds divergence and stops, or
-- bumps vanity_check_attempts and queues another poll, up to
-- VANITY_POLL_MAX_ATTEMPTS. Stops if config disables vanity capture or
-- if we lose the unit.
local function vanityPoll(guid)
    local entry = ALC.Capture.InspectCache.get(guid)
    if not entry or not entry.ci or not entry.ci.gear then return end
    if entry.vanity_check_attempts == nil then return end  -- divergence already found, or aborted

    local unit = resolveUnit(guid)
    if not unit or not UnitExists(unit) or UnitGUID(unit) ~= guid then
        -- Unit gone (out of range, zoned, deserted); stop polling
        entry.vanity_check_attempts = nil
        ALC.Capture.InspectCache.set(guid, entry)
        return
    end
    if not GetInventoryItemID then return end

    local newDiverges = 0
    for _, gearEntry in ipairs(entry.ci.gear) do
        local slot = gearEntry.slot
        if slot then
            local appearanceId = GetInventoryItemID(unit, slot)
            if appearanceId and appearanceId ~= gearEntry.item_id
               and gearEntry.vanity_item_id ~= appearanceId then
                gearEntry.vanity_item_id = appearanceId
                newDiverges = newDiverges + 1
            end
        end
    end

    if newDiverges > 0 then
        entry.vanity_check_attempts = nil
        entry.vanity_check_pull_id = nil
        entry.last_success_at = time()
        ALC.Capture.InspectCache.set(guid, entry)
        if ALC.Capture.SnapshotPipeline and ALC.Capture.SnapshotPipeline.publishPeerInspects then
            ALC.Capture.SnapshotPipeline.publishPeerInspects()
        end
        ALC.Core.Logger.debug(string.format(
            "vanityPoll patched %d slot(s) for %s after %d attempt(s)",
            newDiverges, UnitName(unit) or guid, entry.vanity_check_attempts or 0))
        return
    end

    -- No divergence yet; reschedule if we have attempts left
    local attempts = (entry.vanity_check_attempts or 0) + 1
    if attempts < C.VANITY_POLL_MAX_ATTEMPTS then
        entry.vanity_check_attempts = attempts
        ALC.Capture.InspectCache.set(guid, entry)
        if _G.C_Timer and C_Timer.After then
            C_Timer.After(C.VANITY_POLL_INTERVAL_S, function() vanityPoll(guid) end)
        end
    else
        -- Cap reached; give up. No divergence => assume no transmog.
        entry.vanity_check_attempts = nil
        ALC.Capture.InspectCache.set(guid, entry)
    end
end

-- Public entry point so finalizeInspect can request a poll.
function I.scheduleVanityPoll(guid)
    if _G.C_Timer and C_Timer.After then
        C_Timer.After(C.VANITY_POLL_INTERVAL_S, function() vanityPoll(guid) end)
    end
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

-- Assigned (not `local function`) to satisfy the forward declaration above.
-- `local function` would shadow the forward decl with a fresh local, leaving
-- vanityPoll's reference still pointing at global nil.
resolveUnit = function(guid)
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
        -- Vanity re-scan: GetInventoryItemID for inspected units may take
        -- longer to populate than GetInventoryItemLink. Patch vanity_item_id
        -- onto whatever entries diverge now. Skipped entirely when the user
        -- has transmog viewing off, since GetInventoryItemLink already
        -- returns real gear in that case and divergence detection is moot.
        if transmogVisible() and ci.gear and GetInventoryItemID then
            for _, entry in ipairs(ci.gear) do
                local slot = entry.slot
                if slot then
                    local appearanceId = GetInventoryItemID(unit, slot)
                    if appearanceId and appearanceId ~= entry.item_id then
                        entry.vanity_item_id = appearanceId
                    end
                end
            end
        end
        -- Ascension-only enrichment: mystic enchants + CAO talent state.
        -- Both APIs are absent on Epoch (probe-confirmed), and the inspect
        -- result events for them never fire there.
        if ALC.Profile ~= "epoch" then
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
        end

        -- Epoch enrichment: rich vanilla 3-tab talent shape on ci.talents.
        -- Backend dispatches by snapshot's `server` field. The shallow
        -- specialization.vanilla_talents (rank-only) stays populated by
        -- LocalScan.buildInspectCI for back-compat with v0.1.x parsers.
        if ALC.Profile == "epoch" and ALC.Capture.EpochTalentScan then
            ci.talents = ALC.Capture.EpochTalentScan.readInspectedTalents(unit)
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
        --
        -- On Epoch neither CAO nor mystic exist, so both fields will always
        -- be missing and the partial-retry would loop forever for nothing.
        -- Skip the partial detection entirely on epoch; talent + gear are
        -- the entire payload and INSPECT_TALENT_READY firing means we have
        -- both already.
        local missingCAO, missingMystic = false, false
        if ALC.Profile ~= "epoch" then
            missingCAO    = (ci and ci.specialization
                             and ci.specialization.active_spec_idx == nil)
            missingMystic = (ci and (not ci.mystic_enchants
                                or not ci.mystic_enchants.applied
                                or #ci.mystic_enchants.applied == 0))
        end
        local outcome = "success"
        if missingCAO or missingMystic then
            entry.partial_attempts = (entry.partial_attempts or 0) + 1
            if entry.partial_attempts <= 1 then
                outcome = "partial"
            end
            -- 2nd attempt also incomplete -> accept; back to normal schedule
        end
        -- Always advance last_success_at on a successful inspect. Earlier
        -- versions reverted it when gear was unchanged so SnapshotPipeline's
        -- per-(guid, ts) dedup would skip the iteration; that turned out to
        -- silently kill peer re-broadcast across rapid wipe-retry pulls
        -- (2-of-18 coverage on pull #2+). Re-broadcast scope is now per-pull
        -- in publishPeerInspects, and the demuxer's
        -- (encounter_id, character_id, source, captured_at) unique
        -- constraint absorbs any over-emission within a pull.
        scheduleNext(entry, outcome)

        -- Vanity-staleness poll: when GetInventoryItemLink and GetInventoryItemID
        -- both return the same value (no divergence), we can't distinguish
        -- "no transmog" from "API not yet ripened to expose the divergence."
        -- The transient hybrid state where divergence appears is
        -- non-deterministic, so we re-poll up to VANITY_POLL_MAX_ATTEMPTS
        -- times at VANITY_POLL_INTERVAL_S intervals.
        --
        -- 0.2.0 redesign: previously this set entry.next_scan_at = +1s, which
        -- sent the peer back through the full inspect loop tick - re-firing
        -- NotifyInspect + C_CharacterAdvancement.InspectUnit + C_MysticEnchant.Inspect
        -- on every retry. Three server packets × 10 retries × 24 peers per pull
        -- was the dominant baseline-CPU and inspect-loop-budget cost reported
        -- by Nace in ZG report 7976.
        --
        -- The new path uses a self-rescheduling C_Timer.After closure that ONLY
        -- re-reads GetInventoryItemID for the cached gear slots. No server
        -- packets, no event roundtrip, no inspect-loop tick consumed. The
        -- deferred 8s rescan in tick() (below) already proved this read-only
        -- pattern works for vanity ripening. Cost per poll: 19 GetInventoryItemID
        -- calls + 19 integer compares = microseconds.
        if transmogVisible() and outcome == "success" and ci and ci.gear then
            local newPullId = tracker and tracker.getCurrentPullId() or 0
            if entry.vanity_check_pull_id ~= newPullId then
                entry.vanity_check_attempts = 0
                entry.vanity_check_pull_id = newPullId
            end

            local divergedSlots = 0
            for _, gearEntry in ipairs(ci.gear) do
                if gearEntry.vanity_item_id then
                    divergedSlots = divergedSlots + 1
                end
            end

            if divergedSlots > 0 then
                entry.vanity_check_attempts = nil
                entry.vanity_check_pull_id = nil
            elseif (entry.vanity_check_attempts or 0) < C.VANITY_POLL_MAX_ATTEMPTS then
                I.scheduleVanityPoll(infl.guid)
            end
        end

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
--
-- On Epoch there is no CA / Mystic event flow at all, so finalize as soon
-- as INSPECT_TALENT_READY fires. Probe (2026-04-28) measured the talent
-- event firing reliably ~+0.22s after NotifyInspect, so this gives us a
-- ~5x faster cycle on Epoch than the Ascension 3-event wait would.
local function tryFinalize()
    local infl = I.inFlight
    if not infl or infl.finalized then return end
    if not infl.gotTalent then return end  -- need stock inspect first

    if ALC.Profile == "epoch" then
        finalizeInspect()
        return
    end

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
    -- Stock 3.3.5 inspect for talents / mystic / guild / race. Gear data
    -- now comes from LibOpenRaid's LRS broadcasts (see PeerGearListener),
    -- so we don't need the InspectUnit + SetAlpha(0) trick that was
    -- attempting to ripen the inspect-frame-only vanity-overlay packets.
    -- That trick was rough (occasional frame flashes, complexity) and
    -- still didn't reliably surface divergence. Plain NotifyInspect is
    -- enough for the lighter fields.
    NotifyInspect(unit)
    if ALC.Profile ~= "epoch" then
        -- Ascension-specific: trigger CAO inspect packet
        if _G.C_CharacterAdvancement and type(_G.C_CharacterAdvancement.InspectUnit) == "function" then
            pcall(_G.C_CharacterAdvancement.InspectUnit, unit)
        end
        -- Ascension-specific: trigger mystic enchant inspect packet
        if ALC.Capture.MysticEnchantScan then
            ALC.Capture.MysticEnchantScan.requestInspect(unit)
        end
    end
    ALC.Core.Metrics.inc("inspect_sent")

    -- Schedule a deferred vanity-overlay re-scan when transmog viewing is
    -- on. Out-of-combat manual inspects (e.g. in Orgrimmar) reliably surface
    -- divergence because the user keeps the frame open 5-30s. In-combat
    -- auto-inspects need a longer read window for the same packets to
    -- arrive. 8s is a compromise between API ripening and publish delay.
    -- If transmog viewing is off, GetInventoryItemLink already returns the
    -- real (non-vanity) item, so the rescan is pointless and we skip it.
    if transmogVisible() then
        local deferredGuid = nextGuid
        local deferredFn = function()
            if not UnitExists(unit) or UnitGUID(unit) ~= deferredGuid then return end
            local cachedEntry = ALC.Capture.InspectCache.get(deferredGuid)
            if not cachedEntry or not cachedEntry.ci or not cachedEntry.ci.gear then return end
            if not GetInventoryItemID then return end

            local newDiverges = 0
            for _, gearEntry in ipairs(cachedEntry.ci.gear) do
                local slot = gearEntry.slot
                if slot then
                    local appearanceId = GetInventoryItemID(unit, slot)
                    if appearanceId and appearanceId ~= gearEntry.item_id
                       and gearEntry.vanity_item_id ~= appearanceId then
                        gearEntry.vanity_item_id = appearanceId
                        newDiverges = newDiverges + 1
                    end
                end
            end

            if newDiverges > 0 then
                -- Bump last_success_at so the next publishPeerInspects
                -- treats this as a fresh CI worth re-enqueueing.
                cachedEntry.last_success_at = time()
                cachedEntry.vanity_check_attempts = nil
                ALC.Capture.InspectCache.set(deferredGuid, cachedEntry)
                if ALC.Capture.SnapshotPipeline and ALC.Capture.SnapshotPipeline.publishPeerInspects then
                    ALC.Capture.SnapshotPipeline.publishPeerInspects()
                end
                ALC.Core.Logger.debug(string.format(
                    "Deferred vanity-rescan patched %d slot(s) for %s and re-published.",
                    newDiverges, UnitName(unit) or deferredGuid))
            end

            -- Close the InspectFrame opened by InspectUnit() in tick(). We
            -- SetAlpha(0)'d it to keep it invisible while events fired; now
            -- that we've read what we need, hide it and restore alpha so the
            -- user's next manual right-click→Inspect renders normally.
            if _G.InspectFrame then
                pcall(InspectFrame.Hide, InspectFrame)
                pcall(InspectFrame.SetAlpha, InspectFrame, 1)
            end
        end

        if _G.C_Timer and C_Timer.After then
            C_Timer.After(8.0, deferredFn)
        else
            local tf = CreateFrame("Frame")
            local startedAt = GetTime()
            tf:SetScript("OnUpdate", function(self, el)
                if GetTime() - startedAt >= 8.0 then
                    self:SetScript("OnUpdate", nil); deferredFn()
                end
            end)
        end
    end
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
    if ALC.Profile ~= "epoch" then
        -- Ascension-specific inspect-result events. We treat any payload as
        -- "ack received" and finalize as soon as both have fired (or 3s
        -- after INSPECT_TALENT_READY, whichever comes first). The /alcv3
        -- probe (2026-04-25) confirmed both events fire reliably with
        -- result codes "CA_INSPECT_OK" / "RE_INSPECT_OK" within ~1.5s.
        -- These events do not exist on Epoch, where INSPECT_TALENT_READY
        -- alone carries the full payload.
        ALC.RegisterEvent("INSPECT_CHARACTER_ADVANCEMENT_RESULT", onCAResult)
        ALC.RegisterEvent("MYSTIC_ENCHANT_INSPECT_RESULT", onMysticResult)
    end
    ALC.RegisterEvent("RAID_ROSTER_UPDATE", I.onRosterChange)
    ALC.RegisterEvent("PARTY_MEMBERS_CHANGED", I.onRosterChange)

    -- OnUpdate-driven tick. Per-profile interval: 1.0s on Ascension
    -- (Bronzebeard-validated 24/24 at 1.0s), 0.5s on Epoch (probe-validated
    -- 24/24 at 0.30s, 0.5s leaves margin and roughly halves cold-cycle).
    local interval = ALC.Core.Profile.inspectIntervalSeconds()
    local accum = 0
    I.ticker = ALC.frame
    I.ticker:HookScript("OnUpdate", function(self, elapsed)
        accum = accum + elapsed
        if accum >= interval then
            accum = 0
            tick()
        end
    end)

    ALC.Core.Logger.debug(string.format(
        "InspectLoop started (profile=%s, interval=%.2fs)",
        tostring(ALC.Profile), interval))
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
