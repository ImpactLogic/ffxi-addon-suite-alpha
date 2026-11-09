--Battle Lines: a read-only combat meter for FFXI. It reads the action packets the client already
--receives and sends nothing (except //bl report, which types one chat line when you ask for it).
--
--Segments (current fight / previous fights / overall), four views (damage, taken, healing, deaths) picked from a tab row,
--one bar per party member with amount, effective rate and share, click a bar for that player's ability breakdown (a death
--for its last hits), click again to go back, right-click to cycle the segment. The engine is core.lua (pure Lua, tested
--offline by tools/test-battlelines.lua); this file is the Windower side: party lookup, the box, clicks, commands, and
--data/fights.tsv (each finished fight, for later analysis; tools/battlelines_snap.py turns it into PNG + HTML reports).
--
--Who is counted: you, your party, alliance and trusts, and their pets (credited to the owner). Only what the client
--sees: people out of range or in another zone are missing. Mob HP is not shown (the game only exposes HP%).

_addon.name = 'battlelines'
_addon.author = 'ImpactLogic'
_addon.version = '0.7.3'   -- bump on every change that reaches the game
_addon.commands = {'battlelines', 'bl', 'det'}   -- det is a compatibility alias

config = require('config')
texts = require('texts')
res = require('resources')
require('pack')

local core = require('core')
local emodel = require('enmity_model')

local defaults = {
    log_max_kb = 128,
    show_box = true,
    mode = 'current',        -- current | overall | last | <n>
    view = 'damage',         -- damage | taken | healing | deaths | enmity
    dps = 'fight',           -- fight (whole fight) | effective (event-window burst rate)
    stats = {damage = 'total', taken = 'total', healing = 'total'},
    show_damage_mix = false, -- optional WS / skillchain / other lines below damage bars
    rows = 8,
    enmity_damage = false,    -- Enmity tab: add a rough damage-based CE/VE estimate
    enmity_coefficient = 0, -- CE per damage point; //bl coefficient
    idle = 10,               -- seconds without activity that end a fight
    max_fights = 10,
    save_fights = true,      -- append each finished fight to data/fights.tsv
    box = {pos = {x = 20, y = 200}, text = {size = 10, font = 'Consolas'},
           bg = {alpha = 170}, flags = {draggable = true}},
}
local settings = config.load(defaults)
-- Themed background from addons/boxtheme, created before the box so the text draws on top (optional).
package.path = (windower.windower_path or '') .. 'addons/boxtheme/?.lua;' .. package.path
local panel_ok, panel = pcall(function() return require('boxpanel').new('battlelines', {bars = true, close_cmd = 'bl box off'}) end)
if not panel_ok then panel = nil end
local box = texts.new('', settings.box, settings)
if panel then panel:attach(box, settings) end

local DATA = windower.addon_path .. 'data/'
local NL = string.char(10)

local function log_line(text)
    if not windower.dir_exists(DATA) then windower.create_dir(DATA) end
    local f = io.open(DATA .. 'battlelines.log', 'a')
    if not f then return end
    if f:seek('end') > (tonumber(settings.log_max_kb) or 128) * 1024 then
        f:close()
        f = io.open(DATA .. 'battlelines.log', 'w')
        if not f then return end
    end
    f:write(os.date('[%m-%d %H:%M:%S] ') .. text .. NL)
    f:close()
end

local function msg(text)
    windower.add_to_chat(207, 'Battle Lines: ' .. text)
    log_line(text)
end

local function guarded(label, fn)
    return function(...)
        local args, n = {...}, select('#', ...)
        local ok, err = xpcall(function() return fn(unpack(args, 1, n)) end, debug.traceback)
        if not ok then
            log_line('ERROR in ' .. label .. ': ' .. tostring(err))
            windower.add_to_chat(167, 'Battle Lines error in ' .. label .. ' - see battlelines/data/battlelines.log')
        end
    end
end

