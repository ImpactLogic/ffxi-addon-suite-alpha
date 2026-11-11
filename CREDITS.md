# Credits

This project stands on other people's work. Thank you to all of them.

## Windower

Everything here runs on [Windower 4](https://www.windower.net/): its Lua addon API, its libraries (`config`, `texts`, `packets`, `resources`
and the rest) and its game resource tables (`res/`) are used throughout. Several addons here were started from, or take their layout from,
addons in the Windower addon collection.

## Authors of the addons we forked

The forks keep their authors' copyright notices and licences. Who wrote what, under which licence, and from where it came is listed in
[THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md) (generated from each fork's `UPSTREAM.md`). Our changes are marked in the code.

## Data and images

- **BG Wiki:** the release omits walkthrough text and the earlier derived lookup tables. Final Fantasy XI is a trademark of Square Enix.
- **Boxtheme textures:** generated from original gradients and shapes by `tools/make-boxtheme-art.lua`. The PNGs contain no game screenshots.
- **XIchecklist** (HiPotion): its story map is the source of the id tables Story Guide uses to read where a character is in a storyline. The tables are
  generated locally and not shipped. Its author describes it as free to use, share and edit ("free to use/share/edit/anything"); that is an informal statement, not a licence file, so it is credited here.
- **Game data**: item, spell, zone and key item names come from Windower's resource tables as installed.

## This project

Written by ImpactLogic, with help from Claude (Anthropic) as a coding assistant. Final licence: see [LICENSE](LICENSE).
