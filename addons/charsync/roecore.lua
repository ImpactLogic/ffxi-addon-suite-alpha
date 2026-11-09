-- Read-only raw RoE evidence. Layout: installed Windower packets/fields.lua.
-- Separate from quest pages: 0x112 Order is uint32 at 0x84, not quest type at 0x24.
local raw = require('progresscore')
local core = {PACKETS = {[0x111] = true, [0x112] = true}}
core.to_tsv, core.row_line = raw.to_tsv, raw.row_line
local function page(id, data)
    if type(data) ~= 'string' then return nil end
    if id == 0x111 and #data >= 0x104 then return 0 end
    if id ~= 0x112 or #data < 0x88 then return nil end
    local a,b,c,d = data:byte(0x85,0x88)
    local order = a + b*256 + c*65536 + d*16777216
    if order <= 3 then return order end
end
function core.update(rows, id, data, captured)
    local order = page(id, data)
    if order == nil then return false end
    local key = ('0x%03x:0x%04x'):format(id, order)
    local hex = raw.hex(data)
    local old = rows[key]
    local changed = not old or old.hex:sub(9) ~= hex:sub(9)
    local row = {captured=captured, packet=('0x%03x'):format(id),
        type=('0x%04x'):format(order), size=#data, hex=hex}
    rows[key] = row -- captured means last observed, including unchanged pages.
    return true, row, changed
end
function core.parse(text)
    local rows = {}
    for key, row in pairs(raw.parse(text)) do
        local bytes = row.hex:gsub('..', function(h) return string.char(tonumber(h,16)) end)
        local order = page(tonumber(row.packet), bytes)
        if order ~= nil and #bytes == row.size and order == tonumber(row.type) then
            rows[key] = row
        end
    end
    return rows
end
function core.summary(rows)
    local out, n = {}, 0
    local active = rows['0x111:0x0000']
    out[1] = 'RoE active: ' .. (active and ('observed ' .. active.captured) or 'not recorded')
    for order=0,3 do
        local row = rows[('0x112:0x%04x'):format(order)]
        if row then n=n+1 end
        out[#out+1] = ('RoE completion page %d: %s'):format(order,
            row and ('observed ' .. row.captured) or 'not recorded (unknown)')
    end
    out[#out+1] = ('RoE coverage: %d/4 completion pages; open the Records of Eminence menus to refresh'):format(n)
    return out
end
return core