-------------------------------------------------------------------------------
-- State
-------------------------------------------------------------------------------
local FIGHTS_MAX_KB = 1024
local function save_fight(seg)
    if not settings.save_fights then return end
    if not windower.dir_exists(DATA) then windower.create_dir(DATA) end
    local path = DATA .. 'fights.tsv'
    local f = io.open(path, 'a')
    if not f then return end
    if f:seek('end') > FIGHTS_MAX_KB * 1024 then
        f:close()
        os.remove(DATA .. 'fights.old.tsv')
        os.rename(path, DATA .. 'fights.old.tsv')
        f = io.open(path, 'a')
        if not f then return end
    end
    local stamp = os.date('%Y-%m-%d %H:%M:%S')
    for _, line in ipairs(core.tsv_rows(seg)) do f:write(stamp .. '\t' .. line .. NL) end
    f:close()
end

local state = core.new({idle = settings.idle, max_fights = settings.max_fights, on_close = save_fight})
local estate = emodel.new()   -- Enmity tab: rough CE/VE per enemy, never actual hate
local view = {kind = 'list'}   -- list | options | player | death
local rendered = {ids = {}, tabs = {}}   -- what the last render drew, for clicks
local VIEWS = {{'damage', 'Damage'}, {'taken', 'Taken'}, {'healing', 'Healing'}, {'deaths', 'Deaths'}, {'enmity', 'Enmity'}}

-------------------------------------------------------------------------------
-- Who counts: members by mob id, their pets credited to the owner. Shape from combatlog: get_party() members are
-- member.mob.id, pets via mob.pet_index. Cached for 2 s: action packets arrive many times a second.
-------------------------------------------------------------------------------
local cache = {t = -100, owner = {}, member = {}, name = {}}
local function refresh_party()
    if os.clock() - cache.t < 2 then return end
    local owner, member, name = {}, {}, {}
    local ok, party = pcall(windower.ffxi.get_party)
    if ok and type(party) == 'table' then
        for _, m in pairs(party) do
            if type(m) == 'table' and type(m.mob) == 'table' and m.mob.id then
                owner[m.mob.id] = m.mob.id
                member[m.mob.id] = m.mob.id
                name[m.mob.id] = m.name or m.mob.name
                local pi = m.mob.pet_index
                if pi and pi > 0 then
                    local okp, pet = pcall(windower.ffxi.get_mob_by_index, pi)
                    if okp and type(pet) == 'table' and pet.id then owner[pet.id] = m.mob.id end
                end
            end
        end
    end
    local me = windower.ffxi.get_player()
    if me and me.id then owner[me.id] = me.id member[me.id] = me.id name[me.id] = me.name end
    cache.t, cache.owner, cache.member, cache.name, cache.me = os.clock(), owner, member, name, me and me.id or nil
end

local function name_of(id)
    if cache.name[id] then return cache.name[id] end
    local ok, mob = pcall(windower.ffxi.get_mob_by_id, id)
    return ok and type(mob) == 'table' and mob.name or nil
end

local ABILITY_TABLES = {[3] = 'weapon_skills', [4] = 'spells', [5] = 'items', [6] = 'job_abilities', [11] = 'monster_abilities', [13] = 'job_abilities'}
local itemname_ok, itemname = pcall(require, 'itemname')   -- item names without loading the 18.7 MB res.items table
local function ability_name(cat, param)
    if cat == 5 and itemname_ok then
        local n = itemname.name(param, function() return res.items end)
        return n or ('#' .. tostring(param))
    end
    local t = res[ABILITY_TABLES[cat] or '']
    local e = t and t[param]
    return e and e.en or ('#' .. tostring(param))
end

local ctx = {
    owner = function(id) return cache.owner[id] end,
    member = function(id) return cache.member[id] end,
    enemy = function(id) return cache.owner[id] == nil end,
    self = function(id) return id ~= nil and id == cache.me end,
    name = name_of,
    ability = ability_name,
}

