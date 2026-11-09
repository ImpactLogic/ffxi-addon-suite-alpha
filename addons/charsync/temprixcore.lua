-- Raw observed Temprix dialogue, not decoded Aeonic completion flags.
local core = {}
core.HEADER = 'captured\tsession\tcharacter\tzone\tnpc_id\tdirection\tpacket\tmode\tpayload_hex'
local menus = {[0x032]=true, [0x033]=true, [0x034]=true}
local function hex(s)
    return (s:gsub('.', function(c) return ('%02x'):format(c:byte()) end))
end
function core.reset(state) state.active=nil end
function core.observe(state, o)
    if o.injected or not o.character or type(o.data)~='string' then return nil end
    local a=state.active
    if a and (a.character~=o.character or a.zone~=o.zone or o.now-a.started>120) then
        core.reset(state) a=nil
    end
    local addressed = (o.direction=='incoming' and (menus[o.id] or o.id==0x036)) or
        (o.direction=='outgoing' and o.id==0x05B)
    if addressed and o.npc_name and o.npc_name:lower()=='temprix' then
        if not a or a.npc_id~=o.npc_id then
            state.serial=(state.serial or 0)+1
            a={character=o.character, zone=o.zone, npc_id=o.npc_id, started=o.now,
                session=o.captured .. '-' .. tostring(o.now) .. '-' .. state.serial}
            state.active=a
        end
    elseif addressed and o.npc_id and (menus[o.id] or o.direction=='outgoing') then
        core.reset(state) return nil
    end
    if not a then return nil end
    local accepted = addressed and o.npc_id==a.npc_id or
        (o.direction=='incoming' and o.id==0x05C) or o.direction=='text'
    if not accepted then return nil end
    state.rows=(state.rows or 0)+1
    state.last=o.captured
    return table.concat({o.captured,a.session,o.character,tostring(o.zone or '-'),
        tostring(a.npc_id or '-'),o.direction,o.id and ('0x%03x'):format(o.id) or '-',
        tostring(o.mode or '-'),hex(o.data)}, '\t')
end
return core
