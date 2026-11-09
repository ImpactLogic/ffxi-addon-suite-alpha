-- Passive captures: packets the client sends on its own at login or zoning, kept raw, one row each, in
-- passive.tsv. Nothing is decoded here and the player does nothing; //cs passive lists which have arrived,
-- which is the "captured" status a setup screen can show. Which packets exist and what they probably carry
-- comes from the XIchecklist add-on's handlers (checked: each arrives in Harness captures on every zone-in,
-- three characters, 2026-10-17); the field meanings are its claims, not ours.
local raw = require('progresscore')
local core = {}
core.HEADER = 'captured\tkey\tpacket\tsize\thex'

-- order: for 0x063, the byte at 1-based position 5. Warps (order 6) and points (2, 5) have their own handlers.
core.SPECS = {
    {key = 'zones',        id = 0x008, label = 'zones visited (claimed)'},
    {key = 'monstrosity-a', id = 0x063, order = 3, label = 'monstrosity levels and instincts (claimed)'},
    {key = 'monstrosity-b', id = 0x063, order = 4, label = 'monstrosity race/job instincts and variants (claimed)'},
    {key = 'alter-ego',    id = 0x08E, label = 'Alter Ego points (claimed)'},
    {key = 'mmm',          id = 0x0AD, label = 'Moblin Maze Mongers vouchers and runes (claimed)'},
    {key = 'crafts',       id = 0x062, label = 'crafting skill levels (claimed)'},
    {key = 'title',        id = 0x061, label = 'player info and current title (claimed)'},
}

-- The spec key for a packet, or nil. A 0x063 shorter than 5 bytes has no order and matches nothing.
function core.key_of(id, data)
    if type(data) ~= 'string' then return nil end
    for _, s in ipairs(core.SPECS) do
        if s.id == id and (not s.order or data:byte(5) == s.order) then return s.key end
    end
    return nil
end

-- rows: {[key] = {captured, key, packet, size, hex}}. Returns true when the packet is new or differs from
-- the held copy; the 4-byte header (id, size, sequence number) does not count as a difference.
function core.update(rows, id, data, captured)
    local key = core.key_of(id, data)
    if not key then return false end
    local hex = raw.hex(data)
    local old = rows[key]
    if old and old.hex:sub(9) == hex:sub(9) then return false, old end
    local row = {captured = captured, key = key, packet = ('0x%03x'):format(id), size = #data, hex = hex}
    rows[key] = row
    return true, row
end

function core.row_line(row)
    return table.concat({row.captured, row.key, row.packet, tostring(row.size), row.hex}, '\t')
end

function core.to_tsv(rows)
    local out = {core.HEADER}
    for _, s in ipairs(core.SPECS) do
        if rows[s.key] then out[#out + 1] = core.row_line(rows[s.key]) end
    end
    return table.concat(out, '\n') .. '\n'
end

function core.parse(text)
    local rows = {}
    if type(text) ~= 'string' then return rows end
    local first = true
    for line in text:gmatch('[^\r\n]+') do
        if first then
            first = false
            if line ~= core.HEADER then return {} end
        else
            local captured, key, packet, size, hex = line:match('^([^\t]+)\t([^\t]+)\t([^\t]+)\t(%d+)\t([0-9a-f]+)$')
            if captured and #hex % 2 == 0 and #hex == tonumber(size) * 2 then
                local bytes = hex:gsub('..', function(h) return string.char(tonumber(h, 16)) end)
                local k = core.key_of(tonumber(packet), bytes)
                if k == key then rows[key] = {captured = captured, key = key, packet = packet, size = tonumber(size), hex = hex} end
            end
        end
    end
    return rows
end

-- One line per spec for //cs passive: when its newest change was seen, or that it has not arrived.
function core.summary(rows)
    local out, have = {}, 0
    for _, s in ipairs(core.SPECS) do
        local r = rows[s.key]
        if r then have = have + 1 end
        out[#out + 1] = ('%s: %s'):format(s.label, r and ('changed %s'):format(r.captured) or 'not yet (zone once)')
    end
    table.insert(out, 1, ('Passive captures: %d/%d arrived (raw packets, meanings are XIchecklist\'s claims)'):format(have, #core.SPECS))
    return out
end

return core
