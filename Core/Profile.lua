-- Core/Profile.lua
-- Detects which 3.3.5 server family this client is connected to so the rest
-- of the addon can route per-server behavior at runtime. Sets ALC.Profile to
-- one of "ascension" | "epoch" | "triumvirate" | "unknown". Result is cached to
-- ALC_Config.server_profile so /reload doesn't re-probe.
--
-- Triumvirate is stock WotLK 3.3.5a (private server triumvirate-wow.com). It
-- shares Epoch's capture path entirely: standard talent-group (dual-spec)
-- reader, and none of Ascension's CAO / MysticEnchant / transmog / M+ API
-- surface. It is its own profile only so the backend can tenant-route by the
-- snapshot's `server` tag; behaviorally it is an Epoch-family client
-- (see P.isEpochFamily()).
--
-- Detection order:
--   1. ALC_Config.server_profile_override (manual escape hatch for forks /
--      rebrands where auto-detect is wrong).
--   2. Realm-name match via GetRealmName().
--   3. Global probe fallback (Ascension-only globals present?).
--   4. "unknown" (snapshot still ships, backend treats as bare-vanilla 3.3.5).

local ALC = _G.ALC
local P = {}
ALC.Core.Profile = P

P.ASCENSION   = "ascension"
P.EPOCH       = "epoch"
P.TRIUMVIRATE = "triumvirate"
P.UNKNOWN     = "unknown"

-- Exact-match realm names. The Bronzebeard realm reports as the combined
-- string "Bronzebeard - Warcraft Reborn" via GetRealmName() (verified
-- 2026-04-28 from a live Fangyuan CI dump in BRD). The bare names are
-- kept as belt-and-suspenders in case a fork or shard reports a shorter
-- string. Update when new shards launch.
local REALMS = {
    ["Bronzebeard - Warcraft Reborn"] = P.ASCENSION,
    ["Bronzebeard"]                   = P.ASCENSION,
    ["Warcraft Reborn"]               = P.ASCENSION,
    ["Kezan"]                         = P.EPOCH,
    ["Gurubashi"]                     = P.EPOCH,
    -- Triumvirate: stock WotLK 3.3.5a private server (triumvirate-wow.com).
    -- Realm string confirmed 2026-06-15 via clean probe (WTF account realm
    -- folder = "Triumvirate"; single word, no GetRealmName() sanitization).
    ["Triumvirate"]                   = P.TRIUMVIRATE,
}

-- Global probe: Ascension-only namespaces verified absent on Epoch via the
-- 2026-04-28 ALC_Epoch_Probe run (see addons/alc-multi-server-design.md
-- Phase 1 §A). Presence => Ascension; absence + unmatched realm => unknown.
local function probeAscensionGlobals()
    if type(_G.CAO_Known) == "table" then return true end
    if type(_G.AscensionUI) == "table"
       and type(_G.AscensionUI.MysticEnchant) == "table" then
        return true
    end
    if type(_G.C_CharacterAdvancement) == "table" then return true end
    if type(_G.C_MysticEnchant) == "table" then return true end
    return false
end

-- Public: run detection and stamp ALC.Profile. Idempotent.
function P.detect()
    _G.ALC_Config = _G.ALC_Config or {}

    -- 1. Manual override
    local override = ALC_Config.server_profile_override
    if override == P.ASCENSION or override == P.EPOCH
       or override == P.TRIUMVIRATE or override == P.UNKNOWN then
        ALC.Profile = override
        ALC_Config.server_profile = override
        return override
    end

    -- 2. Realm-name match
    local realm = (type(GetRealmName) == "function") and GetRealmName() or nil
    if type(realm) == "string" then
        local matched = REALMS[realm]
        if matched then
            ALC.Profile = matched
            ALC_Config.server_profile = matched
            return matched
        end
    end

    -- 3. Global probe
    if probeAscensionGlobals() then
        ALC.Profile = P.ASCENSION
        ALC_Config.server_profile = P.ASCENSION
        return P.ASCENSION
    end

    -- 4. Unknown
    ALC.Profile = P.UNKNOWN
    ALC_Config.server_profile = P.UNKNOWN
    return P.UNKNOWN
end

-- Convenience predicates so callers don't repeat the literal strings.
function P.isAscension()   return ALC.Profile == P.ASCENSION end
function P.isEpoch()       return ALC.Profile == P.EPOCH end
function P.isTriumvirate() return ALC.Profile == P.TRIUMVIRATE end

-- Epoch-family = servers that share Epoch's capture path: the standard
-- talent-group (dual-spec) reader, and NONE of Ascension's CAO / MysticEnchant
-- / transmog / Mythic+ API surface. Triumvirate (stock WotLK 3.3.5a) qualifies;
-- it differs from Epoch only in the `server` tag it stamps for backend tenant
-- routing. Capture-side branches should gate on this, not on isEpoch(), so a
-- new Epoch-family tenant routes correctly without touching every call site.
function P.isEpochFamily()
    return ALC.Profile == P.EPOCH or ALC.Profile == P.TRIUMVIRATE
end

-- Returns the per-server inspect throttle floor with a safe fallback.
function P.inspectIntervalSeconds()
    local C = ALC.Core.Constants
    local byProfile = C and C.INSPECT_MIN_INTERVAL_S_BY_PROFILE
    local val = byProfile and byProfile[ALC.Profile or P.ASCENSION]
    return val or (C and C.INSPECT_MIN_INTERVAL_S) or 1.0
end
