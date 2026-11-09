--Battle Lines core: the combat-meter engine, pure Lua (no Windower), driven offline by tools/test-battlelines.lua.
--
--Built for the combat information the FFXI client receives:
--  * SEGMENTS: a fight starts at the first party damage on an enemy (or the first enemy damage on YOU) and ends
--    after `idle` seconds without any. Enemy damage on another party member only joins a fight that is already
--    running: a member dying to a boss you are not fighting (Sortie, Leshonn 2026-10-07) is not your engagement. The last `max_fights` are kept; "overall" adds them all up until a reset.
--  * FOUR VIEWS per segment: damage done, damage taken, healing, deaths.
--  * PLAYERS: party, alliance and trusts by mob id; a pet's damage and healing are credited to its owner (by-ability
--    rows keep "Pet:" in the name so it stays visible).
--  * RATES: burst uses each player's own action window (gaps longer than `idle` are downtime); fight uses the
--    whole fight length.
--  * ABILITIES per player: melee, ranged, each WS, each spell (with magic-burst count), each JA, pet abilities,
--    skillchains the player closed, added effects; for taken: each source and what it used; for healing: each spell/JA.
--  * DEATHS: who died, when in the fight, to what, and the last hits taken before it.
--
--Message ids are the ones combatlog/live.lua uses (Windower res/action_messages.lua, checked against our own rows):
--  1 hit, 67 crit, 15 / 63 miss; 352 / 576 / 577 ranged hit, 353 ranged crit; 185 / 187 / 197 WS damage;
--  2 / 252 spell (252 magic burst), 264 / 265 AoE; 110 / 157 / 317 ability damage; 288-302, 767, 768 skillchain;
--  229 additional effect damage. Healing (res/action_messages.lua, read 2026-09-30): 7 spell, 24 / 263 / 367 plain
--  "recovers N HP", 102 / 306 / 318 ability, 103 / 238 weapon skill; the amount is what was restored, overcure is not
--  exposed. Deaths: 6 / 97 "defeats", 20 / 113 / 406 / 605 "falls to the ground".
local M = {}

local MELEE_HIT   = {[1] = true, [67] = true}
local MELEE_CRIT  = {[67] = true}
local RANGED_HIT  = {[352] = true, [353] = true, [576] = true, [577] = true}
local RANGED_CRIT = {[353] = true}
local WS_DAMAGE   = {[185] = true, [187] = true, [197] = true}
local MAGIC_DAMAGE = {[2] = true, [252] = true, [264] = true, [265] = true}
local JA_DAMAGE   = {[110] = true, [157] = true, [264] = true, [317] = true}
local ADDED = {[229] = true}
local SC = {[767] = true, [768] = true}
for id = 288, 302 do SC[id] = true end
local ADD_CATS = {[1] = true, [2] = true, [3] = true, [6] = true, [13] = true}
local HEAL = {[7] = true, [24] = true, [102] = true, [103] = true, [238] = true, [263] = true, [306] = true, [318] = true, [367] = true}
local DEATH = {[6] = true, [20] = true, [97] = true, [113] = true, [406] = true, [605] = true}
M.SC = SC
M.KINDS = {'damage', 'taken', 'healing', 'deaths'}
M.STATS = {
    damage = {'total', 'rate', 'share', 'events', 'average', 'max', 'crits', 'bursts'},
    taken = {'total', 'rate', 'share', 'events', 'average', 'max'},
    healing = {'total', 'rate', 'share', 'events', 'average', 'max'},
}

local RECENT_HITS = 8   -- incoming hits kept per player for the death report

function M.new(opts)
    opts = opts or {}
    local s = {idle = opts.idle or 10, max_fights = opts.max_fights or 10, fights = {}, current = nil, count = 0,
        on_close = opts.on_close}
    s.overall = M.segment('Overall', nil)
    return s
end

function M.segment(name, now)
    return {name = name, start = now, last = now, total = 0, players = {}, mobs = {},
        taken = {total = 0, players = {}}, healing = {total = 0, players = {}}, deaths = {}}
end

-- The bucket a view reads: damage lives on the segment itself, the others in their own tables.
local function bucket(seg, kind)
    if kind == 'taken' then return seg.taken elseif kind == 'healing' then return seg.healing end
    return seg
end

local function player_in(b, id, name)
    local p = b.players[id]
    if not p then
        p = {id = id, name = name or ('#' .. tostring(id)), total = 0, active = 0, last_t = nil, abilities = {}, recent = {}}
        b.players[id] = p
    end
    if name and p.name:sub(1, 1) == '#' then p.name = name end
    return p
