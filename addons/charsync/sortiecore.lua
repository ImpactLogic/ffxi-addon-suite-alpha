-- Read-only temporary-bag evidence, isolated from permanent snapshot/removal logic.
-- IDs/names/roles: Windower res/items.lua9894-9926 and retained Category:Sortie.
local core = {}
local items = require('sortie_items')
local function integer(v) return type(v)=='number' and v>=0 and v==math.floor(v) end
local function enabled(v) return v==true or v==1 end
local function clean(v) return tostring(v or '-'):gsub('[\t\r\n]', ' ') end

function core.capture(o)
    local in_scope = o.zone == 133 -- Outer Ra'Kaznar [U], actual Sortie capture zone.
    local a,b,bag = o.before or {},o.after or {},o.bag
    local readable = in_scope and enabled(a.enabled) and enabled(b.enabled) and type(bag)=='table' and bag.enabled~=false and bag.enabled~=0
    local seen,occupied,bad = {},0,false
    if readable then
        for key,it in pairs(bag) do
            if type(key)=='number' then
                if not integer(key) or key<1 or not integer(a.max) or key>a.max or type(it)~='table' then
                    bad=true
                elseif it.id==nil then
                    bad=true
                elseif it.id~=0 then
                    occupied=occupied+1
                    local slot=it.slot or key
                    if not integer(it.id) or not integer(it.count) or it.count<1 or not integer(slot) or slot~=key then
                        bad=true
                    else
                        seen[it.id]=seen[it.id] or {}
                        seen[it.id][#seen[it.id]+1]={slot=slot,count=it.count}
                    end
                end
            end
        end
    end
    local consistent = readable and not bad and integer(a.count) and integer(b.count) and integer(a.max)
        and a.max>0 and a.max==b.max and a.count==b.count and occupied==a.count
        and (bag.count==nil or bag.count==a.count)
    local result={character=o.character,captured_epoch=o.epoch,zone=o.zone,reason=o.reason,
        addon_version=o.version,in_sortie_scope=in_scope,readable=readable,
        count_consistent_read=not not consistent,reported_before=a.count,reported_after=b.count,
        observed_slots=occupied,invalid_entries=bad,run_id=nil,current_usable=nil,items={}}
    for _,item in ipairs(items) do
        local locations=readable and seen[item.id] or nil
        local count=0
        for _,v in ipairs(locations or {}) do count=count+v.count end
        result.items[#result.items+1]={id=item.id,name=item.name,family=item.family,
            retention=item.retention,locations=locations or {},
            observed_count=locations and count or (consistent and 0 or nil),
            status=locations and 'observed_present' or (consistent and 'not_observed_complete_read' or 'unknown')}
    end
    return result
end

function core.encode(c)
    local lines={table.concat({'h','1',clean(c.character),clean(c.captured_epoch),clean(c.zone),
        clean(c.reason),clean(c.addon_version),'clock=unix_epoch','run_id=unknown','current_usable=unknown'},'\t'),
        table.concat({'b','temporary',tostring(c.in_sortie_scope),tostring(c.readable),
            tostring(c.count_consistent_read),clean(c.reported_before),clean(c.reported_after),
            clean(c.observed_slots),tostring(c.invalid_entries)},'\t')}
    for _,item in ipairs(c.items) do
        local slots={}
        for _,v in ipairs(item.locations) do slots[#slots+1]=v.slot..':'..v.count end
        table.sort(slots)
        lines[#lines+1]=table.concat({'i',item.id,clean(item.name),item.family,item.retention,
            item.status,clean(item.observed_count),#slots>0 and table.concat(slots,',') or '-'},'\t')
    end
    return table.concat(lines,'\n')..'\n'
end

return core
