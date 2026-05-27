-- Core/Constants.lua
-- All tunable constants in one place. Precomputed string prefixes live here
-- to avoid string concatenation in hot paths.

local ALC = _G.ALC
local C = {}
ALC.Core.Constants = C

-- Version
-- 0.42.1: roster-cache perf pass. InspectLoop now keeps a GUID->unit hash
-- (rebuilt on roster events, lazy-revalidated on miss) instead of rescanning
-- raid1..raidN per resolveUnit/pickNext call. SnapshotPipeline.deferQueue
-- switched from table.remove(queue,1) to a head/tail FIFO, eliminating the
-- O(n) shift per drained peer in large-group inspect bursts.
-- 0.42.0: new PP chunk family for ground-truth {owner, pet} GUID pairs
-- captured from the controlled-pet unit slots (raidNpet / partyNpet / pet).
-- Rides the existing SpellFailedRelay transport with a distinct envelope
-- ([[ALC_PP_v1_...]]) so the server parser can route pet pairs independently
-- of CI snapshots. Relay landed-evidence + UIErrorsFrame suppressor
-- generalized to match the family prefix [[ALC_ so both chunk families
-- transit cleanly through the same SPELL_CAST_FAILED hijack.
C.VERSION = "0.42.1"
-- Bumped to 3 in 0.2.0: snapshot header gained a `server` field
-- ("ascension" | "epoch" | "unknown") so the backend can dispatch per-server
-- parsing for talents / mystic / vanity.
-- Bumped to 4 in 0.2.5: added transmog_viewing field on local CIs (logger's
-- "show transmog on inspect" preference). Backend uses this to flag reports
-- where peer-gear data may be poisoned by Ascension's q=6/ilvl=1 mythic
-- appearance overlays. Forces an inspect-cache wipe on first 0.2.5 boot
-- via InspectCache.rehydrate's schema guard; repopulates within the first
-- cold cycle. (A short-lived 0.3.0 experiment that dropped vanity_item_id
-- entirely was reverted before broad release; that path also bumped schema
-- to 4 but with a different shape, so users who briefly ran 0.3.0 should
-- expect a clean inspect cache repopulation regardless.)
-- Bumped to 5 in 0.30.4: ci.talents (Epoch path) now ships both spec slots
-- as `{ talent_groups = { [1]={tabs}, [2]={tabs} }, active_group = N }`,
-- with talents keyed by the game's actual talent index instead of insertion
-- order. Pre-v5 Epoch captures only read slot 1 by default and silently
-- mis-attributed any character whose active spec was in slot 2 (root cause
-- for Themeatman / Saws looking like Arms while raiding as Fury). Forces an
-- inspect-cache wipe on first 0.30.4 boot via InspectCache.rehydrate's
-- schema guard.
C.SCHEMA_VERSION = 5

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

-- Pet-pair (PP) chunk envelope. Parallel family to CI, carried by the same
-- SpellFailedRelay transport but routed to a different server-side demuxer.
-- Body shape: { v=1, session_id, captured_for_boss, captured_for_pull_id,
-- pairs = { {o=<ownerGuid>, p=<petGuid>}, ... } }
-- Format: [[ALC_PP_v<schema>_<sessionId>_<snapshotId>_<seq>/<total>]]<b64>
C.PP_SENTINEL_PREFIX = "[[ALC_PP_v1_"
C.PP_SCHEMA_VERSION  = 1

-- Family prefix shared by all ALC chunk envelopes (CI, PP, TS, any future
-- family). Used by:
--   - SpellFailedRelay landed-evidence check: confirms the prior chunk landed
--     in WoWCombatLog.txt by matching failedType against the family prefix
--     (any ALC-family chunk landing is sufficient evidence).
--   - UIErrorsFrame suppressor: silent-drop any red-text message starting
--     with the family prefix so chunks landing on uncovered fail-reason
--     globals don't leak into the user's UI.
-- Kept short so any future v3+ CI or v2+ PP family bumps don't require
-- updating two suppressors in lockstep.
C.RELAY_FAMILY_PREFIX = "[[ALC_"

-- Telemetry (TS) chunk envelope. Third family, parallel to CI and PP.
-- Carries periodic encounter telemetry (player positions + vitals + targets
-- + hostile NPC ledger) through the same SpellFailedRelay transport.
-- Body shape: { schema_version=1, addon_version, stream="telemetry",
--   event_type, session_id, snapshot_id, captured_at, captured_by_guid,
--   server, reason, encounter, map, units=[...], monsters=[...] }
-- Format: [[ALC_TS_v1_<sessionId>_<snapshotId>_<seq>/<total>]]<b64>
-- Local experiment as of 0.42.1: schema not yet consumed server-side.
C.TS_SENTINEL_PREFIX     = "[[ALC_TS_v1_"
C.TELEMETRY_SCHEMA_VERSION = 1

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

-- Relay queue (chunk transport via SPELL_CAST_FAILED localized fail-reason)
C.RELAY_QUEUE_MAX_CHUNKS = 400
C.RELAY_CHUNK_TTL_S      = 600  -- 10 min

-- CLEU SPELL_CAST_FAILED arg index for the localized fail-reason text.
-- Stock 3.3.5 puts failedType at index 12 of the COMBAT_LOG_EVENT_UNFILTERED
-- payload. Ascension's custom client confirmed via /alcprobe failedtype-arg
-- (validated 2026-04-30 on Bronzebeard). If a future client patch shifts
-- args, re-run the probe and update this constant.
C.RELAY_FAILEDTYPE_ARG_INDEX = 12

-- Canonical list of SPELL_FAILED_* globals the relay rewrites during chunk
-- transport. Ordered most-observed first (real Ascension raid logs in
-- ascensionLogs/data/downloads). Sources for the expanded set:
--   - Original Phase-1 starter set (38 entries; covered ~24% of fail volume)
--   - Diff of `2026-04-30-22.53.58 WoWCombatLog.txt` non-ALC SPELL_CAST_FAILED
--     reasons against /alcprobe dump-failreasons output (live _G snapshot of
--     285 SPELL_FAILED_* string globals on enUS Bronzebeard 2026-04-30):
--       SPELL_FAILED_INTERRUPTED_COMBAT  ("Interrupted")
--       SPELL_FAILED_ONLY_STEALTHED      ("You must be in stealth mode.")
--       SPELL_FAILED_NOT_HERE            ("You can't use that here.")
--       SPELL_FAILED_MOVING              ("Can't do that while moving")
--       SPELL_FAILED_CUSTOM_ERROR_32     ("Must be in Cat Form")
--
-- IMPORTANT: three high-volume strings on this client come from C-side
-- formatting and have NO matching _G global, so the relay cannot carry chunks
-- on those events:
--   - "Not enough rage"                 (414 events / 22-min log; bear/warrior)
--   - "Not enough energy"               (352 events; rogue/cat-druid)
--   - "Can't do that while horrified"   (73 events; Ascension custom mechanic)
-- These account for ~76% of chunk-loss events. The structural fix is the
-- landed-evidence gating in SpellFailedRelay.onSpellCastFailed, which uses
-- RELAY_FAILEDTYPE_ARG_INDEX above to read failedType and confirm the prior
-- chunk landed via RELAY_FAMILY_PREFIX match before advancing the queue.
-- Globals list expansion below is a complement, not a substitute, for the
-- gating fix.
C.RELAY_FAIL_GLOBALS = {
    -- Tier 1: high-frequency (original Phase-1 set)
    "SPELL_FAILED_NOT_READY",                -- "Not yet recovered" (cooldown spam; dominant)
    "SPELL_FAILED_INTERRUPTED",
    "SPELL_FAILED_INTERRUPTED_COMBAT",       -- added 0.2.7: same "Interrupted" string, alt code path
    "SPELL_FAILED_OUT_OF_RANGE",
    "SPELL_FAILED_LINE_OF_SIGHT",
    "SPELL_FAILED_INVALID_TARGET",
    "SPELL_FAILED_BAD_TARGETS",
    "SPELL_FAILED_NO_TARGETS",
    "SPELL_FAILED_TARGETS_DEAD",
    "SPELL_FAILED_CASTER_DEAD",
    "SPELL_FAILED_UNIT_NOT_INFRONT",
    "SPELL_FAILED_NOT_INFRONT",
    "SPELL_FAILED_NOT_BEHIND",
    "SPELL_FAILED_TOO_CLOSE",
    "SPELL_FAILED_AURA_BOUNCED",
    "SPELL_FAILED_AFFECTING_COMBAT",
    "SPELL_FAILED_ALREADY_AT_FULL_HEALTH",
    "SPELL_FAILED_ALREADY_AT_FULL_POWER",
    "SPELL_FAILED_CASTER_AURASTATE",
    "SPELL_FAILED_STUNNED",
    "SPELL_FAILED_CHARMED",
    "SPELL_FAILED_CONFUSED",
    "SPELL_FAILED_FLEEING",
    "SPELL_FAILED_PACIFIED",
    "SPELL_FAILED_SILENCED",
    "SPELL_FAILED_SPELL_IN_PROGRESS",
    "SPELL_FAILED_IMMUNE",
    "SPELL_FAILED_NO_COMBO_POINTS",
    "SPELL_FAILED_BAD_IMPLICIT_TARGETS",
    "SPELL_FAILED_CANT_BE_CHARMED",
    "SPELL_FAILED_CANT_BE_DISENCHANTED",
    "SPELL_FAILED_CANT_BE_MILLED",
    "SPELL_FAILED_CANT_BE_PROSPECTED",
    "SPELL_FAILED_CANT_CAST_ON_TAPPED",
    "SPELL_FAILED_LOW_CASTLEVEL",
    "SPELL_FAILED_ITEM_NOT_READY",
    "SPELL_FAILED_TOO_MANY_OF_ITEM",
    "SPELL_FAILED_MOREPOWERFULSPELLACTIVE",

    -- Tier 2: added 0.2.7 from leak-tally diff
    "SPELL_FAILED_ONLY_STEALTHED",           -- "You must be in stealth mode."
    "SPELL_FAILED_NOT_HERE",                 -- "You can't use that here."
    "SPELL_FAILED_MOVING",                   -- "Can't do that while moving"
    "SPELL_FAILED_CUSTOM_ERROR_32",          -- "Must be in Cat Form" (Ascension-specific slot)
}

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

-- Delay between INSPECT_TALENT_READY and the actual gear/talent read.
-- Empirical observation 2026-04-29 via /aip probe on a Shaman peer with
-- the Ascension q=6/ilvl=1 mythic appearance system (Fel Betrayer set):
-- GetInventoryItemLink initially returns the VISUAL appearance item id
-- (cached state from before inspect packet 2 lands) and FLIPS to the real
-- underlying item id at ~290ms after INSPECT_TALENT_READY. No event
-- signals the flip. We defer the readGear call by 400ms so we capture the
-- post-flip (real) item ids instead of the pre-flip (visual) ids. 400ms
-- gives ~110ms margin past the observed flip while staying well inside
-- the 1.0s inspect tick budget (cold-cycle time unchanged).
C.INSPECT_FLIP_DELAY_S = 0.4

-- Vanity divergence-poll cap. The vanity overlay packet ripens client-side
-- after the initial inspect on a non-deterministic delay; we re-read
-- GetInventoryItemID a few times until divergence appears or we give up.
-- 8 polls × 1s = 8s total ripening window, comfortably wider than the
-- typical 2-4s we've seen in the wild on Bronzebeard.
C.VANITY_POLL_MAX_ATTEMPTS = 8
C.VANITY_POLL_INTERVAL_S = 1.0

-- Encounter telemetry cadence. Snapshots compress + chunk through the same
-- relay as CI and PP, so we throttle on three axes: interval (how often to
-- emit), monster active/prune windows (which mobs are in-band for the
-- snapshot), and a queue-pressure backoff (skip snapshots when the relay
-- is already saturated, since adding more would just deepen the backlog).
C.TELEMETRY_INTERVAL_S              = 2.0
C.TELEMETRY_MONSTER_ACTIVE_WINDOW_S = 12.0
C.TELEMETRY_MONSTER_PRUNE_AFTER_S   = 60.0
C.TELEMETRY_QUEUE_SKIP_AT_CHUNKS    = 300

-- Peers per OnUpdate frame when draining the deferred publish queue.
-- 0.41.0: dropped from 2 to 1. At 2 peers/frame the per-frame compression
-- cost was ~100ms (2 x ~50ms LibDeflate), which is ~6 dropped frames at
-- 60fps and still felt as a stutter on average hardware. At 1 peer/frame
-- the per-frame cost is ~50ms (~3 dropped frames), wall-time drain for
-- 25 cached peers grows from ~200ms to ~400ms, but the engine stays
-- responsive enough that input is not blocked. This is now also the
-- periodic 30s republish path, so per-frame smoothness matters more than
-- total drain wall-time.
C.PEERS_PER_DEFER_FRAME = 1

-- Defaults for config
C.DEFAULT_CONFIG = {
    debug = false,
    auto_combatlog_on_raid = true,
    broadcast_enabled = true,
    hijack_enabled = true,
    is_logger = true,
    silent_auto_logging = false,  -- skip both start + stop popups; logging stays on across zone changes until user manually toggles
    log_dungeons = true,          -- when off, auto-/combatlog only fires for raids (instanceType=="raid"), skipping 5-man dungeons
    pet_tracking_enabled = true,  -- 0.42.0: PP chunk emission for {owner, pet} GUID pairs from controlled-pet unit slots
    telemetry_enabled    = true,  -- 0.42.1 local experiment: TS chunk emission for periodic encounter telemetry (positions, vitals, hostile NPC ledger). Not yet consumed server-side.
}
