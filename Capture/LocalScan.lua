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

function L.buildLocalCI(sessionId)
    local CAO = ALC.Capture.CAOScan
    local Myst = ALC.Capture.MysticEnchantScan
    local Gear = ALC.Capture.GearScan
    local C = ALC.Core.Constants

    local specInfo = CAO.readActiveSpecInfo() or {}
    -- Use the unified canonical reader so own-player CI carries the same
    -- field shape as inspect-side CIs (active_spec_idx, ca_known,
    -- ca_talent_ranks, etc.). The Phase 0 readKnown/readTalentRanks paths
    -- returned partial data on Bronzebeard; readCAOForUnit("player") is the
    -- 3-arg-signature version that actually works.
    local cao = CAO.readCAOForUnit("player") or {}
    local ci = {
        schema_version = C.SCHEMA_VERSION,
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
            investment = CAO.readInvestment(),
        },
        gear = Gear.readGear("player"),
        mystic_enchants = {
            -- Same { applied, per_slot } shape as inspect CIs. Preset-level
            -- metadata (active_preset, preset_capacity, tab_unlocked) only
            -- exists for own-player and is supplementary.
            applied = Myst.readInspectedEnchants("player"),
            per_slot = Myst.readInspectedEnchantsPerSlot("player"),
            active_preset = Myst.readActivePreset(),
            preset_capacity = Myst.readPresetCapacity(),
            tab_unlocked = Myst.hasUnlockedTab(),
        },
        arena_teams = arenaTeams(),
        pet = petInfo(),
    }

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
        session_id = sessionId,
        captured_at = time() * 1000,
        source = "inspect",
        is_logger = false,
        captured_by_guid = UnitGUID("player"),
        player = {
            guid = UnitGUID(unit),
            name = UnitName(unit),
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
    }
end
