-- Decision-first presentation only. No saved snapshots or inferred item movement.
local V = {}
local C = {text={228,234,242}, dim={154,165,181}, ready={108,222,164},
    active={117,207,246}, warning={255,184,106}, danger={255,126,139}}
local function color(role, text)
    local c = C[role]
    return ('\\cs(%d,%d,%d)%s\\cr'):format(c[1],c[2],c[3],text)
end

-- A zero capacity, absent count or ambiguous availability is not an empty bag.
function V.read(info)
    if not info then return nil, 'UNKNOWN' end
    if info.enabled == false or info.enabled == 0 then return nil, 'NOT ENABLED' end
    if info.enabled ~= true and info.enabled ~= 1 then return nil, 'AVAILABILITY UNKNOWN' end
    local used, maximum = tonumber(info.count), tonumber(info.max)
    if not used or not maximum or maximum <= 0 or used < 0 or used > maximum
        or used % 1 ~= 0 or maximum % 1 ~= 0 then return nil, 'COUNT UNKNOWN' end
    return {used=used, max=maximum, free=maximum-used, frac=used/maximum}
end

local function status(row, opts)
    if row.free == 0 then return 'danger', 'FULL' end
    if row.frac >= (opts.crit or .95) then return 'warning', 'NEAR FULL' end
    if row.frac >= (opts.warn or .8) then return 'warning', 'FILLING' end
    return 'ready', 'ROOM'
end

function V.render(infos, opts, definitions)
    local rows, unknown, disabled = {}, 0, 0
    for index, bag in ipairs(definitions) do
        -- Preserve existing per-bag choices, including wardrobe sum visibility.
        local shown = opts.show and opts.show[bag.key]
        if bag.ward and (opts.wardrobes or 'sum') == 'sum' then shown=opts.show and opts.show.wardrobe end
        if shown then
            local r, reason = V.read(infos[bag.id])
            if not r then
                r={reason=reason}
                if reason == 'NOT ENABLED' then disabled=disabled+1 else unknown=unknown+1 end
            end
            r.label, r.id, r.index = bag.label, bag.id, index
            rows[#rows+1]=r
        end
    end
    table.sort(rows, function(a,b)
        if (a.id==0) ~= (b.id==0) then return a.id==0 end
        if (a.frac~=nil) ~= (b.frac~=nil) then return a.frac~=nil end
        if a.frac and a.frac~=b.frac then return a.frac>b.frac end
        return a.index<b.index
    end)
    local lines, bars = {}, {}
    local focus=rows[1]
    local role='normal'
    if not focus then
        lines[1]=color('dim','No bags selected - //bags show inventory')
    elseif focus.reason then
        role='warning'
        lines[1]=color('warning','Check bag state - ' .. focus.label)
    else
        local label
        role,label=status(focus,opts)
        local action=focus.free==0 and 'Free a slot' or (role=='warning' and 'Review bag space' or 'Space available')
        lines[1]=color(role,action .. ' - ' .. focus.label)
    end
    local shown, visible_rows=0,0
    for _,r in ipairs(rows) do
        if opts.layout=='detailed' or r==focus or (r.frac and shown<3) then
            visible_rows=visible_rows+1
            if r.reason then
                lines[#lines+1]=color('warning',r.label .. '  ' .. r.reason)
            else
                local tone,label=status(r,opts)
                lines[#lines+1]=color('text',('%-10s %2d free  %d/%d'):format(r.label,r.free,r.used,r.max))
                    .. '  ' .. color(tone,label)
                -- Bars are behind text; the glue adds one for the title line.
                bars[#bars+1]={line=#lines,frac=r.frac,fill=true,rgba={C[tone][1],C[tone][2],C[tone][3],48}}
                shown=shown+1
            end
        end
    end
    if opts.layout~='detailed' and #rows>visible_rows then
        local omitted=#rows-visible_rows
        lines[#lines+1]=color(unknown>0 and 'warning' or 'dim',('+ %d bag%s - detailed; %d unknown; %d not enabled'):format(omitted,omitted==1 and '' or 's',unknown,disabled))
    end
    if opts.layout=='detailed' then lines[#lines+1]=color('dim','Counts from client; updates every second') end
    return lines,bars,role
end
return V
