-- UI/SlashCommand.lua
-- /alc handler.

local ALC = _G.ALC

SLASH_ALC1 = "/alc"
SLASH_ALC2 = "/ascensionlogs"

local function split(s)
    local out = {}
    for w in s:gmatch("%S+") do out[#out + 1] = w end
    return out
end

-- User-facing help. Power-user commands (inspect-now, publish-now, clear-cache,
-- zone add/remove/list, boss, metrics reset) stay functional but aren't
-- advertised - the settings panel covers everything most people need.
local function printHelp()
    local L = ALC.Core.Logger
    L.info("|cff00ff00Ascension Logs Companion|r")
    L.info("  |cffffd200/alc|r           open settings")
    L.info("  |cffffd200/alc status|r    show current state")
end

SlashCmdList["ALC"] = function(msg)
    msg = msg or ""
    local parts = split(msg:lower())
    local cmd = parts[1] or ""
    local L = ALC.Core.Logger

    if cmd == "" or cmd == "gui" then
        ALC.UI.SettingsFrame.toggle()

    elseif cmd == "status" then
        local cfg = _G.ALC_Config or {}
        local cache = _G.ALC_InspectCache or {}
        local nCache = 0
        for _ in pairs(cache) do nCache = nCache + 1 end
        local c = ALC.Core.Metrics.counters
        local zone = (GetInstanceInfo() ~= "" and GetInstanceInfo()) or GetZoneText() or "Unknown"
        local logging = (LoggingCombat and LoggingCombat()) and "|cff00ff00Yes|r" or "|cffaaaaaaNo|r"
        local autoOn  = cfg.auto_combatlog_on_raid and "|cff00ff00On|r" or "|cffaaaaaaOff|r"

        L.info("|cff00ff00Ascension Logs Companion|r |cff888888v" .. ALC.Core.Constants.VERSION .. "|r")
        L.info("Current zone: |cffe8e8e8" .. zone .. "|r   /combatlog: " .. logging)
        L.info("Auto-log on zone entry: " .. autoOn)
        L.info(" ")
        L.info("|cffffd200Combatant info delivery|r")
        L.info("  Snapshots delivered: |cffe8e8e8" .. (c.chunks_flushed or 0) .. "|r"
            .. "    Pending: |cffe8e8e8" .. (c.chunks_queued or 0) .. "|r")
        if (c.chunks_dropped_ttl or 0) > 0 or (c.chunks_dropped_overflow or 0) > 0 then
            L.info("  Dropped: " .. (c.chunks_dropped_ttl or 0) .. " stale, "
                .. (c.chunks_dropped_overflow or 0) .. " overflow")
        end
        L.info(" ")
        L.info("|cffffd200Inspect activity|r")
        L.info("  Players inspected: |cff00ff00" .. (c.inspect_success or 0) .. " ok|r"
            .. " / |cffaaaaaa" .. (c.inspect_sent or 0) .. " sent|r"
            .. " / |cffff7777" .. (c.inspect_timeout or 0) .. " timeout|r")
        L.info("  Players cached: |cffe8e8e8" .. nCache .. "|r")
        if (c.boss_transitions or 0) > 0 then
            L.info("  Boss transitions: |cffe8e8e8" .. c.boss_transitions .. "|r")
        end

    elseif cmd == "debug" then
        _G.ALC_Config = _G.ALC_Config or {}
        ALC_Config.debug = not ALC_Config.debug
        L.info("Debug: " .. (ALC_Config.debug and "on" or "off"))

    elseif cmd == "inspect-now" then
        ALC.Capture.InspectLoop.inspectNow("target")

    elseif cmd == "hijack" and parts[2] == "off" then
        ALC.Transport.SpellFailedHijack.disable()
        L.info("Hijack disabled. /reload to re-enable.")

    elseif cmd == "zone" then
        local sub = parts[2]
        _G.ALC_Config = _G.ALC_Config or {}
        ALC_Config.monitored_zones = ALC_Config.monitored_zones or {}
        if sub == "add" then
            local zone = table.concat(parts, " ", 3)
            if zone == "" then
                zone = GetInstanceInfo() ~= "" and GetInstanceInfo() or GetZoneText()
            end
            ALC_Config.monitored_zones[zone] = true
            L.info("Added zone: " .. zone)
        elseif sub == "remove" then
            local zone = table.concat(parts, " ", 3)
            ALC_Config.monitored_zones[zone] = nil
            L.info("Removed zone: " .. zone)
        elseif sub == "list" then
            for zone, enabled in pairs(ALC_Config.monitored_zones) do
                if enabled then L.info("  - " .. zone) end
            end
        else
            L.info("Usage: /alc zone add|remove|list [name]")
        end

    elseif cmd == "clear-cache" then
        _G.ALC_InspectCache = {}
        L.info("Inspect cache cleared.")

    elseif cmd == "boss" then
        local sub = parts[2]
        if sub == "current" or sub == nil then
            local curr = ALC.Capture.EncounterTracker.getCurrentBoss()
            L.info("Current boss: " .. (curr or "(none)"))
            L.info("Registry size: " .. ALC.Zone.BossRegistry.count() .. " bosses")
        elseif sub == "add" then
            local name = table.concat(parts, " ", 3)
            if name ~= "" then
                ALC.Zone.BossRegistry.add(name)
                L.info("Added boss: " .. name)
            end
        elseif sub == "set" then
            local name = table.concat(parts, " ", 3)
            ALC.Capture.EncounterTracker.setBoss(name ~= "" and name or nil)
            L.info("Force-set current boss: " .. name)
        elseif sub == "clear" then
            ALC.Capture.EncounterTracker.clearBoss()
            L.info("Cleared current boss.")
        else
            L.info("Usage: /alc boss current | add NAME | set NAME | clear")
        end

    elseif cmd == "metrics" and parts[2] == "reset" then
        ALC.Core.Metrics.reset()
        L.info("Metrics reset.")

    elseif cmd == "publish-now" then
        if ALC.Capture.SnapshotPipeline then
            ALC.Capture.SnapshotPipeline.forcePublish()
        else
            L.warn("SnapshotPipeline not loaded")
        end

    elseif cmd == "help" then
        printHelp()

    else
        L.info("Unknown: " .. cmd)
        printHelp()
    end
end
