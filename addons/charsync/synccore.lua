--synccore: the parts of charsync that need no game, so tools/test-charsync.lua can run them offline.
--
-- The file format is ffxi-atlas's character snapshot schema, version 1 (docs/CHARACTER-SNAPSHOT.md,
-- src/store/snapshot_schema.py). atlas owns it; this module conforms. One file, tab separated:
--
--   h  k=v ...                                  schema, addon, addon_version, contributor, character,
--                                               captured, reason
--   p  key  value                               a player fact: gil, main_job, jobs.WAR ...
--   b  bag  enabled  count  max
--   i  bag  index  item_id  count  name  augments  ext  extdata
--   e  slot  bag  index
--   k  key_item_id  name
local core = {}

core.SCHEMA = 1

-- Windower's bag ids (res.bags; the same table organizer's _static.bag_ids spells out).
core.BAG_NAMES = {[0] = 'inventory', [1] = 'safe', [2] = 'storage', [3] = 'temporary', [4] = 'locker',
    [5] = 'satchel', [6] = 'sack', [7] = 'case', [8] = 'wardrobe', [9] = 'safe2', [10] = 'wardrobe2',
    [11] = 'wardrobe3', [12] = 'wardrobe4', [13] = 'wardrobe5', [14] = 'wardrobe6', [15] = 'wardrobe7',
    [16] = 'wardrobe8'}

-- Permanent holdings exclude the temporary bag. Some Sortie traversal items persist despite that
-- bag label; sortiecore records its own scoped evidence without changing permanent ownership.
core.BAGS = {'inventory', 'safe', 'safe2', 'storage', 'locker', 'satchel', 'sack', 'case',
    'wardrobe', 'wardrobe2', 'wardrobe3', 'wardrobe4', 'wardrobe5', 'wardrobe6', 'wardrobe7', 'wardrobe8'}

-- get_items('equipment') keys, in the game's slot order.
core.SLOTS = {'main', 'sub', 'range', 'ammo', 'head', 'neck', 'left_ear', 'right_ear', 'body', 'hands',
    'left_ring', 'right_ring', 'back', 'waist', 'legs', 'feet'}

-- get_player() keys that are not about the character's holdings, or change second to second, or are
-- another addon's job: points writes merits and job points.
core.SKIP_PLAYER = {buffs = true, vitals = true, status = true, target_index = true, target_locked = true,
    index = true, id = true, follow_index = true, autorun = true, in_combat = true, merits = true,
    job_points = true, gil = true}

local function clean(v)
    if v == nil then return '-' end
    local s = tostring(v):gsub('%c', ' ')
    if s == '' then return '-' end
    return s
end
core.clean = clean

function core.hex(s)
    if type(s) ~= 'string' or s == '' then return '-' end
    return (s:gsub('.', function(c) return ('%02x'):format(c:byte()) end))
end

