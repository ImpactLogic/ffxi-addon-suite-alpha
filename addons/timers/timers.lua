--timers: ability and spell recasts as a themed box with time bars. READ-ONLY: asks Windower for recasts
--and sends nothing. Replaces the closed-source Timers.dll plugin for recasts (buff timers stay in buffbox).
_addon.name = 'timers'
_addon.author = 'ImpactLogic'
_addon.version = '0.1.5'   -- bump on every change that reaches the game
_addon.commands = {'timers', 'tm'}

config = require('config')
texts = require('texts')
res = require('resources')

local core = require('timercore')

local defaults = {
    log_max_kb = 128,
    show_box = true,
    abilities = true,
    spells = true,
    bars = true,
    max_rows = 10,
    box = {pos = {x = 20, y = 420}, text = {size = 10, font = 'Consolas'},
           bg = {alpha = 170}, flags = {draggable = true}},
}
local settings = config.load(defaults)
-- Themed background from addons/boxtheme, created before the box so the text draws on top (optional).
package.path = (windower.windower_path or '') .. 'addons/boxtheme/?.lua;' .. package.path
local panel_ok, panel = pcall(function() return require('boxpanel').new('timers', {bars = true, close_cmd = 'tm box off'}) end)
if not panel_ok then panel = nil end
local box = texts.new('', settings.box, settings)
if panel then panel:attach(box, settings) end

local DATA = windower.addon_path .. 'data/'
local NL = string.char(10)

local function log_line(text)
    if not windower.dir_exists(DATA) then windower.create_dir(DATA) end
    local f = io.open(DATA .. 'timers.log', 'a')
    if not f then return end
    if f:seek('end') > (tonumber(settings.log_max_kb) or 128) * 1024 then
        f:close()
        f = io.open(DATA .. 'timers.log', 'w')
        if not f then return end
    end
    f:write(os.date('[%m-%d %H:%M:%S] ') .. text .. NL)
    f:close()
end

local function msg(text)
    windower.add_to_chat(207, 'timers: ' .. text)
    log_line(text)
end

local function guarded(label, fn)
    return function(...)
        local args, n = {...}, select('#', ...)
        local ok, err = xpcall(function() return fn(unpack(args, 1, n)) end, debug.traceback)
        if not ok then
            log_line('ERROR in ' .. label .. ': ' .. tostring(err))
            windower.add_to_chat(167, 'timers error in ' .. label .. ' - see timers/data/timers.log')
        end
    end
end

local names = {ab = {}, sp = {}}
local names_at = -100
local totals = {}
local seen_raw = {}   -- evidence: first raw value seen per timer, so units can be checked from the log

local function refresh_names(now)
    if now - names_at < 5 then return end
    names_at = now
    local abilities = windower.ffxi.get_abilities()
    names.ab = core.ability_names(abilities and abilities.job_abilities, res.job_abilities)
    names.sp = core.spell_names(windower.ffxi.get_spells(), res.spells)
end

local function refresh()
    local info = windower.ffxi.get_info()
    if not info or not info.logged_in or not settings.show_box then box:hide() return end
    local now = os.clock()
    refresh_names(now)
    local ab = windower.ffxi.get_ability_recasts() or {}
    local sp = windower.ffxi.get_spell_recasts() or {}
    local opts = {abilities = settings.abilities, spells = settings.spells, max_rows = settings.max_rows,
        bars = settings.bars, player = windower.ffxi.get_player()}
    local rows = core.collect(ab, sp, names, opts)
    local live = {}
    for _, r in ipairs(rows) do live[r.key] = r.left end
    core.track(totals, live)
    for id, v in pairs(ab) do
        if v > 0 and not seen_raw['a' .. id] then
            seen_raw['a' .. id] = true
            local name = id == 231 and 'Stratagem charges' or (id == 233 and 'Stratagems menu' or names.ab[id] or '?')
            log_line(('ability recast %s raw %s (%s)'):format(id, v, name))
        end
    end
    for id, v in pairs(sp) do
        if v > 0 and not seen_raw['s' .. id] then seen_raw['s' .. id] = true log_line(('spell recast %s raw %s (%s)'):format(id, v, names.sp[id] or '?')) end
    end
    if #rows == 0 then
        if panel then panel:set_bars({}) end
        box:hide()
        return
    end
    local lines, bars = core.render(rows, totals, opts)
    if panel then panel:set_bars(bars) end
    box:text('timers ' .. _addon.version .. NL .. table.concat(lines, NL))
    box:show()
end

local function toggle(key, a)
    if a == 'on' or a == 'off' then settings[key] = (a == 'on') else settings[key] = not settings[key] end
    config.save(settings)
    refresh()
    local label = key == 'show_box' and 'box' or key
    msg(label .. ' ' .. (settings[key] and 'on' or 'off')
        .. (key == 'show_box' and settings[key] and ' (the box stays hidden until an ability or spell is recasting)' or '')
        .. ((key ~= 'show_box' and key ~= 'bars' and a == nil) and ' (this command flips it; add on or off to set it)' or ''))
end

local function handle(cmd, ...)
    cmd = (cmd or 'help'):lower()
    local a = ({...})[1]
    a = a and a:lower()
    if cmd == 'version' then
        msg('version ' .. _addon.version)
    elseif cmd == 'box' then toggle('show_box', a)
    elseif cmd == 'abilities' then toggle('abilities', a)
    elseif cmd == 'spells' then toggle('spells', a)
    elseif cmd == 'bars' then toggle('bars', a)
    elseif cmd == 'rows' and tonumber(a) then
        settings.max_rows = math.max(1, math.min(30, math.floor(tonumber(a))))
        config.save(settings) refresh()
        msg('rows ' .. settings.max_rows)
    else
        msg('//tm box [on|off] | abilities [on|off] | spells [on|off] | bars [on|off] | rows <n> | version  (read-only; hidden when nothing is recasting)')
    end
end

windower.register_event('addon command', guarded('command', handle))

local last = 0
windower.register_event('prerender', function()
    local now = os.clock()
    if now - last < 0.25 then return end
    last = now
    guarded('refresh', refresh)()
end)

windower.register_event('load', guarded('load', function()
    msg('loaded version ' .. _addon.version .. '  (//tm)  read-only')
end))

windower.register_event('logout', guarded('logout', function() totals = {} seen_raw = {} box:hide() end))
