--buffbox: a box listing your buffs with time left, what your food gives, Corsair roll values and
-- fixed-buff effects, a low-time warning and a buff history per character. READ-ONLY.
-- Buff ids: get_player().buffs. Times: incoming 0x063 order 9. Food item: your own item-use
-- action (category 5, param = item id) just before buff 251 "Food" appears. Food effects: the
-- item's description text in res/item_descriptions.lua. Rolls: category-6 actions that hit you
-- (param = roll ability, target param = roll number), values in rolls.lua. Songs: category-4 casts
-- of a BardSong that land on you (param = spell, target param = buff), potency from an optional songs_wiki.lua table (none ships).
-- Nothing is sent.

_addon.name = 'buffbox'
_addon.author = 'ImpactLogic'
_addon.version = '0.10.0'   -- bump on every change that reaches the game
_addon.commands = {'buffbox', 'bb'}

config = require('config')
texts = require('texts')
local res = require('resources')
local core = require('buffcore')
local rolls = require('rolls')
local effects = require('effects')   -- fixed-buff text: empty until an entry has game evidence
local zones_ok, zones = pcall(require, 'zones_wiki')   -- optional region table, none ships
if not zones_ok then zones = nil end
local coalition = require('coalition')
local ionis_ok, ionis_wiki = pcall(require, 'ionis_wiki')   -- optional effect-number table, none ships
if not ionis_ok then ionis_wiki = nil end
local spells_ok, spells_wiki = pcall(require, 'spells_wiki')   -- optional base-value table, none ships
if not spells_ok then spells_wiki = nil end
local songs_ok, songs_wiki = pcall(require, 'songs_wiki')   -- optional song-potency table, none ships
if not songs_ok then songs_wiki = nil end

