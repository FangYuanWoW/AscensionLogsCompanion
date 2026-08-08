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
        guild = (GetGuildInfo("player")),  -- guild name on the player blob (full {name,rank} stays at ci.guild)
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

-- Reads the logger's "show transmog on inspected players" client setting.
-- Captured on the local CI so the backend can correlate logger preferences
-- with capture quality. Validated 2026-04-29 via Bowlie inspect: when the
-- logger has transmog viewing ON, GetInventoryItemLink for inspected peers
-- can return the visual overlay item ID instead of the underlying real
-- item (specifically for Ascension's q=6 ilvl=1 mythic-tier appearances).
-- Reports flagged with transmog_viewing=true should be considered to have
-- potentially poisoned gear data on slots where peers have such appearances.
-- Returns nil on Epoch (no C_Appearance) and on clients lacking the API.
local function transmogViewing()
    if type(_G.C_Appearance) ~= "table"
       or type(C_Appearance.CanSeeAppearances) ~= "function" then
        return nil
    end
    local ok, val = pcall(C_Appearance.CanSeeAppearances)
    if not ok then return nil end
    return val and true or false
end

-- ── Classless (Season 10) identity signals ──────────────────────────────────
-- These APIs live on the shared Ascension superset client but only carry
-- meaning for Hero-class characters on the classless realms (Dawnrise /
-- Darkmoon). Emitting is gated on isHeroCharacter() in buildLocalCI so a
-- non-Hero snapshot (Bronzebeard 9-class, CoA, Epoch, Triumvirate) stays free
-- of vestigial fields. API shapes verified against the live Ascension client
-- addon source (Ascension_BuildCreator / FrameXML): C_Player:IsHero(),
-- C_PrimaryStat:GetActivePrimaryStat() -> Enum.PrimaryStat int, and
-- C_GameMode:IsGameModeActive(Enum.GameMode.WildCard) (colon method, variadic).

-- True when the local player is the classless Hero class. Prefers the
-- first-party C_Player:IsHero(); falls back to the always-present class token
-- (UnitClass -> "HERO") if that API is missing on some client build.
local function isHeroCharacter()
    if type(_G.C_Player) == "table" and type(C_Player.IsHero) == "function" then
        local ok, res = pcall(C_Player.IsHero, C_Player)
        if ok then return res and true or false end
    end
    local _, classToken = UnitClass("player")
    return classToken == "HERO"
end
L.isHeroCharacter = isHeroCharacter

-- Enum.PrimaryStat int -> stable token (see PRIMARY_STAT_STRING in the client's
-- Ascension_BuildCreator/BuildEditor/EditableBuildView.lua).
local PRIMARY_STAT_TOKENS = {
    [1] = "strength",
    [2] = "agility",
    [3] = "intellect",
    [4] = "spirit",
    [5] = "stamina",
    -- Duality is 6, read off Enum.PrimaryStat in game on 2026-07-27 (it was
    -- missing here, so every Duality character emitted token=nil). It is the
    -- MOST common path on Darkmoon, so this was the single biggest gap in the
    -- map. Note the client shows players "Path of Intelligence" and "Path of
    -- Healing" for ids 3 and 4 while these internal tokens say intellect /
    -- spirit; the tokens stay internal and the server maps them to the
    -- player-facing names.
    [6] = "duality",
}

-- Hero-forced primary stat: the path a classless character locks in.
-- Returns { id = <1..6>, token = <string> }, or nil when the API is absent or
-- no stat is set (non-Hero characters return nil here too).
--
-- id 5 (stamina) is in Enum.PrimaryStat but is NOT a selectable path -
-- GetPrimaryStatInfo(5) returns nothing in game - so it should never be seen.
-- It stays mapped so a surprise value still resolves to a token.
local function primaryStat()
    if type(_G.C_PrimaryStat) ~= "table"
       or type(C_PrimaryStat.GetActivePrimaryStat) ~= "function" then
        return nil
    end
    local ok, stat = pcall(C_PrimaryStat.GetActivePrimaryStat, C_PrimaryStat)
    if not ok or not stat then return nil end
    return { id = stat, token = PRIMARY_STAT_TOKENS[stat] }
end

-- Active game-mode flags. WildCard = Darkmoon's random-draft ruleset; Freepick
-- (Dawnrise) is the ABSENCE of a restricted mode, so we capture the WildCard
-- (and Draft) booleans explicitly and let realm identity carry Freepick.
-- Returns { wildcard=<bool>, draft=<bool> } (only the keys that resolved), or
-- nil where C_GameMode / Enum.GameMode is absent.
local function gameMode()
    if type(_G.C_GameMode) ~= "table"
       or type(C_GameMode.IsGameModeActive) ~= "function"
       or type(_G.Enum) ~= "table"
       or type(Enum.GameMode) ~= "table" then
        return nil
    end
    local out = nil
    local probes = { wildcard = Enum.GameMode.WildCard, draft = Enum.GameMode.Draft }
    for key, mask in pairs(probes) do
        if mask ~= nil then
            local ok, active = pcall(C_GameMode.IsGameModeActive, C_GameMode, mask)
            if ok then
                out = out or {}
                out[key] = active and true or false
            end
        end
    end
    return out
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
    local out = {
        name              = name,
        instance_type     = instType,
        difficulty_index  = diffIdx,
        difficulty_name   = diffName,
        max_players       = maxPlayers,
        player_difficulty = playerDiff,
        is_dynamic        = isDynamic and true or false,
        map_id            = mapId,
    }
    -- Mythic+ keystone marker so any CI snapshot taken mid-run is
    -- self-describing (a +N key is otherwise indistinguishable from a plain
    -- Mythic 5-man: both report difficulty_index=3, difficulty_name=""). The
    -- authoritative lifecycle + timed/depleted signal rides the separate KS
    -- chunk family (Capture/KeystoneScan.lua); this is just current state.
    -- 0.66.1: the FULL readActiveKeystone shape rides the marker (was a thin
    -- {level, dungeon_id} triple). The backend synthesizes keystone rows
    -- from these markers when no KS chunk lands, and the thin shape left
    -- those rows without affixes or timer budget - the run record and the
    -- site's affix tooltips need them. A handful of numeric fields per CI
    -- on the compressed transport: negligible cost.
    -- Ascension-only: KeystoneScan.readActiveKeystone() returns nil when
    -- C_MythicPlus is absent (Epoch) or no key is active.
    local KS = ALC.Capture.KeystoneScan
    if KS and KS.readActiveKeystone then
        local ks = KS.readActiveKeystone()
        if ks then
            out.keystone = ks
        end
    end

    -- Thin Manastorm marker (CoA only): lets the backend tell a report IS a
    -- Manastorm run, and know the current level, even if every MS chunk is lost.
    -- The authoritative per-level success rides the separate MS chunk family
    -- (Capture/ManastormScan.lua); this is just current state. Returns nil when
    -- C_Manastorm is absent (Bronzebeard/Epoch) or not inside a run.
    local MS = ALC.Capture.ManastormScan
    if MS and MS.readActiveManastorm then
        local ms = MS.readActiveManastorm()
        if ms then
            out.manastorm = {
                is_active    = true,
                level        = ms.level,
                manastorm_id = ms.manastorm_id,
                type         = ms.manastorm_type,
            }
        end
    end
    return out
end

-- Exposed so the broadcast pipeline can re-stamp a peer's instance from the
-- logger's LIVE reading at emit time. Instance is a "where is the logger now"
-- property shared by the whole raid, not a per-peer fact frozen at inspect-build
-- time. Re-broadcasts (publishPeerInspects / drainDeferQueue) otherwise carry the
-- instance the logger was in when the peer was last inspected, so a raid that
-- changes zones keeps emitting the old zone/difficulty until each peer happens to
-- be re-inspected (see report 10627 / encounter 340057: 20 of 22 CIs stamped
-- "Molten Core / Ascended" into a Snowgrave / Heroic pull, which sank difficulty
-- detection to 'normal').
L.instanceInfo = instanceInfo

function L.buildLocalCI(sessionId)
    local CAO = ALC.Capture.CAOScan
    local Myst = ALC.Capture.MysticEnchantScan
    local Gear = ALC.Capture.GearScan
    local C = ALC.Core.Constants

    local profile = ALC.Profile or "ascension"
    -- Epoch-family (Epoch + Triumvirate) shares the vanilla dual-spec talent
    -- path and lacks the Ascension CAO/mystic API surface; everything else
    -- (including "unknown") takes the Ascension enrichment branch as before.
    local isAscension = not ALC.Core.Profile.isEpochFamily()

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
        transmog_viewing = transmogViewing(),  -- v0.2.5: logger's "show transmog" setting; gates capture quality interpretation on the backend
    }

    -- Classless (Season 10) identity signals - schema 6. Only stamped for
    -- Hero-class characters (the Dawnrise/Darkmoon realms); nil/absent on every
    -- other tenant so their CI shape is unchanged. Backend ignores unknown
    -- fields, so this is safe even if an older demuxer sees them.
    if isHeroCharacter() then
        ci.primary_stat = primaryStat()
        ci.game_mode    = gameMode()
    end

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
    elseif ALC.Core.Profile.isEpochFamily() and ALC.Capture.EpochTalentScan then
        -- Epoch-family enrichment (Epoch + Triumvirate): rich dual-spec talent
        -- shape mirroring the inspect-side payload. Backend dispatches by
        -- ci.server.
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

    -- Classless (Season 10) peer path - schema 6. Unlike the logger's own
    -- primary_stat (a direct GetActivePrimaryStat call), a peer's comes from
    -- PrimaryStatScan's per-pull roster sweep, because GetUnitPrimaryStat is a
    -- plain unit read and does not ride the inspect round-trip at all. It is
    -- therefore often already resolved BEFORE this inspect completes.
    --
    -- nil is a legitimate outcome (peer was out of range for the whole pull),
    -- and the field is simply omitted then - the backend still has its
    -- marker-aura inference as the fallback, so an absent value degrades to
    -- today's behaviour rather than regressing.
    local peerPrimaryStat = nil
    local PSS = ALC.Capture and ALC.Capture.PrimaryStatScan
    if PSS and classToken == "HERO" then
        local okPS, val = pcall(PSS.get, UnitGUID(unit))
        if okPS then peerPrimaryStat = val end
    end

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
            guild = (GetGuildInfo(unit)),  -- guild name on the player blob (full {name,rank} stays at ci.guild)
        },
        guild = guildInfo(unit),
        primary_stat = peerPrimaryStat,
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
