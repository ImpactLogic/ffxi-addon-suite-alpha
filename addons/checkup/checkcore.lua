--checkcore: the pure part of checkup (no Windower calls), so tools/test-checkup.lua runs it offline.
--
-- It reads the files the other addons write -- never their memory, never a packet -- and says how old
-- each fact is. read(path) returns a file's text or nil; now is os.time(). Paths are relative to the
-- Windower addons folder, with <Char> for the character.
local core = {}

local DAY = 86400

-- facts only an NPC or a menu tells you. `date_col` is the column holding the date the
-- fact was read (the newest row wins). `how` is what to do in game when it is missing or stale.
core.SETUP = {
    {id = 'coalitions', addon = 'buffbox', optional = true, label = 'Ionis coalitions', file = 'buffbox/data/<Char>/coalitions.tsv', date_col = 3,
     stale = 14, how = 'ask the six Adoulin Civil Registrars "The State of the <name> Coalition" (buffbox loaded)'},
    {id = 'points', addon = 'charsync', label = 'merits and job points', file = 'charsync/data/<Char>/points.tsv', date_col = 1,
     stale = 7, how = 'load charsync (//lua l charsync): it saves points.tsv on load'},
    {id = 'currencies', addon = 'charsync', label = 'currencies', file = 'charsync/data/<Char>/currencies.tsv', date_col = 1,
     stale = 7, how = 'open the Currencies menu, both pages (charsync loaded)'},
    {id = 'rema', addon = 'charsync', label = 'REMA weapons', file = 'charsync/data/<Char>/rema.tsv', date_col = 1,
     stale = 7, how = '//charsync (it scans REMA weapons with every snapshot)'},
    -- charsync's snapshot has one date, in its header: `date_key` finds it instead of a column.
    {id = 'charsync', addon = 'charsync', label = 'character snapshot', file = 'charsync/data/<Char>/snapshot.tsv', date_key = 'captured=',
     stale = 7, how = 'load charsync (//lua l charsync): it saves on load, login and zoning'},
}
-- On the list but not readable yet: each needs its wording recorded first (evidence rule).
core.NOT_YET = {'nation rank (Signet)', 'mercenary rank (Sanction)', 'campaign medal (Sigil)'}

-- Recorders: is today's file there? `utc` marks add-ons that name files by UTC day, local day otherwise.
core.RECORDERS = {
    {id = 'combatlog', label = 'combat (combatlog)', file = 'combatlog/data/<Char>/combat-<day>.tsv'},
}
core.LOOKBACK = 14   -- days searched back for a recorder's last file

-- Addons whose log is scanned for recent errors, and whose installed version is read.
core.ADDONS = {'bags', 'battlelines', 'boxtheme', 'buffbox', 'charsync', 'checkup', 'combatlog', 'storyguide', 'timers'}
core.ERROR_DAYS = 7

local function sub(path, char, day)
    return (path:gsub('<Char>', char):gsub('<day>', day or ''))
end

local function to_time(date)
    local y, m, d = tostring(date or ''):match('^(%d%d%d%d)%-(%d%d)%-(%d%d)')
    if not y then return nil end
    return os.time({year = tonumber(y), month = tonumber(m), day = tonumber(d), hour = 12})
end

function core.days_old(date, now)
    local t = to_time(date)
    if not t then return nil end
    local today = to_time(os.date('%Y-%m-%d', now))
    return math.floor((today - t) / DAY + 0.5)
end

-- The newest YYYY-MM-DD in column `col` of a TSV (a header row simply does not match).
function core.newest_date(text, col)
    local best
    for line in (text or ''):gmatch('[^\r\n]+') do
        local i, cell = 0, nil
        for c in (line .. '\t'):gmatch('([^\t]*)\t') do
            i = i + 1
            if i == col then cell = c break end
        end
        local d = cell and cell:match('^(%d%d%d%d%-%d%d%-%d%d)')
        if d and (not best or d > best) then best = d end
    end
    return best
end

