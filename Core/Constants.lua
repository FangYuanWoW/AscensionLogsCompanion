-- Core/Constants.lua
-- All tunable constants in one place. Precomputed string prefixes live here
-- to avoid string concatenation in hot paths.

local ALC = _G.ALC
local C = {}
ALC.Core.Constants = C

-- Version
-- 0.60.6 (peer-instance freshness): re-stamp a peer CI's instance from the
-- logger's LIVE GetInstanceInfo at broadcast time, instead of carrying the value
-- frozen when that peer was last inspected. Instance (zone + difficulty) is a
-- "where is the logger now" property shared by the whole raid, but a re-broadcast
-- peer CI (the dominant CI volume) previously re-stamped only boss/pull and left
-- ci.instance untouched - so after the raid changed zones, cached peers kept
-- emitting the OLD zone/difficulty until each happened to be re-inspected.
-- Smoking gun: report 10627 / encounter 340057 (Snowgrave / Heroic) had 20 of 22
-- CIs stamped "Molten Core / Ascended" (the raid's prior instance), which is not
-- unanimous, so the backend's ALC difficulty fallback bailed and the kill
-- defaulted to 'normal'. Fix stamps live instance in both broadcast paths
-- (SnapshotPipeline.publishPeerInspects + the deferred drainDeferQueue); the
-- logger's own CI already builds with a live instanceInfo() so it self-heals.
-- A changed instance busts the F-frame durable hash, so it costs ONE re-keyframe
-- per peer per zone change, then collapses back to refs - steady-state efficiency
-- within an instance is unchanged. No SCHEMA_VERSION bump: the CI shape is
-- identical (instance field already existed), only WHEN it's repopulated changed,
-- so existing inspect-cache entries keep working and self-correct at next
-- broadcast. No transport/codec changes; 0.60.0 wire format unchanged.
-- 0.60.5 (logger spec-change capture): the logger's OWN mid-session spec / hero-
-- build / mystic-enchant swap is now captured on Bronzebeard by registering the
-- native C_CharacterAdvancement change events (Epoch-safe via TryRegisterEvent;
-- those APIs are absent there). Previously only peers' spec changes were picked
-- up (via the re-inspect cadence); the logger never re-inspects self, so their
-- own respec went unrecorded mid-raid. No transport/codec changes.
-- 0.60.4 (own-CI hotfix + guild field): two changes.
-- (1) Fix the logger's own gear/mystic/talents rendering blank on their own
-- report - a regression since the 0.60.0 codec overhaul. The own CI is
-- delta-encoded like peers (keyframe on first sight, then KEYFRAME_REFs), but
-- the own keyframe is only emitted once at login/zone-in (pre-combat): the
-- relay can't drain it out of combat, the pull-start clearQueue wipes it, and
-- every later own publish is a ref the server can't resolve without the
-- keyframe -> no local row. (Peers are immune: re-inspected every boss, so
-- their keyframes land mid-session.) Fix: at PLAYER_REGEN_DISABLED bust
-- lastOwnHash + FrameBuilder.forceKeyframe(ownGuid) so a full own keyframe
-- re-lands inside each pull's logged window.
-- (2) Add the guild NAME to the ci.player blob (the rich {name,rank_name,
-- rank_index} stays at ci.guild). Additive; backend ignores unknown fields.
-- No transport/codec changes; 0.60.0 wire format unchanged.
-- 0.60.3 (empty-gear hotfix): stop the boss-transition re-inspect race from
-- blanking out raiders' gear. On a boss pull EncounterTracker re-queues the
-- whole raid for an immediate re-inspect; on the Epoch profile the inspect
-- finalizes the moment INSPECT_TALENT_READY fires, but the inspected unit's
-- GetInventoryItemLink often hasn't ripened yet as raiders scatter past the
-- 28y inspect range, so readGear() returns zero slots. That empty read was
-- finalized as success and cached/published as the boss keyframe with a newer
-- captured_at, so it shadowed the good trash-pull capture and the player
-- rendered naked on the boss tab. Fix: an empty gear read is no longer a clean
-- success - InspectLoop.finalizeInspect carries the last-known-good gear
-- forward onto the re-stamped CI (talents/spec stay fresh) and retries up to
-- INSPECT_GEAR_RETRY_MAX times to catch a real gear swap, and SnapshotPipeline
-- never broadcasts a gearless peer CI (cold-start guard). No transport/codec
-- changes; 0.60.0 wire format unchanged.
-- 0.60.2 (inspect hotfix follow-up): close the in-flight finalize race that
-- v0.60.1 left open. v0.60.1 stopped the loop STARTING new inspects while an
-- inspect window was open, but a peer inspect already in flight still
-- finalized (event-driven) and called ClearInspectPlayer(), wiping the
-- buffer the user's open window reads from. Symptom: right after a boss kill
-- (loop queues a fresh full-raid sweep) the FIRST inspect-window open showed
-- no tooltips / naked model, a second open of the same player was fine.
-- Fix: gate every ClearInspectPlayer() call on the new inspectBufferInUse()
-- predicate (character pane OR inspect window shown), so a finishing peer
-- inspect can't clear the buffer out from under the user. Details and Skada
-- never call ClearInspectPlayer at all; the next NotifyInspect repoints the
-- buffer regardless, so the clear is optional. No transport/codec changes.
-- 0.60.1 (inspect hotfix): the background inspect loop now stands down while
-- the user has an INSPECT window open, not just their own character pane.
-- WoW 3.3.5 has a single global last-inspected-unit buffer; firing
-- NotifyInspect on a peer while the user inspects a raider stripped that
-- target's equipped-slot tooltips to bare names and reset the 3D model to
-- naked. The v0.30.12 pause gate only covered the user's own character pane
-- (AscensionCharacterFrame); the inspect-frame case (AscensionInspectFrame /
-- stock InspectFrame) was missed. Details and Skada already yield on an open
-- inspect frame; ALC was the only inspect-firing addon that didn't. Also
-- removed an orphaned InspectFrame:Hide() in the deferred vanity rescan -
-- ALC no longer opens its own inspect frame, so that Hide() only ever slammed
-- shut the user's manual inspect window (visible as the stock InspectFrame on
-- Epoch). No transport/codec changes; 0.60.0 wire format unchanged.
-- 0.60.0 (codec overhaul RELEASED): CI/PP/TS now emit EXCLUSIVELY as
-- [[ALC_F_v1_c2_...]] dict-deflated frames via FrameBuilder; the legacy
-- per-family base64 envelopes ([[ALC_CI_/PP_/TS_]]) and the c1/c2 transport
-- experiments were removed from EMIT. One dict-deflate + base64 per bundled
-- frame, plus delta/keyframe for gear (full CI on first sight, tiny refs after)
-- cut relay drains ~2.75x on a real key. frame_codec defaults to "c2" (no /alc
-- toggle); when the FrameBuilder can't run (dict/libs not ready) the pipelines
-- drop LOUDLY (throttled warn) rather than silently degrade. KS stays on its own
-- legacy [[ALC_KS_v1_]] priority lane (unbundled). The server demuxer (decodes
-- BOTH the new frames AND the legacy envelopes) shipped to prod first; legacy
-- DECODE stays server-side forever for version skew.
-- 0.52.0 (pending, dev on feat/keystone-capture; VERSION stays 0.51.0 until
-- release): KS (keystone) chunk family - fourth ALC family, parallel to CI/PP/
-- TS. Event-driven (not periodic): one "start" record on MYTHIC_PLUS_STARTED
-- and one "complete" record on MYTHIC_PLUS_COMPLETE, the latter carrying the
-- authoritative timed-vs-depleted boolean (arg1). Rides the same
-- SpellFailedRelay transport under [[ALC_KS_v1_...]]. Ascension-only
-- (C_MythicPlus absent on Epoch -> module inert). A thin {is_active, level,
-- dungeon_id} marker also rides ci.instance.keystone so mid-run CI snapshots
-- are self-describing. Schema not yet consumed server-side.
-- 0.50.0: TS (telemetry) chunk family ships. Third ALC chunk family,
-- parallel to CI (combatant info) and PP (pet pairs): periodic encounter
-- snapshots of player positions/vitals + a CLEU-built hostile NPC ledger,
-- transiting the existing SpellFailedRelay under the [[ALC_TS_v1_...]]
-- envelope. Self-throttles against relay backlog; schema not yet consumed
-- server-side, so a dropped snapshot is cosmetic.
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
C.VERSION = "0.60.6"
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

