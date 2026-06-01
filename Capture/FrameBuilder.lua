-- Capture/FrameBuilder.lua
-- F-frame builder (codec overhaul Phase 4). Collects typed records (CI/TS/PP)
-- from the capture pipelines and packs them into [[ALC_F_v1_c2_...]] frames: one
-- AceSerializer-per-record, the whole frame deflated once with the D1 dictionary
-- and base64-encoded, bundling the small records (TS/PP) into a single chunk/row.
--
-- Gated by ALC_Config.frame_codec == "c2"; OFF -> every pipeline keeps its
-- legacy per-family base64 path untouched. KS is intentionally NOT routed here:
-- its outcome record needs the relay's priority lane and must not share fate
-- with a bundled frame.
--
-- Transport stays base64 (ASCII): the server reads uploads through readline's
-- UTF-8 decoder, which destroys raw 8-bit bytes.

local ALC = _G.ALC
local FB = {}
ALC.Capture.FrameBuilder = FB

local C = ALC.Core.Constants

FB.TYPE = { CI = 0x01, PP = 0x02, TS = 0x03, KEYFRAME_REF = 0x12 }

-- Delta/keyframe state (per session). A player's gear is sent as a full CI
-- "keyframe" on first sight; unchanged per-pull re-broadcasts become tiny
-- references that re-bind the cached keyframe to the new pull. Re-keyframe every
-- REKEYFRAME_EVERY refs so a lost keyframe orphans at most that many refs.
FB.sentKeyframes = {}   -- guid -> durable hash (number)
FB.refsSince = {}       -- guid -> refs emitted since the last keyframe
FB.REKEYFRAME_EVERY = 8
-- Fields that change every pull but don't change the player's gear identity;
-- excluded from the durable hash (and `kf`, which we stamp onto keyframes).
local VOLATILE = {
    captured_at = true, captured_for_boss = true, captured_for_pull_id = true,
    snapshot_serial = true, kf = true,
}

FB.pending = {}        -- array of { type, body = <ace text> }
FB.pendingBytes = 0
FB.frameCounter = 0
FB.oldestAt = nil      -- time() when the current pending batch started

-- Raw budget per frame, sized EMPIRICALLY (addons/alc-codec/measure-frame-sizing.js):
-- ~8 telemetry snapshots (8.5KB raw) dict-deflate to ~936B base64 == one 950B
-- chunk, because consecutive TS snapshots are near-identical and dedupe hard.
-- Holding to one chunk keeps a frame to one row (bounded loss) while bundling
-- maximally - 8 TS in one drain instead of eight.
FB.FRAME_RAW_BUDGET = 7700
-- Cap how long a partial batch waits so time-stamped TS still drains (captured_at
-- preserves replay placement). At TS's 2s cadence this bundles ~5 snapshots
-- (~828B, ~87% of a chunk) before the hold fires.
FB.MAX_HOLD_S = 10

local digits = "0123456789abcdefghijklmnopqrstuvwxyz"
local function toBase36(n)
    if n == 0 then return "0" end
    local out, x = "", n
    while x > 0 do
        local r = x - math.floor(x / 36) * 36
        out = digits:sub(r + 1, r + 1) .. out
        x = math.floor(x / 36)
    end
    return out
end

function FB.enabled()
    return _G.ALC_Config and ALC_Config.frame_codec == "c2"
        and ALC.Core.Frame ~= nil
        and ALC.Core.Serialize.deflateWithDict ~= nil
end

