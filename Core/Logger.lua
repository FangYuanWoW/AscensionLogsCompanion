-- Core/Logger.lua
-- Minimal logging. All debug prints gated by ALC_Config.debug.
-- error() and warn() always print.

local ALC = _G.ALC
local L = {}
ALC.Core.Logger = L

local PREFIX = "|cff88ccff[ALC]|r "
local WARN   = "|cffffcc00[ALC]|r "
local ERR    = "|cffff4444[ALC]|r "

-- Rebuild the cosmetic chat tag from the active brand (e.g. [TLC] on
-- Triumvirate). Called from Init.boot() after Profile.detect(); log lines
-- emitted before that (early module load) fall back to [ALC]. This is display
-- only: the wire ADDON_PREFIX stays "ALC" (see Core/Constants). The locals are
-- shared upvalues, so reassigning them here updates debug/info/warn/error too.
function L.applyBrand()
    local b = ALC.Core.Branding
    local tag = (b and b.slash and string.upper(b.slash())) or "ALC"
    PREFIX = "|cff88ccff[" .. tag .. "]|r "
    WARN   = "|cffffcc00[" .. tag .. "]|r "
    ERR    = "|cffff4444[" .. tag .. "]|r "
end

local function cfg()
    return _G.ALC_Config or {}
end

function L.debug(msg)
    if cfg().debug then
        DEFAULT_CHAT_FRAME:AddMessage(PREFIX .. "[debug] " .. tostring(msg))
    end
end

function L.info(msg)
    DEFAULT_CHAT_FRAME:AddMessage(PREFIX .. tostring(msg))
end

function L.warn(msg)
    DEFAULT_CHAT_FRAME:AddMessage(WARN .. tostring(msg))
end

function L.error(msg)
    DEFAULT_CHAT_FRAME:AddMessage(ERR .. tostring(msg))
end
