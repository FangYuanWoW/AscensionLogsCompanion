-- Zone/DefaultZones.lua
-- Default monitored zone list. User-editable via settings GUI.
-- Case-insensitive match against GetInstanceInfo() / GetZoneText().

local ALC = _G.ALC
local D = {}
ALC.Zone.DefaultZones = D

D.DEFAULTS = {
    -- Classic raid instances
    ["Molten Core"]          = true,
    ["Blackwing Lair"]       = true,
    ["Zul'Gurub"]            = true,
    ["Ruins of Ahn'Qiraj"]   = true,
    ["Temple of Ahn'Qiraj"]  = true,
    ["Ahn'Qiraj"]            = true,
    ["Naxxramas"]            = true,
    ["Onyxia's Lair"]        = true,

    -- World bosses + outdoor subzones
    ["Azuregos (PvE)"]        = true,
    ["Lord Kazzak (PvE)"]     = true,
    ["Kazzak (PvE)"]          = true,
    ["Emeriss (PvE)"]         = true,
    ["Lethon (PvE)"]          = true,
    ["Taerar (PvE)"]          = true,
    ["Ysondre (PvE)"]         = true,
    ["Soggoth (PvE)"]         = true,
    ["Setis (PvE)"]           = true,
    ["Snowgrave (PvE)"]       = true,
    ["Atal'zull (PvE)"]       = true,
    ["Kaldros Depthbreaker (PvE)"] = true,

    -- AQ gate subzones
    ["The Scarab Wall"]       = true,
    ["The Scarab Dais"]       = true,
    ["Master's Gastric Pit"]  = true,

    -- Dream bosses subzones
    ["Bough Shadow"]          = true,
    ["Dream Bough"]           = true,
    ["Twilight Grove"]        = true,
    ["Seradane"]              = true,

    -- Other raid-event subzones
    ["The Master's Glaive"]   = true,
    ["Throne of the Doom Lord"] = true,
    ["The Tainted Scar"]      = true,
    ["Zul'Mashar"]            = true,
    ["Snowgrave's Cavern"]    = true,

    -- 5-man dungeons (testing scope)
    ["Ragefire Chasm"]        = true,
    ["Wailing Caverns"]       = true,
    ["The Deadmines"]         = true,
    ["Shadowfang Keep"]       = true,
    ["Blackfathom Deeps"]     = true,
    ["The Stockade"]          = true,
    ["Gnomeregan"]            = true,
    ["Razorfen Kraul"]        = true,
    ["Razorfen Downs"]        = true,
    ["Scarlet Monastery"]     = true,
    ["Uldaman"]               = true,
    ["Zul'Farrak"]            = true,
    ["Maraudon"]              = true,
    ["Sunken Temple"]         = true,
    ["Blackrock Depths"]      = true,
    ["Lower Blackrock Spire"] = true,
    ["Upper Blackrock Spire"] = true,
    ["Dire Maul"]             = true,
    ["Stratholme"]            = true,
    ["Scholomance"]           = true,
}
