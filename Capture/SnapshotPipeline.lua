-- Capture/SnapshotPipeline.lua
-- Connective tissue between LocalScan (which builds CI structs) and
-- SpellFailedHijack (which injects chunks into the combat log).
--
-- On any event that may have changed the player's CI (login, equipment
-- change, talent / spec change, mystic enchant change), rebuild the CI,
-- content-hash compare against the last published version, and if
-- different: serialize, chunk, enqueue to the hijack ring buffer.
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

-- Serialize a CI struct into base64-safe chunks ready for hijack injection.
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
        ALC.Transport.SpellFailedHijack.enqueue(chunk)
    end
    ALC.Core.Logger.debug("Own CI enqueued: " .. #chunks .. " chunks (serializer=" .. ALC.Core.Serialize.activePath() .. ", hash " .. hash .. ")")
end

-- Enqueue peer CIs from the inspect cache. Dedup is per-pull, so each new
-- combat-log window gets a fresh broadcast of every cached peer. Without
-- pullId in the dedup key, peers with stable gear were broadcast exactly
-- once per session, producing 2-of-18 coverage on rapid wipe-retry pulls.
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
                        ALC.Transport.SpellFailedHijack.enqueue(chunk)
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

-- Helper: enqueue everything we have right now (own + peers).
function P.publishAll()
    P.publishOwnIfChanged()
    P.publishPeerInspects()
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
        -- with fresh pull metadata. publishAll re-enqueues everything.
        if ALC.Transport.SpellFailedHijack
           and ALC.Transport.SpellFailedHijack.clearQueue then
            ALC.Transport.SpellFailedHijack.clearQueue()
        end
        P.lastPeerEnqueued = {}
        P.publishAll()
    end)
    -- Periodic peer republish: 30s tick (best-effort; 3.3.5 may lack C_Timer)
    if _G.C_Timer and C_Timer.NewTicker then
        C_Timer.NewTicker(30.0, P.publishPeerInspects)
    else
        local accum = 0
        ALC.frame:HookScript("OnUpdate", function(self, el)
            accum = accum + el
            if accum >= 30.0 then accum = 0; P.publishPeerInspects() end
        end)
    end
    ALC.Core.Logger.debug("SnapshotPipeline.start() registered all events")
end

-- Manual trigger for debugging; exposes via /alc publish-now
function P.forcePublish()
    ALC.Core.Logger.info("Force-publishing local CI...")
    P.lastOwnHash = nil  -- bust the dedup cache
    P.publishOwnIfChanged()
end
