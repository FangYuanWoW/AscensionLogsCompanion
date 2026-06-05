-- Capture/SnapshotPipeline.lua
-- Connective tissue between LocalScan (which builds CI structs) and
-- SpellFailedRelay (which carries chunks through the combat log on
-- SPELL_CAST_FAILED events).
--
-- On any event that may have changed the player's CI (login, equipment
-- change, talent / spec change, mystic enchant change), rebuild the CI,
-- content-hash compare against the last published version, and if
-- different: serialize, chunk, enqueue to the relay ring buffer.
--
-- Also enqueues peer CIs from the InspectCache (captured by our
-- inspect loop) so a single logger broadcasts the entire raid's data
-- through the combat log.

local ALC = _G.ALC
local P = {}
ALC.Capture.SnapshotPipeline = P

local C = ALC.Core.Constants

P.lastOwnHash = nil
P.lastOwnSerial = 0

local function shouldPublish()
    if not _G.ALC_Config then return false end
    if not ALC_Config.is_logger then return false end
    return true
end

-- A peer CI is only worth broadcasting once it carries gear. An inspect that
-- finalized with zero gear slots (the boss-transition re-inspect race, see
-- InspectLoop) would otherwise ride a frame as a naked keyframe and shadow a
-- good capture in the backend's per-pull selection. InspectLoop already
-- carries forward last-known-good gear when it can; this is the final guard
-- for the cold-start case (peer never successfully gear-read yet) so an empty
-- CI never leaves the client. No player is ever legitimately gearless, so an
-- empty gear list always means capture failure, not a real naked character.
local function peerCIHasGear(ci)
    return ci and ci.gear and #ci.gear > 0
end

-- Serialize a CI struct for relay injection. NEW-ONLY (codec overhaul): the CI
-- always rides an [[ALC_F_v1_c2_...]] dict-deflated frame via the FrameBuilder,
-- which handles delta/keyframe (full CI on first sight, a tiny KEYFRAME_REF for
-- unchanged gear). The legacy per-CI base64 path ([[ALC_CI_v2_...]], plus the
-- c1/c2 transport experiments) was removed - there is no fallback. On success we
-- return an empty list (the frame was enqueued inside the FrameBuilder, so the
-- caller enqueues nothing); on a hard failure we return nil after a loud,
-- throttled warn so a dict/libs misconfig is visible instead of silently lost.
local function serializeCIToChunks(ci)
    if not ci or not ci.session_id or not ci.captured_by_guid then return nil end
    local FB = ALC.Capture.FrameBuilder
    if FB and FB.addCI(ci) then  -- keyframe on first sight, else a tiny ref
        return {}
    end
    if FB then FB.warnDrop("CI") end
    return nil
end

