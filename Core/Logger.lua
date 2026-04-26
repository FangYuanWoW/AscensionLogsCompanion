-- Core/Logger.lua
-- Minimal logging. All debug prints gated by ALC_Config.debug.
-- error() and warn() always print.

local ALC = _G.ALC
local L = {}
ALC.Core.Logger = L

local PREFIX = "|cff88ccff[ALC]|r "
local WARN   = "|cffffcc00[ALC]|r "
local ERR    = "|cffff4444[ALC]|r "

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
