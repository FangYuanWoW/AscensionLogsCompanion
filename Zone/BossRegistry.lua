-- Zone/BossRegistry.lua
-- Canonical boss name list for Ascension raid content. Used by
-- EncounterTracker to detect when the raid switches to a new boss and
-- kick off a fresh inspect cycle.
--
-- Source of truth: ascensionlogs.gg `creatures` table where is_boss=true
-- exported 2026-04-24. Keep this file synchronized with the backend when
-- new raid phases unlock (BWL, AQ20, AQ40, Naxx, etc.). The addon matches
-- by lowercased name, so casing differences between the DB and in-game
-- UnitName() won't break detection.
--
-- Storage: flat set { [bossName:lower()] = "Canonical Name" } for O(1)
-- match in hot paths (PLAYER_TARGET_CHANGED / UPDATE_MOUSEOVER_UNIT).

local ALC = _G.ALC
local B = {}
ALC.Zone.BossRegistry = B

B.BOSSES = {}    -- flat lookup set; the hot-path structure
B.BY_ZONE = {}   -- convenience for debug / GUI listings

--------------------------------------------------------------------------------
-- Currently seeded in the backend creatures table (BB Phase 1-2 content).
-- Keys are the `location` column from the DB; bosses are exactly as stored.
--------------------------------------------------------------------------------
B.BY_ZONE["Molten Core"] = {
    "Lucifron", "Magmadar", "Gehennas", "Garr", "Baron Geddon",
    "Shazzrah", "Sulfuron Harbinger", "Golemagg the Incinerator",
    "Majordomo Executus", "Ragnaros",
}
B.BY_ZONE["Zul'Gurub"] = {
    "High Priest Venoxis", "High Priestess Jeklik", "High Priestess Mar'li",
    "High Priest Thekal", "High Priestess Arlokk", "Bloodlord Mandokir",
    "Jin'do the Hexxer", "Hakkar",
    -- Optional / sub-bosses
    "Gahz'ranka", "Gri'lek", "Hazza'rah", "Renataki", "Wushoolay",
}
B.BY_ZONE["Onyxia's Lair"] = {
    "Onyxia",
    "Basalthane",          -- Ascension-custom addition
    "Ortorg the Ardent",   -- Epoch (Project Epoch) Phase 1 addition
    "Atressian",           -- Epoch (Project Epoch) Phase 1 addition
}
-- Scarlet Monastery (5-man, all four wings). Full lineup synced from the
-- CoA creatures table 2026-07-31 (was a three-boss dev fixture before,
-- which left chain-pulled bosses like Herod without a mid-combat CI
-- republish and their kills without a difficulty capture).
B.BY_ZONE["Scarlet Monastery"] = {
    "Interrogator Vishas",
    "Bloodmage Thalnos",
    "Houndmaster Loksey",
    "Arcanist Doan",
    "Azshir the Sleepless",
    "Fallen Champion",
    "Ironspine",
    "Herod",
    "High Inquisitor Fairbanks",
    "Scarlet Commander Mograine",
    "High Inquisitor Whitemane",
    "Headless Horseman",    -- seasonal
}

-- The Stockade (5-man, Stormwind). Standard vanilla 1.12 lineup; verify
-- in-game UnitName() if BB has renamed any.
B.BY_ZONE["The Stockade"] = {
    "Targorr the Dread",
    "Kam Deepfury",
    "Hamhock",
    "Bazil Thredd",
    "Dextren Ward",
    "Bruegal Ironknuckle",  -- rare
}