local defaults = {
    log_max_kb = 256,
    capture = true,    -- log raw 0x063 rows, item uses, songs, buff gains/losses and 0x061 stat changes
    show_box = true,
    show_pet = false,  -- food's "Pet:" block
    layout = 'full',   -- 'full' (grouped, with details) or 'compact' (one line per buff, time bars)
    warn_secs = 60,          -- chat warning this long before a long buff wears off; 0 = off
    warn_min_minutes = 10,   -- "long" = had at least this much time when first seen (Food always)
    history = true,          -- data/<Character>/history.tsv: every buff gained and lost
    history_max_kb = 512,    -- then it moves to history.old.tsv and starts again
    box = {pos = {x = 20, y = 300}, text = {size = 10, font = 'Consolas'},
           bg = {alpha = 170}, flags = {draggable = true}},
}
local settings = config.load(defaults)
-- Themed background from addons/boxtheme (idea #57), created before the box so the text draws on top.
-- Optional: without boxtheme the box keeps its own flat background.
package.path = (windower.windower_path or '') .. 'addons/boxtheme/?.lua;' .. package.path
local panel_ok, panel = pcall(function() return require('boxpanel').new('buffbox', {bars = true}) end)
if not panel_ok then panel = nil end
local box = texts.new('', settings.box, settings)
if panel then panel:attach(box, settings) end

local DATA = windower.addon_path .. 'data/'
local NL = string.char(10)
local FOOD_WINDOW = 15   -- seconds between using an item and the Food buff showing

-------------------------------------------------------------------------------
-- Log + error capture (templates/addon).
-------------------------------------------------------------------------------
local function ensure_dir(d)
    if not windower.dir_exists(d) then windower.create_dir(d) end
    return d
end

local function log_line(text)
    local path = ensure_dir(DATA) .. 'buffbox.log'
    local f = io.open(path, 'a')
    if not f then return end
    if f:seek('end') > (tonumber(settings.log_max_kb) or 256) * 1024 then
        f:close()
        f = io.open(path, 'w')
        if not f then return end
    end
    f:write(os.date('[%m-%d %H:%M:%S] ') .. text .. NL)
    f:close()
end

local function msg(text)
    windower.add_to_chat(207, 'buffbox: ' .. text)
    log_line(text)
end

local function guarded(label, fn)
    return function(...)
        local args, n = {...}, select('#', ...)
        local ok, err = xpcall(function() return fn(unpack(args, 1, n)) end, debug.traceback)
        if not ok then
            log_line('ERROR in ' .. label .. ': ' .. tostring(err))
            windower.add_to_chat(167, 'buffbox error in ' .. label .. ' - see buffbox/data/buffbox.log')
        end
    end
end

-------------------------------------------------------------------------------
-- Per-character state. timers and food belong to one character; reset on a switch.
-------------------------------------------------------------------------------
local state = {char = nil, id = nil, timers = {}, food = nil, last_use = nil, rolls = {}, songs = {}, warn = {}, gained = {},
    events = {}, pending = nil, measured = {}, snaps = {}, casts = {},
    registrar = coalition.new(), coalitions = nil}

local function char_file(name)
    return state.char and (ensure_dir(ensure_dir(DATA) .. state.char .. '/') .. name) or nil
end
local function food_path() return char_file('food.txt') end

-- data/<Character>/coalitions.tsv: what each Civil Registrar last said (IDEAS #50), one row per coalition.
local function load_coalitions()
    local list, path = {}, char_file('coalitions.tsv')
    local f = path and io.open(path, 'r')
    if f then
        for l in ((f:read('*a') or '') .. NL):gmatch('([^\n]*)\n') do
            local r = coalition.from_tsv(l)
            if r then list[#list + 1] = r end
        end
        f:close()
    end
    return list
end

local function save_coalition(rec)
    local list, out = load_coalitions(), {}
    rec.date = os.date('%Y-%m-%d')
    for _, r in ipairs(list) do
        if r.coalition ~= rec.coalition then out[#out + 1] = r
        else
            -- An edification-only answer has no "Ionis provides" list, and a status-only answer has no
            -- edification line: each keeps what the other saved before.
            if #rec.effects == 0 then rec.effects = r.effects end
            rec.rank = rec.rank or r.rank
            if not rec.status or rec.status == '' then rec.status = r.status end
        end
    end
    out[#out + 1] = rec
    table.sort(out, function(a, b) return a.coalition < b.coalition end)
    local path = char_file('coalitions.tsv')
    local f = path and io.open(path, 'w')
    if not f then return end
    for _, r in ipairs(out) do f:write(coalition.to_tsv(r, r.date) .. NL) end
    f:close()
    state.coalitions = out
end

local function buff_name(id)
    local b = res.buffs[id]
    return b and b.en or ('buff ' .. id)
end

-- history.tsv: time, + or -, buff id, name, detail (food eaten on +, how long it lasted on -).
local function history(sign, id, detail)
    if not settings.history then return end
    local path = char_file('history.tsv')
    local f = path and io.open(path, 'a')
    if not f then return end
    if f:seek('end') > (tonumber(settings.history_max_kb) or 512) * 1024 then
        f:close()
        local old = path:gsub('%.tsv$', '.old.tsv')
        os.remove(old)
        os.rename(path, old)
        f = io.open(path, 'a')
        if not f then return end
    end
    f:write(table.concat({os.date('%Y-%m-%d %H:%M:%S'), sign, id, buff_name(id), detail or ''}, '\t') .. NL)
    f:close()
end

-- data/<Character>/stats.log (idea #55): 0x061 stat changes with the buff gains, losses and songs around
-- them, one file so the timing lines up. Kept apart from buffbox.log, which is small and starts over when
-- full. Over 1 MiB it moves to stats.old.log.
local function stat_log(text)
    if not settings.capture then return end
    local path = char_file('stats.log')
    local f = path and io.open(path, 'a')
    if not f then return end
    if f:seek('end') > 1024 * 1024 then
        f:close()
        local old = path:gsub('%.log$', '.old.log')
        os.remove(old)
        os.rename(path, old)
        f = io.open(path, 'a')
        if not f then return end
    end
    f:write(os.date('%Y-%m-%d %H:%M:%S ') .. text .. NL)
    f:close()
end

local itemname_ok, itemname = pcall(require, 'itemname')   -- item names without loading the 18.7 MB res.items table
local function item_name_of(id)
    if itemname_ok then return itemname.name(id, function() return res.items end) end
    local it = res.items[id]
    return it and it.en or nil
end

local function food_info(item_id)
    local iname = item_name_of(item_id)
    local d = res.item_descriptions and res.item_descriptions[item_id]
    local own, pet = core.food_effects(d and d.en)
    return {id = item_id, name = iname or ('item ' .. item_id), own = own, pet = pet}
end

-- data/<Character>/food.txt holds "<item id> <unix time eaten>", so a reload or a zone keeps it.
-- It is kept when the buff drops (the buff list can blink during a zone); the next meal overwrites it.
local FOOD_MAX_AGE = 4 * 3600   -- a saved meal older than this is not trusted for the current buff
local function save_food(item_id)
    local path = food_path()
    local f = path and io.open(path, 'w')
    if f then f:write(('%d %d'):format(item_id, os.time()) .. NL) f:close() end
end

local function load_food()
    local path = food_path()
    local f = path and io.open(path, 'r')
    if not f then return nil end
    local id, t = (f:read('*l') or ''):match('^(%d+)%s+(%d+)')
    f:close()
    id, t = tonumber(id), tonumber(t)
    if not id or not t or os.time() - t > FOOD_MAX_AGE then return nil end
    return food_info(id)
end

local function has_buff(p, id)
    for _, b in ipairs(p and p.buffs or {}) do if b == id then return true end end
    return false
end

local function reset_for_character(name)
    state.timers, state.last_use, state.food, state.rolls, state.warn, state.gained = {}, nil, nil, {}, {}, {}
    state.songs, state.stats = {}, nil
    state.events, state.pending, state.measured = {}, nil, {}
    state.snaps, state.casts = {}, {}
    if name then
        local p = windower.ffxi.get_player()
        state.id = p and p.id
        state.food = has_buff(p, core.FOOD) and load_food() or nil
        state.coalitions = load_coalitions()
    end
    log_line('character is now ' .. tostring(name) .. ' - per-character state cleared')
end

local function current_char()
    local player = windower.ffxi.get_player()
    local name = player and player.name or nil
    if name ~= state.char then
        state.char = name
        reset_for_character(name)
    end
    return state.char
end

-------------------------------------------------------------------------------
-- Events
-------------------------------------------------------------------------------
-- Idea #55: each 0x061 (your stats) as a diff against the last one, logged to stats.log, and kept as a
-- pending change the box can put on a buff once the 3 s around it are known (core.resolve_measure).
local function on_stats(data)
    local cur = core.parse_stats(data)
    if not cur then return end
    current_char()
    local d = core.stats_diff(state.stats, cur)
    stat_log(state.stats and ('stats: %s'):format(d ~= '' and d or 'same') or ('stats: first ' .. d))
    -- Every packet is kept (last 60) so a buff can be read from a later one in the same gear.
    state.snaps[#state.snaps + 1] = {t = os.time(), stats = cur}
    if #state.snaps > 60 then table.remove(state.snaps, 1) end
    state.pending = true
    state.stats = cur
end

-- Buff gains and losses of the last 15 min, for core.attribute. A gain's target is what a measured
-- change would belong to: 'food', the song that just landed, or the buff id.
local function note_event(kind, buff_id)
    local now = os.time()
    local target = buff_id
    if kind == 'gain' then
        if buff_id == core.FOOD then target = 'food'
        else
            local list = state.songs[buff_id]
            local newest = list and list[#list]
            if newest and now - newest.t <= 6 then target = newest end
        end
    end
    state.events[#state.events + 1] = {t = now, kind = kind, target = target}
    while state.events[1] and state.events[1].t < now - 960 do table.remove(state.events, 1) end
end

-- Gear changes move your stats too (2026-09-30: a Victory March "measured" Def +314 HP +139, a GearSwap swap).
-- Any equip packet cancels a reading in its 3 s window: incoming 0x050 (the server confirms one slot) and
-- outgoing 0x050 / 0x051 (equip one / an equip set), per libs/packets/fields.lua. At most one per second.
local last_gear = 0
local function note_gear(dir, id)
    local now = os.time()
    if now == last_gear then return end
    last_gear = now
    state.events[#state.events + 1] = {t = now, kind = 'gear'}
    stat_log(('gear: %s 0x%03X'):format(dir, id))
end

local function resolve_pending(now)
    if not state.pending then return end
    local found = core.attribute(state.snaps, state.events, now)
    if found == 'wait' then return end
    state.pending = nil
    if not found then return end
    -- One buff gained since the base packet: the change is its own. Several: it is their sum, and says so.
    local n = #found.targets
    local text = n == 1 and found.text or ('%s  (sum of %d buffs)'):format(found.text, n)
    local names = {}
    for _, target in ipairs(found.targets) do
        if target == 'food' then
            if state.food then state.food.measured = text end
        elseif type(target) == 'table' then target.measured = text
        else state.measured[target] = text end
        names[#names + 1] = target == 'food' and 'Food' or type(target) == 'table' and target.spell or buff_name(target)
    end
    stat_log(('measured: %s -> %s'):format(found.text, table.concat(names, ' + ')))
end

windower.register_event('incoming chunk', guarded('incoming chunk', function(id, data)
    if id == 0x061 then return on_stats(data) end
    if id == 0x050 then return note_gear('in', id) end
    if id ~= 0x063 then return end
    local rows, why = core.parse_buff_times(data)
    if why == 'zone' and settings.capture then log_line('0x063/9 all slots 0 (zoning) - kept last timers') end
    if not rows then return end
    current_char()
    state.timers = rows
    -- Slot order (idea #56): the buffs in the order the server keeps them, logged when it changes.
    local ids = {}
    for _, r in ipairs(rows) do ids[#ids + 1] = r.id end
    local order = table.concat(ids, ' ')
    if order ~= state.slots then
        state.slots = order
        stat_log('slots: ' .. order)
    end
    if settings.capture then
        local parts = {}
        for _, r in ipairs(rows) do parts[#parts + 1] = r.id .. ':' .. r.raw end
        log_line(('0x063/9 os.time=%d %s'):format(os.time(), table.concat(parts, ' ')))
    end
end))

-- A roll (or Double-Up, which reports the same roll with the new total) that landed on you.
local function on_roll(act)
    local ja = res.job_abilities[act.param]
    local key = ja and rolls.key(ja.en)
    if not key then return end
    for _, t in ipairs(act.targets or {}) do
        if t.id == state.id and t.actions and t.actions[1] then
            state.rolls[key] = t.actions[1].param
            if settings.capture then log_line(('roll: %s %d from %d'):format(key, t.actions[1].param, act.actor_id)) end
        end
    end
end

-- A Bard song that landed on you: message 230 / 266 "gains the effect of" (res/action_messages.lua),
-- the target's param is the buff. The chat shows the same ("Shouto casts Valor Minuet V." then
-- "<Name> gains the effect of Minuet.", ffxilogger 2026-09-28).
-- Any other spell that lands on you the same way names the exact tier (Protect V, Haste II) and the caster:
-- kept per buff id for the line under the buff. 237 is "receives the effect of".
local function on_spell(act, sp)
    for _, t in ipairs(act.targets or {}) do
        local a = t.actions and t.actions[1]
        if t.id == state.id and a and (a.message == 230 or a.message == 266 or a.message == 237) then
            local mob = windower.ffxi.get_mob_by_id(act.actor_id)
            state.casts[a.param] = {spell = sp.en, from = mob and mob.name, t = os.time()}
            stat_log(('spell: %s (buff %d, msg %d) from %s'):format(sp.en, a.param, a.message, mob and mob.name or act.actor_id))
        end
    end
end

local function on_song(act)
    local sp = res.spells[act.param]
    if not sp then return end
    if sp.type ~= 'BardSong' then return on_spell(act, sp) end
    for _, t in ipairs(act.targets or {}) do
        local a = t.actions and t.actions[1]
        if t.id == state.id and a and (a.message == 230 or a.message == 266) then
            local mob = windower.ffxi.get_mob_by_id(act.actor_id)
            local from = mob and mob.name
            core.note_song(state.songs, a.param, sp.en, from, os.time())
            local line = ('song: %s (buff %d, msg %d) from %s'):format(sp.en, a.param, a.message, from or act.actor_id)
            if settings.capture then log_line(line) end
            stat_log(line)
        end
    end
end

windower.register_event('action', guarded('action', function(act)
    if act.category ~= 4 and act.category ~= 5 and act.category ~= 6 then return end
    current_char()
    if not state.id then return end
    if act.category == 6 then return on_roll(act) end
    if act.category == 4 then return on_song(act) end
    if act.actor_id ~= state.id then return end
    state.last_use = {item = act.param, t = os.time()}
    if settings.capture then
        log_line(('item use: %d %s'):format(act.param, item_name_of(act.param) or '?'))
    end
end))

windower.register_event('gain buff', guarded('gain buff', function(buff_id)
    current_char()
    local g = state.gained[buff_id] or {}
    state.gained[buff_id] = g
    g[#g + 1] = os.time()
    stat_log(('gain: %d %s'):format(buff_id, buff_name(buff_id)))
    note_event('gain', buff_id)
    if buff_id ~= core.FOOD then history('+', buff_id) return end
    local u = state.last_use
    if u and os.time() - u.t <= FOOD_WINDOW then
        state.food = food_info(u.item)
        save_food(u.item)
        log_line(('food: %s (%d), %d effect lines'):format(state.food.name, u.item, #state.food.own))
    else
        -- No meal just now: the buff came back after a zone or reload. Use the saved meal.
        state.food = load_food()
        log_line('Food buff gained without an item use; saved meal: ' .. (state.food and state.food.name or 'none'))
    end
    history('+', buff_id, state.food and state.food.name)
end))

windower.register_event('lose buff', guarded('lose buff', function(buff_id)
    current_char()
    -- Copies of one buff are assumed to wear off oldest first. A buff that was up before
    -- buffbox loaded has no start time, so its duration is left blank.
    local g = state.gained[buff_id]
    local t = g and table.remove(g, 1)
    stat_log(('lose: %d %s'):format(buff_id, buff_name(buff_id)))
    note_event('lose', buff_id)
    state.measured[buff_id] = nil
    if not has_buff(windower.ffxi.get_player(), buff_id) then state.casts[buff_id] = nil end
    history('-', buff_id, t and core.fmt_left(os.time() - t) or nil)
    if buff_id == core.FOOD then state.food = nil end
    local b = res.buffs[buff_id]
    local key = b and rolls.key(b.en)
    if key then state.rolls[key] = nil end
end))

local function colour(r, g, b, text) return ('\\cs(%d,%d,%d)%s\\cr'):format(r, g, b, text) end

local function zone_name(id)
    if not id then
        local info = windower.ffxi.get_info and windower.ffxi.get_info()
        id = info and info.zone
    end
    local z = id and res.zones and res.zones[id]
    return z and z.en
end

-- Lines under a buff: roll value for a roll we saw land, or the cited effects in effects.lua,
-- led by a red note when a region buff does nothing in this zone. Songs are keyed by row (two
-- Minuets are two different songs).
local function details_for(rows, now)
    local d, rowsong = core.song_details(rows, state.songs, songs_wiki, now)
    for r in pairs(rowsong) do   -- the song's name is the row label now; keep the range lines
        local lines = {}
        for i = 2, #d[r] do lines[#lines + 1] = d[r][i] end
        d[r] = lines
    end
    local here = zone_name()
    for _, r in ipairs(rows) do
        local b = res.buffs[r.id]
        local name = b and b.en
        local key = rolls.key(name)
        local line = key and state.rolls[key] and rolls.describe(key, state.rolls[key])
        if line then d[r.id] = {line}
        elseif name == 'Ionis' and #(state.coalitions or {}) > 0 then
            -- What the registrars said, instead of the generic "depends on" lines.
            local lines = coalition.box_lines(state.coalitions, ionis_wiki)
            d[r.id] = lines
        elseif name and effects[name:lower()] then d[r.id] = effects[name:lower()].lines
        elseif state.casts[r.id] and not d[r] then
            -- The spell that put it there, who cast it, and its base value where the optional table gives one.
            local cst = state.casts[r.id]
            local lines = {cst.spell .. (cst.from and (' (' .. cst.from .. ')') or '')}
            if spells_wiki and spells_wiki[cst.spell] then lines[#lines + 1] = spells_wiki[cst.spell] end
            d[r.id] = lines
        end
        local note = core.region_note(name, here, zones)
        if note then
            local lines = {colour(255, 90, 90, note)}
            for _, l in ipairs(d[r.id] or {}) do lines[#lines + 1] = l end
            d[r.id] = lines
        end
    end
    return d, rowsong
end

-- Bard songs' buff ids (res/spells.lua: each BardSong's status), so the box can group them.
local SONG_BUFFS = {}
for _, sp in pairs(res.spells or {}) do
    if sp.type == 'BardSong' and sp.status then SONG_BUFFS[sp.status] = true end
end
local function is_roll(name) return rolls.key(name) ~= nil end

-- Civil Registrar dialogue (mode 150, once per line; 152 repeats it). Read-only: nothing is changed.
windower.register_event('incoming text', guarded('incoming text', function(original, _, mode)
    if mode ~= 150 or type(original) ~= 'string' or not original:find('Civil Registrar', 1, true)
        and not state.registrar.cur then return end
    -- Drop colour / auto-translate bytes and the trailing prompt marker "1" (as choco does).
    local line = original:gsub('[%z\1-\31\127-\255]', ''):gsub('1$', '')
    local rec = coalition.feed(state.registrar, line)
    if rec then
        current_char()
        save_coalition(rec)
        log_line(('coalition: %s rank %s, %s, %d Ionis effects'):format(rec.coalition, tostring(rec.rank),
            rec.status == 'full' and 'fully edified' or (rec.status ~= '' and rec.status) or 'edification not asked',
            #rec.effects))
        msg(('saved %s Coalition (%d Ionis effects)'):format(rec.coalition, #rec.effects))
    end
end))

-- Zoning into an area where a region buff you hold does nothing: one chat line per buff.
windower.register_event('zone change', guarded('zone change', function(new_id, old_id)
    local p = windower.ffxi.get_player()
    local here = zone_name(new_id)
    current_char()
    stat_log(('zone: %s > %s (%s > %s)'):format(tostring(old_id), tostring(new_id), old_id and zone_name(old_id) or '?', here or '?'))
    for _, id in ipairs(p and p.buffs or {}) do
        local b = res.buffs[id]
        local note = b and core.region_note(b.en, here, zones)
        if note then
            windower.add_to_chat(167, ('buffbox: %s - %s'):format(b.en, note))
            log_line(('zone: %s in %s - %s'):format(b.en, here, note))
        end
    end
end))

windower.register_event('outgoing chunk', guarded('outgoing chunk', function(id)
    if id == 0x050 or id == 0x051 then note_gear('out', id) end
end))

-- Once a second: the rows, the low-time warning (box or no box), then the box.
local last_tick = 0
windower.register_event('prerender', function()
    if os.clock() - last_tick < 1 then return end
    last_tick = os.clock()
    local ok, err = pcall(function()
        local p = windower.ffxi.get_player()
        if not p then box:hide() return end
        current_char()
        local names = setmetatable({}, {__index = function(_, id) local b = res.buffs[id] return b and b.en end})
        local now = os.time()
        local rows = core.join(p.buffs, state.timers, now)
        resolve_pending(now)
        local details, rowsong = details_for(rows, now)
        local opts = {names = names, food = state.food, show_pet = settings.show_pet, char = state.char,
            now = now, details = details, songs = rowsong, measured = state.measured, song_ids = SONG_BUFFS,
            is_roll = is_roll, layout = settings.layout, colour = colour}
        local fire = core.warnings(rows, now, state.warn, tonumber(settings.warn_secs) or 0,
            (tonumber(settings.warn_min_minutes) or 10) * 60)
        if panel then
            local low = false
            for _, row in ipairs(rows) do
                if row.ends and row.ends > now and row.ends - now <= (tonumber(settings.warn_secs) or 0) then low = true break end
            end
            panel:set_status(low and 'warning' or 'ready')
        end
        for _, r in ipairs(fire) do
            local label = (r.id == core.FOOD and state.food) and state.food.name or buff_name(r.id)
            local text = ('%s wears off in %s'):format(label, core.fmt_left(r.ends - now))
            windower.add_to_chat(167, 'buffbox: ' .. text)
            log_line('warn: ' .. text)
        end
        if not settings.show_box then
            if box:visible() then box:hide() end
            return
        end
        local lines, bars = core.render(rows, opts)
        box:text(table.concat(lines, NL))
        box:show()
        if panel then panel:set_bars(bars) end
    end)
    if not ok then log_line('ERROR in box: ' .. tostring(err)) end
end)

-------------------------------------------------------------------------------
-- Commands
-------------------------------------------------------------------------------
local function toggle(key, a)
    if a == 'on' or a == 'off' then settings[key] = (a == 'on') else settings[key] = not settings[key] end
    config.save(settings)
    return settings[key] and 'ON' or 'OFF'
end

local function handle(cmd, ...)
    cmd = (cmd or 'food'):lower()
    local a = ({...})[1]
    a = a and a:lower()
    if cmd == 'version' then
        msg('version ' .. _addon.version)
    elseif cmd == 'box' then
        msg('box ' .. toggle('show_box', a))
    elseif cmd == 'layout' then
        if a == 'full' or a == 'compact' then settings.layout = a
        else settings.layout = settings.layout == 'compact' and 'full' or 'compact' end
        config.save(settings)
        msg('layout ' .. settings.layout .. (settings.layout == 'compact' and ' (one line per buff, time bars)' or ' (grouped, with details)'))
    elseif cmd == 'pet' then
        msg('pet lines ' .. toggle('show_pet', a))
    elseif cmd == 'capture' then
        msg('capture ' .. toggle('capture', a))
    elseif cmd == 'warn' then
        if a == 'off' then settings.warn_secs = 0
        elseif a == 'on' then settings.warn_secs = 60
        elseif tonumber(a) then settings.warn_secs = math.max(0, math.floor(tonumber(a)))
        end
        if a then config.save(settings) end
        local w = tonumber(settings.warn_secs) or 0
        msg(w > 0 and ('warn %d s before a buff of %d+ min (or Food) wears off'):format(w, settings.warn_min_minutes)
            or 'warn OFF')
    elseif cmd == 'ionis' then
        current_char()
        local list = state.coalitions or load_coalitions()
        if #list == 0 then msg('no coalition checked yet: pick "The State of the <name> Coalition" at each Civil Registrar in Adoulin') return end
        for _, c in ipairs(list) do
            msg(('%s Coalition rank %s, %s, checked %s'):format(c.coalition, tostring(c.rank or '?'),
                c.status == 'full' and 'fully edified' or (c.status ~= '' and c.status) or 'edification not asked',
                c.date))
            for _, e in ipairs(c.effects) do
                local n = coalition.wiki_number(ionis_wiki, c.coalition, e)
                msg('  ' .. e .. (n and (' ' .. n .. ' [table]') or ''))
            end
        end
    elseif cmd == 'history' then
        current_char()
        if a == 'on' or a == 'off' then msg('history ' .. toggle('history', a)) return end
        local path = char_file('history.tsv')
        local f = path and io.open(path, 'r')
        local lines = {}
        if f then
            for l in ((f:read('*a') or '') .. NL):gmatch('([^\n]*)\n') do
                if l ~= '' then lines[#lines + 1] = l end
            end
            f:close()
        end
        local count = math.max(1, math.floor(tonumber(a) or 10))
        if #lines == 0 then msg('no buff history yet') return end
        for i = math.max(1, #lines - count + 1), #lines do
            local when, sign, _, name, detail = lines[i]:match('^%S+ (%S+)\t(%S)\t(%d+)\t([^\t]*)\t?(.*)$')
            if when then
                local extra = detail ~= '' and ((sign == '+' and ' (' .. detail .. ')') or (' after ' .. detail)) or ''
                windower.add_to_chat(207, ('buffbox: %s %s %s%s'):format(when, sign, name, extra))
            end
        end
    elseif cmd == 'food' then
        current_char()
        local f = state.food
        if not f then
            msg(has_buff(windower.ffxi.get_player(), core.FOOD) and 'Food is up, but the item was eaten before buffbox saw it'
                or 'no food')
        else
            msg(f.name .. ': ' .. (#f.own > 0 and table.concat(f.own, ' / ') or 'no effect lines in its description'))
        end
    else
        msg('version ' .. _addon.version .. '  //bb [food] | history [n|on|off] | warn [secs|on|off] | ionis'
            .. ' | layout [full|compact] | box [on|off] | pet [on|off] | capture [on|off] | version')
    end
end

windower.register_event('addon command', guarded('command', handle))

windower.register_event('load', guarded('load', function()
    msg('loaded version ' .. _addon.version .. '  (//bb help)  box ' .. (settings.show_box and 'on' or 'off')
        .. '; timers appear after the next buff change')
    current_char()
end))

windower.register_event('login', function()
    coroutine.schedule(guarded('login', current_char), 5)
end)

windower.register_event('logout', guarded('logout', function()
    state.char, state.id = nil, nil
    state.timers, state.food, state.last_use, state.rolls, state.warn, state.gained = {}, nil, nil, {}, {}, {}
    state.songs, state.stats = {}, nil
    state.events, state.pending, state.measured = {}, nil, {}
    state.snaps, state.casts = {}, {}
end))
