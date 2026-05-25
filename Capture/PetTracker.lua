-- Capture/PetTracker.lua
-- Event-driven observer of {owner, pet} GUID pairs. Hands net-new pairs to
-- PetPipeline for relay-shaped emission via the SPELL_FAILED_* CLEU
-- transport. No OnUpdate ticker; the tracker sleeps until UNIT_PET fires
-- (any unit's pet changes), a roster update settles, or combat starts.
--
-- Two dedup layers mirror SnapshotPipeline's CI flow:
--   * observedPets    - process-lifetime set, prevents re-emit of the same
--                       {owner, pet} pair across repeated UNIT_PET fires for
--                       an already-known pair (revive-with-same-GUID, etc.)
--   * emittedThisPull - per-pull set, cleared on PLAYER_REGEN_DISABLED so
--                       each pull's combat-log window receives the full
--                       observed pet map at t=0. Matches SnapshotPipeline's
--                       lastPeerEnqueued reset pattern.
--
-- Scope:
--   * Controlled-pet slots only (warlock demons, hunter pets, mage water
--     elemental, DK permanent ghoul). Totems / mirror images / shadowfiends /
--     druid treants are NOT in the pet unit slot and remain the server-side
--     SPELL_SUMMON inference's responsibility.
--   * Out-of-range raiders return nil from UnitGUID("raidNpet"). UNIT_PET
--     fires when visibility catches up; the PLAYER_REGEN_DISABLED full
--     sweep at pull-start (when everyone is bunched) is the primary
--     coverage window.

local ALC = _G.ALC
local T = {}
ALC.Capture.PetTracker = T

local C = ALC.Core.Constants

T.observedPets = {}     -- ["ownerGuid:petGuid"] = true; process-lifetime
T.emittedThisPull = {}  -- ["ownerGuid:petGuid"] = true; reset on PLAYER_REGEN_DISABLED

local function pairKey(ownerGuid, petGuid)
    return ownerGuid .. ":" .. petGuid
end

local function shouldTrack()
    if not _G.ALC_Config then return false end
    return ALC_Config.pet_tracking_enabled ~= false
end

-- Resolve a (owner, pet) token pair to GUIDs and detect "new for this pull".
-- Always updates observedPets so session-lifetime visibility is tracked even
-- on repeat observations. Returns the pair table when it has not yet been
-- emitted in the current pull (and marks it emitted); nil otherwise.
local function detectNew(ownerTok, petTok)
    local ownerGuid = UnitGUID(ownerTok)
    local petGuid = UnitGUID(petTok)
    if not ownerGuid or not petGuid then return nil end
    local key = pairKey(ownerGuid, petGuid)
    T.observedPets[key] = true
    if T.emittedThisPull[key] then return nil end
    T.emittedThisPull[key] = true
    return { owner = ownerGuid, pet = petGuid }
end

-- Full roster sweep. Returns list of pairs that are new for this pull.
local function sweepAndCollect()
    local newPairs = {}
    local function tryAdd(ownerTok, petTok)
        local pair = detectNew(ownerTok, petTok)
        if pair then newPairs[#newPairs + 1] = pair end
    end

    tryAdd("player", "pet")

    local nRaid = (GetNumRaidMembers and GetNumRaidMembers()) or 0
    if nRaid > 0 then
        for i = 1, nRaid do tryAdd("raid" .. i, "raid" .. i .. "pet") end
    else
        local nParty = (GetNumPartyMembers and GetNumPartyMembers()) or 0
        for i = 1, nParty do tryAdd("party" .. i, "party" .. i .. "pet") end
    end

    return newPairs
end

local function publish(newPairs)
    if not newPairs or #newPairs == 0 then return end
    local pipeline = ALC.Capture.PetPipeline
    if pipeline and pipeline.publishPairs then
        pipeline.publishPairs(newPairs)
    end
end

-- UNIT_PET handler. arg1 is the OWNER's unit token: "player", "raid5",
-- "party2", or junk we don't track ("target", "mouseover", "focus", etc.).
function T.onUnitPet(event, unitTok)
    if not shouldTrack() then return end
    if not unitTok then return end
    if unitTok ~= "player"
       and not string.match(unitTok, "^raid%d+$")
       and not string.match(unitTok, "^party%d+$") then return end
    local petTok = (unitTok == "player") and "pet" or (unitTok .. "pet")
    local pair = detectNew(unitTok, petTok)
    if not pair then return end
    publish({ pair })
end

-- Roster changes: members joined/left. Sweep the full roster to pick up
-- pets that were previously out-of-range and just resolved, plus anyone
-- new in the group whose pets we hadn't seen yet.
function T.onRosterChange()
    if not shouldTrack() then return end
    publish(sweepAndCollect())
end

-- Pull start: clear per-pull dedup so the new combat-log window receives
-- the full observed pet map at t=0, then sweep. Registered AFTER
-- SnapshotPipeline.start() in Init.lua so SnapshotPipeline's
-- PLAYER_REGEN_DISABLED handler (which calls clearQueue()) runs first;
-- our handler then enqueues the pet-pair chunk against an already-cleared
-- relay queue.
function T.onCombatStart()
    if not shouldTrack() then return end
    T.emittedThisPull = {}
    publish(sweepAndCollect())
end

function T.start()
    ALC.RegisterEvent("UNIT_PET", T.onUnitPet)
    ALC.RegisterEvent("RAID_ROSTER_UPDATE", T.onRosterChange)
    ALC.RegisterEvent("PARTY_MEMBERS_CHANGED", T.onRosterChange)
    ALC.RegisterEvent("PLAYER_REGEN_DISABLED", T.onCombatStart)
    ALC.Core.Logger.debug("PetTracker.start() registered events")
end
