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

-- Per-session monotonic snapshot counter. Bumps each time we slice a CI
-- into chunks, giving every snapshot a unique short ID that the demuxer
-- can use to group its chunks together regardless of how the encounter
-- detector splits them in time. Encoded in base36 (0-9 a-z) for byte
-- thrift in the chunk header. Covered the v1 → v2 envelope bump.
P.snapshotCounter = P.snapshotCounter or 0

-- Encode a non-negative integer as base36, lower-case, no padding.
-- 1-9999 fits in 1-3 chars; covers an entire raid session comfortably.
local function toBase36(n)
    if n == 0 then return "0" end
    local digits = "0123456789abcdefghijklmnopqrstuvwxyz"
    local out = ""
    local x = n
    while x > 0 do
        local r = x - math.floor(x / 36) * 36
        out = digits:sub(r + 1, r + 1) .. out
        x = math.floor(x / 36)
    end
    return out
end

-- Build the chunk wrapper around a raw payload string.
-- Format: [[ALC_CI_v2_<sessionId>_<guid>_<snapshotId>_<seq>/<total>]]<b64>
-- snapshotId is a per-session monotonic counter in base36; the same value
-- stamps every chunk of one snapshot. The demuxer groups chunks by
-- (session, guid, snapshotId), so chunks of one snapshot can never mix
-- with another's even when they straddle an encounter boundary.
local function buildChunk(sessionId, guid, snapshotId, seq, total, b64payload)
    return string.format("[[ALC_CI_v2_%s_%s_%s_%d/%d]]%s",
        sessionId, guid, snapshotId, seq, total, b64payload)
end

-- Slice a base64 payload into chunks sized to fit the fail-reason field.
-- All chunks of one snapshot share the same snapshotId so the demuxer
-- can reassemble them as one unit on the server side.
local function chunkPayload(sessionId, guid, b64)
    P.snapshotCounter = (P.snapshotCounter or 0) + 1
    local snapshotId = toBase36(P.snapshotCounter)

    local maxBody = C.CHUNK_PAYLOAD_MAX_BYTES
    local total = math.ceil(#b64 / maxBody)
    if total < 1 then total = 1 end
    local chunks = {}
    for seq = 1, total do
        local startIdx = (seq - 1) * maxBody + 1
        local endIdx = math.min(startIdx + maxBody - 1, #b64)
        chunks[seq] = buildChunk(sessionId, guid, snapshotId, seq, total, b64:sub(startIdx, endIdx))
    end
    return chunks
end

-- Serialize a CI struct into base64-safe chunks ready for relay injection.
local function serializeCIToChunks(ci)
    if not ci or not ci.session_id or not ci.captured_by_guid then return nil end
    local compressed = ALC.Core.Serialize.serializeCI(ci)
    if not compressed then return nil end
    local b64 = ALC.Core.Base64.encode(compressed)
    if not b64 then return nil end
    return chunkPayload(ci.session_id, ci.player.guid or ci.captured_by_guid, b64)
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

    local count = 0
    for guid, entry in pairs(cache) do
        if entry.ci and entry.last_success_at then
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

    local queued = 0
    for guid, entry in pairs(cache) do
        if entry.ci and entry.last_success_at then
            local key = guid .. ":" .. tostring(entry.last_success_at)
                        .. ":" .. tostring(currentPullId)
            if P.lastPeerEnqueued[key] ~= true then
                P.lastPeerEnqueued[key] = true  -- mark now so subsequent calls don't double-queue
                deferEnqueue({
                    guid = guid,
                    entry = entry,
                    currentBoss = currentBoss,
                    currentPullId = currentPullId,
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
    ALC.RegisterEvent("PLAYER_TALENT_UPDATE", P.publishOwnIfChanged)
    ALC.RegisterEvent("ACTIVE_TALENT_GROUP_CHANGED", P.publishOwnIfChanged)
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
