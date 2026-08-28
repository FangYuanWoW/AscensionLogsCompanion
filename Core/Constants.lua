-- Core/Constants.lua
-- All tunable constants in one place. Precomputed string prefixes live here
-- to avoid string concatenation in hot paths.

local ALC = _G.ALC
local C = {}
ALC.Core.Constants = C

-- Addon folder identity, derived at runtime from the file vararg. The .toc
-- loader passes the addon's folder name as the first vararg to every Lua file
-- it loads, so deriving it here (instead of hardcoding "AscensionLogsCompanion")
-- lets a rebranded build keep working without touching code: a per-tenant
-- packaging step can rename the folder (e.g. to TriumvirateLogsCompanion) and
-- the ADDON_LOADED boot gate, every Media\ texture path, the LibDBIcon registry
-- name, and the WoW taint-message string match (WoW builds that message from the
-- folder name) all follow the real folder name automatically.
local ADDON_NAME = ...
C.ADDON_FOLDER = ADDON_NAME or "AscensionLogsCompanion"
C.MEDIA_PATH   = "Interface\\AddOns\\" .. C.ADDON_FOLDER .. "\\Media\\"

-- Version
-- 0.68.0 (per-content-type logging gates): a new log_raids toggle (Settings
-- panel, default ON) is the raid-side twin of log_dungeons - when off, entering
-- a raid or a world-boss zone no longer auto-starts /combatlog, so a player who
-- only wants their Mythic+ and 5-man runs logged can stop hand-disabling the
-- addon before every raid night. Both gates now run through one classifier in
-- ZoneMonitor: IsInInstance() decides indoor content ("raid" / "party"), and
-- outdoor world bosses and raid-event subzones (which report instanceType
-- "none") are matched by name against DefaultZones.OUTDOOR_RAID_ZONES. Content
-- the addon cannot positively identify is never gated. Two behavior changes
-- ride along: the gate now runs BEFORE the already-logging claim, so a session
-- carried in from other content (silent mode never auto-stops) is stopped on
-- entering blocked content instead of quietly logging through it - only a
-- session ALC itself started, never a manual /combatlog; and removing a zone
-- from the Monitored Zones list now records it as false rather than deleting
-- the key, so Z.start()'s defaults seeding stops resurrecting hand-removed
-- zones on the next login (the long-standing "the raid zones keep coming back"
-- report). "Restore Default Zones" on the zones page clears those tombstones.
-- 0.67.2 (opt-out for peer Character Advancement inspects): a new
-- cao_inspect_enabled toggle (Settings panel + /alc cao on|off, default ON)
-- stops the inspect rotation from calling C_CharacterAdvancement.InspectUnit on
-- other players. Relief valve for the class of client-side breakage where a game
-- patch retires a Character Advancement entry id that characters' stored builds
-- still reference: the client resolves every entry of an inspected build against
-- its local table, throws "CharacterAdvancementBuildEntry::UpdatePointers: entry
-- <id> not found" and can go down with it. That happens inside the client's own
-- inspect-response handler, before any addon code runs, so the pcall around the
-- request cannot catch it and there is nothing addon-side to guard - not asking
-- is the only lever. Turning it off costs peers' talents / hero build in reports;
-- gear, mystic enchants, pets and telemetry are unaffected, and the logger's own
-- build capture is untouched (your own build is already resolved client-side, so
-- it carries no added risk). When off, tryFinalize no longer waits on
-- INSPECT_CHARACTER_ADVANCEMENT_RESULT (it would never fire) and the missing-CAO
-- partial-retry is suppressed, so the rotation keeps its normal cadence instead
-- of eating the 3s have-talent-but-not-CA cutoff on every peer. No schema change
-- (SCHEMA_VERSION stays 7): peer CI simply omits the specialization fields it
-- cannot read.
-- 0.67.2 also fixes ALCSync channel placement. WotLK has no MoveChannelUp/Down
-- (Cataclysm API, nil here), so the old pushChannelDown() was always a silent
-- no-op and a slow login could leave ALCSync as channel 1 - stealing /1 and
-- topping the Channels list. The one rule the client follows is that a joining
-- channel takes the LOWEST FREE slot, so placement is purely a question of join
-- timing: VersionCheck now waits for the channel list to go quiet (5s, 45s cap)
-- instead of using a fixed delay, and repairs a bad slot by leaving, parking a
-- throwaway ALCPad channel in the hole it just freed, re-joining (which now
-- lands past the last channel) and dropping the pad - capped at 2 attempts and
-- skipped with no headroom for the pad. Also resolves the channel index fresh
-- at send time: a stale cached index could post the ALCver handshake into
-- whatever public channel had taken that slot.
-- 0.67.1 (keystone START record actually reaches the log): KeystoneScan
-- queued the "start" record on the relay's NORMAL ring while only "complete"
-- took the priority lane. SnapshotPipeline calls relay.clearRing() on every
-- PLAYER_REGEN_DISABLED, and a run's first pull always lands before the first
-- organic failed cast, so the start record was wiped every single time -
-- server-side telemetry across all reports that carried KS chunks found 100%
-- complete records and zero starts. Both lifecycle records now ride the
-- priority lane, which is deliberately preserved across pull-start ring
-- clears. No schema change (KS_SCHEMA_VERSION stays 1); the start record's
-- fields were always populated, they just never arrived. This matters because
-- the two records are lost to DIFFERENT failures - complete to a disconnect
-- or hearth at key-end, start to the ring clear - so a run now has to lose
-- both to end up with no keystone record at all.
-- 0.66.0 (durable Mythic+ run records): KeystoneScan now writes a full
-- per-run record into a new SavedVariablesPerCharacter store
-- (ALC_KeystoneRuns) for EVERY party member running the addon, not just the
-- logger: roster (name/realm/guid/class/race/level for all five, stamped at
-- key start), dungeon/level/affixes/timer budget, per-member death counts
-- (CLEU UNIT_DIED), outcome (timed/depleted/abandoned) and final
-- time/progress. Records open on MYTHIC_PLUS_STARTED (a crash mid-run still
-- leaves the attempt on disk), survive disconnects (PLAYER_ENTERING_WORLD
-- polls the live keystone state and re-attaches or adopts the run), and close
-- on MYTHIC_PLUS_COMPLETE. The Ascension Logs Uploader reads the
-- SavedVariables file from disk and posts new records to the site; dedup is
-- server-side. FIFO cap of KS_RUNS_CAP records; the open run is never
-- evicted. Roster members also carry an embedded compact CI (gear, mystic
-- enchants, CAO build): own from LocalScan.buildLocalCI, peers from the
-- inspect cache as InspectLoop's rotation lands them (first copy wins;
-- resume/close passes fill stragglers). Additionally harvests the client's
-- OWN best-run history (FrameXML C_Keystones / ReadCustomWTF("Keystones"):
-- per-dungeon + per-affix-set bests for every character on the install,
-- with date/time/overtime/level/affixes/class-tagged roster) into
-- ALC_KeystoneRuns.bests - retroactive history predating the addon. No
-- transport/codec changes; the KS relay chunk family is untouched and CI
-- SCHEMA_VERSION stays 7.
-- 0.65.1 (dungeon boss registry sync): BossRegistry now carries the full
-- 5-man dungeon rosters (all wings, rares included) instead of the partial
-- dev-fixture lists. Matters for chain-pulls: the per-pull CI republish rides
-- PLAYER_REGEN_DISABLED, so a boss engaged without dropping combat (trash
-- pulled straight into the boss) only gets a mid-combat CI republish via the
-- BossRegistry name match. Unregistered bosses (e.g. Herod) produced no CI
-- inside their encounter window, and the backend's instance-difficulty
-- fallback then had nothing to read - mythic dungeon kills landed as
-- 'normal'. Data-only change; no transport/schema impact.
-- 0.64.0 (Season 10 classless realms - Dawnrise + Darkmoon): adds two new
-- detected server profiles, "dawnrise" (Freepick) and "darkmoon" (Wildcard),
-- for the classless Season 10 realms. They run the SAME Ascension launcher
-- client as Bronzebeard, so they share Ascension's ENTIRE capture path (CAO /
-- MysticEnchant / transmog / Mythic+ / hero builds) - they are separate
-- profiles ONLY so the snapshot's `server` tag tenant-routes them to their own
-- backend, exactly the Triumvirate-vs-Epoch pattern on the Ascension side.
-- Positive Ascension-only capture gates now check Core.Profile.isAscensionFamily()
-- (ascension OR dawnrise OR darkmoon); the negative `not isEpochFamily()` gates
-- already covered them. Two small classless-only CI emits ride the local CI,
-- gated on C_Player:IsHero() so non-Hero (Bronzebeard/CoA/Epoch/Trium) snapshots
-- stay clean of vestigial fields:
--   * ci.primary_stat = { id, token } from C_PrimaryStat:GetActivePrimaryStat()
--     (Enum.PrimaryStat 1..5 = Str/Agi/Int/Spirit/Stam) - the Hero-forced
--     melee/ranged/caster axis.
--   * ci.game_mode    = { wildcard=<bool>, draft=<bool> } from
--     C_GameMode:IsGameModeActive(Enum.GameMode.WildCard/Draft).
-- These are additive fields; SCHEMA_VERSION bumps 5 -> 6 so the server demuxer
-- can key on the new field set. NOTE: a schema bump forces a one-time
-- inspect-cache repopulate on first 0.64.0 boot for EVERY tenant (via
-- InspectCache.rehydrate's schema guard, same as the 0.2.5 / 0.30.4 bumps) -
-- harmless, repopulates within the first cold inspect cycle. No transport/codec
-- changes; the F-frame wire format is unchanged. Inert for existing tenants:
-- their detected profile and every capture branch outcome are unchanged, and
-- the two new fields never appear on their (non-Hero) CIs.
-- 0.63.3 (guardian scan state is per-fight): the server recycles despawned
-- summons' GUIDs, so a guardian GUID resolved to one owner early in a session
-- can belong to a DIFFERENT owner's summon on a later boss. GuardianTracker's
-- session-lifetime resolved cache kept vouching for the stale owner and never
-- emitted a correcting pair - the server then applied the stale pair
-- report-wide by exact GUID, silently crediting later bosses' guardians to
-- the wrong player (a support who swapped off after one fight kept "earning"
-- Spirit of Life damage on every later boss from other supports' recycled
-- spirits). seenGuids is now wiped on PLAYER_REGEN_ENABLED so every fight
-- re-resolves each guardian from scratch and re-publishes its pair - giving
-- the server per-encounter pairs it can use to scope ownership when a GUID's
-- owner changes mid-report (server-side scoping ships separately). Details
-- clears its whole pet cache per segment for the same reason. No
-- transport/codec changes; PP wire format unchanged.
-- 0.63.2 (guardian owner-scan retry): GuardianTracker no longer gives up on a
-- guardian GUID after one failed tooltip scan. The first CLEU row a proc
-- guardian logs is typically its spawn instant, when a tooltip render by GUID
-- can miss (object not yet queryable, or out of render range) - and the
-- scan-once guard then poisoned that GUID for the whole session, so a
-- fight-long guardian (e.g. a Shieldmaiden shielding the raid for minutes)
-- never got an owner pair and its output landed on an orphan creature row
-- server-side. Failed scans now retry on later rows from the same GUID with
-- exponential backoff (2s doubling to a 30s cap, 12 attempts max); a success
-- is still final and resolved GUIDs are never re-rendered. No transport/codec
-- changes; PP wire format unchanged.
-- 0.62.1 (Triumvirate instance auto-logging): adds the full TBC + WotLK
-- instance set to DefaultZones so auto-/combatlog fires in Triumvirate raids
-- and dungeons (Karazhan, The Obsidian Sanctum, Ulduar, ICC, the WotLK/TBC
-- 5-mans, etc.). Names are the verbatim stock 3.3.5a Map.dbc MapName strings
-- (= what GetInstanceInfo() returns), extracted from the Triumvirate client -
-- NOT the backend roster strings, which carry "The"-prefix/wing-split drift.
-- Includes the stock-name variants for a few vanilla 5-mans (Deadmines,
-- Stormwind Stockade, Blackrock Spire). Purely additive to the shared zone
-- list; inert for Ascension/Epoch (their clients don't return these names).
-- 0.62.0 (Triumvirate server support): adds a third detected server profile,
-- "triumvirate" (stock WotLK 3.3.5a private server, realm "Triumvirate"). It is
-- an Epoch-family client - same standard talent-group (dual-spec) reader, and
-- none of Ascension's CAO / MysticEnchant / transmog / Mythic+ API surface - so
-- every capture-side branch now gates on Core.Profile.isEpochFamily() (Epoch OR
-- Triumvirate) instead of a bare == "epoch". The ONLY divergence from Epoch is
-- the `server` tag the snapshot stamps ("triumvirate"), for backend tenant
-- routing. Inert for Ascension and Epoch users: their detected profile and
-- every branch outcome are unchanged. No SCHEMA_VERSION bump - the Triumvirate
-- CI reuses Epoch's existing talent_groups shape (schema 5). Realm string
-- confirmed 2026-06-15 via clean in-game probe.
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
C.VERSION = "0.70.4"
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
-- Bumped to 6 in 0.64.0: local CI gained classless-only fields primary_stat
-- ({id,token} from C_PrimaryStat:GetActivePrimaryStat) and game_mode
-- ({wildcard,draft} from C_GameMode:IsGameModeActive), emitted only for
-- Hero-class characters on the Dawnrise/Darkmoon realms. Forces the same
-- one-time inspect-cache repopulate via the rehydrate schema guard.
-- Bumped to 7 in 0.65.0: INSPECT CIs gained primary_stat for Hero peers (it
-- reached local CIs in 0.64.0 / schema 6). The bump is deliberate rather than
-- cosmetic - InspectCache is persisted and schema-guarded, so without it every
-- already-cached peer would keep serving a CI with no primary_stat until the
-- normal re-inspect cadence caught up. Bumping wipes the cache and re-inspects
-- fresh, which is the point of the release.
C.SCHEMA_VERSION = 7

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

-- 0.66.0: durable per-run keystone records (ALC_KeystoneRuns
-- SavedVariablesPerCharacter). Written by KeystoneScan for EVERY party member
-- running the addon (not logger-gated); the Ascension Logs Uploader reads the
-- SavedVariables file from disk and posts new records to the site. Append-only
-- with a FIFO cap; the currently-open run is never evicted; dedup is
-- server-side.
-- 0.67.0: run records gain boss_kills = { {at_ms, name, enc_done?}, ... } -
-- one entry per BossRegistry-matched UNIT_DIED while the run is open, i.e.
-- which bosses died and when. Additive field, schema 1 -> 2; older records
-- simply lack it.
C.KS_RUNS_SCHEMA = 2
C.KS_RUNS_CAP    = 200

-- Manastorm (MS) family: CoA-only scaling scenario. One "level_cleared" record
-- per MANASTORM_LEVEL_COMPLETED (arg1 = level number). Body shape:
--   { schema_version=1, addon_version, stream="manastorm", event_type="level_cleared",
--     session_id, event_id, captured_at, captured_by_guid, server,
--     manastorm={ level, level_live, manastorm_id, manastorm_type, max_completed,
--                 boss_name, boss_encounter_id, success=true } }
-- Format: [[ALC_MS_v1_<sessionId>_<eventId>_<seq>/<total>]]<b64>
-- CoA-only: C_Manastorm is absent on Bronzebeard/Epoch, so the module no-ops there.
-- The level-clear fires mid-run (player still inside), so an organic failed cast
-- carries the priority chunk almost immediately; MS_KEEPALIVE_S covers the brief
-- between-levels lull. Local experiment as of 0.61.0: not yet consumed server-side.
C.MS_SENTINEL_PREFIX  = "[[ALC_MS_v1_"
C.MS_SCHEMA_VERSION   = 1
C.MS_KEEPALIVE_S      = 30    -- relay stays active this long after a level clear

-- Inspect timings
C.INSPECT_MIN_INTERVAL_S = 1.0  -- empirically validated 2026-04-25 on Bronzebeard via /alcprobe throttle-blast 1.0: 24/24 fires got replies, 0% server-throttled. 25-man cold cycle: 48s → 24s. Legacy fallback when ALC.Profile is unset.

-- Per-server inspect throttle. Resolved by ALC.Core.Profile.inspectIntervalSeconds()
-- after Profile.detect() runs in Init.lua boot. Validated 2026-04-28 on Epoch
-- (Kezan) via /epochprobe throttle-blast: 24/24 replies at 0.30s close-range,
-- so 0.5s leaves comfortable margin and roughly halves cold-cycle time vs
-- Ascension's 1.0s floor.
C.INSPECT_MIN_INTERVAL_S_BY_PROFILE = {
    -- Frostmourne: MEASURED 2026-08-23 over three live inspects -
    -- INSPECT_READY at a steady 169-180ms, but the talent payload lands at a
    -- VARIABLE 489-989ms, and gear at INSPECT_READY was seen empty (0/19) on
    -- one of the three despite 16-17/19 on the others. The loop is
    -- event-driven (INSPECT_TALENT_READY), so this floor only paces how often
    -- a new inspect may START; 0.5s sits comfortably under the observed
    -- completion time. Same value as the rest of the Epoch family.
    frostmourne = 0.5,
    ascension   = 1.0,
    -- Dawnrise/Darkmoon are the same Ascension client; inherit the validated
    -- 1.0s Ascension inspect floor.
    dawnrise    = 1.0,
    darkmoon    = 1.0,
    epoch       = 0.5,
    -- Triumvirate inherits Epoch's 0.5s floor: same 3.3.5 engine family, and
    -- Epoch (also a private 3.3.5 server) replied 24/24 at 0.30s, so 0.5s
    -- carries comfortable margin. NOT yet throttle-blast-validated on
    -- Triumvirate specifically; drop to 1.0 (the legacy floor) if launch logs
    -- show server-throttled inspect misses.
    triumvirate = 0.5,
}
C.INSPECT_TIMEOUT_S      = 5.0
-- How often tick() may re-walk the group to recover slots whose UnitGUID() was
-- nil at the last rebuild (see InspectLoop.rebuildUnitIndex). Only runs while
-- some slot is still unresolved, so the steady-state cost on a fully-resolved
-- group is zero. 5s trades a little latency for ~25 UnitGUID calls.
C.INSPECT_ROSTER_REFRESH_S = 5.0
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

    -- Tier 3: added 0.67.1 for the ON-DEMAND drain prompt (UI/KeystoneDrain).
    -- "Must have a %s equipped." is what `/cast Fishing` throws with no pole,
    -- and that is the one failure a player can produce deliberately, instantly,
    -- repeatably, with no target and no class dependency. Without this entry
    -- the cast fails and CLEU fires but the engine's own string rides arg 12,
    -- so the chunk is silently lost - the whole mechanism looks broken because
    -- of one missing table row. Measured 2026-08-09: 0 of 13 fishing failures
    -- carried a chunk before adding it, 7 of 7 after.
    "SPELL_FAILED_EQUIPPED_ITEM_CLASS",

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
    log_dungeons = true,          -- when off, auto-/combatlog skips 5-man dungeons (instanceType=="party")
    log_raids    = true,          -- 0.68.0: when off, auto-/combatlog skips raids (instanceType=="raid") AND outdoor world-boss / raid-event zones (DefaultZones.OUTDOOR_RAID_ZONES). Both gates also stop a carried-in ALC-started session on entry, so silent mode can't log through blocked content.
    pet_tracking_enabled = true,  -- 0.42.0: PP chunk emission for {owner, pet} GUID pairs from controlled-pet unit slots
    telemetry_enabled    = true,  -- 0.42.1 local experiment: TS chunk emission for periodic encounter telemetry (positions, vitals, hostile NPC ledger). Not yet consumed server-side.
    keystone_enabled     = true,  -- 0.51.x local experiment: KS chunk emission for Mythic+ keystone start/complete lifecycle events (Ascension only; no-op on Epoch). Not yet consumed server-side.
    keystone_keepalive   = true,  -- 0.51.x: on key complete, keep the relay active for KS_KEEPALIVE_S out of combat so an organic failed cast flushes the priority outcome chunk. Set false to drain only while in combat.
    keystone_toast       = true,  -- 0.51.x: show an on-screen toast when the key-outcome chunk is confirmed landed in the combat log.
    manastorm_enabled    = true,  -- 0.61.0 local experiment: MS chunk emission, one level_cleared record per MANASTORM_LEVEL_COMPLETED (CoA only; no-op where C_Manastorm absent). Not yet consumed server-side.
    manastorm_keepalive  = true,  -- 0.61.0: keep the relay active for MS_KEEPALIVE_S after a level clear so an organic failed cast flushes the priority chunk through the between-levels lull.
    manastorm_toast      = true,  -- 0.61.0: show an on-screen toast when a level-cleared chunk is confirmed landed in the combat log.
    cao_inspect_enabled  = true,  -- 0.67.2: request other players' Character Advancement build during inspect (Ascension family only; no-op where C_CharacterAdvancement is absent). Turn OFF as a relief valve when a client patch retires entry ids that stored builds still reference - the client throws "CharacterAdvancementBuildEntry::UpdatePointers: entry <id> not found" while parsing the inspect response and can crash. Cost of OFF: peers' talents / hero build are missing from reports until it is turned back on.
    -- 0.53.0 (NEW-ONLY, local/dev): CI/PP/TS ride [[ALC_F_v1_c2_...]] dict-deflated
    -- frames exclusively; there is no per-family legacy emit path anymore. This
    -- defaults ON and there is no /alc toggle. Editing this in SavedVariables to
    -- anything other than "c2" disables the ONLY emit path for CI/PP/TS (KS is
    -- unaffected - separate priority lane), so the pipelines will warn loudly and
    -- drop. The deprecated ci_codec / ci_transport_c1 gates were removed with the
    -- legacy CI base64 path they fed.
    frame_codec          = "c2",
}
