# combatlog

**WRITES TO YOUR DISK: once recording is on, this add-on saves your combat to files on your computer, and records again every time it loads until you turn it off.**

- **What it records** (from the game's own action and chat packets, as the code reads them): your job, level, zone, gear, buffs, stats and TP (`c` rows); your combat actions: ability, target, message id, amount (`a` rows); combat messages such as defeats and Treasure Hunter, which can name monsters and other players (`m` rows); treasure pool drops and who won them (`pd`, `pe` rows); reward rows (`r`); and a header with the add-on version, your character name and a random contributor id. Actions aimed *at* you are recorded only after `//cbt incoming`.
- **Where:** `Windower4/addons/combatlog/data/<Character>/combat-<date>.tsv` (one plain-text file per character per day), plus `data/combatlog.log`, `data/settings.xml` and `data/contributor.txt`.
- **How fast it grows** (measured on one player's own folder, 2026-10-03 to 2026-10-27): 59 daily files, 57.6 MB in all. The main character's 38 days: median 0.6 MB, average 1.3 MB, biggest 11 MB (about 48,000 rows in one day). A day's file stops at 20 MB (`data_max_mb`). **Nothing deletes old files.**
- **Off by default.** Type **`//rec on combatlog`** to enable combat recording and **`//rec off combatlog`** to stop it. Changes are picked up within 10 seconds. Missing settings or a missing shared recording module leave combat recording off. `//cbt off` pauses it for the current session, and `//cbt on` resumes it if the shared switch allows it.
- **To delete your records:** `//lua u combatlog`, then delete the files in `combatlog/data/<Character>/` (or the whole `combatlog/data` folder). They are plain text and nothing else depends on them.
- **Nothing is uploaded.** The add-on contains no network code; the files stay on your computer, and sharing them is up to you.

## Other things to know before you rely on it

- **The master-switch hook is new in 1.4.0 and has only been tested offline** (`tools/test-recording.lua` and the source checks in it, 16 checks). It has not been run in the game yet. Evidence: `registry/addons.tsv` has no last-seen-in-game date for combatlog.
- **After you update the files, reload it:** `//lua r combatlog`. `//rec on|off` itself needs no reload (the switch file is re-read every 10 seconds).
- **Memory:** about 20 MB of Lua memory per game client once loaded, flat across 12 days of samples (`data/heap.csv`: 19.69 to 19.72 MB for the main character, 2026-10-17 to 2026-10-28; peak 20.03 MB). No growth was seen; the cause of the 20 MB was not investigated.
- **Two clients share one `data/settings.xml`:** a save from one client can rewrite the other character's section from a stale copy (IDEAS #23). Recording on/off is therefore never saved there.

**Read-only** recorder of your own combat actions, so gear questions can be answered with
measurements instead of theorycraft. See IDEAS.md #22.

It records, and shows you how you are fighting. No automation, no advice; the box is a live
readout (below) plus a warning when an expected buff (e.g. Signet) is missing while you fight.

```
//cbt status            what it is doing and where it is writing
//cbt on | off          pause/resume recording for this session (every load starts recording, unless //rec has the master switch off)
//cbt reset             start the box's totals again (recorded rows are untouched)
//cbt view [damage|short|diag|taken]   the box's layout (saved per character)
//cbt summary [date]    hit rate with a confidence interval, and counts by message id
//cbt fields            every key seen on the parsed action tables (discovery, not assumption)
//cbt incoming          also record actions aimed AT you (off by default)
//cbt expect [buffs]    warn on the box when one is missing while engaged (per character; default region)
//cbt box [on|off]      show or hide the box
//cbt test <label> [note]   start a test (ends a running one); //cbt test end; //cbt test shows it
```

Files: `data/combatlog.log`, `data/<Character>/combat-<date>.tsv`.

**Written in batches** (0.4.4): one open file, rows written every 25 rows or 2 seconds and on zone
change, logout and unload -- not opened and closed per row, which is what hung the client for garden.

**Safe to leave on.** A day's file stops growing at `data_max_mb` (default 20 MB per character, in
`data/settings.xml`); combatlog tells you once and resumes the next day with a new file. Nothing
already written is ever cut. For scale: on one player's folder (2026-10-03 to 10-27) the busiest day was 11 MB and the median day 0.6 MB (the early 0.3 MB figure was from a quiet week).

## 1.3.1: pool rows

`pd` rows now carry the real item count (it was read from the wrong place and was always 0), and the item-0
packets the client sends for the whole pool on zone-in are no longer written (543 of 560 `pd` rows on
2026-10-17 were those). Older files keep both quirks: read `count` 0 as unknown and skip `pd` rows with item 0.

## 1.3.0: the enemy on a reward row

```
r  t  ms  item  mob_id  mob_name  fight  gap_ms
```

When a chat line starting `Obtained` names an item in `reward_items` (settings.xml, default
`Ra'Kaznar starstone`), an `r` row ties it to the enemy that died with it. In the 2026-09-20..10-11 chat logs
the nine starstones all arrived 2-5 s *before* the boss's defeat line, so the reward waits up to 10 s for the
next defeat (or uses one from the 10 s before it); `gap_ms` is reward time minus defeat time, negative when the
reward came first. `mob_id`, `mob_name` and `fight` are `-` when no defeat was seen. Limit: the first defeat
after the reward is taken, so an add dying in between could be named by mistake; `gap_ms` shows how close it is.
Why: the chat line has no mob name, so per-boss starstone rates (Dhartok, Triboulex, Aita, Gartell, Aminon)
could only be guessed from timestamps.

## 1.2.0: Treasure Hunter and a fight id on every defeat

The defeat `m` rows (messages 6, 20, 97) gain two columns at the end: `th`, the Treasure Hunter level the
party had on that mob when it died (read from messages 603 and 608 in the whole party's actions, not only
yours; empty when none was seen), and `fight`, an id `<first party hit time>.<mob id>`. The pool drop row
(`pd`) of the same mob carries the same `fight`, so a drop joins its kill by id instead of a time window
(on 2026-10-16, 894 of 2,942 chat drop rows had no same-name kill within 10 s and 501 more were ambiguous).
Rows from older versions have 10 columns and decode with both empty.

## 1.1.0: the treasure pool, decoded

Incoming 0x0D2 (an item appears in the pool) and 0x0D3 (a lot, or the item leaves the pool) are written
as three more row kinds, so drop rates no longer depend on matching chat lines by item name:

```
pd  t  ms  slot  item_id  count  dropper_id  dropper_name  old
pl  t  ms  slot  lotter_id  lotter_name  lot  top_id  top_name  top_lot
pe  t  ms  slot  item_id  age_s  result  winner_id  winner_name  winner_lot
```

`slot` is the pool slot and joins the three. `dropper_id` is the mob's id, the same id the `m` defeat
rows carry. `old` = 1 means the item was already in the pool when you joined, so its drop time is not
known. `lot` 65535 is a pass. `result` is the packet's Drop byte: 1 = given to a player, 3 = floored
(nobody took it). `age_s` is measured from the `pd` row, so the real pool timer can be read from the data
(harness packet captures of 2026-10-12..15 showed about 300 s). Readers that do not know these kinds skip
them; the atlas combat-log reader needs to accept `pd`, `pl` and `pe` before it ingests files from 1.1.0.

## 1.0.0: the shared schema, contributor id and test markers

combatlog now writes **version 1 of ffxi-atlas's combat log schema** (`docs/COMBAT-LOG-SCHEMA.md` in
ffxi-atlas, which owns the standard; `python -m store.combatlog_schema <files>` there checks a file).
Everything below still holds; files from 0.2-0.9 are "version 0" and stay valid. What is new:

- **A header row** (`h`) first whenever the day's file is opened (a load, a new day, a login): schema
  version, addon version, character, client and a **contributor id**.
- **The contributor id** is random, made once and kept in `data/contributor.txt`, shared by every
  character on this install. It is never the character name: it lets pooled data from many players be
  told apart without naming anyone. `//cbt status` shows it.
- **Augments** of the worn items, in a `gear_aug` context key (`<slot 1-16>:<augment>|...;...`), decoded
  with Windower's extdata library as rema does. Item ids alone could not tell two capes apart.
- **Test markers:** `//cbt test A new feet` writes `x ... test=A event=start note=new feet`, and
  `//cbt test end` (or starting another test) writes its end. ffxi-atlas `python -m validate.experiment
  --a test:A --b test:B` compares the two with confidence intervals. How to design the test is ffxi-atlas
  `docs/METHODOLOGY.md`.

## 0.9.0: SCH and RUN

- **Magic (SCH):** the `magic` line shows the average nuke, n and the magic-burst rate (message
  252), then the last spell with its own average and burst rate. Each of your spells now gets a
  `phase=spell_result` context row with the gear on as it lands (GearSwap's midcast set), so
  ffxi-atlas `python -m validate.combat_jobs magic` can compare nuking sets. Before 0.9.0 a nuke
  was filed under a context up to 10 s old, usually the idle set.
- **Damage taken (RUN):** what enemies do to you is counted in memory, with nothing switched on.
  The damage view ends with a `TAKEN` line; `//cbt view taken` puts it first:

```
TAKEN 312/s  14,020 in 44 hits  x1.3 the party on shared hits (n=12)
  melee 38%  abilities/spells 62%   enemy melee hit you 71% (n=31)
  biggest 1,210 from Triboulex (Feast of Arrows)
  most from Triboulex: 11,900 (85%)
```

  "x1.3 the party" compares your damage with the party's median on attacks that hit you and
  party members together. Recording those hits to the file still needs `//cbt incoming`; then
  `python -m validate.combat_jobs taken` in ffxi-atlas groups them by monster family.

## The box: "how much damage am I doing?" (0.7.0)

A live readout kept in memory from the same packets the recorder reads -- it works with recording
paused, and `//cbt reset` starts it again. `//cbt view` picks the layout:

- **`damage`** (default) answers the question, then takes the answer apart:

```
CombatLog  <character>  REC 1,234 rows
DAMAGE 5,238/s  now 6,010/s (+15%)  58% of party     the answer: per second of fighting
  ws      3,951/s  75%  43,159 avg x every 11s        = average WS x how often you WS
        last Upheaval 27,002 @2450 TP  (its avg 23,341, n=14)
  melee     972/s  19%  1,228/hit x 1.71 swings/round, every 1.7s
        98.7% hit  38.9% crit  n=552  286 TP/round
  sc        301/s   6%  18,819 avg  n=11  last Light 34,647
FIGHT  Locus Dire Bat  0:41  62%  ~1:07 left
  you 48,210  1,176/s  41% of party  mob ~115k HP
SESSION 3.60M in 11:28 fighting  12 kills  0:40 avg
  aftermath 98% of engaged time (AM3 94%)
missing: Signet
```

- **`short`**: the DAMAGE and FIGHT headlines only.
- **`diag`**: the 0.6.0 flat list, every raw figure on its own line, plus the inputs of the
  estimates (party damage on the mob, the HP% it was first seen at, the last-60 s rate).

Why it is laid out this way -- damage per second is hard to state honestly in FFXI:

- **Bursty damage.** One WS or skillchain is worth dozens of swings, so a rate needs time behind it.
  `now` is the last 60 s of *fighting*, beside the session rate as its baseline; it is coloured
  when it is 10% above or below.
- **Downtime is not damage.** Gaps of more than 10 s without your damage are not counted, so
  walking between pulls does not drag the rate down.
- **The levers, not just the total.** Each source is a rate and a share, largest first, and the big
  ones are broken into what gear changes: WS = average x frequency (WSD / PDL / Store TP), melee =
  damage per hit x swings per round / round time (multi-attack, Haste). Skillchains are the WS's
  additional effect (288-302, 767, 768), never added to the WS.
- **Mobs differ.** "Of party" is your share of what your party, trusts and pets did to enemies
  (their damage is counted in memory only; the recorder still does not write their melee).
  `mob ~HP` is party damage / HP% lost -- an estimate (outside damage is missed, overkill counted),
  shown once it has lost 10%, and remembered per mob name from each kill.
- **Rates keep their n.** Crit is message 67 (melee) / 353 (ranged), confirmed from your own rows.

Replaying a real day through it: `luajit addons/combatlog/test_live.lua <combat file> <Character>` (your
rows only; party melee is not in the files, so no share).

## Damage taken and whether the WS set landed (0.8.0)

For "am I short on DT?" and "did GearSwap actually put my WS set on?" (2026-09-28, after a Sortie
death). Needs incoming recording on (`//cbt incoming`).

- **Earrings and rings are recorded.** Before 0.8.0 every row had 0 in the ear1, ear2, ring1 and
  ring2 columns: `get_items('equipment')` calls those slots `left_ear` / `right_ear` / `left_ring` /
  `right_ring` (GearSwap `statics.lua`), and this addon asked for `ear1`. Column names are unchanged.
- **Every context row has `hp` and `max_hp`**, not only the rounded `hpp`.
- **A hit taken gets its own context row** (`phase=hit`, `hit_by=<enemy id>`): gear, `gear_sent`,
  hp, max_hp and buffs at the moment an enemy's action that includes you arrives, and the action's
  rows point at it. Before, a hit inside a one-second WS set was filed under the last 10 s snapshot.
- **When your WS lands, a `phase=ws_result` row** records `gear` as the client shows it then, with
  `ws_ctx=<id>` pointing at the WS's own context. `gear` moves only when the server confirms an equip,
  so a slot where `gear_sent` (what GearSwap asked for) differs from it is a swap that did not happen.

ffxi-atlas reads these: `python -m validate.damage_taken --character <Character>` (each hit, DT worn,
against what the party took from the same attack) and `python -m validate.ws_swaps --character
<Character>` (how often the WS set was missing a piece, by weapon skill and slot).

## What it writes

Three row kinds, tab separated, kind in the first column (`m`, action messages, added in 0.4.0 -- below), plus `h` and `x` from 1.0.0 (above):

```
c  t  id   k=v ...                                    context: job, level, zone, gear, buffs, stats, tp
a  t  ctx  category  ability  target_id  target_name  message  amount
   actor_id  actor_name  reaction  add_msg  add_amount             <- added in 0.2.0
   round  ms  tp                                                   <- added in 0.3.0
```

**Rounds (0.3.0) — for Store TP vs Double Attack vs Haste.** The game sends each attack round as one
packet; every row from it shares a `round` number, so swings per round (multi-attack) is a count.
`ms` is milliseconds since that game client started, for the gap between rounds (Haste); it is only
comparable within one character's file. `tp` is your TP when the round arrived; whether that round's
TP is already applied at that moment is not known, but the rise from one round to the next is the TP
per round either way (Store TP). `//cbt summary` shows swings per round (1/2/3/4+), the median gap
between rounds and the median TP per round. Measuring the gap directly avoids modelling the haste
caps: if more haste stops shortening it, you are capped.

**Who acted (0.2.0).** Every action row says who did it. Before 0.2.0 it didn't, and with
`//cbt incoming` on, a mob's swings at you, another player's rolls and a trust's cures were written
exactly like your own actions. Rows from before 0.2.0 have no actor; `//cbt summary` leaves them out
and says how many. The new columns are appended, so anything reading the first nine still works.

**The party's actions on enemies (0.4.0).** Weapon skills, spells, job abilities, pet abilities and
dances by your party, trusts and their pets are recorded where they land on an enemy: that shows who
opened each skillchain you closed, and which debuffs (Dia, Angon, Frailty, …) were on the mob.
Their melee is not recorded, and neither are buffs on players. Also new, a third row kind:

```
m  t  ms  actor_id  actor_name  target_id  target_name  message  param1  param2
```

action messages about enemies: **defeats** (6, 20, 97; time to kill = first hit to defeat) and
**debuffs wearing off** (64, 204, 206, 350, 531; `param1` is the status id). Readers that only know
`a` and `c` rows skip them.

**Skillchains are kept apart.** `add_msg` / `add_amount` hold the additional effect: on a weapon
skill that is the skillchain. `amount` is the weapon skill alone.

**Weapon skills get their own context, taken when the WS is sent.** For questions like Physical
Damage Limit vs Weapon Skill Damage gear, the damage has to be matched to the gear actually worn
for the WS, the TP spent, the buffs up (attack from other people's rolls and songs decides whether
PDL is worth anything) and the target. None of that can be read when the result arrives: by then
GearSwap has swapped your TP set back and your TP is gone. So when your WS packet goes out, a
context row is written with `phase=ws`, `ws=<id>`, `ws_target=<id>`, `tp`, `buffs`, and two views of
the gear:

- `gear` — what the client shows as equipped;
- `gear_sent` — what your client has just *sent* equip packets for (`0x050` / `0x051`, which is how
  GearSwap swaps). The client's own view only updates when the server confirms, so at that instant
  it may still show the TP set. Both are recorded so the data can show whether they ever differ.

The WS result row points at that context.

**Other context is written when it changes, not on every swing.** A busy hour is thousands of action
rows; repeating the gear set on each one would make the file unusable. Action rows carry the id of
the context in force. Trade-off worth knowing: context is re-snapshotted at most every
`context_secs` (default 10), so for ordinary swings gear and buffs are accurate to within that
window. Only job and zone changes force an immediate snapshot; gear changes do not.

**The gear recorded is what you were actually wearing**, read from the game — not the GearSwap rule
that was supposed to fire. Those differ, and that difference is one of the things this data exists
to expose.

## It records facts, not conclusions

Same rule as `ffxibazaar`: the addon writes mechanical facts, and attribution and analysis happen at
ingest in `ffxi-atlas`, where they can be re-run and corrected. Concretely, **this addon does not
decide what a critical hit is.** It writes the raw message id and amount, and `//cbt summary` groups
by message id with the damage distribution:

```
by message id (this is how the crit id gets identified):
      1 hit       n=2103   avg    118.4  min 61  max 205
     67 hit       n=486    avg    241.7  min 130 max 402
     15 miss      n=298    avg      0.0  min 0   max 0
```

An id whose mean damage sits well above another's, on the same ability, is your critical-hit id —
established from your own rows. That is the intended first use of the summary.

## Evidence

Nothing here is written from memory, per AGENTS.md:

- `windower.packets.parse_action(data)` on incoming `0x028`, and the `act.targets[i].actions[j]`
  shape, are taken from working Windower code: `cyritegamestudios/trust` v17.7.1,
  `cylibs/Cylibs-Windower-Events.lua` and `cylibs/battle/buff_tracker.lua`, read 2026-09-17.
- The equipped-set read (`windower.ffxi.get_items('equipment')` then
  `get_items(item[slot..'_bag'], item[slot]).id`) is from the same source,
  `cylibs/util/inventory_util.lua`.
- The hit / miss / weapon-skill / defeated message id lists in `rows.lua` are from that repo's
  `cylibs/util/action_message_util.lua`. They are used **only to label the summary**; every raw id
  is kept in the rows either way, so a wrong or incomplete list costs nothing.
- Anything not confirmed is **discovered**: `//cbt fields` prints every key seen on the parsed
  action tables, which is how the row format gets extended from evidence rather than a guess.

## Numbers come with n

`//cbt summary` reports hit rate as a Wilson 95% interval, e.g. `80.0% (95% CI 72.2-86.0, n=125)`.
This is deliberate. 8 hits out of 10 and 800 out of 1000 are the same rate and completely different
evidence, and a gear change made on the first is a change made on noise. Any UI built on this data
should keep showing n. IDEAS #22 has the sample-size discussion.

## Why run it with Trust

Trust (IDEAS #5) repeats the same rotation on the same mobs for hours. That is experimental control,
and it is what makes an A/B gear comparison valid: swap one piece, let it run, compare. The recorder
does not depend on Trust and never will — it is deliberately standalone so it stays read-only and
shareable — but Trust is the cleanest way to generate comparable data.

## Tests

```
lua5.1 addons/combatlog/test_rows.lua     # from the repo root
```

Checks on row encoding, the summary, and the confidence interval, no game needed.
`luajit addons/combatlog/test_live.lua [file Char]` tests the box's totals and can replay a real day. The in-game
reload is still the test for `combatlog.lua`.

## First run

1. Load it. `//cbt status` should say RECORDING and name today's file.
2. Fight something. The box counts rows.
3. `//cbt fields` — confirm what the parsed action actually carries, and tell me: that output is
   what decides which columns get added next.
4. `//cbt summary` — check the message ids look sane and find the crit candidate.
5. Then leave it running. This data cannot be backfilled.

## Expected buffs and region buffs

`//cbt expect` lists buffs to warn about while you are engaged, per character. The default is
`region`: Signet / Sanction / Sigil / Ionis.

Those four compete: each overwrites the others, and each is zone-dependent. You can wear one in any
zone, but it only does anything in its home zones, so wearing the wrong one is an opportunity cost,
not an error the game reports. Which zone belongs to which is not in Windower's resources, and it
cannot be read off the data either (seeing Signet up in a zone proves nothing -- you may have carried
it in), so it is not guessed:

- **An undeclared zone** warns only when **none** of the four is up -- you forgot it entirely.
- **`//cbt region Ionis`** (Signet / Sanction / Sigil / Ionis) declares the zone you are standing in,
  shared by both characters in `data/shared/region_zones.txt`. There it warns when the right one is
  missing, and names a wrong one being worn: `missing: Ionis (have Signet, no effect here)`.
- **`//cbt region none`** marks a zone where none apply; it stays quiet there. `//cbt region` alone
  shows the current zone's setting.

Every context row records the zone and all buffs, so the combat numbers can still show the
difference afterwards. A sourced zone -> region table would replace the declarations: IDEAS #30.