-- Rebuild local CI, compare hash, enqueue chunks if changed.
function P.publishOwnIfChanged()
    if not shouldPublish() then
        ALC.Core.Logger.debug("publishOwn: shouldPublish=false (is_logger=" .. tostring(_G.ALC_Config and ALC_Config.is_logger) .. ")")
        return
    end
    local sessionId = (_G.ALC_LocalState or {}).session_id
    if not sessionId then
        ALC.Core.Logger.debug("publishOwn: no session_id")
        return
    end

    local ci = ALC.Capture.LocalScan.buildLocalCI(sessionId)
    if not ci then
        ALC.Core.Logger.debug("publishOwn: buildLocalCI returned nil")
        return
    end

    -- Stamp current encounter context BEFORE hashing so a boss transition
    -- or new pull_id naturally busts the dedup and triggers a fresh publish
    -- even when gear/talents/etc. are unchanged.
    local tracker = ALC.Capture.EncounterTracker
    if tracker then
        ci.captured_for_boss = tracker.getCurrentBoss()
        ci.captured_for_pull_id = tracker.getCurrentPullId()
    end

    local hash = ALC.Core.Hash.hashCI(ci)
    if hash == P.lastOwnHash then
        ALC.Core.Logger.debug("Own CI unchanged (hash " .. hash .. ")")
        return
    end

    P.lastOwnHash = hash
    P.lastOwnSerial = P.lastOwnSerial + 1
    ci.snapshot_serial = P.lastOwnSerial

    -- Persist for SavedVariables fallback path
    _G.ALC_LocalState.last_own_ci = ci
    _G.ALC_LocalState.last_own_ci_snapshot_serial = P.lastOwnSerial

    local chunks = serializeCIToChunks(ci)
    if not chunks then
        -- Often transient on early PLAYER_LOGIN before AceSerializer +
        -- LibDeflate finish loading. Subsequent calls succeed once libs
        -- are ready, so don't spam the user with a warning.
        ALC.Core.Logger.debug("publishOwn: serializeCIToChunks returned nil (libs not ready yet)")
        return
    end

    for _, chunk in ipairs(chunks) do
        ALC.Transport.SpellFailedRelay.enqueue(chunk)
    end
    ALC.Core.Logger.debug("Own CI enqueued: " .. #chunks .. " chunks (serializer=" .. ALC.Core.Serialize.activePath() .. ", hash " .. hash .. ")")
end

-- Enqueue peer CIs from the inspect cache. Dedup is per-pull, so each new
-- combat-log window gets a fresh broadcast of every cached peer. Without
-- pullId in the dedup key, peers with stable gear were broadcast exactly
-- once per session, producing 2-of-18 coverage on rapid wipe-retry pulls.
--
-- This is the synchronous version, called from the periodic 30s ticker
-- where the freeze cost is amortized across 30s of headroom and not
-- coincident with a combat-start frame. For combat-start (PLAYER_REGEN_DISABLED)
-- use publishPeerInspectsDeferred, which spreads the same work across
-- frames to avoid the burst.
function P.publishPeerInspects()
    if not shouldPublish() then return end
    local cache = ALC.Capture.InspectCache.snapshot()
    P.lastPeerEnqueued = P.lastPeerEnqueued or {}

    local tracker = ALC.Capture.EncounterTracker
    local currentBoss   = tracker and tracker.getCurrentBoss() or nil
    local currentPullId = tracker and tracker.getCurrentPullId() or 0

    -- Live instance at broadcast time. The whole raid shares the logger's
    -- instance, so this reading is authoritative for every peer being emitted,
    -- and by broadcast time the client has long settled past the zone-in window
    -- where GetInstanceInfo can lag. Re-stamping here (instead of trusting the
    -- value frozen at inspect-build) fixes peers riding a stale zone/difficulty
    -- after the raid changes zones. A changed instance busts the F-frame durable
    -- hash, so it costs one re-keyframe per peer per zone change, then collapses
    -- back to refs.
    local liveInstance = ALC.Capture.LocalScan.instanceInfo()

    local count = 0
    for guid, entry in pairs(cache) do
        if entry.ci and entry.last_success_at and peerCIHasGear(entry.ci) then
            local key = guid .. ":" .. tostring(entry.last_success_at)
                        .. ":" .. tostring(currentPullId)
            if P.lastPeerEnqueued[key] ~= true then
                P.lastPeerEnqueued[key] = true
                -- Re-stamp boss/pull context at broadcast time. The CI was
                -- built when the inspect completed, which may have been
                -- pre-pull (currentBoss = nil). At broadcast we have
                -- authoritative tracker state, so the chunk's CI body
                -- reflects the encounter it's being emitted into.
                if currentBoss then
                    entry.ci.captured_for_boss    = currentBoss
                    entry.ci.captured_for_pull_id = currentPullId
                end
                if liveInstance then entry.ci.instance = liveInstance end
                local chunks = serializeCIToChunks(entry.ci)
                if chunks then
                    for _, chunk in ipairs(chunks) do
                        ALC.Transport.SpellFailedRelay.enqueue(chunk)
                    end
                    count = count + #chunks
                end
            end
        end
    end
    if count > 0 then
        ALC.Core.Logger.debug("Peer CIs enqueued: " .. count
            .. " chunks total (pullId=" .. tostring(currentPullId) .. ")")
    end
end

-- Deferred peer-publish queue. Drained by an OnUpdate at PEERS_PER_DEFER_FRAME
-- entries per frame so the synchronous LibDeflate compression cost (~50ms
-- per 25-man peer) doesn't all land on the same frame as PLAYER_REGEN_DISABLED.
-- 0.1.8's wipe-retry coverage fix correctly re-broadcasts every cached peer
-- on each combat enter, but doing it synchronously was the dominant cause
-- of multi-second freezes at combat start (Nace report 7976). Same coverage,
-- spread across ~12 frames at 60fps for a 25-man.
P.deferQueue = nil

local function ensureDeferQueue()
    if P.deferQueue then return P.deferQueue end
    P.deferQueue = {
        items = {},
        head = 1,
        tail = 0,
    }
    return P.deferQueue
end

local function deferQueueSize(q)
    if not q or q.tail < q.head then return 0 end
    return q.tail - q.head + 1
end

local function deferEnqueue(item)
    local q = ensureDeferQueue()
    q.tail = q.tail + 1
    q.items[q.tail] = item
end

local function deferDequeue()
    local q = P.deferQueue
    if not q or q.tail < q.head then return nil end
    local item = q.items[q.head]
    q.items[q.head] = nil
    q.head = q.head + 1
    if q.head > q.tail then
        -- Queue fully drained; reset indices to keep integer growth bounded.
        q.head = 1
        q.tail = 0
    end
    return item
end

-- Build the work queue. Cheap (no compression). The actual serialization
-- happens during drain.
function P.publishPeerInspectsDeferred()
    if not shouldPublish() then return end
    local cache = ALC.Capture.InspectCache.snapshot()
    P.lastPeerEnqueued = P.lastPeerEnqueued or {}

    local tracker = ALC.Capture.EncounterTracker
    local currentBoss   = tracker and tracker.getCurrentBoss() or nil
    local currentPullId = tracker and tracker.getCurrentPullId() or 0

    -- Live instance, captured once at enqueue (combat start, well past the
    -- zone-in settle window) and threaded onto each item exactly like boss/pull.
    -- Applied at drain so re-broadcast peers carry the logger's current zone /
    -- difficulty instead of the value frozen at their inspect. See
    -- publishPeerInspects for the full rationale.
    local liveInstance = ALC.Capture.LocalScan.instanceInfo()

    local queued = 0
    for guid, entry in pairs(cache) do
        if entry.ci and entry.last_success_at and peerCIHasGear(entry.ci) then
            local key = guid .. ":" .. tostring(entry.last_success_at)
                        .. ":" .. tostring(currentPullId)
            if P.lastPeerEnqueued[key] ~= true then
                P.lastPeerEnqueued[key] = true  -- mark now so subsequent calls don't double-queue
                deferEnqueue({
                    guid = guid,
                    entry = entry,
                    currentBoss = currentBoss,
                    currentPullId = currentPullId,
                    instance = liveInstance,
                })
                queued = queued + 1
            end
        end
    end
    if queued > 0 then
        ALC.Core.Logger.debug("Peer CIs deferred: " .. queued
            .. " peers queued (pullId=" .. tostring(currentPullId) .. ")")
    end
end

-- Drain at most PEERS_PER_DEFER_FRAME entries; called every OnUpdate frame.
local function drainDeferQueue()
    local queue = P.deferQueue
    if not queue or deferQueueSize(queue) == 0 then return end
    local budget = C.PEERS_PER_DEFER_FRAME or 2
    local drained = 0
    for _ = 1, budget do
        local item = deferDequeue()
        if not item then break end
        if item and item.entry and item.entry.ci then
            if item.currentBoss then
                item.entry.ci.captured_for_boss    = item.currentBoss
                item.entry.ci.captured_for_pull_id = item.currentPullId
            end
            if item.instance then item.entry.ci.instance = item.instance end
            local chunks = serializeCIToChunks(item.entry.ci)
            if chunks then
                for _, chunk in ipairs(chunks) do
                    ALC.Transport.SpellFailedRelay.enqueue(chunk)
                end
                drained = drained + #chunks
            end
        end
    end
end

-- Helper: enqueue everything we have right now (own + peers, synchronous).
function P.publishAll()
    P.publishOwnIfChanged()
    P.publishPeerInspects()
end

-- Helper: own CI sync (cheap, single peer), peer CIs deferred across frames.
-- Used by PLAYER_REGEN_DISABLED to avoid the burst freeze.
function P.publishAllDeferred()
    P.publishOwnIfChanged()
    P.publishPeerInspectsDeferred()
end

local function onLogin()
    -- Defer initial scan a few seconds so Ascension globals populate.
    if _G.C_Timer and C_Timer.After then
        C_Timer.After(5.0, P.publishOwnIfChanged)
    else
        local f = CreateFrame("Frame")
        local start = GetTime()
        f:SetScript("OnUpdate", function(self, el)
            if GetTime() - start >= 5.0 then
                self:SetScript("OnUpdate", nil); P.publishOwnIfChanged()
            end
        end)
    end
end

-- C_Timer.After with the OnUpdate fallback some 3.3.5 forks need.
local function afterDelay(delay, fn)
    if _G.C_Timer and type(C_Timer.After) == "function" then
        C_Timer.After(delay, fn)
    else
        local f = CreateFrame("Frame")
        local startAt = GetTime()
        f:SetScript("OnUpdate", function(self)
            if GetTime() - startAt >= delay then
                self:SetScript("OnUpdate", nil); fn()
            end
        end)
    end
end

-- Settle-aware own-CI refresh for spec / build / mystic-enchant changes.
--
-- The change events fire BEFORE the client-side build has fully settled:
-- GetActiveSpecID and the CAO talent reads in readCAOForUnit("player") can
-- still return the PRE-swap build for a beat (observed live: own CI hash stayed
-- unchanged through the learn/unlearn burst, then flipped seconds later). A
-- single immediate re-read therefore misses the swap, which is why the logger's
-- own respec was captured only intermittently. So we:
--   1. (Ascension only) kick a per-unit-keyed self CAO inspect to nudge the
--      client cache. C_CharacterAdvancement.InspectUnit is per-unit-keyed (see
--      InspectLoop note), NOT the global NotifyInspect buffer, so this can't
--      clobber an in-flight peer capture. Epoch has no C_CharacterAdvancement
--      and reads own talents straight from GetTalentInfo, so it's skipped there.
--   2. Re-read publishOwnIfChanged on a short backoff. publishOwnIfChanged
--      hash-dedups, so the first re-read that sees the settled build publishes
--      and the rest are no-ops. The whole burst of change events coalesces into
--      one backoff schedule via the ownRefreshScheduled guard.
-- On an Ascension CAO spec swap the new active build is readable almost
-- immediately, but GetActiveSpecID / the per-talent reads in
-- readCAOForUnit("player") can lag the swap event by a beat. We can't watch the
-- content hash to detect "settled" because publishOwnIfChanged hashes the whole
-- CI INCLUDING captured_at (a wall-clock timestamp), so the hash changes every
-- second regardless of build - it only dedups reads within the same second.
-- So we just re-read at a few fixed offsets past the swap: the last one is well
-- clear of any settle lag, and each captures whatever the build is then.
-- publishOwnIfChanged still emits a frame each time, but these are pre-pull
-- keyframes (you can't swap spec in combat) and the next pull's
-- PLAYER_REGEN_DISABLED re-read + force-keyframe lands the authoritative one
-- inside the logged window anyway. The ownRefreshScheduled guard coalesces the
-- burst of swap events into a single set of re-reads.
local OWN_REFRESH_STEPS = { 2.0, 6.0 }
P.ownRefreshScheduled = false
local function scheduleOwnRefresh(reason)
    if P.ownRefreshScheduled then return end
    P.ownRefreshScheduled = true

    -- Ascension only: a per-unit-keyed self CAO inspect nudges the client to
    -- refresh the own build cache (per-unit, NOT the global NotifyInspect
    -- buffer the peer loop guards, so it can't clobber an in-flight peer).
    -- Epoch has no C_CharacterAdvancement; it reads own talents from
    -- GetTalentInfo, which is fresh on the talent event.
    if ALC.Core.Profile and ALC.Core.Profile.isAscension()
       and _G.C_CharacterAdvancement
       and type(_G.C_CharacterAdvancement.InspectUnit) == "function"
       and not (ALC.Capture.InspectLoop and ALC.Capture.InspectLoop.inFlight) then
        pcall(_G.C_CharacterAdvancement.InspectUnit, "player")
    end

    for idx, t in ipairs(OWN_REFRESH_STEPS) do
        afterDelay(t, function()
            ALC.Core.Logger.debug("Own refresh re-read @" .. t .. "s (" .. tostring(reason) .. ")")
            P.publishOwnIfChanged()
            if idx == #OWN_REFRESH_STEPS then P.ownRefreshScheduled = false end
        end)
    end
end
P.scheduleOwnRefresh = scheduleOwnRefresh

function P.start()
    ALC.Core.Logger.debug("SnapshotPipeline.start() invoked")
    -- Triggers that may have changed own CI. All event-fire logs are debug
    -- level - normal users see only the meaningful lifecycle events
    -- (boot, combat-log start/stop) on the info channel.
    ALC.RegisterEvent("PLAYER_LOGIN", function()
        ALC.Core.Logger.debug("Pipeline got PLAYER_LOGIN")
        onLogin()
    end)
    ALC.RegisterEvent("PLAYER_ENTERING_WORLD", function()
        ALC.Core.Logger.debug("Pipeline got PLAYER_ENTERING_WORLD")
        P.publishOwnIfChanged()
    end)
    ALC.RegisterEvent("PLAYER_EQUIPMENT_CHANGED", P.publishOwnIfChanged)

    -- Spec / build / mystic-enchant change. These all route through
    -- scheduleOwnRefresh (settle-aware re-read) instead of a single immediate
    -- publish, because the own build reads stale for a beat after the event.
    -- Registered per-flavor as a union; TryRegisterEvent silently skips the
    -- names the running client doesn't know:
    --   * Epoch (stock WotLK): PLAYER_TALENT_UPDATE / ACTIVE_TALENT_GROUP_CHANGED
    --     fire on talent edits and dual-spec swaps. Both exist on Ascension too
    --     but do NOT fire on a C_CharacterAdvancement spec swap.
    --   * Ascension (C_CharacterAdvancement): the native CA + mystic-link events
    --     are what actually fire on a CAO spec/build/ME change. Missing these is
    --     why the logger's own mid-session respec went uncaptured while peers
    --     (refreshed by the inspect loop) stayed correct.
    local function onSpecChange(event)
        ALC.Core.Logger.debug("Pipeline got " .. event .. " -> scheduleOwnRefresh")
        scheduleOwnRefresh(event)
    end
    ALC.RegisterEvent("PLAYER_TALENT_UPDATE", onSpecChange)
    ALC.RegisterEvent("ACTIVE_TALENT_GROUP_CHANGED", onSpecChange)
    local CA_CHANGE_EVENTS = {
        "ASCENSION_CA_SPECIALIZATION_ACTIVE_ID_CHANGED", -- active spec swap
        "CHARACTER_ADVANCEMENT_UPDATE_ENTRIES_RESULT",   -- build applied/settled
        "CHARACTER_ADVANCEMENT_LEARN_RESULT",            -- talent learned
        "CHARACTER_ADVANCEMENT_UNLEARN_RESULT",          -- talent unlearned
        "MYSTIC_ENCHANT_SPECIALIZATION_LINK_UPDATED",    -- ME preset re-linked on swap
    }
    local registered = {}
    for _, ev in ipairs(CA_CHANGE_EVENTS) do
        if ALC.TryRegisterEvent(ev, onSpecChange) then
            registered[#registered + 1] = ev
        end
    end
    ALC.Core.Logger.debug("Spec-change events registered: "
        .. (table.concat(registered, ", ") ~= "" and table.concat(registered, ", ") or "(none on this client)"))
    ALC.RegisterEvent("PLAYER_REGEN_DISABLED", function()
        ALC.Core.Logger.debug("Pipeline got PLAYER_REGEN_DISABLED")
        -- New pull starts: clear any chunks left over from the prior pull's
        -- queue (would otherwise emit late and mis-attribute to this pull's
        -- combat-log window in the backend's timestamp-based dispatcher),
        -- and clear the per-broadcast dedup so every cached peer re-emits
        -- with fresh pull metadata.
        --
        -- 0.2.0: switched from synchronous publishAll() to publishAllDeferred()
        -- so the 25-peer LibDeflate compression sweep spreads across ~12
        -- frames instead of one. publishOwnIfChanged still runs synchronously
        -- (one peer, cheap, hash-deduped); peer compression is the cost
        -- that needs spreading.
        if ALC.Transport.SpellFailedRelay
           and ALC.Transport.SpellFailedRelay.clearQueue then
            ALC.Transport.SpellFailedRelay.clearQueue()
        end
        P.lastPeerEnqueued = {}

        -- Force the logger's OWN CI to re-keyframe and re-publish this pull.
        -- The own keyframe is otherwise emitted just once at login/zone-in
        -- (pre-combat), where the relay can't drain it and the clearQueue above
        -- wipes it; every later own publish is then a KEYFRAME_REF the server
        -- can't resolve, so the logger renders blank on their own report
        -- (regression since the 0.60.0 codec overhaul). Busting lastOwnHash
        -- makes publishOwnIfChanged actually re-emit, and forceKeyframe makes
        -- that emit a full keyframe that lands inside this pull's logged window.
        P.lastOwnHash = nil
        if ALC.Capture.FrameBuilder and ALC.Capture.FrameBuilder.forceKeyframe then
            ALC.Capture.FrameBuilder.forceKeyframe(UnitGUID("player"))
        end

        P.publishAllDeferred()
    end)
    -- Periodic peer republish: 30s tick (best-effort; 3.3.5 may lack C_Timer).
    -- 0.41.0: switched from synchronous publishPeerInspects() to the deferred
    -- variant. The earlier "amortized across 30s of headroom" reasoning was
    -- wrong: amortization changes how often the freeze fires, not the per-tick
    -- peak. With ~17 cached peers in a Molten Core raid (Bronzebeard report
    -- 2026-05-05) the synchronous tick was producing a ~600ms hard freeze
    -- every 30s, landing on trash pulls and mid-fight casts. The deferred
    -- variant spreads the same compression work across ~25 frames, so the
    -- per-frame budget hit is small enough to feel like stutter rather than a
    -- locked client.
    if _G.C_Timer and C_Timer.NewTicker then
        C_Timer.NewTicker(30.0, P.publishPeerInspectsDeferred)
    else
        local accum = 0
        ALC.frame:HookScript("OnUpdate", function(self, el)
            accum = accum + el
            if accum >= 30.0 then accum = 0; P.publishPeerInspectsDeferred() end
        end)
    end

    -- Drain the deferred peer-publish queue every frame. Cheap fast-path
    -- when queue is empty (one nil-check per frame). Active drain pulls
    -- PEERS_PER_DEFER_FRAME entries through serializeCIToChunks per frame.
    ALC.frame:HookScript("OnUpdate", function(self, el)
        drainDeferQueue()
    end)

    ALC.Core.Logger.debug("SnapshotPipeline.start() registered all events")
end

-- Manual trigger for debugging; exposes via /alc publish-now
function P.forcePublish()
    ALC.Core.Logger.info("Force-publishing local CI...")
    P.lastOwnHash = nil  -- bust the dedup cache
    P.publishOwnIfChanged()
end
