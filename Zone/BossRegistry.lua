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
    "Basalthane",  -- Ascension-custom addition
}
-- Scarlet Monastery (5-man, dev fixture for Phase 2 ingestion testing).
-- Captured combat log: 2026-04-25-12.51.56 WoWCombatLog.txt
-- Three encounters validated: Interrogator Vishas (entry 3983),
-- Ironspine (entry 6489, possibly BB custom), Bloodmage Thalnos (entry 4543).
B.BY_ZONE["Scarlet Monastery"] = {
    "Interrogator Vishas",
    "Ironspine",
    "Bloodmage Thalnos",
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

-- Dire Maul North (5-man "King's wing"). Tribute run lineup. The four
-- guard bosses + Kromcrush + King Gordok form the main sequence;
-- Cho'Rush spawns alongside King Gordok.
B.BY_ZONE["Dire Maul"] = {
    "Guard Mol'dar",
    "Stomper Kreeg",
    "Guard Fengus",
    "Guard Slip'kik",
    "Captain Kromcrush",
    "Cho'Rush the Observer",
    "King Gordok",
}

-- Wailing Caverns (5-man, Barrens). Four Druids of the Fang + Mutanus +
-- two rares (Verdan, Skum).
B.BY_ZONE["Wailing Caverns"] = {
    "Lord Cobrahn",
    "Lord Pythas",
    "Lord Serpentis",
    "Lady Anacondra",
    "Verdan the Everliving",   -- rare
    "Skum",                    -- rare turtle
    "Mutanus the Devourer",
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
