# checkup

**Read-only.** Checkup loads the other add-ons for you (`//setup`), says which facts they hold are missing
or old, and owns the `//rec` switch for the recorders. To have it load every time you start the game, add
the line `lua load checkup` to `Windower4/scripts/init.txt`.

```
//setup                short list of modules and what to do next
//setup tick story     tick a module (loads what it needs); untick <id> hides its boxes
//setup apply          load everything that is ticked
//setup skip           close the first-run hint without changing anything
//rec status           which recorders are installed and whether recording is on
//rec on combatlog     turn one recorder on (it must be loaded: //lua l combatlog)
//rec off              turn every recorder off
//checkup todo         only what needs doing
//checkup full         everything: setup facts, recorders, recent errors, installed versions
//checkup depart       free bag slots and what still needs doing before you leave
//checkup addons       the add-ons in this package and their versions
//checkup box [on|off] the "todo" list in a box
//checkup version
```

It reads the files in the Windower addons folder and nothing else. A check is skipped when the add-on it
depends on is not installed.

| Check | File read | Old after | What to do |
|---|---|---|---|
| Ionis coalitions | `buffbox/data/<Char>/coalitions.tsv` | 14 days | ask the six Civil Registrars in Adoulin "The State of the <name> Coalition" (endgame only; ignore it otherwise) |
| Merits and job points | `charsync/data/<Char>/points.tsv` | 7 days | load charsync; it saves on load |
| Currencies | `charsync/data/<Char>/currencies.tsv` | 7 days | open the Currencies menu, both pages |
| REMA weapons | `charsync/data/<Char>/rema.tsv` | 7 days | `//charsync` |
| Combat recorder | `combatlog/data/<Char>/combat-<day>.tsv` | not today | only matters if you turned recording on |
| Errors | `<addon>/data/<addon>.log` | an ERROR in the last 7 days | read that log |

All of these are optional. After login it prints one line saying how many setup items are open, 30 seconds in
(`on_login` in settings). It cannot tell whether an add-on is loaded: a combat recorder with no file today
may just not have fought yet. Log: `data/checkup.log`.

## //setup: modules ticked like check boxes

`//setup` lists the modules as `[x]`/`[ ]`: **Story** (Story Guide, Charsync, Bags, Timers, Buffbox) and
**Gear and character** (Charsync, Bags). `//setup tick story`, `//setup untick gear`, `//setup preset new`,
`//setup apply`, `//setup skip`. A part shared by several ticked modules loads once, and unticking only hides
boxes no other ticked module needs. Nothing is ever unloaded, and recording is never a module: it stays under
`//rec`. Ticked modules are re-applied 30 seconds after login (`setup_apply_on_login` in settings), which is
why Checkup itself should load at login. Loading an add-on that is already loaded may reload it.

Charsync is always on in setup: it saves a local snapshot of your character, and every module reads from it.
`//setup` only lists modules whose add-ons are installed, so a missing folder shows up as a missing module.

`//checkup depart` is a read-only departure check for the character you are on: zone, free slots in
Inventory, Satchel, Sack and Case (LOW below `depart_low`, default 5; FULL at zero; a bag the client cannot
read is "unknown", never ok), any setup facts that need doing, and your own `depart_manual` reminders
(settings.xml, free text) printed as CHECK yourself. It does not check supplies.