-- One setup item -> {label, state = 'ok'|'stale'|'missing', date, age, how}
function core.setup(read, char, now)
    local out = {}
    for _, item in ipairs(core.SETUP) do
      -- A fact whose add-on is not installed is not a to-do: the player cannot act on it.
      if not item.addon or read(item.addon .. '/' .. item.addon .. '.lua') then
        local text = read(sub(item.file, char))
        local date = text and (item.date_key and text:match(item.date_key:gsub('%p', '%%%0') .. '(%d%d%d%d%-%d%d%-%d%d)')
            or item.date_col and core.newest_date(text, item.date_col))
        local age = date and core.days_old(date, now)
        local st = not date and 'missing' or (age > item.stale and 'stale') or 'ok'
        -- An endgame-only fact the player never recorded is not a to-do.
        if not (item.optional and st == 'missing') then
        out[#out + 1] = {id = item.id, label = item.label, state = st, date = date, age = age, how = item.how}
        end
      end
    end
    return out
end

-- One recorder -> {label, state = 'today'|'old'|'none', date, age}
function core.recorders(read, char, now)
    local out = {}
    for _, r in ipairs(core.RECORDERS) do
      if read(r.id .. '/' .. r.id .. '.lua') then   -- only recorders that are installed
        local found
        for back = 0, core.LOOKBACK do
            local day = os.date(r.utc and '!%Y-%m-%d' or '%Y-%m-%d', now - back * DAY)
            if read(sub(r.file, char, day)) then found = {day = day, back = back} break end
        end
        out[#out + 1] = {id = r.id, label = r.label,
            state = not found and 'none' or (found.back == 0 and 'today') or 'old',
            date = found and found.day, age = found and found.back}
      end
    end
    return out
end

-- The last "ERROR" line of an addon log written as [mm-dd HH:MM:SS] text (the template's format).
-- The log has no year, so a stamp later in the year than today is taken as last year.
function core.last_error(text, now)
    local last
    for line in (text or ''):gmatch('[^\r\n]+') do
        if line:find('ERROR', 1, true) then last = line end
    end
    if not last then return nil end
    local mo, d = last:match('^%[(%d%d)%-(%d%d) ')
    local age
    if mo then
        local year = tonumber(os.date('%Y', now))
        local t = os.time({year = year, month = tonumber(mo), day = tonumber(d), hour = 12})
        if t > now + DAY then t = os.time({year = year - 1, month = tonumber(mo), day = tonumber(d), hour = 12}) end
        age = math.floor((to_time(os.date('%Y-%m-%d', now)) - t) / DAY + 0.5)
    end
    return {line = last, age = age}
end

function core.version(text)
    return text and text:match("_addon%.version%s*=%s*'([^']+)'") or text and text:match('_addon%.version%s*=%s*"([^"]+)"')
end

-- Per addon: installed version and a recent error, if any.
function core.addons(read, now)
    local out = {}
    for _, name in ipairs(core.ADDONS) do
        local src = read(name .. '/' .. name .. '.lua')
        if src then
            local err = core.last_error(read(name .. '/data/' .. name .. '.log'), now)
            if err and err.age and err.age > core.ERROR_DAYS then err = nil end
            out[#out + 1] = {name = name, version = core.version(src), error = err}
        end
    end
    return out
end

local function ago(age)
    if not age then return '?' end
    if age == 0 then return 'today' end
    if age == 1 then return 'yesterday' end
    return age .. ' days ago'
end
core.ago = ago

-- Chat lines. `short` keeps only what needs doing (the box).
function core.render(setup, recorders, addons, short)
    local L = {}
    local todo = 0
    for _, s in ipairs(setup) do
        if s.state ~= 'ok' then todo = todo + 1 end
        if s.state ~= 'ok' or not short then
            local head = s.state == 'ok' and ('ok   %s: %s'):format(s.label, ago(s.age))
                or s.state == 'stale' and ('OLD  %s: %s -> %s'):format(s.label, ago(s.age), s.how)
                or ('NONE %s -> %s'):format(s.label, s.how)
            L[#L + 1] = head
        end
    end
    if not short then L[#L + 1] = 'not tracked yet: ' .. table.concat(core.NOT_YET, ', ') end
    for _, r in ipairs(recorders) do
        if r.state ~= 'today' or not short then
            L[#L + 1] = r.state == 'today' and ('ok   %s: writing today'):format(r.label)
                or r.state == 'old' and ('note %s: last file %s (%s)'):format(r.label, r.date, ago(r.age))
                or ('note %s: nothing recorded in %d days (normal until recording is on)'):format(r.label, core.LOOKBACK)
        end
    end
    local versions = {}
    for _, a in ipairs(addons or {}) do
        if a.error then
            L[#L + 1] = ('ERR  %s %s: %s'):format(a.name, ago(a.error.age), a.error.line:sub(1, 90))
        end
        versions[#versions + 1] = a.name .. ' ' .. tostring(a.version or '?')
    end
    if not short and #versions > 0 then L[#L + 1] = 'installed: ' .. table.concat(versions, ', ') end
    if short and #L == 0 then L[1] = 'all set' end
    return L, todo
end

-- Registry listing for `//ck addons [word]`. reg = the table in registry.lua; installed(name) -> installed
-- _addon.version or nil. Only addons and forks. Groups by status so what is proven in game comes first.
-- word filters on id, role, goal or purpose (case-insensitive); 'proven'/'offline'/'copy' also match status.
-- Grouped by the registry's `public` flag: launch, then preview, then the private rest collapsed to a count (0.5.3).
-- `all` expands everything; `automation` lists the automation add-ons (they are in no setup module); any other word
-- searches every group, private ones included. A registry without `public` (old copy, tests) is listed flat.
local ORDER = {proven = 1, offline = 2, copy = 3, idea = 4, retired = 5}
local function sort_rows(rows)
    table.sort(rows, function(a, b)
        local x, y = ORDER[a.status] or 9, ORDER[b.status] or 9
        if x ~= y then return x < y end
        return a.id:lower() < b.id:lower()
    end)
end
local function reg_row(r, installed)
    local have = installed and installed(r.id)
    local seen = r.verified and r.verified ~= '-' and r.verified ~= ''
    local mark = seen and ((r.status == 'proven' and '' or r.status .. ', ') .. 'seen ' .. r.verified)
        or r.status == 'proven' and 'proven, undated'
        or r.status == 'offline' and 'not confirmed in game' or r.status
    local ver = have and (' v' .. have) or (r.kind == 'addon' and ' (not installed)' or '')
    return ('%-14s %s%s  [%s]'):format(r.id, r.role or '', ver, mark)
end

function core.registry(reg, installed, word)
    local w = word and word:lower() or nil
    local groups = {launch = {}, preview = {}, listed = {}, private = {}}
    local shown, counts, private_n = 0, {}, 0
    for _, r in ipairs(reg or {}) do
        local hay = (r.id .. ' ' .. (r.role or '') .. ' ' .. (r.goal or '') .. ' ' .. (r.purpose or '')):lower()
        local match
        if w == 'all' then match = true
        else match = not w or w == r.status or hay:find(w, 1, true) ~= nil end
        if match then
            local g = r.public or 'listed'
            if g == 'private' and not w then private_n = private_n + 1
            else
                local grp = groups[g] or groups.private
                grp[#grp + 1] = r
                shown = shown + 1
                counts[r.status] = (counts[r.status] or 0) + 1
            end
        end
    end
    local L = {}
    for _, g in ipairs({'listed', 'launch', 'preview', 'private'}) do
        local rows = groups[g]
        if #rows > 0 then
            sort_rows(rows)
            if g ~= 'listed' then L[#L + 1] = ('-- %s (%d) --'):format(g == 'private' and 'other (private)' or g, #rows) end
            for _, r in ipairs(rows) do L[#L + 1] = reg_row(r, installed) end
        end
    end
    if private_n > 0 then
        L[#L + 1] = ('-- %d more not shown: //ck addons all --'):format(private_n)
    end
    local summary = {}
    for _, k in ipairs({'proven', 'offline', 'copy', 'idea', 'retired'}) do
        if counts[k] then summary[#summary + 1] = counts[k] .. ' ' .. k end
    end
    table.insert(L, 1, shown .. ' listed: ' .. (#summary > 0 and table.concat(summary, ', ') or 'none'))
    return L
end

-- Departure check for `//ck depart`. Pure: the addon gathers the facts, this words them.
-- d = {name=, zone=, bags={{name=,count=,max=,enabled=}...}, todo=<setup/recorder lines needing doing>,
--      manual={'free text', ...}, low=<free-slot warning level>}
-- Unknown stays unknown: a bag the client reports as not enabled or without a max is listed as unknown, never ok.
function core.depart(d)
    local L, problems = {}, 0
    L[#L + 1] = ('%s is in %s'):format(d.name or '?', d.zone or 'unknown zone')
    local low = d.low or 5
    for _, b in ipairs(d.bags or {}) do
        if not b.max or b.max <= 0 or b.enabled == false then
            L[#L + 1] = ('unknown %s: not readable right now (Mog House or bag not open)'):format(b.name)
        else
            local free = b.max - (b.count or 0)
            if free <= 0 then
                problems = problems + 1
                L[#L + 1] = ('FULL %s %d/%d'):format(b.name, b.count, b.max)
            elseif free < low then
                problems = problems + 1
                L[#L + 1] = ('LOW  %s %d/%d (%d free)'):format(b.name, b.count, b.max, free)
            else
                L[#L + 1] = ('ok   %s %d/%d (%d free)'):format(b.name, b.count, b.max, free)
            end
        end
    end
    for _, t in ipairs(d.todo or {}) do problems = problems + 1 L[#L + 1] = t end
    for _, m in ipairs(d.manual or {}) do L[#L + 1] = 'CHECK yourself: ' .. m end
    L[#L + 1] = problems == 0 and 'ready to go (zone, bags and setup facts only; supplies are not checked)'
        or (problems .. ' thing(s) to look at first')
    return L, problems
end

return core