local on_action = guarded('action', function(data)
    local ok, act = pcall(windower.packets.parse_action, data)
    if not ok or type(act) ~= 'table' then return end
    refresh_party()
    core.add_action(state, act, os.clock(), ctx)
    emodel.action(estate, act, os.time(), ctx,
        {damage = settings.enmity_damage, coefficient = tonumber(settings.enmity_coefficient) or 0})
end)

windower.register_event('incoming chunk', function(id, data)
    if id == 0x028 then on_action(data) end   -- id checked before anything else: chunk events fire on every packet
end)

-------------------------------------------------------------------------------
-- The box
-------------------------------------------------------------------------------
local PALETTE = {{214, 170, 70}, {90, 160, 220}, {120, 200, 120}, {205, 110, 110}, {170, 130, 210}, {90, 200, 200}, {220, 150, 90}, {150, 150, 170}}
local VIEW_COLOUR = {damage = nil, taken = {205, 110, 110}, healing = {120, 200, 120}}
local ME_COLOUR = {236, 192, 98}
local FILL_ALPHA = 120
local LABEL = {damage = 'Damage Done', taken = 'Damage Taken', healing = 'Healing', deaths = 'Deaths', enmity = 'Enmity (estimated)'}
local STAT_LABEL = {total = 'Total', rate = 'Rate', share = 'Share', events = 'Events', average = 'Average', max = 'Max Hit', crits = 'Crits', bursts = 'Bursts'}

local function current_stat()
    local choices = core.STATS[settings.view] or {'total'}
    local selected = settings.stats and settings.stats[settings.view] or 'total'
    for _, name in ipairs(choices) do if selected == name then return selected end end
    return 'total'
end

local function rate_label()
    return settings.dps == 'fight' and 'Fight rate' or 'Burst rate'
end

local function metric(r, stat)
    if stat == 'rate' then return core.big(r.dps) .. '/s' end
    if stat == 'share' then return r.pct > 0 and r.pct < .005 and '<1%' or ('%d%%'):format(math.floor(r.pct * 100 + .5)) end
    return core.big(r.value)
end

local function mix_line(m, indent)
    local function pct(n) return m.total > 0 and math.floor(n / m.total * 100 + .5) or 0 end
    return ('%sWS %s (%d%%)  SC %s (%d%%)  Other %s (%d%%)'):format(indent or '',
        core.big(m.ws), pct(m.ws), core.big(m.sc), pct(m.sc), core.big(m.other), pct(m.other))
end

local function segment() return core.pick(state, settings.mode) end

