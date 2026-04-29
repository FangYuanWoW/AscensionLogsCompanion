-- Capture/LocalScan.lua
-- Top-level orchestrator. Builds the full CI struct for the local player.
-- Amortized across frames in production; this baseline version is a single
-- call. Call from out-of-combat triggers only.

local ALC = _G.ALC
local L = {}
ALC.Capture.LocalScan = L

local function playerGuid()
    return UnitGUID("player")
end

local function playerInfo()
    local name = UnitName("player")
    local _, classToken = UnitClass("player")
    local _, raceToken  = UnitRace("player")
    local gender = UnitSex("player")
    local level = UnitLevel("player")
    local realm = GetRealmName()
    return {
        guid = playerGuid(),
        name = name,
        realm = realm,
        race = raceToken,
        class = classToken,
        gender = gender,
        level = level,
    }
end

local function guildInfo(unit)
    unit = unit or "player"
    local name, rankName, rankIdx = GetGuildInfo(unit)
    if not name then return nil end
    return { name = name, rank_name = rankName, rank_index = rankIdx }
end

local function arenaTeams()
    local out = {}
    for _, teamSize in ipairs({ 2, 3, 5 }) do
        local teamName, teamSize2, teamRating, teamPlayed, teamWon, _, _, _, _, personalRating =
            GetInspectArenaTeamData and GetInspectArenaTeamData(teamSize) or nil
        if teamName then
            out["v" .. teamSize] = {
                name = teamName,
                rating = teamRating,
                played = teamPlayed,
                won = teamWon,
                personal_rating = personalRating,
            }
        end
    end
    return out
end

local function petInfo()
    if UnitExists("pet") then
        return {
            name = UnitName("pet"),
            guid = UnitGUID("pet"),
            family = UnitCreatureFamily("pet"),
        }
    end
    return nil
end

-- Wraps GetInstanceInfo() into a structured snapshot field so the backend
-- can dispatch by both difficulty integer and the friendly name.
--
-- 2026-04-28 Ascension probe (Ragefire Chasm, Bronzebeard) confirmed Ascension
-- extends vanilla 3.3.5's difficulty index past the standard 1-2 cap:
--   index 1 = Normal       difficulty_name = "" (blank)
--   index 2 = Heroic       difficulty_name = "5 Player (Heroic)"
--   index 3 = Mythic       difficulty_name = "" (blank)
-- player_difficulty mirrors the index with a 0-based offset (0/1/2). Because
-- difficulty_name is unreliable (blank for both Normal and Mythic), the
-- backend should key on (instance_type, difficulty_index) and look up the
-- friendly label in its own table. map_id is the stable instance identifier;
-- name can change on localized clients but map_id is constant.
--
-- Server-agnostic: GetInstanceInfo exists on both Ascension and Epoch (and
-- vanilla 1.12 content surfaces sane defaults too). Raid difficulty indices
-- and Mythic+ keystone fields haven't been probed yet; capture raw values
-- and let the backend interpret as those probes land.
local function instanceInfo()
    if type(_G.GetInstanceInfo) ~= "function" then return nil end
    local name, instType, diffIdx, diffName, maxPlayers,
          playerDiff, isDynamic, mapId = GetInstanceInfo()
    return {
        name              = name,
        instance_type     = instType,
        difficulty_index  = diffIdx,
        difficulty_name   = diffName,
        max_players       = maxPlayers,
        player_difficulty = playerDiff,
        is_dynamic        = isDynamic and true or false,
        map_id            = mapId,
    }
end

