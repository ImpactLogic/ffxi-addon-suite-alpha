# ImpactLogic's FFXI add-ons

<img src="brand.svg" alt="FFXI Addon Suite logo" width="64">

**WRITES TO YOUR DISK: the combat recorder (combatlog) saves your combat to files on your computer once recording is on. Recording ships OFF: combat files are written only after you type `//rec on combatlog`, and `//rec off combatlog` stops them. The files go to `Windower4/addons/combatlog/data/<Character>/` (about 1.3 MB per day of play on average, 11 MB on the busiest day measured, never deleted for you), and nothing is uploaded. Read the notice at the top of `addons/combatlog/README.md` before you turn it on.**

**Free and non-commercial: no ads, no donations, no paid tier, nothing is sold.** The code is MIT licensed.

A set of small, read-only add-ons for Final Fantasy XI on [Windower 4](https://www.windower.net/): themed boxes for buffs, recasts, bags and a damage meter, a step-by-step mission guide, a character snapshot, and a setup checklist that ties them together. They are one person's hobby project, written with an AI coding assistant, and they come with no promises.

## Quick start

Copy the nine folders in `addons/` into Windower's `addons/` folder. In game, try `//lua l bags`, then
`//bags layout compact` and `//bags box on`. To try the guided setup, load Checkup with `//lua l checkup`
and type `//setup`.

Charsync writes a local character snapshot when loaded, including through setup. Combatlog saves combat
captures only when enabled. The table below describes the local files each addon creates.

## Read this first

- **Not every add-on has been confirmed in game.** The status below is the project's own registry: **confirmed** means it ran in the game at some point (not necessarily at this exact version), **not confirmed** means it has passed offline tests only and nobody has run it in game yet. Expect rough edges in anything marked not confirmed, and please report what you see.
- **Read-only, by design.** Each add-on's own README says it reads what the client already holds and sends nothing to the game. A search of the shipped code found no sockets, no process launches and no packet injection; web addresses in the code are source citations only. The one exception to "sends nothing" is `//bl report`, which types one chat line only when you ask for it.
- **Automation and the game's rules.** These add-ons only read and display. Anything that plays the game for you may break Square Enix's terms of service and can get an account banned; nothing here is meant to do that, and you are responsible for what you load.
- **Memory:** combatlog holds about 20 MB of Lua memory per game client once loaded, flat over 12 days of samples; the cause was not investigated.

## Install

1. Download this repository (green **Code** button, then **Download ZIP**) and unzip it.
2. Copy the folders inside `addons/` that you want into `Windower4/addons/`. If you copy only some, also copy `boxtheme` (the shared box look) and `checkup`.
3. In game, load each one with `//lua l <name>` (for example `//lua l buffbox`). After you replace the files of an add-on that is already loaded, reload it with `//lua r <name>`.
4. Optional: type `//setup` (alias `//ck`). It lists *modules* as check boxes, such as Story or Gear and character. `//setup tick story` then `//setup apply` loads the add-ons and boxes that module needs, and ticked modules are re-applied 30 seconds after login. Nothing is ever unloaded, and recording is never part of a module: it stays under `//rec`.
5. To show or hide an add-on's box: `//<command> box on` or `//<command> box off`.

`//setup` offers **Story** and **Gear and character** when their add-ons are installed. Install all suite folders to use both modules. Applying setup also loads Charsync if present, which saves character snapshots locally. See the Charsync row below.

To update, copy the new addon files into the existing folders and keep your data folders. To remove an addon, unload it with //lua u <name> and move its folder out of Windower. Keep a backup if you want to retain its settings or recordings.

## What is in the package

Each add-on's own README has the full command list and file list. Every one also writes `data/<addon>.log` and, where Windower's settings library is used, a `data/settings.xml`, inside its own folder.

| Add-on | What it does | Main commands | What it writes (in `Windower4/addons/<name>/data/`) | Status |
|---|---|---|---|---|
| **boxtheme** | Themed backgrounds, locks and accents for every box the other add-ons draw; also the `//rec` master switch for recorders | `//boxtheme`, `//boxtheme <addon> <theme>`, `//rec on\|off\|status` | `themes.txt`, `locks.txt`, `screens.txt`, `recording.cfg` | not confirmed |
| **buffbox** | Your buffs with time left, what your food gives, Corsair roll values, Bard song potency, Ionis coalition info, a low-time warning and a buff history | `//bb`, `//bb box`, `//bb layout full\|compact`, `//bb history`, `//bb warn` | `<Character>/food.txt`, `history.tsv`, `coalitions.tsv`, `stats.log` | confirmed |
| **timers** | Ability and spell recasts as a box with time bars; a Scholar stratagem charge row | `//tm box`, `//tm abilities`, `//tm spells`, `//tm rows <n>` | log only | not confirmed |
| **bags** | How full each bag is, as bubbles or numbers, with a low-space warning | `//bags box`, `//bags mode bubbles\|numbers\|both`, `//bags warn <n>` | log only | not confirmed |
| **battlelines** | A damage meter: damage, damage taken, healing, deaths, enmity, per fight | `//bl box`, `//bl view <tab>`, `//bl mode current\|overall\|last`, `//bl report <channel>` | `fights.tsv` | not confirmed |
| **storyguide** | A storyline tracker for missions and the quests that ride along with them: your place in each storyline, your own confirmations and ticks, and an evidence log. It lists every mission and quest by name in order; it ships no walkthrough text (see below) | `//sg box`, `//sg list`, `//sg track <name>`, `//sg at <mission>`, `//sg done <n>` | per-character progress and evidence files (`.tsv`) | not confirmed |
| **charsync** | A snapshot of one character: every item in every bag with augments, gil, jobs, equipment, key items, points, currencies, REMA weapons and quest/mission pages seen so far. It saves on load, 10 seconds after login and after every zone | `//cs`, `//cs status`, `//cs need`, `//cs last`, `//cs points`, `//cs rema` | `<Character>/snapshot.tsv`, `history/`, `points.tsv`, `rema.tsv`, `currencies.tsv`, progress files, and `contributor.txt` (a random id, never a character name) | confirmed (2026-10-04, earlier version) |
| **checkup** | One command that says which facts the other add-ons hold are missing or old, which recorders stopped writing, and which add-ons have errors in their logs; also `//setup` | `//ck`, `//ck todo`, `//ck addons`, `//ck depart`, `//setup`, `//rec` | `checkup.log` | not confirmed |
| **combatlog** | Records your combat to daily files (and a live box). **Off by default**, see the notice at the top | `//rec on\|off` to record; the add-on's own README lists the rest | `<Character>/combat-<date>.tsv`, `contributor.txt`, `shared/region_zones.txt` | confirmed earlier; the `//rec` switch hook (1.4.0) is tested offline only |

`checkup` also looks for the chat and bazaar recorders (`ffxilogger`, `ffxibazaar`). Those are not part of this package; it will report them as not found.

Also included: `templates/addon/`, a starting folder for writing your own add-on.

## Story Guide: a tracker, no walkthrough text

Story Guide in this package lists every mission and quest of 23 storylines by name and in order (`skeleton/`), tracks where you are and what you have ticked, and says "No step text for this mission yet" where nothing has been written. It does not include a walkthrough: no text copied from any website ships, and no data pack is published. Short step lines in our own words, written from play, go in `addons/storyguide/own/` (see the README there) and appear over the list as they are added. Reading your position straight from the game needs id tables built from XIchecklist, whose author's licence is being confirmed, so until then you confirm where you are with `//sg at <mission>`.

<!-- recommended-addons:start -->

## Recommended and required add-ons

None of these add-ons is included in this package: each is another author's work (or our changed copy of it), so it is linked here to the original. Credits and licences are in `THIRD-PARTY-NOTICES.md`. **Required** means a suite add-on needs it to work; **recommended** means a suite feature loads or pairs with it; **optional** means nothing in the suite refers to it.

| Add-on | Original author | Link | Licence | Use in the suite | Our changes |
|---|---|---|---|---|---|
| barfiller | Morath | <https://github.com/Windower/Lua/tree/dev/addons> (collection page only; this add-on's own folder is not recorded) | BSD 3-clause | optional | yes (our changed copy is not shipped) |
| craft | Mojo | <https://github.com/Windower/Lua/tree/dev/addons/craft> | BSD 3-clause | optional | yes (our changed copy is not shipped) |
| Debuffed | Xathe (Asura) | <https://github.com/Windower/Lua/tree/dev/addons> (collection page only; this add-on's own folder is not recorded) | BSD 3-clause | optional | yes (our changed copy is not shipped) |
| distanceplus | Sammeh of Quetzalcoatl | <https://github.com/Windower/Lua/tree/dev/addons> (collection page only; this add-on's own folder is not recorded) | BSD 3-clause | optional | yes (our changed copy is not shipped) |
| enemybar | mmckee (Mike McKee) | <https://github.com/Windower/Lua/tree/dev/addons> (collection page only; this add-on's own folder is not recorded) | BSD 3-clause | optional | yes (our changed copy is not shipped) |
| equipviewer | Tako, Rubenator | <https://github.com/Windower/Lua/tree/dev/addons/equipviewer> | BSD 3-clause | optional | yes (our changed copy is not shipped) |
| InfoBar | Kenshi | <https://github.com/Windower/Lua/tree/dev/addons> (collection page only; this add-on's own folder is not recorded) | BSD 3-clause | optional | yes (our changed copy is not shipped) |
| MyHome | from20020516 | link missing | BSD-style | optional | yes (our changed copy is not shipped) |
| NyzulHelper | Glarin of Asura | link missing | BSD 3-clause | optional | yes (our changed copy is not shipped) |
| Omen | Braden, Sechs | <https://github.com/Windower/Lua/tree/dev/addons/Omen> | BSD 3-clause | optional | no (unmodified copy) |
| organizer | Byrth, maintainer: Rooks (Byrthnoth and Rooks) | <https://github.com/Windower/Lua/tree/dev/addons/organizer> | BSD 3-clause | optional | no (unmodified copy) |
| plugin_manager | Byrth (Byrthnoth) | <https://github.com/Windower/Lua/tree/dev/addons/plugin_manager> | BSD 3-clause | optional | no (unmodified copy) |
| pointwatch | Byrthnoth (Byrth) | link missing | BSD 3-clause | optional | yes (our changed copy is not shipped) |
| QuickTrade | Valok@Asura (update by Daneblood@Phoenix) | link missing | Public domain (Unlicense) | optional | no (unmodified copy) |
| React | Sammeh (of Quetzalcoatl) | link missing | BSD 3-clause | optional | no (unmodified copy) |
| roe | Cair | <https://github.com/Windower/Lua/tree/dev/addons/roe> | BSD 3-clause | optional | no (unmodified copy) |
| rolltracker | Balloon (Thomas Rogers) | <https://github.com/Windower/Lua/tree/dev/addons/rolltracker> | BSD 3-clause | optional | no (unmodified copy) |
| scoreboard | Suji (Jerry Hebert) | <https://github.com/Windower/Lua/tree/dev/addons/scoreboard> | BSD 3-clause | optional | no (unmodified copy) |
| skillchains | Ivaar | link missing | BSD 3-clause | optional | yes (our changed copy is not shipped) |
| SpellBook | SigilBaram (John S Hobart) | <https://github.com/Windower/Lua/tree/dev/addons/SpellBook> | BSD 3-clause | optional | no (unmodified copy) |
| SpellCheck | Zubis (Damien Dennehy) | <https://github.com/Windower/Lua/tree/dev/addons/SpellCheck> | BSD 3-clause | optional | no (unmodified copy) |
| superwarp | Akaden of Asura | <https://github.com/Windower/Lua/tree/dev/addons/superwarp> (did not load when checked 2026-10-28: HTTP 404) | BSD 3-clause | optional | no (unmodified copy) |
| thtracker | Krizz | <https://github.com/Windower/Lua/tree/dev/addons> (collection page only; this add-on's own folder is not recorded) | BSD 3-clause | optional | yes (our changed copy is not shipped) |
| Tickle | ragns (Copyright 2024 Windower) | <https://github.com/Windower/Lua/tree/dev/addons> (collection page only; this add-on's own folder is not recorded) | BSD 3-clause | optional | yes (our changed copy is not shipped) |
| TParty | Cliff (Windower) | <https://github.com/Windower/Lua/tree/dev/addons> (collection page only; this add-on's own folder is not recorded) | BSD 3-clause | optional | yes (our changed copy is not shipped) |
| TreasurePool | Kenshi | <https://github.com/Windower/Lua/tree/dev/addons> (collection page only; this add-on's own folder is not recorded) | BSD 3-clause | optional | yes (our changed copy is not shipped) |
| zonetimer | Ihina | <https://github.com/Windower/Lua/tree/dev/addons> (collection page only; this add-on's own folder is not recorded) | BSD 3-clause | optional | yes (our changed copy is not shipped) |

27 add-ons listed.
`pointwatch` is an optional external add-on.

<!-- recommended-addons:end -->

## Credits and licence

- The code and documents of this package are MIT licensed, copyright 2026 ImpactLogic: see [LICENSE](LICENSE). Credits are in [CREDITS.md](CREDITS.md), and other people's add-ons that this project changed are listed in [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md).
- Everything runs on Windower 4 and its libraries and resource tables.
- Written by ImpactLogic, with help from Claude (Anthropic) as a coding assistant.
- Final Fantasy XI is a registered trademark and copyright of Square Enix. This project is not affiliated with or endorsed by Square Enix, Windower or BG Wiki.

## Report a problem

Open an issue and say which add-on and version (`//<command> version`), what you did, and what you saw. The add-on's `data/<name>.log` helps, but read it first: it may contain your character name.
