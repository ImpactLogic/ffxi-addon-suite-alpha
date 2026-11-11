--recording: the one master switch for every evidence recorder (idea: first-run onboarding, 2026-10-17).
--
-- One small file holds the answer, so //rec on|off flips every recorder together
-- (and any recorder that adopts it later) without a reload:
--   <Windower>/addons/boxtheme/data/recording.cfg      (data/ is never touched by deploy.ps1)
--   all=off                    master: on or off
--   combatlog=on               optional per-recorder override; it wins over "all"
-- Missing or unreadable settings leave recording off.
--
-- A recorder asks:   package.path = (windower.windower_path or '') .. 'addons/boxtheme/?.lua;' .. package.path
--                    local recording = require('recording')
--                    if recording.enabled('combatlog') then ... end
-- enabled() re-reads the file at most every 10 seconds, so it is cheap to call per event.
-- Pure Lua, no FFI, no game memory. Read failures fall back to off.
local M = {}

local RECHECK = 10      -- seconds between file reads
local cache = {t = -1e9, all = false, per = {}}
M.path = nil            -- tests set this

local function cfg_path()
    if M.path then return M.path end
    return (windower.windower_path or '') .. 'addons/boxtheme/data/recording.cfg'
end

local function flag(v)
    v = tostring(v or ''):lower()
    if v == 'off' or v == '0' or v == 'false' or v == 'no' then return false end
    if v == 'on' or v == '1' or v == 'true' or v == 'yes' then return true end
    return nil
end

local function load_file()
    local state = {all = false, per = {}}
    local f = io.open(cfg_path(), 'r')
    if f then
        for line in f:lines() do
            local k, v = line:match('^%s*([%w_%-]+)%s*=%s*(%S+)')
            if k then
                k = k:lower()
                local b = flag(v)
                if b ~= nil then
                    if k == 'all' then state.all = b else state.per[k] = b end
                end
            end
        end
        f:close()
    end
    return state
end

local function refresh(force)
    local now = os.time()
    if force or now - cache.t >= RECHECK or now < cache.t then
        local ok, s = pcall(load_file)
        if ok then cache.all, cache.per = s.all, s.per
        else cache.all, cache.per = false, {} end
        cache.t = now
    end
end

-- Is this recorder allowed to write? A per-recorder line wins over "all".
function M.enabled(name)
    refresh(false)
    local own = cache.per[tostring(name or ''):lower()]
    if own ~= nil then return own end
    return cache.all
end

-- Set "all" (name nil) or one recorder; name 'default' clears that override. Returns true when saved.
function M.set(name, on)
    refresh(true)
    local all, per = cache.all, {}
    for k, v in pairs(cache.per) do per[k] = v end
    if name == nil or name == 'all' then
        all = on and true or false
        per = {}      -- "//rec off" means off for everything: drop the overrides
    else
        per[tostring(name):lower()] = on and true or false
    end
    local dir = cfg_path():match('^(.*[/\\])')
    if dir and not windower.dir_exists(dir) then windower.create_dir(dir) end
    local f = io.open(cfg_path(), 'w')
    if not f then return false end
    f:write('all=' .. (all and 'on' or 'off') .. '\n')
    local names = {}
    for k in pairs(per) do names[#names + 1] = k end
    table.sort(names)
    for _, k in ipairs(names) do f:write(k .. '=' .. (per[k] and 'on' or 'off') .. '\n') end
    f:close()
    refresh(true)
    return true
end

-- Lines for //rec status. recorders is a list of names (default: the known evidence recorders).
M.RECORDERS = {'combatlog'}
function M.status(recorders)
    refresh(true)
    local out = {'recording ' .. (cache.all and 'ON' or 'OFF') .. ' (master)'}
    for _, n in ipairs(recorders or M.RECORDERS) do
        local own = cache.per[n]
        out[#out + 1] = ('  %s: %s%s'):format(n, M.enabled(n) and 'on' or 'off', own ~= nil and ' (own setting)' or '')
    end
    return out
end

return M
