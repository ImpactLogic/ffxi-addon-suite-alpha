--template: one-line description of what this addon does. READ-ONLY unless the design says otherwise.
--Copy this folder to addons/<name>/, rename the file to <name>.lua, replace "template" everywhere.

_addon.name = 'template'
_addon.author = 'ImpactLogic'
_addon.version = '0.1.0'   -- bump on every change that reaches the game
_addon.commands = {'template'}

config = require('config')

local defaults = {
    log_max_kb = 256,
    capture = true,   -- record raw evidence (text lines / packets) until the wording is verified
}
local settings = config.load(defaults)

local DATA = windower.addon_path .. 'data/'
local NL = string.char(10)

-------------------------------------------------------------------------------
-- Log + error capture. FFXI chat can't be copied out, and Windower prints Lua errors to its own
-- console, so everything we print and every error also goes to data/template.log.
-------------------------------------------------------------------------------
local function ensure_dir(d)
    if not windower.dir_exists(d) then windower.create_dir(d) end
    return d
end

local function log_line(text)
    local path = ensure_dir(DATA) .. 'template.log'
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
    windower.add_to_chat(207, 'template: ' .. text)
    log_line(text)
end

-- Wrap every event handler / command in this so errors land in the log with a traceback.
-- Exception: code that calls coroutine.sleep must not run inside xpcall.
local function guarded(label, fn)
    return function(...)
        local args, n = {...}, select('#', ...)
        local ok, err = xpcall(function() return fn(unpack(args, 1, n)) end, debug.traceback)
        if not ok then
            log_line('ERROR in ' .. label .. ': ' .. tostring(err))
            windower.add_to_chat(167, 'template error in ' .. label .. ' - see template/data/template.log')
        end
    end
end

-- Per-character data lives under data/<Character>/ (git-ignored).
local function char_dir()
    local player = windower.ffxi.get_player()
    return player and ensure_dir(ensure_dir(DATA) .. player.name .. '/') or nil
end

-------------------------------------------------------------------------------
-- Multi-character safety
--
-- One Windower install, several characters, sometimes logged in at once. Two rules keep an addon
-- honest about who it is looking at:
--
--   1. Never trust a character name cached at load. Compare it with the live one and reset when it
--      differs -- people log out and back in as someone else without reloading the addon.
--   2. Reset the NUMBERS too, not just the name. A baseline, a session total or a "last value seen"
--      carried across a switch produces a wrong number under the new character's name. cqshop logged
--      a false 4,486,608 CP gain this way when the nation changed (IDEAS #13); ambu and combatlog
--      both had the same bug across characters (IDEAS #23).
--
-- state.char is the only place the name lives. Call current_char() before writing anything.
-------------------------------------------------------------------------------
local state = {char = nil}

local function reset_for_character(name)
    -- Wipe every per-character number here. Add to this as the addon grows.
    log_line('character is now ' .. tostring(name) .. ' - per-character state cleared')
end

local function current_char()
    local player = windower.ffxi.get_player()
    local name = player and player.name or nil
    if name ~= state.char then
        state.char = name
        if name then reset_for_character(name) end
    end
    return state.char
end

-------------------------------------------------------------------------------
-- Commands
-------------------------------------------------------------------------------
local function handle(cmd, ...)
    cmd = (cmd or 'help'):lower()
    local a = ({...})[1]
    if cmd == 'version' then
        msg('version ' .. _addon.version)
    elseif cmd == 'capture' then
        if a == 'on' or a == 'off' then settings.capture = (a == 'on') config.save(settings) end
        msg('capture ' .. (settings.capture and 'ON' or 'OFF'))
    else
        msg('version ' .. _addon.version .. '  //template version | capture on|off')
    end
end

windower.register_event('addon command', guarded('command', handle))

windower.register_event('load', function()
    msg('loaded version ' .. _addon.version .. '  (//template)')
    current_char()
end)

-- Logging in as a different character must be picked up. The delay lets the client settle.
windower.register_event('login', function()
    coroutine.schedule(guarded('login', current_char), 5)
end)

-- Clear the name on logout so nothing written afterwards lands under the previous character.
windower.register_event('logout', guarded('logout', function()
    state.char = nil
end))