-- Keystone (KS) chunk envelope. Fourth family, parallel to CI / PP / TS.
-- Carries Mythic+ keystone lifecycle EVENTS (not periodic snapshots): one
-- "start" record when MYTHIC_PLUS_STARTED fires and one "complete" record
-- when MYTHIC_PLUS_COMPLETE fires. The complete record's `completed_timed`
-- is the authoritative timed-vs-depleted signal (MYTHIC_PLUS_COMPLETE arg1),
-- confirmed both ways by the 2026-05-27 (depleted, a1=false) and 2026-05-30
-- (timed, a1=true) probe runs. Affixes/level/dungeon are Ascension internal
-- IDs (huge numbers) captured raw; the backend resolves names.
-- Body shape: { schema_version=1, addon_version, stream="keystone",
--   event_type="start"|"complete", session_id, event_id, captured_at,
--   captured_by_guid, server, completed_timed (complete only), keystone={...} }
-- Format: [[ALC_KS_v1_<sessionId>_<eventId>_<seq>/<total>]]<b64>
-- Ascension-only: C_MythicPlus is absent on Epoch, so the module no-ops there.
-- Local experiment as of 0.51.x: schema not yet consumed server-side.
C.KS_SENTINEL_PREFIX  = "[[ALC_KS_v1_"
C.KS_SCHEMA_VERSION   = 1

