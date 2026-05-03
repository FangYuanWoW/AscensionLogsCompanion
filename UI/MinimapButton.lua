-- UI/MinimapButton.lua
-- Minimap button via LibDBIcon-1.0. The button name LibDBIcon10_AscensionLogsCompanion
-- is recognized by ElvUI / TukUI / Bartender minimap-button grabbers (whitelist
-- prefix "LibDBIcon"), so users running those UIs don't end up with our icon
-- piled into the inside-minimap stack that obscures the map face.

local ALC = _G.ALC
local M = {}
ALC.UI.MinimapButton = M

local LDB_NAME = "AscensionLogsCompanion"

-- LibDBIcon expects { hide = bool, minimapPos = number }. Older builds wrote
-- { hidden = bool, angle = number }; rewrite in place on first load so users
-- keep their saved position and visibility preference across the upgrade.
local function migrateConfig()
    _G.ALC_Config = _G.ALC_Config or {}
    local mb = ALC_Config.minimap_button
    if type(mb) ~= "table" then
        ALC_Config.minimap_button = { hide = false, minimapPos = 200 }
        return ALC_Config.minimap_button
    end
    if mb.hidden ~= nil and mb.hide == nil then
        mb.hide = mb.hidden
        mb.hidden = nil
    end
    if mb.angle ~= nil and mb.minimapPos == nil then
        mb.minimapPos = mb.angle
        mb.angle = nil
    end
    if mb.hide == nil then mb.hide = false end
    if mb.minimapPos == nil then mb.minimapPos = 200 end
    return mb
end

local function buildTooltip(tt)
    local metrics = ALC.Core.Metrics and ALC.Core.Metrics.counters or {}
    local cache = _G.ALC_InspectCache or {}
    local nCache = 0
    for _ in pairs(cache) do nCache = nCache + 1 end
    tt:AddLine("|cff00ff00Ascension Logs Companion|r")
    tt:AddLine("v" .. ALC.Core.Constants.VERSION, 0.7, 0.7, 0.7)
    tt:AddLine(" ")
    tt:AddDoubleLine("Players inspected", tostring(metrics.inspect_success or 0), 1, 1, 1, 0.4, 1, 0.4)
    tt:AddDoubleLine("Players cached",    tostring(nCache),                       1, 1, 1, 1, 1, 1)
    tt:AddDoubleLine("Combatant info delivered", tostring(metrics.chunks_flushed or 0), 1, 1, 1, 0.4, 1, 0.4)
    if (metrics.chunks_queued or 0) > 0 then
        tt:AddDoubleLine("Pending delivery", tostring(metrics.chunks_queued or 0), 1, 1, 1, 1, 1, 0.4)
    end
    tt:AddLine(" ")
    tt:AddLine("|cffaaaaaaClick:|r open settings")
    tt:AddLine("|cffaaaaaaDrag:|r reposition")
end

function M.start()
    local LibStub = _G.LibStub
    if not LibStub then
        ALC.Core.Logger.error("MinimapButton: LibStub missing - icon disabled")
        return
    end
    local LDB  = LibStub("LibDataBroker-1.1", true)
    local Icon = LibStub("LibDBIcon-1.0", true)
    if not LDB or not Icon then
        ALC.Core.Logger.error("MinimapButton: LibDataBroker/LibDBIcon missing - icon disabled")
        return
    end

    local db = migrateConfig()

    -- :NewDataObject errors if the same name registers twice (e.g. /reload
    -- after a hotfix patches this file). Reuse the existing object in that
    -- case so /reload doesn't break the minimap icon.
    local launcher = LDB:GetDataObjectByName(LDB_NAME)
                  or LDB:NewDataObject(LDB_NAME, {
        type = "launcher",
        text = "Ascension Logs",
        icon = "Interface\\AddOns\\AscensionLogsCompanion\\Media\\flame-32.tga",
        OnClick = function(_, button)
            if ALC.UI.SettingsFrame then ALC.UI.SettingsFrame.toggle() end
        end,
        OnTooltipShow = buildTooltip,
    })

    if not Icon:IsRegistered(LDB_NAME) then
        Icon:Register(LDB_NAME, launcher, db)
    else
        Icon:Refresh(LDB_NAME, db)
    end

    -- pfQuest-wotlk's player-arrow detection in compat/client.lua falls back
    -- to ({ Minimap:GetChildren() })[9] when it can't find an unnamed Model
    -- child whose model path matches "interface\minimap\minimaparrow". On
    -- 3.3.5 the engine renders the arrow internally, so the loop fails and
    -- the [9] fallback is taken. Adding any extra child to Minimap shifts
    -- that index, pfQuest then SetFrameLevel(8)'s the wrong Blizzard frame,
    -- and on the pfQuest-epoch + ElvUI stack the minimap face goes black.
    -- Reparent the button to UIParent so it isn't enumerated. The position
    -- anchor still targets Minimap, so it continues to track the map.
    local btn = _G["LibDBIcon10_" .. LDB_NAME]
    if btn and btn:GetParent() == Minimap then
        btn:SetParent(UIParent)
        btn:SetFrameStrata("MEDIUM")
        btn:SetFrameLevel(8)
    end
end

function M.hide()
    _G.ALC_Config = _G.ALC_Config or {}
    ALC_Config.minimap_button = ALC_Config.minimap_button or {}
    ALC_Config.minimap_button.hide = true
    local Icon = _G.LibStub and LibStub("LibDBIcon-1.0", true)
    if Icon then Icon:Hide(LDB_NAME) end
    ALC.Core.Logger.info("Minimap button hidden. Toggle from /alc settings.")
end

function M.show()
    _G.ALC_Config = _G.ALC_Config or {}
    ALC_Config.minimap_button = ALC_Config.minimap_button or {}
    ALC_Config.minimap_button.hide = false
    local Icon = _G.LibStub and LibStub("LibDBIcon-1.0", true)
    if Icon then Icon:Show(LDB_NAME) end
    -- LibDBIcon defers creation when hide=true at register time; the button
    -- only exists after :Show. Reparent again here to cover that path. See
    -- M.start() for the pfQuest-wotlk index-shift rationale.
    local btn = _G["LibDBIcon10_" .. LDB_NAME]
    if btn and btn:GetParent() == Minimap then
        btn:SetParent(UIParent)
        btn:SetFrameStrata("MEDIUM")
        btn:SetFrameLevel(8)
    end
end
