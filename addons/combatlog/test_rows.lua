-- Offline test for addons/combatlog/rows.lua under a stubbed Windower.
-- Run: luajit addons/combatlog/test_rows.lua   (from the repo root; any Lua 5.1)
package.path = (arg[0]:match('^(.*)[/\\]') or '.') .. '/?.lua;' .. package.path

-- Portable: on Windows os.execute runs cmd.exe, where `mkdir -p` makes a folder literally named
-- "-p" in the current directory (it did, 2026-09-18). Detect the shell and use its own commands.
local WIN = package.config:sub(1, 1) == '\\'
local TMP = os.getenv('TMPDIR') or os.getenv('TEMP') or '/tmp'
local ROOT = TMP .. '/combatlog_test/'
local function native(p) return WIN and p:gsub('/', '\\') or p end
local function mkdir(d)
    if WIN then os.execute('if not exist "' .. native(d) .. '" mkdir "' .. native(d) .. '"')
    else os.execute('mkdir -p "' .. d .. '"') end
end
if WIN then os.execute('if exist "' .. native(ROOT) .. '" rmdir /s /q "' .. native(ROOT) .. '"')
else os.execute('rm -rf "' .. ROOT .. '"') end
mkdir(ROOT)

windower = {
    dir_exists = function(d)
        local f = io.open(d .. '/.probe', 'a')
        if f then f:close() os.remove(d .. '/.probe') return true end
        return false
    end,
    create_dir = mkdir,
}

local rows = require('rows')
rows.dir = ROOT

local fails, checks = 0, 0
local function eq(got, want, label)
    checks = checks + 1
    if got ~= want then
        fails = fails + 1
        print(('FAIL %s: got %s, want %s'):format(label, tostring(got), tostring(want)))
    end
end
local function near(got, want, tol, label)
    checks = checks + 1
    if not got or math.abs(got - want) > tol then
        fails = fails + 1
        print(('FAIL %s: got %s, want %s +-%s'):format(label, tostring(got), tostring(want), tostring(tol)))
    end
end

-- action round trip
local a = rows.decode(rows.encode_action(1758000000, 3, 1, 0, 1234567, 'Locus Ghost Crab', 1, 412))
eq(a.kind, 'a', 'action kind')
eq(a.t, 1758000000, 'action t')
eq(a.ctx, 3, 'action ctx')
eq(a.target_id, 1234567, 'target id')
eq(a.target_name, 'Locus Ghost Crab', 'target name with a space survives')
eq(a.message, 1, 'message id')
eq(a.amount, 412, 'amount')

-- a nil amount (a miss carries no damage) must round trip as nil, not 0
local m = rows.decode(rows.encode_action(1758000001, 3, 1, 0, 1234567, 'Crab', 15, nil))
eq(m.amount, nil, 'missing amount decodes as nil, not zero')
eq(m.message, 15, 'miss message id')

-- a tab in a mob name must not break the columns
local weird = rows.decode(rows.encode_action(1, 1, 1, 0, 2, 'Bad\tName', 1, 5))
eq(weird.target_name, 'Bad Name', 'tab in a name is escaped')
eq(weird.amount, 5, 'columns still line up after an escaped name')

-- context round trip
local c = rows.decode(rows.encode_ctx(1758000000, 7, {job = 'COR', lvl = 99, gear = '1,2,3', buffs = ''}))
eq(c.kind, 'c', 'ctx kind')
eq(c.id, 7, 'ctx id')
eq(c.f.job, 'COR', 'ctx job')
eq(c.f.lvl, 99, 'ctx lvl is a number')
eq(c.f.gear, '1,2,3', 'ctx gear list')

eq(rows.decode('garbage'), nil, 'garbage rejected')
eq(rows.decode(''), nil, 'empty rejected')
eq(rows.decode('a\tnot_a_time\t1\t1\t0\t2\tx\t1\t5'), nil, 'non-numeric timestamp rejected')

-- labels come from the trust-sourced id lists
eq(rows.label(15), 'miss', 'label miss')
eq(rows.label(1), 'hit', 'label hit')
eq(rows.label(2), 'ws', 'label ws')
eq(rows.label(6), 'defeated', 'label defeated')
eq(rows.label(9999), '?', 'unknown id stays unknown, not guessed')