-- Keystone-outcome drain tuning. The MYTHIC_PLUS_COMPLETE record is enqueued
-- into the relay's PRIORITY lane (drains ahead of the normal CI/PP/TS ring)
-- and the relay is kept active for KS_KEEPALIVE_S after the key ends - even
-- out of combat, where the relay normally sleeps - so the next ORGANIC failed
-- cast (mount, cooldown, "can't do that while moving") carries it into
-- WoWCombatLog.txt. A toast fires only on confirmed landing. (A forced
-- fail-cast was prototyped to guarantee a landing but removed: it requires
-- protected-function calls that taint from insecure code.)
C.KS_KEEPALIVE_S = 45    -- relay stays active this long after MYTHIC_PLUS_COMPLETE

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
-- Max quick retries when an inspect finalizes with zero gear slots (the
-- boss-transition re-inspect race - gear data not yet ripened). Each retry
-- reuses the existing partial-retry cadence (next_scan_at = +5s). Counter
-- resets on any non-empty read and per new boss. See InspectLoop.finalizeInspect.
C.INSPECT_GEAR_RETRY_MAX = 2

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
-- relay as CI and PP, and the relay only drains when the logging player
-- organically fails a cast (a few chunks/min). So the transport, not the
-- 2s timer, sets the real emission rate.
--
-- The 0.50.x hard "skip at 300 chunks" gate turned that shortfall into a
-- dense front-loaded burst followed by dead air: at pull start the ring is
-- near-empty so telemetry fires at 2s, but within ~15-35s the shared queue
-- (TS + the whole-raid CI broadcast) crosses 300 and EVERY later snapshot
-- is skipped, because organic fails can't drain it back under 300. Field
-- reports 9785/9794 showed 6-10% of a fight covered, all at the start.
--
-- 0.51.0 replaces the binary gate with an adaptive cadence: emit at the
-- base interval while the queue is shallow, then stretch the interval
-- toward TELEMETRY_MAX_INTERVAL_S as the queue fills, so generation tracks
-- the channel's real drain rate and the snapshots that DO land spread
-- evenly across the whole fight instead of front-loading. Crucially the
-- cadence NEVER stops on queue depth: it self-throttles by stretching the
-- interval (ramping from TELEMETRY_BACKOFF_START_CHUNKS up to the
-- RELAY_QUEUE_MAX_CHUNKS ring cap) rather than ever gating off, so telemetry
-- stays continuous for the whole encounter. There is no queue-pressure skip;
-- the only stops are the intentional scope gates (logger / combatlog /
-- combat / instance).
C.TELEMETRY_INTERVAL_S              = 2.0   -- base cadence (shallow queue)
C.TELEMETRY_MAX_INTERVAL_S          = 20.0  -- most-stretched cadence (queue near ring cap)
C.TELEMETRY_BACKOFF_START_CHUNKS    = 80    -- begin stretching the interval past this depth
C.TELEMETRY_MONSTER_ACTIVE_WINDOW_S = 12.0
C.TELEMETRY_MONSTER_PRUNE_AFTER_S   = 60.0

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
    keystone_enabled     = true,  -- 0.51.x local experiment: KS chunk emission for Mythic+ keystone start/complete lifecycle events (Ascension only; no-op on Epoch). Not yet consumed server-side.
    keystone_keepalive   = true,  -- 0.51.x: on key complete, keep the relay active for KS_KEEPALIVE_S out of combat so an organic failed cast flushes the priority outcome chunk. Set false to drain only while in combat.
    keystone_toast       = true,  -- 0.51.x: show an on-screen toast when the key-outcome chunk is confirmed landed in the combat log.
    -- 0.53.0 (NEW-ONLY, local/dev): CI/PP/TS ride [[ALC_F_v1_c2_...]] dict-deflated
    -- frames exclusively; there is no per-family legacy emit path anymore. This
    -- defaults ON and there is no /alc toggle. Editing this in SavedVariables to
    -- anything other than "c2" disables the ONLY emit path for CI/PP/TS (KS is
    -- unaffected - separate priority lane), so the pipelines will warn loudly and
    -- drop. The deprecated ci_codec / ci_transport_c1 gates were removed with the
    -- legacy CI base64 path they fed.
    frame_codec          = "c2",
}
