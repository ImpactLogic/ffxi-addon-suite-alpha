-- Warp unlock bitmasks from incoming 0x063 order 6 (byte 5 of the packet). Event driven: it arrives around
-- login / zoning and when a home point or survival guide menu opens, so no menu has to be clicked.
-- Layout confirmed on 3 characters in Harness captures 2026-10-17 (one character 3 home point bits, another 95,
-- a third 120): zero-based 0x08..0x17 home points, 0x18..0x27 survival guides, 0x28..0x37 waypoints, each
-- 128 bits little-endian. Bit numbers only; which bit is which place is NOT known here (atlas maps them).
-- Place names come from warpnames.lua (generated from the XIchecklist map by tools/build-warp-names.py).
-- Fields after 0x38 (telepoints, maws, eschan portals) are kept in the raw hex but not decoded: not checked.
local raw = require('progresscore')
local core = {}
core.HEADER = 'captured\tpacket\torder\tsize\thex'
local MIN_SIZE = 0x38
local MASKS = {homePoints = 0x08, survivalGuides = 0x18, waypoints = 0x28}
core.MASKS = MASKS

local function is_warp(id, data)
    return id == 0x063 and type(data) == 'string' and #data >= MIN_SIZE and data:byte(5) == 6
end
function core.observe(id, data, captured)
    if not is_warp(id, data) then return nil end
    return {captured=captured, packet='0x063', order=6, size=#data, hex=raw.hex(data)}
end
-- Sorted zero-based bit numbers set in the 16-byte mask starting at zero-based offset `base`.
local function bits(data, base)
    local out = {}
    for i = 0, 15 do
        local b = data:byte(base + i + 1)
        for k = 0, 7 do
            if math.floor(b / 2^k) % 2 == 1 then out[#out + 1] = i * 8 + k end
        end
    end
    return out
end
function core.decode(data)
    if not is_warp(0x063, data) then return nil end
    local out = {}
    for name, base in pairs(MASKS) do out[name] = bits(data, base) end
    return out
end
function core.row_line(row)
    return table.concat({row.captured,row.packet,tostring(row.order),tostring(row.size),row.hex}, '\t')
end
function core.to_tsv(row)
    return core.HEADER .. '\n' .. (row and (core.row_line(row) .. '\n') or '')
end
function core.parse(text)
    if type(text) ~= 'string' then return nil end
    local header, body = text:match('^([^\n]*)\n(.*)$')
    if header ~= core.HEADER then return nil end
    local captured,packet,order,size,hex = body:match('^([^\t\n]+)\t([^\t]+)\t(%d+)\t(%d+)\t([0-9a-f]+)\n?$')
    if not captured or packet ~= '0x063' or order ~= '6' or #hex % 2 ~= 0 or #hex ~= tonumber(size)*2 then return nil end
    local bytes = hex:gsub('..', function(h) return string.char(tonumber(h,16)) end)
    return core.observe(0x063, bytes, captured)
end
-- True when the masks differ; the 4-byte header (sequence number) and bytes after 0x38 do not count.
function core.changed(old, new)
    if not old then return true end
    return old.hex:sub(9, MIN_SIZE*2) ~= new.hex:sub(9, MIN_SIZE*2)
end
function core.summary(row)
    if not row then return 'Warps: not recorded (unknown; arrives on login or zoning)' end
    local bytes = row.hex:gsub('..', function(h) return string.char(tonumber(h,16)) end)
    local d = core.decode(bytes)
    return ('Warps: %d home points, %d survival guides, %d waypoints set; observed %s via 0x063 (bit numbers, not place names)')
        :format(#d.homePoints, #d.survivalGuides, #d.waypoints, row.captured)
end

-- Report lines for `//cs warps have|missing [home|guides|waypoints]`: names joined into chat-sized lines.
-- `names` is the warpnames table; tests pass their own. A bit with no name is listed as 'bit N'.
local KINDS = {{key='homePoints', scope='homepoints', title='home points', word='home'},
    {key='survivalGuides', scope='survivalguides', title='survival guides', word='guides'},
    {key='waypoints', scope='waypoints', title='waypoints', word='waypoints'}}
local function wrap(head, items, out)
    local line = head
    for i, item in ipairs(items) do
        local piece = (i > 1 and ', ' or ' ') .. item
        if #line + #piece > 200 then out[#out + 1] = line line = '  ' .. item
        else line = line .. piece end
    end
    out[#out + 1] = line
end
function core.report(row, mode, which, names)
    if not row then return {'Warps: not recorded (unknown; arrives on login or zoning)'} end
    if names == nil then
        local ok, t = pcall(require, 'warpnames')
        names = ok and t or {}
    end
    local bytes = row.hex:gsub('..', function(h) return string.char(tonumber(h,16)) end)
    local d = core.decode(bytes)
    local out = {}
    for _, k in ipairs(KINDS) do
        if not which or which == k.word then
            local map = names[k.scope] or {}
            local set = {}
            for _, bit in ipairs(d[k.key]) do set[bit] = true end
            local have, missing = {}, {}
            local bits = {}
            for bit in pairs(map) do bits[#bits + 1] = bit end
            table.sort(bits)
            for _, bit in ipairs(bits) do
                local into = set[bit] and have or missing
                into[#into + 1] = map[bit]
            end
            for _, bit in ipairs(d[k.key]) do
                if not map[bit] then have[#have + 1] = 'bit ' .. bit end
            end
            local list = mode == 'missing' and missing or have
            wrap(('%s %s (%d):'):format(mode == 'missing' and 'Missing' or 'Have', k.title, #list), list, out)
        end
    end
    return out
end
return core
