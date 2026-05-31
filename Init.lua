-- Init.lua
-- Boot sequence. Wires everything together after ADDON_LOADED.

local ALC = _G.ALC

local function boot()
    -- Reclaim memory from the deprecated ALC_SessionLog SavedVariable. It
    -- was write-only fallback persistence that nothing on the addon side
    -- or backend side ever read, but it grew unbounded for 30 days
    -- (~290 KB per encounter * many encounters per session) and on heavy
    -- raiders pushed the Lua VM past its allocation cap mid-combat,
    -- producing "memory allocation error: block too big" on inspect-side
    -- handlers. WoW's SavedVariables loader still dofile()s the existing
    -- on-disk blob into _G.ALC_SessionLog before our addon boots, so we
    -- nil it here to let the GC reclaim it immediately. The variable is
    -- no longer declared in the .toc, so on next save WoW writes only
    -- the still-declared variables and the bloat drops off disk too.
    -- Safe to remove this block in a future version once we're confident
    -- everyone has cycled through one save with 0.30.13+.
    _G.ALC_SessionLog = nil

    -- Seed config with defaults
    _G.ALC_Config = _G.ALC_Config or {}
    for k, v in pairs(ALC.Core.Constants.DEFAULT_CONFIG) do
        if ALC_Config[k] == nil then
            ALC_Config[k] = v
        end
    end

    -- Detect server family BEFORE any module starts so they can branch on
    -- ALC.Profile during their .start() hooks. Sets ALC.Profile to one of
    -- "ascension" | "epoch" | "unknown" and caches to ALC_Config.
    ALC.Core.Profile.detect()

    -- Per-character state
    ALC.Parser.Session.init()

    -- Rehydrate inspect cache
    ALC.Capture.InspectCache.rehydrate()

    -- Start subsystems (order matters: the relay must be ready to receive
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
    safeStart("SpellFailedRelay", ALC.Transport.SpellFailedRelay)
    safeStart("AddonChannel", ALC.Transport.AddonChannel)
    safeStart("VersionCheck", ALC.Transport.VersionCheck)
    safeStart("InspectLoop", ALC.Capture.InspectLoop)
    safeStart("SnapshotPipeline", ALC.Capture.SnapshotPipeline)
    safeStart("PetPipeline", ALC.Capture.PetPipeline)
    -- PetTracker MUST start after SnapshotPipeline so its PLAYER_REGEN_DISABLED
    -- handler is registered (and thus fires) AFTER SnapshotPipeline's, which
    -- calls SpellFailedRelay.clearQueue() at pull-start. PetTracker enqueues
    -- the fresh pet-pair sweep into the now-empty queue.
    safeStart("PetTracker", ALC.Capture.PetTracker)
    -- Telemetry boots last among capture modules. It only emits while
    -- combat-logging in a raid/party instance and gates on relay queue
    -- depth, so it's safe to run alongside CI + PP transit on the same
    -- SpellFailedRelay.
    safeStart("Telemetry", ALC.Capture.Telemetry)
    -- KeystoneScan arms the Mythic+ lifecycle events (start/complete). It is
    -- event-driven and Ascension-only (no-ops on Epoch where C_MythicPlus is
    -- absent), so it's cheap to boot alongside the other capture modules.
    safeStart("KeystoneScan", ALC.Capture.KeystoneScan)
    safeStart("MinimapButton", ALC.UI.MinimapButton)

    ALC.Core.Logger.info("|cff00ff00Ascension Logs Companion|r v" .. ALC.Core.Constants.VERSION .. " loaded.  |cffffd200/alc|r for settings.")

    -- First-boot sanity probe
    if ALC_Config.debug then
        local hasCAO = type(_G.CAO_Known) == "table"
        local hasMystic = type(_G.AscensionUI) == "table"
                     and type(_G.AscensionUI.MysticEnchant) == "table"
        ALC.Core.Logger.debug("Server profile: " .. tostring(ALC.Profile))
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