-- A table as dotted keys, sorted: {jobs = {WAR = 99}} -> {{'jobs.WAR', 99}}.
local function flatten(prefix, t, out, depth)
    if depth > 3 then return end
    local keys = {}
    for k in pairs(t) do keys[#keys + 1] = k end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    for _, k in ipairs(keys) do
        local v = t[k]
        local key = prefix == '' and tostring(k) or (prefix .. '.' .. tostring(k))
        if type(v) == 'table' then flatten(key, v, out, depth + 1)
        elseif type(v) == 'number' or type(v) == 'string' or type(v) == 'boolean' then out[#out + 1] = {key, v} end
    end
end

-- The player facts: gil first (it comes from get_items or get_player, whichever has it), then every
-- scalar and nested table of get_player() that SKIP_PLAYER does not leave out.
function core.player_rows(player, gil)
    local rows = {}
    if type(gil) == 'number' then rows[#rows + 1] = {'gil', ('%d'):format(gil)} end
    local keep = {}
    for k, v in pairs(type(player) == 'table' and player or {}) do
        if type(k) == 'string' and not core.SKIP_PLAYER[k] and not k:match('^_') then keep[k] = v end
    end
    flatten('', keep, rows, 1)
    return rows
end

-- What extdata.decode gave, split: the augment strings in order, and every other scalar (rank, path,
-- type is dropped as it only names the decoder) as k=v.
function core.split_decoded(d)
    if type(d) ~= 'table' then return {}, {} end
    local augs = {}
    for _, a in ipairs(type(d.augments) == 'table' and d.augments or {}) do
        local s = tostring(a)
        if s ~= '' and s ~= 'none' then augs[#augs + 1] = s end
    end
    local keys, ext = {}, {}
    for k, v in pairs(d) do
        -- extdata.decode includes __raw as binary. The final TSV column already
        -- preserves those exact bytes as hex; putting them in ext breaks text rows.
        if k ~= 'augments' and k ~= 'type' and k ~= '__raw'
            and (type(v) == 'number' or type(v) == 'string' or type(v) == 'boolean') then
            keys[#keys + 1] = k
        end
    end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    for _, k in ipairs(keys) do ext[#ext + 1] = tostring(k) .. '=' .. clean(d[k]):gsub(';', ',') end
    return augs, ext
end

-- A bag read as enabled but holding nothing, while the equipment says a worn piece sits in it, was not loaded
-- yet (seen 2026-10-06: a zone-time snapshot had every equipped slot pointing into empty wardrobes). Its items
-- are unknown, not absent, so it is marked unreadable. Returns the names of the bags it changed.
function core.distrust_empty_bags(bags, equipment)
    local changed = {}
    local worn = {}
    for _, slot in ipairs(core.SLOTS) do
        local index, bag = (equipment or {})[slot], core.BAG_NAMES[(equipment or {})[slot .. '_bag']]
        if type(index) == 'number' and index ~= 0 and bag then worn[bag] = true end
    end
    for _, b in ipairs(bags or {}) do
        if b.enabled and worn[b.name] and #(b.items or {}) == 0 then
            b.enabled, b.items = false, {}
            changed[#changed + 1] = b.name
        end
    end
    return changed
end

-- The previous snapshot's bags, so a bag this sync could not read can keep what it last held. Returns nil
-- when the text is not a snapshot of `character`. {captured = ..., bags = {name = {count, max, items = {raw}}},
-- carried = {name = captured}}: raw is the i row's columns after the bag name, kept verbatim; carried is the
-- `p carried.<bag>` rows an earlier carry-forward wrote, so the original capture time survives repeats.
function core.parse_previous(text, character)
    if type(text) ~= 'string' then return nil end
    local prev = {bags = {}, carried = {}}
    local first = true
    for line in text:gmatch('[^\n]+') do
        local c = {}
        for f in (line .. '\t'):gmatch('([^\t]*)\t') do c[#c + 1] = f end
        if first then
            first = false
            if c[1] ~= 'h' then return nil end
            local kv = {}
            for i = 2, #c do local k, v = c[i]:match('^([^=]+)=(.*)$') if k then kv[k] = v end end
            if kv.schema ~= tostring(core.SCHEMA) or kv.character ~= character then return nil end
            prev.captured = kv.captured
        elseif c[1] == 'b' and c[2] then
            prev.bags[c[2]] = {enabled = c[3] == '1', count = c[4], max = c[5], items = {}}
        elseif c[1] == 'i' and c[2] and prev.bags[c[2]] then
            local raw = {}
            for i = 3, #c do raw[#raw + 1] = c[i] end
            local items = prev.bags[c[2]].items
            items[#items + 1] = {raw = raw}
        elseif c[1] == 'p' and c[2] and c[2]:match('^carried%.') then
            prev.carried[c[2]:sub(9)] = c[3]
        end
    end
    return prev
end

-- A bag that could not be read this time (not loaded, in a bag outside the Mog House, disabled) is unknown,
-- not empty, and a zone-time sync would otherwise overwrite a full snapshot with a partial one. Where the
-- previous snapshot read the bag, keep its items, and say so: the returned {bag = captured} goes into the file
-- as `p carried.<bag>` rows. A bag never read before stays unreadable.
function core.carry_forward(bags, prev)
    local carried = {}
    if not prev then return carried end
    for _, b in ipairs(bags or {}) do
        local old = prev.bags[b.name]
        if not b.enabled and old and old.enabled then
            b.enabled, b.items, b.count, b.max, b.carried = true, old.items, old.count, old.max, true
            carried[b.name] = prev.carried[b.name] or prev.captured or '-'
        end
    end
    return carried
end

-- bags: {{name, enabled, count, max, items = {{index, id, count, extdata}, ...}}, ...}
-- equipment: {main = index, main_bag = bag id, ...} (get_items('equipment'))
-- key_items: {id, ...}; names: function(item id) -> name; ki_names: function(key item id) -> name
-- decode: function(item) -> extdata.decode's table or nil
function core.build(o)
    local L = {}
    local function row(...) L[#L + 1] = table.concat({...}, '\t') end
    local h = {schema = core.SCHEMA, addon = 'charsync', addon_version = o.addon_version,
        contributor = o.contributor, character = o.character, captured = o.captured, reason = o.reason}
    local hk = {'schema', 'addon', 'addon_version', 'contributor', 'character', 'captured', 'reason'}
    local parts = {'h'}
    for _, k in ipairs(hk) do parts[#parts + 1] = k .. '=' .. clean(h[k]) end
    L[1] = table.concat(parts, '\t')
    for _, p in ipairs(core.player_rows(o.player, o.gil)) do row('p', clean(p[1]), clean(p[2])) end
    local cb = {}
    for name in pairs(o.carried or {}) do cb[#cb + 1] = name end
    table.sort(cb)
    for _, name in ipairs(cb) do row('p', 'carried.' .. name, clean(o.carried[name])) end
    local n_items = 0
    for _, b in ipairs(o.bags or {}) do
        row('b', b.name, b.enabled and '1' or '0', clean(b.count), clean(b.max))
    end
    for _, b in ipairs(o.bags or {}) do
        if b.enabled then
            for _, it in ipairs(b.items or {}) do
                if it.raw then
                    row('i', b.name, (table.unpack or unpack)(it.raw))
                    n_items = n_items + 1
                elseif it.id and it.id ~= 0 then
                    local augs, ext = {}, {}
                    if it.extdata and o.decode then augs, ext = core.split_decoded(o.decode(it)) end
                    row('i', b.name, clean(it.index), clean(it.id), clean(it.count or 1),
                        clean(o.names and o.names(it.id)), #augs > 0 and clean(table.concat(augs, ' | ')) or '-',
                        #ext > 0 and table.concat(ext, ';') or '-', core.hex(it.extdata))
                    n_items = n_items + 1
                end
            end
        end
    end
    local eq = o.equipment or {}
    for _, slot in ipairs(core.SLOTS) do
        local index, bag = eq[slot], core.BAG_NAMES[eq[slot .. '_bag']]
        if type(index) == 'number' and index ~= 0 and bag then row('e', slot, bag, ('%d'):format(index)) end
    end
    local kis = {}
    for _, id in pairs(o.key_items or {}) do if type(id) == 'number' then kis[#kis + 1] = id end end
    table.sort(kis)
    for _, id in ipairs(kis) do row('k', ('%d'):format(id), clean(o.ki_names and o.ki_names(id))) end
    return table.concat(L, '\n') .. '\n', {items = n_items, key_items = #kis, bags = #(o.bags or {})}
end

-- Describe saved evidence, never turn an unread bag or unrecorded menu into zero.
-- Progress timestamps are saved changes, not a promise of the last menu visit.
function core.capture_status(character, snapshot, currencies, progress)
    local out = {}
    local previous = core.parse_previous(snapshot, character)
    if previous and previous.captured then
        out[#out + 1] = 'snapshot: ' .. tostring(previous.captured or 'timestamp unknown')
        local unread, carried = {}, {}
        for name, bag in pairs(previous.bags) do if not bag.enabled then unread[#unread + 1] = name end end
        for name in pairs(previous.carried) do carried[#carried + 1] = name end
        table.sort(unread) table.sort(carried)
        for _, name in ipairs(carried) do
            out[#out + 1] = name .. ': carried contents from ' .. tostring(previous.carried[name])
        end
        if #unread > 0 then out[#out + 1] = 'unread bags: ' .. table.concat(unread, ', ') .. ' (unknown, not empty)' end
        if #unread > 0 or #carried > 0 then out[#out + 1] = 'refresh storage: enter your Mog House, then //charsync; unread wardrobes may be unavailable' end
    else
        out[#out + 1] = 'snapshot: missing or not a valid snapshot for ' .. tostring(character) .. '; run //charsync'
    end
    for _, packet in ipairs({'0x113', '0x118'}) do
        local row = (currencies or {})[packet]
        out[#out + 1] = 'currencies ' .. packet .. ': ' .. (row and tostring(row.date) .. ' (date only)' or 'not recorded')
    end
    out[#out + 1] = 'refresh currencies: open both Currencies pages; //charsync alone does not refresh them'
    local count, oldest, newest = 0, nil, nil
    for _, row in pairs(progress or {}) do
        count = count + 1
        local stamp = row.captured
        if stamp and stamp ~= '' then
            if not oldest or stamp < oldest then oldest = stamp end
            if not newest or stamp > newest then newest = stamp end
        end
    end
    if count > 0 then
        out[#out + 1] = ('progress: %d raw pages; saved changes %s to %s'):format(count, oldest or 'unknown', newest or 'unknown')
        out[#out + 1] = 'unchanged pages keep their old timestamps; these pages do not yet establish quest completion'
    else out[#out + 1] = 'progress: no saved pages' end
    out[#out + 1] = 'refresh progress: open Quest and Mission menu categories; //charsync progress lists saved pages'
    return out
end

return core