function L.buildLocalCI(sessionId)
    local CAO = ALC.Capture.CAOScan
    local Myst = ALC.Capture.MysticEnchantScan
    local Gear = ALC.Capture.GearScan
    local C = ALC.Core.Constants

    local profile = ALC.Profile or "ascension"
    local isAscension = (profile ~= "epoch")

    -- Ascension-only enrichment. On Epoch the underlying APIs are absent so
    -- these calls return nil/empty, but doing them explicitly conditional
    -- keeps the Epoch snapshot clean of vestigial Ascension fields.
    local specInfo = isAscension and (CAO.readActiveSpecInfo() or {}) or {}
    -- Use the unified canonical reader so own-player CI carries the same
    -- field shape as inspect-side CIs (active_spec_idx, ca_known,
    -- ca_talent_ranks, etc.). The Phase 0 readKnown/readTalentRanks paths
    -- returned partial data on Bronzebeard; readCAOForUnit("player") is the
    -- 3-arg-signature version that actually works.
    local cao = (isAscension and CAO.readCAOForUnit("player")) or {}
    local ci = {
        schema_version = C.SCHEMA_VERSION,
        addon_version  = C.VERSION,
        server = profile,                  -- v0.2.0 multi-server tag
        session_id = sessionId,
        captured_at = time() * 1000,
        source = "local",
        is_logger = (_G.ALC_Config and ALC_Config.is_logger) and true or false,
        captured_by_guid = playerGuid(),
        player = playerInfo(),
        guild  = guildInfo("player"),
        specialization = {
            active_spec_idx = cao.spec_idx,
            active_spec_slot = specInfo.slot_index,
            active_spec_name = specInfo.name,
            active_spec_role = specInfo.role,
            unlocked_specs = cao.unlocked_specs,
            vanilla_talents = CAO.readVanillaTalents(false),
            ca_known = cao.ca_known,
            ca_talent_ranks = cao.ca_talent_ranks,
            ca_talent_max_ranks = cao.ca_talent_max_ranks,
            hero_build = cao.hero_build,
            investment = isAscension and CAO.readInvestment() or nil,
        },
        gear = Gear.readGear("player"),
        arena_teams = arenaTeams(),
        pet = petInfo(),
        instance = instanceInfo(),
    }

    if isAscension then
        ci.mystic_enchants = {
            -- Same { applied, per_slot } shape as inspect CIs. Preset-level
            -- metadata (active_preset, preset_capacity, tab_unlocked) only
            -- exists for own-player and is supplementary.
            applied = Myst.readInspectedEnchants("player"),
            per_slot = Myst.readInspectedEnchantsPerSlot("player"),
            active_preset = Myst.readActivePreset(),
            preset_capacity = Myst.readPresetCapacity(),
            tab_unlocked = Myst.hasUnlockedTab(),
        }
    elseif profile == "epoch" and ALC.Capture.EpochTalentScan then
        -- Epoch enrichment: rich vanilla 3-tab talent shape mirroring the
        -- inspect-side payload. Backend dispatches by ci.server.
        ci.talents = ALC.Capture.EpochTalentScan.readInspectedTalents("player")
    end

    return ci
end

-- Build a degraded "inspect-only" CI for a unit we just inspected.
-- Ascension-specific fields set to nil so backend can flag limited data.
function L.buildInspectCI(unit, sessionId)
    local CAO = ALC.Capture.CAOScan
    local Gear = ALC.Capture.GearScan
    local C = ALC.Core.Constants

    local _, classToken = UnitClass(unit)
    local _, raceToken  = UnitRace(unit)
    return {
        schema_version = C.SCHEMA_VERSION,
        addon_version  = C.VERSION,
        server = ALC.Profile or "ascension",   -- v0.2.0 multi-server tag
        session_id = sessionId,
        captured_at = time() * 1000,
        source = "inspect",
        is_logger = false,
        captured_by_guid = UnitGUID("player"),
        player = {
            guid = UnitGUID(unit),
            name = UnitName(unit),
            -- Inspector and inspected peer are guaranteed same-realm by
            -- CanInspect's same-realm constraint, so the logger's
            -- GetRealmName() answers for the peer too. Saves us from
            -- needing a per-peer realm fetch (which doesn't exist as an
            -- inspect-time API anyway).
            realm = GetRealmName(),
            race = raceToken,
            class = classToken,
            gender = UnitSex(unit),
            level = UnitLevel(unit),
        },
        guild = guildInfo(unit),
        specialization = {
            active_spec_id = nil,
            ca_known = nil,
            ca_talent_ranks = nil,
            vanilla_talents = CAO.readVanillaTalents(true),
        },
        gear = Gear.readGear(unit),
        mystic_enchants = nil,  -- inspect cannot reach
        arena_teams = arenaTeams(),
        instance = instanceInfo(),  -- inspector and target share the same instance
    }
end
