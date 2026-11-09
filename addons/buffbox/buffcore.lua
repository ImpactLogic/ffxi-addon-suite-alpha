--buffbox buffcore: pure functions (no windower.*), so tools/test-buffbox.lua can run them offline.
local core = {}

local function u16(s, off) local a, b = s:byte(off + 1, off + 2) return a + b * 256 end
local function u32(s, off)
    local a, b, c, d = s:byte(off + 1, off + 4)
    return a + b * 256 + c * 65536 + d * 16777216
end

-- Incoming 0x063, order 9 (Windower libs/packets/fields.lua): Order u16 at 0x04,
-- Buffs u16[32] at 0x08, Time u32[32] at 0x48. Slot i of Buffs goes with slot i of Time.
-- Empty slots are 255 (0xFF), confirmed in game 2026-09-27.
function core.parse_buff_times(data)
    if type(data) ~= 'string' or #data < 0x48 + 32 * 4 then return nil end
    if u16(data, 0x04) ~= 9 then return nil end
    local out, any = {}, false
    for i = 0, 31 do
        local id = u16(data, 0x08 + i * 2)
        local raw = u32(data, 0x48 + i * 4)
        if id ~= 0 or raw ~= 0 then any = true end
        if id ~= 0xFF and id ~= 0xFFFF then out[#out + 1] = {id = id, raw = raw} end
    end
    -- Zoning out sends one packet with every slot 0 and time 0 (seen in game 2026-09-27): not a buff
    -- list. The last real timers are kept; they are absolute end times, so they stay right.
    if not any then return nil, 'zone' end
    return out
end

-- Buff end time as a Unix time. fields.lua's bufftime: 1009810800 + raw/60 + k * 2^32/60 with k
-- hard-coded (10 in 2026) and "increment every 2.27 years". Instead of hard-coding k, take the k
-- that puts the end time nearest to now, which stays right across the wrap.
local EPOCH, WRAP = 1009810800, 0x100000000 / 60
function core.buff_end(raw, now)
    if not raw or raw == 0 then return nil end
    local base = EPOCH + raw / 60
    local k = math.floor((now - base) / WRAP + 0.5)
    local t = base + k * WRAP
    -- Nothing we show lasts a day; anything else is a placeholder value, not a timer.
    if t - now > 86400 then return nil end
    return t
end

function core.fmt_left(secs)
    if not secs then return '--' end
    secs = math.max(0, math.floor(secs))
    local h, m, s = math.floor(secs / 3600), math.floor(secs % 3600 / 60), secs % 60
    if h > 0 then return ('%d:%02d:%02d'):format(h, m, s) end
    return ('%d:%02d'):format(m, s)
end

-- Food effects from the item's description (Windower res/item_descriptions.lua, the game's own text).
-- Flavour text comes first; the effects start at the first line holding a stat like "HP+20",
-- "Acc.+10%" or "\"Resist Sleep\"+1". Everything after a "Pet:" marker is the pet's block.
-- Lines are kept as the game wrote them: wording differs between foods ("Accuracy" / "Acc.").
function core.food_effects(text)
    local own, pet = {}, {}
    if type(text) ~= 'string' then return own, pet end
    local target, started = own, false
    for line in (text:gsub('\r', '') .. '\n'):gmatch('([^\n]*)\n') do
        if not started and line:find('[%w%.%"%%]%s?[%+%-]%d') then started = true end
        if started then
            local rest = line:match('^%s*Pet:%s*(.*)$')
            if rest then target, line = pet, rest end
            if line:match('%S') then target[#target + 1] = line end
        end
    end
    return own, pet
end

-- Timers for the buffs the client says you have now. player_buffs is the authoritative list
-- (get_player().buffs); timers come from the last 0x063 and are matched by id, in order, so two
-- copies of one song each get their own time. Returns {id, ends} rows, ends nil when unknown.
function core.join(player_buffs, timers, now)
    local queue = {}
    for _, t in ipairs(timers or {}) do
        queue[t.id] = queue[t.id] or {}
        table.insert(queue[t.id], core.buff_end(t.raw, now) or false)
    end
    local rows = {}
    for _, id in ipairs(player_buffs or {}) do
        if id ~= 255 then
            local q = queue[id]
            local ends = q and #q > 0 and table.remove(q, 1) or nil
            rows[#rows + 1] = {id = id, ends = ends or nil}
        end
    end
    return rows
end

core.FOOD = 251   -- res/buffs.lua: [251] = "Food"

-- Low-time warnings. Only long buffs warn (had at least min_len seconds when first timed, or Food),
-- so songs and rolls that last a few minutes do not flood chat. Each copy of a buff warns once;
-- a refresh (time left jumps up by over a minute) arms it again. st persists between calls:
-- {[id#n] = {max, last, warned}}; copies of a buff that are gone are dropped from it.
-- Sets r.warn on every row inside its warning window (drawn red) and returns the rows to warn
-- about in chat now.
function core.warnings(rows, now, st, warn_secs, min_len)
    local fire, count, seen = {}, {}, {}
    for _, r in ipairs(rows) do
        count[r.id] = (count[r.id] or 0) + 1
        local key = r.id .. '#' .. count[r.id]
        seen[key] = true
        if r.ends then
            local left = r.ends - now
            local s = st[key]
            if not s or left > s.last + 60 then
                s = {max = left, last = left, warned = false}
                st[key] = s
            end
            s.last = left
            r.total = s.max   -- for the time bar: time left / time it had when first seen
            local long = s.max >= min_len or r.id == core.FOOD
            if warn_secs > 0 and long and left > 0 and left <= warn_secs then
                r.warn = true
                if not s.warned then
                    s.warned = true
                    fire[#fire + 1] = r
                end
            end
        end
    end
    for k in pairs(st) do if not seen[k] then st[k] = nil end end
    return fire
end

-- Which group a buff goes in (idea #57 layout): food, songs, rolls, region, other.
core.GROUPS = {'food', 'songs', 'rolls', 'region', 'other'}
core.HEADING = {food = 'FOOD', songs = 'SONGS', rolls = 'ROLLS', region = 'REGION', other = 'OTHER'}
function core.kind(id, name, opts)
    if id == core.FOOD then return 'food' end
    if opts.song_ids and opts.song_ids[id] then return 'songs' end
    if opts.is_roll and opts.is_roll(name) then return 'rolls' end
    if core.REGION_BUFFS[name or ''] then return 'region' end
    return 'other'
end

local GOLD, BLUE, AMBER, RED, DIM = {216, 184, 106}, {143, 212, 255}, {242, 184, 75}, {255, 90, 90}, {170, 176, 200}
local BAR = {food = {127, 191, 138, 255}, songs = {111, 134, 217, 255}, rolls = {181, 139, 224, 255},
    region = {150, 150, 150, 255}, other = {150, 160, 190, 255}, warn = {242, 184, 75, 255}}

-- Box text, grouped (idea #57). opts: names = {[id] = name}, food = {name, own, pet, measured} or nil,
-- show_pet, char, now, details = {[id or row] = {lines}} (roll values, fixed-buff effects, region notes),
-- songs = {[row] = {spell, from, measured}}, measured = {[id] = text} (stat changes read when a buff landed),
-- song_ids = {[buff id] = true}, is_roll = function(name), layout = 'full' | 'compact',
-- colour = function(r, g, b, text) (nil = plain). Rows with r.warn are drawn red with a '!'.
-- Returns the lines and the time bars {line, frac, rgba} (compact layout only).
function core.render(rows, opts)
    local paint = opts.colour or function(_, _, _, s) return s end
    local function c(rgb, s) return paint(rgb[1], rgb[2], rgb[3], s) end
    local compact = opts.layout == 'compact'
    local out, bars = {('buffbox  %s  %d buff%s'):format(opts.char or '?', #rows, #rows == 1 and '' or 's')}, {}
    if #rows == 0 then out[#out + 1] = ' none' return out, bars end
    local groups = {}
    for _, r in ipairs(rows) do
        local name = opts.names[r.id] or ('buff ' .. r.id)
        local k = core.kind(r.id, name, opts)
        groups[k] = groups[k] or {}
        table.insert(groups[k], {r = r, name = name})
    end
    local width = compact and 16 or 22
    for _, k in ipairs(core.GROUPS) do
        local list = groups[k]
        if list then
            local bards, nb = {}, 0
            for _, e in ipairs(list) do
                local sg = opts.songs and opts.songs[e.r]
                if sg and sg.from and not bards[sg.from] then bards[sg.from] = true nb = nb + 1 end
            end
            local one_bard = nb == 1 and next(bards) or nil
            if not compact then
                out[#out + 1] = c(GOLD, core.HEADING[k] .. (k == 'songs' and one_bard and ('  from ' .. one_bard) or ''))
            end
            for _, e in ipairs(list) do
                local r = e.r
                local left = r.ends and (r.ends - opts.now) or nil
                local f = r.id == core.FOOD and opts.food or nil
                local sg = opts.songs and opts.songs[r]
                local label = e.name
                if r.id == core.FOOD then label = f and f.name or 'Food (item not seen)'
                elseif sg then label = sg.spell end
                local d = opts.details and (opts.details[r] or opts.details[r.id]) or {}
                if compact and k == 'rolls' and d[1] then label = label .. ' ' .. (d[1]:match('^(%d+)') or '') end
                if #label > width then label = label:sub(1, width) end
                local line = ((r.warn and '!' or ' ') .. '%-' .. width .. 's %8s'):format(label, core.fmt_left(left))
                out[#out + 1] = r.warn and c(RED, line) or line
                if compact and left and r.total and r.total > 0 then
                    bars[#bars + 1] = {line = #out, frac = left / r.total, rgba = r.warn and BAR.warn or BAR[k]}
                end
                local measured = (f and f.measured) or (sg and sg.measured) or (opts.measured and opts.measured[r.id])
                if compact then
                    if measured then out[#out + 1] = c(BLUE, '  ' .. measured) end
                else
                    if sg and sg.from and not one_bard then out[#out + 1] = c(DIM, '    ' .. sg.from) end
                    if f then
                        for _, l in ipairs(f.own) do out[#out + 1] = c(DIM, '    ' .. l) end
                        if opts.show_pet and #f.pet > 0 then
                            out[#out + 1] = c(DIM, '    Pet:')
                            for _, l in ipairs(f.pet) do out[#out + 1] = c(DIM, '      ' .. l) end
                        end
                    end
                    for _, l in ipairs(d) do
                        local lucky = k == 'rolls' and l:find('(lucky)', 1, true)
                        out[#out + 1] = (l:find('\\cs', 1, true) and ('    ' .. l)) or c(lucky and AMBER or DIM, '    ' .. l)
                    end
                    if measured then out[#out + 1] = c(BLUE, '    measured ' .. measured) end
                end
            end
        end
    end
    return out, bars
end

-- Bard songs. The buff says only "Minuet"; the cast that landed on you names the song ("Shouto casts
-- Valor Minuet V", ffxilogger 2026-09-28). songs = {[buff id] = {{spell, from, t}, ...}}; a recast of the
-- same song replaces its entry.
function core.note_song(songs, buff_id, spell, from, t)
    local list = songs[buff_id] or {}
    songs[buff_id] = list
    for i = #list, 1, -1 do if list[i].spell == spell then table.remove(list, i) end end
    list[#list + 1] = {spell = spell, from = from, t = t}
end

-- Lines under one song: its name and bard, then each stat from the optional song-potency table
-- (optional songs_wiki.lua, none ships) as the range from the lowest to the highest +song column. The bard's +song gear
-- is not sent, so the one real value is somewhere in that range.
function core.song_lines(s, wiki)
    local lines = {s.spell .. (s.from and (' (' .. s.from .. ')') or '')}
    local w = wiki and wiki[s.spell]
    if not w then return lines end
    local lo, hi = w.bonus[1], w.bonus[#w.bonus]
    for _, st in ipairs(w.stats) do
        local v = st[2]
        local range = (v[1] == v[#v]) and v[1] or (v[1] .. '-' .. v[#v])
        lines[#lines + 1] = ('%s %s at %s..%s'):format(st[1], range, lo, hi)
    end
    return lines
end

-- {[row] = lines} for the song rows. Copies of one buff (two Minuets) are paired by age: newest cast
-- with the row that ends last (inferred, not sent: songs of one kind last about as long). Songs whose
-- buff is gone are dropped, except casts under 5 s old (the buff list can lag the cast).
function core.song_details(rows, songs, wiki, now)
    local by_id, out, rowsong = {}, {}, {}
    for _, r in ipairs(rows) do
        by_id[r.id] = by_id[r.id] or {}
        table.insert(by_id[r.id], r)
    end
    for id, list in pairs(songs) do
        local rs = by_id[id] or {}
        table.sort(list, function(a, b) return a.t < b.t end)
        while #list > #rs and list[1].t < now - 5 do table.remove(list, 1) end
        if #list == 0 then songs[id] = nil end
        local sorted = {}
        for i, r in ipairs(rs) do sorted[i] = r end
        table.sort(sorted, function(a, b) return (a.ends or math.huge) < (b.ends or math.huge) end)
        local off = #sorted - #list
        for i, s in ipairs(list) do
            local r = sorted[off + i]
            if r then out[r] = core.song_lines(s, wiki) rowsong[r] = s end
        end
    end
    return out, rowsong
end

-- Incoming 0x061, your own stats (Windower libs/packets/fields.lua): Maximum HP/MP u32 at 0x04/0x08,
-- Base STR..CHR u16 at 0x14..0x20, Added STR..CHR s16 at 0x22..0x2E, Attack u16 at 0x30, Defense u16
-- at 0x32, eight elemental resistances s16 at 0x34..0x42. Idea #55: a buff's potency may show as the
-- change in these when it lands. Returns {name = value} in STATS order, or nil.
local ATTR = {'STR', 'DEX', 'VIT', 'AGI', 'INT', 'MND', 'CHR'}
local ELEM = {'Fire', 'Ice', 'Wind', 'Earth', 'Ltng', 'Water', 'Light', 'Dark'}
core.STATS = {'HP', 'MP'}
for _, a in ipairs(ATTR) do core.STATS[#core.STATS + 1] = a end
for _, a in ipairs(ATTR) do core.STATS[#core.STATS + 1] = '+' .. a end
core.STATS[#core.STATS + 1] = 'Atk'
core.STATS[#core.STATS + 1] = 'Def'
for _, e in ipairs(ELEM) do core.STATS[#core.STATS + 1] = e end

local function s16(s, off) local v = u16(s, off) return v >= 0x8000 and v - 0x10000 or v end
function core.parse_stats(data)
    if type(data) ~= 'string' or #data < 0x44 then return nil end
    local v = {HP = u32(data, 0x04), MP = u32(data, 0x08), Atk = u16(data, 0x30), Def = u16(data, 0x32)}
    for i, a in ipairs(ATTR) do
        v[a] = u16(data, 0x14 + (i - 1) * 2)
        v['+' .. a] = s16(data, 0x22 + (i - 1) * 2)
    end
    for i, e in ipairs(ELEM) do v[e] = s16(data, 0x34 + (i - 1) * 2) end
    return v
end

-- "Atk 1200>1386(+186) +STR 40>52(+12)" for what changed, '' when nothing did, every stat when prev is nil.
function core.stats_diff(prev, cur)
    local parts = {}
    for _, k in ipairs(core.STATS) do
        if not prev then parts[#parts + 1] = ('%s %d'):format(k, cur[k])
        elseif prev[k] ~= cur[k] then
            parts[#parts + 1] = ('%s %d>%d(%+d)'):format(k, prev[k], cur[k], cur[k] - prev[k])
        end
    end
    return table.concat(parts, ' ')
end

-- What a buff changed, for the box: "Atk +52  Def +4  HP +20  STR +2" (base stats never move with buffs).
local SHORT = {'Atk', 'Def', 'HP', 'MP', '+STR', '+DEX', '+VIT', '+AGI', '+INT', '+MND', '+CHR',
    'Fire', 'Ice', 'Wind', 'Earth', 'Ltng', 'Water', 'Light', 'Dark'}
function core.stats_short(prev, cur)
    if not prev or not cur then return '' end
    local parts = {}
    for _, k in ipairs(SHORT) do
        local d = (cur[k] or 0) - (prev[k] or 0)
        if d ~= 0 then parts[#parts + 1] = ('%s %+d'):format((k:gsub('^%+', '')), d) end
    end
    return table.concat(parts, '  ')
end

-- A stat change is put on a buff only when it is the one thing that happened: exactly one buff gained and
-- none lost within 3 s either side (the stats packet came 1 s before the Food gain, 2026-09-28 15:22).
-- An equip change (kind 'gear') in the window cancels it too: gear moves stats the same way.
-- events = {{t, kind = 'gain' | 'lose' | 'gear', target}}. Returns 'wait', the gain's target, or false.
function core.resolve_measure(pending, events, now)
    if now - pending.t < 3 then return 'wait' end
    local gain, n_gain, n_lose = nil, 0, 0
    for _, e in ipairs(events) do
        if math.abs(e.t - pending.t) <= 3 then
            if e.kind == 'gain' then gain, n_gain = e, n_gain + 1 else n_lose = n_lose + 1 end
        end
    end
    if n_gain == 1 and n_lose == 0 then return gain.target end
    return false
end

-- Reading a buff from a LATER stats packet (idea #55, 2026-10-01). The server resends 0x061 when you do
-- something yourself (food, an ability, a gear change) but not when someone else's buff lands on you (stats.log,
-- three nights: Minuet 0 of 13, Protect 0 of 6, Food 7 of 7). So the newest packet is compared with an older one
-- and the change is given to every buff gained in between.
--   snaps  = {{t, stats}, ...} oldest first; the last is the packet to explain.
--   events = {{t, kind = 'gain' | 'lose' | 'gear', target}}.
-- Base packet: the previous one when no gear moved since; otherwise the newest earlier packet (15 min) in the
-- same gear, told by its fingerprint (added STR..CHR, max HP and MP), so only Attack / Defense / resistances
-- can differ. Any buff lost in between cancels it. Returns 'wait' (2 s for the events around the packet),
-- nil, or {text, targets = {...}}: one target = that buff's own number, several = their sum.
core.FINGERPRINT = {'+STR', '+DEX', '+VIT', '+AGI', '+INT', '+MND', '+CHR', 'HP', 'MP'}
function core.same_gear(a, b)
    for _, k in ipairs(core.FINGERPRINT) do if a[k] ~= b[k] then return false end end
    return true
end
function core.attribute(snaps, events, now)
    local cur, prev = snaps[#snaps], snaps[#snaps - 1]
    if not cur or not prev then return nil end
    if now - cur.t < 2 then return 'wait' end
    local base = prev
    for _, e in ipairs(events) do
        if e.kind == 'gear' and e.t > prev.t - 1 and e.t <= cur.t + 2 then base = nil break end
    end
    if not base then
        for i = #snaps - 1, 1, -1 do
            if cur.t - snaps[i].t > 900 then break end
            if core.same_gear(snaps[i].stats, cur.stats) then base = snaps[i] break end
        end
        if not base then return nil end
    end
    local targets = {}
    for _, e in ipairs(events) do
        if e.t > base.t + 2 and e.t <= cur.t + 2 then
            if e.kind == 'lose' then return nil end
            if e.kind == 'gain' then targets[#targets + 1] = e.target end
        end
    end
    if #targets == 0 then return nil end
    local text = core.stats_short(base.stats, cur.stats)
    if text == '' then return nil end
    return {text = text, targets = targets}
end

-- Region buffs work only in their own areas (from an optional zones_wiki.lua table; none ships).
core.REGION_BUFFS = {Signet = true, Sanction = true, Sigil = true, Ionis = true}

-- "Bastok Markets [S]" (Windower) and "Bastok Markets (S)" (the spelling other sites use) give the same key.
function core.zone_key(name)
    return (name or ''):lower():gsub('[^a-z0-9]', '')
end

-- A note when a region buff does nothing in this zone, else nil. A zone missing from the table
-- (cities, Adoulin wilds, Abyssea, Escha) is unknown, not "no effect", so it gets no note.
function core.region_note(buff_name, zone_name, zones)
    if not core.REGION_BUFFS[buff_name or ''] or not zones or not zone_name then return nil end
    local z = zones[core.zone_key(zone_name)]
    if not z or not z.buff or z.buff == buff_name then return nil end
    return ('No effect here (%s area)'):format(z.buff)
end

return core
