-- Capture/Telemetry.lua
-- Low-frequency encounter telemetry: where players were, what they were
-- targeting, their vitals, and which hostile NPCs were active during logged
-- combat. Separate stream from CI (build/equipment) and PP (pet pairs).
--
-- Envelope: [[ALC_TS_v1_<sessionId>_<snapshotId>_<seq>/<total>]]<b64>
-- Transit:  SpellFailedRelay (matches the family prefix [[ALC_, no relay
--           changes needed; landed-evidence + UIErrorsFrame suppression
--           inherit for free).
--
-- Cost model: TELEMETRY_INTERVAL_S = 2.0 means roughly one snapshot every
-- ~120 frames at 60fps. Each snapshot is compressed + chunked through the
-- same relay queue as CI. A backlogged relay can't snowball into more chunks
-- because the cadence self-throttles (effectiveInterval stretches the
-- interval as the queue fills) rather than emitting faster than it drains;
-- it never stops, just slows under pressure and recovers as the queue drains.
--
-- Efficiency notes:
--   * npc_id parsed once per GUID, memoized on the monster entry itself
--   * roster static fields (name/class/level) cached and invalidated on
--     roster events, so we don't re-call UnitClass/UnitName/UnitLevel
--     per raid member per snapshot (those are stable until composition
--     changes); only the dynamic fields (health/power/position/target)
--     are read every snapshot
--   * collectMonsters builds a guid->visibleFields index ONCE per snapshot
--     instead of walking every candidate unit for every monster (O(M+N)
--     vs O(M*N))
--   * GetPlayerMapPosition's zone-set side effect is avoided when the
--     player's current map already reports a non-zero position; the
--     SetMapToCurrentZone dance only fires when needed
--   * WoW API names hoisted to locals in hot paths

local ALC = _G.ALC
local T = {}
ALC.Capture.Telemetry = T

local C = ALC.Core.Constants

-- Hot-path WoW API locals
local UnitExists      = UnitExists
local UnitGUID        = UnitGUID
local UnitName        = UnitName
local UnitClass       = UnitClass
local UnitLevel       = UnitLevel
local UnitHealth      = UnitHealth
local UnitHealthMax   = UnitHealthMax
local UnitPower       = UnitPower
local UnitPowerMax    = UnitPowerMax
local UnitPowerType   = UnitPowerType
local UnitIsDeadOrGhost = UnitIsDeadOrGhost
local UnitIsConnected = UnitIsConnected
local UnitAffectingCombat = UnitAffectingCombat
local UnitClassification = UnitClassification
local UnitCreatureType = UnitCreatureType
local GetNumRaidMembers = GetNumRaidMembers
local GetNumPartyMembers = GetNumPartyMembers
local GetRaidRosterInfo = GetRaidRosterInfo
local IsInInstance    = IsInInstance

T.started = false
T.snapshotCounter = 0
T.accum = 0
T.monsters = {}            -- guid -> { npc_id, name, flags, counters, ... }
T.rosterStatic = {}        -- unitToken -> { guid, name, class, level }
T.rosterDirty = true       -- force a static-cache rebuild on next snapshot
T.lastSnapshotAt = nil
T.lastSnapshotId = nil
T.lastSkipReason = "not_started"

------------------------------------------------------------------------------
-- Small helpers

local function nowMs()
    return time() * 1000
end

local DIGITS36 = "0123456789abcdefghijklmnopqrstuvwxyz"
local function toBase36(n)
    if n == 0 then return "0" end
    local out = ""
    local x = n
    while x > 0 do
        local r = x - math.floor(x / 36) * 36
        out = DIGITS36:sub(r + 1, r + 1) .. out
        x = math.floor(x / 36)
    end
    return out
end

local function round4(n)
    if type(n) ~= "number" then return nil end
    return math.floor(n * 10000 + 0.5) / 10000
end

------------------------------------------------------------------------------
-- Map / instance info. mapInfo() is the superset; we don't ship a separate
-- instanceInfo() block (the original draft had both, fully redundant).

local function mapInfo()
    local out = {
        zone_text    = (type(GetZoneText) == "function") and GetZoneText() or nil,
        subzone_text = (type(GetSubZoneText) == "function") and GetSubZoneText() or nil,
    }
    if type(_G.GetInstanceInfo) == "function" then
        local name, instType, diffIdx, diffName, maxPlayers,
              playerDiff, isDynamic, mapId = GetInstanceInfo()
        out.instance_name      = name
        out.instance_type      = instType
        out.difficulty_index   = diffIdx
        out.difficulty_name    = diffName
        out.max_players        = maxPlayers
        out.player_difficulty  = playerDiff
        out.is_dynamic         = isDynamic and true or false
        out.instance_map_id    = mapId
    end
    if type(GetCurrentMapAreaID) == "function" then
        out.world_map_area_id = GetCurrentMapAreaID()
    end
    if type(GetMapInfo) == "function" then
        out.map_file = GetMapInfo()
    end
    if type(GetCurrentMapDungeonLevel) == "function" then
        out.dungeon_level = GetCurrentMapDungeonLevel()
    end
    if type(GetCurrentMapContinent) == "function" then
        out.continent = GetCurrentMapContinent()
    end
    if type(GetCurrentMapZone) == "function" then
        out.zone_idx = GetCurrentMapZone()
    end
    return out
end

-- 3.3.5's GetPlayerMapPosition is gated on the world map being set to the
-- current zone. We only do the SetMapToCurrentZone dance if a probe call
-- returns 0,0, and we never touch map state while WorldMapFrame is open
-- (would yank the user's UI around).
local function withCurrentZoneMap(fn)
    local needAdjust = type(GetPlayerMapPosition) == "function"
    if needAdjust then
        local px, py = GetPlayerMapPosition("player")
        if px and py and (px ~= 0 or py ~= 0) then
            return fn()
        end
    end

    local canAdjust = needAdjust
        and type(SetMapToCurrentZone) == "function"
        and not (_G.WorldMapFrame and WorldMapFrame:IsShown())
    if not canAdjust then return fn() end

    local oldContinent = type(GetCurrentMapContinent) == "function"
                         and GetCurrentMapContinent() or nil
    local oldZone = type(GetCurrentMapZone) == "function"
                    and GetCurrentMapZone() or nil
    pcall(SetMapToCurrentZone)

    -- Forward an arbitrary number of return values from fn. fn() is called
    -- ONCE; results are captured into a table with explicit count so trailing
    -- nils survive unpack (Lua 5.1 has no table.pack).
    local function pack(...) return { n = select('#', ...), ... } end
    local results = pack(fn())

    if oldContinent and oldContinent > 0 and type(SetMapZoom) == "function" then
        pcall(SetMapZoom, oldContinent, oldZone or 0)
    end
    return unpack(results, 1, results.n)
end

local function readPosition(unit)
    if not UnitExists(unit) then return nil end
    local out

    if type(GetPlayerMapPosition) == "function" then
        local ok, x, y = pcall(GetPlayerMapPosition, unit)
        if ok and x and y and (x ~= 0 or y ~= 0) then
            out = {
                map_x = round4(x),
                map_y = round4(y),
                map_position_source = "GetPlayerMapPosition",
            }
        end
    end

    if type(UnitPosition) == "function" then
        local ok, y, x, z, instanceId = pcall(UnitPosition, unit)
        if ok and x and y and (x ~= 0 or y ~= 0) then
            out = out or {}
            out.world_x = round4(x)
            out.world_y = round4(y)
            out.world_z = round4(z)
            out.world_instance_id = instanceId
            out.world_position_source = "UnitPosition"
        end
    end

    return out
end

------------------------------------------------------------------------------
-- Roster static cache. (name, class, level) are stable between roster events,
-- so we cache them per unit token and only re-read dynamic fields every snap.

local function rebuildRosterStatic()
    local out = {}
    local function fill(unit)
        if not UnitExists(unit) then return end
        local _, classToken = UnitClass(unit)
        out[unit] = {
            guid  = UnitGUID(unit),
            name  = UnitName(unit),
            class = classToken,
            level = UnitLevel(unit),
        }
    end

    local raidN = (GetNumRaidMembers() or 0)
    if raidN > 0 then
        for i = 1, raidN do fill("raid" .. i) end
    else
        fill("player")
        for i = 1, (GetNumPartyMembers() or 0) do fill("party" .. i) end
    end

    T.rosterStatic = out
    T.rosterDirty = false
end

local function ensureRosterStatic()
    if T.rosterDirty then rebuildRosterStatic() end
end

local function onRosterChange()
    T.rosterDirty = true
end

------------------------------------------------------------------------------
-- Unit collection. The static cache eats the name/class/level cost; per-snap
-- we only pay for health/power/position/target/dead-state reads.

local function unitPower(unit)
    local powerType, powerToken = UnitPowerType(unit)
    return {
        type    = powerType,
        token   = powerToken,
        current = UnitPower(unit),
        max     = UnitPowerMax(unit),
    }
end

local function buildUnitEntry(unit, rosterRaidInfo)
    if not UnitExists(unit) then return nil end
    ensureRosterStatic()
    local static = T.rosterStatic[unit]
    -- Static cache miss can happen if the roster changed between events and
    -- our last rebuild. Fall back to a one-off read so the snapshot is still
    -- complete; the next event will mark dirty.
    if not static or static.guid ~= UnitGUID(unit) then
        local _, classToken = UnitClass(unit)
        static = {
            guid  = UnitGUID(unit),
            name  = UnitName(unit),
            class = classToken,
            level = UnitLevel(unit),
        }
        T.rosterStatic[unit] = static
    end

    local targetUnit = unit .. "target"
    local hasTarget  = UnitExists(targetUnit)
    local pos        = readPosition(unit)

    -- Payload trimmed in 0.51.0: name / level / zone / target_name and the
    -- world_x/y/z coordinate triplet (+ position-source strings) are dropped.
    -- The server resolves identity by guid (the characters table already
    -- carries name/level from the CI/inspect path), and the replay viewer is
    -- 2D so only the map_x/map_y pair is consumed. `class` stays: the
    -- demuxer's targeter-anchor monster positioning keys on it (isMeleeUnit).
    local out = {
        unit       = unit,
        guid       = static.guid,
        class      = static.class,
        subgroup   = rosterRaidInfo and rosterRaidInfo.subgroup or nil,
        online     = rosterRaidInfo and rosterRaidInfo.online,
        dead       = UnitIsDeadOrGhost(unit) and true or false,
        connected  = UnitIsConnected(unit) and true or false,
        health     = UnitHealth(unit),
        max_health = UnitHealthMax(unit),
        power      = unitPower(unit),
        target_guid = hasTarget and UnitGUID(targetUnit) or nil,
    }

    if pos then
        out.map_x = pos.map_x
        out.map_y = pos.map_y
    end
    return out
end

local function collectUnits()
    local units = {}
    local targetCounts = {}
    local positioned = 0

    local function emit(unit, rosterRaidInfo)
        local info = buildUnitEntry(unit, rosterRaidInfo)
        if not info then return end
        units[#units + 1] = info
        if info.map_x and info.map_y then positioned = positioned + 1 end
        if info.target_guid then
            targetCounts[info.target_guid] = (targetCounts[info.target_guid] or 0) + 1
        end
    end

    local raidN = (GetNumRaidMembers() or 0)
    if raidN > 0 then
        for i = 1, raidN do
            local rosterRaidInfo
            local name, _rank, subgroup, level, _className, classFile, zone, online, isDead =
                GetRaidRosterInfo(i)
            rosterRaidInfo = {
                name     = name,
                subgroup = subgroup,
                level    = level,
                class    = classFile,
                zone     = zone,
                online   = online and true or false,
                dead     = isDead and true or false,
            }
            emit("raid" .. i, rosterRaidInfo)
        end
    else
        emit("player", { subgroup = 1, online = true })
        for i = 1, (GetNumPartyMembers() or 0) do
            emit("party" .. i, { subgroup = 1, online = true })
        end
    end

    return units, targetCounts, positioned
end

------------------------------------------------------------------------------
-- Hostile NPC ledger. Built incrementally from COMBAT_LOG_EVENT_UNFILTERED;
-- snapshot reads from it. npc_id is parsed once per GUID and cached on the
-- entry itself (no separate cache map).

local function band(v, mask)
    if not v or not mask then return 0 end
    if _G.bit and bit.band then return bit.band(v, mask) end
    if _G.bit32 and bit32.band then return bit32.band(v, mask) end
    return 0
end

local function isHostileNpc(flags)
    if not flags then return false end
    local hostile = _G.COMBATLOG_OBJECT_REACTION_HOSTILE
    if not hostile or band(flags, hostile) == 0 then return false end
    local npcControl = _G.COMBATLOG_OBJECT_CONTROL_NPC
    if npcControl and band(flags, npcControl) ~= 0 then return true end
    local npcType = _G.COMBATLOG_OBJECT_TYPE_NPC
    if npcType and band(flags, npcType) ~= 0 then return true end
    return false
end

local function extractNpcId(guid)
    if type(guid) ~= "string" then return nil end
    -- Modern (retail-style) GUID: Creature-0-server-instance-zone-NPCID-spawn
    local retail = guid:match("^Creature%-%d+%-%d+%-%d+%-%d+%-(%d+)%-")
    if retail then return tonumber(retail) end
    -- 3.3.5 hex GUID: 0xF130<6 hex NPC id><...>
    local hex = guid:match("^0xF130(%x%x%x%x%x%x)")
    if hex then return tonumber(hex, 16) end
    return nil
end

local function touchMonster(guid, name, flags, role, subEvent)
    if not guid then return nil end
    local m = T.monsters[guid]
    local now = nowMs()
    if not m then
        m = {
            guid           = guid,
            npc_id         = extractNpcId(guid),
            name           = name,
            flags          = flags,
            first_seen_at  = now,
            last_seen_at   = now,
            source_events  = 0,
            dest_events    = 0,
            casts          = 0,
            damage_done    = 0,
            damage_taken   = 0,
            healing_done   = 0,
        }
        T.monsters[guid] = m
        if ALC.Core.Metrics then ALC.Core.Metrics.inc("telemetry_monsters_seen") end
    end

    if name  then m.name  = name  end
    if flags then m.flags = flags end
    m.last_seen_at = now
    m.last_event   = subEvent
    if role == "source" then
        m.source_events = m.source_events + 1
    elseif role == "dest" then
        m.dest_events = m.dest_events + 1
    end
    return m
end

local function eventAmount(subEvent, ...)
    if subEvent == "SWING_DAMAGE" then
        return select(9, ...)
    elseif subEvent == "RANGE_DAMAGE"
        or subEvent == "SPELL_DAMAGE"
        or subEvent == "SPELL_PERIODIC_DAMAGE"
        or subEvent == "SPELL_BUILDING_DAMAGE" then
        return select(12, ...)
    elseif subEvent == "ENVIRONMENTAL_DAMAGE" then
        return select(10, ...)
    elseif subEvent == "SPELL_HEAL" or subEvent == "SPELL_PERIODIC_HEAL" then
        return select(12, ...)
    end
    return nil
end

local function spellInfoFromEvent(subEvent, ...)
    if subEvent:sub(1, 5) == "SWING" or subEvent:sub(1, 13) == "ENVIRONMENTAL" then
        return nil, nil
    end
    return select(9, ...), select(10, ...)
end

local function onCombatLog(_event, ...)
    if not (_G.ALC_Config and ALC_Config.telemetry_enabled) then return end
    local _ts, subEvent, sourceGUID, sourceName, sourceFlags,
          destGUID, destName, destFlags = ...

    if subEvent == "UNIT_DIED" then
        if isHostileNpc(destFlags) then
            local m = touchMonster(destGUID, destName, destFlags, "dest", subEvent)
            if m then m.death_at = nowMs() end
        end
        return
    end

    local sourceMonster = isHostileNpc(sourceFlags)
    local destMonster   = isHostileNpc(destFlags)
    if not sourceMonster and not destMonster then return end

    local spellId, spellName = spellInfoFromEvent(subEvent, ...)
    local amount = eventAmount(subEvent, ...)

    if sourceMonster then
        local m = touchMonster(sourceGUID, sourceName, sourceFlags, "source", subEvent)
        if m then
            if subEvent:find("_CAST_", 1, true) then
                m.casts = m.casts + 1
            end
            if spellId then
                m.last_spell_id   = spellId
                m.last_spell_name = spellName
            end
            if subEvent:find("_DAMAGE", 1, true) and type(amount) == "number" then
                m.damage_done = m.damage_done + amount
            elseif subEvent:find("_HEAL", 1, true) and type(amount) == "number" then
                m.healing_done = m.healing_done + amount
            end
        end
    end

    if destMonster then
        local m = touchMonster(destGUID, destName, destFlags, "dest", subEvent)
        if m and subEvent:find("_DAMAGE", 1, true) and type(amount) == "number" then
            m.damage_taken = m.damage_taken + amount
        end
    end
end

-- Build a guid -> {unit, health, max_health, level, classification,
-- creature_type, map_x, map_y, world_x, world_y, world_z} map ONCE per
-- snapshot by walking the candidate target slots. This replaces the
-- O(M*N) per-monster walk in the original draft.
--
-- Monster positions only land for *targeted* hostiles (any unit selected
-- by anyone in the raid). Untargeted nuisance mobs stay positionless, but
-- they're also healthless / unrenderable for replay, so the gap is
-- inherent rather than fixable.
local function buildVisibleMonsterIndex()
    local out = {}
    local function probe(unit)
        if not UnitExists(unit) then return end
        local g = UnitGUID(unit)
        if not g or out[g] then return end
        local entry = {
            unit           = unit,
            health         = UnitHealth(unit),
            max_health     = UnitHealthMax(unit),
            level          = UnitLevel(unit),
            classification = UnitClassification and UnitClassification(unit) or nil,
            creature_type  = UnitCreatureType and UnitCreatureType(unit) or nil,
        }
        local pos = readPosition(unit)
        if pos then
            -- 2D replay only; world_x/y/z + position-source strings trimmed in 0.51.0.
            entry.map_x = pos.map_x
            entry.map_y = pos.map_y
        end
        out[g] = entry
    end

    probe("target"); probe("focus"); probe("mouseover"); probe("pettarget")
    local raidN = (GetNumRaidMembers() or 0)
    if raidN > 0 then
        for i = 1, raidN do probe("raid" .. i .. "target") end
    else
        for i = 1, (GetNumPartyMembers() or 0) do probe("party" .. i .. "target") end
    end
    return out
end

local function collectMonsters(targetCounts)
    local now = nowMs()
    local activeWindow = (C.TELEMETRY_MONSTER_ACTIVE_WINDOW_S or 12) * 1000
    local pruneAfter   = (C.TELEMETRY_MONSTER_PRUNE_AFTER_S or 60) * 1000
    local visibleByGuid = buildVisibleMonsterIndex()

    local out = {}
    for guid, m in pairs(T.monsters) do
        local age = now - (m.last_seen_at or now)
        if age > pruneAfter then
            T.monsters[guid] = nil
        elseif age <= activeWindow or (m.death_at and now - m.death_at <= activeWindow) then
            -- Payload trimmed in 0.51.0: the combat ledger (name, flags,
            -- *_seen_at, source/dest_events, casts, damage_*, healing_done,
            -- last_event, last_spell_*, targeted_by_count) is dropped - none
            -- of it survives to encounter_actor_samples server-side. Only
            -- guid, npc_id, death_at and the visible{} block are kept. The
            -- ledger is still accumulated in T.monsters because last_seen_at
            -- / death_at drive the active-window filter above; it just isn't
            -- serialized into the snapshot anymore.
            local entry = {
                guid     = guid,
                npc_id   = m.npc_id,
                death_at = m.death_at,
            }
            local visible = visibleByGuid[guid]
            if visible then entry.visible = visible end
            out[#out + 1] = entry
        end
    end
    return out
end

------------------------------------------------------------------------------
-- Snapshot envelope + transit

local function relayQueueSize()
    local relay = ALC.Transport and ALC.Transport.SpellFailedRelay
    if not relay or not relay.queue then return 0 end
    return relay.queue.size or 0
end

-- Adaptive cadence (0.51.0). The relay only drains when the logging player
-- organically fails a cast (a few chunks/min), far slower than a fixed 2s
-- feed. A fixed interval just front-loads the shared queue - the 6-10%
-- front-loaded coverage seen on reports 9785/9794. Instead, stretch the
-- interval as the queue fills: base cadence while shallow, ramping linearly
-- toward TELEMETRY_MAX_INTERVAL_S as the queue approaches the ring cap.
--
-- This is a self-throttle, NOT a stop: it always returns a finite interval,
-- so generation stays continuous for the whole encounter. There is no
-- queue-depth skip anymore (see shouldSnapshot); the cadence simply goes
-- coarser under pressure and back to 2s as the queue drains.
local function effectiveInterval()
    local base = C.TELEMETRY_INTERVAL_S or 2.0
    local soft = C.TELEMETRY_BACKOFF_START_CHUNKS or 80
    local q = relayQueueSize()
    if q <= soft then return base end
    local maxInterval = C.TELEMETRY_MAX_INTERVAL_S or 20.0
    local hard = C.RELAY_QUEUE_MAX_CHUNKS or 400
    local span = hard - soft
    if span < 1 then span = 1 end
    local frac = (q - soft) / span
    if frac > 1 then frac = 1 end
    return base + (maxInterval - base) * frac
end

local function shouldSnapshot()
    if not _G.ALC_Config then T.lastSkipReason = "no_config"; return false end
    if not ALC_Config.telemetry_enabled then T.lastSkipReason = "disabled"; return false end
    if not ALC_Config.is_logger then T.lastSkipReason = "not_logger"; return false end
    if not ALC_Config.hijack_enabled then T.lastSkipReason = "relay_disabled"; return false end
    if not LoggingCombat or not LoggingCombat() then T.lastSkipReason = "combatlog_off"; return false end
    if not UnitAffectingCombat("player") then T.lastSkipReason = "not_in_combat"; return false end
    local _, instType = IsInInstance()
    if instType ~= "raid" and instType ~= "party" then
        T.lastSkipReason = "not_instance"; return false
    end
    -- No queue-pressure stop (0.51.0): telemetry NEVER gates itself off on
    -- queue depth. A logger that is actively capturing should stay continuous
    -- for the whole encounter; effectiveInterval() handles relay backpressure
    -- by stretching the cadence (self-throttle), never by going silent. The
    -- only stops are the intentional scope gates checked above (logger /
    -- combatlog / combat / instance). The ring's own overflow eviction bounds
    -- memory; coarser cadence under load keeps that churn low.
    T.lastSkipReason = nil
    return true
end

local function buildChunkEnvelope(sessionId, snapshotId, seq, total, b64)
    return string.format("[[ALC_TS_v1_%s_%s_%d/%d]]%s",
        sessionId, snapshotId, seq, total, b64)
end

local function enqueuePayload(payload, sessionId, snapshotId)
    -- Phase 4 frame gate: bundle this telemetry snapshot into an [[ALC_F_...]] frame.
    if ALC.Capture.FrameBuilder and ALC.Capture.FrameBuilder.enabled() then
        return ALC.Capture.FrameBuilder.add(ALC.Capture.FrameBuilder.TYPE.TS, payload)
    end
    -- serializeCI is the generic Ace+Deflate serializer (same path PetPipeline
    -- reuses). Despite the name, it takes any table.
    local compressed = ALC.Core.Serialize.serializeCI(payload)
    if not compressed then return false end
    local b64 = ALC.Core.Base64.encode(compressed)
    if not b64 then return false end

    local maxBody = C.CHUNK_PAYLOAD_MAX_BYTES
    local total = math.ceil(#b64 / maxBody)
    if total < 1 then total = 1 end
    for seq = 1, total do
        local startIdx = (seq - 1) * maxBody + 1
        local endIdx = math.min(startIdx + maxBody - 1, #b64)
        ALC.Transport.SpellFailedRelay.enqueue(
            buildChunkEnvelope(sessionId, snapshotId, seq, total, b64:sub(startIdx, endIdx))
        )
    end
    return true
end

function T.snapshot(reason)
    if not shouldSnapshot() then return false end
    local sessionId = _G.ALC_LocalState and ALC_LocalState.session_id
    if not sessionId then return false end

    T.snapshotCounter = T.snapshotCounter + 1
    local snapshotId = toBase36(T.snapshotCounter)

    -- Both collectUnits and collectMonsters call readPosition, which depends
    -- on the world-map state being set to the current zone (3.3.5 quirk).
    -- Wrap both in the same withCurrentZoneMap call so the map-state dance
    -- happens at most once per snapshot.
    local units, targetCounts, positioned, monsters = withCurrentZoneMap(function()
        local u, tc, p = collectUnits()
        local m = collectMonsters(tc)
        return u, tc, p, m
    end)

    local tracker = ALC.Capture.EncounterTracker
    local payload = {
        schema_version    = C.TELEMETRY_SCHEMA_VERSION,
        addon_version     = C.VERSION,
        stream            = "telemetry",
        event_type        = "encounter_snapshot",
        session_id        = sessionId,
        snapshot_id       = snapshotId,
        captured_at       = nowMs(),
        captured_by_guid  = UnitGUID("player"),
        server            = ALC.Profile or "unknown",
        reason            = reason or "interval",
        encounter = {
            in_combat = UnitAffectingCombat("player") and true or false,
            boss      = tracker and tracker.getCurrentBoss and tracker.getCurrentBoss() or nil,
            pull_id   = tracker and tracker.getCurrentPullId and tracker.getCurrentPullId() or nil,
        },
        map      = mapInfo(),
        units    = units,
        monsters = monsters,
    }

    if enqueuePayload(payload, sessionId, snapshotId) then
        T.lastSnapshotAt = time()
        T.lastSnapshotId = snapshotId
        if ALC.Core.Metrics then
            ALC.Core.Metrics.inc("telemetry_snapshots_queued")
            ALC.Core.Metrics.inc("telemetry_units_positioned", positioned or 0)
        end
        ALC.Core.Logger.debug("Telemetry enqueued: snapshot " .. snapshotId
            .. " units=" .. tostring(units and #units or 0)
            .. " monsters=" .. tostring(payload.monsters and #payload.monsters or 0))
        return true
    end
    return false
end

------------------------------------------------------------------------------
-- Lifecycle

local function onCombatStart()
    -- Clear the hostile-NPC ledger on pull-start so we don't carry yard-trash
    -- residue into a boss snapshot.
    T.monsters = {}
    T.accum    = 0
    T.snapshot("combat_start")
end

function T.start()
    if T.started then return end
    T.started = true

    ALC.RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED", onCombatLog)
    ALC.RegisterEvent("PLAYER_REGEN_DISABLED", onCombatStart)
    ALC.RegisterEvent("RAID_ROSTER_UPDATE", onRosterChange)
    ALC.RegisterEvent("PARTY_MEMBERS_CHANGED", onRosterChange)

    ALC.frame:HookScript("OnUpdate", function(_self, elapsed)
        if not UnitAffectingCombat("player") then
            T.accum = 0
            return
        end
        T.accum = T.accum + elapsed
        if T.accum >= effectiveInterval() then
            T.accum = 0
            T.snapshot("interval")
        end
    end)
end

function T.forceSnapshot()
    return T.snapshot("manual")
end

function T.probe(logger)
    local log = logger or ALC.Core.Logger.info
    local inInstance, instType = IsInInstance()
    log("Telemetry module: started=" .. tostring(T.started)
        .. " enabled=" .. tostring(_G.ALC_Config and ALC_Config.telemetry_enabled)
        .. " is_logger=" .. tostring(_G.ALC_Config and ALC_Config.is_logger))
    log("Scope: /combatlog=" .. tostring(LoggingCombat and LoggingCombat())
        .. " combat=" .. tostring(UnitAffectingCombat("player"))
        .. " instance=" .. tostring(inInstance) .. "/" .. tostring(instType)
        .. " queue=" .. tostring(relayQueueSize()))
    log("Last: snapshot=" .. tostring(T.lastSnapshotId or "(none)")
        .. " skip=" .. tostring(T.lastSkipReason or "(none)"))

    local pos = withCurrentZoneMap(function() return readPosition("player") end)
    if pos then
        log("Player pos: map=(" .. tostring(pos.map_x) .. "," .. tostring(pos.map_y)
            .. ") world=(" .. tostring(pos.world_x) .. "," .. tostring(pos.world_y)
            .. "," .. tostring(pos.world_z) .. ")")
    else
        log("Player pos: unavailable")
    end

    local nMobs = 0
    for _ in pairs(T.monsters) do nMobs = nMobs + 1 end
    log("Tracked hostile NPCs: " .. tostring(nMobs))

    -- One-shot dump of the instance/map block so the user can see what the
    -- difficulty/zone fields actually look like on this server (useful for
    -- the Ascension mythic-tier question).
    local m = mapInfo()
    log("Map: instance_name=" .. tostring(m.instance_name)
        .. " type=" .. tostring(m.instance_type)
        .. " diff=" .. tostring(m.difficulty_index) .. "/" .. tostring(m.difficulty_name)
        .. " max_players=" .. tostring(m.max_players)
        .. " mapid=" .. tostring(m.instance_map_id))
end
