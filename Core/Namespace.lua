-- Core/Namespace.lua
-- Creates the root addon namespace and submodule tables. Loaded first.

_G.ALC = _G.ALC or {}
local ALC = _G.ALC

ALC.Core      = ALC.Core      or {}
ALC.Capture   = ALC.Capture   or {}
ALC.Transport = ALC.Transport or {}
ALC.Zone      = ALC.Zone      or {}
ALC.Parser    = ALC.Parser    or {}
ALC.UI        = ALC.UI        or {}

-- Event dispatcher frame. Every module subscribes via ALC.RegisterEvent.
ALC.frame = ALC.frame or CreateFrame("Frame", "ALC_EventFrame", UIParent)
ALC.handlers = ALC.handlers or {}

function ALC.RegisterEvent(event, fn)
    ALC.handlers[event] = ALC.handlers[event] or {}
    table.insert(ALC.handlers[event], fn)
    ALC.frame:RegisterEvent(event)
end

ALC.frame:SetScript("OnEvent", function(self, event, ...)
    local list = ALC.handlers[event]
    if not list then return end
    for i = 1, #list do
        local ok, err = pcall(list[i], event, ...)
        if not ok and ALC.Core.Logger then
            ALC.Core.Logger.error("Handler for " .. event .. " errored: " .. tostring(err))
        end
    end
end)
