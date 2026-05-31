-- Capture/PetPipeline.lua
-- Chunker + relay enqueuer for {owner, pet} GUID-pair batches captured by
-- PetTracker. Mirrors SnapshotPipeline's shape but emits a distinct chunk
-- envelope ([[ALC_PP_v1_...]]) so the server-side demuxer can route pet
-- pairs separately from full CI snapshots.
--
-- Envelope: [[ALC_PP_v1_<sessionId>_<snapshotId>_<seq>/<total>]]<b64>
--   - No <guid> field (pair lists are not owned by a single character)
--   - snapshotId is a per-session base36 counter, independent from
--     SnapshotPipeline's CI counter to avoid demuxer collision
--
-- Payload body (pre-deflate, pre-base64):
--   { v=1,
--     session_id=<sessionId>,
--     captured_for_boss=<bossName or nil>,
--     captured_for_pull_id=<pullId or 0>,
--     pairs={ {o=<ownerGuid>, p=<petGuid>}, ... } }
-- Short field names keep raw payload tight; GUIDs already deflate well
-- (shared 0xF130.../0xF140... prefixes).

local ALC = _G.ALC
local P = {}
ALC.Capture.PetPipeline = P

local C = ALC.Core.Constants

-- Per-session monotonic snapshot counter. Bumps each call to publishPairs;
-- every chunk of the same emission shares the snapshotId so the demuxer
-- can reassemble multi-chunk pet snapshots (rare; almost all PP emissions
-- fit in 1 chunk).
P.snapshotCounter = P.snapshotCounter or 0

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

local function buildChunk(sessionId, snapshotId, seq, total, b64payload)
    return string.format("%s%s_%s_%d/%d%s%s",
        C.PP_SENTINEL_PREFIX,
        sessionId, snapshotId, seq, total,
        C.CI_SENTINEL_SUFFIX,
        b64payload)
end

local function chunkPayload(sessionId, b64)
    P.snapshotCounter = (P.snapshotCounter or 0) + 1
    local snapshotId = toBase36(P.snapshotCounter)
    local maxBody = C.CHUNK_PAYLOAD_MAX_BYTES
    local total = math.ceil(#b64 / maxBody)
    if total < 1 then total = 1 end
    local chunks = {}
    for seq = 1, total do
        local startIdx = (seq - 1) * maxBody + 1
        local endIdx = math.min(startIdx + maxBody - 1, #b64)
        chunks[seq] = buildChunk(sessionId, snapshotId, seq, total, b64:sub(startIdx, endIdx))
    end
    return chunks
end

local function shouldPublish()
    if not _G.ALC_Config then return false end
    if ALC_Config.pet_tracking_enabled == false then return false end
    if not ALC_Config.is_logger then return false end
    return true
end

-- Public entrypoint. pairs is a list of {owner=<guid>, pet=<guid>} tables.
-- Builds one snapshot per call; the snapshotId groups all chunks of this
-- emission together for demuxer reassembly. Drops on the floor if libs
-- aren't ready, no session id is set, or the user is not a logger.
function P.publishPairs(pairs)
    if not pairs or #pairs == 0 then return end
    if not shouldPublish() then return end

    local sessionId = (_G.ALC_LocalState or {}).session_id
    if not sessionId then
        ALC.Core.Logger.debug("PetPipeline: no session_id, skipping")
        return
    end

    local tracker = ALC.Capture.EncounterTracker
    local boss   = tracker and tracker.getCurrentBoss   and tracker.getCurrentBoss()   or nil
    local pullId = tracker and tracker.getCurrentPullId and tracker.getCurrentPullId() or 0

    local body = {
        v = C.PP_SCHEMA_VERSION,
        session_id = sessionId,
        captured_for_boss = boss,
        captured_for_pull_id = pullId,
        pairs = {},
    }
    for i = 1, #pairs do
        body.pairs[i] = { o = pairs[i].owner, p = pairs[i].pet }
    end

    -- Phase 4 frame gate: bundle this pet-pair record into an [[ALC_F_...]] frame.
    if ALC.Capture.FrameBuilder and ALC.Capture.FrameBuilder.enabled() then
        ALC.Capture.FrameBuilder.add(ALC.Capture.FrameBuilder.TYPE.PP, body)
        return
    end

    -- Reuse the generic Ace+Deflate serializer. Despite the "CI" naming,
    -- the function is body-agnostic (Lua table -> deflated binary string).
    local compressed = ALC.Core.Serialize.serializeCI(body)
    if not compressed then
        ALC.Core.Logger.debug("PetPipeline: serializer returned nil (libs not ready yet)")
        return
    end
    local b64 = ALC.Core.Base64.encode(compressed)
    if not b64 then return end

    local chunks = chunkPayload(sessionId, b64)
    if not chunks then return end

    for _, chunk in ipairs(chunks) do
        ALC.Transport.SpellFailedRelay.enqueue(chunk)
    end

    ALC.Core.Logger.debug(string.format(
        "PetPipeline enqueued: %d pairs in %d chunks (pullId=%s, boss=%s)",
        #pairs, #chunks, tostring(pullId), tostring(boss)))
end

function P.start()
    -- No event handlers; PetTracker calls publishPairs directly. Module
    -- exists for symmetry with SnapshotPipeline and to host the chunker.
    ALC.Core.Logger.debug("PetPipeline.start() ready")
end
