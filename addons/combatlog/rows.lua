-- combatlog row IO and summaries.
-- No Windower dependency beyond dir_exists/create_dir, so this file is testable outside the game
-- (see test_rows.lua).
--
-- The format is ffxi-atlas's combat log schema (docs/COMBAT-LOG-SCHEMA.md, store/combatlog_schema.py),
-- which owns the standard; this file writes version rows.SCHEMA of it. 1.0.0 added two row kinds:
--
--   h  t  k=v ...    header: schema, addon, addon_version, contributor, character, client. Written
--                    first whenever a file is opened for writing (load, new day, login).
--   x  t  k=v ...    test marker: test=<label> event=start|end [note=...]
--
-- The row kinds from before 1.0.0 (schema version 0), tab separated, first column is the kind:
--
--   c  t  id   k=v ...              context: who you were and what you wore, written when it changes
--   a  t  ctx  category  ability  target_id  target_name  message  amount
--      actor_id  actor_name  reaction  add_msg  add_amount                      <- added in 0.2.0
--      round  ms  tp                                                             <- added in 0.3.0
--
-- 0.3.0 (Store TP vs Double Attack vs Haste): `round` numbers each action packet, so every row from
-- one melee round shares it and hits-per-round is a count; `ms` is os.clock() in milliseconds (time
-- since this client started -- only comparable within one character's file) for the gap between
-- rounds; `tp` is your TP when the round arrived. Whether the client has already applied that
-- round's TP at that moment is not known, but the difference between consecutive rounds is the TP
-- per round either way.
--
-- 0.2.0 appended five columns rather than inserting them, so anything reading the first nine
-- still works. Why they were needed (2026-09-18): rows did not say WHO acted, so with "incoming"
-- on, the mob's swings at you, a Corsair's rolls and a trust's cures were indistinguishable from
-- your own actions. add_msg / add_amount carry the skillchain (additional effect) so it is never
-- mistaken for weapon skill damage. Rows from 0.1.x decode with actor_id = nil.
--
-- A weapon skill's context row is special: it is written at the moment the WS is SENT, with
-- phase=ws, the TP spent, and gear_sent -- the set GearSwap sent for the WS, which the client's
-- own equipment view may not show yet. The WS result row points at that context. See combatlog.lua.
--
-- Action rows are fixed-column and deliberately small: a busy hour is thousands of them, and the
-- context (gear, buffs, stats) is written once per change rather than repeated on every swing.
--
-- We record message ids, not conclusions. Which id means "critical hit" is NOT asserted here --
-- rows.summarize() groups by message id with the damage distribution, which is how that gets
-- established from your own data rather than from memory. See README.

local rows = {}

rows.dir = nil   -- set by combatlog.lua
rows.SCHEMA = 1
-- Called with the character when a day file is opened for writing; returns the lines to write
-- first (the h row, and the x row of a test still running). Set by combatlog.lua.
rows.on_open = nil

-- Message id lists, taken from working Windower code (cyritegamestudios/trust v17.7.1,
-- cylibs/util/action_message_util.lua, read 2026-09-17), NOT from memory. They are used only to
-- label the summary; every raw id is kept in the rows regardless.
rows.MSG_HIT      = {[1] = true, [67] = true, [264] = true, [352] = true, [353] = true}
rows.MSG_MISS     = {[15] = true, [16] = true, [53] = true, [354] = true}
rows.MSG_WS       = {[2] = true, [110] = true, [185] = true, [187] = true, [317] = true, [529] = true, [802] = true}
rows.MSG_DEFEATED = {[6] = true, [20] = true, [113] = true, [406] = true, [605] = true, [646] = true}

-------------------------------------------------------------------------------
-- Encoding
-------------------------------------------------------------------------------
local function esc(v)
    if v == nil then return '-' end
    return (tostring(v):gsub('[\t\n]', ' '))
end

local function esc_kv(v)
    if v == nil then return '-' end
    return (tostring(v):gsub('[\t\n=]', ' '))
end

function rows.encode_action(t, ctx, category, ability, target_id, target_name, message, amount,
                            actor_id, actor_name, reaction, add_msg, add_amount, round, ms, tp)
    return table.concat({'a', esc(t), esc(ctx), esc(category), esc(ability),
        esc(target_id), esc(target_name), esc(message), esc(amount),
        esc(actor_id), esc(actor_name), esc(reaction), esc(add_msg), esc(add_amount),
        esc(round), esc(ms), esc(tp)}, '\t')
end

-- 0.4.0: action messages (incoming 0x029), a third row kind. Kept for enemies only:
--   m  t  ms  actor_id  actor_name  target_id  target_name  message  param1  param2
-- Defeats (6, 20, 97) give time-to-kill, measured from your first hit on that target_id; wear-offs
-- (64, 204, 206, 350, 531, param1 = the status id) close the debuff windows opened by the 'a' rows
-- where a party member's spell/ability "receives the effect of" landed on the mob.
-- Readers that only know 'a' and 'c' skip 'm' rows: decode returns them, summarize ignores them.
-- 1.2.0 appends two columns, filled on a defeat only: th = the Treasure Hunter level the party had
-- on that mob when it died (nil = none seen), fight = an id for the fight, "<first hit time>.<mob id>",
-- the same id the pool drop row (pd) of that mob carries.
function rows.encode_msg(t, ms, actor_id, actor_name, target_id, target_name, message, p1, p2, th, fight)
    return table.concat({'m', esc(t), esc(ms), esc(actor_id), esc(actor_name),
        esc(target_id), esc(target_name), esc(message), esc(p1), esc(p2), esc(th), esc(fight)}, '\t')
end

-- 1.1.0: the treasure pool, decoded from incoming 0x0D2 (an item appears) and 0x0D3 (a lot, or the
-- end of that item). Three row kinds; `slot` is the pool slot (0x0D2 Index / 0x0D3 Index), which is
-- what joins a drop to its lots and its end, so identical items in the pool at once stay apart
-- (matching the chat lines by item name cannot do that: 78% of 3,603 pool items on 2026-10-16 had a
-- same-named item open at the same time).
--   pd  t  ms  slot  item_id  count  dropper_id  dropper_name  old  fight
--   pl  t  ms  slot  lotter_id  lotter_name  lot  top_id  top_name  top_lot
--   pe  t  ms  slot  item_id  age_s  result  winner_id  winner_name  winner_lot
-- old = 1: the item was already in the pool when you joined/zoned, so its real drop time is unknown.
-- lot 65535 = a pass. result is the packet's Drop byte: 1 = given to a player, 3 = floored (nobody
-- took it: the expiry case), 0 never appears on pe (that is a pl row).
function rows.encode_pool_drop(t, ms, slot, item, count, dropper_id, dropper_name, old, fight)
    return table.concat({'pd', esc(t), esc(ms), esc(slot), esc(item), esc(count),
        esc(dropper_id), esc(dropper_name), esc(old), esc(fight)}, '\t')
