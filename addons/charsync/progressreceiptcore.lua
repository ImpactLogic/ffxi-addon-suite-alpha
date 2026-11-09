-- Passive raw page receipts, separate from content-change timestamps. No decoding or requests.
local core = {}
local TAB, NL = string.char(9), string.char(10)
local function timestamp(s)
    return type(s)=='string' and s:match('^%d%d%d%d%-%d%d%-%d%d %d%d:%d%d:%d%d$') ~= nil
end
local function valid(row)
    if type(row)~='table' or row.packet~='0x056' or not timestamp(row.received) or
       not timestamp(row.content_changed_at) or type(row.changed)~='boolean' or
       type(row.type)~='string' or not row.type:match('^0x%x%x%x%x$') or
       type(row.size)~='number' or row.size<38 or row.size%1~=0 or
       type(row.hex)~='string' or #row.hex~=row.size*2 or not row.hex:match('^[0-9a-f]+$') then return false end
    if row.hex:sub(1,2)~='56' or tonumber(row.hex:sub(3,4),16)%2~=0 then return false end
    local ptype=tonumber(row.hex:sub(73,74),16)+256*tonumber(row.hex:sub(75,76),16)
    return ptype==tonumber(row.type) and row.content_changed_at<=row.received
end
local function key(row) return row.packet..':'..row.type end
function core.row_line(row)
    return table.concat({'r',row.received,row.packet,row.type,tostring(row.size),row.hex,
        row.content_changed_at,tostring(row.changed)},TAB)
end
function core.observe(rows, raw, changed_at, changed)
    if type(raw)~='table' then return false end
    local row={received=raw.captured,packet=raw.packet,type=raw.type,size=raw.size,hex=raw.hex,
        content_changed_at=changed_at,changed=changed}
    if not valid(row) then return false end
    local k=key(row);local old=rows[k]
    -- Clock regressions do not replace a later receipt; raw change history is independent.
    if old and (old.received>row.received or core.row_line(old)==core.row_line(row)) then return false end
    rows[k]=row
    return true,row
end
function core.header(character,version)
    return table.concat({'h','schema=1','character='..character,'addon_version='..version,'scope=raw_receipt_only'},TAB)
end
function core.to_tsv(rows,character,version)
    local keys={};for k in pairs(rows) do keys[#keys+1]=k end;table.sort(keys)
    local out={core.header(character,version)}
    for _,k in ipairs(keys) do out[#out+1]=core.row_line(rows[k]) end
    return table.concat(out,NL)..NL
end
function core.parse(text,character)
    local rows={};local first=true
    for line in (text or ''):gmatch('[^\r\n]+') do
        local c={};for value in (line..TAB):gmatch('([^\t]*)\t') do c[#c+1]=value end
        if first then
            first=false
            if #c~=5 or c[1]~='h' or c[2]~='schema=1' or c[3]~='character='..character or
               not c[4]:match('^addon_version=.+$') or c[5]~='scope=raw_receipt_only' then return {} end
        elseif #c==8 and c[1]=='r' and (c[8]=='true' or c[8]=='false') then
            local row={received=c[2],packet=c[3],type=c[4],size=tonumber(c[5]),hex=c[6],
                content_changed_at=c[7],changed=c[8]=='true'}
            if valid(row) then
                local k=key(row)
                if not rows[k] or rows[k].received<=row.received then rows[k]=row end
            end
        end
    end
    return rows
end
function core.summary(rows)
    local n,oldest,newest=0,nil,nil
    for _,row in pairs(rows) do
        n=n+1
        if not oldest or row.received<oldest then oldest=row.received end
        if not newest or row.received>newest then newest=row.received end
    end
    if n==0 then return 'progress receipts: none recorded; menu opening alone does not prove a packet arrived' end
    return ('progress receipts: %d raw pages; last received %s to %s (not mission completion)'):format(n,oldest,newest)
end
function core.page_summary(content,receipts)
    local row=receipts[content.packet..':'..content.type]
    return ('%s type %s: %d bytes, content changed %s; last received %s'):format(
        content.packet,content.type,content.size,content.captured,row and row.received or 'not recorded')
end
return core
