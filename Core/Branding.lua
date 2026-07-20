-- Core/Branding.lua
-- Per-tenant user-visible identity (display name, accent color, releases URL).
-- The capture / transport logic is shared across every 3.3.5 tenant (see
-- Core/Profile.lua); ONLY the cosmetic brand differs, so it lives here keyed by
-- the detected ALC.Profile rather than being forked into a separate addon. A
-- per-tenant packaging step renames the folder + .toc for distribution; this
-- module handles everything the running client shows in-game.
--
-- Bronzebeard, Epoch, and CoA all ship under the "Ascension Logs" umbrella
-- brand, so only "ascension" and "triumvirate" have entries here; every other
-- profile (epoch, CoA-as-ascension, unknown) falls back to the ascension brand.
--
-- All lookups are LAZY (resolved at call time) because ALC.Profile is not set
-- until Profile.detect() runs inside Init.boot(). Every caller here fires after
-- boot (slash handler, minimap tooltip, settings-frame build, version nag, the
-- auto-/combatlog popups), so the active profile is always resolved by then.

local ALC = _G.ALC
local B = {}
ALC.Core.Branding = B

local BRANDS = {
    ascension = {
        short       = "Ascension Logs",
        full        = "Ascension Logs Companion",
        slash       = "alc",     -- the advertised slash command (without the leading /)
        accent      = "4ec3ff",  -- blue flame
        domain      = "ascensionlogs.gg",
        releasesUrl = "https://github.com/FangYuanWoW/AscensionLogsCompanion/releases",
    },
    triumvirate = {
        short       = "Triumvirate Logs",
        full        = "Triumvirate Logs Companion",
        slash       = "tlc",     -- /alc still works everywhere as a universal alias
        accent      = "4ec3ff",  -- shares the Ascension blue (owner keeps the blue brand color)
        domain      = "triumlogs.gg",
        releasesUrl = "https://github.com/FangYuanWoW/triumvirate-logs-companion/releases",
    },
}

-- Resolve the active brand. Epoch / CoA / unknown intentionally fall back to the
-- Ascension umbrella brand.
function B.current()
    return BRANDS[ALC.Profile] or BRANDS.ascension
end

-- Green status form, e.g. "|cff00ff00Ascension Logs Companion|r". Used in
-- chat/log lines (load message, /alc banner, minimap tooltip header).
function B.titleGreen()
    return "|cff00ff00" .. B.current().full .. "|r"
end

-- Two-tone accent form, e.g. "|cff4ec3ffAscension Logs|r |cffe8e8e8Companion|r".
-- Used in the settings header, the auto-/combatlog popups, and the new-version
-- nag.
function B.titleRich()
    local b = B.current()
    return "|cff" .. b.accent .. b.short .. "|r |cffe8e8e8Companion|r"
end

function B.short()       return B.current().short end
function B.full()        return B.current().full end
function B.slash()       return B.current().slash end
function B.domain()      return B.current().domain end
function B.releasesUrl() return B.current().releasesUrl end
