--boxpanel: themed backgrounds drawn behind an addon's text box. Shared by every addon here.
--
--   package.path = windower.windower_path .. 'addons/boxtheme/?.lua;' .. package.path
--   local ok, boxpanel = pcall(require, 'boxpanel')
--   local panel = ok and boxpanel.new('buffbox') or nil   -- BEFORE texts.new, so the text draws on top
--   local box = texts.new(...)
--   if panel then panel:attach(box, settings) end   -- settings: saved after a handle drag
--
-- The panel follows the box by itself (position, size, shown/hidden, dragging), 20 times a second.
-- Which theme: addons/boxtheme/data/themes.txt ("default type1", "buffbox glass"), written by the
-- boxtheme addon (//boxtheme) and re-read every 3 s, so a change shows in every box without a reload.
-- Art: addons/boxtheme/art/*.png, drawn by tools/make-boxtheme-art.lua (our own gradients and noise).
-- Pure parts (themes, config, geometry) need no Windower, so tools/test-boxtheme.lua can run them.
local P = {}

-- every box addon pushed its text to the game on every tick, changed or not (28 call sites). The text
-- library's text(t, str) rebuilds the text and redraws it each time, so this skips a call whose string equals the
-- last one given to the same object. Done once here, on the library table (instances reach text() through the
-- table, so assigning a field on a box would hit the library's __newindex and break it). Strings with ${...}
-- variables, and any clear/append in between, are never skipped. P.dedupe_text(texts) returns true when installed.
function P.dedupe_text(texts)
    if type(texts) ~= 'table' or texts._dedupe_text or type(texts.text) ~= 'function' or type(texts.clear) ~= 'function' then return false end
    texts._dedupe_text = true
    local orig_text, orig_clear, orig_append = texts.text, texts.clear, texts.append
    local last = setmetatable({}, {__mode = 'k'})
    texts.text = function(t, str, ...)
        if type(str) == 'string' and not str:find('${', 1, true) then
            if last[t] == str then return end
            local r = orig_text(t, str, ...)
            last[t] = str   -- after the call: orig_text goes through clear, which forgets
            return r
        end
        last[t] = nil
        return orig_text(t, str, ...)
    end
    texts.clear = function(t, ...) last[t] = nil return orig_clear(t, ...) end
    if type(orig_append) == 'function' then
        texts.append = function(t, ...) last[t] = nil return orig_append(t, ...) end
    end
    return true
end
do
    local ok, texts = pcall(require, 'texts')
    if ok then pcall(P.dedupe_text, texts) end
end

local GAME_FRAME = {outer = {28, 31, 46, 255}, inner = {184, 189, 210, 255}}
local GAME_TITLE = {inset = 3, bg = {0, 0, 0, 46}, line = {154, 160, 184, 255}}
local function game(tex, overlay, label)
    return {label = label, body = {tex = tex}, overlay = overlay, frame = GAME_FRAME, title = GAME_TITLE}
end

-- Colours for type1..type8 were measured from the user's screenshots of the in-game Window Types.
P.THEMES = {
    type1 = game('type1.png', nil, 'game window type 1: indigo'),
    type2 = game('type2.png', nil, 'game window type 2: slate grey'),
    type3 = game('type3.png', 'scanlines.png', 'game window type 3: indigo with scanlines'),
    type4 = game('type4.png', nil, 'game window type 4: dark teal'),
    type5 = game('type5.png', nil, 'game window type 5: grey to lavender'),
    type6 = game('type6.png', nil, 'game window type 6: deep navy'),
    type7 = game('type7.png', nil, 'game window type 7: leather brown'),
    type8 = game('type8.png', nil, 'game window type 8: blue ripples'),
    menu = {label = "Vana'diel menu: navy, silver frame, title strip", body = {tex = 'menu.png'},
        frame = {outer = {125, 134, 173, 255}, inner = {10, 13, 28, 255}},
        title = {inset = 1, tex = 'menu_title.png', bottom = {125, 134, 173, 255}}},
    hud = {label = 'compact HUD: dark, blue top edge', body = {rgba = {8, 10, 18, 200}},
        top = {rgba = {111, 134, 217, 255}, h = 2}},
    black = {label = 'black: matte, no frame', body = {rgba = {0, 0, 0, 220}},
        frame = {outer = {42, 42, 42, 255}}, title = {bottom = {51, 51, 51, 255}}},
    glass = {label = 'smoked glass: see-through, gold edges', body = {tex = 'glass.png'},
        top = {rgba = {201, 165, 90, 255}, h = 1}, bottom = {rgba = {107, 86, 48, 255}, h = 1}},
    frame = {label = 'frame only: border and title bar, no fill (for overlays another program draws)', body = {rgba = {0, 0, 0, 0}},
        frame = GAME_FRAME, title = GAME_TITLE},
    plain = {label = "plain: the box's own flat background, no panel", plain = true},
}
P.ORDER = {'type1', 'type2', 'type3', 'type4', 'type5', 'type6', 'type7', 'type8', 'menu', 'hud', 'black',
    'glass', 'frame', 'plain'}
P.DEFAULT = 'type1'   -- the user's own game setting (screenshot, 2026-09-28)
P.PAD = 6             -- panel edge beyond the text, px
P.TYPE = {inherit = {}, compact = {font = 'Consolas', size = 10}, standard = {font = 'Consolas', size = 12},
    large = {font = 'Consolas', size = 15}}
P.ACCENTS = {calm = {normal = {111,134,217,255}, ready = {104,205,157,255},
    active = {111,180,255,255}, warning = {244,185,85,255}, danger = {237,103,103,255}},
    vivid = {normal = {145,169,255,255}, ready = {94,238,157,255},
    active = {83,195,255,255}, warning = {255,202,69,255}, danger = {255,94,111,255}}}
P.STATES = {normal = true, ready = true, active = true, warning = true, danger = true}

function P.parse_choices(text, choices, fallback)
    local cfg = {default = fallback, per = {}}
    for line in ((text or '') .. '\n'):gmatch('([^\n]*)\n') do
        local k, v = line:gsub('#.*', ''):match('^%s*(%S+)%s+(%S+)%s*$')
        if k and choices[v:lower()] then
            if k:lower() == 'default' then cfg.default = v:lower() else cfg.per[k:lower()] = v:lower() end
        end
    end
    return cfg
end

function P.format_choices(cfg, label)
    local lines = {'# boxtheme ' .. label, 'default ' .. cfg.default}
    local keys = {}
    for k in pairs(cfg.per) do keys[#keys + 1] = k end
    table.sort(keys)
    for _, k in ipairs(keys) do lines[#lines + 1] = k .. ' ' .. cfg.per[k] end
    return table.concat(lines, '\n') .. '\n'
end

function P.choice_for(cfg, addon)
    return cfg.per[(addon or ''):lower()] or cfg.default
end

function P.parse_preview(text, now)
    local addon, theme, expires = (text or ''):match('^(%w+)%s+(%w+)%s+(%d+)')
    if addon and P.THEMES[theme] and tonumber(expires) > (now or os.time()) then
        return {addon = addon:lower(), theme = theme, expires = tonumber(expires)}
    end
end

-- themes.txt: "default <theme>" and "<addon> <theme>" lines; '#' comments; unknown themes ignored.
function P.parse_config(text)
    local cfg = {default = nil, per = {}}
    for line in ((text or '') .. '\n'):gmatch('([^\n]*)\n') do
        local k, v = line:gsub('#.*', ''):match('^%s*(%S+)%s+(%S+)%s*$')
        if k and P.THEMES[v:lower()] then
            if k:lower() == 'default' then cfg.default = v:lower() else cfg.per[k:lower()] = v:lower() end
        end
    end
    return cfg
end

function P.format_config(cfg)
    local lines = {'# boxtheme: which background each addon box draws. Written by //boxtheme; editable by hand.',
        'default ' .. (cfg.default or P.DEFAULT)}
    local names = {}
    for k in pairs(cfg.per) do names[#names + 1] = k end
    table.sort(names)
    for _, k in ipairs(names) do lines[#lines + 1] = k .. ' ' .. cfg.per[k] end
    return table.concat(lines, '\n') .. '\n'
end

function P.theme_for(cfg, addon)
    return (cfg and cfg.per[(addon or ''):lower()]) or (cfg and cfg.default) or P.DEFAULT
end

-- Rectangles for one theme around text at (x, y) sized w x h, first line line_h tall.
-- Each: {tex = file or nil (white), rgba, x, y, w, h, tile = {nx, ny} or nil}. Back to front.
function P.layout(name, x, y, w, h, line_h, pad)
    local t = P.THEMES[name]
    if not t or t.plain then return {} end
    pad = pad or P.PAD
    local X, Y, W, H = x - pad, y - pad, w + 2 * pad, h + 2 * pad
    local out = {}
    local function rect(tex, rgba, rx, ry, rw, rh, tile)
        if rw > 0 and rh > 0 then out[#out + 1] = {tex = tex, rgba = rgba or {255, 255, 255, 255}, x = rx, y = ry, w = rw, h = rh, tile = tile} end
    end
    local function frame(rgba, i)
        rect(nil, rgba, X + i, Y + i, W - 2 * i, 1)
        rect(nil, rgba, X + i, Y + H - 1 - i, W - 2 * i, 1)
        rect(nil, rgba, X + i, Y + i + 1, 1, H - 2 - 2 * i)
        rect(nil, rgba, X + W - 1 - i, Y + i + 1, 1, H - 2 - 2 * i)
    end
    rect(t.body.tex, t.body.rgba, X, Y, W, H)
    if t.overlay then rect(t.overlay, nil, X, Y, W, H, {math.max(1, math.ceil(W / 4)), math.max(1, math.ceil(H / 3))}) end
    if t.title and line_h and line_h > 0 then
        local i = t.title.inset or 0
        local tx, ty, tw, th = X + i, Y + i, W - 2 * i, pad + line_h + 2 - i
        if t.title.tex or t.title.bg then rect(t.title.tex, t.title.bg, tx, ty, tw, th) end
        if t.title.line then
            rect(nil, t.title.line, tx, ty, tw, 1)
            rect(nil, t.title.line, tx, ty + th - 1, tw, 1)
            rect(nil, t.title.line, tx, ty + 1, 1, th - 2)
            rect(nil, t.title.line, tx + tw - 1, ty + 1, 1, th - 2)
        end
        if t.title.bottom then rect(nil, t.title.bottom, tx, ty + th, tw, 1) end
    end
    if t.top then rect(nil, t.top.rgba, X, Y, W, t.top.h) end
    if t.bottom then rect(nil, t.bottom.rgba, X, Y + H - t.bottom.h, W, t.bottom.h) end
    if t.frame then
        if t.frame.outer then frame(t.frame.outer, 0) end
        if t.frame.inner then frame(t.frame.inner, 1) end
    end
    return out
end

-- Time bars: {line = n (1 = first line), frac = 0..1, rgba}. A 2 px bar along the bottom of that line; with fill = true the bar
-- covers the whole row instead (a damage-meter row, behind the text).
function P.bar_rects(bars, x, y, w, line_h)
    local out = {}
    for _, b in ipairs(bars or {}) do
        local f = math.max(0, math.min(1, b.frac or 0))
        local bw = math.floor(w * f + 0.5)
        if bw > 0 and b.line and line_h > 0 then
            if b.fill then
                out[#out + 1] = {rgba = b.rgba or {111, 134, 217, 120}, x = x, y = y + (b.line - 1) * line_h, w = bw, h = math.floor(line_h)}
            else
                out[#out + 1] = {rgba = b.rgba or {111, 134, 217, 255}, x = x, y = y + b.line * line_h - 2, w = bw, h = 2}
            end
        end
    end
    return out
end

function P.count_lines(s)
    if type(s) ~= 'string' or s == '' then return 1 end
    return select(2, s:gsub('\n', '\n')) + 1
end

-- Room for the title bar's controls. The grip and padlock sit at the right of the title strip, over whatever the first
-- line says; a long title ("buffbox  <character>  2 buffs") ran under them (2026-09-30 screenshot). The fonts here are
-- monospace, so the first line's width is its share of the widest line. Returns how many px the panel (not the text)
-- must grow to the right so the controls clear the title; 0 when they already fit.
P.CONTROLS_W = 14 * 2 + 6 + 4 + 8   -- grip + padlock + gaps, matches P.ICON below
function P.title_extra(text, w)
    if type(text) ~= 'string' or text == '' or not w or w <= 0 then return 0 end
    text = text:gsub([[\cs%(%d+,%d+,%d+%)]], ''):gsub([[\cr]], '')
    local widest, first = 0, nil
    for line in (text .. '\n'):gmatch('([^\n]*)\n') do
        local n = #line
        if first == nil then first = n end
        if n > widest then widest = n end
    end
    if widest == 0 then return 0 end
    local need = first * (w / widest) + P.CONTROLS_W
    return need > w and math.ceil(need - w) or 0
end

-------------------------------------------------------------------------------
-- Title bar controls: a padlock at the right of the title strip, and an optional close box at the left.
-- Lock state lives in themes.txt's sibling locks.txt ("all locked", "<addon> locked|unlocked"), not in each addon.
-------------------------------------------------------------------------------
P.ICON = 14   -- shown size of the 16x16 icon art (art/lock_on.png, lock_off.png, close.png)
local WHITE = {255, 255, 255, 255}

function P.parse_locks(text)
    local cfg = {all = false, per = {}}
    for line in ((text or '') .. '\n'):gmatch('([^\n]*)\n') do
        local k, v = line:gsub('#.*', ''):match('^%s*(%S+)%s+(%S+)%s*$')
        if k and (v == 'locked' or v == 'unlocked') then
            if k:lower() == 'all' then cfg.all = (v == 'locked') else cfg.per[k:lower()] = (v == 'locked') end
        end
    end
    return cfg
end

function P.format_locks(cfg)
    local lines = {'# boxtheme: which boxes are locked (not draggable). Written by //boxtheme lock; editable by hand.',
        'all ' .. (cfg.all and 'locked' or 'unlocked')}
    local names = {}
    for k in pairs(cfg.per) do names[#names + 1] = k end
    table.sort(names)
    for _, k in ipairs(names) do lines[#lines + 1] = k .. ' ' .. (cfg.per[k] and 'locked' or 'unlocked') end
    return table.concat(lines, '\n') .. '\n'
end

-- A box's own entry wins over "all".
function P.is_locked(cfg, addon)
    if not cfg then return false end
    local own = cfg.per[(addon or ''):lower()]
    if own ~= nil then return own end
    return cfg.all and true or false
end

-- Set one box, or all of them. `all` clears the per-box entries so it means what it says.
function P.set_lock(cfg, addon, locked)
    if addon == nil or addon == 'all' then
        cfg.all, cfg.per = locked and true or false, {}
    else
        cfg.per[addon:lower()] = locked and true or false
    end
    return cfg
end

-- Where the controls sit for a box whose text is at (x, y), w wide, first line line_h tall.
function P.controls(x, y, w, line_h, pad, with_close)
    pad = pad or P.PAD
    local X, Y, W = x - pad, y - pad, w + 2 * pad
    local size = P.ICON
    local iy = Y + math.floor((pad + (line_h or 12) + 2 - size) / 2)
    local out = {lock = {x = X + W - 4 - size, y = iy, w = size, h = size}}
    -- The whole title strip is the drag handle; the grip is where it is drawn (left of the padlock).
    out.strip = {x = X, y = Y, w = W, h = pad + (line_h or 12) + 2}
    out.grip = {x = out.lock.x - 6 - size, y = iy, w = size, h = size}
    if with_close then out.close = {x = X + 4, y = iy, w = size, h = size} end
    return out
end

function P.hit(r, mx, my)
    return r ~= nil and mx >= r.x - 3 and mx <= r.x + r.w + 3 and my >= r.y - 3 and my <= r.y + r.h + 3
end

-- The padlock and close box are smooth PNGs, one per state, each on its own image: the panel only shows or hides
-- them, it never swaps a texture (that is what made the old pixel-rectangle padlock lag). `slot` is the image it uses.
function P.lock_icon(r, locked)
    return {slot = locked and 1 or 2, tex = locked and 'lock_on.png' or 'lock_off.png', x = r.x, y = r.y, w = r.w, h = r.h, rgba = WHITE}
end

-- A thin box around the padlock, exactly the clickable area (P.hit), so the target is visible. Four 1 px lines.
local FRAME_COL = {150, 158, 180, 255}
function P.lock_frame(r)
    local m = 3
    local x, y, w, h = r.x - m, r.y - m, r.w + 2 * m, r.h + 2 * m
    return {{rgba = FRAME_COL, x = x, y = y, w = w, h = 1}, {rgba = FRAME_COL, x = x, y = y + h - 1, w = w, h = 1},
        {rgba = FRAME_COL, x = x, y = y + 1, w = 1, h = h - 2}, {rgba = FRAME_COL, x = x + w - 1, y = y + 1, w = 1, h = h - 2}}
end

function P.grip_icon(r)
    return {slot = 8, tex = 'grip.png', x = r.x, y = r.y, w = r.w, h = r.h, rgba = WHITE}
end

-- Exact test (no slop) for the drag strip.
function P.in_rect(r, mx, my)
    return r ~= nil and mx >= r.x and mx <= r.x + r.w and my >= r.y and my <= r.y + r.h
end

function P.close_icon(r)
    return {slot = 3, tex = 'close.png', x = r.x, y = r.y, w = r.w, h = r.h, rgba = WHITE}
end

-------------------------------------------------------------------------------
-- Adapter: makes a group of images look like a text box to the panel, so image-based displays (equipviewer's icon grid,
-- atlasmap's map) get the same frame, title bar, padlock and drag handle. `o`:
--   get()       -> x, y, w, h   the content rectangle on screen (below the title bar), nil while there is nothing to frame
--   move(x, y)                  put the content's top-left corner at x, y
--   visible()   -> boolean
--   title       the title text; `label` is the texts object that shows it (atlasmap already has one), else `texts` (the
--               texts module) is used to create one here
--   is_draggable() / lock(locked)   optional: read and set the addon's own drag switch, so a locked display cannot be
--               dragged any other way either
-- The title bar sits above the content: the adapter reports a box that starts P.TITLE_H higher than the content.
-------------------------------------------------------------------------------
P.TITLE_H = 18
function P.adapter(o)
    local a = {no_title_extra = true, drag_ok = true}
    local label = o.label
    if not label and o.texts then
        label = o.texts.new(o.title or '', {text = {font = 'Consolas', size = 10}, bg = {visible = false}, flags = {draggable = false}})
        a.own_label = label
    end
    function a:visible() return o.visible() and true or false end
    function a:pos(x, y)
        if x then o.move(x, y + P.TITLE_H) return end
        local cx, cy = o.get()
        if not cx then return nil, nil end
        return cx, cy - P.TITLE_H
    end
    function a:extents()
        local _, _, w, h = o.get()
        if not w then return nil, nil end
        return w, h + P.TITLE_H
    end
    function a:text() return o.title or '' end
    function a:line_h() return P.TITLE_H - 2 end   -- the title strip is pad + line_h + 2 tall: it ends where the content starts
    function a:bg_visible() end
    function a:draggable(v)
        if v == nil then
            if o.is_draggable then return o.is_draggable() and true or false end
            return self.drag_ok
        end
        self.drag_ok = v
        if o.lock then o.lock(not v) end
    end
    local shown, lx, ly   -- what the title label already shows: only a change goes to the native text object
    function a:tick()
        if not a.own_label then return end
        local cx, cy = o.get()
        if cx and o.visible() then
            if lx ~= cx or ly ~= cy then label:pos(cx, cy - P.TITLE_H) lx, ly = cx, cy end
            if not shown then label:show() shown = true end
        elseif shown ~= false then
            label:hide()
            shown = false
        end
    end
    return a
end

-------------------------------------------------------------------------------
-- Windower side
-------------------------------------------------------------------------------
-- Screen changes (Windower profile UI scale, window size, FFXI config): text positions are in UI pixels (window / uiscale), so a box saved at
-- x = 1500 on a 1969-wide UI is off screen when the UI becomes 1129 wide. Each addon's last-seen UI size is kept in data/screens.txt
-- ("addon width height"); when it differs from now, the box keeps its relative place on the screen and is always clamped fully on screen.
function P.parse_screens(text)
    local t = {}
    for line in (text or ''):gmatch('[^\r\n]+') do
        local a, w, h = line:match('^%s*([%w_%-]+)%s+(%d+)%s+(%d+)')
        if a then t[a:lower()] = {w = tonumber(w), h = tonumber(h)} end
    end
    return t
end

function P.format_screens(t)
    local names = {}
    for k in pairs(t) do names[#names + 1] = k end
    table.sort(names)
    local out = {'# addon, UI width, UI height the box positions were last seen at (written by boxpanel; safe to delete)'}
    for _, k in ipairs(names) do out[#out + 1] = ('%s %d %d'):format(k, t[k].w, t[k].h) end
    return table.concat(out, '\n') .. '\n'
end

local function clamp(v, lo, hi) if v < lo then return lo elseif v > hi then return hi end return v end

-- Where a box should be now. prev = {w=, h=} last seen UI size (or nil), uw/uh = UI size now, (x, y) its position, (w, h) its size.
-- Returns x, y, moved. Never moves a box that is fully on screen and whose screen did not change.
function P.follow_screen(prev, uw, uh, x, y, w, h)
    if not uw or not uh or uw <= 0 or uh <= 0 then return x, y, false end
    local nx, ny = x, y
    if prev and prev.w and prev.h and prev.w > 0 and prev.h > 0 and (prev.w ~= uw or prev.h ~= uh) then
        nx, ny = x * uw / prev.w, y * uh / prev.h
    end
    w, h = w or 0, h or 0
    nx = clamp(nx, 0, math.max(0, uw - w))
    ny = clamp(ny, 0, math.max(0, uh - h))
    nx, ny = math.floor(nx + 0.5), math.floor(ny + 0.5)
    return nx, ny, (nx ~= x or ny ~= y)
end

local POOL, BAR_POOL, ICON_POOL = 20, 40, 10
-- Seconds between two refreshes of a panel. Every refresh asks the native text object for its position, size and visibility,
-- so a panel idles at 5 Hz and runs at 20 Hz for FAST_FOR seconds after any mouse event (a drag, a click on the padlock).
P.IDLE_GAP, P.FAST_GAP, P.FAST_FOR = 0.2, 0.05, 1.5
local Panel = {}
Panel.__index = Panel

local function root() return windower.windower_path .. 'addons/boxtheme/' end

local function read_config()
    local f = io.open(root() .. 'data/themes.txt', 'r')
    if not f then return P.parse_config('') end
    local s = f:read('*a')
    f:close()
    return P.parse_config(s)
end

local function read_file(name)
    local f = io.open(root() .. 'data/' .. name, 'r')
    if not f then return '' end
    local s = f:read('*a')
    f:close()
    return s
end

function P.read_type() return P.parse_choices(read_file('type.txt'), P.TYPE, 'inherit') end
function P.read_accent() return P.parse_choices(read_file('accent.txt'), P.ACCENTS, 'calm') end
function P.read_preview() return P.parse_preview(read_file('preview.txt')) end

function P.save_text(name, contents)
    local dir = root() .. 'data/'
    if not windower.dir_exists(dir) then windower.create_dir(dir) end
    local f = io.open(dir .. name, 'w')
    if not f then return false end
    f:write(contents)
    f:close()
    return true
end

local function read_locks()
    local f = io.open(root() .. 'data/locks.txt', 'r')
    if not f then return P.parse_locks('') end
    local s = f:read('*a')
    f:close()
    return P.parse_locks(s)
end
P.read_locks = read_locks

function P.save_locks(cfg)
    local dir = root() .. 'data/'
    if not windower.dir_exists(dir) then windower.create_dir(dir) end
    local f = io.open(dir .. 'locks.txt', 'w')
    if not f then return false end
    f:write(P.format_locks(cfg))
    f:close()
    return true
end

local function read_screens() return P.parse_screens(read_file('screens.txt')) end

-- Called about once a second: keep this box on screen after a change of resolution or UI scale (see P.follow_screen).
function Panel:follow_screen()
    local box = self.box
    if not box or not windower.get_windower_settings then return end
    local s = windower.get_windower_settings()
    local uw, uh = s and s.ui_x_res, s and s.ui_y_res
    if not uw or uw <= 0 then return end
    local shown = box:visible()
    local screens = self.screens or read_screens()
    local prev = screens[self.addon:lower()]
    local changed = not prev or prev.w ~= uw or prev.h ~= uh
    if shown or changed then
        local x, y = box:pos()
        local w, h = box:extents()
        local nx, ny, moved = P.follow_screen(prev, uw, uh, x, y, w, h)
        if moved then
            box:pos(nx, ny)
            if box.drag_end then pcall(box.drag_end, box)
            else
                local root_t = self.root or rawget(_G, 'settings')
                if root_t then pcall(function() require('config').save(root_t) end) end
            end
        end
    end
    if changed then
        screens = read_screens()   -- other addons write this file too: merge, don't overwrite
        screens[self.addon:lower()] = {w = uw, h = uh}
        P.save_text('screens.txt', P.format_screens(screens))
    end
    self.screens = nil
end

function P.save_config(cfg)
    local dir = root() .. 'data/'
    if not windower.dir_exists(dir) then windower.create_dir(dir) end
    local f = io.open(dir .. 'themes.txt', 'w')
    if not f then return false end
    f:write(P.format_config(cfg))
    f:close()
    return true
end
P.read_config = read_config

-- Create the image pool now (before the addon's texts.new) so the text is drawn over it.
function P.new(addon, opts)
    local images = require('images')
    local self = setmetatable({addon = addon, prims = {}, bars = {}, icons = {}, cache = {}, want_bars = {},
        cfg = read_config(), cfg_t = os.clock(), theme = nil, locks = read_locks(), locked = false,
        type_cfg = P.read_type(), accent_cfg = P.read_accent(), preview = P.read_preview(), state = 'normal',
        close_cmd = opts and opts.close_cmd or nil, ctl = nil,
        -- above: draw the title strip on a new line ABOVE the box instead of over its first line (for boxes with no
        -- title line). caption: the text on that strip. line_h: line height for boxes that are not text (images).
        above = opts and opts.above or false, caption_text = opts and (opts.caption or addon) or addon,
        line_h = opts and opts.line_h or nil}, Panel)
    local function prim()
        return images.new({pos = {x = 0, y = 0}, size = {width = 1, height = 1}, draggable = false,
            texture = {path = root() .. 'art/white.png', fit = false}, color = {alpha = 0, red = 255, green = 255, blue = 255}})
    end
    for i = 1, POOL do self.prims[i] = prim() self.prims[i]:hide() end
    if opts and opts.bars then for i = 1, BAR_POOL do self.bars[i] = prim() self.bars[i]:hide() end end
    for i = 1, ICON_POOL do self.icons[i] = prim() self.icons[i]:hide() end
    pcall(function() require('heapstat').start() end)   -- every box addon reports its Lua heap (data/heap.csv)
    return self
end

local function apply(img, r, key, cache)
    local tex = root() .. 'art/' .. (r.tex or 'white.png')
    local c = cache[key] or {}
    cache[key] = c
    if c.tex ~= tex then img:path(tex) c.tex = tex end
    local nx, ny = r.tile and r.tile[1] or 1, r.tile and r.tile[2] or 1
    if c.nx ~= nx or c.ny ~= ny then img:repeat_xy(nx, ny) c.nx, c.ny = nx, ny end
    if c.x ~= r.x or c.y ~= r.y then img:pos(r.x, r.y) c.x, c.y = r.x, r.y end
    if c.w ~= r.w or c.h ~= r.h then img:size(r.w, r.h) c.w, c.h = r.w, r.h end
    local col = r.rgba
    local ck = col[1] .. ',' .. col[2] .. ',' .. col[3] .. ',' .. col[4]
    if c.col ~= ck then img:color(col[1], col[2], col[3]) img:alpha(col[4]) c.col = ck end
    if not c.shown then img:show() c.shown = true end
end

local function hide_from(list, from, cache, prefix)
    for i = from, #list do
        local c = cache[prefix .. i]
        if not c or c.shown ~= false then list[i]:hide() cache[prefix .. i] = c or {} cache[prefix .. i].shown = false end
    end
end

-- The caption on a strip-above title bar: a small text made after the image pool, so it draws over the strip.
function Panel:place_caption(x, py, line_h)
    if not self.above then return end
    if not self.caption then
        if x == nil then return end
        local ok, texts = pcall(require, 'texts')
        if not ok then return end
        self.caption = texts.new(self.caption_text, {pos = {x = x, y = py}, text = {size = 10, font = 'Consolas'},
            bg = {visible = false}, flags = {draggable = false}})
    end
    if x == nil then self.caption:hide() self.cap_pos = nil return end
    local cx, cy = x, py + math.max(0, math.floor((P.PAD + (line_h or 12) - 10) / 2))
    if not self.cap_pos or self.cap_pos[1] ~= cx or self.cap_pos[2] ~= cy then self.caption:pos(cx, cy) self.cap_pos = {cx, cy} end
    self.caption:show()
end

function Panel:set_bars(bars) self.want_bars = bars or {} end
function Panel:set_status(state) self.state = P.STATES[state] and state or 'normal' end

function Panel:refresh()
    local box = self.box
    if not box then return end
    if box.tick then box:tick() end   -- an adapter keeps its title label in step
    if os.clock() - self.cfg_t > 3 then
        self.cfg, self.locks, self.cfg_t = read_config(), read_locks(), os.clock()
        self.type_cfg, self.accent_cfg, self.preview = P.read_type(), P.read_accent(), P.read_preview()
    end
    self.locked = P.is_locked(self.locks, self.addon)
    -- Locked boxes cannot be dragged. Checked every refresh so an addon that turns dragging back on loses.
    if box.draggable and box:draggable() == self.locked then box:draggable(not self.locked) end
    -- A box that is not a texts object (an image grid, a map) can ask to hear about the lock: set_locked(bool).
    if box.set_locked and self.sent_lock ~= self.locked then box:set_locked(self.locked) self.sent_lock = self.locked end
    local name = P.theme_for(self.cfg, self.addon)
    if self.preview and self.preview.addon == self.addon and self.preview.expires > os.time() then name = self.preview.theme end
    local type_name = P.choice_for(self.type_cfg, self.addon)
    if self.applied_type ~= type_name and box.font and box.size then
        if not self.base_type then self.base_type = {font = box:font(), size = box:size()} end
        local preset = type_name == 'inherit' and self.base_type or P.TYPE[type_name]
        box:font(preset.font)
        box:size(preset.size)
        self.applied_type = type_name
    end
    if name ~= self.theme then
        self.theme = name
        if box.bg_visible then box:bg_visible(P.THEMES[name].plain and true or false) end
    end
    if not box:visible() or P.THEMES[name].plain then
        hide_from(self.prims, 1, self.cache, 'p')
        hide_from(self.bars, 1, self.cache, 'b')
        hide_from(self.icons, 1, self.cache, 'i')
        self.ctl = nil
        self:place_caption(nil)
        return
    end
    local x, y = box:pos()
    local w, h = box:extents()
    if not w or w <= 0 then   -- empty text: nothing to frame, so hide the panel rather than leave the last frame up
        hide_from(self.prims, 1, self.cache, 'p') hide_from(self.bars, 1, self.cache, 'b') hide_from(self.icons, 1, self.cache, 'i')
        self.ctl = nil
        self:place_caption(nil)
        return
    end
    local line_h = self.line_h or (box.line_h and box:line_h()) or h / P.count_lines(box:text())
    local pw = box.no_title_extra and w or w + P.title_extra(box:text(), w)   -- panel width: grows when a long title would run under the controls
    -- Strip above: the panel grows upward by one line and the title strip is that new line.
    local py, ph = y, h
    if self.above then py, ph = y - line_h - 2, h + line_h + 2 end
    local rects = P.layout(name, x, py, pw, ph, line_h)
    local accent = P.ACCENTS[P.choice_for(self.accent_cfg, self.addon)][self.state]
    if #rects < #self.prims then rects[#rects + 1] = {rgba = accent, x = x - P.PAD + 2,
        y = py - P.PAD + 2, w = math.max(1, pw + 2 * P.PAD - 4), h = 2} end
    for i = 1, math.min(#rects, #self.prims) do apply(self.prims[i], rects[i], 'p' .. i, self.cache) end
    hide_from(self.prims, #rects + 1, self.cache, 'p')
    local bars = P.bar_rects(self.want_bars, x, y, w, line_h)
    for i = 1, math.min(#bars, #self.bars) do apply(self.bars[i], bars[i], 'b' .. i, self.cache) end
    hide_from(self.bars, #bars + 1, self.cache, 'b')
    -- No close box: it sat under the first line of text and could not be clicked (2026-09-30). `//<addon> box off` closes.
    self.ctl = P.controls(x, py, pw, line_h, P.PAD, false)
    self:place_caption(x, py, line_h)
    local icons = {}
    local lk = P.lock_icon(self.ctl.lock, self.locked)
    icons[lk.slot] = lk
    for i, r in ipairs(P.lock_frame(self.ctl.lock)) do icons[3 + i] = r end
    if not self.locked then icons[8] = P.grip_icon(self.ctl.grip) end   -- a locked box shows no handle
    for i = 1, #self.icons do
        if icons[i] then
            apply(self.icons[i], icons[i], 'i' .. i, self.cache)
        else
            local c = self.cache['i' .. i]
            if not c or c.shown ~= false then self.icons[i]:hide() self.cache['i' .. i] = c or {} self.cache['i' .. i].shown = false end
        end
    end
end

-- One line saying what this panel is doing, for an addon's debug command: attached?, theme, size, shown images, last error.
function Panel:debug()
    local shown = 0
    for _, list in ipairs({self.prims, self.bars, self.icons}) do
        for i = 1, #list do
            local c = self.cache[(list == self.prims and 'p' or (list == self.bars and 'b' or 'i')) .. i]
            if c and c.shown then shown = shown + 1 end
        end
    end
    local ctl = self.ctl and self.ctl.strip
    return ('panel %s: %s, theme %s, locked %s, %d images shown%s%s'):format(tostring(self.addon), self.box and 'attached' or 'STOPPED',
        tostring(self.theme), tostring(self.locked), shown,
        ctl and (', strip at %d,%d %dx%d'):format(ctl.x, ctl.y, ctl.w, ctl.h) or ', no controls yet',
        self.err and (', LAST ERROR: ' .. self.err) or '')
end

-- True when the pointer is over one of this box's title-bar controls (for addons with their own click handler).
function Panel:over_control(mx, my)
    local c = self.ctl
    return c ~= nil and (P.hit(c.lock, mx, my) or P.hit(c.close, mx, my))
end

-- Start following the box. Not every frame (the 2026-09-17 client hangs): 5 times a second, 20 while the mouse is busy.
function Panel:attach(box, root)
    self.box = box
    self.base_type, self.applied_type = nil, nil
    self.root = root   -- the addon's settings table, saved after a drag (texts saves it for its own drags)
    if self.attached then self.cache = {} return self end   -- a replacement text object: follow it, events already registered
    self.attached = true
    local last, last_follow = 0, 0
    windower.register_event('prerender', function()
        local now = os.clock()
        if now - last < (now < (self.fast_until or 0) and P.FAST_GAP or P.IDLE_GAP) then return end
        last = now
        if self.box and os.clock() - last_follow > 1 then   -- about once a second: follow a change of resolution or UI scale
            last_follow = os.clock()
            pcall(self.follow_screen, self)
        end
        local ok, err = pcall(self.refresh, self)
        if not ok then self.err, self.box = tostring(err), nil end   -- stop quietly rather than error every frame; Panel:debug() reports why
    end)
    -- Title bar clicks: press on the padlock / close box, release within 4 px of where it went down. Acting on the
    -- release (like mimic's box) means a click never starts a drag, and the state changes once per click. The
    -- padlock redraws at once (no waiting for the next 20 Hz tick) and says what it did in chat.
    local press, drag = nil, nil
    windower.register_event('mouse', function(kind, mx, my)
        self.fast_until = os.clock() + P.FAST_FOR
        if not self.box or not self.box:visible() or not self.ctl then press, drag = nil, nil return end
        -- Drag handle: pressing anywhere on the title strip (not the padlock) moves the box with the pointer. The
        -- text library only drags from over the text itself, which left the padding above it dead.
        if kind == 0 and drag then
            if self.locked then drag = nil else self.box:pos(mx - drag.dx, my - drag.dy) end
            return
        elseif kind == 2 and drag then
            drag = nil
            if self.box.drag_end then
                pcall(self.box.drag_end, self.box)   -- a wrapped box commits its own move
            else
                local root = self.root or rawget(_G, 'settings')
                if root then pcall(function() require('config').save(root) end) end
            end
            return
        end
        if kind == 1 then
            if not self.locked and not P.hit(self.ctl.lock, mx, my) and P.in_rect(self.ctl.strip, mx, my) then
                local bx, by = self.box:pos()
                drag = {dx = mx - bx, dy = my - by}
            end
            if P.hit(self.ctl.lock, mx, my) then press = {what = 'lock', x = mx, y = my} return true
            elseif self.ctl.close and self.close_cmd and P.hit(self.ctl.close, mx, my) then press = {what = 'close', x = mx, y = my} return true end
            press = nil
        elseif kind == 2 and press then
            local p = press
            press = nil
            if math.abs(mx - p.x) > 4 or math.abs(my - p.y) > 4 then return end
            if p.what == 'lock' then
                local cfg = read_locks()
                local now = not P.is_locked(cfg, self.addon)
                P.set_lock(cfg, self.addon, now)
                P.save_locks(cfg)
                self.locks, self.cfg_t = cfg, os.clock()
                pcall(self.refresh, self)
                windower.add_to_chat(207, ('%s: box %s'):format(self.addon, now and 'LOCKED' or 'unlocked'))
            else
                windower.send_command(self.close_cmd)
            end
            return true
        end
    end)
    return self
end

return P