local function tab_line()
    local parts, tabs, at = {}, {}, 1
    for _, v in ipairs(VIEWS) do
        local text = (view.kind ~= 'options' and settings.view == v[1]) and ('[*' .. v[2] .. ']') or ('[' .. v[2] .. ']')
        tabs[#tabs + 1] = {from = at, to = at + #text - 1, view = v[1]}
        parts[#parts + 1] = text
        at = at + #text + 1
    end
    local option = view.kind == 'options' and '[*Options]' or '[Options]'
    tabs[#tabs + 1] = {from = at, to = at + #option - 1, view = 'options'}
    parts[#parts + 1] = option
    return table.concat(parts, ' '), tabs
end

local function trunc(text, n) if #text > n then return text:sub(1, n) end return text end

local function enmity_mob(now)
    local ok, sel = pcall(windower.ffxi.get_mob_by_target, 't')
    if ok and type(sel) == 'table' and sel.id and estate.mobs[sel.id] then return sel.id end
    local best, latest = nil, -1
    for id, mob in pairs(estate.mobs) do
        if mob.last > latest and now - mob.last < 15 then best, latest = id, mob.last end
    end
    return best
end

-- Enmity tab: modelled CE/VE per party member for the targeted (or latest active) enemy. Estimate only.
local function render_enmity(my_id)
    local now = os.time()
    local lines, bars = {}, {}
    local id = enmity_mob(now)
    lines[1] = 'Battle Lines  Enmity (estimated, not real hate)'
    local tabs
    lines[2], tabs = tab_line()
    rendered = {ids = {}, tabs = tabs}
    if not id then
        lines[3] = 'Target an enemy in a fight; nothing modelled yet'
        return lines, bars
    end
    local rows, mob = emodel.rows(estate, id, now)
    local observed = mob.observed and (mob.observed.kind == 'acted on'
        and ('Last acted on: ' .. (mob.observed.name or ('#' .. mob.observed.id)))
        or 'Last action: multiple targets') or 'Last target: unseen'
    lines[3] = trunc(mob.name, 22) .. '  ' .. observed
    lines[4] = '#  Player           CE     VE  Total'
    local unknown = 0
    for i, r in ipairs(rows) do
        unknown = unknown + r.unknown
        if i <= settings.rows then
            lines[#lines + 1] = ('%2d %-12s %6d %6d %6d'):format(i, trunc(r.name, 12),
                math.floor(r.ce + .5), math.floor(r.ve + .5), math.floor(r.total + .5))
            local c = (r.id == my_id) and ME_COLOUR or PALETTE[(i - 1) % #PALETTE + 1]
            bars[#bars + 1] = {line = #lines, frac = r.frac, fill = true, rgba = {c[1], c[2], c[3], FILL_ALPHA}}
        end
    end
    for _, s in ipairs(mob.switches or {}) do
        lines[#lines + 1] = ('Switch %ds ago: %s -> %s'):format(math.floor(now - s.at), trunc(s.from, 10), trunc(s.to, 10))
    end
    lines[#lines + 1] = ('Unmodelled: %d  Enemy packets: %d  Damage %s @ %.2f'):format(unknown, mob.packet_count,
        settings.enmity_damage and 'on' or 'off', tonumber(settings.enmity_coefficient) or 0)
    return lines, bars
end

local function render()
    local seg = segment()
    local me = windower.ffxi.get_player()
    local my_id = me and me.id
    local lines, bars = {}, {}
    if settings.view == 'enmity' and view.kind == 'list' then return render_enmity(my_id) end
    if not seg and view.kind ~= 'options' then
        lines[1] = 'Battle Lines  no fights yet'
        rendered = {ids = {}, tabs = {}}
        return lines, bars
    end
    local tag = seg and (seg.name == 'Overall' and 'Overall' or core.label(seg)) or 'No fight'
    local running = seg and seg == state.current and core.in_fight(state, os.clock())
    local view_name = settings.view
    local head = ('Battle Lines  %s  %s%s'):format(tag, core.clock(core.duration(seg)), running and '' or ' (done)')

    if view.kind == 'options' then
        lines[1] = 'Battle Lines  Options for ' .. LABEL[view_name]
        lines[2], rendered.tabs = tab_line()
        lines[3] = 'Click a setting to change it:'
        lines[4] = '[Rate basis]  ' .. rate_label() .. '  (fight or action time)'
        lines[5] = view_name == 'deaths' and 'Primary stat: Death events (fixed)' or
            (view_name == 'enmity' and 'Enmity: estimated CE+VE; //bl coefficient, //bl enmity damage on|off' or 'Primary stat (sorts bars):')
        rendered.ids = {[4] = {option = 'rate'}}
        rendered.options = {}
        if view_name ~= 'deaths' and core.STATS[view_name] then
            local choices = core.STATS[view_name]
            for i, name in ipairs(choices) do
                local line = 6 + math.floor((i - 1) / 4)
                local label = (current_stat() == name and '[*' or '[') .. STAT_LABEL[name] .. ']'
                local from = lines[line] and #lines[line] + 2 or 1
                lines[line] = (lines[line] and lines[line] .. ' ' or '') .. label
                rendered.options[line] = rendered.options[line] or {}
                rendered.options[line][#rendered.options[line] + 1] = {from = from, to = from + #label - 1, stat = name}
            end
        end
        if view_name == 'damage' then
            local line = #lines + 1
            lines[line] = '[Damage mix]  ' .. (settings.show_damage_mix and 'On' or 'Off') .. '  (WS / SC / Other below bars)'
            rendered.ids[line] = {option = 'mix'}
        end
        lines[#lines + 1] = 'Preferences saved; right-click changes fight.'
        return lines, bars
    end

    -- Sub-views first.
    if view.kind == 'player' and view_name ~= 'deaths' then
        local rows, p = core.breakdown(seg, view.id, view_name)
        if not p then view = {kind = 'list'} return render() end
        lines[1] = ('%s  %s  %s'):format(trunc(p.name, 12), core.big(p.total), view_name)
        if view_name == 'damage' then lines[2] = mix_line(core.damage_mix(seg, view.id)) end
        local c = VIEW_COLOUR[view_name] or {90, 160, 220}
        for i, r in ipairs(rows) do
            if i > settings.rows then break end
            lines[#lines + 1] = ('%-26s %6s %3d%% x%-3d avg %s'):format(trunc(r.key, 26), core.big(r.total), math.floor(r.pct * 100 + 0.5), r.n, core.big(r.avg))
            bars[#bars + 1] = {line = #lines, frac = r.frac, fill = true, rgba = {c[1], c[2], c[3], FILL_ALPHA}}
        end
        rendered = {ids = {}, tabs = {}}
        return lines, bars
    end
    if view.kind == 'death' then
        local d = core.deaths(seg)[view.index]
        if not d then view = {kind = 'list'} return render() end
        lines[1] = ('%s died at %s%s'):format(trunc(d.name, 12), core.clock(d.at), d.killer and (' to ' .. trunc(d.killer, 14)) or '')
        for i = #d.recent, 1, -1 do
            if #lines > settings.rows then break end
            local h = d.recent[i]
            lines[#lines + 1] = ('-%4.1fs  %-20s %6s'):format(math.max(0, (seg.start or 0) + d.at - h.t), trunc(h.key, 20), core.big(h.amount))
        end
        if #lines == 1 then lines[2] = '(no hits recorded before it)' end
        rendered = {ids = {}, tabs = {}}
        return lines, bars
    end

    -- List views.
    local tabs
    if view_name == 'deaths' then
        lines[1] = head .. ('  %d deaths'):format(#core.deaths(seg))
    else
        lines[1] = head .. '  ' .. LABEL[view_name] .. ' ' .. core.big(core.total(seg, view_name))
    end
    lines[2], tabs = tab_line()
    local ids = {}
    if view_name == 'deaths' then
        lines[3] = '#  Player        Time  Killer'
        for i, d in ipairs(core.deaths(seg)) do
            if i > settings.rows then break end
            lines[#lines + 1] = ('%2d %-12s %5s  %s'):format(i, trunc(d.name, 12), core.clock(d.at), d.killer and trunc(d.killer, 16) or '')
            ids[#lines] = {death = i}
        end
        if #core.deaths(seg) == 0 then lines[#lines + 1] = '(nobody has died)' end
    else
        local stat = current_stat()
        lines[3] = stat == 'total' and ('#  Player        Total  ' .. rate_label() .. '  Share') or
            ('#  Player        ' .. STAT_LABEL[stat] .. '  Total  Share')
        local rows = core.rows(seg, settings.dps, view_name, stat)
        for i, r in ipairs(rows) do
            if i > settings.rows then break end
            if stat == 'total' then
                lines[#lines + 1] = ('%2d %-12s %6s %7s %4s'):format(i, trunc(r.name, 12), core.big(r.total), core.big(r.dps) .. '/s', metric(r, 'share'))
            else
                lines[#lines + 1] = ('%2d %-12s %7s %6s %4s'):format(i, trunc(r.name, 12), metric(r, stat), core.big(r.total), metric(r, 'share'))
            end
            local c = (r.id == my_id) and ME_COLOUR or VIEW_COLOUR[view_name] or PALETTE[(i - 1) % #PALETTE + 1]
            bars[#bars + 1] = {line = #lines, frac = r.frac, fill = true, rgba = {c[1], c[2], c[3], FILL_ALPHA}}
            ids[#lines] = {player = r.id}
            if view_name == 'damage' and settings.show_damage_mix then
                lines[#lines + 1] = mix_line(core.damage_mix(seg, r.id), '    ')
                ids[#lines] = {player = r.id}
            end
        end
    end
    rendered = {ids = ids, tabs = tabs}
    return lines, bars
end

local last_draw = 0
windower.register_event('prerender', function()
    if os.clock() - last_draw < 0.25 then return end
    last_draw = os.clock()
    local ok, err = pcall(function()
        core.tick(state, os.clock())   -- a fight that has gone quiet moves to the history (and is saved)
        if not settings.show_box then
            if box:visible() then box:hide() end
            return
        end
        local lines, bars = render()
        box:text(table.concat(lines, NL))
        box:show()
        if panel then panel:set_bars(bars) end
    end)
    if not ok then log_line('ERROR in box: ' .. tostring(err)) end
end)

local function cycle_segment()
    local list = core.choices(state)
    local at = 1
    for i, c in ipairs(list) do if c == tostring(settings.mode) then at = i end end
    settings.mode = list[at % #list + 1]
    config.save(settings)
    view = {kind = 'list'}
    msg('showing ' .. settings.mode)
end

local function set_view(name)
    settings.view = name
    config.save(settings)
    view = {kind = 'list'}
end

local function set_stat(name)
    for _, allowed in ipairs(core.STATS[settings.view] or {}) do
        if name == allowed then
            settings.stats = settings.stats or {}
            settings.stats[settings.view] = name
            config.save(settings)
            return true
        end
    end
    return false
end

-- Clicks. Left button: a tab switches the view, a bar opens that player's abilities (a death row its last hits), a click
-- anywhere in a breakdown returns to the list. Right button: cycle current -> last -> 2 -> ... -> overall. The title
-- strip (drag handle and padlock) is left alone, and a press that moved more than 4 px was a drag.
local press = nil
windower.register_event('mouse', function(kind, mx, my)
    if not settings.show_box or not box:visible() then press = nil return end
    local function inside()
        local x, y = box:pos()
        local w, h = box:extents()
        if not w or w <= 0 or mx < x or mx > x + w or my < y or my > y + h then return nil end
        local text = box:text() or ''
        local lines = select(2, text:gsub('\n', '\n')) + 1
        local widest = 0
        for l in (text .. NL):gmatch('([^\n]*)\n') do if #l > widest then widest = #l end end
        return x, y, w, h, lines, widest
    end
    if kind == 1 or kind == 3 then
        press = {x = mx, y = my, right = (kind == 3)}
    elseif (kind == 2 or kind == 4) and press then
        local p = press
        press = nil
        if p.right ~= (kind == 4) then return end
        if math.abs(mx - p.x) > 4 or math.abs(my - p.y) > 4 then return end
        local x, y, w, h, lines, widest = inside()
        if not x then return end
        local line = math.floor((my - y) / (h / lines)) + 1
        if line <= 1 then return end   -- the title line: drag handle / padlock
        if panel and panel:over_control(mx, my) then return end
        if p.right then cycle_segment() return true end
        if line == 2 then
            local col = math.floor((mx - x) / (w / math.max(widest, 1))) + 1
            for _, t in ipairs(rendered.tabs) do
                if col >= t.from and col <= t.to then
                    if t.view == 'options' then view = {kind = 'options'} else set_view(t.view) end
                    return
                end
            end
            return
        end
        if view.kind == 'options' then
            local hit = rendered.ids[line]
            if hit and hit.option == 'rate' then settings.dps = settings.dps == 'fight' and 'effective' or 'fight' config.save(settings)
            elseif hit and hit.option == 'mix' then settings.show_damage_mix = not settings.show_damage_mix config.save(settings)
            else
                local col = math.floor((mx - x) / (w / math.max(widest, 1))) + 1
                for _, option in ipairs(rendered.options[line] or {}) do
                    if col >= option.from and col <= option.to then set_stat(option.stat) break end
                end
            end
            return
        end
        if view.kind ~= 'list' then view = {kind = 'list'} return end
        local hit = rendered.ids[line]
        if hit and hit.player then view = {kind = 'player', id = hit.player}
        elseif hit and hit.death then view = {kind = 'death', index = hit.death} end
    end
end)

-------------------------------------------------------------------------------
-- Commands
-------------------------------------------------------------------------------
local function onoff(a, current)
    if a == 'on' then return true elseif a == 'off' then return false end
    return not current
end

local function report(channel)
    if settings.view == 'enmity' then msg('the Enmity tab is an estimate and is not reported to chat') return end
    local seg = segment()
    if not seg then msg('nothing to report yet') return end
    local parts = {}
    if settings.view == 'deaths' then
        for i, d in ipairs(core.deaths(seg)) do
            if i > 5 then break end
            parts[#parts + 1] = ('%s %s%s'):format(d.name, core.clock(d.at), d.killer and (' to ' .. d.killer) or '')
        end
    else
        for i, r in ipairs(core.rows(seg, settings.dps, settings.view, current_stat())) do
            if i > 5 then break end
            parts[#parts + 1] = ('%d. %s %s (%s/s, %d%%)'):format(i, r.name, core.big(r.total), core.big(r.dps), math.floor(r.pct * 100 + 0.5))
        end
    end
    local line = ('Battle Lines %s %s %s (%s, ranked by %s): %s'):format(core.label(seg), core.clock(core.duration(seg)),
        LABEL[settings.view], rate_label(), current_stat(), table.concat(parts, '  '))
    if channel == 'say' or channel == 'party' or channel == 'linkshell' or channel == 'ls' then
        local cmd = ({say = '/s', party = '/p', linkshell = '/l', ls = '/l'})[channel]
        windower.send_command('input ' .. cmd .. ' ' .. line)
    else
        windower.add_to_chat(207, line)
    end
end

local function find_player(text)
    local seg = segment()
    if not seg or not text then return nil end
    text = text:lower()
    local b = settings.view == 'taken' and seg.taken or (settings.view == 'healing' and seg.healing or seg)
    for id, p in pairs(b.players) do
        if p.name:lower():sub(1, #text) == text then return id end
    end
end

local function handle(cmd, ...)
    cmd = (cmd or 'help'):lower()
    local a = ({...})[1]
    if a then a = a:lower() end
    if cmd == 'version' then
        msg('version ' .. _addon.version)
    elseif cmd == 'box' then
        settings.show_box = onoff(a, settings.show_box)
        config.save(settings)
        msg('box ' .. (settings.show_box and 'ON' or 'OFF'))
    elseif cmd == 'mode' or cmd == 'segment' then
        if a == 'current' or a == 'overall' or a == 'last' or tonumber(a) then
            settings.mode = a
            config.save(settings)
            view = {kind = 'list'}
        end
        msg('showing ' .. tostring(settings.mode) .. '  (current | overall | last | <n> for the n-th previous fight; right-click the box to cycle)')
    elseif cmd == 'next' then
        cycle_segment()
    elseif cmd == 'view' then
        for _, v in ipairs(VIEWS) do if a == v[1] then set_view(a) end end
        msg('view ' .. settings.view .. '  (damage | taken | healing | deaths | enmity)')
    elseif cmd == 'options' then
        view = {kind = 'options'}
        msg('options open in the box; click Rate basis or a Primary stat')
    elseif cmd == 'rate' or cmd == 'dps' then
        if a == 'burst' then a = 'effective' end
        if a == 'effective' or a == 'fight' then settings.dps = a config.save(settings) end
        msg('rate ' .. rate_label() .. '  (fight = whole fight; burst = time between each player\'s actions)')
    elseif cmd == 'stat' then
        if a then set_stat(a) end
        msg('primary stat ' .. current_stat() .. '  (' .. table.concat(core.STATS[settings.view] or {'total'}, ' | ') .. ')')
    elseif cmd == 'mix' then
        settings.show_damage_mix = onoff(a, settings.show_damage_mix)
        config.save(settings)
        msg('damage mix ' .. (settings.show_damage_mix and 'ON' or 'OFF') .. '  (WS / SC / Other below Damage bars)')
    elseif cmd == 'coefficient' then
        local v = tonumber(a)
        if v and v >= 0 and v <= 2 then settings.enmity_coefficient = v config.save(settings) end
        msg(('enmity damage coefficient %.2f CE per damage point (reset clears old totals)'):format(tonumber(settings.enmity_coefficient) or 0))
    elseif cmd == 'enmity' then
        if a == 'damage' then
            settings.enmity_damage = onoff((({...})[2] or ''):lower(), settings.enmity_damage)
            config.save(settings)
        end
        msg('enmity damage estimate ' .. (settings.enmity_damage and 'ON' or 'OFF') .. '  (//bl enmity damage on|off)')
    elseif cmd == 'rows' then
        local v = tonumber(a)
        if v then settings.rows = math.max(1, math.min(20, math.floor(v))) config.save(settings) end
        msg('rows ' .. settings.rows)
    elseif cmd == 'idle' then
        local v = tonumber(a)
        if v then
            settings.idle = math.max(3, v)
            state.idle = settings.idle
            config.save(settings)
        end
        msg('a fight ends after ' .. settings.idle .. ' s without activity')
    elseif cmd == 'save' then
        settings.save_fights = onoff(a, settings.save_fights)
        config.save(settings)
        msg('saving finished fights to data/fights.tsv: ' .. (settings.save_fights and 'ON' or 'OFF'))
    elseif cmd == 'snap' then
        local seg = segment()
        if not seg then
            msg('nothing to snapshot yet')
        elseif seg ~= state.current and seg ~= state.overall then
            msg('that fight is already saved in data/fights.tsv (when it ended)')
        else
            local was = settings.save_fights
            settings.save_fights = true
            save_fight(seg)
            settings.save_fights = was
            msg('saved ' .. core.label(seg) .. ' to data/fights.tsv. On the PC: python tools/battlelines_snap.py  (PNG + HTML report)')
        end
    elseif cmd == 'reset' then
        core.reset(state)
        estate = emodel.new()
        view = {kind = 'list'}
        msg('reset: all fights and enmity totals cleared')
    elseif cmd == 'report' then
        report(a)
    elseif cmd == 'player' or cmd == 'show' then
        local id = find_player(a)
        if id then view = {kind = 'player', id = id} else msg('no player "' .. tostring(a) .. '" in this view') end
    elseif cmd == 'back' or cmd == 'list' then
        view = {kind = 'list'}
    else
        msg('//bl box [on|off] | options | mix [on|off] | view damage|taken|healing|deaths|enmity | coefficient <0..2> | enmity damage [on|off] | stat <name> | rate fight|burst | mode current|overall|last|<n> | next | rows <n> | idle <s> | save [on|off] | snap | reset | report [say|party|ls] | player <name> | back | version')
    end
end

windower.register_event('addon command', guarded('command', handle))

windower.register_event('load', function()
    msg('loaded version ' .. _addon.version .. '  (//bl)  read-only')
end)

-- A different character, or logging out, is a different party: start clean.
windower.register_event('logout', function()
    core.reset(state)
    estate = emodel.new()
    view = {kind = 'list'}
    cache.t = -100
end)

-- Enmity totals describe one zone's fights; start clean on a zone change.
windower.register_event('zone change', function() estate = emodel.new() end)
