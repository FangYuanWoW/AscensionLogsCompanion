-- Core/Profile.lua
-- Detects which 3.3.5 server family this client is connected to so the rest
-- of the addon can route per-server behavior at runtime. Sets ALC.Profile to
-- one of "ascension" | "dawnrise" | "darkmoon" | "epoch" | "triumvirate" |
-- "unknown". Result is cached to ALC_Config.server_profile so /reload doesn't
-- re-probe.
--
-- Dawnrise and Darkmoon are the Season 10 CLASSLESS realms (Freepick /
-- Wildcard). They run the SAME Ascension launcher client as Bronzebeard, so
-- they share Ascension's ENTIRE capture path (CAO / MysticEnchant / transmog /
-- Mythic+ / hero builds); the Ascension-globals probe below even resolves them.
-- They are separate profiles ONLY so the snapshot's `server` tag tenant-routes
-- them to their own backend (dawnrise.ascensionlogs.gg / darkmoon.ascensionlogs.gg),
-- exactly the way Triumvirate is its own tag while sharing Epoch's capture path.
-- Capture-side branches therefore gate on Core.Profile.isAscensionFamily()
-- (ascension OR dawnrise OR darkmoon), NOT on a bare == "ascension".
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
P.DAWNRISE    = "dawnrise"      -- Season 10 classless Freepick realm (Ascension-family capture)
P.DARKMOON    = "darkmoon"      -- Season 10 classless Wildcard realm (Ascension-family capture)
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
    -- Conquest of Azeroth (Ascension family; public launch 2026-07-03 with
    -- two realms). The exact GetRealmName() string is unverified on the live
    -- realms (the beta probe environment was Vol'jin), so both the bare and
    -- launcher-style suffixed forms are listed. Belt-and-suspenders only:
    -- the Ascension-globals probe below also resolves CoA clients.
    ["Vol'jin"]                       = P.ASCENSION,
    ["Rexxar"]                        = P.ASCENSION,
    ["Vol'jin - Conquest of Azeroth"] = P.ASCENSION,
    ["Rexxar - Conquest of Azeroth"]  = P.ASCENSION,
    -- Season 10 classless realms (launch 2026-07-24). Same Ascension launcher
    -- client as Bronzebeard, so the Ascension-globals probe below ALSO resolves
    -- them to a working capture path; these realm entries exist to stamp the
    -- correct tenant `server` tag (dawnrise/darkmoon) for backend routing. They
    -- MUST win over the probe, which is why realm-name match runs first (step 2
    -- vs step 3 in P.detect). VERIFIED in-game: the live Dawnrise realm string is
    -- "Dawnrise - Season 10 Freepick" (Darkmoon expected "... Wildcard"); the
    -- exact table below plus P.detect's ^Dawnrise/^Darkmoon prefix fallback both
    -- resolve it. If nothing matches, the probe safely falls back to "ascension"
    -- and the backend still tenant-routes by domain+realm.
    ["Dawnrise"]                          = P.DAWNRISE,
    ["Dawnrise - Season 10"]              = P.DAWNRISE,
    ["Dawnrise - Season 10 Freepick"]     = P.DAWNRISE,
    ["Dawnrise - Ascension"]              = P.DAWNRISE,
    ["Darkmoon"]                          = P.DARKMOON,
    ["Darkmoon - Season 10"]              = P.DARKMOON,
    ["Darkmoon - Season 10 Wildcard"]     = P.DARKMOON,
    ["Darkmoon - Ascension"]              = P.DARKMOON,
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

    -- 2. Realm-name match. Exact table first, then a prefix fallback: the live
    --    classless realm strings carry a suffix (verified in-game: Dawnrise =
    --    "Dawnrise - Season 10 Freepick", Darkmoon = "Darkmoon - Season 10
    --    Wildcard"), so an exact lookup alone would miss them and mis-tag the
    --    tenant as generic "ascension". Prefix-match keeps it robust to whatever
    --    suffix the realm list carries.
    local realm = (type(GetRealmName) == "function") and GetRealmName() or nil
    if type(realm) == "string" then
        local matched = REALMS[realm]
        if not matched then
            if realm:find("^Dawnrise") then matched = P.DAWNRISE
            elseif realm:find("^Darkmoon") then matched = P.DARKMOON end
        end
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

-- Ascension-family = servers that share Ascension's FULL capture path (CAO /
-- MysticEnchant / transmog / Mythic+ / hero builds): Bronzebeard, CoA
-- (detected as "ascension"), and the classless Season 10 realms Dawnrise /
-- Darkmoon. The only divergence for the classless realms is the `server` tag
-- they stamp for backend tenant routing. Positive Ascension-only capture gates
-- should check this, not a bare isAscension(), so classless clients keep the
-- full enrichment. (Note: the capture branches that gate the OTHER way -
-- `not isEpochFamily()` - already include dawnrise/darkmoon on the Ascension
-- side automatically; this predicate is for the few positive checks.)
function P.isAscensionFamily()
    return ALC.Profile == P.ASCENSION
        or ALC.Profile == P.DAWNRISE
        or ALC.Profile == P.DARKMOON
end

-- True on the two classless (Hero-class) Season 10 realms. Used to gate the
-- classless-only CI emits (primary stat, game mode) at the profile level as a
-- complement to the per-character C_Player:IsHero() check.
function P.isClassless()
    return ALC.Profile == P.DAWNRISE or ALC.Profile == P.DARKMOON
end

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
