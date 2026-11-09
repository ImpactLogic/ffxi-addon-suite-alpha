-- combatlog live display: what the box shows while you fight.
--
-- It answers one question -- "how much damage am I doing?" -- in the order a player asks it (0.7.0):
--   DAMAGE   your damage per second of fighting, now vs the session, and your share of the party's
--            -- then the same number taken apart into the levers gear changes:
--              WS    = average WS  x  how often you WS          (WSD / PDL / TP gear, Store TP)
--              SC    = what the skillchains you close add
--              melee = swings per round x damage per hit / round time   (multi-attack, Haste)
--   FIGHT    the current target: time, HP%, time left, your share, the mob's estimated HP
--   SESSION  totals, kills, time to kill, Aftermath uptime
--   TAKEN    (0.9.0) what enemies do to you: damage per second of being hit, melee vs abilities and
--            spells, the biggest hit, the source that hurt most, and -- when one attack hit you and
--            party members together -- how your share compares with theirs (the Sortie question:
--            "do I take more than the party?"). In memory only; the recorder needs //cbt incoming.
--
-- Why this is hard in FFXI, and what the display does about it:
--   * damage is bursty (one WS or skillchain is worth dozens of swings), so a per-second rate is
--     only honest over enough time: "now" is the last 60 s of FIGHTING, and the session rate beside
--     it is the baseline;
--   * walking between pulls is not slow damage: gaps over 10 s without your damage are downtime;
--   * mobs differ wildly in HP, so the fight line shows your share of the party's damage and the
--     mob's HP estimated from the party's damage and the HP% it lost;
--   * rates on a handful of swings are noise, so hit / crit keep their n.
--
-- Pure Lua, no Windower calls: combatlog.lua feeds it the same parsed actions the recorder sees and
-- passes the clock in, so test_live.lua can drive it offline. Party members' damage is counted here
-- in memory for the share and the HP estimate; the recorder still does not write their melee.
--
-- Message ids are from Windower res/action_messages.lua (read 2026-09-25), and the ones that matter
-- were checked against one character's own rows (09-19 / 09-23): melee 1 / 67 / 15, WS 185 with the
-- skillchain in add_msg (288-302, 767, 768), enspell-type added damage 229.
--   1 hit, 67 critical hit, 15 / 63 miss
--   352 / 576 / 577 ranged hit (576 "squarely", 577 "strikes true"), 353 ranged crit, 354 ranged miss
--   185 WS damage, 197 WS resisted (still damage), 188 WS miss, 187 WS drain
--   2 / 252 spell damage (252 = magic burst), 264 / 265 AoE damage, 110 / 317 / 157 ability damage
--   288-302, 767, 768 "Skillchain: <name>. <target> takes N damage"; 229 "Additional effect: N"
-- Magic (0.9.0, for SCH): every damaging spell is kept per spell id with its magic-burst count (252).

local live = {}

local MELEE_HIT  = {[1] = true, [67] = true}
local MELEE_CRIT = {[67] = true}
local MELEE_MISS = {[15] = true, [63] = true}
local RANGED_HIT  = {[352] = true, [353] = true, [576] = true, [577] = true}
local RANGED_CRIT = {[353] = true}
local RANGED_MISS = {[354] = true}
local WS_DAMAGE   = {[185] = true, [187] = true, [197] = true}
local WS_MISS     = {[188] = true}
local MAGIC_DAMAGE = {[2] = true, [252] = true, [264] = true, [265] = true}
local JA_DAMAGE    = {[110] = true, [157] = true, [264] = true, [317] = true}
local ADDED = {[229] = true}
local SC = {[767] = true, [768] = true}
for id = 288, 302 do SC[id] = true end
live.SC = SC

