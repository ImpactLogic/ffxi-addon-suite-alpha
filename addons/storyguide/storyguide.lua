--storyguide: a step-by-step box for missions (and the quests that ride along with them). READ-ONLY: it reads packets and sends nothing.
-- Tracks (storylines in wiki order) are generated offline by tools/build-storyguide.py into tracks/; the box shows the current mission, its parts and steps
-- as a checklist, what the mission requires, and what comes next. Position comes from a mission you confirm (//sg at) tied to the game's own value, or
-- from an ordinal rule where the value is the mission position. Steps tick themselves when a key item they name appears; the rest you tick with //sg done.

_addon.name = 'storyguide'
_addon.author = 'ImpactLogic'
_addon.version = '0.18.0'   -- bump on every change that reaches the game
_addon.commands = {'storyguide', 'sg'}

config = require('config')
texts = require('texts')
resources = require('resources')
local core = require('storyguide_core')
local evidence = require('storyguide_evidence')
-- Data for tracks that carry step text (dev-only, not shipped): without these files the add-on runs the same, with none of them.
local function optional(name) local ok, m = pcall(require, name) return (ok and type(m) == 'table') and m or {} end
local branches = optional('storyguide_branches')
local triggers = require('storyguide_triggers')
local rewards = require('storyguide_rewards')
local fixes = optional('storyguide_fixes')
local gathers = optional('storyguide_gathers')   -- GATHER steps (prototype): see storyguide_gather.lua
local gather = require('storyguide_gather')

local defaults = {
    log_max_kb = 256,
    show_box = true,   -- the repo-wide display switch: //sg box [on|off]
    inferred_triggers = false, -- opt-in wording suggestions; never confirmed progress
    track = 'chains-of-promathia',
    auto = true,   -- master switch for ticks the add-on makes itself (curated triggers and guesses); //sg auto [on|off]. The evidence log is always written.
    welcomed = false,   -- the welcome text has been shown once; //sg welcome shows it again
    notify = false,   -- one chat line when a step ticks itself; //sg notify [on|off]
    gather = true,    -- GATHER steps (prototype): the [GATHER n/m] counters and the bag auto tick; //sg gather [on|off]
    details = false,   -- the details breakout box (start, level, goal, requirements): //sg details [on|off], or click the Details line
    details_box = {pos = {x = 30, y = 560}, text = {size = 10, font = 'Consolas'}, bg = {alpha = 170}, flags = {draggable = true}},
    layout = 'one',   -- 'one': a single box with a Steps | List tab strip (default); 'two': separate list and step boxes. //sg layout one|two
    compact = false,  -- step box shows only the NOW line; //sg compact [on|off], right-click the tab strip, or click the expand line
    show_list = true,   -- the second box: missions in order, done / here / next few; //sg box list [on|off]
    list_box = {pos = {x = 30, y = 60}, text = {size = 10, font = 'Consolas'}, bg = {alpha = 170}, flags = {draggable = true}},
    width = 62, max_lines = 24,
    box = {pos = {x = 30, y = 260}, text = {size = 10, font = 'Consolas'}, bg = {alpha = 170}, flags = {draggable = true}},
}
local settings = config.load(defaults)
do   -- the game's own zone names, so travel wording in a step ("Head to ... Zeruhn Mines") can be recognised
    local names = {}
    for _, z in pairs(resources.zones or {}) do if z and z.en then names[#names + 1] = z.en end end
    core.zones = names
end
-- Themed background from addons/boxtheme, created before the box so the text draws on top (optional; without it the box keeps its flat background).
-- The box's first line is its title: the theme's title strip covers it, with the drag handle, padlock and close button.
package.path = (windower.windower_path or '') .. 'addons/boxtheme/?.lua;' .. package.path
local panel_ok, panel = pcall(function() return require('boxpanel').new('storyguide', {close_cmd = 'sg box off'}) end)
if not panel_ok then panel = nil end
local box = texts.new('${text}', settings.box, settings)
if panel then panel:attach(box, settings) end
-- The list box: its own themed panel (//boxtheme storyguide_list <theme>), so the list and the steps can be read at the same time.
local lpanel_ok, lpanel = pcall(function() return require('boxpanel').new('storyguide_list', {close_cmd = 'sg box list off'}) end)
if not lpanel_ok then lpanel = nil end
local lbox = texts.new('${text}', settings.list_box, settings)
if lpanel then lpanel:attach(lbox, settings) end

-- The details breakout: a third box, closed by default, so the goal text never takes room from the steps (//boxtheme storyguide_details <theme>).
local dpanel_ok, dpanel = pcall(function() return require('boxpanel').new('storyguide_details', {close_cmd = 'sg details off'}) end)
if not dpanel_ok then dpanel = nil end
local dbox = texts.new('${text}', settings.details_box, settings)
if dpanel then dpanel:attach(dbox, settings) end

local DATA = windower.addon_path .. 'data/'
local NL = string.char(10)

-- Where each track finds the game's own value: page type and byte offset of the 0x056 mission page (Windower fields.lua), and the position rule.
local TRACK_FIELDS = {
    ['chains-of-promathia'] = {page = 0xFFFF, offset = 16},
    ['treasures-of-aht-urhgan'] = {page = 0x0080, offset = 24, rule = 'ordinal'},
    ['wings-of-the-goddess'] = {page = 0x0080, offset = 28, rule = 'ordinal'},
    ['rise-of-the-zilart'] = {page = 0xFFFF, offset = 12},
    ['rhapsodies-of-vana-diel'] = {page = 0xFFFF, offset = 32},
    ['san-d-oria'] = {page = 0xFFFF, offset = 8}, ['bastok'] = {page = 0xFFFF, offset = 8}, ['windurst'] = {page = 0xFFFF, offset = 8},
}

local function ensure_dir(d)
    if not windower.dir_exists(d) then windower.create_dir(d) end
    return d
end

local function log_line(text)
    local f = io.open(ensure_dir(DATA) .. 'storyguide.log', 'a')
    if not f then return end
    if f:seek('end') > (tonumber(settings.log_max_kb) or 256) * 1024 then f:close(); f = io.open(DATA .. 'storyguide.log', 'w') end
    if f then f:write(os.date('[%m-%d %H:%M:%S] ') .. text .. NL); f:close() end
end

local function msg(text)
    windower.add_to_chat(207, 'storyguide: ' .. text)
    log_line(text)
end

local function guarded(label, fn)
    return function(...)
        local args, n = {...}, select('#', ...)
        local ok, err = xpcall(function() return fn(unpack(args, 1, n)) end, debug.traceback)
        if not ok then
            log_line('ERROR in ' .. label .. ': ' .. tostring(err))
            windower.add_to_chat(167, 'storyguide error in ' .. label .. ' - see storyguide/data/storyguide.log')
        end
    end
end

-------------------------------------------------------------------------------
-- State (per character: never carried across a character switch)
-------------------------------------------------------------------------------
local tracks = {}            -- slug -> track table
local state = {char = nil, anchors = {}, done = {}, values = {}, raw = {}, ki = {}, keys = {}, page = 0, pages = 1, scroll = nil, from = 1, focus = {}, shown = nil, rows = {}, nlines = 1, list_scroll = nil, auto = {}, inferred = {}, vetoed = {}, step_rows = {}, step_n = 1, step_state = {}, announced = {}, tab = 'steps', strip = false, flash = nil, last_auto = nil, press = nil, dirty = true, last_refresh = 0}

local function load_tracks()
    tracks = {}
    local dir = windower.addon_path .. 'tracks/'
    for _, name in ipairs(windower.get_dir(dir) or {}) do
        local slug = name:match('^(.+)%.lua$')
        if slug then
            local chunk = loadfile(dir .. name)
            local ok, track = pcall(chunk or function() error('cannot load ' .. name) end)
            if ok and type(track) == 'table' then tracks[slug] = track else log_line('could not load track ' .. name .. ': ' .. tostring(track)) end
        end
    end
    -- The shipped skeleton (skeleton/<slug>.lua: mission and quest names and order, no step text) fills in every storyline that has no track above.
    local sdir = windower.addon_path .. 'skeleton/'
    for _, name in ipairs(windower.get_dir(sdir) or {}) do
        local slug = name:match('^(.+)%.lua$')
        if slug and not tracks[slug] then
            local chunk = loadfile(sdir .. name)
            local ok, track = pcall(chunk or function() error('cannot load ' .. name) end)
            if ok and type(track) == 'table' then tracks[slug] = track else log_line('could not load skeleton ' .. name .. ': ' .. tostring(track)) end
        end
    end
    for slug, track in pairs(tracks) do
        local moved = core.apply_fixes(track, fixes)
        if moved > 0 then log_line(('%s: %d step(s) reordered by storyguide_fixes.lua'):format(slug, moved)) end
    end
    -- Curated overlay (tools/build-curated.py): the cleaned steps replace a mission's wiki steps. Optional, like the id tables.
    for slug, track in pairs(tracks) do
        local chunk = loadfile(windower.addon_path .. 'curated/' .. slug .. '.lua')
        local ok, curated = pcall(chunk or function() error('no curated overlay') end)
        if ok and type(curated) == 'table' then
            log_line(('%s: %d mission(s) replaced by the curated overlay'):format(slug, core.apply_curated(track, curated)))
        end
    end
    -- Our own step text (own/<slug>.lua, same shape as the curated overlay): short lines in our own words, added over time from play. Optional.
    for slug, track in pairs(tracks) do
        local chunk = loadfile(windower.addon_path .. 'own/' .. slug .. '.lua')
        local ok, own = pcall(chunk or function() error('no own overlay') end)
        if ok and type(own) == 'table' then
            log_line(('%s: %d mission(s) with our own step text'):format(slug, core.apply_curated(track, own)))
        end
    end
    -- Game-id tables (tools/build-storyguide-ids.py), optional: without one a storyline falls back to your confirmation.
    for slug, track in pairs(tracks) do
        local chunk = loadfile(windower.addon_path .. 'ids/' .. slug .. '.lua')
        local ok, ids = pcall(chunk or function() error('no id table') end)
        if ok and type(ids) == 'table' then
            local matched = core.attach_ids(track, ids, evidence.skipped[slug])
            log_line(('%s: %d of %d missions matched to game ids'):format(slug, matched, #track.missions))
        end
    end
end

local function char_dir()
    local player = windower.ffxi.get_player()
    return player and ensure_dir(ensure_dir(DATA) .. player.name .. '/') or nil
end

local function read_file(path)
    local f = io.open(path, 'r')
    if not f then return nil end
    local text = f:read('*a'); f:close(); return text
end

local function write_file(path, text)
    local f = io.open(path, 'w')
    if f then f:write(text); f:close() end
end

local replay_evidence   -- defined with the trigger code below
local function sync_char()
    local player = windower.ffxi.get_player()
    if not player then return false end
    if state.char ~= player.name then
        state.prev56 = nil
        state.char, state.values, state.raw, state.keys, state.ki, state.recorded_ki = player.name, {}, {}, {}, {}, nil
        local dir = char_dir()
        state.anchors = core.anchors_from_tsv(dir and read_file(dir .. 'anchors.tsv'))
        state.done = core.done_from_tsv(dir and read_file(dir .. 'done.tsv'))
        state.auto = core.done_from_tsv(dir and read_file(dir .. 'auto.tsv'))
        state.inferred = core.done_from_tsv(dir and read_file(dir .. 'inferred.tsv'))
        state.vetoed = core.done_from_tsv(dir and read_file(dir .. 'vetoed.tsv'))
        for _, track in pairs(tracks) do
            for _, mission in ipairs(track.missions) do
                if mission.migrate then for _, set in ipairs({state.done, state.auto, state.inferred, state.vetoed}) do core.migrate_keys(set, mission) end end
            end
        end
        state.focus = {}; state.preview, state.shown_index, state.list_scroll = nil, nil, nil
        for line in tostring(dir and read_file(dir .. 'focus.tsv') or ''):gmatch('[^'..string.char(13,10)..']+') do
            local id, n = line:match('^([^'..string.char(9)..']*)'..string.char(9)..'(%d+)$')
            if id then state.focus[id] = tonumber(n) end
        end
        state.dirty = true
        if replay_evidence then replay_evidence(true) end
    end
    return true
end

local function save()
    local dir = char_dir()
    if not dir then return end
    write_file(dir .. 'anchors.tsv', core.anchors_to_tsv(state.anchors))
    write_file(dir .. 'done.tsv', core.done_to_tsv(state.done))
    write_file(dir .. 'auto.tsv', core.done_to_tsv(state.auto))
    write_file(dir .. 'inferred.tsv', core.done_to_tsv(state.inferred))
    write_file(dir .. 'vetoed.tsv', core.done_to_tsv(state.vetoed))
    local rows = {}
    for id, n in pairs(state.focus) do rows[#rows + 1] = id .. string.char(9) .. n end
    table.sort(rows)
    write_file(dir .. 'focus.tsv', table.concat(rows, NL) .. NL)
end

-------------------------------------------------------------------------------
-- Game values (0x056 mission pages) and key items
-------------------------------------------------------------------------------
local function u16(data, offset) return (data:byte(offset + 1) or 0) + (data:byte(offset + 2) or 0) * 256 end
local function i32(data, offset)
    local v = u16(data, offset) + u16(data, offset + 2) * 65536
    return v >= 2147483648 and v - 4294967296 or v
end

-- Evidence recorder: while you play, every zone-in, cutscene/menu event, key item change and mission value change is written to
-- data/<char>/evidence.tsv with the mission on screen, and every //sg done <n> is written too. That file is what the auto-tick triggers are built from
-- (only events a capture has confirmed will ever tick a step). Read-only: it listens and sends nothing.
local function record(kind, detail)
    local dir = state.char and char_dir()
    if not dir then return end
    local f = io.open(dir .. 'evidence.tsv', 'a')
    if not f then return end
    local track = tracks[settings.track]
    local entry = track and state.index and track.missions[state.index]
    local zone = windower.ffxi.get_info().zone
    f:write(table.concat({os.date('%Y-%m-%d %H:%M:%S'), kind, entry and entry.id or '', zone or '', detail or ''}, string.char(9)), NL)
    f:close()
end

-- Tick a step from evidence when the event matches a trigger of the mission on screen (never over a step you undid).
local check_triggers
local function zone_name(id) local z = resources.zones[id]; return z and z.en or tostring(id) end

local function trigger_matches(c, ev)
    return c.kind == ev.kind and c.zone == ev.zone and (c.menu == nil or c.menu == ev.menu) and (c.npc == nil or c.npc == ev.npc)
end

-- Fail-safe: rebuild auto ticks from the evidence log. Every logged zone/cutscene event carries the mission that was on screen, so the curated triggers can be run
-- over it again. Runs when a character loads and on //sg replay. Never over a step you undid, never when //sg auto is off, and only curated triggers (no guesses).
function replay_evidence(quiet)
    local dir = state.char and char_dir()
    local text = dir and read_file(dir .. 'evidence.tsv')
    if not text or not settings.auto then if not quiet then msg(text and 'auto ticks are off; nothing replayed' or 'no evidence log yet') end return end
    local added = 0
    local T = string.char(9)
    local rows, last_reset = {}, {}
    for line in text:gmatch('[^' .. string.char(13, 10) .. ']+') do
        local f = {}
        for field in (line .. T):gmatch('([^' .. T .. ']*)' .. T) do f[#f + 1] = field end
        rows[#rows + 1] = f
        if f[2] == 'reset' then last_reset[f[3]] = #rows end   -- a //sg reset is final: events before it never restore ticks
    end
    for n, f in ipairs(rows) do
        local kind, id, detail = f[2], f[3], f[5] or ''
        local list = triggers[id]
        if list and n > (last_reset[id] or 0) and (kind == 'zone' or kind == 'event32' or kind == 'event34') then
            local ev
            if kind == 'zone' then ev = {kind = 'zone', zone = detail}
            else ev = {kind = 'event', zone = detail:match('zone=(.-) menu=') , menu = tonumber(detail:match('menu=(%d+)')), npc = (detail:match('npc=(.*)$') ~= '?') and detail:match('npc=(.*)$') or nil} end
            for key, conditions in pairs(list) do
                for _, c in ipairs(conditions) do
                    if trigger_matches(c, ev) and not (state.vetoed[id] and state.vetoed[id][key]) and not (state.auto[id] and state.auto[id][key]) and not (state.done[id] and state.done[id][key]) then
                        state.auto[id] = state.auto[id] or {}
                        state.auto[id][key] = true
                        added = added + 1
                        record('auto-replay', id .. ' ' .. key)
                    end
                end
            end
        end
    end
    if added > 0 then save(); state.dirty = true end
    if added > 0 or not quiet then msg(('replayed the evidence log: %d step(s) restored'):format(added)) end
end

function check_triggers(ev)
    local track = tracks[settings.track]
    local entry = track and state.index and track.missions[state.index]
    if not entry or not settings.auto then return end   -- //sg auto off: the log still records events, nothing ticks itself
    -- No curated trigger matched: guess from the step wording (storyguide_core.infer), the first unticked step that fits.
    local list = triggers[entry.id] or {}
    local function ticked_set()
        local t = {}
        for _, set in ipairs({state.done[entry.id] or {}, state.auto[entry.id] or {}, state.inferred[entry.id] or {}}) do
            for k in pairs(set) do t[k] = true end
        end
        return t   -- an undone step is open again for a NEW event (the undo only stops the same old evidence being replayed on load)
    end
    local curated = false
    for key, conditions in pairs(list) do
        for _, c in ipairs(conditions) do
            if trigger_matches(c, ev) then curated = true end
        end
    end
    if not curated then
        if not settings.inferred_triggers then return end
        local key = core.match_inferred(entry, ev, ticked_set(), branches[entry.id])
        if key then
            state.inferred[entry.id] = state.inferred[entry.id] or {}
            state.inferred[entry.id][key] = true
            if state.vetoed[entry.id] then state.vetoed[entry.id][key] = nil end
            record('inferred', key .. ' | ' .. tostring(ev.npc or ev.zone))
            save(); state.dirty = true
        end
        return
    end
    for key, conditions in pairs(list) do
        for _, c in ipairs(conditions) do
            if trigger_matches(c, ev)
                and not (state.auto[entry.id] and state.auto[entry.id][key]) then
                state.auto[entry.id] = state.auto[entry.id] or {}
                state.auto[entry.id][key] = true
                if state.vetoed[entry.id] then state.vetoed[entry.id][key] = nil end
                record('auto', key)
                state.flash = {id = entry.id, key = key, until_ = os.clock() + 6}
                state.last_auto = {id = entry.id, key = key}
                if settings.notify then
                    local text
                    for _, item in ipairs(core.flatten(entry, branches[entry.id])) do if item.key == key then text = item.text end end
                    msg('step done: ' .. tostring(text or key))
                end
                save(); state.dirty = true
            end
        end
    end
end


-- Tick or untick one step of a mission (a typed //sg done|undo, or a click). Undo is remembered (vetoed.tsv) and a tick the add-on made itself is logged as
-- undo-auto / undo-inferred; the log itself is append-only.
local function mark_step(entry, key, cmd)
    local was_auto = state.auto[entry.id] and state.auto[entry.id][key]
    local was_inferred = state.inferred[entry.id] and state.inferred[entry.id][key]
    state.done[entry.id] = state.done[entry.id] or {}
    state.done[entry.id][key] = (cmd == 'done') or nil
    if cmd == 'undo' then
        state.vetoed[entry.id] = state.vetoed[entry.id] or {}; state.vetoed[entry.id][key] = true   -- kept across reloads
        if state.auto[entry.id] then state.auto[entry.id][key] = nil end
        if state.inferred[entry.id] then state.inferred[entry.id][key] = nil end
    elseif state.vetoed[entry.id] then state.vetoed[entry.id][key] = nil end
    local step
    for _, item in ipairs(core.flatten(entry, branches[entry.id])) do if item.key == key then step = item.text end end
    local kind = cmd
    if cmd == 'undo' and was_auto then kind = 'undo-auto' elseif cmd == 'undo' and was_inferred then kind = 'undo-inferred' end
    record(kind, ('%s | %s'):format(key, step or ''))
    save(); state.dirty = true
    msg(('%s: %s'):format(cmd == 'done' and 'ticked' or 'unticked', step or key))
end

-- A click on a step: untick it if it is ticked (by hand or by the add-on), tick it otherwise. A step ticked only by your key item list cannot be unticked.
local function click_step(entry, key, right)
    if key == '@details' then settings.details = not settings.details; config.save(settings); state.dirty = true; return end
    if state.step_state[key] == 'implied' or state.step_state[key] == 'implied_guess' then mark_step(entry, key, 'undo'); return end   -- implied by a later step: clicking says it did not happen after all
    local by_hand = state.done[entry.id] and state.done[entry.id][key]
    local by_addon = (state.auto[entry.id] and state.auto[entry.id][key]) or (state.inferred[entry.id] and state.inferred[entry.id][key])
    if right then
        if by_hand or by_addon then mark_step(entry, key, 'undo') else msg('that step is not ticked') end
    elseif by_hand or by_addon then mark_step(entry, key, 'undo')
    else
        for _, item in ipairs(core.flatten(entry, branches[entry.id])) do
            if item.key == key and #item.ki > 0 then
                for _, name in ipairs(item.ki) do if state.ki[name:lower()] then msg('that step ticks itself from your key item list and cannot be unticked'); return end end
            end
        end
        mark_step(entry, key, 'done')
    end
end

windower.register_event('incoming chunk', guarded('chunk', function(id, original)
    if id == 0x032 and #original >= 0x0E then
        local npc = original:byte(5) + original:byte(6) * 256 + original:byte(7) * 65536 + original:byte(8) * 16777216
        local zone, menu = u16(original, 0x0A), u16(original, 0x0C)
        local mob = windower.ffxi.get_mob_by_id and windower.ffxi.get_mob_by_id(npc)
        record('event32', ('zone=%s menu=%d npc=%s'):format(zone_name(zone), menu, mob and mob.name or npc))
        check_triggers({kind = 'event', zone = zone_name(zone), menu = menu, npc = mob and mob.name})
    elseif id == 0x034 and #original >= 0x2E then
        local zone, menu = u16(original, 0x2A), u16(original, 0x2C)
        local mob = windower.ffxi.get_mob_by_index and windower.ffxi.get_mob_by_index(u16(original, 0x28))
        record('event34', ('zone=%s menu=%d npc=%s'):format(zone_name(zone), menu, mob and mob.name or '?'))
        check_triggers({kind = 'event', zone = zone_name(zone), menu = menu, npc = mob and mob.name})
    end
    if id ~= 0x056 or #original < 0x26 then return end
    local page = u16(original, 0x24)
    -- Recorder: any 4-byte field of a mission page that changed (not just the ones we read), to find out what the game itself tracks inside a mission.
    local before = state.prev56 and state.prev56[page]
    state.prev56 = state.prev56 or {}
    state.prev56[page] = original
    if before and #before == #original then
        local shown = 0
        for off = 4, #original - 4, 4 do
            if shown < 12 and original:sub(off + 1, off + 4) ~= before:sub(off + 1, off + 4) then
                shown = shown + 1
                record('pkt56', ('page=0x%04X offset=0x%02X %d -> %d'):format(page, off, i32(before, off), i32(original, off)))
            end
        end
    end
    if page == 0x00D0 or page == 0x00D8 then state.raw[page] = original; state.dirty = true end   -- completed-mission bit pages
    state.values[page] = state.values[page] or {}
    for _, field in pairs(TRACK_FIELDS) do
        if field.page == page and #original >= field.offset + 4 then
            local value = i32(original, field.offset)
            if state.values[page][field.offset] ~= value then record('value', ('page=0x%04X offset=%d value=%d'):format(page, field.offset, value)) end
            state.values[page][field.offset] = value
        end
    end
    state.dirty = true
end))

-- A key item you just received ticks its step for good (auto.tsv), so handing the item over in the next cutscene does not un-tick it.
local function latch_ki(name)
    local track = tracks[settings.track]
    local entry = track and state.index and track.missions[state.index]
    if not entry then return end
    for _, item in ipairs(core.flatten(entry, branches[entry.id])) do
        if item.kind == 'step' and not (state.auto[entry.id] and state.auto[entry.id][item.key]) then
            for _, ki in ipairs(item.ki) do
                if ki:lower() == name then
                    state.auto[entry.id] = state.auto[entry.id] or {}
                    state.auto[entry.id][item.key] = true
                    if state.vetoed[entry.id] then state.vetoed[entry.id][item.key] = nil end
                    record('auto', item.key .. ' | key item ' .. name)
                    save(); state.dirty = true
                end
            end
        end
    end
end

local function refresh_key_items()
    local set = {}
    for _, id in pairs(windower.ffxi.get_key_items() or {}) do
        local res = resources.key_items[id]
        if res and res.en then set[res.en:lower()] = true end
    end
    if state.recorded_ki then
        for name in pairs(set) do if not state.recorded_ki[name] then record('ki+', name); latch_ki(name) end end
        for name in pairs(state.recorded_ki) do if not set[name] then record('ki-', name) end end
    end
    state.recorded_ki = set
    state.ki = set
end

local function current_track()
    local slug = settings.track
    return tracks[slug], slug
end

local function track_state(slug)
    local field = TRACK_FIELDS[slug]
    local track = tracks[slug]
    local value = field and state.values[field.page] and state.values[field.page][field.offset] or nil
    local completed
    local map = track and track.map
    if map and map.mode == 'bits' and state.raw[map.page] then
        local raw = state.raw[map.page]
        completed = function(key)
            local byte = raw:byte(map.offset + math.floor(key / 8) + 1)
            if not byte then return nil end
            return math.floor(byte / 2 ^ (key % 8)) % 2 == 1
        end
    end
    return {value = value, completed = completed, anchor = track and state.anchors[track.storyline] or nil, rule = field and field.rule}
end

-- Colours (Windower text escapes): the step to do now is bright, finished ones are dim, section headings stand apart.
local CL_NOW, CL_DIM, CL_HEAD, CL_RESET, CL_FLASH = '\\cs(255,224,96)', '\\cs(130,130,130)', '\\cs(120,200,255)', '\\cr', '\\cs(120,255,140)'

local function tab_strip()
    local s = state.tab == 'list' and ' Steps  [List]' or '[Steps]   List '
    return CL_DIM .. s .. '   click step: tick   click tab: switch   right-click: compact' .. CL_RESET
end

-- GATHER steps: how many of an item are in the inventory (a name matches the item's short or long name, any case), and whether a key item is held.
local item_ids
local function ids_named(name)
    if not item_ids then
        item_ids = {}
        for id, it in pairs(resources.items) do
            for _, n in ipairs({it.en or '', it.enl or ''}) do
                if n ~= '' then
                    local k = n:lower()
                    item_ids[k] = item_ids[k] or {}
                    item_ids[k][#item_ids[k] + 1] = id
                end
            end
        end
    end
    return item_ids[name:lower()] or {}
end

local function bag_have()
    local counts = {}
    local inv = windower.ffxi.get_items('inventory')
    if inv then
        for i = 1, (inv.max or 80) do
            local it = inv[i]
            if it and it.id and it.id > 0 then counts[it.id] = (counts[it.id] or 0) + (it.count or 1) end
        end
    end
    return {
        item = function(name) local n = 0; for _, id in ipairs(ids_named(name)) do n = n + (counts[id] or 0) end; return n end,
        ki = function(name) return state.ki and state.ki[name:lower()] or false end,
    }
end

-- A gather step ticks itself (auto.tsv, so handing the items over afterwards does not un-tick it) once the item is in the bag or the key item held.
-- //sg undo wins: a vetoed step is left alone. Checked at most once a second.
local last_gather = 0
local function latch_gathers(entry)
    local specs = entry and gathers[entry.id]
    if not specs or not settings.auto or not settings.gather or os.clock() - last_gather < 1 then return end
    last_gather = os.clock()
    for _, key in ipairs(gather.done_keys(specs, bag_have())) do
        local ticked = (state.auto[entry.id] and state.auto[entry.id][key]) or (state.done[entry.id] and state.done[entry.id][key])
        if not ticked and not (state.vetoed[entry.id] and state.vetoed[entry.id][key]) then
            state.auto[entry.id] = state.auto[entry.id] or {}
            state.auto[entry.id][key] = true
            record('auto', key .. ' | gather ' .. specs[key].item)
            save(); state.dirty = true
        end
    end
end

local function refresh()
    if not sync_char() then box:hide(); lbox:hide(); dbox:hide(); return end
    local track, slug = current_track()
    if not track then box.text = 'storyguide: no track "' .. tostring(settings.track) .. '"; //sg list'; return end
    refresh_key_items()
    local cstate = track_state(slug)
    local index, source, note = core.position(track, cstate)
    if state.slug ~= slug then state.preview, state.list_scroll = nil, nil end
    state.index, state.slug = index, slug   -- the true position: triggers and evidence always use this, never the mission being browsed
    latch_gathers(index and track.missions[index])
    local one = settings.layout ~= 'two'
    local list_in_box = one and state.tab == 'list' and not settings.compact
    do
        local lines, rows = core.render_list(track, index, source, note, {
            title = 'Story Guide v' .. _addon.version, width = list_in_box and settings.width or settings.list_width or 44, max_lines = settings.list_lines or 24, scroll = state.list_scroll, selected = state.preview,
            now = CL_NOW, dim = CL_DIM, head = CL_HEAD, reset = CL_RESET})
        if list_in_box then   -- the list takes the step box: tab strip under the title, row numbers move down one line
            table.insert(lines, 2, tab_strip())
            local shifted = {}
            for n, i in pairs(rows) do shifted[n + 1] = i end
            rows = shifted
        end
        state.rows, state.nlines = rows, #lines
        state.list_lines = lines
        lbox.text = table.concat(lines, NL)
    end
    local shown, shown_source = index, source
    if state.preview and track.missions[state.preview] then shown, shown_source = state.preview, 'preview' end
    local entry = shown and track.missions[shown]
    if state.shown_index ~= shown then state.page = 0; state.scroll = nil end   -- a new mission starts on its first page
    state.shown_index = shown
    local flash = state.flash and os.clock() < state.flash.until_ and state.flash.id == (track.missions[shown] or {}).id and state.flash.key or nil
    local lines, _, keys, pages, from, _, rows, by_key, finished, stop = core.render(track, shown, shown_source, note, {
        title = 'Story Guide v' .. _addon.version, compact = settings.compact, flash = flash, flashc = CL_FLASH, vetoed = entry and state.vetoed[entry.id] or nil, details_open = settings.details,
        done = entry and state.done[entry.id] or {}, evidence = entry and state.auto[entry.id] or nil, inferred = settings.inferred_triggers and entry and state.inferred[entry.id] or nil, have_ki = function(name) return state.ki[name] end,
        details = false, width = settings.width, max_lines = settings.max_lines, page = state.page, scroll = state.scroll,
        branches = entry and branches[entry.id] or nil, focus = entry and state.focus[entry.id] or nil,
        decorate = entry and settings.gather and gathers[entry.id] and gather.decorator(gathers[entry.id], bag_have(), (windower.ffxi.get_player() or {}).main_job_level) or nil,
        now = CL_NOW, dim = CL_DIM, head = CL_HEAD, reset = CL_RESET})
    if finished and entry and shown == index and not state.announced[entry.id] then   -- mission-complete moment, once per mission and session
        state.announced[entry.id] = true
        local following = track.missions[index + 1]
        if settings.notify then msg(('mission done: %s%s'):format(entry.name, following and ('. Then: ' .. following.name) or '')) end
    end
    state.keys, state.pages, state.from = keys, pages or 1, from or 1
    state.span = (stop and from) and (stop - from + 1) or 3   -- items on screen: the wheel moves at most span - 1, so no step is skipped
    state.strip = one and not settings.compact
    if state.strip then   -- tab strip under the title (one-box layout)
        table.insert(lines, 2, tab_strip())
        local shifted = {}
        for n, key in pairs(rows or {}) do shifted[n + 1] = key end
        rows = shifted
    end
    state.step_rows, state.step_n, state.step_state = rows or {}, #lines, by_key or {}
    dbox.text = (entry and settings.details) and table.concat(core.details_lines(track, entry, {title = 'Mission details v' .. _addon.version, width = settings.width, reward = rewards[entry.id]}), NL) or ''
    if state.scroll then state.scroll = state.from end
    if state.page >= state.pages then state.page = state.pages - 1 end
    box.text = table.concat(list_in_box and state.list_lines or lines, NL)
    state.dirty = false
end

windower.register_event('prerender', guarded('prerender', function()
    local now = os.time()
    if (settings.show_box or settings.show_list) and (state.dirty or now - state.last_refresh >= 2) then
        state.last_refresh = now
        refresh()
    end
    if state.char and settings.show_box then box:show() else box:hide() end
    if state.char and settings.show_list and settings.layout == 'two' then lbox:show() else lbox:hide() end
    if state.char and settings.details and (settings.show_box or settings.show_list) then dbox:show() else dbox:hide() end
end))

-- Mouse over the boxes. The wheel scrolls the box under the pointer (swallowed there so the camera does not zoom). In the list box a left click on a row
-- opens that mission in the step box (browsing only, the true position is untouched); a right click in the step box returns to your own position.
-- The clicked line is found from the box's own height divided by its line count, so it needs no font metrics.
local function clicked_line(x, y, which, nlines)
    which = which or lbox
    local bx, by = which:pos()
    local _, h = which:extents()
    if not (bx and by and h and h > 0) then return nil end
    return math.floor((y - by) / (h / math.max(nlines or state.nlines or 1, 1))) + 1
end

windower.register_event('mouse', function(kind, x, y, delta)
    if not state.char then return end
    local one = settings.layout ~= 'two'
    local in_box = settings.show_box and box:visible() and box:hover(x, y)
    local list_in_box = one and state.tab == 'list' and not settings.compact
    local on_list = (list_in_box and in_box) or (not one and settings.show_list and lbox:visible() and lbox:hover(x, y))
    local on_steps = in_box and not list_in_box
    if not (on_list or on_steps or in_box) then return end
    -- A click is a press and a release in the same spot: a drag of the box (it is draggable) must not tick a step.
    if kind == 1 or kind == 3 then state.press = {x = x, y = y} end
    local function moved() return not state.press or math.abs(state.press.x - x) > 3 or math.abs(state.press.y - y) > 3 end
    if kind == 10 then
        local ok = pcall(function()
            if on_list then
                local track = current_track()
                local top = state.list_scroll or 1
                state.list_scroll = math.max(1, math.min(top + (delta > 0 and -3 or 3), track and #track.missions or 1))
            else
                local jump = math.max(1, math.min(3, (state.span or 3) - 1))
                state.scroll = math.max(1, (state.scroll or state.from or 1) + (delta > 0 and -jump or jump))
            end
            state.dirty = true
        end)
        if ok then return true end
    elseif (kind == 2 or kind == 4) and in_box and not moved() then
        local handled = false
        pcall(function()
            local line = clicked_line(x, y, box, list_in_box and state.nlines or state.step_n)
            if state.strip and line == 2 then   -- the tab strip: click switches Steps | List, right-click toggles compact
                if kind == 2 then state.tab = state.tab == 'list' and 'steps' or 'list' else settings.compact = true; config.save(settings) end
                state.scroll, state.dirty = nil, true; handled = true
            elseif list_in_box then
                local row = kind == 2 and state.rows[line]
                if row then state.preview, state.page, state.scroll, state.tab = row, 0, nil, 'steps'; state.dirty = true; handled = true end
            elseif kind == 4 and state.preview then   -- browsing another mission: right-click goes back to your own position
                state.preview, state.page, state.scroll = nil, 0, nil; state.dirty = true; handled = true
            else
                local track = current_track()
                local entry = track and state.shown_index and track.missions[state.shown_index]
                local key = state.step_rows[line]
                if key == '@expand' then settings.compact = false; config.save(settings); state.dirty = true; handled = true
                elseif key and entry then click_step(entry, key, kind == 4); handled = true end
            end
        end)
        if handled then return true end
    elseif kind == 2 and on_list and not one and not moved() then   -- the separate list box (two-box layout): open the row in the step box
        local handled = false
        pcall(function()
            local row = state.rows[clicked_line(x, y)]
            if row then state.preview, state.page, state.scroll = row, 0, nil; state.dirty = true; handled = true end
        end)
        if handled then return true end
    end
end)

windower.register_event('logout', guarded('logout', function() state.char = nil; box:hide(); lbox:hide(); dbox:hide() end))
windower.register_event('zone change', guarded('zone', function() state.dirty = true; local z = zone_name(windower.ffxi.get_info().zone); record('zone', z); check_triggers({kind = 'zone', zone = z}) end))

-------------------------------------------------------------------------------
-- Commands
-------------------------------------------------------------------------------
local function show_welcome()
    msg('Story Guide: a read-only, step-by-step guide. The yellow line is what to do now; click a step to tick it, click again to untick.')
    msg('Defaults (change any with the command): one box with Steps | List tabs (//sg layout two), steps tick themselves from what the game shows (//sg auto off),')
    msg('no chat line when one does (//sg notify on), goal and requirements closed (click Details or //sg details), compact view off (//sg compact on). //sg help lists everything.')
    settings.welcomed = true; config.save(settings)
end

local function help()
    msg('//sg infer on|off: optional [~] wording suggestions; off by default, never confirmed completion')
    msg('//sg welcome | layout [one|two] | compact [on|off] | replay | auto [on|off] | notify [on|off] | gather [on|off] | details [on|off] | undo last | (click a step to tick or untick it, right-click to untick) | open <n|name> | here | box [list|steps] [on|off] | list | track <name> | at <mission> | done <n> | undo <n> | reset | path <n> | page [n] | (mouse wheel scrolls the box) | next | ahead [n] | status | version')
end

windower.register_event('addon command', guarded('command', function(cmd, ...)
    cmd = (cmd or 'status'):lower()
    local rest = table.concat({...}, ' ')
    sync_char()
    local track, slug = current_track()
    if cmd == 'infer' then
        local choice = (...)
        if choice == 'on' or choice == 'off' then settings.inferred_triggers = choice == 'on'; config.save(settings); state.dirty = true end
        msg('wording suggestions ' .. (settings.inferred_triggers and 'on' or 'off') .. '; [~] is unconfirmed and does not count toward path completion')
    elseif cmd == 'auto' or cmd == 'notify' then
        local choice = (...)
        local field = cmd == 'auto' and 'auto' or 'notify'
        if choice == 'on' or choice == 'off' then settings[field] = choice == 'on' else settings[field] = not settings[field] end
        config.save(settings); state.dirty = true
        if cmd == 'auto' then
            msg('auto ticks ' .. (settings.auto and 'on' or 'off') .. (settings.auto and '; click a step or //sg undo <n> to take one back' or '; nothing ticks itself, tick by hand (click a step or //sg done <n>). The evidence log is still written.'))
        else
            msg('chat line when a step ticks itself: ' .. (settings.notify and 'on' or 'off'))
        end
    elseif cmd == 'welcome' then
        show_welcome()
    elseif cmd == 'layout' then
        local choice = (...)
        if choice == 'one' or choice == 'two' then settings.layout = choice else settings.layout = settings.layout == 'two' and 'one' or 'two' end
        state.tab = 'steps'; config.save(settings); state.dirty = true
        msg('layout: ' .. (settings.layout == 'two' and 'two boxes (list and steps)' or 'one box with a Steps | List tab strip'))
    elseif cmd == 'compact' then
        local choice = (...)
        if choice == 'on' or choice == 'off' then settings.compact = choice == 'on' else settings.compact = not settings.compact end
        config.save(settings); state.dirty = true
        msg('compact mode ' .. (settings.compact and 'on (only the NOW line; click the expand line or //sg compact off)' or 'off'))
    elseif cmd == 'gather' then
        local choice = (...)
        if choice == 'on' or choice == 'off' then settings.gather = choice == 'on' else settings.gather = not settings.gather end
        config.save(settings); state.dirty = true
        msg('GATHER counters ' .. (settings.gather and 'on (bag counts and auto ticks on gather steps)' or 'off (steps show the wiki text only, nothing ticks from the bag)'))
    elseif cmd == 'replay' then
        replay_evidence(false)
    elseif cmd == 'details' then
        local choice = (...)
        if choice == 'on' or choice == 'off' then settings.details = choice == 'on' else settings.details = not settings.details end
        config.save(settings); state.dirty = true
        msg('details box (start, level, goal, requirements) ' .. (settings.details and 'open' or 'closed') .. '; click the Details line or //sg details')
    elseif cmd == 'box' then
        local which, arg = (...), select(2, ...)
        if which ~= 'list' and which ~= 'steps' then which, arg = nil, which end   -- //sg box [on|off] = both boxes; //sg box list|steps [on|off] = one
        local function flip(current) if arg == 'on' then return true elseif arg == 'off' then return false else return not current end end
        if which == 'list' then settings.show_list = flip(settings.show_list)
        elseif which == 'steps' then settings.show_box = flip(settings.show_box)
        else local on = flip(settings.show_box); settings.show_box = on; settings.show_list = on end
        config.save(settings)
        msg(('boxes: steps %s, list %s'):format(settings.show_box and 'on' or 'off', settings.show_list and 'on' or 'off'))
    elseif cmd == 'list' then
        local names = {}
        for name in pairs(tracks) do names[#names + 1] = name end
        table.sort(names)
        msg('tracks: ' .. table.concat(names, ', ') .. '  (now: ' .. tostring(settings.track) .. ')')
    elseif cmd == 'open' then
        if not track then msg('no track loaded'); return end
        local index = tonumber(rest) or core.find(track, rest)
        if not (index and track.missions[index]) then msg('//sg open <number or name>: see the list view (//sg view list)'); return end
        state.preview, state.page, state.scroll, state.tab = index, 0, nil, 'steps'
        state.dirty = true
        msg('browsing ' .. track.missions[index].name .. '; //sg here returns to your position')
    elseif cmd == 'here' then
        state.preview, state.page, state.scroll = nil, 0, nil; state.dirty = true
        msg('showing your position')
    elseif cmd == 'track' then
        if tracks[rest] then settings.track = rest; config.save(settings); state.dirty = true; msg('showing ' .. rest)
        else msg('no such track; //sg list') end
    elseif cmd == 'at' then
        if not track then msg('no track loaded'); return end
        local index = core.find(track, rest)
        if not index then msg('no mission matching "' .. rest .. '" in ' .. track.storyline); return end
        local value = track_state(slug).value
        state.anchors[track.storyline] = {node = track.missions[index].id, value = value}
        save(); state.dirty = true
        msg(('confirmed: %s is on %s (game value %s)'):format(state.char or '?', track.missions[index].name, tostring(value)))
    elseif cmd == 'done' or cmd == 'undo' then
        local entry = track and state.shown_index and track.missions[state.shown_index]
        local arg = (...)
        if cmd == 'undo' and arg == 'last' then   -- the last step that ticked itself: a one-word way back from a wrong auto tick
            local last = state.last_auto
            entry = nil
            for _, m in ipairs(track and track.missions or {}) do if last and m.id == last.id then entry = m end end
            if not entry then msg('nothing to undo: no step has ticked itself in this session'); return end
            mark_step(entry, last.key, 'undo'); state.last_auto = nil
            return
        end
        local n = tonumber(arg)
        local key = n and state.keys and state.keys[n]
        if not (key and entry) then msg('no step ' .. tostring(n) .. ' in the box'); return end
        mark_step(entry, key, cmd)
    elseif cmd == 'reset' then
        local entry = track and state.shown_index and track.missions[state.shown_index]
        if entry then
            local function keys_of(set) local t = {} for k in pairs(set or {}) do t[#t + 1] = k end table.sort(t) return table.concat(t, ',') end
            record('reset', ('done=%s auto=%s inferred=%s vetoed=%s'):format(keys_of(state.done[entry.id]), keys_of(state.auto[entry.id]), keys_of(state.inferred[entry.id]), keys_of(state.vetoed[entry.id])))
            state.done[entry.id], state.auto[entry.id], state.inferred[entry.id], state.vetoed[entry.id] = nil, nil, nil, nil; save(); state.dirty = true; msg('cleared the ticks for ' .. entry.name) end
    elseif cmd == 'page' then
        local want = tonumber((...))
        state.scroll = nil
        state.page = want and (want - 1) or (state.page + 1)
        if state.page >= (state.pages or 1) or state.page < 0 then state.page = 0 end
        state.dirty = true
        msg(('page %d of %d'):format(state.page + 1, state.pages or 1))
    elseif cmd == 'path' then
        local entry = track and state.shown_index and track.missions[state.shown_index]
        local spec = entry and branches[entry.id]
        local n = tonumber((...))
        if not spec then msg('this mission has no parallel paths'); return end
        if not (n and spec.paths[n]) then msg('//sg path <1-' .. #spec.paths .. '>: ' .. spec.paths[1].name .. (spec.paths[2] and (' / ' .. spec.paths[2].name) or '')); return end
        state.focus[entry.id] = n; state.scroll = nil; state.dirty = true; save()
        msg('showing path ' .. n .. ': ' .. spec.paths[n].name)
    elseif cmd == 'ahead' then
        if not (track and state.index) then msg('position unknown; //sg at <mission>'); return end
        local count = math.max(1, math.min(tonumber((...)) or 5, 40))
        local last = math.min(state.index + count, #track.missions)
        if last <= state.index then msg('nothing after this in the track'); return end
        for i = state.index + 1, last do
            local e = track.missions[i]
            msg(('%d. %s%s%s%s'):format(i, e.name, e.kind == 'quest' and ' (quest)' or '', e.start and (' - ' .. e.start) or '', e.level and (' [Lv ' .. e.level .. ']') or ''))
        end
        if last < #track.missions then msg(('... %d more after that; //sg ahead %d'):format(#track.missions - last, #track.missions - state.index)) end
    elseif cmd == 'next' then
        local entry = track and state.index and track.missions[state.index + 1]
        msg(entry and ('next: ' .. entry.name .. (entry.start and (' - ' .. entry.start) or '')) or 'nothing after this in the track')
    elseif cmd == 'version' then
        msg('version ' .. _addon.version)
    elseif cmd == 'status' then
        local index, source, note = nil, nil, 'no track'
        if track then index, source, note = core.position(track, track_state(slug)) end
        msg(('read-only; track %s; %s'):format(tostring(settings.track), index and (track.missions[index].name .. ' (' .. tostring(source) .. ')') or tostring(note)))
    else
        help()
    end
end))

windower.register_event('load', guarded('load', function()
    load_tracks()
    local count = 0
    for _ in pairs(tracks) do count = count + 1 end
    msg(('loaded version %s; read-only (sends nothing); %d track(s); //sg help'):format(_addon.version, count))
    msg('wording suggestions ' .. (settings.inferred_triggers and 'on' or 'off') .. '; //sg infer on|off; [~] is unconfirmed')
    if count == 0 then msg('no tracks found in storyguide/tracks: run tools/build-storyguide.py and deploy') end
    if not settings.welcomed then show_welcome() end
end))