-- write and read back a day
local D = '2026-09-17'
rows.append('Alice', D, rows.encode_ctx(1758000000, 1, {job = 'COR', lvl = 99}))
-- 80 ordinary hits at 100, 20 of message 67 at 300 (the shape a crit id would have), 25 misses
for i = 1, 80 do rows.append('Alice', D, rows.encode_action(1758000000 + i, 1, 1, 0, 5, 'Crab', 1, 100)) end
for i = 1, 20 do rows.append('Alice', D, rows.encode_action(1758000100 + i, 1, 1, 0, 5, 'Crab', 67, 300)) end
for i = 1, 25 do rows.append('Alice', D, rows.encode_action(1758000200 + i, 1, 1, 0, 5, 'Crab', 15, nil)) end

local list = rows.read_day('Alice', D)
eq(#list, 126, 'all rows read back (125 actions + 1 context)')

local s = rows.summarize(list)
eq(s.hits, 100, 'hits counted from both hit ids')
eq(s.misses, 25, 'misses counted')
eq(s.swings, 125, 'swings')
near(s.hit_rate, 0.80, 0.001, 'hit rate')
eq(s.damage, 80 * 100 + 20 * 300, 'total damage over hit ids')

-- the summary must separate the two hit ids, since that separation IS the crit finding
local by = {}
for _, m2 in ipairs(s.by_message) do by[m2.message] = m2 end
eq(by[1].n, 80, 'message 1 count')
near(by[1].avg, 100, 0.001, 'message 1 average')
eq(by[67].n, 20, 'message 67 count')
near(by[67].avg, 300, 0.001, 'message 67 average -- 3x, which is what identifies it')
eq(by[15].avg, nil, 'a message with no damage has no average')
eq(s.by_message[1].message, 1, 'sorted by frequency, commonest first')

-- Wilson interval: wide on small n, tight on large n. This is the whole point of reporting it.
local lo1, hi1 = rows.hit_rate_ci(8, 10)
local lo2, hi2 = rows.hit_rate_ci(800, 1000)
checks = checks + 1
if not (hi1 - lo1 > 0.3) then fails = fails + 1 print('FAIL small-n interval should be wide, got ' .. (hi1 - lo1)) end
checks = checks + 1
if not (hi2 - lo2 < 0.06) then fails = fails + 1 print('FAIL large-n interval should be tight, got ' .. (hi2 - lo2)) end
near((lo2 + hi2) / 2, 0.80, 0.01, 'large-n interval centres on the rate')
-- the degenerate cases must not blow up or escape [0,1]
local lo3, hi3 = rows.hit_rate_ci(0, 5)
checks = checks + 1
if not (lo3 >= 0 and hi3 <= 1) then fails = fails + 1 print('FAIL zero-hit interval out of range') end
eq(rows.hit_rate_ci(0, 0), nil, 'no swings, no interval')

-- an empty day is empty, not an error
eq(#rows.read_day('Nobody', D), 0, 'missing file reads as empty')
local empty = rows.summarize({})
eq(empty.hit_rate, nil, 'no swings means no hit rate, not 0%')

-- 0.2.0: who acted, reaction, skillchain (additional effect)
local KAAT, KAIR, BAT = 795148, 795214, 17556100
local v2 = rows.decode(rows.encode_action(1758000100, 7, 3, 93, BAT, 'Locus Dire Bat', 185, 21843,
    KAAT, 'Alice', 1, 288, 9120))
eq(v2.ability, 93, 'v2 WS id')
eq(v2.amount, 21843, 'v2 WS damage is the WS alone')
eq(v2.actor_id, KAAT, 'v2 actor id')
eq(v2.actor_name, 'Alice', 'v2 actor name')
eq(v2.reaction, 1, 'v2 reaction')
eq(v2.add_msg, 288, 'v2 skillchain message')
eq(v2.add_amount, 9120, 'v2 skillchain damage kept apart from the WS')

-- no add effect is written as '-' and must come back nil, not 0 (0 would read as a 0-damage chain)
local plain = rows.decode(rows.encode_action(1758000101, 7, 1, 0, BAT, 'Locus Dire Bat', 1, 400,
    KAAT, 'Alice', 8, nil, nil))
eq(plain.add_msg, nil, 'absent skillchain is nil')
eq(plain.add_amount, nil, 'absent skillchain damage is nil')

-- a 0.1.x row (nine columns) still decodes, with no actor
local old = rows.decode(table.concat({'a', '1758000000', '3', '1', '0', '1234567', 'Crab', '1', '412'}, '\t'))
eq(old.amount, 412, 'v1 row still decodes')
eq(old.actor_id, nil, 'v1 row has no actor')

-- a name with a tab in it cannot shift the columns after it
local tabbed = rows.decode(rows.encode_action(1758000102, 7, 1, 0, BAT, 'Bad\tName', 1, 5, KAAT, 'Kaat\tria', 1, nil, nil))
eq(tabbed.amount, 5, 'tab in target name does not shift amount')
eq(tabbed.actor_id, KAAT, 'tab in target name does not shift actor')

-- summarize(list, actor): only that actor's swings count; legacy rows are counted apart
local mixed = {
    rows.decode(rows.encode_action(1, 1, 1, 0, BAT, 'Bat', 1, 100, KAAT, 'Alice', 1)),     -- her hit
    rows.decode(rows.encode_action(2, 1, 1, 0, BAT, 'Bat', 15, nil, KAAT, 'Alice', 1)),    -- her miss
    rows.decode(rows.encode_action(3, 1, 1, 0, BAT, 'Bat', 15, nil, KAIR, 'Bob', 1)),     -- alt's miss
    rows.decode(rows.encode_action(4, 1, 1, 0, KAAT, 'Alice', 1, 300, BAT, 'Bat', 1)),     -- the bat hits HER
    old,                                                                                       -- unattributable
}
local mine = rows.summarize(mixed, KAAT)
eq(mine.swings, 2, 'only own swings counted')
eq(mine.hits, 1, 'own hits')
eq(mine.hit_rate, 0.5, 'alt misses and incoming hits do not move her hit rate')
eq(mine.unattributed, 1, 'legacy row reported as unattributed, not counted')
local everyone = rows.summarize(mixed)
eq(everyone.swings, 5, 'no filter keeps the old behaviour')
eq(everyone.unattributed, 0, 'no filter, nothing is unattributed')

-- 0.3.0: round / ms / tp round-trip, and the round statistics
local r3 = rows.decode(rows.encode_action(1758000200, 9, 1, 0, BAT, 'Bat', 1, 400, KAAT, 'Alice', 1, nil, nil, 77, 123456, 540))
eq(r3.round, 77, 'v3 round')
eq(r3.ms, 123456, 'v3 ms')
eq(r3.tp, 540, 'v3 tp')
eq(v2.round, nil, 'v2 row has no round')

local function sw(round, ms, tp, msg, actor)
    return rows.decode(rows.encode_action(1, 1, 1, 0, BAT, 'Bat', msg or 1, 100, actor or KAAT, 'x', 1, nil, nil, round, ms, tp))
end
local fight = {
    sw(1, 1000, 100), sw(1, 1000, 100),              -- double attack round
    sw(2, 3500, 160), sw(2, 3500, 160, 15),          -- double, one missed: still two swings
    sw(3, 6000, 220),                                -- single
    sw(4, 8500, 280), sw(4, 8500, 280), sw(4, 8500, 280),   -- triple
    sw(5, 30000, 20),                                -- 21.5 s later: a new fight, gap and TP ignored
    sw(6, 32000, 80, 1, KAIR),                       -- someone else's round: ignored
    rows.decode(rows.encode_action(1, 1, 3, 93, BAT, 'Bat', 185, 20000, KAAT, 'x', 1, nil, nil, 7, 8600, 0)),  -- a WS: not a melee round
}
local st = rows.rounds(fight, KAAT)
eq(st.rounds, 5, 'five own melee rounds')
near(st.swings_per_round, 9 / 5, 1e-9, 'swings per round')
eq(st.by_swings[1], 2, 'single-swing rounds')
eq(st.by_swings[2], 2, 'double rounds (a miss still counts as a swing)')
eq(st.by_swings[3], 1, 'triple rounds')
eq(st.gaps, 3, 'the 21.5 s gap is a new fight, not a slow round')
eq(st.gap_ms, 2500, 'median gap between rounds')
eq(st.tp_per_round, 60, 'median TP per round')
eq(st.tp_samples, 3, 'TP drop across the new fight is not a gain')
local none = rows.rounds({v2, old}, KAAT)
eq(none.rounds, 0, 'pre-0.3.0 rows have no rounds')
eq(none.gap_ms, nil, 'no rounds, no gap')

-- 0.4.0: action-message rows (defeats, wear-offs) round-trip and stay out of the swing counts
local m1 = rows.decode(rows.encode_msg(1758000300, 99000, KAAT, 'Alice', BAT, 'Locus Dire Bat', 6, 0, 0))
eq(m1.kind, 'm', 'message row kind')
eq(m1.message, 6, 'defeat message id')
eq(m1.target_id, BAT, 'message target')
eq(m1.ms, 99000, 'message ms')
local m2 = rows.decode(rows.encode_msg(1758000301, 99500, BAT, 'Locus Dire Bat', BAT, 'Locus Dire Bat', 206, 134, nil))
eq(m2.p1, 134, 'wear-off carries the status id')
eq(m2.p2, nil, 'absent param is nil')
local with_msgs = {m1, m2, rows.decode(rows.encode_action(1, 1, 1, 0, BAT, 'Bat', 1, 100, KAAT, 'Alice', 1))}
eq(rows.summarize(with_msgs, KAAT).swings, 1, 'message rows are not swings')

-- safeguard: a full file stops growing, keeps what it has, and reports once
rows.max_bytes = 200
local told = 0
rows.on_full = function() told = told + 1 end
local wrote = 0
for i = 1, 50 do
    if rows.append('Capped', D, rows.encode_action(1758000000 + i, 1, 1, 0, BAT, 'Bat', 1, i, KAAT, 'Alice', 1)) then
        wrote = wrote + 1
    end
end
rows.flush()
local cf = io.open(rows.path('Capped', D), 'r')
local size = cf and cf:seek('end') or 0
if cf then cf:close() end
checks = checks + 1
if not (wrote > 0 and wrote < 50) then fails = fails + 1 print('FAIL cap: wrote ' .. wrote .. ' of 50') end
checks = checks + 1
if size < 200 or size > 200 + 200 then fails = fails + 1 print('FAIL cap: file is ' .. size .. ' bytes') end
eq(told, 1, 'cap reported exactly once, not per row')
eq(#rows.read_day('Capped', D), wrote, 'rows written before the cap are intact')
rows.max_bytes, rows.on_full = nil, nil

-- 0.4.4 buffered writing: rows are held, written in batches, and never lost
local function on_disk(char, date)
    local f = io.open(rows.path(char, date), 'r')
    if not f then return 0 end
    local n = 0
    for _ in f:lines() do n = n + 1 end
    f:close()
    return n
end
local line = rows.encode_action(1, 1, 1, 0, BAT, 'Bat', 1, 1, KAAT, 'Alice', 1)
rows.close()
for i = 1, 3 do rows.append('Buffer', D, line) end
eq(on_disk('Buffer', D), 0, 'a few rows are held, not written one by one')
eq(#rows.read_day('Buffer', D), 3, 'but reading the day includes them')
eq(on_disk('Buffer', D), 3, 'reading flushed them to disk')
for i = 1, 25 do rows.append('Buffer', D, line) end
eq(on_disk('Buffer', D), 28, 'a batch of 25 is written without being asked')
rows.append('Buffer', D, line)
rows.flush()
eq(on_disk('Buffer', D), 29, 'flush writes everything held')
rows.append('Buffer', D, line)
rows.append('Buffer', '2026-09-19', line)     -- the next day: the old file must be written and closed
eq(on_disk('Buffer', D), 30, 'switching to a new day writes out the old day first')
local open = 0
for _ in pairs(rows.writers) do open = open + 1 end
eq(open, 1, 'only one file is open at a time')
rows.close()
eq(on_disk('Buffer', '2026-09-19'), 1, 'close writes the rest')
eq(next(rows.writers), nil, 'close leaves nothing open')

-- 1.0.0 schema v1: an h row first whenever a file is opened, x markers decode
rows.on_open = function(char)
    return {rows.encode_kv('h', 1758000000, {schema = rows.SCHEMA, addon = 'combatlog', addon_version = '1.0.0',
        contributor = '0123456789abcdef', character = char, client = 'windower4'})}
end
rows.append('Schema', D, rows.encode_kv('x', 1758000001, {test = 'A', event = 'start', note = 'new feet'}))
rows.append('Schema', D, line)
rows.close()
rows.append('Schema', D, line)        -- opened again (a reload): a second header
local got = rows.read_day('Schema', D)
eq(#got, 5, 'two headers, a marker and two actions')
eq(got[1].kind, 'h', 'the header comes first')
eq(got[1].f.contributor, '0123456789abcdef', 'the header carries the contributor')
eq(got[1].f.character, 'Schema', 'and the character')
eq(got[1].f.schema, '1', 'and the schema version')
eq(got[2].kind, 'x', 'then the marker')
eq(got[2].f.note, 'new feet', 'marker notes keep their spaces')
eq(got[4].kind, 'h', 'reopening writes the header again')
eq(rows.encode_kv('x', 1, {test = 'a=b'}), 'x\t1\ttest=a b', '= inside a value is escaped')
eq(rows.summarize(got).hits, 2, 'the summary ignores h and x rows')
rows.close()
rows.on_open = nil

-- 1.1.0 treasure pool rows
local pd = rows.decode(rows.encode_pool_drop(1790000001, 5000, 3, 4096, 1, 17969159, 'Locus Dire Bat', 0, '1790000000.17969159'))
eq(pd.fight, '1790000000.17969159', 'pool drop fight id')
local md = rows.decode(rows.encode_msg(1790000001, 4900, 795148, 'Char', 17969159, 'Locus Dire Bat', 6, 0, 0, 4, '1790000000.17969159'))
eq(md.th, 4, 'defeat row Treasure Hunter level')
eq(md.fight, '1790000000.17969159', 'defeat row fight id')
local mold = rows.decode(rows.encode_msg(1790000001, 4900, 795148, 'Char', 17969159, 'Locus Dire Bat', 6, 0, 0))
eq(mold.th, nil, 'no TH seen gives nil')
eq(mold.fight, nil, 'no fight gives nil')
local m10 = rows.decode('m\t1\t2\t3\tA\t4\tB\t6\t0\t0')
eq(m10.kind, 'm', 'an old 10-column message row still decodes')
eq(m10.th, nil, 'and has no th')
eq(pd.kind, 'pd', 'pool drop kind')
eq(pd.slot, 3, 'pool drop slot')
eq(pd.item, 4096, 'pool drop item')
eq(pd.dropper_id, 17969159, 'pool drop dropper id')
eq(pd.dropper_name, 'Locus Dire Bat', 'pool drop dropper name')
eq(pd.old, 0, 'pool drop old flag')
local pl = rows.decode(rows.encode_pool_lot(1790000002, 5100, 3, 795148, 'Lotter', 600, 795214, 'Top', 700))
eq(pl.kind, 'pl', 'pool lot kind')
eq(pl.lot, 600, 'pool lot value')
eq(pl.top_name, 'Top', 'pool lot top name')
local pe = rows.decode(rows.encode_pool_end(1790000300, 305000, 3, 4096, 299, 1, 795214, 'Top', 700))
eq(pe.kind, 'pe', 'pool end kind')
eq(pe.age, 299, 'pool end age')
eq(pe.result, 1, 'pool end result')
local pe3 = rows.decode(rows.encode_pool_end(1790000300, 305000, 4, 4096, 300, 3))
eq(pe3.result, 3, 'floored pool end result')
eq(pe3.winner_id, nil, 'floored pool end has no winner')
eq(pe3.winner_name, nil, 'floored pool end has no winner name')
eq(rows.summarize({pd, pl, pe}).hits, 0, 'the summary ignores pool rows')

-- 1.3.0 reward rows
local rw = rows.decode(rows.encode_reward(1790000010, 7000, "Ra'Kaznar starstone", 17969200, 'Triboulex', '1790000000.17969200', -4000))
eq(rw.kind, 'r', 'reward kind')
eq(rw.item, "Ra'Kaznar starstone", 'reward item')
eq(rw.mob_id, 17969200, 'reward enemy id')
eq(rw.mob_name, 'Triboulex', 'reward enemy name')
eq(rw.fight, '1790000000.17969200', 'reward fight id')
eq(rw.gap_ms, -4000, 'reward gap is negative when the reward came first')
local rn = rows.decode(rows.encode_reward(1790000010, 7000, 'x', nil, nil, nil, nil))
eq(rn.mob_name, nil, 'a reward with no defeat has no enemy')
eq(rn.fight, nil, 'and no fight')
eq(rows.summarize({rw}).hits, 0, 'the summary ignores reward rows')

print(('%d checks, %d failed'):format(checks, fails))
os.exit(fails == 0 and 0 or 1)
