--heapstat: one line every 10 minutes with this addon's own Lua heap, so a Lua leak can be told apart from native growth (idea #219).
--
--   package.path = (windower.windower_path or '') .. 'addons/boxtheme/?.lua;' .. package.path
--   pcall(function() require('heapstat').start() end)
--
-- Every addon runs in its own Lua state, so each one has to report for itself. The file is <addon>/data/heap.csv:
--   time,char,raw_kb,live_kb,reason
-- raw_kb is the heap as it is (garbage included); live_kb is measured right after a full collection, so it is what the addon
-- really holds. A live_kb that keeps climbing across hours is a leak in that addon; a flat live_kb with a climbing client
-- (see PadRelay's ALIVE line, or //memwatch) points at native memory instead. tools/heap-report.py reads every addon's file.
-- Pure Lua: no FFI, no game memory, and nothing touches the game for the first minute after load.
local M = {}

local INTERVAL = 600        -- seconds between samples
local FIRST_AFTER = 60      -- seconds after load before the first one (the client is still loading)
local MAX_BYTES = 200 * 1024

local state = {started = false, t0 = 0, last = 0, path = nil}

local function addon_name()
    local a = rawget(_G, '_addon')
    return a and a.name or 'unknown'
end

local function char_name()
    local ok, p = pcall(function() return windower.ffxi.get_player() end)
    return ok and p and p.name or ''
end

local function open_path()
    if state.path then return state.path end
    local dir = windower.addon_path .. 'data/'
    if not windower.dir_exists(dir) then windower.create_dir(dir) end
    state.path = dir .. 'heap.csv'
    return state.path
end

-- One row now. Public so a command can ask for it.
function M.sample(reason)
    local raw = collectgarbage('count')
    collectgarbage('collect')
    local live = collectgarbage('count')
    local path = open_path()
    local f = io.open(path, 'a')
    if not f then return nil end
    local size = f:seek('end')
    if size == 0 then f:write('time,char,raw_kb,live_kb,reason\n') end
    f:write(string.format('%s,%s,%.0f,%.0f,%s\n', os.date('%Y-%m-%d %H:%M:%S'), char_name(), raw, live, reason or 'tick'))
    f:close()
    if size > MAX_BYTES then   -- keep one old file, so the series never grows without bound
        local old = path:gsub('heap%.csv$', 'heap.old.csv')
        os.remove(old)
        os.rename(path, old)
    end
    return live
end

-- Start the 10-minute series for the calling addon. Safe to call twice (a second call does nothing).
function M.start()
    if state.started then return end
    state.started = true
    state.t0 = os.time()
    state.last = state.t0 + FIRST_AFTER - INTERVAL   -- first sample FIRST_AFTER seconds after load
    windower.register_event('prerender', function()
        local now = os.time()
        if now - state.last < INTERVAL then return end
        state.last = now
        pcall(M.sample, 'tick')
    end)
    -- A zone change is where the client's memory steps up; one extra row per zone shows whether this addon moved with it.
    windower.register_event('zone change', function()
        local now = os.time()
        if now - state.t0 < FIRST_AFTER or now - (state.zoned or 0) < 60 then return end
        state.zoned = now
        pcall(M.sample, 'zone')
    end)
end

return M