end

function rows.encode_pool_lot(t, ms, slot, lotter_id, lotter_name, lot, top_id, top_name, top_lot)
    return table.concat({'pl', esc(t), esc(ms), esc(slot), esc(lotter_id), esc(lotter_name),
        esc(lot), esc(top_id), esc(top_name), esc(top_lot)}, '\t')
end

function rows.encode_pool_end(t, ms, slot, item, age, result, winner_id, winner_name, winner_lot)
    return table.concat({'pe', esc(t), esc(ms), esc(slot), esc(item), esc(age), esc(result),
        esc(winner_id), esc(winner_name), esc(winner_lot)}, '\t')
end

-- 1.3.0: a reward line the player is watching for (settings.reward_items, default the Ra'Kaznar
-- starstone), tied to the enemy whose defeat it came with:
--   r  t  ms  item  mob_id  mob_name  fight  gap_ms
-- gap_ms = reward time minus defeat time in ms: NEGATIVE when the reward line came first (the starstone
-- text arrives 2-5 s before the boss's defeat line). mob_id / mob_name / fight are '-' when no defeat
-- was seen within 10 s either way. The first defeat after the reward (or the last one just before it)
-- is taken, so a different enemy dying in between can be picked by mistake; gap_ms shows how far apart.
function rows.encode_reward(t, ms, item, mob_id, mob_name, fight, gap_ms)
    return table.concat({'r', esc(t), esc(ms), esc(item), esc(mob_id), esc(mob_name),
        esc(fight), esc(gap_ms)}, '\t')
end

-- h and x rows: kind, time, then k=v in key order (1.0.0).
function rows.encode_kv(kind, t, fields)
    local parts = {kind, esc(t)}
    local keys = {}
    for k in pairs(fields or {}) do keys[#keys + 1] = k end
    table.sort(keys)
    for _, k in ipairs(keys) do parts[#parts + 1] = k .. '=' .. esc_kv(fields[k]) end
    return table.concat(parts, '\t')
end

function rows.encode_ctx(t, id, fields)
    local parts = {'c', esc(t), esc(id)}
    local keys = {}
    for k in pairs(fields or {}) do keys[#keys + 1] = k end
    table.sort(keys)
    for _, k in ipairs(keys) do parts[#parts + 1] = k .. '=' .. esc_kv(fields[k]) end
    return table.concat(parts, '\t')
end

function rows.decode(line)
    local cols = {}
    for c in (line .. '\t'):gmatch('([^\t]*)\t') do cols[#cols + 1] = c end
    local kind = cols[1]

    if kind == 'a' and #cols >= 9 and tonumber(cols[2]) then
        return {
            kind = 'a', t = tonumber(cols[2]), ctx = tonumber(cols[3]) or cols[3],
            category = tonumber(cols[4]), ability = tonumber(cols[5]),
            target_id = tonumber(cols[6]), target_name = cols[7],
            message = tonumber(cols[8]), amount = tonumber(cols[9]),
            -- 0.2.0 columns; nil on 0.1.x rows ('-' also decodes to nil)
            actor_id = tonumber(cols[10]), actor_name = (cols[11] and cols[11] ~= '-') and cols[11] or nil,
            reaction = tonumber(cols[12]), add_msg = tonumber(cols[13]), add_amount = tonumber(cols[14]),
            -- 0.3.0 columns; nil on older rows
            round = tonumber(cols[15]), ms = tonumber(cols[16]), tp = tonumber(cols[17]),
        }
    elseif kind == 'm' and #cols >= 10 and tonumber(cols[2]) then
        return {
            kind = 'm', t = tonumber(cols[2]), ms = tonumber(cols[3]),
            actor_id = tonumber(cols[4]), actor_name = cols[5] ~= '-' and cols[5] or nil,
            target_id = tonumber(cols[6]), target_name = cols[7] ~= '-' and cols[7] or nil,
            message = tonumber(cols[8]), p1 = tonumber(cols[9]), p2 = tonumber(cols[10]),
            -- 1.2.0 columns; nil on older rows
            th = tonumber(cols[11]), fight = (cols[12] and cols[12] ~= '-') and cols[12] or nil,
        }
    elseif kind == 'r' and #cols >= 8 and tonumber(cols[2]) then
        return {
            kind = 'r', t = tonumber(cols[2]), ms = tonumber(cols[3]), item = cols[4],
            mob_id = tonumber(cols[5]), mob_name = cols[6] ~= '-' and cols[6] or nil,
            fight = cols[7] ~= '-' and cols[7] or nil, gap_ms = tonumber(cols[8]),
        }
    elseif kind == 'pd' and #cols >= 9 and tonumber(cols[2]) then
        return {
            kind = 'pd', t = tonumber(cols[2]), ms = tonumber(cols[3]), slot = tonumber(cols[4]),
            item = tonumber(cols[5]), count = tonumber(cols[6]), dropper_id = tonumber(cols[7]),
            dropper_name = cols[8] ~= '-' and cols[8] or nil, old = tonumber(cols[9]),
            fight = (cols[10] and cols[10] ~= '-') and cols[10] or nil,   -- 1.2.0
        }
    elseif kind == 'pl' and #cols >= 10 and tonumber(cols[2]) then
        return {
            kind = 'pl', t = tonumber(cols[2]), ms = tonumber(cols[3]), slot = tonumber(cols[4]),
            lotter_id = tonumber(cols[5]), lotter_name = cols[6] ~= '-' and cols[6] or nil,
            lot = tonumber(cols[7]), top_id = tonumber(cols[8]),
            top_name = cols[9] ~= '-' and cols[9] or nil, top_lot = tonumber(cols[10]),
        }
    elseif kind == 'pe' and #cols >= 10 and tonumber(cols[2]) then
        return {
            kind = 'pe', t = tonumber(cols[2]), ms = tonumber(cols[3]), slot = tonumber(cols[4]),
            item = tonumber(cols[5]), age = tonumber(cols[6]), result = tonumber(cols[7]),
            winner_id = tonumber(cols[8]), winner_name = cols[9] ~= '-' and cols[9] or nil,
            winner_lot = tonumber(cols[10]),
        }
    elseif (kind == 'h' or kind == 'x') and #cols >= 2 and tonumber(cols[2]) then
        local row = {kind = kind, t = tonumber(cols[2]), f = {}}
        for i = 3, #cols do
            local k, v = cols[i]:match('^([^=]+)=(.*)$')
            if k then row.f[k] = v end
        end
        return row
    elseif kind == 'c' and #cols >= 3 and tonumber(cols[2]) then
        local row = {kind = 'c', t = tonumber(cols[2]), id = tonumber(cols[3]) or cols[3], f = {}}
        for i = 4, #cols do
            local k, v = cols[i]:match('^([^=]+)=(.*)$')
            if k then row.f[k] = tonumber(v) or v end
        end
        return row
    end
    return nil
end

-------------------------------------------------------------------------------
-- File IO
-------------------------------------------------------------------------------
-- The folder check is cached per character: asking the OS on every row is a filesystem call per
-- action packet, the same cost garden 0.1.1 paid (garden.lua:173-187 caches it the same way).
local dir_known = {}
local function char_dir(char)
    local d = rows.dir .. char .. '/'
    if not dir_known[d] then
        if not windower.dir_exists(d) then windower.create_dir(d) end
        dir_known[d] = true
    end
    return d
end

function rows.path(char, date) return char_dir(char) .. 'combat-' .. date .. '.tsv' end

-- Safeguard: a day's file stops growing at rows.max_bytes (set from settings by combatlog.lua).
-- Once full it is never truncated -- it is evidence -- and rows.on_full is called once so the player
-- is told, instead of the recorder silently stopping. A new day starts a new file.
rows.max_bytes = nil
rows.full = {}      -- path -> true once that file hit the cap
rows.on_full = nil

-- Buffered writing (0.4.4). Until now every row opened, appended and closed the file. garden 0.1.1
-- did that per packet under Program Files -- where the antivirus inspects every open -- and hung the
-- client (2026-09-17); One character's combat file reached 3.7 MB on 2026-09-18. So, like garden: one open
-- handle, rows held in memory and written in a batch every FLUSH_ROWS rows or FLUSH_SECONDS seconds,
-- whichever comes first. combatlog.lua calls rows.tick() on a timer so a quiet spell still gets
-- written, and rows.flush() / rows.close() on zone change, logout and unload.
local FLUSH_ROWS, FLUSH_SECONDS = 25, 2
rows.writers = {}   -- path -> {file, bytes (incl. buffered), buf, n, last}

local function flush_writer(w)
    if w.n == 0 then return end
    w.file:write(table.concat(w.buf, '', 1, w.n))
    w.file:flush()
    w.buf, w.n, w.last = {}, 0, os.clock()
end

local function writer_for(path, char)
    local w = rows.writers[path]
    if w then return w end
    -- Only one file is written at a time; a new day or a new character closes the old one.
    for other, ow in pairs(rows.writers) do
        flush_writer(ow)
        ow.file:close()
        rows.writers[other] = nil
    end
    local f = io.open(path, 'a')
    if not f then return nil end
    w = {file = f, bytes = f:seek('end') or 0, buf = {}, n = 0, last = os.clock()}
    rows.writers[path] = w
    -- 1.0.0: the schema header (and a running test's marker) first, every time the file is opened.
    if rows.on_open then
        local ok, lines = pcall(rows.on_open, char)
        if ok and type(lines) == 'table' then
            for _, l in ipairs(lines) do
                local text = l .. '\n'
                w.n = w.n + 1
                w.buf[w.n] = text
                w.bytes = w.bytes + #text
            end
        end
    end
    return w
end

function rows.append(char, date, line)
    local path = rows.path(char, date)
    if rows.full[path] then return false end
    local w = writer_for(path, char)
    if not w then return false end
    if rows.max_bytes and w.bytes >= rows.max_bytes then
        flush_writer(w)
        rows.full[path] = true
        if rows.on_full then pcall(rows.on_full, path) end
        return false
    end
    local text = line .. '\n'
    w.n = w.n + 1
    w.buf[w.n] = text
    w.bytes = w.bytes + #text
    if w.n >= FLUSH_ROWS or (os.clock() - w.last) >= FLUSH_SECONDS then flush_writer(w) end
    return true
end

-- Write anything held longer than FLUSH_SECONDS (call on a timer).
function rows.tick()
    for _, w in pairs(rows.writers) do
        if w.n > 0 and (os.clock() - w.last) >= FLUSH_SECONDS then flush_writer(w) end
    end
end

-- Write everything held now.
function rows.flush()
    for _, w in pairs(rows.writers) do flush_writer(w) end
end

-- Write everything and close the file (logout, unload).
function rows.close()
    for path, w in pairs(rows.writers) do
        flush_writer(w)
        w.file:close()
        rows.writers[path] = nil
    end
end

function rows.read_day(char, date)
    rows.flush()   -- rows still in memory belong in the answer
    local out = {}
    local f = io.open(rows.path(char, date), 'r')
    if not f then return out end
    for line in f:lines() do
        local r = rows.decode(line)
        if r then out[#out + 1] = r end
    end
    f:close()
    return out
end

-------------------------------------------------------------------------------
-- Summary
--
-- Grouped by message id, because that is the question this recorder exists to answer first:
-- which ids appear, how often, and with what damage distribution. A message id whose mean damage
-- sits well above another's, on the same ability, is your critical-hit id -- established from
-- your rows, not assumed.
-------------------------------------------------------------------------------
-- only_actor: count only that actor's rows. Rows with no actor (0.1.x files) cannot be attributed,
-- so they are counted separately as `unattributed` and left out -- with "incoming" on they mixed
-- your actions with everyone else's, and silently including them is how a 16%-hit-rate alt and a
-- mob's swings at you got blended into your hit rate (2026-09-18).
function rows.summarize(list, only_actor)
    local by_msg, order = {}, {}
    local hits, misses, total_damage = 0, 0, 0
    local unattributed = 0

    for _, r in ipairs(list) do
        local counted = r.kind == 'a' and r.message
        if counted and only_actor then
            if r.actor_id == nil then
                unattributed = unattributed + 1
                counted = false
            elseif r.actor_id ~= only_actor then
                counted = false
            end
        end
        if counted then
            local m = by_msg[r.message]
            if not m then
                m = {message = r.message, n = 0, damage = 0, amounts = 0, min = nil, max = nil,
                     label = rows.label(r.message)}
                by_msg[r.message] = m
                order[#order + 1] = m
            end
            m.n = m.n + 1
            if r.amount then
                m.amounts = m.amounts + 1
                m.damage = m.damage + r.amount
                m.min = (m.min == nil or r.amount < m.min) and r.amount or m.min
                m.max = (m.max == nil or r.amount > m.max) and r.amount or m.max
            end
            if rows.MSG_HIT[r.message] then
                hits = hits + 1
                total_damage = total_damage + (r.amount or 0)
            elseif rows.MSG_MISS[r.message] then
                misses = misses + 1
            end
        end
    end

    -- Averaged over the rows that carried an amount, not over every row: a miss has no damage,
    -- and reporting its average as 0 would drag every mixed group towards zero.
    for _, m in ipairs(order) do m.avg = m.amounts > 0 and (m.damage / m.amounts) or nil end
    table.sort(order, function(x, y) return x.n > y.n end)

    local swings = hits + misses
    return {
        by_message = order,
        hits = hits, misses = misses, swings = swings,
        hit_rate = swings > 0 and (hits / swings) or nil,
        damage = total_damage,
        unattributed = unattributed,
    }
end

-- Melee rounds for one actor (0.3.0 rows only): the numbers Store TP, Double Attack and Haste move.
--   swings per round  -- multi-attack (every row of a round is one swing, hit or miss)
--   gap between rounds -- attack speed; Haste shortens it, so a measured gap that stops shrinking
--                         when more haste is added means the cap is reached, without modelling it
--   TP per round       -- Store TP; taken as the rise in tp from one round to the next
-- Gaps longer than MAX_GAP_MS are a new fight, not a slow round, and are left out; so is any TP
-- change that is not a rise (a weapon skill spent it in between).
rows.MAX_GAP_MS = 10000

local function median(list)
    if #list == 0 then return nil end
    table.sort(list)
    local mid = math.floor((#list + 1) / 2)
    if #list % 2 == 1 then return list[mid] end
    return (list[mid] + list[mid + 1]) / 2
end
rows.median = median

function rows.rounds(list, actor)
    local by_round, order = {}, {}
    for _, r in ipairs(list) do
        if r.kind == 'a' and r.category == 1 and r.round and r.actor_id == actor then
            local rd = by_round[r.round]
            if not rd then
                rd = {round = r.round, ms = r.ms, tp = r.tp, swings = 0}
                by_round[r.round] = rd
                order[#order + 1] = rd
            end
            rd.swings = rd.swings + 1
        end
    end
    table.sort(order, function(a, b) return (a.ms or 0) < (b.ms or 0) end)

    local per_swings, gaps, tp_gains = {}, {}, {}
    local total_swings = 0
    for i, rd in ipairs(order) do
        total_swings = total_swings + rd.swings
        local bucket = rd.swings >= 4 and 4 or rd.swings
        per_swings[bucket] = (per_swings[bucket] or 0) + 1
        local prev = order[i - 1]
        if prev and prev.ms and rd.ms and (rd.ms - prev.ms) <= rows.MAX_GAP_MS then
            gaps[#gaps + 1] = rd.ms - prev.ms
            if prev.tp and rd.tp and rd.tp > prev.tp then tp_gains[#tp_gains + 1] = rd.tp - prev.tp end
        end
    end
    return {
        rounds = #order,
        swings_per_round = #order > 0 and total_swings / #order or nil,
        by_swings = per_swings,          -- [1] = one-swing rounds, [2] = double, [3] = triple, [4] = 4+
        gap_ms = median(gaps), gaps = #gaps,
        tp_per_round = median(tp_gains), tp_samples = #tp_gains,
    }
end

function rows.label(message)
    if rows.MSG_MISS[message] then return 'miss' end
    if rows.MSG_WS[message] and rows.MSG_HIT[message] then return 'hit/ws' end
    if rows.MSG_WS[message] then return 'ws' end
    if rows.MSG_HIT[message] then return 'hit' end
    if rows.MSG_DEFEATED[message] then return 'defeated' end
    return '?'
end

-- Wilson score interval, so a hit rate is reported with the uncertainty it actually has.
-- 12 hits out of 15 is not the same evidence as 1,200 out of 1,500, and a gear decision made on
-- the first is a decision made on noise. z = 1.96 (95%).
function rows.hit_rate_ci(hits, swings)
    if not swings or swings <= 0 then return nil end
    local z, p, n = 1.96, hits / swings, swings
    local denom = 1 + z * z / n
    local centre = (p + z * z / (2 * n)) / denom
    local margin = z * math.sqrt(p * (1 - p) / n + z * z / (4 * n * n)) / denom
    -- Clamped: at p = 0 or p = 1 the arithmetic can land a hair outside [0,1], and a hit rate of
    -- -0.0000001% in a report is the kind of detail that makes people distrust the whole number.
    local lo = math.max(0, centre - margin)
    local hi = math.min(1, centre + margin)
    return lo, hi
end

return rows
