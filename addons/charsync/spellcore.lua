-- get_spells learned flags are independent of current-job castability.
-- Official contract: github.com/Windower/Lua/wiki/FFXI-Functions#get_spells
local core={}
local function integer(v) return type(v)=='number' and v>=0 and v<=65535 and v==math.floor(v) end
local function clean(v) return tostring(v or '-'):gsub('[\t\r\n]',' ') end
local function view(value)
    local flags,bad={},false
    if type(value)~='table' then return flags,true end
    for key,flag in pairs(value) do
        if integer(key) and type(flag)=='boolean' then flags[key]=flag
        else bad=true end
    end
    return flags,bad
end
function core.capture(o)
    local a,bad_a=view(o.before)
    local b,bad_b=view(o.after)
    if o.logged_in~=true then a,b={},{} bad_a,bad_b=true,true end
    local stable=o.logged_in==true and not bad_a and not bad_b
    local count=0
    for id,flag in pairs(a) do count=count+1 if b[id]~=flag then stable=false end end
    for id in pairs(b) do if a[id]==nil then stable=false end end
    if count==0 then stable=false end
    local rows={}
    for id,flag in pairs(b) do
        local resource=o.resources and o.resources[id]
        rows[#rows+1]={id=id,flag=flag,name=resource and (resource.en or resource.english) or '-',
            status=flag and 'learned_flag_observed' or 'false_flag_observed_not_removal'}
    end
    table.sort(rows,function(x,y) return x.id<y.id end)
    return {character=o.character,epoch=o.epoch,reason=o.reason,version=o.version,
        stable=stable,invalid_entries=bad_a or bad_b,rows=rows,
        completeness='api_flags_only_not_verified_exhaustive',current_castability=nil}
end
function core.encode(c)
    local lines={table.concat({'h','1',clean(c.character),clean(c.epoch),clean(c.reason),clean(c.version),
        tostring(c.stable),tostring(c.invalid_entries),c.completeness,'current_castability=unknown','rows='..#c.rows},'\t')}
    for _,r in ipairs(c.rows) do lines[#lines+1]=table.concat({'s',r.id,tostring(r.flag),clean(r.name),r.status},'\t') end
    return table.concat(lines,'\n')..'\n'
end
return core
