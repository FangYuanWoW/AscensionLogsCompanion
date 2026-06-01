-- Capture/PetPipeline.lua
-- Builds {owner, pet} GUID-pair batch bodies captured by PetTracker and hands
-- them to the FrameBuilder as PP records.
--
-- NEW-ONLY (codec overhaul): pet pairs ride an [[ALC_F_v1_c2_...]] dict-deflated
-- frame (record type PP), bundled alongside CI/TS. The legacy per-PP base64
-- envelope ([[ALC_PP_v1_...]]) and this module's own chunker were removed; the
-- server frame demuxer routes PP records by their 1-byte type. KS is the only
-- family still on a standalone legacy envelope (its own priority lane).
--
-- Payload body (the PP record, pre-frame):
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

    -- NEW-ONLY (codec overhaul): pet pairs ride an [[ALC_F_v1_c2_...]] frame via
    -- the FrameBuilder (record type PP). The legacy per-PP base64 envelope
    -- ([[ALC_PP_v1_...]]) was removed - there is no fallback, so a drop warns
    -- loudly instead of silently degrading.
    local FB = ALC.Capture.FrameBuilder
    if FB and FB.add(FB.TYPE.PP, body) then
        ALC.Core.Logger.debug(string.format(
            "PetPipeline framed: %d pairs (pullId=%s, boss=%s)",
            #pairs, tostring(pullId), tostring(boss)))
        return
    end
    if FB then FB.warnDrop("PP") end
end

function P.start()
    -- No event handlers; PetTracker calls publishPairs directly. Module
    -- exists for symmetry with SnapshotPipeline and to host the chunker.
    ALC.Core.Logger.debug("PetPipeline.start() ready")
end