end

local function record(seg, b, id, name, key, amount, crit, burst, now, idle, src)
    if seg.start == nil then seg.start = now end
    local p = player_in(b, id, name)
    p.total = p.total + amount
    b.total = b.total + amount
    if p.last_t and now - p.last_t <= idle then p.active = p.active + (now - p.last_t) end
    p.last_t = now
    local a = p.abilities[key]
    if not a then a = {total = 0, n = 0, crits = 0, max = 0, bursts = 0} p.abilities[key] = a end
    a.total, a.n = a.total + amount, a.n + 1
    if crit then a.crits = a.crits + 1 end
    if burst then a.bursts = a.bursts + 1 end
    if amount > a.max then a.max = amount end
    if src then   -- a hit taken: keep the last few for the death report
        table.insert(p.recent, {t = now, src = src, key = key, amount = amount})
        while #p.recent > RECENT_HITS do table.remove(p.recent, 1) end
    end
    seg.last = now
end

local function record_mob(seg, mob_id, mob_name, amount)
    if not mob_id then return end
    local m = seg.mobs[mob_id]
    if not m then m = {name = mob_name or ('#' .. tostring(mob_id)), total = 0} seg.mobs[mob_id] = m end
    m.total = m.total + amount
    if mob_name then m.name = mob_name end
end

local function close_current(s)
    local c = s.current
    if not c then return end
    table.insert(s.fights, 1, c)
    while #s.fights > s.max_fights do table.remove(s.fights) end
    s.current = nil
    if s.on_close then pcall(s.on_close, c) end
end

-- The segment this event belongs to; closes the running one after `idle` seconds without activity. With
-- start == false no new fight is opened (healing and deaths only count inside a fight).
local function segment_for(s, now, start)
    local c = s.current
    if c and now - c.last > s.idle then close_current(s) c = nil end
    if not c and start ~= false then
        c = M.segment('Fight', now)
        s.count = s.count + 1
        c.number = s.count
        s.current = c
    end
    return c
end

