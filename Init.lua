-- Init.lua
-- Boot sequence. Wires everything together after ADDON_LOADED.

local ALC = _G.ALC

local function boot()
    -- Seed config with defaults
    _G.ALC_Config = _G.ALC_Config or {}
    for k, v in pairs(ALC.Core.Constants.DEFAULT_CONFIG) do
        if ALC_Config[k] == nil then
            ALC_Config[k] = v
        end
    end

    -- Per-character state
    ALC.Parser.Session.init()

    -- Rehydrate inspect cache
    ALC.Capture.InspectCache.rehydrate()

    -- Start subsystems (order matters: hijack must be ready to receive
    -- chunks before SnapshotPipeline starts producing them).
    -- Each wrapped in pcall so one bad module doesn't break the whole addon.
    local function safeStart(name, mod)
        if not mod or type(mod.start) ~= "function" then
            ALC.Core.Logger.error(name .. ": module or .start missing")
            return
        end
        local ok, err = pcall(mod.start)
        if not ok then
            ALC.Core.Logger.error(name .. ".start() errored: " .. tostring(err))
        else
            ALC.Core.Logger.debug(name .. " started")
        end
    end

    safeStart("ZoneMonitor", ALC.Zone.ZoneMonitor)
    safeStart("EncounterDetector", ALC.Parser.EncounterDetector)
    safeStart("EncounterTracker", ALC.Capture.EncounterTracker)
    safeStart("SpellFailedHijack", ALC.Transport.SpellFailedHijack)
    safeStart("AddonChannel", ALC.Transport.AddonChannel)
    safeStart("InspectLoop", ALC.Capture.InspectLoop)
    safeStart("SnapshotPipeline", ALC.Capture.SnapshotPipeline)
    safeStart("MinimapButton", ALC.UI.MinimapButton)

    ALC.Core.Logger.info("|cff00ff00Ascension Logs Companion|r v" .. ALC.Core.Constants.VERSION .. " loaded.  |cffffd200/alc|r for settings.")

    -- First-boot sanity probe
    if ALC_Config.debug then
        local hasCAO = type(_G.CAO_Known) == "table"
        local hasMystic = type(_G.AscensionUI) == "table"
                     and type(_G.AscensionUI.MysticEnchant) == "table"
        ALC.Core.Logger.debug("CAO_Known present: " .. tostring(hasCAO))
        ALC.Core.Logger.debug("AscensionUI.MysticEnchant present: " .. tostring(hasMystic))
    end
end

local bootFrame = CreateFrame("Frame")
bootFrame:RegisterEvent("ADDON_LOADED")
bootFrame:RegisterEvent("PLAYER_LOGIN")
bootFrame:RegisterEvent("PLAYER_LOGOUT")
bootFrame:SetScript("OnEvent", function(self, event, arg1)
    if event == "ADDON_LOADED" and arg1 == "AscensionLogsCompanion" then
        boot()
        self:UnregisterEvent("ADDON_LOADED")
    elseif event == "PLAYER_LOGIN" then
        -- Peer broadcast join-storm window starts now
        if ALC.Transport.AddonChannel then
            ALC.Transport.AddonChannel.markJoin()
        end
    elseif event == "PLAYER_LOGOUT" then
        -- Persist metrics snapshot so post-raid analysis survives the session
        if ALC.Core.Metrics then
            ALC.Core.Metrics.persist()
        end
    end
end)
