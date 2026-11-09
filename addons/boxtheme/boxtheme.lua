--boxtheme: picks the background every addon box here draws (idea #57). READ-ONLY: it only writes its own
-- data/themes.txt; each addon's panel (boxpanel.lua) re-reads that file every 3 s.
--   //boxtheme                      list the themes and what each box uses
--   //boxtheme <theme>              every box that has no theme of its own
--   //boxtheme <addon> <theme>      one box ("default" gives it back to the shared theme)
--   //boxtheme lock [addon|all]     lock boxes (no dragging); the padlock in a box's title bar does the same
--   //boxtheme unlock [addon|all]

_addon.name = 'boxtheme'
_addon.author = 'ImpactLogic'
_addon.version = '0.5.7'   -- bump on every change that reaches the game
_addon.commands = {'boxtheme', 'bt'}

package.path = windower.addon_path .. '?.lua;' .. package.path
local P = require('boxpanel')

local DATA = windower.addon_path .. 'data/'
local NL = string.char(10)

local function log_line(text)
    if not windower.dir_exists(DATA) then windower.create_dir(DATA) end
    local f = io.open(DATA .. 'boxtheme.log', 'a')
    if not f then return end
    if f:seek('end') > 64 * 1024 then f:close() f = io.open(DATA .. 'boxtheme.log', 'w') if not f then return end end
    f:write(os.date('[%m-%d %H:%M:%S] ') .. text .. NL)
    f:close()
end

local function msg(text)
    windower.add_to_chat(207, 'boxtheme: ' .. text)
    log_line(text)
end

local function guarded(label, fn)
    return function(...)
        local args, n = {...}, select('#', ...)
        local ok, err = xpcall(function() return fn(unpack(args, 1, n)) end, debug.traceback)
        if not ok then
            log_line('ERROR in ' .. label .. ': ' .. tostring(err))
            windower.add_to_chat(167, 'boxtheme error in ' .. label .. ' - see boxtheme/data/boxtheme.log')
        end
    end
end

local function list()
    local cfg = P.read_config()
    msg(('version %s. Shared theme: %s'):format(_addon.version, cfg.default or (P.DEFAULT .. ' (built in)')))
    for _, name in ipairs(P.ORDER) do msg(('  %-6s %s'):format(name, P.THEMES[name].label)) end
    local own = {}
    for k, v in pairs(cfg.per) do own[#own + 1] = k .. ' ' .. v end
    table.sort(own)
    msg(#own > 0 and ('Own themes: ' .. table.concat(own, ', ')) or 'No box has its own theme.')
    local locks = P.read_locks()
    local locked = {}
    for k, v in pairs(locks.per) do if v then locked[#locked + 1] = k end end
    table.sort(locked)
    msg(locks.all and 'Locked: all boxes' or (#locked > 0 and ('Locked: ' .. table.concat(locked, ', ')) or 'Nothing locked (click the padlock in a title bar).'))
    msg('//boxtheme <theme>  |  //boxtheme <addon> <theme|default>  |  //boxtheme lock|unlock [addon|all]')
    msg('//boxtheme type|accent [addon] <preset|default>  |  preview <addon> <theme>|off|commit')
    msg('Type: inherit, compact, standard, large. Accent: calm, vivid. Preview lasts 60 seconds.')
end

windower.register_event('addon command', guarded('command', function(a, b, c)
    a, b, c = a and a:lower(), b and b:lower(), c and c:lower()
    if not a or a == 'help' or a == 'list' then return list() end
    if a == 'version' then return msg('version ' .. _addon.version) end
    if a == 'type' or a == 'accent' then
        local choices, read = a == 'type' and P.TYPE or P.ACCENTS, a == 'type' and P.read_type or P.read_accent
        local cfg = read()
        local addon, choice = c and b or 'default', c or b
        if not choice then return msg(a .. ': ' .. P.choice_for(cfg, 'default')) end
        if choice == 'default' and addon ~= 'default' then cfg.per[addon] = nil
        elseif choices[choice] then
            if addon == 'default' then cfg.default = choice else cfg.per[addon] = choice end
        else return msg('unknown ' .. a .. ' preset: ' .. choice) end
        if P.save_text(a .. '.txt', P.format_choices(cfg, a)) then msg(a .. ' ' .. addon .. ': ' .. P.choice_for(cfg, addon)) end
        return
    end
    if a == 'preview' then
        if b == 'off' then P.save_text('preview.txt', '') return msg('preview ended') end
        if b == 'commit' then
            local preview = P.read_preview()
            if not preview then return msg('no active preview') end
            local cfg = P.read_config()
            cfg.per[preview.addon] = preview.theme
            if P.save_config(cfg) and P.save_text('preview.txt', '') then msg(preview.addon .. ': kept ' .. preview.theme) end
            return
        end
        if not b or not P.THEMES[c or ''] then return msg('use //boxtheme preview <addon> <theme>, off, or commit') end
        if P.save_text('preview.txt', b .. ' ' .. c .. ' ' .. tostring(os.time() + 60) .. NL) then
            msg(b .. ': previewing ' .. c .. ' for 60 seconds')
        end
        return
    end
    if a == 'lock' or a == 'unlock' then
        local locks = P.read_locks()
        P.set_lock(locks, b, a == 'lock')
        if P.save_locks(locks) then msg(('%s: %s'):format(b or 'all boxes', a == 'lock' and 'locked' or 'unlocked')) end
        return
    end
    local cfg = P.read_config()
    if not b then
        if not P.THEMES[a] then return msg(('no theme "%s" - //boxtheme lists them'):format(a)) end
        cfg.default = a
        if P.save_config(cfg) then msg(('every box: %s (%s)'):format(a, P.THEMES[a].label)) end
        return
    end
    if b == 'default' then
        cfg.per[a] = nil
        if P.save_config(cfg) then msg(('%s: back to the shared theme (%s)'):format(a, cfg.default or P.DEFAULT)) end
        return
    end
    if not P.THEMES[b] then return msg(('no theme "%s" - //boxtheme lists them'):format(b)) end
    cfg.per[a] = b
    if P.save_config(cfg) then msg(('%s: %s'):format(a, b)) end
end))

windower.register_event('load', guarded('load', function()
    msg(('loaded version %s (//boxtheme lists the themes). Boxes switch within 3 s.'):format(_addon.version))
end))
