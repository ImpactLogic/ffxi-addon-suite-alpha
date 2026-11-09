--progresscore: the recorder half of the quest and mission tracker (IDEAS #76), with no Windower in it so
-- tools/test-progress.lua can run it offline.
--
-- What it does: keeps the newest raw copy of each quest / mission log packet the client sends, per
-- (packet id, type), and writes them as progress.tsv for ffxi-atlas (docs/PROGRESS-LOG.md, which owns the
-- format). It decodes NOTHING. Which bits mean "completed" is exactly what this recorder exists to find
-- out, so the whole packet travels as hex and atlas decodes from evidence later.
--
-- The one structural guess: for 0x056 the packet type is a uint16 little-endian at byte offset 0x24 (the
-- LandSandBoat layout, tools/lsb-packet-names.txt: 0x056_mission). It is only used to keep one row per
-- log page; a wrong guess merges pages or splits one, and the full hex is kept either way.
local core = {}

local TAB, NL = string.char(9), string.char(10)

core.HEADER = {'captured', 'packet', 'type', 'size', 'hex'}

-- Incoming packets recorded. 0x056 carries the quest and mission log pages. The client asks for them
-- when the Quest / Mission menus open, so the menus have to be opened to fill the file.
core.PACKETS = {[0x056] = true}

local TYPE_OFFSET = 0x24   -- 0-based offset into the packet, header included

function core.hex(s)
    return (s:gsub('.', function(c) return ('%02x'):format(c:byte()) end))
end

-- uint16 little-endian at TYPE_OFFSET, or nil when the packet is too short to have one.
function core.type_of(data)
    if type(data) ~= 'string' or #data < TYPE_OFFSET + 2 then return nil end
    return data:byte(TYPE_OFFSET + 1) + data:byte(TYPE_OFFSET + 2) * 256
end

local function key(id, ptype)
    return ('0x%03x:%s'):format(id, ptype and ('0x%04x'):format(ptype) or '-')
end

-- rows: {[key] = {captured, packet, type, size, hex}}. Returns true when this packet is new or differs
-- from the copy held, so callers can append a history line only for a real change.
function core.update(rows, id, data, captured)
    if not core.PACKETS[id] or type(data) ~= 'string' then return false end
    local ptype = core.type_of(data)
    local k = key(id, ptype)
    local hex = core.hex(data)
    local old = rows[k]
    local row = {captured = captured, packet = ('0x%03x'):format(id),
        type = ptype and ('0x%04x'):format(ptype) or '-', size = #data, hex = hex}
    -- The first 4 bytes are the packet header (id, size, and a sequence number that alternates between
    -- copies of the same page, seen 2026-10-06), so they do not count as a change.
    if old and old.hex:sub(9) == hex:sub(9) then
        return false, row, old.captured -- receipt is new; stored content/change date stays old
    end
    rows[k] = row
    return true, row, row.captured
end

local function row_line(r)
    return table.concat({r.captured, r.packet, r.type, tostring(r.size), r.hex}, TAB)
end
core.row_line = row_line

function core.to_tsv(rows)
    local keys = {}
    for k in pairs(rows) do keys[#keys + 1] = k end
    table.sort(keys)
    local out = {table.concat(core.HEADER, TAB)}
    for _, k in ipairs(keys) do out[#out + 1] = row_line(rows[k]) end
    return table.concat(out, NL) .. NL
end

-- Read a progress.tsv back, so pages seen in an earlier session are not dropped when this session opens
-- only one menu. Bad lines are skipped.
function core.parse(text)
    local rows = {}
    local first = true
    for line in (text or ''):gmatch('[^\r\n]+') do
        if first then
            first = false
            if line ~= table.concat(core.HEADER, TAB) then return {} end
        else
            local c = {}
            for f in (line .. TAB):gmatch('([^\t]*)\t') do c[#c + 1] = f end
            local id = c[2] and tonumber(c[2])
            if #c >= 5 and id and c[5]:match('^[0-9a-f]*$') then
                rows[key(id, tonumber(c[3]))] = {captured = c[1], packet = c[2], type = c[3],
                    size = tonumber(c[4]) or 0, hex = c[5]}
            end
        end
    end
    return rows
end

function core.count(rows)
    local n = 0
    for _ in pairs(rows) do n = n + 1 end
    return n
end

-- One line per page for //charsync progress.
function core.summary(rows)
    local keys = {}
    for k in pairs(rows) do keys[#keys + 1] = k end
    table.sort(keys)
    local out = {}
    for _, k in ipairs(keys) do
        local r = rows[k]
        out[#out + 1] = ('%s type %s: %d bytes, seen %s'):format(r.packet, r.type, r.size, r.captured)
    end
    return out
end

return core