-- ctx: owner(id) -> credited player id (the id itself for a member, the owner for a pet, nil for anyone else),
--      member(id) -> id only for a real party member (not a pet), enemy(id) -> true for a target that counts as an
--      enemy, name(id) -> display name, ability(category, param) -> name, self(id) -> true for the local player
--      (optional: without it any party member being hit opens a fight, as in 0.6.0 and earlier).
function M.add_action(s, act, now, ctx)
    local owner = ctx.owner(act.actor_id)
    local member = ctx.member or function(id) return ctx.owner(id) == id and id or nil end
    local is_pet = owner ~= nil and owner ~= act.actor_id
    local cat = act.category
    local actor_name = ctx.name(act.actor_id)
    local damage, taken, healing, deaths = {}, {}, {}, {}
    for _, target in pairs(act.targets or {}) do
        local tmember = member(target.id)
        for _, a in pairs(target.actions or {}) do
            local m, amt = a.message, a.param
            if owner and ctx.enemy(target.id) then
                if amt and amt > 0 then
                    if cat == 1 and MELEE_HIT[m] then
                        damage[#damage + 1] = {is_pet and 'Pet: melee' or 'Melee', amt, MELEE_CRIT[m], false, target.id}
                    elseif cat == 2 and RANGED_HIT[m] then
                        damage[#damage + 1] = {'Ranged', amt, RANGED_CRIT[m], false, target.id}
                    elseif cat == 3 and WS_DAMAGE[m] then
                        damage[#damage + 1] = {(is_pet and 'Pet: ' or 'WS: ') .. ctx.ability(3, act.param), amt, false, false, target.id}
                    elseif cat == 4 and MAGIC_DAMAGE[m] then
                        damage[#damage + 1] = {'Spell: ' .. ctx.ability(4, act.param), amt, false, m == 252, target.id}
                    elseif cat == 6 and JA_DAMAGE[m] then
                        damage[#damage + 1] = {'JA: ' .. ctx.ability(6, act.param), amt, false, false, target.id}
                    elseif cat == 13 and (WS_DAMAGE[m] or JA_DAMAGE[m] or MAGIC_DAMAGE[m]) then
                        damage[#damage + 1] = {'Pet: ' .. ctx.ability(13, act.param), amt, false, false, target.id}
                    end
                end
                if a.has_add_effect and ADD_CATS[cat] and a.add_effect_param and a.add_effect_param > 0 then
                    local am = a.add_effect_message
                    if SC[am] then damage[#damage + 1] = {'Skillchain', a.add_effect_param, false, false, target.id}
                    elseif ADDED[am] then damage[#damage + 1] = {'Added effect', a.add_effect_param, false, false, target.id} end
                end
            end
            if tmember and not owner and amt and amt > 0 then
                -- an enemy hitting a party member
                local what
                if cat == 1 and MELEE_HIT[m] then what = 'Melee'
                elseif WS_DAMAGE[m] or MAGIC_DAMAGE[m] or JA_DAMAGE[m] then what = ctx.ability(cat, act.param) end
                if what then taken[#taken + 1] = {tmember, (actor_name or '?') .. ': ' .. what, amt, actor_name or '?'} end
            end
            if tmember and owner and amt and amt > 0 and HEAL[m] then
                local owner_key = cat == 4 and 'Spell: ' or (cat == 6 and 'JA: ') or (cat == 3 and 'WS: ') or (cat == 5 and 'Item: ') or 'Heal: '
                healing[#healing + 1] = {(is_pet and 'Pet: ' or '') .. owner_key .. ctx.ability(cat, act.param), amt}
                healing[#healing].by = owner
            end
            if tmember and DEATH[m] then
                deaths[#deaths + 1] = {tmember, (not owner) and actor_name or nil}
            end
        end
    end
    local function both(fn)
        local seg = segment_for(s, now, true)
        fn(seg)
        fn(s.overall)
    end
    for _, e in ipairs(damage) do
        local name, mob_name = ctx.name(owner), ctx.name(e[5])
        both(function(seg)
            record(seg, seg, owner, name, e[1], e[2], e[3], e[4], now, s.idle)
            record_mob(seg, e[5], mob_name, e[2])
        end)
    end
    for _, e in ipairs(taken) do
        local opens = ctx.self == nil or ctx.self(e[1])
        if opens or segment_for(s, now, false) then
            both(function(seg) record(seg, seg.taken, e[1], ctx.name(e[1]), e[2], e[3], false, false, now, s.idle, e[4]) end)
        end
    end
    if #healing > 0 and segment_for(s, now, false) then
        for _, e in ipairs(healing) do
            both(function(seg) record(seg, seg.healing, e.by, ctx.name(e.by), e[1], e[2], false, false, now, s.idle) end)
        end
    end
    if #deaths > 0 and segment_for(s, now, false) then
        for _, d in ipairs(deaths) do
            local name = ctx.name(d[1])
            both(function(seg)
                local p = seg.taken.players[d[1]]
                local recent = {}
                if p then for i, h in ipairs(p.recent) do recent[i] = h end end
                seg.deaths[#seg.deaths + 1] = {id = d[1], name = name or ('#' .. tostring(d[1])), at = now - (seg.start or now),
                    killer = d[2], recent = recent}
                seg.last = now
            end)
        end
    end
end

-- True while a fight is running (activity within `idle` seconds).
function M.in_fight(s, now) return s.current ~= nil and now - s.current.last <= s.idle end

-- Close a running fight that has gone quiet, so it reaches the history (and on_close) without waiting for the next hit.
function M.tick(s, now)
    if s.current and now - s.current.last > s.idle then close_current(s) end
end

-- The segment to show: 'current' (the running fight, or the newest finished one), 'overall', 'last' (the newest
-- closed fight), or a number (n-th newest closed fight).
function M.pick(s, which)
    if which == 'overall' then return s.overall end
    if which == 'last' then return s.fights[1] or s.current end
    local n = tonumber(which)
    if n then return s.fights[n] end
    return s.current or s.fights[1]
end

-- Segment choices for cycling: current, last, 2, 3, ... (as many as exist), overall.
function M.choices(s)
    local out = {'current'}
    for i = 1, #s.fights do out[#out + 1] = i == 1 and 'last' or tostring(i) end
    out[#out + 1] = 'overall'
    return out
end

-- The mob that took the most damage names the fight (or, with no damage dealt, the one that hit the party most).
function M.label(seg)
    if not seg then return '' end
    if seg.name == 'Overall' then return 'Overall' end
    local best, top = nil, -1
    for _, m in pairs(seg.mobs) do if m.total > top then best, top = m.name, m.total end end
    if best then return best end
    for _, p in pairs(seg.taken.players) do
        for key, a in pairs(p.abilities) do
            local src = key:match('^(.-): ')
            if src and a.total > top then best, top = src, a.total end
        end
    end
    return best or 'Fight'
end

function M.duration(seg)
    if not seg or not seg.start then return 0 end
    return math.max(1, seg.last - seg.start)
end

-- Sorted rows for the bar list. The selected stat sets both order and bar length; all are derived from
-- already-recorded action results, so no new packet interpretation is needed.
function M.rows(seg, mode, kind, stat)
    local out = {}
    if not seg then return out end
    local b = bucket(seg, kind)
    local dur = M.duration(seg)
    local top = 0
    stat = stat or 'total'
    for _, p in pairs(b.players) do
        local time = mode == 'fight' and dur or math.max(1, p.active)
        local r = {id = p.id, name = p.name, total = p.total, dps = p.total / time,
            pct = b.total > 0 and p.total / b.total or 0, events = 0, max = 0, crits = 0, bursts = 0}
        for _, a in pairs(p.abilities) do
            r.events = r.events + a.n
            r.max = math.max(r.max, a.max)
            r.crits = r.crits + a.crits
            r.bursts = r.bursts + a.bursts
        end
        r.average = r.events > 0 and r.total / r.events or 0
        r.value = stat == 'rate' and r.dps or (stat == 'share' and r.pct or r[stat] or r.total)
        out[#out + 1] = r
        if r.value > top then top = r.value end
    end
    table.sort(out, function(a, b2)
        if a.value ~= b2.value then return a.value > b2.value end
        if a.total ~= b2.total then return a.total > b2.total end
        return a.name < b2.name
    end)
    for _, r in ipairs(out) do r.frac = top > 0 and r.value / top or 0 end
    return out
end

function M.total(seg, kind)
    if not seg then return 0 end
    return bucket(seg, kind).total
end

-- One player's ability rows for a view, biggest first.
function M.breakdown(seg, id, kind)
    local out = {}
    local b = seg and bucket(seg, kind)
    local p = b and b.players[id]
    if not p then return out, nil end
    for key, a in pairs(p.abilities) do
        out[#out + 1] = {key = key, total = a.total, n = a.n, avg = a.n > 0 and a.total / a.n or 0, max = a.max,
            crits = a.crits, bursts = a.bursts, pct = p.total > 0 and a.total / p.total or 0}
    end
    table.sort(out, function(a, b2) if a.total ~= b2.total then return a.total > b2.total end return a.key < b2.key end)
    local top = out[1] and out[1].total or 0
    for _, r in ipairs(out) do r.frac = top > 0 and r.total / top or 0 end
    return out, p
end

-- Damage categories for the optional compact mix and the player's ability view. Skillchain damage is
-- already recorded separately and credited to the closer; pet abilities stay in Other.
function M.damage_mix(seg, id)
    local p = seg and seg.players[id]
    if not p then return nil end
    local ws, sc = 0, 0
    for key, a in pairs(p.abilities) do
        if key:sub(1, 4) == 'WS: ' then ws = ws + a.total
        elseif key == 'Skillchain' then sc = sc + a.total end
    end
    return {ws = ws, sc = sc, other = math.max(0, p.total - ws - sc), total = p.total}
end

-- Deaths in a segment, in order. Each has .recent = the last hits that player took before dying.
function M.deaths(seg)
    return seg and seg.deaths or {}
end

function M.reset(s)
    s.fights, s.current, s.count = {}, nil, 0
    s.overall = M.segment('Overall', nil)
end

function M.big(n)
    n = n or 0
    if n >= 1000000 then return ('%.2fm'):format(n / 1000000) end
    if n >= 10000 then return ('%.1fk'):format(n / 1000) end
    return tostring(math.floor(n + 0.5))
end

function M.clock(secs)
    secs = math.floor(secs or 0)
    return ('%d:%02d'):format(math.floor(secs / 60), secs % 60)
end

-- One tab-separated line per player per view per ability for a finished fight: what data/fights.tsv holds.
-- Columns: fight, mob, seconds, view, player, ability, total, uses.
function M.tsv_rows(seg)
    local out = {}
    local label, secs = M.label(seg), math.floor(M.duration(seg))
    for _, kind in ipairs({'damage', 'taken', 'healing'}) do
        for id, p in pairs(bucket(seg, kind).players) do
            for key, a in pairs(p.abilities) do
                out[#out + 1] = table.concat({tostring(seg.number or 0), label, secs, kind, p.name, key, a.total, a.n}, '\t')
            end
        end
    end
    table.sort(out)
    return out
end

return M
