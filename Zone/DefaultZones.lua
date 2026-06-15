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
    ["Blackrock Caverns"]     = true,
    ["Blackrock Depths"]      = true,
    ["Lower Blackrock Spire"] = true,
    ["Upper Blackrock Spire"] = true,
    ["Dire Maul"]             = true,
    ["Stratholme"]            = true,
    ["Scholomance"]           = true,

    -- ── Triumvirate (stock WotLK 3.3.5a) ─────────────────────────────────
    -- Verbatim Map.dbc MapName_lang (enUS) strings = exactly what
    -- GetInstanceInfo() returns on a stock 3.3.5a client (extracted from the
    -- Triumvirate client 2026-06-15, base archives, no patch-4 edits). A few
    -- are vanilla instances whose stock map name differs from the
    -- Ascension-client entries above (e.g. stock "Deadmines" vs "The
    -- Deadmines", single-map "Blackrock Spire" vs the L/U split) - both forms
    -- coexist harmlessly. NOTE: the TBC raids below are stock client maps but
    -- are not yet in the Triumvirate backend content seed, so kills there
    -- won't classify until the bosses are seeded.

    -- Raids (TBC + WotLK; launch = Karazhan + The Obsidian Sanctum)
    ["Karazhan"]                              = true,
    ["Ahn'Qiraj Temple"]                      = true,
    ["Gruul's Lair"]                          = true,
    ["Magtheridon's Lair"]                    = true,
    ["Coilfang: Serpentshrine Cavern"]        = true,
    ["Tempest Keep"]                          = true,
    ["The Battle for Mount Hyjal"]            = true,
    ["Black Temple"]                          = true,
    ["Zul'Aman"]                              = true,
    ["The Sunwell"]                           = true,
    ["Ulduar"]                                = true,
    ["The Obsidian Sanctum"]                  = true,
    ["The Eye of Eternity"]                   = true,
    ["Vault of Archavon"]                     = true,
    ["Trial of the Crusader"]                 = true,
    ["Icecrown Citadel"]                      = true,
    ["The Ruby Sanctum"]                      = true,

    -- Vanilla 5-man stock-name variants (GetInstanceInfo differs from above)
    ["Deadmines"]                             = true,
    ["Stormwind Stockade"]                    = true,
    ["Blackrock Spire"]                       = true,

    -- TBC 5-mans
    ["Hellfire Citadel: Ramparts"]            = true,
    ["Hellfire Citadel: The Blood Furnace"]   = true,
    ["Hellfire Citadel: The Shattered Halls"] = true,
    ["Coilfang: The Slave Pens"]              = true,
    ["Coilfang: The Underbog"]                = true,
    ["Coilfang: The Steamvault"]              = true,
    ["Auchindoun: Mana-Tombs"]                = true,
    ["Auchindoun: Auchenai Crypts"]           = true,
    ["Auchindoun: Sethekk Halls"]             = true,
    ["Auchindoun: Shadow Labyrinth"]          = true,
    ["Tempest Keep: The Mechanar"]            = true,
    ["Tempest Keep: The Botanica"]            = true,
    ["Tempest Keep: The Arcatraz"]            = true,
    ["The Escape From Durnholde"]             = true,
    ["Opening of the Dark Portal"]            = true,
    ["Magister's Terrace"]                    = true,

    -- WotLK 5-mans
    ["Utgarde Keep"]                          = true,
    ["Utgarde Pinnacle"]                      = true,
    ["The Nexus"]                             = true,
    ["The Oculus"]                            = true,
    ["Azjol-Nerub"]                           = true,
    ["Ahn'kahet: The Old Kingdom"]            = true,
    ["Drak'Tharon Keep"]                      = true,
    ["Gundrak"]                               = true,
    ["Halls of Stone"]                        = true,
    ["Halls of Lightning"]                    = true,
    ["Violet Hold"]                           = true,
    ["The Culling of Stratholme"]             = true,
    ["Trial of the Champion"]                 = true,
    ["The Forge of Souls"]                    = true,
    ["Pit of Saron"]                          = true,
    ["Halls of Reflection"]                   = true,
}
