--charsync: one whole snapshot of a character (every bag's items with augments, gil, jobs, what is
--equipped, key items) for the ffxi-atlas character page (IDEAS #60). READ-ONLY: it reads what the
--client already holds; nothing is ever sent.
--
-- 0.3.13: also records packets that arrive on their own at login or zoning (visited zones, monstrosity, Alter Ego
-- points, MMM, crafts, title) raw into passive.tsv; `//cs passive` says which have arrived. And the warp unlock bitmasks (0x063 order 6: home points, survival guides, waypoints) into
-- warps.tsv raw; `//cs warps` counts them, `//cs warps have|missing [home|guides|waypoints]` names them. It arrives on login / zoning, no menu click needed. Bit numbers only.
--
-- 0.3.2: a bag this sync cannot read (a zone out of the Mog House, a disabled wardrobe) keeps what the
-- previous snapshot held instead of turning unknown, and says so in `p carried.<bag>` rows (the capture time
-- of the contents). A zone sync no longer overwrites a full Mog House snapshot with a partial one.
--
-- 0.3.1: a bag read as empty while a worn piece sits in it is written as unreadable (zone-time snapshots had
-- empty wardrobes); progress pages no longer count as changed when only the packet header's sequence differs.
--
-- 0.3.0 (IDEAS #76): also records the client's quest / mission log packets (0x056) raw into progress.tsv, so
-- ffxi-atlas can learn how they map (docs/PROGRESS-LOG.md). Nothing is decoded here and nothing is sent;
-- open the Quest and Mission menus to make the client send the pages.
--
-- 0.2.0 (IDEAS #74 step 1): also writes what the points and rema addons used to, from the same bag reads:
-- points.tsv (merits, job points), rema.tsv (REMA weapons held) and currencies.tsv (the Currencies menu,
-- from 0x113 / 0x118). Those two addons are retired; their cores (pointscore, remacore) and the generated
-- rema_weapons.lua moved here. Each extra runs on its own under pcall, so one failing never stops the
-- snapshot. rema's box is gone (never game-tested); //charsync rema prints the same lines.
--
-- Writes data/<Char>/snapshot.tsv on load, login, zoning and //charsync, in ffxi-atlas's character
-- snapshot schema v1 (docs/CHARACTER-SNAPSHOT.md; atlas owns the format, this addon conforms). The
-- file is written to a temp name and then moved into place, so a reader never sees half of one. A
-- copy per day goes in data/<Char>/history/ (the last snapshot of the day wins), kept keep_days days.
-- ffxi-atlas `store.pack pull` copies snapshot.tsv into the character pack.
_addon.name = 'charsync'
_addon.author = 'ImpactLogic'
_addon.version = '0.3.25'   -- bump on every change that reaches the game
_addon.commands = {'charsync', 'cs'}

config = require('config')
package.path = (windower.windower_path or '') .. 'addons/boxtheme/?.lua;' .. package.path
pcall(function() require('heapstat').start() end)   -- one Lua-heap row per 10 min in data/heap.csv (idea #219)
packets = require('packets')
extdata = require('extdata')
res = require('resources')

local core = require('synccore')
local needcore = require('needcore')
local pointscore = require('pointscore')
local remacore = require('remacore')
local progresscore = require('progresscore')
local progressreceiptcore = require('progressreceiptcore')
local roecore = require('roecore')
local masterycore = require('masterycore')
local warpcore = require('warpcore')
local passivecore = require('passivecore')
local temprixcore = require('temprixcore')
local temprixprogress = require('temprixprogress')
local remapath = require('remapath')
local sortiecore = require('sortiecore')
local spellcore = require('spellcore')
local temprix_state = {}
local WEAPONS = require('rema_weapons')

local defaults = {
    log_max_kb = 256,
    temprix_capture = true, -- passive menu/dialogue evidence; no actions or decoding
    sortie_capture = true, -- separate client-view temporary evidence on normal sync
    spell_capture = true, -- passive learned API flags; not castability/removal proof
    keep_days = 60,
    -- Currency fields named by //charsync rema: case-insensitive substrings of the names packets.parse gives
    -- 0x113 / 0x118. Every numeric field is written to currencies.tsv whatever this says.
    watch = {'hallmark', 'gallantry', 'plasm', 'escha', 'gallimaufry', 'segment'},
    show_box = false,   -- //charsync box on|off: next REMA step per weapon held; off until asked
    box = {pos = {x = 20, y = 500}, text = {size = 10, font = 'Consolas'},
           bg = {alpha = 170}, flags = {draggable = true}},
}
local settings = config.load(defaults)

local DATA = windower.addon_path .. 'data/'
local NL = string.char(10)

local function ensure_dir(d)
    if not windower.dir_exists(d) then windower.create_dir(d) end
    return d
end

local function log_line(text)
    local path = ensure_dir(DATA) .. 'charsync.log'
    local f = io.open(path, 'a')
    if not f then return end
    if f:seek('end') > (tonumber(settings.log_max_kb) or 256) * 1024 then
        f:close()
        f = io.open(path, 'w')
        if not f then return end
    end
    f:write(os.date('[%m-%d %H:%M:%S] ') .. text .. NL)
    f:close()
end

local function msg(text)
    windower.add_to_chat(207, 'charsync: ' .. text)
    log_line(text)
end

local function guarded(label, fn)
    return function(...)
        local args, n = {...}, select('#', ...)
        local ok, err = xpcall(function() return fn(unpack(args, 1, n)) end, debug.traceback)
        if not ok then
            log_line('ERROR in ' .. label .. ': ' .. tostring(err))
            windower.add_to_chat(167, 'charsync error in ' .. label .. ' - see charsync/data/charsync.log')
        end
    end
end

-- Everything below belongs to state.char and is dropped when the character changes (template rules).
local refresh_box   -- assigned below; extras() and the Temprix hook call it
local state = {char = nil, last = nil, rows = {}, snap = {}, totals = nil, progress = nil, progress_receipts = nil, roe = nil}
local CURRENCY_PACKETS = {[0x113] = '0x113', [0x118] = '0x118'}
-- res/buffs.lua: 270 / 271 / 272 = Aftermath Lv.1 / 2 / 3, 273 = Aftermath.
local AFTERMATH = {[270] = 'Lv.1', [271] = 'Lv.2', [272] = 'Lv.3', [273] = 'up'}

local function current_char()
    local player = windower.ffxi.get_player()
    local name = player and player.name or nil
    if name ~= state.char then
        temprix_state = {}
        state.roe = nil state.warps = nil state.passive = nil
    state.char, state.last, state.rows, state.snap, state.totals, state.progress = name, nil, {}, {}, nil, nil
        state.progress_receipts = nil
        if name then
            local dir = DATA .. name .. '/'
            -- Carry over what the retired rema addon saved, so a Currencies page not reopened is not lost.
            local f = io.open(dir .. 'currencies.tsv', 'r') or io.open(windower.addon_path .. '../rema/data/' .. name .. '/currencies.tsv', 'r')
            if f then state.snap = remacore.parse_currencies(f:read('*a')) f:close() end
            log_line('character is now ' .. name .. ' - per-character state cleared')
        end
    end
    return state.char
end

-- The contributor id atlas pools on (random per install, never a character name). combatlog made one
-- first; reuse it so an install is one contributor whichever addon wrote the file.
local contributor_id = nil
local function contributor()
    if contributor_id then return contributor_id end
    for _, path in ipairs({windower.addon_path .. '../combatlog/data/contributor.txt', DATA .. 'contributor.txt'}) do
        local f = io.open(path, 'r')
        if f then
            local v = (f:read('*l') or ''):match('^%s*([0-9a-f]+)%s*$')
            f:close()
            if v and #v >= 16 and #v <= 64 then contributor_id = v return v end
        end
    end
    math.randomseed(os.time() + math.floor(os.clock() * 1000))
    local hex = {}
    for i = 1, 16 do hex[i] = ('%x'):format(math.random(0, 15)) end
    contributor_id = table.concat(hex)
    local f = io.open(ensure_dir(DATA) .. 'contributor.txt', 'w')
    if f then f:write(contributor_id, NL) f:close() end
    log_line('new contributor id ' .. contributor_id)
    return contributor_id
end

local function read_gil(player, all)
    if type(player) == 'table' and type(player.gil) == 'number' then return player.gil end
    if type(all) == 'table' and type(all.gil) == 'number' then return all.gil end
    return nil
end

local function item_name(id)
    local r = res.items[id]
    return r and (r.english or r.en or r.name) or nil
end

local function ki_name(id)
    local r = res.key_items[id]
    return type(r) == 'table' and (r.english or r.en or r.name) or nil
end

local function decode(item)
    local ok, d = pcall(extdata.decode, item)
    return ok and d or nil
end

-- One bag as the schema wants it. get_bag_info gives enabled / count / max (cqshop reads it the same
-- way, field-tested); get_items(bag) the items, as rema reads them. A bag that is not enabled (not yet
-- bought, or not loaded) has items that are unknown, not absent.
local function read_bag(name)
    local ok_i, info = pcall(windower.ffxi.get_bag_info, name)
    info = ok_i and type(info) == 'table' and info or nil
    local ok, items = pcall(windower.ffxi.get_items, name)
    if not ok or type(items) ~= 'table' or items.enabled == false or (info and info.enabled == false) then
        return {name = name, enabled = false, count = info and info.count, max = info and info.max, items = {}}
    end
    local list = {}
    for i, it in ipairs(items) do
        if type(it) == 'table' and it.id and it.id ~= 0 then
            list[#list + 1] = {index = it.slot or i, id = it.id, count = it.count, extdata = it.extdata}
        end
    end
    return {name = name, enabled = true, count = info and info.count or items.count,
            max = info and info.max or items.max, items = list}
end

local function write_atomic(path, text)
    local tmp = path .. '.tmp'
    local f = io.open(tmp, 'w')
    if not f then log_line('could not write ' .. tmp) return false end
    f:write(text)
    f:close()
    os.remove(path)   -- Windows' rename will not replace an existing file
    local ok, err = os.rename(tmp, path)
    if not ok then log_line('could not move ' .. tmp .. ' into place: ' .. tostring(err)) return false end
    return true
end

local function prune(dir)
    local keep = tonumber(settings.keep_days) or 60
    local cutoff = os.date('%Y-%m-%d', os.time() - keep * 86400)
    local ok, names = pcall(windower.get_dir, dir)
    for _, name in ipairs(ok and names or {}) do
        local day = name:match('^snapshot%-(%d%d%d%d%-%d%d%-%d%d)%.tsv$')
        if day and day < cutoff then os.remove(dir .. name) end
    end
end

-- Augment strings from extdata, plus any other scalar it decodes (an Aeonic's rank may be one).
local function rema_decode(item)
    if not item.extdata then return nil end
    local ok, d = pcall(extdata.decode, item)
    if not ok or type(d) ~= 'table' then return nil end
    local out = {}
    for _, a in ipairs(type(d.augments) == 'table' and d.augments or {}) do out[#out + 1] = tostring(a) end
    local keys = {}
    for k, v in pairs(d) do
        if k ~= 'augments' and k ~= 'type' and (type(v) == 'number' or type(v) == 'string') then keys[#keys + 1] = k end
    end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    for _, k in ipairs(keys) do out[#out + 1] = tostring(k) .. '=' .. tostring(d[k]) end
    return out
end

local function aftermath()
    local player = windower.ffxi.get_player()
    for _, id in ipairs(player and player.buffs or {}) do
        if AFTERMATH[id] then return AFTERMATH[id] end
    end
    return nil
end

local function char_dir()
    return ensure_dir(ensure_dir(DATA) .. state.char .. '/')
end

-- points.tsv: what get_player() holds for merits and job points (the retired points addon's dump).
local function write_points(why)
    local player = windower.ffxi.get_player()
    if not player then return 0 end
    local ok_jp, res_jp = pcall(function() return res.job_points end)
    local ok_m, res_m = pcall(function() return res.merit_points end)
    local rows = pointscore.rows(player, ok_jp and res_jp or nil, ok_m and res_m or nil)
    write_atomic(char_dir() .. 'points.tsv', pointscore.to_tsv(rows, os.date('%Y-%m-%d')))
    log_line(('points (%s): %d rows in points.tsv'):format(why, #rows))
    if #rows.unnamed > 0 then
        log_line(('%d without a res name: %s'):format(#rows.unnamed, table.concat(rows.unnamed, ', ')))
    end
    return #rows
end

-- rema.tsv: every REMA weapon copy in a bag the snapshot could read.
local function write_rema(why, bags)
    local readable = {}
    for _, b in ipairs(bags) do
        if b.enabled then readable[#readable + 1] = {name = b.name, items = b.items} end
    end
    state.rows = remacore.scan(readable, WEAPONS, rema_decode)
    write_atomic(char_dir() .. 'rema.tsv', remacore.rema_tsv(state.rows, os.date('%Y-%m-%d')))
    log_line(('rema (%s): %d bags, %d REMA weapon copies'):format(why, #readable, #state.rows))
    return #state.rows
end

-- Every extra on its own, so one failing never costs the snapshot or the others.
local function write_sortie(why)
    if not settings.sortie_capture then return end
    local ok_info,info=pcall(function() return windower.ffxi.get_info() end)
    local zone=ok_info and type(info)=='table' and info.zone or nil
    local before,after,bag
    if zone==133 then
        -- res/bags.lua identifies Temporary as3; metadata API requires its numeric ID.
        local ok_a,a=pcall(windower.ffxi.get_bag_info,3)
        local ok_b,b=pcall(windower.ffxi.get_items,3)
        local ok_c,c=pcall(windower.ffxi.get_bag_info,3)
        before=ok_a and type(a)=='table' and a or nil
        bag=ok_b and type(b)=='table' and b or nil
        after=ok_c and type(c)=='table' and c or nil
    end
    local capture=sortiecore.capture({character=state.char,epoch=os.time(),zone=zone,
        reason=why,version=_addon.version,before=before,after=after,bag=bag})
    local text=sortiecore.encode(capture)
    local dir=char_dir()
    if not write_atomic(dir..'sortie-temporary.tsv',text) then return end
    local history=io.open(dir..'sortie-temporary-history.tsv','a')
    if not history then error('could not append Sortie temporary history') end
    local written,err=history:write(text) history:close()
    if not written then error('could not write Sortie temporary history: '..tostring(err)) end
    log_line('Sortie temporary evidence ('..why..'): scope='..tostring(capture.in_sortie_scope)..
        ', count-consistent='..tostring(capture.count_consistent_read)..'; current usability/run unknown')
end

local function write_spells(why)
    if not settings.spell_capture then return end
    local ok_i,info=pcall(windower.ffxi.get_info)
    local ready=ok_i and type(info)=='table' and info.logged_in==true
    local ok_a,a,ok_b,b
    if ready then
        ok_a,a=pcall(windower.ffxi.get_spells)
        ok_b,b=pcall(windower.ffxi.get_spells)
    end
    local c=spellcore.capture({character=state.char,epoch=os.time(),reason=why,version=_addon.version,
        logged_in=ready,
        before=ok_a and a or nil,after=ok_b and b or nil,resources=res.spells})
    local text=spellcore.encode(c)
    local dir=char_dir()
    if not write_atomic(dir..'spells.tsv',text) then return end
    local history=io.open(dir..'spells-history.tsv','a')
    if not history then error('could not append learned-spell history') end
    local written,err=history:write(text) history:close()
    if not written then error('could not write learned-spell history: '..tostring(err)) end
    log_line('Learned spell API evidence ('..why..'): '..#c.rows..' flags; stable='..tostring(c.stable)..'; completeness/castability unknown')
end

local function extras(why, bags)
    for _, step in ipairs({
        {'points', function() write_points(why) end},
        {'rema', function() write_rema(why, bags) end},
        {'sortie', function() write_sortie(why) end},
        {'spells', function() write_spells(why) end},
        {'box', function() refresh_box() end},
    }) do
        local ok, err = xpcall(step[2], debug.traceback)
        if not ok then log_line('ERROR in ' .. step[1] .. ': ' .. tostring(err)) end
    end
end

local function sync(why)
    if not current_char() then return nil end
    local player = windower.ffxi.get_player()
    local ok_all, all = pcall(windower.ffxi.get_items)
    all = ok_all and all or nil
    local bags = {}
    for _, name in ipairs(core.BAGS) do bags[#bags + 1] = read_bag(name) end
    local ok_eq, equipment = pcall(windower.ffxi.get_items, 'equipment')
    local distrusted = core.distrust_empty_bags(bags, ok_eq and equipment or nil)
    if #distrusted > 0 then log_line('empty but worn-from, written as not readable: ' .. table.concat(distrusted, ', ')) end
    local carried = {}
    local pf = io.open(char_dir() .. 'snapshot.tsv', 'r')
    if pf then
        local old = pf:read('*a')
        pf:close()
        carried = core.carry_forward(bags, core.parse_previous(old, state.char))
    end
    local carried_names = {}
    for name in pairs(carried) do carried_names[#carried_names + 1] = name end
    table.sort(carried_names)
    if #carried_names > 0 then log_line('unreadable now, kept from the previous snapshot: ' .. table.concat(carried_names, ', ')) end
    local ok_ki, kis = pcall(windower.ffxi.get_key_items)
    local text, counts = core.build({
        addon_version = _addon.version, contributor = contributor(), character = state.char,
        captured = os.date('%Y-%m-%d %H:%M:%S'), reason = why,
        player = player, gil = read_gil(player, all), bags = bags, carried = carried,
        equipment = ok_eq and equipment or nil, key_items = ok_ki and kis or nil,
        names = item_name, ki_names = ki_name, decode = decode,
    })
    local dir = ensure_dir(ensure_dir(DATA) .. state.char .. '/')
    if not write_atomic(dir .. 'snapshot.tsv', text) then return nil end
    local hist = ensure_dir(dir .. 'history/')
    write_atomic(hist .. 'snapshot-' .. os.date('%Y-%m-%d') .. '.tsv', text)
    prune(hist)
    extras(why, bags)
    local unread = {}
    for _, b in ipairs(bags) do if not b.enabled then unread[#unread + 1] = b.name end end
    state.last = {when = os.date('%H:%M:%S'), why = why, counts = counts, unread = unread, carried = carried_names}
    log_line(('sync (%s): %d items in %d bags, %d key items; not readable: %s'):format(why, counts.items,
        counts.bags - #unread, counts.key_items, #unread > 0 and table.concat(unread, ', ') or 'none'))
    return state.last
end

local function report(s)
    if not s then msg('nothing written yet (not logged in?)') return end
    msg(('%s at %s: %d items, %d key items -> data/%s/snapshot.tsv'):format(s.why, s.when, s.counts.items,
        s.counts.key_items, tostring(state.char)))
    if #(s.carried or {}) > 0 then msg('kept from the previous snapshot (not readable now): ' .. table.concat(s.carried, ', ')) end
    if #s.unread > 0 then msg('not readable: ' .. table.concat(s.unread, ', ') .. ' (unknown, not empty)') end
end

-- The merit bank: 0x063 order 2 arrives when the Merits menu opens (fields.lua: Limit Points, Merit Points).
local function read_totals(data)
    local ok, p = pcall(packets.parse, 'incoming', data)
    if ok and type(p) == 'table' and p['Merit Points'] then
        state.totals = {merit_points = p['Merit Points'], max_merit_points = p['Max Merit Points'],
            limit_points = p['Limit Points']}
    end
end

-- progress.tsv: the newest raw copy of each quest / mission log page (IDEAS #76). Pages from earlier sessions
-- are loaded first so opening one menu does not drop the rest; every change is also appended to
-- progress-history.tsv, so completions show up as diffs between two copies of one page.
local function record_progress(id, data)
    local dir = char_dir()
    if not state.progress then
        local f = io.open(dir .. 'progress.tsv', 'r')
        state.progress = f and progresscore.parse(f:read('*a')) or {}
        if f then f:close() end
    end
    local changed, row, changed_at = progresscore.update(state.progress, id, data, os.date('%Y-%m-%d %H:%M:%S'))
    if row then
        if not state.progress_receipts then
            local rf = io.open(dir .. 'progress-receipts.tsv', 'r')
            state.progress_receipts = progressreceiptcore.parse(rf and rf:read('*a') or nil, state.char)
            if rf then rf:close() end
        end
        local observed, receipt = progressreceiptcore.observe(state.progress_receipts, row, changed_at, changed)
        if observed then
            if write_atomic(dir .. 'progress-receipts.tsv', progressreceiptcore.to_tsv(state.progress_receipts,state.char,_addon.version)) then
                local hpath=dir .. 'progress-receipts-history.tsv'
                local hf=io.open(hpath,'a')
                if hf then
                    if hf:seek('end')==0 then hf:write(progressreceiptcore.header(state.char,_addon.version),NL) end
                    hf:write(progressreceiptcore.row_line(receipt),NL) hf:close()
                else log_line('could not append progress receipt history') end
                log_line(('progress receipt: %s type %s, received %s; content changed %s; changed=%s'):format(
                    row.packet,row.type,receipt.received,receipt.content_changed_at,tostring(changed)))
            end
        end
    end
    if not changed then return end
    write_atomic(dir .. 'progress.tsv', progresscore.to_tsv(state.progress))
    local hpath = dir .. 'progress-history.tsv'
    local hf = io.open(hpath, 'a')
    if hf then
        if hf:seek('end') > 512 * 1024 then
            hf:close()
            hf = io.open(hpath, 'w')
        end
        if hf then hf:write(progresscore.row_line(row), NL) hf:close() end
    end
    log_line(('progress: %s type %s, %d bytes (changed)'):format(row.packet, row.type, row.size))
end

-- Geas Fete kill counts from the Temprix menu parameters (hypothesis, see temprixprogress.lua). Newest packet
-- is kept in temprix-progress.tsv; a change in any parameter also appends a line to temprix-progress-history.tsv.
local function record_temprix_progress(row, data)
    local session = row:match('^[^\t]*\t([^\t]*)')
    local captured = os.date('%Y-%m-%d %H:%M:%S')
    local line = temprixprogress.row_line(captured, session or '-', state.char, data)
    if not line then return end
    local d = temprixprogress.decode(data)
    local last = temprix_state.progress
    temprix_state.progress = d
    local f = io.open(char_dir() .. 'temprix-progress.tsv', 'w')
    if f then f:write(temprixprogress.HEADER, NL, line, NL) f:close() end
    local changed = not last
    if last then for i = 1, temprixprogress.PARAM_COUNT do
        if last.params[i] ~= d.params[i] then changed = true end
    end end
    if changed then
        pcall(refresh_box)
        local hf = io.open(char_dir() .. 'temprix-progress-history.tsv', 'a')
        if hf then
            if hf:seek('end') == 0 then hf:write(temprixprogress.HEADER, NL) end
            hf:write(line, NL) hf:close()
        end
    end
end
-- NPC identity comes from the live mob table; no zone/menu/progress-bit guesses.
local function record_temprix(direction, id, data, injected, mode)
    if not settings.temprix_capture or not current_char() then return end
    local npc_id, npc_name
    if id and (id == 0x032 or id == 0x033 or id == 0x034 or id == 0x036 or
        (direction == 'outgoing' and id == 0x05B)) then
        local ok, p = pcall(packets.parse, direction, data)
        if not ok or type(p) ~= 'table' then return end
        npc_id = p.NPC or p.Actor or p.Target
        local mob = npc_id and windower.ffxi.get_mob_by_id(npc_id)
        npc_name = mob and mob.name
    end
    local info = windower.ffxi.get_info()
    local row = temprixcore.observe(temprix_state, {character=state.char,
        zone=info and info.zone, now=os.time(), captured=os.date('%Y-%m-%d %H:%M:%S'),
        direction=direction, id=id, data=data, injected=injected, mode=mode,
        npc_id=npc_id, npc_name=npc_name})
    if not row then return end
    if direction == 'incoming' and id == 0x034 then record_temprix_progress(row, data) end
    local path = char_dir() .. 'temprix.tsv'
    local f = io.open(path, 'a')
    if not f then log_line('Temprix capture: cannot open file') return end
    local size = f:seek('end')
    if size > 1024*1024 then
        f:close()
        local archive = path .. '.' .. os.date('%Y%m%d-%H%M%S') .. '-' .. tostring(math.floor(os.clock()*1000))
        local moved = os.rename(path, archive)
        if not moved then log_line('Temprix capture: archive failed; preserving file') return end
        f = io.open(path, 'a')
        if not f then return end
        size = 0
    end
    if size == 0 then f:write(temprixcore.HEADER, NL) end
    f:write(row, NL) f:close()
end
windower.register_event('outgoing chunk', guarded('Temprix outgoing', function(id, data, modified, injected)
    if id == 0x05B then record_temprix('outgoing', id, data, injected) end
end))
windower.register_event('incoming text', guarded('Temprix text', function(original, modified, mode)
    -- Contextual text is retained raw, never automatically treated as NPC speech/clear credit.
    if type(original) == 'string' then record_temprix('text', nil, original, false, mode) end
end))

windower.register_event('incoming chunk', guarded('incoming', function(id, data, modified, injected)
    if id == 0x032 or id == 0x033 or id == 0x034 or id == 0x036 or id == 0x05C then
        record_temprix('incoming', id, data, injected)
    end
    if id == 0x01B and not injected then
        if current_char() then
            local row = masterycore.observe(id, data, os.date('%Y-%m-%d %H:%M:%S'))
            if row then
                local dir = char_dir()
                local f = io.open(dir .. 'mastery.tsv', 'r')
                local old = masterycore.parse(f and f:read('*a') or nil)
                if f then f:close() end
                if write_atomic(dir .. 'mastery.tsv', masterycore.to_tsv(row)) and
                    (not old or old.rank ~= row.rank) then
                    local hf = io.open(dir .. 'mastery-history.tsv', 'a')
                    if hf then
                        if hf:seek('end') > 512*1024 then hf:close() hf=io.open(dir .. 'mastery-history.tsv','w') end
                        if hf then hf:write(masterycore.row_line(row), NL) hf:close() end
                    end
                    log_line(masterycore.summary(row))
                end
            end
        end
        return
    end
    if not injected and passivecore.key_of(id, data) and current_char() then
        local dir = char_dir()
        if not state.passive then
            local f = io.open(dir .. 'passive.tsv', 'r')
            state.passive = passivecore.parse(f and f:read('*a') or nil)
            if f then f:close() end
        end
        local changed, row = passivecore.update(state.passive, id, data, os.date('%Y-%m-%d %H:%M:%S'))
        if changed then
            write_atomic(dir .. 'passive.tsv', passivecore.to_tsv(state.passive))
            local f = io.open(dir .. 'passive-history.tsv', 'a')
            if f then
                if f:seek('end') > 512*1024 then f:close() f=io.open(dir .. 'passive-history.tsv','w') end
                if f then f:write(passivecore.row_line(row), NL) f:close() end
            end
        end
    end
    if id == 0x063 and data:byte(5) == 6 then
        if current_char() and not injected then
            local row = warpcore.observe(id, data, os.date('%Y-%m-%d %H:%M:%S'))
            if row then
                local dir = char_dir()
                if not state.warps then
                    local f = io.open(dir .. 'warps.tsv', 'r')
                    state.warps = warpcore.parse(f and f:read('*a') or nil)
                    if f then f:close() end
                end
                local changed = warpcore.changed(state.warps, row)
                state.warps = row
                write_atomic(dir .. 'warps.tsv', warpcore.to_tsv(row))
                if changed then
                    local f = io.open(dir .. 'warps-history.tsv', 'a')
                    if f then
                        if f:seek('end') > 512*1024 then f:close() f=io.open(dir .. 'warps-history.tsv','w') end
                        if f then f:write(warpcore.row_line(row), NL) f:close() end
                    end
                    log_line(warpcore.summary(row))
                end
            end
        end
        return
    end
    if id == 0x063 and data:byte(5) == 2 then
        if current_char() then read_totals(data) end
        return
    end
    if roecore.PACKETS[id] and not injected then
        if current_char() then
            local dir = char_dir()
            if not state.roe then
                local f = io.open(dir .. 'roe.tsv', 'r')
                state.roe = roecore.parse(f and f:read('*a') or nil)
                if f then f:close() end
            end
            local valid, row, changed = roecore.update(state.roe, id, data, os.date('%Y-%m-%d %H:%M:%S'))
            if valid then
                write_atomic(dir .. 'roe.tsv', roecore.to_tsv(state.roe))
                if changed then
                    local f = io.open(dir .. 'roe-history.tsv', 'a')
                    if f then
                        if f:seek('end') > 512*1024 then f:close() f=io.open(dir .. 'roe-history.tsv','w') end
                        if f then f:write(roecore.row_line(row), NL) f:close() end
                    end
                    log_line('RoE changed: ' .. row.packet .. ' page ' .. row.type)
                end
            end
        end
        return
    end
    if progresscore.PACKETS[id] and not injected then
        if current_char() then record_progress(id, data) end
        return
    end
    local pk = CURRENCY_PACKETS[id]
    if not pk or injected or not current_char() then return end
    local ok, p = pcall(packets.parse, 'incoming', data)
    local fields = ok and remacore.numeric_fields(p) or {}
    if #fields == 0 then log_line(pk .. ' arrived but parsed to no numeric fields') return end
    state.snap[pk] = {date = os.date('%Y-%m-%d'), fields = fields}
    write_atomic(char_dir() .. 'currencies.tsv', remacore.currencies_tsv(state.snap))
    log_line(('%s: %d fields saved'):format(pk, #fields))
end))

-- Newest Temprix reading: this load's packet, else the saved temprix-progress.tsv.
local function temprix_progress_data()
    local d = temprix_state.progress
    if d or not current_char() then return d end
    local f = io.open(char_dir() .. 'temprix-progress.tsv', 'r')
    if not f then return nil end
    f:read('*l')
    local r = temprixprogress.parse_row(f:read('*l') or '')
    f:close()
    if not r then return nil end
    local bytes = {}
    for _ = 1, temprixprogress.PARAM_BASE do bytes[#bytes + 1] = '\0' end
    for i = 1, temprixprogress.PARAM_COUNT do
        local v = r.params[i] or 0
        for _ = 1, 4 do bytes[#bytes + 1] = string.char(v % 256) v = math.floor(v / 256) end
    end
    return temprixprogress.decode(table.concat(bytes))
end

-- Everything //cs rema path and the box need: paths, held lines and the have() lookup.
local function rema_path_context()
    local ok, paths = pcall(require, 'rema_paths')
    if not ok or type(paths) ~= 'table' or not paths.lines then
        return nil, 'The REMA step lists are not included in this release yet (rema_paths.lua). Your REMA weapons, currencies and snapshot are still recorded.'
    end
    local function saved(name)
        local f = io.open(char_dir() .. name, 'r')
        if not f then return nil end
        local t = f:read('*a') f:close() return t
    end
    local snap = saved('snapshot.tsv')
    local d = temprix_progress_data()
    local have = remapath.make_have({
        snapshot = snap and remapath.parse_snapshot(snap) or nil,
        currencies = state.snap,
        progress = function(ref)
            local key = ref:match('^geasfete:(%w+)$')
            if not d or not key or not d.groups[key] then return nil end
            return d.groups[key].set >= d.groups[key].total
        end})
    return paths, remapath.held(state.rows), have
end

-- //cs rema path [line]: every REMA family's steps for the lines held, or for one named line.
local function rema_path_report(filter)
    local paths, held, have = rema_path_context()
    if not paths then msg(held) return end
    local names = {}
    if filter and filter ~= '' then
        for n in pairs(paths.lines) do if n:lower() == filter:lower() then names[1] = n end end
        if #names == 0 then msg('No REMA line named ' .. filter) return end
    else
        for n in pairs(held) do names[#names + 1] = n end
        table.sort(names)
        if #names == 0 then msg('No REMA weapon held; name a line: //cs rema path Chango') return end
    end
    for _, n in ipairs(names) do
        for _, l in ipairs(remapath.lines(remapath.evaluate(paths, n, held, have))) do msg(l) end
    end
    msg('[x] done  [ready] needs met  [ ] blocked  [?] no data  [gap] not readable yet. Aeonic bit mapping is a hypothesis.')
end

-- //cs box on: one line per REMA weapon held with its next step. Redrawn after a sync or a Temprix reading,
-- not every frame, so it costs nothing between those.
local box, box_panel
function refresh_box()
    if not settings.show_box then
        if box then box:hide() end
        return
    end
    local ok, err = pcall(function()
        if not box then
            local texts = require('texts')
            local pok, panel = pcall(function() return require('boxpanel').new('charsync', {bars = false}) end)
            box_panel = pok and panel or nil
            box = texts.new('', settings.box, settings)
            if box_panel then box_panel:attach(box, settings) end
        end
        local paths, held, have = rema_path_context()
        local lines = {}
        if not paths then lines[1] = 'charsync: ' .. tostring(held)
        else
            local names = {}
            for n in pairs(held) do names[#names + 1] = n end
            table.sort(names)
            for _, n in ipairs(names) do
                local e = remapath.evaluate(paths, n, held, have)
                local nx = e and e.next
                lines[#lines + 1] = nx and ('%s: %s %s'):format(n, ({ready = '[ready]', blocked = '[ ]',
                    unknown = '[?]', gap = '[gap]'})[nx.status] or '', nx.label) or (n .. ': complete')
                if #lines >= 8 then break end
            end
            if #lines == 0 then lines[1] = 'No REMA weapon held (//cs rema path <name>)' end
        end
        box:text(table.concat(lines, NL))
        box:show()
    end)
    if not ok then log_line('ERROR in box: ' .. tostring(err)) end
end

local function handle(cmd, ...)
    cmd = (cmd or 'sync'):lower()
    local a = ({...})[1]
    if cmd == 'version' then
        msg('version ' .. _addon.version)
    elseif cmd == 'sync' or cmd == 'now' then
        report(sync('command'))
    elseif cmd == 'need' then
        -- What the player still has to do for charsync to know their state (menus to open, NPCs to talk to). Read-only.
        if current_char() then
            local rows = needcore.need(function(name)
                local f = io.open(DATA .. state.char .. '/' .. name, 'r')
                if not f then return nil end
                local text = f:read('*a') f:close() return text
            end, os.time())
            local lines, todo = needcore.render(rows, a ~= 'all')
            for _, line in ipairs(lines) do msg(line) end
            msg(todo == 0 and 'nothing required right now' or (todo .. ' thing(s) to do; //cs need all shows finished ones too'))
            for _, w in ipairs(needcore.NOT_YET) do msg('not readable yet: ' .. w) end
        else msg('need: not logged in') end
    elseif cmd == 'status' then
        if current_char() then
            local function saved(name)
                local f = io.open(DATA .. state.char .. '/' .. name, 'r')
                if not f then return nil end
                local text = f:read('*a') f:close() return text
            end
            for _, line in ipairs(core.capture_status(state.char, saved('snapshot.tsv'),
                remacore.parse_currencies(saved('currencies.tsv')),
                progresscore.parse(saved('progress.tsv')))) do msg(line) end
            msg(progressreceiptcore.summary(progressreceiptcore.parse(saved('progress-receipts.tsv'),state.char)))
            for _, line in ipairs(roecore.summary(roecore.parse(saved('roe.tsv')))) do msg(line) end
            msg(masterycore.summary(masterycore.parse(saved('mastery.tsv'))))
        else msg('status: not logged in') end
    elseif cmd == 'spells' then
        if a=='on' or a=='off' then settings.spell_capture=a=='on' config.save(settings) end
        msg('Learned spell API capture '..(settings.spell_capture and 'on' or 'off')..
            ' on normal sync; history retained, no removal/current castability inferred.')
    elseif cmd == 'sortie' then
        if a=='on' or a=='off' then
            settings.sortie_capture=a=='on' config.save(settings)
        end
        msg('Sortie temporary capture '..(settings.sortie_capture and 'on' or 'off')..
            ' on normal sync; separate dated client-view evidence, run/current usability unknown.')
    elseif cmd == 'temprix' then
        if a == 'on' or a == 'off' then
            settings.temprix_capture = a == 'on' config.save(settings)
            if not settings.temprix_capture then temprixcore.reset(temprix_state) end
        end
        if a == 'progress' then
            local d = temprix_progress_data()
            for _, l in ipairs(temprixprogress.summary_lines(d)) do msg(l) end
            return
        end
        msg('Temprix passive recorder ' .. (settings.temprix_capture and 'on' or 'off') ..
            '; ' .. tostring(temprix_state.rows or 0) .. ' rows this load; last ' ..
            tostring(temprix_state.last or 'not observed') .. '. Speak to Temprix and check Aeonic progress; raw evidence only.')
    elseif cmd == 'mastery' then
        if current_char() then
            local f = io.open(char_dir() .. 'mastery.tsv', 'r')
            local row = masterycore.parse(f and f:read('*a') or nil)
            if f then f:close() end
            msg(masterycore.summary(row))
        else msg('Mastery Rank: not logged in') end
    elseif cmd == 'passive' then
        if current_char() then
            local f = io.open(char_dir() .. 'passive.tsv', 'r')
            local rows = passivecore.parse(f and f:read('*a') or nil)
            if f then f:close() end
            for _, line in ipairs(passivecore.summary(rows)) do msg(line) end
        else msg('Passive captures: not logged in') end
    elseif cmd == 'warps' then
        if current_char() then
            local f = io.open(char_dir() .. 'warps.tsv', 'r')
            local row = warpcore.parse(f and f:read('*a') or nil)
            if f then f:close() end
            if a == 'have' or a == 'missing' then
                for _, line in ipairs(warpcore.report(row, a, ({...})[2])) do msg(line) end
            else msg(warpcore.summary(row)) end
        else msg('Warps: not logged in') end
    elseif cmd == 'roe' then
        if current_char() then
            local f = io.open(char_dir() .. 'roe.tsv', 'r')
            local rows = roecore.parse(f and f:read('*a') or nil)
            if f then f:close() end
            for _, line in ipairs(roecore.summary(rows)) do msg(line) end
        else msg('RoE: not logged in') end
    elseif cmd == 'last' then
        report(state.last)
    elseif cmd == 'points' then
        local player = windower.ffxi.get_player()
        if player and current_char() then
            write_points('command')
            for _, l in ipairs(pointscore.summary(player, state.totals)) do msg(l) end
        end
    elseif cmd == 'rema' or cmd == 'currencies' then
        if current_char() then
            if #state.rows == 0 then sync('rema') end
            if a == 'path' then rema_path_report(({...})[2]) return end
            for _, l in ipairs(remacore.summary(state.rows, state.snap, settings.watch)) do msg(l) end
            local am = aftermath()
            if am then msg('Aftermath ' .. am .. ' (time left: buffbox)') end
        end
    elseif cmd == 'progress' or cmd == 'quests' or cmd == 'missions' then
        if current_char() then
            local rows = state.progress
            if not rows then
                local f = io.open(char_dir() .. 'progress.tsv', 'r')
                rows = f and progresscore.parse(f:read('*a')) or {}
                if f then f:close() end
                state.progress = rows
            end
            if progresscore.count(rows) == 0 then
                msg('no quest or mission pages recorded yet: open the Quest and Mission menus (every category), then //charsync progress')
            else
                msg(progresscore.count(rows) .. ' page(s) in progress.tsv:')
                local rf=io.open(char_dir() .. 'progress-receipts.tsv','r')
                local receipts=progressreceiptcore.parse(rf and rf:read('*a') or nil,state.char)
                if rf then rf:close() end
                msg(progressreceiptcore.summary(receipts))
                local keys={} for k in pairs(rows) do keys[#keys+1]=k end table.sort(keys)
                for _, k in ipairs(keys) do msg(progressreceiptcore.page_summary(rows[k],receipts)) end
            end
        end
    elseif cmd == 'box' then
        if a == 'on' or a == 'off' then settings.show_box = (a == 'on') config.save(settings) end
        if current_char() and #state.rows == 0 and settings.show_box then sync('box') end
        refresh_box()
        msg('box ' .. (settings.show_box and 'on' or 'off') .. ' (next REMA step per weapon held)')
    else
        msg('//charsync [sync] | status | last | points | rema [path [line]] | progress | roe | mastery | spells [on|off] | sortie [on|off] | temprix [on|off|progress] | box [on|off] | version  -- read-only')
    end
end

windower.register_event('addon command', guarded('command', handle))

windower.register_event('load', guarded('load', function()
    msg('loaded version ' .. _addon.version .. '  (//charsync; //cs status for capture dates)  read-only: nothing is sent')
    msg('Sortie temporary capture '..(settings.sortie_capture and 'on' or 'off')..
        ' on sync; //cs sortie on|off; separate state/history, no permanent inventory changes')
    msg('Learned spell API capture '..(settings.spell_capture and 'on' or 'off')..
        ' on sync; //cs spells on|off; history retained, current castability unknown')
    -- Temprix pickup is silent: the 0x034 hook records and decodes without chat output (//cs temprix to look).
    msg('Progress receipts on: unchanged raw pages record last received separately; //cs progress for dates, no requests sent')
    if current_char() then sync('load') end
end))

windower.register_event('login', function()
    coroutine.schedule(guarded('login', function() current_char() sync('login') end), 10)
end)

-- Moving things to or from Mog House storage shows up after the next zone.
windower.register_event('zone change', function()
    temprixcore.reset(temprix_state)
    coroutine.schedule(guarded('zone', function() sync('zone') end), 10)
end)

windower.register_event('logout', guarded('logout', function()
    temprix_state = {}
    state.roe = nil state.warps = nil state.passive = nil
    state.char, state.last, state.rows, state.snap, state.totals, state.progress = nil, nil, {}, {}, nil, nil
    state.progress_receipts = nil
end))
