# buffbox 0.10.0

A box listing your buffs with time left, what your food gives, Corsair roll values, which Bard song you have
with its potency range, and (from a cited table) what fixed buffs give, a low-time warning and a buff history. **Read-only**: it only reads packets
and resources, nothing is sent. Load with `//lua l buffbox`.

```
//bb                 your food and its effects, in chat (same as //bb food)
//bb box [on|off]    show/hide the box (saved as show_box)
//bb layout [full|compact]  grouped with details, or one line per buff with time bars
//bb pet [on|off]    also show the food's "Pet:" lines (off by default)
//bb history [n]     last n (default 10) buffs gained/lost, with how long each lasted
//bb history on|off  keep data/<Character>/history.tsv (on by default)
//bb warn [secs|on|off]  chat warning before a long buff wears off (default 60 s; on = 60)
//bb capture [on|off]  log raw buff-timer rows, item uses, songs and stat changes
//bb help | version
```

```
buffbox  <character>  6 buffs
FOOD
 Grape Daifuku                 28:14
    HP+20 STR+2 VIT+3
    Acc.+10% (Max. 80)
    Atk.+10% (Max. 50)
    measured Atk +52  Def +4  HP +20  STR +2  VIT +3
SONGS  from Shouto
 Valor Minuet V                 2:41
    Attack & Ranged Attack 124-223 at +0..+8
ROLLS
 Chaos Roll                     4:31
    11 (lucky): 31.25% (320/1024) Attack
REGION
 Ionis                       2:51:07
OTHER
 Haste                          1:52
 Protect                          --
```

Layout: buffs are grouped as Food, Songs, Rolls,
Region, Other under gold headings; details are dimmed; what your own stats showed when the buff landed is in
blue (`measured`). `//bb layout compact` draws one line per buff with a draining time bar under it (green
food, blue songs, purple rolls, amber in the last minute) and only the measured lines. The background is the
shared boxtheme panel (`addons/boxtheme`, `//boxtheme`).

Where each part comes from:
- **Buff list:** `get_player().buffs`. Food is buff 251 "Food" (`res/buffs.lua`).
- **Time left:** incoming `0x063` order 9, `Buffs u16[32]` at 0x08 and `Time u32[32]` at 0x48
  (`libs/packets/fields.lua`). The server sends it when your buffs change, so after a reload the box shows
  `--` until the next change. The end time uses fields.lua's formula, choosing the 2^32/60 wrap nearest now
  instead of its hard-coded 10.
- **Which food:** your own item-use action (category 5, param = item id) within 15 s before the Food
  buff appears. Saved to `data/<Character>/food.txt` so a zone or reload keeps it; a saved meal older than
  4 h is ignored. Food eaten while buffbox was not loaded shows as `Food (item not seen)`.
- **Food effects:** the item's description in `res/item_descriptions.lua`, from the first stat line on,
  exactly as the game words it. Percentages show as the game states them (`+15% (Max. 72)`): the real
  number depends on your own stats, which the client does not provide.
- **Roll values:** a Corsair roll (or Double-Up) that lands on you is a category-6 action: `param` is the
  roll's job ability, the target's `param` the roll number. Values come from RollTracker 1.8.1.1's table
  (`rolls.lua`, BSD notice kept; its own comments mark which rows it confirmed). Base values only: no gear or job bonus.
  A wiki-derived table that used to take priority was removed (0.10.0); a few roll values may differ from it.
- **Fixed-buff effects:** `effects.lua` is empty (0.10.0): its entries were summaries of wiki pages and no
  wiki-derived content ships. Add an entry only with its own evidence (what the game shows, with the date).
- **Region check:** with an optional `zones_wiki.lua` table (**none ships**, 0.10.0), holding Signet / Sanction / Sigil /
  Ionis in a zone where it does nothing puts a red `No effect here (Sigil area)` under it and one chat line when you
  zone in. Without the table the box says nothing.
- **Ionis, exactly:** ask each coalition's Civil Registrar in Adoulin, menu option "The State of the
  <name> Coalition" (edification is optional). buffbox reads the answer from chat, saves it to `data/<Character>/coalitions.tsv`, and
  shows the effects the Registrar listed under Ionis, one line per coalition, with the date checked.
  `//bb ionis` lists them in full, with a number where an optional `ionis_wiki.lua` table (none ships) has one.
  Re-check after a coalition evaluation: a rank drop can lose an effect.
