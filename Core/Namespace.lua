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

-- Like RegisterEvent but tolerant of events the running client doesn't know.
-- frame:RegisterEvent throws "Unknown event" for unrecognized names, so
-- registering an Ascension-only CharacterAdvancement event on Epoch (or vice
-- versa) would error out of the caller. We pcall the registration and only
-- wire the handler when the client accepts the event. Returns true if it
-- registered. Used to subscribe the per-flavor spec/build-change events as a
-- single union without a profile branch at every call site.
function ALC.TryRegisterEvent(event, fn)
    local ok = pcall(ALC.frame.RegisterEvent, ALC.frame, event)
    if not ok then return false end
    ALC.handlers[event] = ALC.handlers[event] or {}
    table.insert(ALC.handlers[event], fn)
    return true
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