-- Dire Maul (5-man, all three wings). North tribute lineup + East + West,
-- synced from the CoA creatures table 2026-07-31.
B.BY_ZONE["Dire Maul"] = {
    -- North (King's wing / tribute)
    "Guard Mol'dar",
    "Stomper Kreeg",
    "Guard Fengus",
    "Guard Slip'kik",
    "Captain Kromcrush",
    "Cho'Rush the Observer",
    "King Gordok",
    "Gordok Captain",
    "Gordok Reaver",
    "Gordok Warlock",
    -- East
    "Pusillin",
    "Lethtendris",
    "Hydrospawn",
    "Alzzin the Wildshaper",
    "Isalien",
    -- West
    "Tendris Warpwood",
    "Illyanna Ravenoak",
    "Magister Kalendris",
    "Tsu'zee",
    "Immol'thar",
    "Prince Tortheldrin",
    "Lord Hel'nurath",
}

-- Wailing Caverns (5-man, Barrens). Four Druids of the Fang + Mutanus +
-- two rares (Verdan, Skum).
B.BY_ZONE["Wailing Caverns"] = {
    "Lord Cobrahn",
    "Lord Pythas",
    "Lord Serpentis",
    "Lady Anacondra",
    "Kresh",                   -- rare turtle
    "Deviate Faerie Dragon",   -- rare
    "Verdan the Everliving",   -- rare
    "Skum",                    -- rare turtle
    "Mutanus the Devourer",
}
-- Maraudon (5-man, Desolace). Vanilla 1.12 lineup.
B.BY_ZONE["Maraudon"] = {
    "Noxxion",
    "Razorlash",
    "Lord Vyletongue",
    "Meshlok the Harvester",   -- rare
    "Celebras the Cursed",
    "Landslide",
    "Tinkerer Gizlock",
    "Rotgrip",
    "Princess Theradras",
}

-- Uldaman (5-man, Badlands). Vanilla 1.12 lineup. The Lost Dwarves are a
-- group encounter (Baelog + Eric the Swift + Olaf) targetable individually
-- so we register all three names plus the group label. Eric's name varies
-- across cores ("The Swift" vs "the Swift"); registered both forms.
B.BY_ZONE["Uldaman"] = {
    "Revelosh",
    "Baelog",
    "Eric \"The Swift\"",
    "Eric the Swift",       -- some cores drop the quotes
    "Olaf",
    "The Lost Dwarves",     -- group label, occasionally used as canonical
    "Ironaya",
    "Obsidian Sentinel",
    "Ancient Stone Keeper",
    "Galgann Firehammer",
    "Grimlok",
    "Archaedas",
}

-- Zul'Farrak (5-man, Tanaris). Vanilla 1.12 lineup. The Sergeant Bly +
-- prisoner event spawns 5 prisoner NPCs that fight alongside the player
-- group; Bly is the named boss-tagged target. Gahz'rilla is summoned at
-- the trough via Mallet of Zul'Farrak.
B.BY_ZONE["Zul'Farrak"] = {
    "Antu'sul",
    "Theka the Martyr",
    "Witch Doctor Zum'rah",
    "Nekrum Gutchewer",
    "Shadowpriest Sezz'ziz",
    "Hydromancer Velratha",
    "Sergeant Bly",
    "Sandfury Executioner",
    "Gahz'rilla",
    "Chief Ukorz Sandscalp",
    "Dustwraith",              -- rare
    "Sandarr Dunereaver",      -- rare
    "Zerillis",                -- rare
}

-- Blackrock Depths (5-man, BRM). Vanilla 1.12 lineup. The Ring of Law
-- rotates one of six bosses per run; all six listed so any roll matches.
-- Theldren is the optional arena PvP encounter (group of player-class
-- mobs). Verek is Stilgiss's pet but appears in the kill list on some
-- private cores, included for completeness. The Seven Dwarves are
-- handled as a group encounter in WoW; we register the canonical
-- "Doom'rel" name (the leader summoned at the runestone) plus the
-- individuals so any tag works.
B.BY_ZONE["Blackrock Depths"] = {
    "Lord Roccor",
    "High Interrogator Gerstahn",
    -- Ring of Law (one rolls per run)
    "Anub'shiah",
    "Eviscerator",
    "Gorosh the Dervish",
    "Grizzle",
    "Hedrum the Creeper",
    "Ok'thor the Breaker",
    "Theldren",  -- optional PvP arena encounter
    "Pyromancer Loregrain",
    "Houndmaster Grebmar",
    "Lord Incendius",
    "Warder Stilgiss",
    "Verek",
    "Fineous Darkvire",
    "Bael'Gar",
    "General Angerforge",
    "Golem Lord Argelmach",
    "Hurley Blackbreath",
    "Phalanx",
    "Plugger Spazzring",
    "Ambassador Flamelash",
    "Panzor the Invincible",
    "Ribbly Screwspigot",
    "Watchman Doomgrip",
    "Magmus",
    "Emperor Dagran Thaurissan",
    "Princess Moira Bronzebeard",
    -- The Seven Dwarves (Doomforge group encounter)
    "Doom'rel",
    "Doom'rel the Necromancer",  -- some cores include the title
    "Doom'caller",
    "Doom'priest",
    "Doom'spirit",
    "Doom'rage",
    "Doom'cloak",
    "Doom'whisper",
}

-- Scholomance (5-man, EPL). Vanilla 1.12 lineup. Verify exact names in
-- runtime via /alc boss add if any are off (e.g. some servers spell
-- "Doctor Theolen Krastinov" without the title).
B.BY_ZONE["Scholomance"] = {
    "Kirtonos the Herald",
    "Jandice Barov",
    "Rattlegore",
    "Death Knight Darkreaver",
    "Marduk Blackpool",
    "Vectus",
    "Lady Illucia Barov",
    "Lord Alexei Barov",
    "The Ravenian",
    "Lorekeeper Polkelt",
    "Ras Frostwhisper",
    "Kormok",
    "Instructor Malicia",
    "Doctor Theolen Krastinov",
    "Darkmaster Gandling",
    -- Sub-bosses tracked by the backend roster
    "Blood Steward of Kirtonos",
    "Dark Shade",
    "Unstable Corpse",
    "Carrion Swarmer",
    "Scholomance Occultist",
}
-- Blackrock Caverns (5-man, BRM). Ascension-custom content, live-logged via ALC.
-- Seeded in the backend creatures table 2026-06-11; names are the exact combat-log
-- spelling (verified against BB report 9224). Beauty is the optional pet boss.
B.BY_ZONE["Blackrock Caverns"] = {
    "Rom'ogg Bonecrusher",
    "Corla, Herald of Twilight",
    "Karsh Steelbender",
    "Beauty",
    "Ascendant Lord Obsidius",
}
--------------------------------------------------------------------------------
-- Dungeons synced from the CoA (Conquest of Azeroth) creatures table
-- 2026-07-31. Names are exactly as stored in the backend; the addon's
-- lowercased match absorbs casing drift. Rares included - the backend
-- tracks them as encounters.
--------------------------------------------------------------------------------
B.BY_ZONE["Ragefire Chasm"] = {
    "Oggleflint",
    "Taragaman the Hungerer",
    "Jergosh the Invoker",
    "Bazzalan",
}
B.BY_ZONE["The Deadmines"] = {
    "Rhahk'Zor",
    "Miner Johnson",
    "Sneed",
    "Sneed's Shredder",
    "Gilnid",
    "Mr. Smite",
    "Cookie",
    "Captain Greenskin",
    "Edwin VanCleef",
}
B.BY_ZONE["Shadowfang Keep"] = {
    "Rethilgore",
    "Razorclaw the Butcher",
    "Baron Silverlaine",
    "Commander Springvale",
    "Odo the Blindwatcher",
    "Fenrus the Devourer",
    "Wolf Master Nandos",
    "Archmage Arugal",
    "Deathsworn Captain",      -- rare
}
B.BY_ZONE["Blackfathom Deeps"] = {
    "Ghamoo-ra",
    "Lady Sarevess",
    "Gelihast",
    "Baron Aquanis",
    "Old Serra'kis",
    "Twilight Lord Kelris",
    "Lorgus Jett",
    "Aku'mai",
}
B.BY_ZONE["Gnomeregan"] = {
    "Grubbis",
    "Viscous Fallout",
    "Electrocutioner 6000",
    "Crowd Pummeler 9-60",
    "Mekgineer Thermaplugg",
    "Dark Iron Ambassador",    -- rare
}
B.BY_ZONE["Razorfen Kraul"] = {
    "Roogug",
    "Aggem Thorncurse",
    "Death Speaker Jargba",
    "Overlord Ramtusk",
    "Agathelos the Raging",
    "Charlga Razorflank",
    "Blind Hunter",            -- rare
    "Earthcaller Halmgar",     -- rare
}
B.BY_ZONE["Razorfen Downs"] = {
    "Tuten'kash",
    "Mordresh Fire Eye",
    "Glutton",
    "Amnennar the Coldbringer",
    "Plaguemaw the Rotting",
    "Ragglesnout",             -- rare
}
B.BY_ZONE["Sunken Temple"] = {
    "Atal'alarion",
    "Jammal'an the Prophet",
    "Ogom the Wretched",
    "Dreamscythe",
    "Weaver",
    "Morphaz",
    "Hazzas",
    "Avatar of Hakkar",
    "Shade of Eranikus",
    "Festering Rotslime",
    "Spawn of Hakkar",
}
B.BY_ZONE["Lower Blackrock Spire"] = {
    "Highlord Omokk",
    "Shadow Hunter Vosh'gajin",
    "War Master Voone",
    "Mother Smolderweb",
    "Urok Doomhowl",
    "Quartermaster Zigris",
    "Gizrul the Slavener",
    "Halycon",
    "Overlord Wyrmthalak",
    -- Rares
    "Bannok Grimaxe",
    "Burning Felguard",
    "Crystal Fang",
    "Ghok Bashguud",
    "Spirestone Battle Lord",
    "Spirestone Butcher",
    "Spirestone Lord Magus",
    "Warosh",
    "Xot'hot the Burning",
}
B.BY_ZONE["Upper Blackrock Spire"] = {
    "Pyroguard Emberseer",
    "Solakar Flamewreath",
    "Goraluk Anvilcrack",
    "Warchief Rend Blackhand",
    "Gyth",
    "The Beast",
    "General Drakkisath",
    -- Rares / event
    "Father Flame",
    "Jed Runewatcher",
    "Lord Valthalak",
}
B.BY_ZONE["Stratholme"] = {
    -- Live side
    "Hearthsinger Forresten",
    "The Unforgiven",
    "Timmy the Cruel",
    "Malor the Zealous",
    "Cannon Master Willey",
    "Archivist Galford",
    "Grand Crusader Dathrohan",
    "Balnazzar",
    "Crimson Hammersmith",
    "Skul",
    "Stonespine",
    -- Dead side
    "Magistrate Barthilas",
    "Baroness Anastari",
    "Nerub'enkan",
    "Maleki the Pallid",
    "Black Guard Swordsmith",
    "Ramstein the Gorger",
    "Baron Rivendare",
    "Lord Aurius Rivendare",
    "Postmaster Malown",
}
B.BY_ZONE["De Other Side"] = {
    "Drak'math the Sinister King",
    "Muzah, the Shadow Hunter",
    "Vol\226\128\153zeen",     -- curly apostrophe, exactly as the client names it
    "Vol'zeen",                -- straight-apostrophe fallback
}
B.BY_ZONE["Vaults of the Inquisition"] = {
    "Inquisitorial Confessor Konrad",
    "His Majesty Darkandle",
    "The Deceiver's Presence",
}

B.BY_ZONE["World Bosses"] = {
    "Atal'zul, the Soulreaver",
    "Azuregos",
    "Emeriss",
    "Lord Kazzak",
    "Lethon",
    "Setis",
    "Snowgrave",
    "The Will of Soggoth",
    "Taerar",
    "Ysondre",
    "Volchan",  -- Epoch (Project Epoch) Phase 1 world boss
}

--------------------------------------------------------------------------------
-- Phase-forward placeholders. These zones are not yet seeded in the backend
-- creatures table because BB has not unlocked the content. When the
-- corresponding raid opens, uncomment and verify names match the DB.
--------------------------------------------------------------------------------
-- B.BY_ZONE["Blackwing Lair"] = {
--     "Razorgore the Untamed", "Vaelastrasz the Corrupt", "Broodlord Lashlayer",
--     "Firemaw", "Ebonroc", "Flamegor", "Chromaggus", "Nefarian",
-- }
-- B.BY_ZONE["Ruins of Ahn'Qiraj"] = {
--     "Kurinnaxx", "General Rajaxx", "Moam", "Buru the Gorger",
--     "Ayamiss the Hunter", "Ossirian the Unscarred",
-- }
-- B.BY_ZONE["Temple of Ahn'Qiraj"] = {
--     "The Prophet Skeram", "Silithid Royalty", "Battleguard Sartura",
--     "Fankriss the Unyielding", "Viscidus", "Princess Huhuran",
--     "Twin Emperors", "Emperor Vek'lor", "Emperor Vek'nilash",
--     "Ouro", "C'Thun",
-- }
-- B.BY_ZONE["Naxxramas"] = {
--     "Anub'Rekhan", "Grand Widow Faerlina", "Maexxna",
--     "Noth the Plaguebringer", "Heigan the Unclean", "Loatheb",
--     "Instructor Razuvious", "Gothik the Harvester", "The Four Horsemen",
--     "Patchwerk", "Grobbulus", "Gluth", "Thaddius",
--     "Sapphiron", "Kel'Thuzad",
-- }

-- Build the flat lookup set
for _, list in pairs(B.BY_ZONE) do
    for _, name in ipairs(list) do
        B.BOSSES[name:lower()] = name
    end
end

-- Returns canonical boss name if match, else nil.
function B.match(unitName)
    if type(unitName) ~= "string" or unitName == "" then return nil end
    return B.BOSSES[unitName:lower()]
end

-- User-extensible at runtime via /alc boss add "Custom Boss Name"
function B.add(name)
    if not name or name == "" then return end
    B.BOSSES[name:lower()] = name
end

function B.remove(name)
    if not name then return end
    B.BOSSES[name:lower()] = nil
end

function B.count()
    local n = 0
    for _ in pairs(B.BOSSES) do n = n + 1 end
    return n
end
