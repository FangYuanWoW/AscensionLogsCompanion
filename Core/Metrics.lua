-- Core/Metrics.lua
-- Session-local counters for observability. Exported via /alc status
-- and persisted to ALC_LocalState.metrics on logout so post-raid analysis
-- can reconcile against CI rows landed server-side.

local ALC = _G.ALC
local M = {}
ALC.Core.Metrics = M

M.counters = {
    chunks_queued          = 0,  -- every enqueue increments
    chunks_flushed         = 0,  -- incremented when a chunk gets rotated out
    chunks_dropped_ttl     = 0,  -- aged out (>10 min without being flushed)
    chunks_dropped_overflow = 0, -- ring buffer evicted on push
    hijack_activations     = 0,  -- transitions false->true
    hijack_deactivations   = 0,  -- transitions true->false
    inspect_sent           = 0,  -- NotifyInspect calls fired
    inspect_success        = 0,  -- INSPECT_TALENT_READY resolved to CI
    inspect_timeout        = 0,  -- 5s elapsed with no reply
    inspect_gate_fail      = 0,  -- CanInspect preconditions failed
    inspect_partial        = 0,  -- inspect landed but the CI was missing CAO or mystic data. A CAPTURE, not a loss - counted apart from inspect_success, which is why success/sent alone cannot be read as a failure rate.
    inspect_unreachable_skip = 0, -- 0.71.0: candidate rejected at SELECTION time for range. NOT comparable to inspect_gate_fail across versions - this counts evaluations, gate_fail counts spent ticks, and pre-0.71.0 every rejection was a spent tick.
    inspect_unresolved     = 0,  -- 0.70.1: pickNext returned a GUID that resolves to no unit token, so the tick was spent on nothing. A cache holding out-of-group GUIDs shows up here first.
    roster_refresh_gain    = 0,  -- 0.70.1: group slots recovered by the tick-driven roster rebuild (0.70.0+)
    peer_ci_received       = 0,
    peer_ci_deduped        = 0,
    boss_transitions       = 0,  -- new boss detected -> triggers re-inspect cycle
    max_payload_len        = 0,  -- largest chunk observed; flag if creeping up
    taint_errors_suppressed = 0, -- 0.40.0: ScriptErrorsFrame "tainted the call" hits filtered before display
    taint_popups_suppressed = 0, -- 0.40.0: ADDON_ACTION_FORBIDDEN/BLOCKED modal hits filtered before display
    last_flush_at          = nil,
    last_reset_at          = time(),
}

function M.inc(key, n)
    M.counters[key] = (M.counters[key] or 0) + (n or 1)
end

function M.observe_payload_len(len)
    if len > (M.counters.max_payload_len or 0) then
        M.counters.max_payload_len = len
    end
end

function M.mark_flush()
    M.counters.last_flush_at = time()
    M.inc("chunks_flushed")
end

function M.snapshot()
    local out = {}
    for k, v in pairs(M.counters) do out[k] = v end
    return out
end

function M.reset()
    for k, v in pairs(M.counters) do
        if type(v) == "number" then
            M.counters[k] = 0
        else
            M.counters[k] = nil
        end
    end
    M.counters.last_reset_at = time()
end

function M.persist()
    _G.ALC_LocalState = _G.ALC_LocalState or {}
    ALC_LocalState.metrics = M.snapshot()
end

-- Pretty-print for /alc status
function M.report(logger)
    local c = M.counters
    local log = logger or ALC.Core.Logger.info
    log("Relay: " .. c.chunks_flushed .. " flushed / " .. c.chunks_queued .. " queued")
    if c.chunks_dropped_ttl > 0 or c.chunks_dropped_overflow > 0 then
        log("  drops: " .. c.chunks_dropped_ttl .. " TTL, " .. c.chunks_dropped_overflow .. " overflow")
    end
    log("Inspect: " .. c.inspect_success .. " success / " .. c.inspect_sent .. " sent / "
        .. (c.inspect_partial or 0) .. " partial / "
        .. c.inspect_timeout .. " timeout / " .. c.inspect_gate_fail .. " gate-fail / "
        .. (c.inspect_unresolved or 0) .. " unresolved / "
        .. (c.inspect_unreachable_skip or 0) .. " out-of-range skips")
    local IL = ALC.Capture and ALC.Capture.InspectLoop
    if IL then
        local cacheN = 0
        for _ in pairs(ALC.Capture.InspectCache.snapshot()) do cacheN = cacheN + 1 end
        log("Roster: " .. #(IL.rosterGuids or {}) .. " tracked / "
            .. (IL.rosterUnresolved or 0) .. " unresolved / " .. cacheN .. " cached"
            .. " (+" .. (c.roster_refresh_gain or 0) .. " recovered)")
    end
    if c.max_payload_len > 0 then
        log("Max chunk payload observed: " .. c.max_payload_len .. " bytes")
    end
    if (c.taint_errors_suppressed or 0) > 0 or (c.taint_popups_suppressed or 0) > 0 then
        log("Taint suppressed: " .. (c.taint_errors_suppressed or 0) .. " errors, "
            .. (c.taint_popups_suppressed or 0) .. " popups")
    end
    if c.last_flush_at then
        log("Last flush: " .. (time() - c.last_flush_at) .. "s ago")
    end
end
