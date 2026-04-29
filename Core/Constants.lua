-- Core/Constants.lua
-- All tunable constants in one place. Precomputed string prefixes live here
-- to avoid string concatenation in hot paths.

local ALC = _G.ALC
local C = {}
ALC.Core.Constants = C

-- Version
C.VERSION = "0.2.4"
-- Bumped to 3 in 0.2.0: snapshot header gained a `server` field
-- ("ascension" | "epoch" | "unknown") so the backend can dispatch per-server
-- parsing for talents / mystic / vanity. Forces an inspect-cache wipe on
-- first 0.2.0 boot via InspectCache.rehydrate's schema guard, which is
-- acceptable; the cache repopulates within the first cold cycle.
C.SCHEMA_VERSION = 3

-- Addon channel
C.ADDON_PREFIX = "ALC"

-- CI sentinel (precomputed prefix; full sentinel built per chunk).
-- Bumped to v2 in 0.1.9: chunk header now carries a per-snapshot ID so
-- the server-side demuxer can group chunks by snapshot regardless of
-- encounter boundary, eliminating the cross-snapshot Frankenstein decode
-- class of bugs (see report 7980 for the smoking-gun case). Backend
-- accepts both v1 and v2 sentinels during the rollout window.
C.CI_SENTINEL_PREFIX = "[[ALC_CI_v2_"
C.CI_SENTINEL_SUFFIX = "]]"

-- Inspect timings
C.INSPECT_MIN_INTERVAL_S = 1.0  -- empirically validated 2026-04-25 on Bronzebeard via /alcprobe throttle-blast 1.0: 24/24 fires got replies, 0% server-throttled. 25-man cold cycle: 48s → 24s. Legacy fallback when ALC.Profile is unset.

-- Per-server inspect throttle. Resolved by ALC.Core.Profile.inspectIntervalSeconds()
-- after Profile.detect() runs in Init.lua boot. Validated 2026-04-28 on Epoch
-- (Kezan) via /epochprobe throttle-blast: 24/24 replies at 0.30s close-range,
-- so 0.5s leaves comfortable margin and roughly halves cold-cycle time vs
-- Ascension's 1.0s floor.
C.INSPECT_MIN_INTERVAL_S_BY_PROFILE = {
    ascension = 1.0,
    epoch     = 0.5,
}
C.INSPECT_TIMEOUT_S      = 5.0
C.INSPECT_RESCAN_MS      = 300000  -- 5 min (used when boss tracking pins a current boss)
C.INSPECT_NOBOSS_RESCAN_MS = 60000   -- 1 min fallback when no boss is tracked (heroic dungeons, custom content, EncounterTracker silent failures)
C.INSPECT_STALE_MS       = 600000  -- 10 min
C.INSPECT_BACKOFF_MAX_S  = 60

-- SavedVariables bounds
C.INSPECT_CACHE_MAX_ENTRIES = 100
C.SESSION_LOG_MAX_DAYS      = 30
C.SESSION_LOG_MAX_BYTES     = 10 * 1024 * 1024  -- 10 MB

-- Addon channel flow control
C.ADDON_MSG_MAX_BYTES        = 255  -- WoW hard limit
C.ADDON_MSG_OUTBOUND_PER_SEC = 8    -- below WoW's ~10/s cap
C.ADDON_MSG_JOIN_CAP_S       = 10   -- first 10s after raid join
C.ADDON_MSG_JOIN_CAP_RATE    = 2    -- 2 msg/s during login storm window
C.HELLO_JITTER_MAX_S         = 3.0

-- Hijack queue
C.HIJACK_QUEUE_MAX_CHUNKS = 400
C.HIJACK_CHUNK_TTL_S      = 600  -- 10 min

-- Chunking
-- Empirically validated 2026-04-24 on Ascension 3.3.5: 800-char fail-reason
-- field survives the combat log writer intact (931-char total line length).
-- We use 700 to leave headroom against any per-encounter spike or
-- realm-config divergence.
C.CHUNK_SENTINEL_RESERVE_BYTES = 62  -- [[ALC_CI_v1_<23-char session>_<18-char guid>_<seq>/<total>]] worst-case; seq/total stays 3-char up to 9-chunk CIs which covers everything we've seen
C.CHUNK_PAYLOAD_MAX_BYTES      = 950  -- empirical 1023-char fail-reason cap measured on Bronzebeard 2026-04-25 (length-set 1024 truncated to "_EN", losing the trailing D); 950 leaves 11-char margin for sentinel growth + server variance

-- CI freshness thresholds
C.CI_FRESH_MAX_MS   = 60000
C.CI_STALE_MAX_MS   = 180000

-- Vanity divergence-poll cap. The vanity overlay packet ripens client-side
-- after the initial inspect on a non-deterministic delay; we re-read
-- GetInventoryItemID a few times until divergence appears or we give up.
-- 8 polls × 1s = 8s total ripening window, comfortably wider than the
-- typical 2-4s we've seen in the wild on Bronzebeard.
C.VANITY_POLL_MAX_ATTEMPTS = 8
C.VANITY_POLL_INTERVAL_S = 1.0

-- Peers per OnUpdate frame when draining the deferred publish queue. With
-- 60fps and a 25-man raid that's 24 peers / 2 per frame = 12 frames =
-- ~200ms to drain the queue, vs ~1s synchronous burn before. Tunable.
C.PEERS_PER_DEFER_FRAME = 2

-- Defaults for config
C.DEFAULT_CONFIG = {
    debug = false,
    auto_combatlog_on_raid = true,
    broadcast_enabled = true,
    hijack_enabled = true,
    is_logger = true,
    silent_auto_logging = false,  -- skip both start + stop popups; logging stays on across zone changes until user manually toggles
    log_dungeons = true,          -- when off, auto-/combatlog only fires for raids (instanceType=="raid"), skipping 5-man dungeons
}
