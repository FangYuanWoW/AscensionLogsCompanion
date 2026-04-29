-- Core/Constants.lua
-- All tunable constants in one place. Precomputed string prefixes live here
-- to avoid string concatenation in hot paths.

local ALC = _G.ALC
local C = {}
ALC.Core.Constants = C

-- Version
C.VERSION = "0.1.9"
C.SCHEMA_VERSION = 2

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
C.INSPECT_MIN_INTERVAL_S = 1.0  -- empirically validated 2026-04-25 on Bronzebeard via /alcprobe throttle-blast 1.0: 24/24 fires got replies, 0% server-throttled. 25-man cold cycle: 48s → 24s.
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
