# Credits

This project stands on other people's work. Thank you to all of them.

## Windower

Everything here runs on [Windower 4](https://www.windower.net/): its Lua addon API, its libraries (`config`, `texts`, `packets`, `resources`
and the rest) and its game resource tables (`res/`) are used throughout. Several addons here were started from, or take their layout from,
addons in the Windower addon collection.

## Other authors' work

Other authors' add-ons are linked from the README, not shipped. The little third-party material that is inside this package is listed in [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md).

## Data and images

- **BG Wiki:** no text or tables from it ship in this package. Final Fantasy XI is a trademark of Square Enix.
- **Boxtheme textures:** generated from original gradients and shapes by `tools/make-boxtheme-art.lua`. The PNGs contain no game screenshots.
- **XIchecklist** (HiPotion): nothing from it ships in this package. Its handlers were once read to learn which login packets exist; Charsync's packet list now follows Windower's packets library instead.
- **RollTracker** (Thomas Rogers): the roll value table in `addons/buffbox/rolls.lua`, BSD 3-clause, notice kept in the file; see THIRD-PARTY-NOTICES.md.
- **Game data**: item, spell, zone and key item names come from Windower's resource tables as installed.

## This project

Written by ImpactLogic, with help from Claude (Anthropic) as a coding assistant. Final licence: see [LICENSE](LICENSE).
