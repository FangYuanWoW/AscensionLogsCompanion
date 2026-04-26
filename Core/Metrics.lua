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
    peer_ci_received       = 0,
    peer_ci_deduped        = 0,
    boss_transitions       = 0,  -- new boss detected -> triggers re-inspect cycle
    max_payload_len        = 0,  -- largest chunk observed; flag if creeping up
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
    log("Hijack: " .. c.chunks_flushed .. " flushed / " .. c.chunks_queued .. " queued")
    if c.chunks_dropped_ttl > 0 or c.chunks_dropped_overflow > 0 then
        log("  drops: " .. c.chunks_dropped_ttl .. " TTL, " .. c.chunks_dropped_overflow .. " overflow")
    end
    log("Inspect: " .. c.inspect_success .. " success / " .. c.inspect_sent .. " sent / "
        .. c.inspect_timeout .. " timeout / " .. c.inspect_gate_fail .. " gate-fail")
    if c.max_payload_len > 0 then
        log("Max chunk payload observed: " .. c.max_payload_len .. " bytes")
    end
    if c.last_flush_at then
        log("Last flush: " .. (time() - c.last_flush_at) .. "s ago")
    end
end
