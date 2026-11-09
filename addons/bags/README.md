# bags 0.2.1

New opt-in layouts: `//bags layout compact|detailed`. Inventory comes first, followed by selected bags
ordered by fullness, with free slots, used/capacity and labeled native row fills. Unknown counts and
not-enabled metadata stay explicit. These layouts list wardrobes individually; legacy modes retain
the existing aggregation. Existing saved layout, theme, position and font settings are preserved.
Use `//bags pos <x> <y>` and `//bags size <6-40>` for placement and size.

How full each bag is, as bubbles (`[#######---]`), numbers (`68/80`) or both. **Read-only**: it asks Windower
for bag sizes and sends nothing. Replaces the third-party `invtracker`; moving items stays with `stash`.
Themed by `boxtheme` when that is installed.

```
//bags box [on|off]              show or hide the box
//bags mode bubbles|numbers|both
//bags numbers frac|free         68/80  or  12 free
//bags wardrobes sum|each        one Wardrobes line, or one per wardrobe
//bags show|hide <bag>           inventory satchel sack case wardrobe safe safe2 storage locker
//bags warn <n>                  chat warning when Inventory has n or fewer free (0 = off, default 5)
```

Default bags: Inventory, Satchel, Sack, Case, Wardrobes. Mog House bags report only while you are there, so
they are off until you `show` them. Colour: green, amber from 80% full, red from 95% (`warn`, `crit` in settings).

Default mode is numbers (`//bags mode bubbles|both` for the pips).

Offline tests: `lua5.1 tools/test-bags.lua` (25 checks). Not yet tested in game: whether `get_bag_info` counts
for wardrobes 3-8 match the client, and how `\cs` colours look with the theme.
