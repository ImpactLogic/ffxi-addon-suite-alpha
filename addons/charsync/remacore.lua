--remacore: the pure part of rema (no Windower calls), so tools/test-rema.lua can run it outside the game.
--
-- rema.tsv    every Relic / Mythic / Empyrean / Aeonic weapon the character holds, one row per copy:
--             date, line, kind, item_id, name, stage, order, bag, augments, extdata (hex)
-- currencies.tsv  every numeric field of the last Currencies packets (0x113, 0x118), by the name
--             packets.parse gives it: date, packet, field, value. Nothing is renamed or picked.
local core = {}

local TAB, NL = string.char(9), string.char(10)

core.REMA_HEADER = {'date', 'line', 'kind', 'item_id', 'name', 'stage', 'order', 'bag', 'augments', 'extdata'}
core.CURRENCY_HEADER = {'date', 'packet', 'field', 'value'}

local function clean(v) return (tostring(v == nil and '' or v):gsub('[\t\r\n]', ' ')) end

function core.hex(s)
    if type(s) ~= 'string' then return '' end
    return (s:gsub('.', function(c) return ('%02X'):format(c:byte()) end))
end

-- bags: list of {name = 'wardrobe', items = {item, ...}} with Windower's item tables (id, count, extdata).
-- weapons: rema_weapons.lua. decode(item) -> list of augment strings, or nil (pcall'd by the caller).
function core.scan(bags, weapons, decode)
    local rows = {}
    for _, bag in ipairs(bags) do
        for _, item in ipairs(bag.items or {}) do
            local w = item and item.id and weapons[item.id]
            if w then
                local augs = {}
                for _, a in ipairs((decode and decode(item)) or {}) do
                    if a and a ~= '' and a ~= 'none' then augs[#augs + 1] = clean(a) end
                end
                rows[#rows + 1] = {line = w.line, kind = w.kind, item_id = item.id, name = w.name,
                    stage = w.stage, order = w.order or 0, bag = bag.name,
                    augments = table.concat(augs, ' | '), extdata = core.hex(item.extdata)}
            end
        end
    end
    table.sort(rows, function(a, b)
        if a.kind ~= b.kind then return a.kind < b.kind end
        if a.line ~= b.line then return a.line < b.line end
        if a.order ~= b.order then return a.order > b.order end
        return a.bag < b.bag
    end)
    return rows
end

function core.rema_tsv(rows, date)
    local out = {table.concat(core.REMA_HEADER, TAB)}
    for _, r in ipairs(rows) do
        out[#out + 1] = table.concat({date, clean(r.line), r.kind, r.item_id, clean(r.name), clean(r.stage),
            r.order, r.bag, r.augments, r.extdata}, TAB)
    end
    return table.concat(out, NL) .. NL
end

-- Highest stage held per line: the row the summary shows.
function core.best(rows)
    local by, order = {}, {}
    for _, r in ipairs(rows) do
        local cur = by[r.line]
        if not cur then order[#order + 1] = r.line end
        if not cur or r.order > cur.order then by[r.line] = r end
    end
    local out = {}
    for _, line in ipairs(order) do out[#out + 1] = by[line] end
    return out
end

-- A parsed packet table -> sorted {field, value} for numeric fields; names starting with _ are padding.
function core.numeric_fields(p)
    local out = {}
    if type(p) ~= 'table' then return out end
    for k, v in pairs(p) do
        if type(k) == 'string' and not k:match('^_') and type(v) == 'number' then
            out[#out + 1] = {field = k, value = v}
        end
    end
    table.sort(out, function(a, b) return a.field < b.field end)
    return out
end

-- snap: {['0x113'] = {date = 'YYYY-MM-DD', fields = {{field, value}, ...}}, ...}
function core.currencies_tsv(snap)
    local packets = {}
    for k in pairs(snap) do packets[#packets + 1] = k end
    table.sort(packets)
    local out = {table.concat(core.CURRENCY_HEADER, TAB)}
    for _, pk in ipairs(packets) do
        for _, f in ipairs(snap[pk].fields) do
            out[#out + 1] = table.concat({snap[pk].date, pk, clean(f.field), tostring(f.value)}, TAB)
        end
    end
    return table.concat(out, NL) .. NL
end

-- Read currencies.tsv back, so a new 0x113 replaces only 0x113's rows.
function core.parse_currencies(text)
    local snap = {}
    for line in (text or ''):gmatch('[^\r\n]+') do
        local date, pk, field, value = line:match('^([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)$')
        if date and date ~= 'date' and tonumber(value) then
            snap[pk] = snap[pk] or {date = date, fields = {}}
            table.insert(snap[pk].fields, {field = field, value = tonumber(value)})
        end
    end
    return snap
end

-- Fields whose name contains any watched word (case-insensitive), across packets.
function core.watched(snap, words)
    local out, seen = {}, {}
    local packets = {}
    for k in pairs(snap) do packets[#packets + 1] = k end
    table.sort(packets)
    for _, pk in ipairs(packets) do
        for _, f in ipairs(snap[pk].fields) do
            local low = f.field:lower()
            for _, w in ipairs(words or {}) do
                if low:find(w:lower(), 1, true) and not seen[f.field] then
                    seen[f.field] = true
                    out[#out + 1] = {field = f.field, value = f.value, date = snap[pk].date}
                end
            end
        end
    end
    return out
end

local KIND_LABEL = {relic = 'Relic', mythic = 'Mythic', empyrean = 'Empyrean', aeonic = 'Aeonic', prime = 'Prime'}

local function commas(n)
    local s = tostring(math.floor(n))
    local k
    repeat s, k = s:gsub('^(-?%d+)(%d%d%d)', '%1,%2') until k == 0
    return s
end

function core.summary(rows, snap, words)
    local lines = {}
    local best = core.best(rows)
    if #best == 0 then
        lines[#lines + 1] = 'no Relic, Mythic, Empyrean or Aeonic weapon in any bag'
    end
    for _, r in ipairs(best) do
        local stage = r.stage ~= '' and r.stage or (r.augments ~= '' and r.augments or 'no augments read')
        lines[#lines + 1] = ('%s %s: %s (%s)'):format(KIND_LABEL[r.kind] or r.kind, r.line, stage, r.bag)
    end
    local w = core.watched(snap or {}, words)
    if #w > 0 then
        local parts = {}
        for _, f in ipairs(w) do parts[#parts + 1] = f.field .. ' ' .. commas(f.value) end
        lines[#lines + 1] = 'currencies (' .. w[1].date .. '): ' .. table.concat(parts, ', ')
    elseif not next(snap or {}) then
        lines[#lines + 1] = 'currencies: open the Currencies menu once to record them'
    end
    return lines
end

return core
