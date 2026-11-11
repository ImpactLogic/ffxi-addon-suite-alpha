# timers 0.1.5

Ability and spell recasts as a themed box with a time bar under each row. **Read-only**: it asks Windower
for recasts and sends nothing. Replaces the closed-source `Timers.dll` plugin for recasts; buff timers stay in
`buffbox`. The box hides itself when nothing is recasting, except on Scholar: a Stratagems charge row stays visible
at full charges.

```
//tm box [on|off]             show or hide the box
//tm abilities [on|off]       job ability recasts
//tm spells [on|off]          spell recasts
//tm bars [on|off]            the time bars
//tm rows <n>                 most rows shown (default 10)
```

The Scholar row shows available/max charges and the countdown to the next charge (or `ready` when full). It stays
at the top even when the row limit is reached. It uses shared ability recast ID 231; ID 233 is the Stratagems menu
and is not another charge. Five charges recover every 48 seconds at level 90+, or every 33 seconds after the
550-JP gift; lower levels use 240 seconds divided by the number of charges. The `abilities` switch also controls
this row. Other rows are sorted by time left; blue bars are abilities, gold bars are spells. Themed by `boxtheme`.

BuffBox shows the active Stratagem effects (such as Perpetuance) only while they are on the character; casting
the next spell consumes them. It does not show the persistent charge pool.

Not verified in game: the spell recast unit. Windower returns raw ticks, and GearSwap divides by 60, which this
assumes (`SPELL_DIV` in `timercore.lua`). The first raw value of each recast is logged to `data/timers.log`;
cast one spell and compare its countdown with the game's to confirm. Ability recasts are in seconds.

Offline tests: `luajit tools/test-timers.lua` (35 checks). The new charge calculation is not yet verified in game;
compare the count and next-charge countdown with the Scholar ability menu after `//lua r timers`.
