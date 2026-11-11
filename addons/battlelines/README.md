# Battle Lines

A combat meter for FFXI (ideas #66, #67). **Read-only**: it reads the action packets the client already
receives and sends nothing (except `//bl report <channel>`, which types one chat line when you ask for it).

```
//bl box [on|off]                     show or hide the meter
//bl view damage|taken|healing|deaths|enmity which tab (or click the tab row)
//bl options                          open the clickable Options tab
//bl mix [on|off]                     show WS / Skillchain / Other under each Damage bar (default off)
//bl stat total|rate|share|events|average|max|crits|bursts  choose the bar ranking (available stats depend on view)
//bl rate fight|burst                 choose whole-fight or action-window rate (fight is the new-install default)
//bl mode current|overall|last|<n>    which fight: the running one, everything since reset, the last finished one, or the n-th previous
//bl next                             cycle the fight (same as right-clicking the box)
//bl dps effective|fight              older command, kept as an alias for rate burst|fight
//bl rows <n>                         bars shown (default 8)
//bl idle <seconds>                   a fight ends after this long without activity (default 10)
//bl save [on|off]                    append each finished fight to data/fights.tsv (default on)
//bl coefficient <0..2>               Enmity tab: CE per damage point (default 0)
//bl enmity damage [on|off]           Enmity tab: include the rough damage estimate (default on)
//bl snap                            save the running fight (or overall) to fights.tsv now, to picture it before it ends
//bl reset                            clear all fights
//bl report [say|party|ls]            top five of the current view as one line; no channel = your own chat only
//bl player <name>  //bl back        ability breakdown for one player / back to the bars
```

What you see: a themed box (boxtheme title bar, lock, drag handle). Line 1 is the fight, its length and the view total;
line 2 has clickable `[Damage] [Taken] [Healing] [Deaths] [Options]` buttons, with `*` marking the selected tab. A
heading identifies the rate basis or selected primary stat. Bars show rank, player, amount, rate and share. A positive
share under half a percent reads `<1%`. Your bar is gold; taken is red, healing is green. Options lets you click the
rate basis or choose a primary stat button for the current view; the latter sets bar order and length. Each view remembers
its own stat. Deaths remains a list of events.

On the Damage tab, **Damage mix** in Options adds one short line under each player's bar: weapon skill (WS),
skillchain (SC), and other damage, with each amount's share of that player's total. The main DPS bars keep their
usual totals and order. Click either line to open the player detail, where the same summary appears above individual
abilities. Skillchain damage is attributed to the player who closed it; pet abilities are part of Other.

- **Left-click a tab** to switch the view. **Left-click a bar** for that player's abilities (melee, each WS, spell with
  magic bursts, JA, pet abilities, skillchains, added effects; for *taken* each source and the move it used; for
  *healing* each spell or ability): total, share, uses, average. **Click a death** for the last hits before it.
  Click anywhere in a breakdown to go back.
- **Right-click** the box to cycle the fight: current, last, 2, 3, ... , overall. (If right-click does nothing on
  your setup, `//bl next` does the same.)
- Views: **Damage** done, **Taken** (enemy hits on party members), **Healing** (cures, abilities; the game reports the
  amount restored, overcure is not exposed), **Deaths** (who, how far into the fight, killed by, last eight hits).

How fights and rates are counted:
- A fight starts at the first party damage on an enemy (or the first enemy hit on the party) and ends after `idle`
  seconds without activity; the last 10 are kept. Healing and deaths only count inside a fight.
- New installations use the whole fight for rates. Burst rate divides by each player's action window (gaps over
  `idle` are downtime). Existing saved rate preferences are respected.
- Party, alliance and trusts by mob id; a pet's damage and healing go to its owner (its ability rows say `Pet:`).

Saved fights: `data/fights.tsv`, one line per player per view per ability (time, fight, mob, seconds, view, player,
ability, total, uses), rolled to `fights.old.tsv` past 1 MB. It is for later analysis (atlas), not read by the addon.

Pictures: on the PC run `python tools/battlelines_snap.py` (add `--open` to see the gallery). Per fight it writes
`data/snapshots/<date>_<time>_<mob>.png` (the card: damage, taken, healing bars, ready to post) and `.html` (the full
report with every player's abilities, click to expand), plus an `index.html` gallery. PNGs come from headless Edge or
Chrome; with neither it writes the HTML only. `--last N` redraws the newest N, `--all` everything. Rates there are
amount / fight length (the file has no per-player active time); deaths are not saved.

Limits: only actions the client receives are seen (out of range or another zone is missing); the game exposes only
mob HP%, so there is no "damage vs HP". Planned: an enmity view.

Files: `core.lua` (engine, pure Lua), `battlelines.lua` (Windower side). Offline tests: `luajit tools/test-battlelines.lua`
(engine, 83 checks) and `luajit tools/test-battlelines-glue.lua` (the addon with a mocked Windower, 43 checks).
Message ids and the party lookup come from `combatlog/live.lua`; the idea of a flat party meter is Suji's scoreboard
(`forks/scoreboard`, BSD).

The former `//det` command remains available as a compatibility alias. Existing settings and saved fights are copied to the Battle Lines data folder during the rename.
If `details` is still loaded in the current game session, switch with `//lua u details` and `//lua l battlelines`.
The startup script loads `battlelines` on the next game launch.

## Enmity tab (0.7.0)

A fifth tab, `[Enmity]`, replaces the separate Enmity Lines box. For the enemy you have targeted (or the latest active one) it
shows each party member's **modelled** cumulative (CE) and volatile (VE) enmity and the enemy's last observed target, plus the
last three observed target switches. Damage-based estimation starts off. Set a coefficient with
`//bl coefficient <0..2>` and enable it with `//bl enmity damage on` if you want to experiment.
**These are estimates, not the game's hate list**: cures, buffs, resets, damage-taken loss, enemy level and gear enmity are not modelled,
and the "Unmodelled" count shows how many actions were seen but not scored. The model lives in `enmity_model.lua` (a copy of
`enmitylines/enmitycore.lua` plus the switch list). Evidence for calibration is still recorded by the `enmity` addon.
