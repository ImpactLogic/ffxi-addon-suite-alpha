-- Local Mastery Rank from incoming 0x01B Job Info. Installed fields.lua:
-- unsigned char at zero-based 0x66, header included. Not per-job Master Level.
local raw = require('progresscore')
local core = {}
core.HEADER = 'captured\tpacket\trank\tsize\thex'
function core.observe(id, data, captured)
    if id ~= 0x01B or type(data) ~= 'string' or #data < 0x67 then return nil end
    return {captured=captured, packet='0x01b', rank=data:byte(0x67), size=#data, hex=raw.hex(data)}
end
function core.row_line(row)
    return table.concat({row.captured,row.packet,tostring(row.rank),tostring(row.size),row.hex}, '\t')
end
function core.to_tsv(row)
    return core.HEADER .. '\n' .. (row and (core.row_line(row) .. '\n') or '')
end
function core.parse(text)
    if type(text) ~= 'string' then return nil end
    local header, body = text:match('^([^\n]*)\n(.*)$')
    if header ~= core.HEADER then return nil end
    local captured,packet,rank,size,hex = body:match('^([^\t\n]+)\t([^\t]+)\t(%d+)\t(%d+)\t([0-9a-f]+)\n?$')
    if not captured or packet~='0x01b' or #hex%2~=0 or #hex~=tonumber(size)*2 then return nil end
    local bytes=hex:gsub('..',function(h) return string.char(tonumber(h,16)) end)
    local row=core.observe(0x01B,bytes,captured)
    if not row or row.rank~=tonumber(rank) then return nil end
    return row
end
function core.summary(row)
    if not row then return 'Mastery Rank: not recorded (unknown; waiting for natural Job Info packet)' end
    return ('Mastery Rank: %d; observed %s via 0x01B (not Master Level)'):format(row.rank,row.captured)
end
return core
