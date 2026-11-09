--bags: how full each bag is, as bubbles, numbers (68/80) or both. READ-ONLY: it asks Windower for bag
--sizes and sends no packets. Replaces the third-party invtracker; moves stay with stash.
_addon.name = 'bags'
_addon.author = 'ImpactLogic'
_addon.version = '0.2.1'   -- bump on every change that reaches the game
_addon.commands = {'bags'}

config = require('config')
texts = require('texts')

local core = require('bagcore')
local view = require('view')

local defaults = {
    log_max_kb = 128,
    show_box = true,
    layout = 'numbers',     -- numbers | bubbles | both
    numbers = 'frac',       -- frac (68/80) | free (12 free)
    wardrobes = 'sum',      -- sum (one line) | each
    warn = 0.8,             -- amber from this fraction full
    crit = 0.95,            -- red from this fraction full
    warn_free = 5,          -- chat warning when Inventory has this many free slots or fewer (0 = off)
    show = {inventory = true, satchel = true, sack = true, case = true, wardrobe = true,
            safe = false, safe2 = false, storage = false, locker = false},
    box = {pos = {x = 20, y = 200}, text = {size = 10, font = 'Consolas'},
           bg = {alpha = 170}, flags = {draggable = true}},
}
local settings = config.load(defaults)
-- Themed background from addons/boxtheme, created before the box so the text draws on top (optional).
package.path = (windower.windower_path or '') .. 'addons/boxtheme/?.lua;' .. package.path
local panel_ok, panel = pcall(function() return require('boxpanel').new('bags', {close_cmd = 'bags box off'}) end)
if not panel_ok then panel = nil end
local box = texts.new('', settings.box, settings)
if panel then panel:attach(box, settings) end

local DATA = windower.addon_path .. 'data/'
local NL = string.char(10)

local function log_line(text)
    if not windower.dir_exists(DATA) then windower.create_dir(DATA) end
    local f = io.open(DATA .. 'bags.log', 'a')
    if not f then return end
    if f:seek('end') > (tonumber(settings.log_max_kb) or 128) * 1024 then
        f:close()
        f = io.open(DATA .. 'bags.log', 'w')
        if not f then return end
    end
    f:write(os.date('[%m-%d %H:%M:%S] ') .. text .. NL)
    f:close()
end

local function msg(text, colour)
    windower.add_to_chat(colour or 207, 'bags: ' .. text)
    log_line(text)
end

local function guarded(label, fn)
    return function(...)
        local args, n = {...}, select('#', ...)
        local ok, err = xpcall(function() return fn(unpack(args, 1, n)) end, debug.traceback)
        if not ok then
            log_line('ERROR in ' .. label .. ': ' .. tostring(err))
            windower.add_to_chat(167, 'bags error in ' .. label .. ' - see bags/data/bags.log')
        end
    end
end

local prev_free = nil

local function refresh()
    if not windower.ffxi.get_info().logged_in then box:hide() return end
    local infos = {}
    for _, b in ipairs(core.BAGS) do infos[b.id] = windower.ffxi.get_bag_info(b.id) end
    local inv = view.read(infos[0])
    if inv then
        local free = inv.free
        if core.crossed(prev_free, free, settings.warn_free) then
            msg(('Inventory has %d free slot%s'):format(free, free == 1 and '' or 's'), 167)
        end
        prev_free = free
        if panel then panel:set_status(settings.warn_free > 0 and free <= settings.warn_free and 'warning' or 'ready') end
    else
        prev_free = nil
        if panel then panel:set_status('warning') end
    end
    if not settings.show_box then box:hide() return end
    local lines, bars, status
    if settings.layout == 'compact' or settings.layout == 'detailed' then
        lines, bars, status = view.render(infos, settings, core.BAGS)
    else
        lines = core.render(infos, settings)
    end
    if panel then
        for _, bar in ipairs(bars or {}) do bar.line = bar.line + 1 end
        panel:set_bars(bars or {})
        if status then panel:set_status(status) end
    end
    box:text('bags ' .. _addon.version .. NL .. table.concat(lines, NL))
    box:show()
end

local function set_show(key, on)
    for _, b in ipairs(core.BAGS) do
        if b.key == key or (key == 'wardrobe' and b.ward) then
            settings.show[key == 'wardrobe' and 'wardrobe' or b.key] = on
            return true
        end
    end
    return false
end

local function handle(cmd, ...)
    cmd = (cmd or 'help'):lower()
    local a = ({...})[1]
    a = a and a:lower()
    if cmd == 'version' then
        msg('version ' .. _addon.version)
    elseif cmd == 'box' then
        if a == 'on' or a == 'off' then settings.show_box = (a == 'on') else settings.show_box = not settings.show_box end
        config.save(settings)
        refresh()
        msg('box ' .. (settings.show_box and 'on' or 'off'))
    elseif (cmd == 'mode' or cmd == 'layout') and
        (core.LAYOUTS[a or ''] or a == 'compact' or a == 'detailed') then
        settings.layout = a
        config.save(settings) refresh()
        msg('mode ' .. a)
    elseif cmd == 'pos' then
        local x, y = tonumber(a), tonumber(({...})[2])
        if not x or not y then msg('Usage: //bags pos <x> <y>') return end
        box:pos(x,y); settings.box.pos.x=x; settings.box.pos.y=y
        config.save(settings)
    elseif cmd == 'size' then
        local size = tonumber(a)
        if not size or size < 6 or size > 40 then msg('Usage: //bags size <6-40>') return end
        box:size(size); settings.box.text.size=size
        config.save(settings)
    elseif cmd == 'numbers' and (a == 'frac' or a == 'free') then
        settings.numbers = a
        config.save(settings) refresh()
        msg('numbers ' .. a)
    elseif cmd == 'wardrobes' and (a == 'sum' or a == 'each') then
        settings.wardrobes = a
        config.save(settings) refresh()
        msg('wardrobes ' .. a)
    elseif cmd == 'show' or cmd == 'hide' then
        if a and set_show(a, cmd == 'show') then
            config.save(settings) refresh()
            msg(a .. ' ' .. (cmd == 'show' and 'shown' or 'hidden'))
        else
            msg('bags: inventory satchel sack case wardrobe safe safe2 storage locker')
        end
    elseif cmd == 'warn' and tonumber(a) then
        settings.warn_free = math.max(0, math.floor(tonumber(a)))
        config.save(settings)
        msg('warning at ' .. settings.warn_free .. ' free inventory slots (0 = off)')
    else
        msg('//bags box [on|off] | mode bubbles|numbers|both | numbers frac|free | wardrobes sum|each | ' ..
            'layout compact|detailed|numbers|bubbles|both | pos <x> <y> | size <6-40> | ' ..
            'show|hide <bag> | warn <free slots> | version  (read-only)')
    end
end

windower.register_event('addon command', guarded('command', handle))

local last = 0
windower.register_event('prerender', function()
    local now = os.clock()
    if now - last < 1 then return end
    last = now
    guarded('refresh', refresh)()
end)

windower.register_event('load', guarded('load', function()
    msg('loaded version ' .. _addon.version .. '  (layout ' .. settings.layout .. '; //bags layout compact|detailed; //bags help) read-only')
    refresh()
end))

windower.register_event('logout', guarded('logout', function() prev_free = nil box:hide() end))
