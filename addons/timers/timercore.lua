--timercore: pure logic for the timers box (no windower.*), so tools/test-timers.lua can run it offline.
local M = {}

-- Ability recasts come back in seconds. Spell recasts are believed to be 1/60 s ticks (GearSwap divides by
-- 60): UNVERIFIED here, so the addon logs the first raw value of every recast it sees (data/timers.log).
M.SPELL_DIV = 60

function M.fmt(secs)
    secs = math.max(0, math.ceil(secs))
    if secs >= 3600 then return ('%d:%02d:%02d'):format(math.floor(secs / 3600), math.floor(secs % 3600 / 60), secs % 60) end
    return ('%d:%02d'):format(math.floor(secs / 60), secs % 60)
end

-- Longest remaining time seen per timer, to turn "time left" into a bar fraction. Keyed 'a<id>' / 's<id>'.
-- A timer that is gone (ready) is forgotten so the next use starts a new total.
function M.track(totals, live)
    for k in pairs(totals) do if not live[k] then totals[k] = nil end end
    for k, left in pairs(live) do
        if not totals[k] or left > totals[k] then totals[k] = left end
    end
end

-- Scholar stratagems share recast 231. That value is the total time until the pool is full, not the
-- time until one charge; 233 is only the Stratagems menu. A 550-JP SCH gets a 33 s charge instead of 48 s.
function M.stratagem_row(player, recast)
    if not player then return nil end
    local main = player.main_job == 'SCH'
    if not main and player.sub_job ~= 'SCH' then return nil end
    local level = tonumber(main and player.main_job_level or player.sub_job_level) or 0
    if level < 10 then return nil end
    local max = math.min(5, math.floor((level + 10) / 20))
    local spent = main and player.job_points and player.job_points.sch and tonumber(player.job_points.sch.jp_spent) or 0
    local interval = main and max == 5 and spent >= 550 and 33 or (240 / max)
    local remaining = math.max(0, tonumber(recast) or 0)
    local missing = math.min(max, math.ceil(remaining / interval - 1e-9))
    local available = max - missing
    local next_charge = remaining > 0 and (remaining - math.floor((remaining - 1e-9) / interval) * interval) or 0
    local progress = remaining > 0 and (1 - next_charge / interval) or 0
    return {key = 'sch231', name = ('Stratagems %d/%d'):format(available, max), left = next_charge,
        kind = 'ability', stratagems = true, frac = (available + progress) / max}
end

-- ab: {[recast id] = seconds}, sp: {[spell id] = raw ticks}, names: {ab = {[recast id] = name}, sp = {[id] = name}}.
-- Returns rows sorted by time left: {key, name, left, kind}. Unnamed timers are dropped (not ours to show).
function M.collect(ab, sp, names, opts)
    opts = opts or {}
    local rows = {}
    if opts.abilities ~= false then
        for id, left in pairs(ab or {}) do
            local n = names.ab and names.ab[id]
            if id ~= 231 and id ~= 233 and n and left > 0 then
                rows[#rows + 1] = {key = 'a' .. id, name = n, left = left, kind = 'ability'}
            end
        end
        local stratagems = M.stratagem_row(opts.player, ab and ab[231])
        if stratagems then rows[#rows + 1] = stratagems end
    end
    if opts.spells ~= false then
        for id, raw in pairs(sp or {}) do
            local n = names.sp and names.sp[id]
            local left = raw / M.SPELL_DIV
            if n and left > 0 then rows[#rows + 1] = {key = 's' .. id, name = n, left = left, kind = 'spell'} end
        end
    end
    table.sort(rows, function(a, b)
        if a.stratagems or b.stratagems then return a.stratagems and not b.stratagems end
        if a.left ~= b.left then return a.left < b.left end
        return a.name < b.name
    end)
    local max = opts.max_rows or 10
    while #rows > max do table.remove(rows) end
    return rows
end

local COLOURS = {ability = {111, 134, 217, 255}, spell = {201, 165, 90, 255}}

-- Lines (first line is the title, which the theme's title strip covers) and bars for boxpanel:set_bars.
function M.render(rows, totals, opts)
    opts = opts or {}
    local width = opts.name_width or 14
    local lines, bars = {}, {}
    for i, r in ipairs(rows) do
        local name = r.name
        if #name > width then name = name:sub(1, width) end
        lines[#lines + 1] = ('%-' .. width .. 's %7s'):format(name, r.stratagems and r.left == 0 and 'ready' or M.fmt(r.left))
        if opts.bars ~= false then
            local total = totals and totals[r.key] or r.left
            bars[#bars + 1] = {line = i + 1, frac = r.frac or (total > 0 and (r.left / total) or 0), rgba = COLOURS[r.kind]}
        end
    end
    return lines, bars
end

-- Names for the recasts a character has: job ability list -> {[recast id] = name}; known spells -> {[id] = name}.
function M.ability_names(ability_ids, job_abilities)
    local out = {}
    for _, id in ipairs(ability_ids or {}) do
        local a = job_abilities[id]
        if a and a.recast_id and a.en and not out[a.recast_id] then out[a.recast_id] = a.en end
    end
    return out
end

function M.spell_names(known, spells)
    local out = {}
    for id, has in pairs(known or {}) do
        local s = has and spells[id]
        if s and s.en then out[id] = s.en end
    end
    return out
end

return M
