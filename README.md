<div align="center">

<img src="docs/logo.png" alt="Ascension Logs Companion" width="128" height="128" />

# Ascension Logs Companion

**Cross-player Combatant Information capture for Ascension WoW (3.3.5a)**

Auto-inspects your raid in the background and embeds gear, talents, CharacterAdvancement builds, and mystic enchants into your `WoWCombatLog.txt` so uploads to **[ascensionlogs.gg](https://ascensionlogs.gg)** can render WarcraftLogs-style combatant detail on every report.

[![Latest release](https://img.shields.io/github/v/release/FangYuanWoW/AscensionLogsCompanion?color=4ec3ff)](https://github.com/FangYuanWoW/AscensionLogsCompanion/releases/latest)
[![License](https://img.shields.io/badge/license-MIT-e8e8e8)](LICENSE)
[![Client](https://img.shields.io/badge/client-3.3.5a-orange)](#install)

</div>

---

## Why this exists

Stock 3.3.5a does not emit `COMBATANT_INFO` events - analytics tools that
rely on them (gear breakdown, talent specs per fight, etc.) have no data
to work with. ALC fills that gap by:

1. Auto-inspecting the raid in the background (one logger covers every
   raider within inspect range, no setup or coordination needed).
2. Reading your own client's CharacterAdvancement / mystic-enchant state
   directly from the Lua API.
3. Serializing every captured Combatant Info struct, compressing it, and
   embedding it into `SPELL_CAST_FAILED` events so the server-side parser
   can demux it cleanly when the log is uploaded.

The result: dungeon and raid reports on ascensionlogs.gg can show the full
build of every player who was within ~28y of any logger during the fight.

## Install

1. Download the latest release zip and extract `AscensionLogsCompanion/`
   into your `Interface\AddOns\` folder.
2. Restart the game (or `/reload`).
3. Click the blue-flame **minimap button**, or type `/alc`.

## Usage

| Action | What it does |
|---|---|
| `/alc` | Open settings panel |
| `/alc status` | Print current state and live capture stats |
| Minimap button (click) | Toggle settings panel |
| Minimap button (shift-drag) | Reposition around minimap |

Default behavior: the addon runs continuously in raids and dungeons,
auto-starts `/combatlog` on entry to monitored zones, and prompts before
stopping when you leave. No further interaction needed.

## Settings

- **Auto /combatlog on raid/dungeon zone entry** - toggle the auto-start.
  When off, you log manually with `/combatlog` and the addon stays out of
  the way.
- **Silent auto-logging** - skip the start/stop confirmation prompts. The
  addon starts logging silently on zone entry and never auto-stops; you
  control `/combatlog` yourself.
- **Debug mode** - verbose chat output for diagnostics.
- **Monitored zones** - list of zones where auto-`/combatlog` triggers.
  Add the current zone with one click; remove anything you don't want
  with the X next to its name. Defaults cover all classic raids, world
  bosses, and the major 5-man dungeons.

## Default monitored zones

- **Raids:** Molten Core, Onyxia's Lair, Zul'Gurub, all world bosses
- **5-mans:** The Stockade, Wailing Caverns, Scarlet Monastery, Dire Maul,
  Blackrock Depths/Spire, Stratholme, Scholomance, Sunken Temple,
  Razorfen Kraul/Downs, Maraudon, Uldaman, Zul'Farrak, plus everything
  else from the classic 1.12 lineup

Customize the full list via the settings panel.

## Coexistence with other addons

Plays nicely with `FangYuanWoW/CombatLogs`. If either addon has already
enabled `/combatlog`, ALC skips its own toggle and tells you in chat that
combat logging was already active. Logging is never inadvertently
disabled.

No conflicts with WeakAuras, Skada, Recount, Details, DBM, or standard
raid frame addons.

## How the data flows

```
       inspect cycle
   +─────────────────────+
   |  raid party tokens  |  NotifyInspect cycle, gated by inspect range
   +──────────+──────────+
              |
              ▼
   +─────────────────────+
   |   Combatant Info    |  ← gear, talents, CAO, mystic, guild, arena
   |       struct        |
   +──────────+──────────+
              |  serialize → deflate → URL-safe base64
              ▼
   +─────────────────────+
   |  chunk into payloads|
   |  with sentinel      |  [[ALC_CI_v1_<session>_<guid>_<seq>/<total>]]
   |  header             |
   +──────────+──────────+
              |  embed in fail-reason field of SPELL_CAST_FAILED
              ▼
   +─────────────────────+
   |  WoWCombatLog.txt   |  ← uploaded to ascensionlogs.gg
   +─────────────────────+
```

The server-side demuxer reverses the pipeline: scans for the sentinel,
reassembles chunks per `(session, guid, snapshot)` tuple, decompresses,
parses the AceSerializer-3.0 stream, and lands a structured CI per
encounter participant in the database.

## Privacy & data scope

The addon only reads data that any other player in your raid can already
see (gear, equipped enchants, visible talents) plus your own client-side
Ascension state (CAO build, mystic enchants, active spec, guild). It
embeds that data in the combat log so the parser at ascensionlogs.gg can
attribute it back to the right encounter - nothing else is read or sent.

What's captured: gear itemstrings, vanilla talent ranks, CAO known nodes
and ranks, mystic enchant slot map, active spec, guild and rank, race,
class, level, gender. What's NOT captured: chat content, account info,
UI state, anything from other addons, anything outside the inspectable
character profile.

Inspect itself is a public protocol - anyone in your raid can see the
same data by right-clicking and inspecting. ALC just turns thousands
of one-off manual inspects into structured, per-encounter capture.

## License

MIT - see `LICENSE`.

## Author

Made by **FangYuanWoW** for the Ascension community. Issues and pull
requests welcome on this repository.
