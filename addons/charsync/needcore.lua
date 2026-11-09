--needcore: what charsync still needs from the player (pure, no Windower calls; tools/test-charsync-need.lua runs it offline).
-- Every row is a fact the client only hands over when the player does something: open a menu, visit the Mog House, talk to an NPC.
-- read(name) returns the text of one of the character's saved files, or nil. now is os.time().
-- Read-only: it looks at dates in files charsync already wrote and says what to do; it never acts for the player.
local core = {}

local DAY = 86400

-- kind 'auto' = charsync does it by itself (listed so a missing file is explained); 'menu' = player opens a menu;
-- 'npc' = player talks to an NPC (charsync only records the dialogue that arrives; it never talks to the NPC).
core.ROWS = {
    {id = 'snapshot', label = 'character snapshot (bags, gear, key items, levels)', file = 'snapshot.tsv', kind = 'auto', stale = 7,
     how = '//charsync (it also runs on load, login and zoning; visit your Mog House once so storage can be read)'},
    {id = 'points', label = 'merits and job points', file = 'points.tsv', kind = 'auto', stale = 7,
     how = '//charsync points (open the Merits menu once for the merit bank)'},
    {id = 'rema', label = 'REMA weapons', file = 'rema.tsv', kind = 'auto', stale = 7,
     how = '//charsync (it scans REMA weapons with every snapshot)'},
    {id = 'currencies', label = 'currencies', file = 'currencies.tsv', kind = 'menu', stale = 14,
     how = 'open the Currencies menu, both pages'},
    {id = 'progress', label = 'quest and mission log', file = 'progress.tsv', kind = 'menu', stale = 30,
     how = 'open the Quest menu and the Mission menu, every category'},
    {id = 'roe', label = 'Records of Eminence', file = 'roe.tsv', kind = 'menu', stale = 14,
     how = 'open the Records of Eminence menu pages'},
    {id = 'temprix', label = 'Aeonic progress (Temprix)', file = 'temprix.tsv', kind = 'npc', stale = 30, optional = true,
     how = 'talk to Temprix and read the Aeonic progress dialogue (charsync only records it)'},
}
-- Wanted but not readable yet: no row until the capture exists (evidence first).
core.NOT_YET = {'player titles (the client packet is not verified yet)'}

local function epoch(y, mo, d, h, mi, s)
    return os.time({year = tonumber(y), month = tonumber(mo), day = tonumber(d), hour = tonumber(h) or 12, min = tonumber(mi) or 0, sec = tonumber(s) or 0})
end

-- Newest date in a file: `captured=YYYY-MM-DD HH:MM:SS` in a header, else any YYYY-MM-DD at a line start or after a tab.
function core.newest(text)
    if not text or text == '' then return nil end
    local best
    local function consider(t) if t and (not best or t > best) then best = t end end
    for y, mo, d, h, mi, s in text:gmatch('(%d%d%d%d)%-(%d%d)%-(%d%d)[ T]?(%d?%d?):?(%d?%d?):?(%d?%d?)') do
        consider(epoch(y, mo, d, h ~= '' and h or nil, mi ~= '' and mi or nil, s ~= '' and s or nil))
    end
    return best
end

-- -> list of {id, label, kind, optional, state = 'ok'|'stale'|'missing', days, how}
function core.need(read, now)
    local rows = {}
    for _, def in ipairs(core.ROWS) do
        local t = core.newest(read(def.file))
        local row = {id = def.id, label = def.label, kind = def.kind, optional = def.optional, how = def.how}
        if not t then row.state = 'missing'
        else
            row.days = math.max(0, math.floor((now - t) / DAY))
            row.state = row.days > def.stale and 'stale' or 'ok'
        end
        rows[#rows + 1] = row
    end
    return rows
end

-- Chat lines. todo_only drops finished rows. Optional rows that are missing are shown as optional, never as a to-do.
function core.render(rows, todo_only)
    local out, todo = {}, 0
    for _, r in ipairs(rows) do
        if r.state == 'ok' then
            if not todo_only then out[#out + 1] = ('[x] %s (%d day%s old)'):format(r.label, r.days, r.days == 1 and '' or 's') end
        else
            local why = r.state == 'stale' and ('%d days old'):format(r.days) or 'not recorded yet'
            if r.optional then out[#out + 1] = ('[ ] (optional) %s - %s: %s'):format(r.label, why, r.how)
            else
                todo = todo + 1
                out[#out + 1] = ('[ ] %s - %s: %s'):format(r.label, why, r.how)
            end
        end
    end
    return out, todo
end

return core