-- A pipeline hands a record struct + its type. We AceSerialize it now (cheap)
-- and hold the text; the whole frame is deflated once at flush. Returns true if
-- the record was accepted (caller then skips its legacy emit).
function FB.add(recType, struct)
    if not FB.enabled() then return false end
    local body = ALC.Core.Serialize.aceEncode(struct)
    if not body then return false end
    -- CI is large + durable: flush any pending small records first, then emit
    -- the CI as its own frame so it never shares a chunk's fate with TS/PP.
    if recType == FB.TYPE.CI then
        FB.flush()
        FB.pending = { { type = recType, body = body } }
        FB.pendingBytes = #body
        FB.oldestAt = time()
        FB.flush()
        return true
    end
    if #FB.pending == 0 then FB.oldestAt = time() end
    FB.pending[#FB.pending + 1] = { type = recType, body = body }
    FB.pendingBytes = FB.pendingBytes + #body
    -- Emit as soon as we've got a chunk's worth; otherwise the ticker flushes
    -- on the max-hold so records accumulate into shared frames in between.
    if FB.pendingBytes >= FB.FRAME_RAW_BUDGET then FB.flush() end
    return true
end

-- Hash the CI's gear identity (volatile per-pull binding excluded) so the same
-- player with unchanged gear across pulls produces the same keyframe id.
local function durableHashCI(ci)
    local tmp = {}
    for k, v in pairs(ci) do
        if not VOLATILE[k] then tmp[k] = v end
    end
    return ALC.Core.Hash.hashCI(tmp)
end

-- CI entry point (delta/keyframe). Keyframe on first sight, gear change, or the
-- periodic refresh; otherwise a tiny KEYFRAME_REF that re-binds the cached
-- keyframe to this pull. The server caches keyframes by (guid, kf) and resolves
-- refs against them. Collapses per-pull re-broadcasts of unchanged gear (the
-- dominant CI volume in a dungeon) from a full CI to ~50 bytes.
function FB.addCI(ci)
    if not FB.enabled() then return false end
    local guid = (ci.player and ci.player.guid) or ci.captured_by_guid
    if not guid then return FB.add(FB.TYPE.CI, ci) end
    local dh = durableHashCI(ci)
    local refs = FB.refsSince[guid] or 0
    if FB.sentKeyframes[guid] == dh and refs < FB.REKEYFRAME_EVERY then
        FB.refsSince[guid] = refs + 1
        return FB.add(FB.TYPE.KEYFRAME_REF, {
            g = guid, h = dh,
            b = ci.captured_for_boss, p = ci.captured_for_pull_id, t = ci.captured_at,
        })
    end
    -- (re)keyframe: first sight, gear change, or periodic refresh
    FB.sentKeyframes[guid] = dh
    FB.refsSince[guid] = 0
    ci.kf = dh
    return FB.add(FB.TYPE.CI, ci)
end

-- Ticker entry point: flush only when there's a full batch or the hold expired,
-- so small records (TS) actually bundle instead of each going out alone.
function FB.tick()
    if #FB.pending == 0 then return end
    if FB.pendingBytes >= FB.FRAME_RAW_BUDGET
       or (FB.oldestAt and (time() - FB.oldestAt) >= FB.MAX_HOLD_S) then
        FB.flush()
    end
end

local function buildFrameChunks(sessionId, frameRecords)
    FB.frameCounter = FB.frameCounter + 1
    local frameId = toBase36(FB.frameCounter)
    local frame = ALC.Core.Frame.encode(frameRecords)
    local compressed = ALC.Core.Serialize.deflateWithDict(frame)
    if not compressed then return nil end
    local b64 = ALC.Core.Base64.encode(compressed)
    if not b64 then return nil end
    local maxBody = C.CHUNK_PAYLOAD_MAX_BYTES
    local total = math.ceil(#b64 / maxBody)
    if total < 1 then total = 1 end
    local chunks = {}
    for seq = 1, total do
        local s = (seq - 1) * maxBody + 1
        local e = math.min(s + maxBody - 1, #b64)
        chunks[seq] = string.format("[[ALC_F_v1_c2_%s_%s_%d/%d]]%s",
            sessionId, frameId, seq, total, b64:sub(s, e))
    end
    return chunks
end

-- Pack all pending records into frames (each <= budget) and enqueue them.
function FB.flush()
    if #FB.pending == 0 then return end
    local sessionId = (_G.ALC_LocalState or {}).session_id
    if not sessionId then return end
    local relay = ALC.Transport.SpellFailedRelay

    local records, bytes = {}, 0
    local function emit()
        if #records == 0 then return end
        local chunks = buildFrameChunks(sessionId, records)
        if chunks and relay then
            for _, ch in ipairs(chunks) do relay.enqueue(ch) end
        end
        records, bytes = {}, 0
    end
    for _, rec in ipairs(FB.pending) do
        if bytes > 0 and (bytes + #rec.body) > FB.FRAME_RAW_BUDGET then emit() end
        records[#records + 1] = rec
        bytes = bytes + #rec.body
    end
    emit()
    FB.pending = {}
    FB.pendingBytes = 0
    FB.oldestAt = nil
end

-- Periodic flush so time-sensitive records (TS) don't linger between the budget
-- triggers. Self-starts on login.
function FB.start()
    if FB._started then return end
    FB._started = true
    -- Drain any partial batch when combat ends so time-stamped TS isn't stranded
    -- in a short pull.
    if ALC.RegisterEvent then
        ALC.RegisterEvent("PLAYER_REGEN_ENABLED", function() FB.flush() end)
    end
    if _G.C_Timer and C_Timer.NewTicker then
        C_Timer.NewTicker(1.0, function() FB.tick() end)
    elseif ALC.frame then
        local accum = 0
        ALC.frame:HookScript("OnUpdate", function(self, el)
            accum = accum + el
            if accum >= 1.0 then accum = 0; FB.tick() end
        end)
    end
end

if ALC.RegisterEvent then ALC.RegisterEvent("PLAYER_LOGIN", FB.start) end

return FB
