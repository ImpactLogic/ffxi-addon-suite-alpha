# boxtheme 0.5.8

Themed backgrounds for every box our addons draw: the eight in-game Window Types, plus a
Vana'diel menu look, a compact HUD, black and smoked glass. **Read-only in game.** It stores themes, locks, screen placement and recording preferences in its local `data/` folder. Load with `//lua l boxtheme` when you want to change a theme; the boxes do not need it
loaded to draw their background.

```
//boxtheme                      list the themes and which box uses which
//boxtheme <theme>              every box without a theme of its own
//boxtheme <addon> <theme>      one box, e.g. //boxtheme buffbox glass
//boxtheme <addon> default      that box follows the shared theme again
//boxtheme type compact         shared typography (inherit, compact, standard, large)
//boxtheme type bags large      one box's typography; "default" clears its override
//boxtheme accent vivid         shared accent palette (calm or vivid)
//boxtheme accent bags calm     one box's accent palette
//boxtheme preview bags glass   try one box for 60 seconds
//boxtheme preview commit       keep that theme for the previewed box
//boxtheme preview off          end the preview
```

Typography sets font and size on text boxes. `inherit` keeps each addon's own settings and is the default. Windower's text API has no line-spacing control, so line spacing remains addon-defined. Image-based displays keep their own labels. Accent palettes color a thin title strip across themed boxes; bags and buffbox use `ready` and `warning` states. Other boxes use `normal` until they report a state. Existing selected tab text remains controlled by its addon.

**Drag handle (0.2.3).** The whole title strip drags the box (the text library only drags from over the text), with a small grip (2 x 3 dots) left of the padlock while unlocked; a locked box shows no grip and does not drag. The position is saved when the drag ends: addons pass their settings table as `panel:attach(box, settings)`.

**Lock and close (0.2.0).** Every themed box has a small padlock at the right of its title bar. Click it to
lock the box (gold = locked, grey = unlocked): a locked box cannot be dragged. Boxes whose addon passes `close_cmd`
(`bags`, `timers`) also get a small square at the left that runs the addon's `box off`. Lock state is kept in
`data/locks.txt`, so it is one setting for the whole suite. **0.2.1:** the icons are smooth 14 px PNGs (one image per state, so
nothing swaps textures), a click acts on the button release (so it can't start a drag), the padlock redraws at once and chat
says "<addon>: box LOCKED" or "unlocked". Reload each box addon once to pick up the new panel code.


```
//boxtheme lock [addon|all]       //boxtheme unlock [addon|all]
```

Themes: `type1` .. `type8` (the game's Window Types), `menu`, `hud`, `black`, `glass`, and `plain` (the
box's own flat background, as before). Default: `type1`, the user's own game setting. Boxes pick up a change
within 3 s, no reload.

How it works:
- `boxpanel.lua` is the shared part. Each addon creates its panel just before its text box (so the text is
  drawn on top), then attaches it. The panel follows the box 20 times a second: position (also while
  dragging), size (`texts:extents()`), shown or hidden. The title strip covers the box's first line, which is
  the addon's name in every box here. It turns the box's own flat background off, and back on for `plain`.
- The panel is built from Windower `images` (prims): one stretched body texture, an optional tiled overlay
  (type 3's scanlines), the title strip, and 1 px frame lines from a tinted white PNG. Buffbox also uses it
  for its time bars (`//bb layout compact`).
- Art: `art/*.png`, drawn by `tools/make-boxtheme-art.lua` (LuaJIT, deterministic). It is our own art:
  gradients and noise, with colours measured from the user's screenshots of the eight in-game Window Types
  (2026-09-28). Nothing is copied from the game or from other addons (Trust's art is "All rights reserved").
- If `addons/boxtheme` is missing, every box keeps its old flat background: the panel is optional.

Offline tests: `luajit tools/test-boxtheme.lua` (253 checks: themes, config file, geometry, a mocked
Windower). Not yet tested in game: whether Windower draws text over prims regardless of creation order (the
panel is created first to be safe). If a box's text ever disappears behind its panel, `//boxtheme plain`.

**Image-based displays (0.2.7).** `boxpanel.adapter{get, move, visible, title, label|texts, is_draggable, lock}` makes a group of images look like
a text box to the panel, so a display with no text (equipviewer's icon grid, atlasmap's map) gets the same frame, title bar, padlock and drag
handle. The title bar sits `P.TITLE_H` (18 px) above the content. Create the panel before the images so it draws underneath.

## recording.lua: the master recording switch

Not a theme: a tiny shared library every evidence recorder asks "may I write?". The answer lives in
`data/recording.cfg` (`all=on|off`, optional `combatlog=on` style overrides). **Missing file = off**, and the public package ships `all=off`. Flip it with `//rec on|off|status [recorder]`
(command lives in checkup). Combatlog follows within 10 seconds. Offline test: `luajit tools/test-recording.lua`.

## Text dedupe (0.5.3)

`boxpanel` now makes the Windower text library skip a `text(box, str)` call whose string equals the last one given to
the same box, so boxes that refresh every tick stop redrawing unchanged text (28 call sites, 25 addons, two clients).
Strings with `${...}` variables and any `clear` or `append` in between are never skipped. Each addon picks it up on its
next reload (`//lua r <addon>`). If a box ever stops updating, `//lua u boxtheme` does not undo it; reload that addon
after reverting `P.dedupe_text` in `boxpanel.lua`. Offline-tested with a stub library only (`tools/test-boxtheme.lua`).