- **Songs:** the buff only says `Minuet`. The cast that lands on you (category-4 action, a `BardSong` in
  `res/spells.lua`, target message 230 or 266 "gains the effect of", target `param` = buff id) names the song
  and the bard. Under the buff: the song and the bard; with an optional `songs_wiki.lua` table (**none ships**, 0.10.0)
  also each stat as a range over the +song columns. Two copies of
  one buff (two Minuets) are paired by age: the newest cast goes with the copy that ends last (inferred).
  Songs that landed before buffbox loaded show only the name and time.
- **Stat recorder:** each incoming `0x061` (Max HP/MP, base and added
  STR..CHR, Attack, Defense, elemental resistances; offsets from `libs/packets/fields.lua`) is written to
  `data/<Character>/stats.log` as a diff against the last one (`stats: Atk 1200>1386(+186)`, or `same`), with
  the `gain:` / `lose:` / `song:` lines around it, `slots:` (your buffs in the server's slot order, when it
  changes) and `zone:` lines, so a buff's change in your stats can be matched to it later.
  Over 1 MiB it moves to `stats.old.log`. Off with `//bb capture off`.
- **Spell tiers (0.9.0):** any spell that lands on you (category-4 action, target message 230 / 266 / 237) names
  its exact tier and caster, shown under the buff: `Protect V (Name)`. With an optional `spells_wiki.lua` table
  (none ships, 0.10.0) its base value is added. Base only: the caster's gear and merits are not sent.
- **Measured from a later packet (0.9.0):** the server resends your stats when you do something yourself (food,
  an ability, a gear change) but not when someone else's buff lands (stats.log, three nights: Minuet 0 of 13,
  Protect 0 of 6, Food 7 of 7). So each stats packet is compared with the previous one, or, when gear moved,
  with the newest earlier packet in the same gear (same added STR..CHR, max HP and MP; up to 15 min back), and
  the change is given to every buff gained in between. One buff: its own number. Several: `(sum of 3 buffs)`.
  A buff lost in between cancels it. Expect corrections as data comes in.
- **Measured (the 3 s rule it replaced):** when your stats change (0x061) and exactly one buff was gained and none lost within 3 s
  either side, the change goes under that buff: Food, the song that just landed, or any other buff. Game test
  2026-09-28: Grape Daifuku read back as its item text (Atk +52 = its 10% capped at 50, plus STR). Gear swaps
  change stats too: since 0.8.2 an equip packet (incoming 0x050, outgoing 0x050/0x051) in the window cancels
  the reading (logged as `gear:`). Each reading is logged as `measured:` in stats.log.
- **Other buffs' potency** (Haste, Protect): not sent by the game, so only name and time are shown.
- **Buff history:** Windower's `gain buff` / `lose buff` events, written to
  `data/<Character>/history.tsv` (time, `+`/`-`, buff id, name, food eaten or how long it lasted).
  A buff that was up before buffbox loaded gets a blank duration. Over 512 KiB it moves to
  `history.old.tsv`.
- **Low-time warning:** once per buff, in chat and the log, `warn_secs` (60) before it ends; the box
  draws those lines red with `!`. Only buffs with 10+ minutes when first timed warn (`warn_min_minutes`),
  plus Food always, so songs and rolls do not flood chat. A refresh arms the warning again.

Verified in game 2026-09-27 (Grape Daifuku, Ionis): empty timer slots are 255, category-5 `param` is
the item id (6343), Food read exactly 30:00, Ionis exactly 3:00:00, and zoning did not drop the Food buff.
Zoning out sends one 0x063 row with all 32 slots 0; it is ignored and the last timers kept. Timers read
~12 s long after that zone (not yet explained). +1 foods are separate items (Grape Daifuku +1 = 6344)
with their own description, so the box shows the +1 stats. Not yet verified: roll actions (logged as
`roll:`), history and warnings, songs (logged as `song:`).

Offline tests: `luajit tools/test-buffbox.lua` (205 checks). Log: `buffbox/data/buffbox.log` (capped 256 KiB).
