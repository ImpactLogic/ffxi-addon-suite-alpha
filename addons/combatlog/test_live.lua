-- Offline test for addons/combatlog/live.lua (the box's running totals). No Windower needed.
-- Run: luajit addons/combatlog/test_live.lua [combat-YYYY-MM-DD.tsv Char]   (from the repo root)
-- With a file, it also replays that day's own rows through live.lua and prints the box.
package.path = (arg[0]:match('^(.*)[/\\]') or '.') .. '/?.lua;' .. package.path
local live = require('live')

local fails, checks = 0, 0
local function eq(got, want, label)
    checks = checks + 1
    if got ~= want then
        fails = fails + 1
        print(('FAIL %s: got %s, want %s'):format(label, tostring(got), tostring(want)))
    end
end

local ME, MOB, MOB2, PAL = 1, 100, 101, 2
local function enemy(id) return id == MOB or id == MOB2 end
local function name(id) return id == MOB and 'Bat' or id == MOB2 and 'Crab' or nil end
local function melee(msgs, target)
    local acts = {}
    for i, m in ipairs(msgs) do acts[i] = {message = m[1], param = m[2] or 0} end
    return {actor_id = ME, category = 1, param = 0, targets = {{id = target or MOB, actions = acts}}}
end

-- Melee: hits, crits, misses, rounds
local s = live.new()
live.action(s, melee({{1, 100}, {67, 200}}), 0, 0, false, enemy, name)
live.action(s, melee({{15}}), 3, 150, false, enemy, name)
live.action(s, melee({{1, 100}, {1, 100}, {67, 300}}), 6, 400, false, enemy, name)
eq(s.melee.hits, 5, 'hits')
eq(s.melee.crits, 2, 'crits')
eq(s.melee.misses, 1, 'misses')
eq(s.damage.melee, 800, 'melee damage')
eq(s.rounds.n, 3, 'rounds')
eq(#s.rounds.gaps, 2, 'two gaps')
eq(s.rounds.tp[2], 250, 'TP per round is the rise between rounds')
eq(s.active, 6, 'fighting time is the gaps between damage')

-- A long pause is downtime, not fighting
live.action(s, melee({{1, 100}}), 60, 500, false, enemy, name)
eq(s.active, 6, 'a 54 s gap is not counted')
eq(#s.rounds.gaps, 2, 'nor is it a round gap')

-- WS with a skillchain: kept apart, TP from the send
live.ws_sent(s, 93, 2450)
live.action(s, {actor_id = ME, category = 3, param = 93, targets = {{id = MOB, actions = {
    {message = 185, param = 20000, has_add_effect = true, add_effect_message = 288, add_effect_param = 50000}}}}},
    62, 0, false, enemy, name)
eq(s.damage.ws, 20000, 'WS damage')
eq(s.damage.sc, 50000, 'skillchain damage kept apart')
eq(s.last_ws.tp, 2450, 'TP the WS was sent at')
eq(s.ws[93].n, 1, 'WS count')
eq(s.sc.last_msg, 288, 'SC message')

-- WS miss
live.action(s, {actor_id = ME, category = 3, param = 93, targets = {{id = MOB, actions = {{message = 188, param = 0}}}}},
    64, 0, false, enemy, name)
eq(s.ws[93].misses, 1, 'WS miss counted')
eq(s.last_ws.miss, true, 'last WS shows the miss')

-- Category 7 (WS readying) add-effect fields are not damage
local before = s.total
live.action(s, {actor_id = ME, category = 7, param = 0, targets = {{id = MOB, actions = {
    {message = 43, param = 0, has_add_effect = true, add_effect_message = 288, add_effect_param = 999}}}}},
    65, 0, false, enemy, name)
eq(s.total, before, 'category 7 adds nothing')

-- Enspell-type added damage
live.action(s, melee({{1, 100}}), 66, 0, false, enemy, name)
live.action(s, {actor_id = ME, category = 1, param = 0, targets = {{id = MOB, actions = {
    {message = 1, param = 10, has_add_effect = true, add_effect_message = 229, add_effect_param = 40}}}}},
    67, 0, false, enemy, name)
eq(s.damage.added, 40, 'added effect damage')

-- Actions on non-enemies are ignored (a cure on yourself, a buff on a party member)
before = s.total
live.action(s, {actor_id = ME, category = 4, param = 1, targets = {{id = PAL, actions = {{message = 2, param = 500}}}}},
    68, 0, false, enemy, name)
eq(s.total, before, 'damage "to" a party member is not counted')

-- Pet damage is one bucket
live.action(s, {actor_id = 50, category = 1, param = 0, targets = {{id = MOB, actions = {{message = 1, param = 77}}}}},
    69, nil, true, enemy, name)
eq(s.damage.pet, 77, 'pet damage')
eq(s.melee.hits, 8, 'pet hits are not your hits')

-- Kills: only targets you damaged
live.defeated(s, MOB, 80)
eq(s.kills.n, 1, 'kill counted')
eq(s.kills.last, 80, 'ttk from your first action on it')
live.defeated(s, MOB, 81)
eq(s.kills.n, 1, 'a second defeat message for the same mob is not a second kill')
live.defeated(s, 999, 82)
eq(s.kills.n, 1, 'a mob you never hit is not your kill')

-- Aftermath uptime
live.sample_buffs(s, {272, 40}, true)
live.sample_buffs(s, {270}, true)
live.sample_buffs(s, {40}, true)
live.sample_buffs(s, {272}, false)
eq(s.am.engaged, 3, 'samples only while engaged')
eq(s.am.any, 2, 'any aftermath')
eq(s.am.lv3, 1, 'AM3')

-- Formatting
eq(live.big(1234567), '1.23M', 'millions')
eq(live.big(57657), '57,657', 'thousands')
eq(live.big(999), '999', 'small')
eq(live.clock(3725), '1:02:05', 'hours')
eq(live.clock(41), '0:41', 'seconds')

-- Render: all three views, none crash, n kept on the hit rate
local ropts = {target_id = MOB, target_hpp = 0,
    ws_name = function() return 'Upheaval' end, sc_name = function() return 'Light' end}
local out = table.concat(live.render(s, 83, ropts), '\n')
eq(out:find('n=9', 1, true) ~= nil, true, 'damage view: hit rate shows n')
eq(out:find('DAMAGE', 1, true) == 1, true, 'damage view opens with the answer')
eq(out:find('last Upheaval', 1, true) ~= nil, true, 'damage view: last WS named')
eq(out:find('1 kill ', 1, true) ~= nil, true, 'damage view: kills')
-- Sources are listed largest first: SC (50,000) before WS (20,000) before melee
local p_sc, p_ws, p_me = out:find('  sc ', 1, true), out:find('  ws ', 1, true), out:find('  melee ', 1, true)
eq(p_sc < p_ws and p_ws < p_me, true, 'sources sorted by share')
ropts.short = true
eq(#live.render(s, 83, ropts), 2, 'short view: DAMAGE and FIGHT only')
ropts.short = nil
local diag = table.concat(live.render_diag(s, 83, ropts), '\n')
eq(diag:find('n=9', 1, true) ~= nil, true, 'diag view: hit rate shows n')
eq(diag:find('kills 1', 1, true) ~= nil, true, 'diag view: kills')
eq(#live.render(live.new(), 0, {}), 0, 'empty session renders nothing')
eq(#live.render_diag(live.new(), 0, {}), 0, 'empty session renders nothing (diag)')

-- Party share and the mob HP estimate
local p = live.new()
local hp = {[MOB] = 100}
local function hpp(id) return hp[id] end
live.action(p, melee({{1, 1000}}), 0, 0, false, enemy, name, hpp)
eq(p.fights[MOB].hpp0, 100, 'HP% when first hit')
live.party_action(p, {actor_id = PAL, category = 3, param = 1, targets = {{id = MOB, actions = {
    {message = 185, param = 3000, has_add_effect = true, add_effect_message = 288, add_effect_param = 1000}}}}},
    2, enemy, name, hpp)
eq(p.party_total, 5000, 'party total includes you, their WS and their skillchain')
eq(p.total, 1000, 'their damage is not yours')
eq(p.fights[MOB].party, 5000, 'fight party total')
live.party_action(p, {actor_id = PAL, category = 4, param = 1, targets = {{id = ME, actions = {{message = 2, param = 900}}}}},
    3, enemy, name, hpp)
eq(p.party_total, 5000, 'damage on a non-enemy is not counted')
hp[MOB] = 50
local pout = table.concat(live.render(p, 10, {target_id = MOB, target_hpp = 50}), '\n')
eq(pout:find('20% of party', 1, true) ~= nil, true, 'your share shown')
eq(pout:find('mob ~10k HP', 1, true) ~= nil, true, 'mob HP from party damage over HP% lost')
eq(pout:find('~0:10 left', 1, true) ~= nil, true, 'time left at the party pace')
live.defeated(p, MOB, 12)
eq(p.mob_hp.Bat.n, 1, 'mob HP remembered at the kill')
eq(math.floor(p.mob_hp.Bat.sum), 5000, 'at the kill: party damage from 100%')

-- "now" is the last RECENT seconds of fighting
local q = live.new()
for t = 0, 120, 2 do
    live.action(q, melee({{1, t < 60 and 100 or 300}}), t, 0, false, enemy, name)
end
eq(q.active, 120, 'fighting time')
eq(math.floor(live.recent_dps(q) + 0.5), 150, 'recent rate uses only the last 60 s')
eq(live.recent_dps(live.new()), nil, 'no recent rate before 15 s of fighting')

-- Fights: only FIGHTS_KEPT remembered
local f = live.new()
for i = 1, live.FIGHTS_KEPT + 5 do
    live.action(f, melee({{1, 1}}, 1000 + i), i, 0, false, function() return true end, name)
end
local n = 0
for _ in pairs(f.fights) do n = n + 1 end
eq(n, live.FIGHTS_KEPT, 'old fights are forgotten')

-- 0.9.0 magic (SCH): per spell, with magic bursts (252)
do
    local m = live.new()
    local function nuke(id, msg, dmg, t)
        live.action(m, {actor_id = ME, category = 4, param = id, targets = {{id = MOB, actions = {
            {message = msg, param = dmg}}}}}, t, 0, false, enemy, name)
    end
    nuke(496, 2, 10000, 0)       -- plain hit
    nuke(496, 252, 20000, 3)     -- magic burst
    nuke(146, 252, 30000, 6)
    eq(m.magic.n, 3, 'three nukes')
    eq(m.magic.mb, 2, 'two bursts')
    eq(m.magic.spells[496].n, 2, 'per spell count')
    eq(m.magic.spells[496].mb, 1, 'per spell bursts')
    eq(m.damage.magic, 60000, 'magic damage')
    eq(m.magic.last.mb, true, 'last was a burst')
    local L = live.render(m, 6, {spell_name = function(id) return id == 146 and 'Fire V' or 'Thunder V' end})
    local joined = table.concat(L, '\n')
    eq(joined:find('20,000 avg  n=3  MB 67%', 1, true) ~= nil, true, 'magic line: avg, n, MB rate')
    eq(joined:find('last Fire V 30,000 MB', 1, true) ~= nil, true, 'last spell named with MB')
end

-- 0.9.0 damage taken (RUN): only what reached you; shared attacks against the party's median
do
    local t = live.new()
    local function party(id) return id == PAL or id == 3 or id == 4 end
    local function hit(cat, id, targets, now)
        live.taken(t, {actor_id = MOB, category = cat, param = id, targets = targets}, now, ME, party, 'Bat')
    end
    hit(1, 0, {{id = ME, actions = {{message = 1, param = 300}}}}, 0)
    hit(1, 0, {{id = ME, actions = {{message = 15, param = 0}}}}, 2)
    hit(11, 2000, {{id = ME, actions = {{message = 185, param = 900}}},
        {id = PAL, actions = {{message = 185, param = 500}}},
        {id = 3, actions = {{message = 185, param = 600}}},
        {id = 4, actions = {{message = 185, param = 700}}}}, 4)
    hit(1, 0, {{id = PAL, actions = {{message = 1, param = 999}}}}, 5)   -- not at you: ignored
    eq(t.taken.hits, 2, 'two hits reached you')
    eq(t.taken.misses, 1, 'one miss')
    eq(t.taken.total, 1200, 'damage taken')
    eq(t.taken.melee, 300, 'melee part')
    eq(t.taken.other, 900, 'ability part')
    eq(t.taken.biggest.amt, 900, 'biggest hit')
    eq(t.taken.shared.n, 1, 'one shared attack')
    eq(t.taken.shared.party, 600, 'party median on it')
    eq(t.taken.active, 4, 'time being hit')
    local L = live.render_taken(t, 5, {ability_name = function(c, id) return c == 11 and id == 2000 and 'Feast of Arrows' or nil end})
    eq(L[1], 'TAKEN 300/s  1,200 in 2 hits  x1.5 the party on shared hits (n=1)', 'taken headline')
    eq(L[2], '  melee 25%  abilities/spells 75%   enemy melee hit you 50% (n=2)', 'split and hit rate')
    eq(L[3], '  biggest 900 from Bat (Feast of Arrows)', 'biggest named')
    eq(L[4], '  most from Bat: 1,200 (100%)', 'worst source')
    local D = live.render(t, 5, {})
    eq(D[#D] and D[#D]:find('^TAKEN ') ~= nil, true, 'damage view ends with the TAKEN headline')
    eq(#live.render(t, 5, {short = true}), 0, 'short view leaves TAKEN out')
end

print(('%d checks, %d failed'):format(checks, fails))

-- Optional replay of a real day's own rows (a, category, ability, target_id, msg, amount, actor, add).
local file, char = arg[1], arg[2]
if file then
    local r = live.new()
    local cur, cur_round, cur_t, ms0 = nil, nil, 0, nil
    local function flush()
        if cur then live.action(r, cur, cur_t, cur.tp, false, function(id) return id ~= cur.actor_id end, function() return 'mob' end) end
        cur = nil
    end
    for line in io.lines(file) do
        local c = {}
        for v in (line .. '\t'):gmatch('([^\t]*)\t') do c[#c + 1] = v end
        if c[1] == 'a' and c[11] == char and c[15] and c[15] ~= '-' then
            local round = c[15]
            if round ~= cur_round then
                flush()
                cur_round = round
                ms0 = ms0 or tonumber(c[16])
                cur_t = (tonumber(c[16]) - ms0) / 1000
                cur = {actor_id = tonumber(c[10]), category = tonumber(c[4]), param = tonumber(c[5]),
                       tp = tonumber(c[17]), targets = {}}
                if cur.category == 3 then live.ws_sent(r, cur.param, nil) end
            end
            local tid = tonumber(c[6])
            local tgt
            for _, t in ipairs(cur.targets) do if t.id == tid then tgt = t end end
            if not tgt then tgt = {id = tid, actions = {}} cur.targets[#cur.targets + 1] = tgt end
            local add = tonumber(c[13])
            tgt.actions[#tgt.actions + 1] = {message = tonumber(c[8]), param = tonumber(c[9]),
                has_add_effect = add ~= nil, add_effect_message = add, add_effect_param = tonumber(c[14])}
        end
    end
    flush()
    print('-- replay of ' .. file .. ' (your rows only: party melee is not recorded)')
    for _, l in ipairs(live.render(r, cur_t, {})) do print(l) end
    print('-- short')
    for _, l in ipairs(live.render(r, cur_t, {short = true})) do print(l) end
    print('-- diag')
    for _, l in ipairs(live.render_diag(r, cur_t, {})) do print(l) end
end

os.exit(fails == 0 and 0 or 1)