-- Any message that is damage to the target, whoever did it (for the party's total).
local ANY_DAMAGE = {}
for _, set in ipairs({MELEE_HIT, RANGED_HIT, WS_DAMAGE, MAGIC_DAMAGE, JA_DAMAGE}) do
    for id in pairs(set) do ANY_DAMAGE[id] = true end
end
-- Categories whose add-effect fields can be damage: melee, ranged, WS, JA, pet WS. Category 7
-- (WS readying) carries add-effect fields too, and they are not damage.
local ADD_CATS = {[1] = true, [2] = true, [3] = true, [6] = true, [13] = true}

live.IDLE = 10          -- seconds without your damage that end a burst (not counted as fighting)
live.RECENT = 60        -- seconds of fighting behind "now"
live.ROUNDS_KEPT = 100  -- rounds / gaps kept for the rolling medians
live.FIGHTS_KEPT = 30   -- enemies remembered at once

-- Buffs 270 / 271 / 272 = Aftermath Lv.1 / 2 / 3, 273 = Aftermath (res/buffs.lua).
local AM = {[270] = 1, [271] = 2, [272] = 3, [273] = 0}

local SOURCES = {'melee', 'ranged', 'ws', 'sc', 'magic', 'ja', 'added', 'pet'}

local function median(list)
    if #list == 0 then return nil end
    local s = {}
    for i, v in ipairs(list) do s[i] = v end
    table.sort(s)
    local mid = math.floor((#s + 1) / 2)
    if #s % 2 == 1 then return s[mid] end
    return (s[mid] + s[mid + 1]) / 2
end

local function push(list, v, keep)
    list[#list + 1] = v
    if #list > keep then table.remove(list, 1) end
end

function live.new()
    local damage = {}
    for _, b in ipairs(SOURCES) do damage[b] = 0 end
    return {
        damage = damage, total = 0,
        party_total = 0,                          -- everyone in the party incl. you, on enemies
        active = 0, last_dmg = nil,               -- seconds spent fighting, and when you last did damage
        recent = {},                              -- {at = active seconds, amt} for the "now" rate
        melee = {hits = 0, crits = 0, misses = 0},
        ranged = {hits = 0, crits = 0, misses = 0},
        rounds = {n = 0, swings = 0, last_t = nil, last_tp = nil, gaps = {}, tp = {}, sizes = {}},
        ws = {},                                  -- ws id -> {n, total, misses}
        ws_used = 0,                              -- every WS you used, landed or not
        last_ws = nil,                            -- {id, dmg, tp, miss}
        sc = {n = 0, total = 0, last = nil, last_msg = nil},
        sent_tp = {},                             -- ws id -> TP when it was sent
        fights = {}, fight_order = {},            -- target id -> {name, first, last, dmg, party, hpp0}
        mob_hp = {},                              -- mob name -> {sum, n}: HP estimated at each kill
        kills = {n = 0, ttk = {}, last = nil, last_name = nil},
        am = {engaged = 0, lv3 = 0, any = 0, seen = false},
        magic = {n = 0, mb = 0, spells = {}, last = nil},   -- spell id -> {n, total, mb}
        taken = {total = 0, hits = 0, misses = 0, melee = 0, melee_hits = 0, other = 0, active = 0, last = nil,
                 biggest = nil, by_source = {}, shared = {me = 0, party = 0, n = 0}},
    }
end

local function fight_for(s, id, name, now, hpp)
    local f = s.fights[id]
    if not f then
        f = {id = id, name = name, first = now, last = now, dmg = 0, party = 0}
        s.fights[id] = f
        push(s.fight_order, id, live.FIGHTS_KEPT)
        local keep = {}
        for _, fid in ipairs(s.fight_order) do keep[fid] = true end
        for fid in pairs(s.fights) do if not keep[fid] then s.fights[fid] = nil end end
    end
    if name then f.name = name end
    -- The HP% when the party's damage on it was first seen: the base for the HP estimate.
    if f.hpp0 == nil and hpp then f.hpp0 = hpp(id) end
    return f
end

local function party_damage(s, amount, target, name, now, hpp)
    if not amount or amount <= 0 then return end
    s.party_total = s.party_total + amount
    local f = fight_for(s, target, name, now, hpp)
    f.party = f.party + amount
end

local function add_damage(s, bucket, amount, target, name, now, hpp)
    if not amount or amount <= 0 then return end
    s.damage[bucket] = s.damage[bucket] + amount
    s.total = s.total + amount
    -- Time fighting: gaps between your damage; a gap longer than IDLE is downtime and not counted.
    if s.last_dmg and now - s.last_dmg <= live.IDLE then s.active = s.active + (now - s.last_dmg) end
    s.last_dmg = now
    s.recent[#s.recent + 1] = {at = s.active, amt = amount}
    while s.recent[1] and s.recent[1].at <= s.active - live.RECENT do table.remove(s.recent, 1) end
    party_damage(s, amount, target, name, now, hpp)
    local f = s.fights[target]
    f.dmg = f.dmg + amount
    f.last = now
end

-- A weapon skill has just been SENT (outgoing 0x01A), with the TP about to be spent.
function live.ws_sent(s, ws, tp)
    s.sent_tp[ws] = tp
end

-- One parsed action packet (windower.packets.parse_action) by you or your pet.
--   now      seconds (os.clock)
--   tp       your TP when it arrived (nil for the pet)
--   is_pet   true when the actor is your pet: all its damage goes in one bucket
--   enemy(id) true when that target is not you, a party member or a pet
--   name(id)  the target's name, or nil
--   hpp(id)   optional: the target's HP% now, for the mob HP estimate
function live.action(s, act, now, tp, is_pet, enemy, name, hpp)
    local cat = act.category
    local swings = 0
    for _, target in pairs(act.targets or {}) do
        if enemy(target.id) then
            local tname = name(target.id)
            for _, a in pairs(target.actions or {}) do
                local m, amt = a.message, a.param
                if is_pet then
                    if ANY_DAMAGE[m] then add_damage(s, 'pet', amt, target.id, tname, now, hpp) end
                elseif cat == 1 then
                    swings = swings + 1
                    if MELEE_HIT[m] then
                        s.melee.hits = s.melee.hits + 1
                        if MELEE_CRIT[m] then s.melee.crits = s.melee.crits + 1 end
                        add_damage(s, 'melee', amt, target.id, tname, now, hpp)
                    elseif MELEE_MISS[m] then
                        s.melee.misses = s.melee.misses + 1
                        fight_for(s, target.id, tname, now, hpp)
                    end
                elseif cat == 2 then
                    if RANGED_HIT[m] then
                        s.ranged.hits = s.ranged.hits + 1
                        if RANGED_CRIT[m] then s.ranged.crits = s.ranged.crits + 1 end
                        add_damage(s, 'ranged', amt, target.id, tname, now, hpp)
                    elseif RANGED_MISS[m] then
                        s.ranged.misses = s.ranged.misses + 1
                    end
                elseif cat == 3 then
                    local w = s.ws[act.param]
                    if not w then w = {n = 0, total = 0, misses = 0} s.ws[act.param] = w end
                    if WS_DAMAGE[m] then
                        w.n = w.n + 1
                        w.total = w.total + (amt or 0)
                        s.ws_used = s.ws_used + 1
                        add_damage(s, 'ws', amt, target.id, tname, now, hpp)
                        s.last_ws = {id = act.param, dmg = amt or 0, tp = s.sent_tp[act.param]}
                    elseif WS_MISS[m] then
                        w.misses = w.misses + 1
                        s.ws_used = s.ws_used + 1
                        s.last_ws = {id = act.param, dmg = 0, tp = s.sent_tp[act.param], miss = true}
                    end
                    s.sent_tp[act.param] = nil
                elseif cat == 4 and MAGIC_DAMAGE[m] then
                    add_damage(s, 'magic', amt, target.id, tname, now, hpp)
                    local mg = s.magic
                    local sp = mg.spells[act.param]
                    if not sp then sp = {n = 0, total = 0, mb = 0} mg.spells[act.param] = sp end
                    local burst = (m == 252)
                    sp.n, sp.total = sp.n + 1, sp.total + (amt or 0)
                    mg.n = mg.n + 1
                    if burst then sp.mb, mg.mb = sp.mb + 1, mg.mb + 1 end
                    mg.last = {id = act.param, dmg = amt or 0, mb = burst}
                elseif cat == 6 and JA_DAMAGE[m] then
                    add_damage(s, 'ja', amt, target.id, tname, now, hpp)
                end

                -- The additional effect: a skillchain when you close one, or enspell-type damage.
                if a.has_add_effect and not is_pet and ADD_CATS[cat] then
                    local am, aamt = a.add_effect_message, a.add_effect_param
                    if SC[am] then
                        s.sc.n = s.sc.n + 1
                        s.sc.total = s.sc.total + (aamt or 0)
                        s.sc.last, s.sc.last_msg = aamt, am
                        add_damage(s, 'sc', aamt, target.id, tname, now, hpp)
                    elseif ADDED[am] then
                        add_damage(s, 'added', aamt, target.id, tname, now, hpp)
                    end
                end
            end
        end
    end

    -- One melee packet is one round (combatlog 0.3.0): swings per round, the gap between rounds
    -- (Haste), and the TP gained between rounds (Store TP). A drop in TP means a WS was spent.
    if cat == 1 and not is_pet and swings > 0 then
        local r = s.rounds
        r.n, r.swings = r.n + 1, r.swings + swings
        push(r.sizes, swings, live.ROUNDS_KEPT)
        if r.last_t and now - r.last_t <= live.IDLE then
            push(r.gaps, now - r.last_t, live.ROUNDS_KEPT)
            if r.last_tp and tp and tp > r.last_tp then push(r.tp, tp - r.last_tp, live.ROUNDS_KEPT) end
        end
        r.last_t, r.last_tp = now, tp
    end
end

-- A party member's (or trust's, or their pet's) action: only its damage on enemies is counted, for
-- your share and the mob HP estimate. Their skillchains count as theirs.
function live.party_action(s, act, now, enemy, name, hpp)
    for _, target in pairs(act.targets or {}) do
        if enemy(target.id) then
            local tname = name(target.id)
            for _, a in pairs(target.actions or {}) do
                if ANY_DAMAGE[a.message] then party_damage(s, a.param, target.id, tname, now, hpp) end
                if a.has_add_effect and ADD_CATS[act.category]
                   and (SC[a.add_effect_message] or ADDED[a.add_effect_message]) then
                    party_damage(s, a.add_effect_param, target.id, tname, now, hpp)
                end
            end
        end
    end
end

-- An enemy's action (0.9.0). me = your id; party(id) true for a party member or trust; source = the
-- actor's name. Damage uses the same messages as your own (ANY_DAMAGE); 15 / 63 are melee misses.
-- When one packet hit you AND party members, your damage and the median of theirs are added to
-- `shared`, so the box can say whether the same attacks hurt you more than them.
local TAKEN_MISS = {[15] = true, [63] = true}

function live.taken(s, act, now, me, party, source)
    local t = s.taken
    local mine, others = nil, {}
    for _, target in pairs(act.targets or {}) do
        for _, a in pairs(target.actions or {}) do
            local m, amt = a.message, a.param or 0
            if target.id == me then
                if ANY_DAMAGE[m] then
                    mine = (mine or 0) + amt
                    t.total, t.hits = t.total + amt, t.hits + 1
                    if act.category == 1 then t.melee, t.melee_hits = t.melee + amt, t.melee_hits + 1
                    else t.other = t.other + amt end
                    if not t.biggest or amt > t.biggest.amt then
                        t.biggest = {amt = amt, source = source, category = act.category, id = act.param}
                    end
                    local key = source or '?'
                    t.by_source[key] = (t.by_source[key] or 0) + amt
                    if t.last and now - t.last <= live.IDLE then t.active = t.active + (now - t.last) end
                    t.last = now
                elseif TAKEN_MISS[m] then
                    t.misses = t.misses + 1
                end
            elseif party(target.id) and ANY_DAMAGE[m] then
                others[#others + 1] = amt
            end
        end
    end
    if mine and #others > 0 then
        t.shared.me = t.shared.me + mine
        t.shared.party = t.shared.party + median(others)
        t.shared.n = t.shared.n + 1
    end
end

-- The mob's HP from the party's damage and the HP% it lost: only an estimate (damage from outside
-- the party is missed, overkill is counted), and nil until it has lost enough HP to mean anything.
local function hp_estimate(f, hpp_now)
    if not (f.hpp0 and hpp_now and f.party > 0) then return nil end
    local lost = f.hpp0 - hpp_now
    if lost < 10 then return nil end
    return f.party * 100 / lost
end

-- An enemy was defeated (0x029 messages 6 / 20 / 97). Counted as your kill only if you hit it.
function live.defeated(s, target, now)
    local f = s.fights[target]
    if not f or f.dmg <= 0 or f.dead then return end
    f.dead = now
    local ttk = now - f.first
    s.kills.n = s.kills.n + 1
    push(s.kills.ttk, ttk, 50)
    s.kills.last, s.kills.last_name = ttk, f.name
    local hp = hp_estimate(f, 0)
    if hp and f.name then
        local m = s.mob_hp[f.name] or {sum = 0, n = 0}
        m.sum, m.n = m.sum + hp, m.n + 1
        s.mob_hp[f.name] = m
    end
end

-- Sampled once a second while engaged: Aftermath uptime.
function live.sample_buffs(s, buffs, engaged)
    if not engaged then return end
    local lv = nil
    for _, id in ipairs(buffs or {}) do
        if AM[id] then lv = math.max(lv or 0, AM[id]) end
    end
    s.am.engaged = s.am.engaged + 1
    if lv then
        s.am.seen = true
        s.am.any = s.am.any + 1
        if lv == 3 then s.am.lv3 = s.am.lv3 + 1 end
    end
end

-------------------------------------------------------------------------------
-- Rendering
-------------------------------------------------------------------------------
local function big(n)
    n = math.floor((n or 0) + 0.5)
    if n >= 10000000 then return ('%.1fM'):format(n / 1000000) end
    if n >= 1000000 then return ('%.2fM'):format(n / 1000000) end
    local s = tostring(n)
    local out = s:reverse():gsub('(%d%d%d)', '%1,'):reverse()
    return (out:gsub('^,', ''))
end
live.big = big

-- 115,234 -> "115k", 1,234,567 -> "1.2M": for estimates, where more digits would be false precision.
local function approx(n)
    if n >= 1000000 then return ('%.1fM'):format(n / 1000000) end
    if n >= 1000 then return ('%dk'):format(math.floor(n / 1000 + 0.5)) end
    return tostring(math.floor(n + 0.5))
end
live.approx = approx

local function clock(secs)
    secs = math.floor(secs or 0)
    if secs >= 3600 then return ('%d:%02d:%02d'):format(secs / 3600, (secs % 3600) / 60, secs % 60) end
    return ('%d:%02d'):format(secs / 60, secs % 60)
end
live.clock = clock

local function pct(a, b) return b > 0 and (100 * a / b) or 0 end
local function rate(amount, secs) return secs > 0 and amount / secs or 0 end

-- The last RECENT seconds of fighting, per second (nil until there are 15 s of it: before that the
-- session rate IS the recent rate).
function live.recent_dps(s)
    if s.active < 15 then return nil end
    local sum = 0
    for _, e in ipairs(s.recent) do sum = sum + e.amt end
    return sum / math.min(live.RECENT, s.active)
end

-- The fight to show: your current target if the party has hit it, otherwise the latest one still
-- alive (or the latest dead one for a few seconds, so the kill is visible).
local function shown_fight(s, target_id, now)
    if target_id and s.fights[target_id] then return s.fights[target_id] end
    local id = s.fight_order[#s.fight_order]
    local f = id and s.fights[id]
    if f and f.dmg > 0 and (not f.dead or now - f.dead < 8) and now - f.last < 30 then return f end
    return nil
end

-- TAKEN: what enemies did to you. `full` adds the breakdown lines (the taken view).
local function taken_lines(s, opts, full)
    local c = opts.c or function(_, _, _, t) return t end
    local t = s.taken
    if t.hits == 0 then return {} end
    local L = {}
    local line = c(255, 180, 120, 'TAKEN ') .. ('%s/s  %s in %d hits'):format(
        big(rate(t.total, math.max(t.active, 1))), big(t.total), t.hits)
    if t.shared.n > 0 and t.shared.party > 0 then
        local x = t.shared.me / t.shared.party
        local tag = ('x%.1f the party on shared hits (n=%d)'):format(x, t.shared.n)
        line = line .. '  ' .. (x >= 1.2 and c(255, 120, 80, tag) or tag)
    end
    L[#L + 1] = line
    if full then
        local swings = t.melee_hits + t.misses
        L[#L + 1] = ('  melee %d%%  abilities/spells %d%%   enemy melee hit you %s'):format(
            math.floor(pct(t.melee, t.total) + 0.5), math.floor(pct(t.other, t.total) + 0.5),
            t.misses > 0 and ('%.0f%% (n=%d)'):format(pct(t.melee_hits, swings), swings) or 'every time')
        local b = t.biggest
        if b then
            local what = opts.ability_name and opts.ability_name(b.category, b.id) or nil
            L[#L + 1] = ('  biggest %s from %s%s'):format(big(b.amt), b.source or '?', what and (' (' .. what .. ')') or '')
        end
        local top, topn = nil, 0
        for k, v in pairs(t.by_source) do if v > topn then top, topn = k, v end end
        if top then
            L[#L + 1] = ('  most from %s: %s (%d%%)'):format(top, big(topn), math.floor(pct(topn, t.total) + 0.5))
        end
    end
    return L
end

-- Lines for the box. opts:
--   target_id, target_hpp  your current target and its HP% (nil if none)
--   ws_name(id), sc_name(msg)  display names
--   c(r,g,b,text)  colour wrapper (identity in tests)
--   spell_name(id), ability_name(category, id)  display names for magic and for what hit you
--   short          only the DAMAGE and FIGHT headlines
function live.render(s, now, opts)
    local c = opts.c or function(_, _, _, t) return t end
    local function head(t) return c(120, 200, 255, t) end
    local function dim(t) return c(170, 170, 170, t) end
    local L = {}
    local secs = s.active

    -- DAMAGE: the answer, then the same number taken apart into its levers.
    if s.total > 0 then
        local dps = rate(s.total, secs)
        local line = head('DAMAGE ') .. ('%s/s'):format(big(dps))
        local now_dps = live.recent_dps(s)
        if now_dps and dps > 0 then
            local d = math.floor(pct(now_dps - dps, dps) + 0.5)
            local tag = ('now %s/s (%s%d%%)'):format(big(now_dps), d >= 0 and '+' or '', d)
            line = line .. '  ' .. (d >= 10 and c(120, 255, 120, tag) or d <= -10 and c(255, 160, 80, tag) or tag)
        end
        if s.party_total > s.total then
            line = line .. ('  %d%% of party'):format(math.floor(pct(s.total, s.party_total) + 0.5))
        end
        L[#L + 1] = line

        if not opts.short then
            -- Largest share first: the top line is where gear matters most.
            local order = {}
            for _, b in ipairs(SOURCES) do
                if pct(s.damage[b], s.total) >= 0.5 then order[#order + 1] = b end
            end
            table.sort(order, function(a, b) return s.damage[a] > s.damage[b] end)
            for _, b in ipairs(order) do
                local lead = ('  %-6s%7s/s %3d%%  '):format(b, big(rate(s.damage[b], secs)),
                    math.floor(pct(s.damage[b], s.total) + 0.5))
                if b == 'ws' and s.ws_used > 0 then
                    local miss = s.ws_used - (function() local n = 0 for _, w in pairs(s.ws) do n = n + w.n end return n end)()
                    L[#L + 1] = lead .. ('%s avg x every %s'):format(big(s.damage.ws / s.ws_used),
                        secs > 0 and ('%.0fs'):format(secs / s.ws_used) or '-')
                        .. (miss > 0 and c(255, 80, 80, ('  %d missed'):format(miss)) or '')
                    local lw = s.last_ws
                    if lw then
                        local name = opts.ws_name and opts.ws_name(lw.id) or ('WS ' .. tostring(lw.id))
                        local w = s.ws[lw.id]
                        L[#L + 1] = dim(('        last %s %s%s%s'):format(name,
                            lw.miss and 'MISS' or big(lw.dmg), lw.tp and (' @%d TP'):format(lw.tp) or '',
                            (w and w.n > 0 and w.n < s.ws_used) and ('  (its avg %s, n=%d)'):format(big(w.total / w.n), w.n) or ''))
                    end
                elseif b == 'sc' then
                    local name = opts.sc_name and opts.sc_name(s.sc.last_msg) or 'skillchain'
                    L[#L + 1] = lead .. ('%s avg  n=%d  last %s %s'):format(
                        big(s.sc.total / s.sc.n), s.sc.n, name, big(s.sc.last))
                elseif b == 'melee' and s.melee.hits > 0 then
                    local r = s.rounds
                    local sum = 0
                    for _, v in ipairs(r.sizes) do sum = sum + v end
                    local gap = median(r.gaps)
                    L[#L + 1] = lead .. ('%s/hit x %s swings/round, every %s'):format(
                        big(s.damage.melee / s.melee.hits),
                        #r.sizes > 0 and ('%.2f'):format(sum / #r.sizes) or '-',
                        gap and ('%.1fs'):format(gap) or '-')
                    local m = s.melee
                    local sw = m.hits + m.misses
                    local tp = median(r.tp)
                    L[#L + 1] = dim(('        %.1f%% hit  %.1f%% crit  n=%d  %s TP/round'):format(
                        pct(m.hits, sw), pct(m.crits, m.hits), sw, tp and tostring(math.floor(tp + 0.5)) or '-'))
                elseif b == 'magic' and s.magic.n > 0 then
                    local mg = s.magic
                    L[#L + 1] = lead .. ('%s avg  n=%d  MB %d%%'):format(big(s.damage.magic / mg.n), mg.n,
                        math.floor(pct(mg.mb, mg.n) + 0.5))
                    local lm = mg.last
                    if lm then
                        local name = opts.spell_name and opts.spell_name(lm.id) or ('spell ' .. tostring(lm.id))
                        local sp = mg.spells[lm.id]
                        L[#L + 1] = dim(('        last %s %s%s%s'):format(name, big(lm.dmg), lm.mb and ' MB' or '',
                            (sp and sp.n > 1) and ('  (its avg %s, n=%d, MB %d%%)'):format(big(sp.total / sp.n), sp.n,
                                math.floor(pct(sp.mb, sp.n) + 0.5)) or ''))
                    end
                elseif b == 'ranged' and s.ranged.hits > 0 then
                    local rg = s.ranged
                    local shots = rg.hits + rg.misses
                    L[#L + 1] = lead .. ('%s/hit  %.1f%% hit  %.1f%% crit  n=%d'):format(
                        big(s.damage.ranged / rg.hits), pct(rg.hits, shots), pct(rg.crits, rg.hits), shots)
                else
                    L[#L + 1] = lead
                end
            end
        end
    end

    -- FIGHT: this mob.
    local f = shown_fight(s, opts.target_id, now)
    if f and f.dmg > 0 then
        local t = (f.dead or now) - f.first
        local live_hpp = (opts.target_id == f.id) and opts.target_hpp or nil
        local line = head('FIGHT  ') .. ('%s  %s'):format(f.name or '?', clock(t))
        if f.dead then
            line = line .. c(120, 255, 120, '  defeated')
        elseif live_hpp then
            line = line .. ('  %d%%'):format(live_hpp)
            -- The whole party's pace: the HP% it has lost so far, over the time taken.
            local lost = (f.hpp0 or 100) - live_hpp
            if live_hpp > 0 and lost > 0 and t >= 5 then
                line = line .. ('  ~%s left'):format(clock(t * live_hpp / lost))
            end
        end
        L[#L + 1] = line
        if not opts.short then
            local sub = ('  you %s  %s/s'):format(big(f.dmg), big(rate(f.dmg, t)))
            if f.party > f.dmg then sub = sub .. ('  %d%% of party'):format(math.floor(pct(f.dmg, f.party) + 0.5)) end
            local hp = hp_estimate(f, f.dead and 0 or live_hpp)
            local known = f.name and s.mob_hp[f.name]
            if hp then
                sub = sub .. ('  mob ~%s HP'):format(approx(hp))
            elseif known then
                sub = sub .. ('  mob ~%s HP (n=%d)'):format(approx(known.sum / known.n), known.n)
            end
            L[#L + 1] = sub
        end
    end

    -- SESSION: the totals behind the rate.
    if s.total > 0 and not opts.short then
        local line = head('SESSION ') .. ('%s in %s fighting'):format(big(s.total), clock(secs))
        if s.kills.n > 0 then
            local sum = 0
            for _, v in ipairs(s.kills.ttk) do sum = sum + v end
            line = line .. ('  %d kill%s  %s avg'):format(s.kills.n, s.kills.n == 1 and '' or 's', clock(sum / #s.kills.ttk))
        end
        L[#L + 1] = line
        if s.am.seen and s.am.engaged > 0 then
            L[#L + 1] = ('  aftermath %d%% of engaged time (AM3 %d%%)'):format(
                math.floor(pct(s.am.any, s.am.engaged) + 0.5), math.floor(pct(s.am.lv3, s.am.engaged) + 0.5))
        end
    end
    if not opts.short then
        for _, l in ipairs(taken_lines(s, opts, false)) do L[#L + 1] = l end
    end
    return L
end

-- The taken view (//cbt view taken, for tanks: RUN): TAKEN in full, then the DAMAGE headline.
function live.render_taken(s, now, opts)
    local L = taken_lines(s, opts, true)
    if #L == 0 then L[1] = 'nothing has hit you yet' end
    local short = {}
    for k, v in pairs(opts) do short[k] = v end
    short.short = true
    for _, l in ipairs(live.render(s, now, short)) do L[#L + 1] = l end
    return L
end

-- The diagnostic view (//cbt view diag): 0.6.0's flat list, every raw figure on its own line, kept
-- for checking the numbers the damage view is built from. Plus the inputs of the estimates.
function live.render_diag(s, now, opts)
    local c = opts.c or function(_, _, _, t) return t end
    local L = {}

    local f = shown_fight(s, opts.target_id, now)
    if f then
        local t = (f.dead or now) - f.first
        local line = ('%s  %s'):format(f.name or '?', clock(t))
        if f.dead then
            line = line .. c(120, 255, 120, '  defeated')
        elseif opts.target_id == f.id and opts.target_hpp then
            line = line .. ('  %d%%'):format(opts.target_hpp)
        end
        L[#L + 1] = line
        L[#L + 1] = (' you %s dmg  %s dps'):format(big(f.dmg), big(t > 0 and f.dmg / t or 0))
        L[#L + 1] = (' party %s dmg  first seen at %s%%'):format(big(f.party),
            f.hpp0 and tostring(f.hpp0) or '?')
    end

    if s.total > 0 then
        L[#L + 1] = ('session %s dmg  %s dps  %s fighting'):format(
            big(s.total), big(rate(s.total, s.active)), clock(s.active))
        local now_dps = live.recent_dps(s)
        L[#L + 1] = (' last %ds: %s dps   party %s dmg'):format(live.RECENT,
            now_dps and big(now_dps) or '-', big(s.party_total))
        local parts = {}
        for _, b in ipairs(SOURCES) do
            local p = pct(s.damage[b], s.total)
            if p >= 0.5 then parts[#parts + 1] = ('%s %d%%'):format(b, math.floor(p + 0.5)) end
        end
        L[#L + 1] = ' ' .. table.concat(parts, '  ')
    end

    local m = s.melee
    local swings = m.hits + m.misses
    if swings > 0 then
        L[#L + 1] = ('melee %.1f%% hit  %.1f%% crit  n=%d'):format(
            pct(m.hits, swings), pct(m.crits, m.hits), swings)
    end
    local rg = s.ranged
    local shots = rg.hits + rg.misses
    if shots > 0 then
        L[#L + 1] = ('ranged %.1f%% hit  %.1f%% crit  n=%d'):format(
            pct(rg.hits, shots), pct(rg.crits, rg.hits), shots)
    end

    local r = s.rounds
    if #r.sizes > 0 then
        local sum = 0
        for _, v in ipairs(r.sizes) do sum = sum + v end
        local gap, tp = median(r.gaps), median(r.tp)
        L[#L + 1] = (' %.2f swings/round  %s TP/round  %s between  (last %d rounds)'):format(
            sum / #r.sizes, tp and tostring(math.floor(tp + 0.5)) or '-',
            gap and ('%.1fs'):format(gap) or '-', #r.sizes)
    end

    local lw = s.last_ws
    if lw then
        local w = s.ws[lw.id]
        local name = opts.ws_name and opts.ws_name(lw.id) or ('WS ' .. tostring(lw.id))
        local line = ('WS %s %s'):format(name, lw.miss and c(255, 80, 80, 'MISS') or big(lw.dmg))
        if lw.tp then line = line .. (' @%d'):format(lw.tp) end
        if w and w.n > 0 then line = line .. ('  avg %s n=%d'):format(big(w.total / w.n), w.n) end
        if w and w.misses > 0 then line = line .. ('  %d miss'):format(w.misses) end
        L[#L + 1] = line
    end
    if s.sc.n > 0 then
        local name = opts.sc_name and opts.sc_name(s.sc.last_msg) or 'skillchain'
        L[#L + 1] = ('SC %s %s  avg %s n=%d'):format(name, big(s.sc.last), big(s.sc.total / s.sc.n), s.sc.n)
    end

    if s.kills.n > 0 then
        local sum = 0
        for _, v in ipairs(s.kills.ttk) do sum = sum + v end
        L[#L + 1] = ('kills %d  avg %s  last %s'):format(s.kills.n, clock(sum / #s.kills.ttk), clock(s.kills.last))
    end

    if s.am.seen and s.am.engaged > 0 then
        L[#L + 1] = ('aftermath %d%% (AM3 %d%%) while engaged'):format(
            math.floor(pct(s.am.any, s.am.engaged) + 0.5), math.floor(pct(s.am.lv3, s.am.engaged) + 0.5))
    end
    return L
end

return live
