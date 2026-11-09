--checkup: one command that says which facts the addons hold are missing or old, and which recorders
--have stopped writing (IDEAS #51 setup checklist, #43 addon health). READ-ONLY: it reads the files
--the other addons write in the Windower addons folder and nothing else; nothing is ever sent.
--The one thing it writes is the master recording switch, boxtheme/data/recording.cfg (//rec on|off).
--
--  setup      facts only an NPC or a menu tells you (Ionis coalitions, merits and job points,
--             currencies, REMA weapons), with how old each one is and what to do when it is stale
--  recorders  whether ffxilogger, combatlog and ffxibazaar have written a file today
--  addons     the version installed, and any ERROR in an addon's log in the last 7 days
--
--On login it prints only what needs doing. What it cannot see: whether an addon is loaded right now
--(a recorder with no file today may just have had nothing to record).
_addon.name = 'checkup'
_addon.author = 'ImpactLogic'
_addon.version = '0.5.9'   -- bump on every change that reaches the game
_addon.commands = {'checkup', 'ck', 'rec', 'setup'}

config = require('config')
texts = require('texts')

res = require('resources')
local core = require('checkcore')
-- Master recording switch (addons/boxtheme/recording.lua): //rec on|off|status [recorder], also //ck rec ...
package.path = (windower.windower_path or '') .. 'addons/boxtheme/?.lua;' .. package.path
local rec_ok, recording = pcall(require, 'recording')
local setup = require('setupcore')
-- charsync's list of what the player still has to do in game (//cs need); optional: without charsync deployed there are no rows.
package.path = (windower.windower_path or '') .. 'addons/charsync/?.lua;' .. package.path
local need_ok, needcore = pcall(require, 'needcore')

local defaults = {
    log_max_kb = 256,
    show_box = false,
    on_login = true,     -- print what needs doing once, after login
    setup_modules = '',  -- ticked //setup modules, comma separated
    setup_asked = false, -- the one-time first-run hint has been shown
    setup_apply_on_login = true,  -- re-apply ticked modules after login (loads their add-ons, shows their boxes)
    depart_low = 5,      -- //ck depart warns when a bag has fewer free slots than this
    depart_manual = '',  -- reminders //ck depart prints as CHECK yourself, comma separated, e.g. 'food,echo drops'
    box = {pos = {x = 20, y = 300}, text = {size = 10, font = 'Consolas'},
           bg = {alpha = 170}, flags = {draggable = true}},
}
local settings = config.load(defaults)
-- Themed background from addons/boxtheme (idea #57), created before the box so the text draws on top.
-- Optional: without boxtheme the box keeps its own flat background.
package.path = (windower.windower_path or '') .. 'addons/boxtheme/?.lua;' .. package.path
local panel_ok, panel = pcall(function() return require('boxpanel').new('checkup') end)
if not panel_ok then panel = nil end
local box = texts.new('', settings.box, settings)
if panel then panel:attach(box, settings) end

local DATA = windower.addon_path .. 'data/'
local ADDONS = windower.addon_path .. '../'
local NL = string.char(10)

local function ensure_dir(d)
    if not windower.dir_exists(d) then windower.create_dir(d) end
    return d
end

local function log_line(text)
    local path = ensure_dir(DATA) .. 'checkup.log'
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

local function msg(text, colour)
    windower.add_to_chat(colour or 207, 'checkup: ' .. text)
    log_line(text)
end

local function guarded(label, fn)
    return function(...)
        local args, n = {...}, select('#', ...)
        local ok, err = xpcall(function() return fn(unpack(args, 1, n)) end, debug.traceback)
        if not ok then
            log_line('ERROR in ' .. label .. ': ' .. tostring(err))
            windower.add_to_chat(167, 'checkup error in ' .. label .. ' - see checkup/data/checkup.log')
        end
    end
end

-- Another addon's file, read whole; nil when it does not exist. Logs are capped at 256 KB by their
-- addons, so reading one whole is cheap.
local function read(rel)
    local f = io.open(ADDONS .. rel, 'r')
    if not f then return nil end
    local text = f:read('*a')
    f:close()
    return text
end

local function char()
    local player = windower.ffxi.get_player()
    return player and player.name or nil
end

local function check(short)
    local name = char()
    if not name then return nil end
    local now = os.time()
    return core.render(core.setup(read, name, now), core.recorders(read, name, now), core.addons(read, now), short)
end

local function colour_of(line)
    if line:match('^ok') or line == 'all set' then return 207 end
    return 167
end

local function refresh_box()
    if not settings.show_box then box:hide() return end
    local lines = check(true)
    if not lines then box:hide() return end
    box:text('checkup ' .. _addon.version .. '  ' .. tostring(char()) .. NL .. table.concat(lines, NL))
    box:show()
end

local function print_lines(lines)
    for _, l in ipairs(lines) do msg(l, colour_of(l)) end
end

-- //setup: modules ticked like check boxes (addons/checkup/packs/*.txt). Recording is never a module (//rec).
local requires_of
local function setup_packs()
    local idx = setup.parse_index(read('checkup/packs/index.txt'))
    local packs = {}
    for _, id in ipairs(idx.modules) do
        local text = read('checkup/packs/' .. id .. '.txt')
        if text then
            local pack = setup.parse_pack(id, text)
            local available = true
            for addon in pairs(setup.needed({pack}, {[id] = true}, requires_of)) do
                if not read(addon .. '/' .. addon .. '.lua') then
                    available = false
                    break
                end
            end
            if available then packs[#packs + 1] = pack end
        end
    end
    return packs, idx
end

local function send(cmd) windower.send_command(cmd) end

-- An add-on that cannot work without another says so: `_addon.requires = 'a;b'` in its main file. //setup loads those too.
requires_of = function(addon)
    return setup.parse_requires(read(addon .. '/' .. addon .. '.lua'))
end

local function apply_plan(plan)
    for _, addon in ipairs(plan.load) do send('lua l ' .. addon) end
    -- Boxes are switched a moment after the loads so the add-on exists when it hears the command.
    coroutine.schedule(function()
        for _, c in ipairs(plan.box_on) do send(c .. ' box on') end
        for _, c in ipairs(plan.box_off) do send(c .. ' box off') end
    end, 3)
end

local function handle_setup(a, b)
    local packs, idx = setup_packs()
    if #packs == 0 then msg('no setup modules found: deploy checkup again') return end
    local ids = {}
    for _, p in ipairs(packs) do ids[#ids + 1] = p.id end
    local ticked = setup.ids_to_set(settings.setup_modules)
    local function save(set) settings.setup_modules = setup.set_to_csv(set, ids) settings.setup_asked = true config.save(settings) end
    local function known(id) for _, x in ipairs(ids) do if x == id then return true end end end
    if a == 'tick' or a == 'untick' then
        if not known(b) then msg('unknown module ' .. tostring(b) .. ' (//setup lists them)') return end
        for _, p in ipairs(packs) do if p.id == b and p.always then msg(b .. ' is always on (passive collection for every player)') return end end
        local after = setup.ids_to_set(settings.setup_modules)
        after[b] = (a == 'tick') or nil
        apply_plan(setup.plan(packs, ticked, after, requires_of))
        save(after)
    elseif a == 'preset' then
        local list = idx.presets[b or '']
        if not list then msg('presets: ' .. (function() local t = {} for k in pairs(idx.presets) do t[#t + 1] = k end table.sort(t) return table.concat(t, ', ') end)()) return end
        for _, id in ipairs(list) do
            if not known(id) then msg('preset needs missing add-ons (see the install guide)') return end
        end
        local after = setup.ids_to_set(table.concat(list, ','))
        apply_plan(setup.plan(packs, ticked, after, requires_of))
        save(after)
    elseif a == 'apply' then
        apply_plan(setup.apply_all(packs, ticked, requires_of))
        msg('applying ticked modules (already-loaded add-ons just reload)')
    elseif a == 'skip' then
        save(ticked)
        msg('ok, nothing changed. //setup any time.')
        return
    end
    msg('setup modules (//setup tick|untick <id>, preset <name>, apply, skip):')
    for _, l in ipairs(setup.render(packs, setup.ids_to_set(settings.setup_modules))) do msg(l) end
    local name = char()
    if need_ok and name then
        local rows = needcore.need(function(file) return read('charsync/data/' .. name .. '/' .. file) end, os.time())
        local lines, todo = needcore.render(rows, true)
        msg(todo == 0 and 'your data: nothing required right now' or ('your data: ' .. todo .. ' thing(s) to do in game (//cs need):'))
        for _, l in ipairs(lines) do msg(l) end
    end
    msg('recording is separate: ' .. (rec_ok and recording.enabled('ffxilogger') and 'ON' or 'OFF') .. ' (//rec on|off). Nothing here turns it on.')
end

local function handle(cmd, ...)
    cmd = (cmd or 'all'):lower()
    local a = ({...})[1]
    if cmd == 'version' then
        msg('version ' .. _addon.version)
    elseif cmd == 'box' then
        if a == 'on' or a == 'off' then settings.show_box = (a == 'on')
        else settings.show_box = not settings.show_box end
        config.save(settings)
        refresh_box()
        msg('box ' .. (settings.show_box and 'on' or 'off'))
    elseif cmd == 'all' or cmd == 'todo' then
        if cmd == 'all' then handle_setup(nil) end   -- bare //setup lands here too (Windower does not pass the alias)
        local lines = check(cmd == 'todo')
        if not lines then msg('not logged in') return end
        print_lines(lines)
        refresh_box()
    elseif cmd == 'setup' or cmd == 'tick' or cmd == 'untick' or cmd == 'preset' or cmd == 'apply' or cmd == 'skip' or cmd == 'list' then
        -- //setup [tick|untick <id> | preset <name> | apply | skip] arrives as cmd = tick|...; //ck setup ... as cmd = setup.
        local a1, a2 = a, ({...})[2]
        if cmd ~= 'setup' then a1, a2 = cmd, a end
        handle_setup(a1, a2)
    elseif cmd == 'rec' or cmd == 'on' or cmd == 'off' or cmd == 'status' then
        -- //rec on|off [recorder] and //rec status arrive here as cmd = on|off|status; //ck rec ... as cmd = rec.
        if not rec_ok then msg('recording.lua missing: deploy boxtheme again') return end
        local rest = {...}
        local verb, who = cmd, a
        if cmd == 'rec' then verb, who = a or 'status', rest[2] end
        if verb == 'on' or verb == 'off' then
            if not recording.set(who, verb == 'on') then msg('could not write recording.cfg') return end
            msg((who or 'all recorders') .. ' ' .. verb .. '. ffxilogger, pricelog and combatlog follow within 10 s; harness needs //lua r harness.')
        end
        print_lines(recording.status())
    elseif cmd == 'addons' then
        local ok, reg = pcall(require, 'registry')
        if not ok or type(reg) ~= 'table' then msg('registry.lua missing: deploy checkup again') return end
        local function installed(name)
            local text = read(name .. '/' .. name .. '.lua')
            return text and text:match("_addon%.version%s*=%s*['\"]([^'\"]+)['\"]") or nil
        end
        print_lines(core.registry(reg, installed, a))
    elseif cmd == 'depart' then
        local name = char()
        if not name then msg('not logged in') return end
        local info = windower.ffxi.get_info()
        local zone = info and info.zone and res.zones[info.zone] and res.zones[info.zone].en or nil
        local bags = {}
        for _, b in ipairs({'inventory', 'satchel', 'sack', 'case'}) do
            local bi = windower.ffxi.get_bag_info(b)
            bags[#bags + 1] = {name = b, count = bi and bi.count, max = bi and bi.max, enabled = bi and bi.enabled}
        end
        local now = os.time()
        local need = {}
        for _, l in ipairs((core.render(core.setup(read, name, now), core.recorders(read, name, now), core.addons(read, now), true))) do
            if not l:match('^ok') and l ~= 'all set' then need[#need + 1] = l end
        end
        print_lines((core.depart({name = name, zone = zone, bags = bags, todo = need,
            manual = (function() local o = {} for w in tostring(settings.depart_manual or ''):gmatch('[^,]+') do o[#o + 1] = (w:gsub('^%s+', ''):gsub('%s+$', '')) end return o end)(), low = settings.depart_low})))
    elseif cmd == 'help' then
        msg('//setup [tick|untick <module>|preset <name>|apply|skip] | //rec on|off|status [recorder] | //checkup [all] | todo | depart | addons [all|automation|word] | box [on|off] | version  -- read-only: reads the other addons\' files')
    else
        msg('unknown command; //checkup help')
    end
end

windower.register_event('addon command', guarded('command', handle))

windower.register_event('load', guarded('load', function()
    msg('loaded version ' .. _addon.version .. '  (//checkup, //ck)  read-only')
    if not settings.setup_asked then
        msg('First time? Type //setup to tick what you want. Recording defaults to OFF; //rec status checks it.')
    end
    refresh_box()
end))

-- After login, once the other addons have had time to write their files.
windower.register_event('login', function()
    coroutine.schedule(guarded('login', function()
        if settings.on_login then
            local lines, todo = check(true)
            -- Only when a setup fact needs doing: right after login no recorder has written yet today.
            if lines and (todo or 0) > 0 then print_lines(lines) end
        end
        if settings.setup_apply_on_login and settings.setup_asked then
            local ok, packs = pcall(setup_packs)
            if ok and #packs > 0 then apply_plan(setup.apply_all(packs, setup.ids_to_set(settings.setup_modules), requires_of)) end
        end
        refresh_box()
    end), 30)
end)

windower.register_event('logout', guarded('logout', function() box:hide() end))
