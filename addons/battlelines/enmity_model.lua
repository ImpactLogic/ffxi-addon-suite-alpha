-- Enmity model for the Battle Lines Enmity tab. Pure Lua; all values are estimates from observed packets.
-- Copied from addons/enmitylines/enmitycore.lua (same CE/VE rules) plus a short per-enemy list of observed target switches.
local M = {}
local DAMAGE = {
    [1] = {[1]=true,[67]=true},
    [2] = {[352]=true,[353]=true,[576]=true,[577]=true},
    [3] = {[185]=true,[187]=true,[197]=true},
    [4] = {[2]=true,[252]=true,[264]=true,[265]=true},
    [6] = {[110]=true,[157]=true,[264]=true,[317]=true},
    [13] = {[185]=true,[187]=true,[197]=true,[110]=true,[157]=true,[317]=true},
}

function M.new() return {mobs = {}, order = {}} end

local function mob_for(state, id, name, now)
    local mob = state.mobs[id]
    if not mob then
        mob = {id=id, name=name or ('#'..tostring(id)), players={}, last=now,
               observed=nil, ambiguous=0, packet_count=0}
        state.mobs[id] = mob
        state.order[#state.order+1] = id
        if #state.order > 30 then state.mobs[table.remove(state.order, 1)] = nil end
    end
    if name then mob.name = name end
    mob.last = now
    return mob
end

local function player_for(mob, id, name, now)
    local p = mob.players[id]
    if not p then
        p = {id=id, name=name or ('#'..tostring(id)), ce=0, ve=0,
             at=now, damage=0, known=0, unknown=0}
        mob.players[id] = p
    end
    if name then p.name = name end
    return p
end

local function decay(p, now)
    p.ve = math.max(0, p.ve - math.max(0, now - p.at) * 60)
    p.at = now
end

local function gain(p, ce, ve, now)
    decay(p, now)
    p.ce = math.min(30000, p.ce + ce)
    p.ve = math.min(30000, p.ve + ve)
    p.known = p.known + 1
end

-- ctx.owner(id), ctx.name(id), ctx.ability(category,param).
-- Returns observations for the caller's capped local log.
function M.action(state, act, now, ctx, opts)
    if type(act) ~= 'table' or not act.actor_id then return {} end
    opts = opts or {}
    local owner = ctx.owner(act.actor_id)
    local events = {}
    if owner then
        for _, target in pairs(act.targets or {}) do
            if target.id and not ctx.owner(target.id) then
                local mob = mob_for(state, target.id, ctx.name(target.id), now)
                local p = player_for(mob, owner, ctx.name(owner), now)
                local amount = 0
                for _, a in pairs(target.actions or {}) do
                    if DAMAGE[act.category] and DAMAGE[act.category][a.message]
                            and type(a.param) == 'number' and a.param > 0 then
                        amount = amount + a.param
                    end
                end
                local ability = ctx.ability(act.category, act.param)
                if act.category == 6 and ability == 'Provoke' then
                    gain(p, 1, 1800, now)
                    events[#events+1] = {mob=mob.id, actor=owner, kind='Provoke', ce=1, ve=1800}
                elseif amount > 0 and opts.damage ~= false then
                    local ce = amount * (opts.coefficient or 0)
                    gain(p, ce, 3 * ce, now)
                    p.damage = p.damage + amount
                    events[#events+1] = {mob=mob.id, actor=owner, kind='damage estimate', damage=amount, ce=ce, ve=3*ce}
                else
                    p.unknown = p.unknown + 1
                    events[#events+1] = {mob=mob.id, actor=owner, kind='unmodeled', category=act.category, ability=ability}
                end
            end
        end
    else
        local party_targets, count = {}, 0
        for _, target in pairs(act.targets or {}) do
            if ctx.owner(target.id) and not party_targets[target.id] then
                party_targets[target.id] = true
                count = count + 1
            end
        end
        if count > 0 then
            local mob = mob_for(state, act.actor_id, ctx.name(act.actor_id), now)
            mob.packet_count = mob.packet_count + 1
            if count == 1 then
                local id = next(party_targets)
                local prev = mob.observed
                if prev and prev.kind == 'acted on' and prev.id ~= id then
                    mob.switches = mob.switches or {}
                    table.insert(mob.switches, 1, {at = now, from = prev.name or ('#' .. tostring(prev.id)),
                        to = ctx.name(id) or ('#' .. tostring(id))})
                    while #mob.switches > 3 do table.remove(mob.switches) end
                end
                mob.observed = {id=id, name=ctx.name(id), at=now, kind='acted on'}
                events[#events+1] = {mob=mob.id, actor=act.actor_id, kind='observed target', target=id}
            else
                mob.ambiguous = mob.ambiguous + 1
                mob.observed = {at=now, kind='multiple targets'}
                events[#events+1] = {mob=mob.id, actor=act.actor_id, kind='multiple targets', count=count}
            end
            -- Damage taken, shadows, status effects and hate-reset moves are not
            -- modeled; the box makes this incompleteness visible.
        end
    end
    return events
end

function M.rows(state, mob_id, now)
    local mob = state.mobs[mob_id]
    if not mob then return {}, nil end
    local rows, top = {}, 0
    for _, p in pairs(mob.players) do
        decay(p, now)
        local total = p.ce + p.ve
        rows[#rows+1] = {id=p.id, name=p.name, ce=p.ce, ve=p.ve, total=total,
                        damage=p.damage, known=p.known, unknown=p.unknown}
        if total > top then top = total end
    end
    table.sort(rows, function(a,b)
        if a.total ~= b.total then return a.total > b.total end
        return a.name < b.name
    end)
    for _, row in ipairs(rows) do row.frac = top > 0 and row.total/top or 0 end
    return rows, mob
end

return M
