--combatlog: READ-ONLY recorder of your own combat actions, for gear and stat analysis (IDEAS #22).
--
--It records and nothing else: no automation, no conclusions. Rows are
--mechanical facts (message ids and amounts); attribution and analysis happen at ingest in
--ffxi-atlas, the same split ffxibazaar uses.
--
--The box (0.6.0) is a live readout of your own fighting -- damage, DPS, hit / crit, rounds, WS,
--skillchains, kills, Aftermath uptime -- kept in memory by live.lua, plus the missing-buff warning
--(//cbt expect). It reads the same packets the recorder does and never acts on them.
--
--0.9.0 (SCH and RUN): the magic line counts magic bursts per spell (message 252), and what enemies do
--to you is kept in memory for a TAKEN line and a tank view (//cbt view taken) -- damage per second
--of being hit, the biggest hit, the worst source, and your share on attacks that hit the party too.
--The box needs nothing switched on; recording those hits to the file still needs //cbt incoming.
--
--1.0.0: writes version 1 of ffxi-atlas's combat log schema (docs/COMBAT-LOG-SCHEMA.md there, which owns
--the standard): an h row with the schema version and a random contributor id (data/contributor.txt,
--never the character name) when a file is opened, the augments of worn gear (gear_aug), and
--//cbt test markers (x rows) so a comparison can be tied to a stated test.
--
--Evidence: the action packet is read with windower.packets.parse_action, and the equipped set with
--windower.ffxi.get_items('equipment') + get_items(bag, slot).id. Both APIs, and the hit/miss/WS
--message id lists in rows.lua, were taken from working Windower code (cyritegamestudios/trust
--v17.7.1, read 2026-09-17), not written from memory. Fields this addon has not confirmed are
--DISCOVERED at runtime (//cbt fields) rather than assumed.

_addon.name = 'CombatLog'
_addon.author = 'ImpactLogic'
_addon.version = '1.4.2'   -- 1.4.0: obeys the //rec master switch
_addon.commands = {'combatlog', 'cbt'}

config = require('config')
texts = require('texts')
res = require('resources')
-- Combat recording requires an affirmative answer from the shared //rec switch.
package.path = (windower.windower_path or '') .. 'addons/boxtheme/?.lua;' .. package.path
local rec_ok, recording = pcall(require, 'recording')
local function master_on()
    if not rec_ok then return false end
    local ok, on = pcall(recording.enabled, 'combatlog')
    return ok and on == true
end
extdata = require('extdata')   -- augments, read-only, as rema and stash decode them

local rows = require('rows')
local live = require('live')
require('pack')   -- data:unpack in the outgoing handler; without it packet reads fail silently (garden 0.1.3)

local EQUIP_SLOTS = {'main', 'sub', 'range', 'ammo', 'head', 'neck', 'ear1', 'ear2',
                     'body', 'hands', 'ring1', 'ring2', 'back', 'waist', 'legs', 'feet'}

-- 0.8.0: get_items('equipment') names the ear and ring slots left_ear / right_ear / left_ring /
-- right_ring (GearSwap statics.lua default_slot_map, read 2026-09-28). Before 0.8.0 this addon
-- asked for 'ear1' etc., got nil, and wrote 0 for all four slots in every row. The column names
-- and order in the rows are unchanged.
local EQUIP_KEY = {ear1 = 'left_ear', ear2 = 'right_ear', ring1 = 'left_ring', ring2 = 'right_ring'}
local function equip_key(slot) return EQUIP_KEY[slot] or slot end

-- Equip packets (0x050 / 0x051) number the slots differently from get_items('equipment').
-- From Windower res/slots.lua, not from memory.
local SLOT_NAME = {[0] = 'main', [1] = 'sub', [2] = 'range', [3] = 'ammo', [4] = 'head', [5] = 'body',
    [6] = 'hands', [7] = 'legs', [8] = 'feet', [9] = 'neck', [10] = 'waist', [11] = 'ear1',
    [12] = 'ear2', [13] = 'ring1', [14] = 'ring2', [15] = 'back'}

local defaults = {
    log_max_kb = 256,
    include_incoming = false,   -- also record actions aimed AT you (defence/enmity work, later)
    context_secs = 10,          -- re-snapshot context at most this often
    data_max_mb = 20,           -- per character per day; the busiest day so far was 0.3 MB
    expect_buffs = 'region',    -- warn on the box when one is missing while engaged; //cbt expect
                                -- 'region' = this zone's Signet / Sanction / Sigil / Ionis (see below)
    reward_items = "Ra'Kaznar starstone",   -- comma list: item names to tie to the enemy that died with them (r rows)
    show_box = true,
    view = 'damage',            -- the box: damage | short | diag  (//cbt view)
    box = {pos = {x = 300, y = 380}, text = {size = 10, font = 'Consolas'},
           bg = {alpha = 170}, flags = {draggable = true}},
}
local settings = config.load(defaults)
-- Themed background from addons/boxtheme (idea #57), created before the box so the text draws on top.
-- Optional: without boxtheme the box keeps its own flat background.
package.path = (windower.windower_path or '') .. 'addons/boxtheme/?.lua;' .. package.path
local panel_ok, panel = pcall(function() return require('boxpanel').new('combatlog') end)
if not panel_ok then panel = nil end
local box = texts.new('', settings.box, settings)
if panel then panel:attach(box, settings) end

local DATA = windower.addon_path .. 'data/'
local NL = string.char(10)

local state = {
    char = nil,
    player_id = nil,
    ctx_id = 0,
    ctx_key = nil,
    ctx_time = 0,
    session = {actions = 0, ctx = 0, start = os.time(), ws = 0},
    fields_seen = {act = {}, target = {}, action = {}},
    sent = {},          -- slot name -> {id, t}: the last item our client SENT an equip packet for
    pending_ws = {},    -- ws id -> {ctx, t}: WS sent, result not seen yet
    -- Recording is a SESSION switch, on at every load, never saved (0.4.5). It used to be saved in
    -- settings.xml: the owner turned it off one morning to save space, and every later reload came
    -- back silently not recording -- the Ambuscade run of 2026-09-18 was lost that way. And the
    -- file is shared by both clients: a save from one rewrites the other character's section from
    -- a stale copy (IDEAS #23), so a saved switch cannot be trusted anyway. //cbt off pauses until
    -- the next load.
    recording = true,
    test = nil,         -- 1.0.0: the running //cbt test: {label, note}
    live = live.new(),  -- the box's running totals; //cbt reset starts them again
}

-- Writing needs all three: this session's //cbt switch, a loaded character, and the //rec master switch.
local function writing()
    return state.recording and state.char and master_on()
end

-------------------------------------------------------------------------------
-- Log
-------------------------------------------------------------------------------
local function ensure_dir(d)
    if not windower.dir_exists(d) then windower.create_dir(d) end
    return d
end

local function log_line(text)
    local path = ensure_dir(DATA) .. 'combatlog.log'
    local f = io.open(path, 'a')
    if not f then return end
    if f:seek('end') > (tonumber(settings.log_max_kb) or 256) * 1024 then
        f:close()
        f = io.open(path, 'w')
        if not f then return end
        f:write('== log trimmed at ' .. os.date('%Y-%m-%d %H:%M:%S') .. ' ==' .. NL)
    end
    f:write(os.date('[%m-%d %H:%M:%S] ') .. text .. NL)
    f:close()
end

local function msg(text)
    windower.add_to_chat(207, 'CombatLog: ' .. text)
    log_line(text)
end

local function guarded(label, fn)
    return function(...)
        local args, n = {...}, select('#', ...)
        local ok, err = xpcall(function() return fn(unpack(args, 1, n)) end, debug.traceback)
        if not ok then
            log_line('ERROR in ' .. label .. ': ' .. tostring(err))
            windower.add_to_chat(167, 'CombatLog error in ' .. label .. ' - see combatlog/data/combatlog.log')
        end
    end
end

rows.dir = DATA
rows.max_bytes = (tonumber(settings.data_max_mb) or 20) * 1024 * 1024
rows.on_full = function(path)
    msg(('today\'s file reached %s MB - recording paused until tomorrow (data_max_mb in settings.xml). %s')
        :format(tostring(settings.data_max_mb), path))
end

local function today() return os.date('%Y-%m-%d') end

-- 1.0.0: the contributor id. Random, made once per install and kept in data/contributor.txt, shared by
-- every character on this install: pooled data can tell players apart without naming anyone. Losing
-- the file only makes you a new contributor.
local contributor_id = nil
local function contributor()
    if contributor_id then return contributor_id end
    local path = ensure_dir(DATA) .. 'contributor.txt'
    local f = io.open(path, 'r')
    if f then
        local v = (f:read('*l') or ''):match('^%s*([0-9a-f]+)%s*$')
        f:close()
        if v and #v >= 16 and #v <= 64 then contributor_id = v return v end
    end
    math.randomseed(os.time() + math.floor(os.clock() * 1000))
    local hex = {}
    for i = 1, 16 do hex[i] = ('%x'):format(math.random(0, 15)) end
    contributor_id = table.concat(hex)
    f = io.open(path, 'w')
    if f then f:write(contributor_id, NL) f:close() end
    log_line('new contributor id ' .. contributor_id)
    return contributor_id
end

rows.on_open = function(char)
    local lines = {rows.encode_kv('h', os.time(), {schema = rows.SCHEMA, addon = 'combatlog',
        addon_version = _addon.version, contributor = contributor(), character = char, client = 'windower4'})}
    -- A header resets a reader's running tests, so a test still running is started again after it.
    if state.test then
        lines[2] = rows.encode_kv('x', os.time(), {test = state.test.label, event = 'start', note = state.test.note})
    end
    return lines
end

-------------------------------------------------------------------------------
-- Context: who you were and what you wore
--
-- Written when it changes (or at most every context_secs), never on every swing: a busy hour is
-- thousands of action rows and repeating the gear set on each one would make the file useless.
-- The set recorded is what you were ACTUALLY wearing, read from the game -- not the GearSwap rule
-- that was supposed to fire. Those differ, and that difference is one of the things this data is
-- meant to expose.
-------------------------------------------------------------------------------
local function equipped_ids()
    local ok, eq = pcall(windower.ffxi.get_items, 'equipment')
    if not ok or type(eq) ~= 'table' then return nil end
    local ids = {}
    for _, slot in ipairs(EQUIP_SLOTS) do
        local id = 0
        local bag, index = eq[equip_key(slot) .. '_bag'], eq[equip_key(slot)]
        if bag and index and index > 0 then
            local ok2, item = pcall(windower.ffxi.get_items, bag, index)
            if ok2 and type(item) == 'table' and item.id then id = item.id end
        end
        ids[#ids + 1] = tostring(id)
    end
    return table.concat(ids, ',')
end

-- 1.0.0: augments of the worn items, for the schema's gear_aug key: '<slot 1-16>:<aug>|<aug>;...' in
-- EQUIP_SLOTS order, only slots whose item has any. Two copies of one cape with different augments
-- are different items (ffxi-atlas hard rule 2); before 1.0.0 the rows could not tell them apart.
-- Decoded with Windower's extdata library (rema.lua does the same), cached by the raw extdata.
local aug_cache = {}
local function augments_of(item)
    local raw = item.extdata
    if type(raw) ~= 'string' or raw == '' then return nil end
    local hit = aug_cache[raw]
    if hit ~= nil then return hit or nil end
    local list = {}
    local ok, d = pcall(extdata.decode, item)
    if ok and type(d) == 'table' and type(d.augments) == 'table' then
        for _, a in ipairs(d.augments) do
            a = tostring(a)
            if a ~= '' and a ~= 'none' then list[#list + 1] = (a:gsub('[|;\t\n=]', ' ')) end
        end
    end
    local text = #list > 0 and table.concat(list, '|') or false
    aug_cache[raw] = text
    return text or nil
end

local function equipped_augments()
    local ok, eq = pcall(windower.ffxi.get_items, 'equipment')
    if not ok or type(eq) ~= 'table' then return '' end
    local parts = {}
    for i, slot in ipairs(EQUIP_SLOTS) do
        local bag, index = eq[equip_key(slot) .. '_bag'], eq[equip_key(slot)]
        if bag and index and index > 0 then
            local ok2, item = pcall(windower.ffxi.get_items, bag, index)
            if ok2 and type(item) == 'table' then
                local a = augments_of(item)
                if a then parts[#parts + 1] = i .. ':' .. a end
            end
        end
    end
    return table.concat(parts, ';')
end

local function buff_ids()
    local player = windower.ffxi.get_player()
    if not (player and player.buffs) then return '' end
    local list = {}
    for _, id in ipairs(player.buffs) do list[#list + 1] = tostring(id) end
    table.sort(list)
    return table.concat(list, ',')
end

-- The gear the client has SENT, overlaid on what it shows as equipped. GearSwap swaps the WS set
-- in a few milliseconds before the WS packet goes out, and the client's own equipment view only
-- updates when the server confirms (incoming 0x050) -- GearSwap tracks exactly that gap in its
-- injected_equipment_registry. So at the moment a WS is sent, get_items may still show the TP set.
-- Sends older than SENT_WINDOW seconds are assumed confirmed and ignored. Both views are recorded
-- (gear, gear_sent) so the data shows whether they ever actually differ.
local SENT_WINDOW = 3

local function gear_sent()
    local ok, eq = pcall(windower.ffxi.get_items, 'equipment')
    if not ok or type(eq) ~= 'table' then return nil end
    local now, ids = os.clock(), {}
    for _, slot in ipairs(EQUIP_SLOTS) do
        local s = state.sent[slot]
        local id
        if s and (now - s.t) <= SENT_WINDOW then
            id = s.id
        else
            id = 0
            local bag, index = eq[equip_key(slot) .. '_bag'], eq[equip_key(slot)]
            if bag and index and index > 0 then
                local ok2, item = pcall(windower.ffxi.get_items, bag, index)
                if ok2 and type(item) == 'table' and item.id then id = item.id end
            end
        end
        ids[#ids + 1] = tostring(id)
    end
    return table.concat(ids, ',')
end

-- Remember one outgoing equip: inventory index + bag -> item id, now, before anything moves.
local function note_equip(index, slot_id, bag)
    local slot = SLOT_NAME[slot_id]
    if not slot then return end
    local id = 0
    if index and index > 0 then
        local ok, item = pcall(windower.ffxi.get_items, bag, index)
        if ok and type(item) == 'table' and item.id then id = item.id end
    end
    state.sent[slot] = {id = id, t = os.clock()}
end

-- Everything a context row records, read now.
local function build_fields()
    local player = windower.ffxi.get_player()
    if not player then return nil end
    local info = windower.ffxi.get_info()

    local gear = equipped_ids() or ''
    local buffs = buff_ids()
    local fields = {
        job = player.main_job, lvl = player.main_job_level,
        sub = player.sub_job, sublvl = player.sub_job_level,
        zone = info and info.zone, gear = gear, buffs = buffs,
    }
    local aug = equipped_augments()
    if aug ~= '' then fields.gear_aug = aug end
    -- player.stats is not confirmed on every Windower build, so take it defensively and let the
    -- absence show up as missing columns rather than as an error.
    if type(player.stats) == 'table' then
        for stat, value in pairs(player.stats) do
            if type(value) == 'number' then fields['stat_' .. tostring(stat):lower()] = value end
        end
    end
    if type(player.vitals) == 'table' then
        fields.tp, fields.hpp, fields.mpp = player.vitals.tp, player.vitals.hpp, player.vitals.mpp
        -- 0.8.0: HP itself, not only the rounded %, so damage taken can be put against max HP.
        -- Names as BlueAutoLevel and vanalytics read them (player.vitals.hp / max_hp).
        fields.hp, fields.max_hp = player.vitals.hp, player.vitals.max_hp
    end
    return fields
end

-- Snapshot the context if it changed; returns the context id to tag action rows with.
local function current_ctx()
    local now = os.time()
    if state.ctx_key and (now - state.ctx_time) < (tonumber(settings.context_secs) or 10) then
        return state.ctx_id
    end

    local fields = build_fields()
    if not fields then return state.ctx_id end

    local key = table.concat({fields.job or '?', fields.lvl or '?', fields.sub or '?',
        fields.sublvl or '?', fields.zone or '?', fields.gear, fields.gear_aug or '', fields.buffs}, '|')

    state.ctx_time = now
    if key ~= state.ctx_key then
        state.ctx_key = key
        state.ctx_id = state.ctx_id + 1
        state.session.ctx = state.session.ctx + 1
        if state.char then
            rows.append(state.char, today(), rows.encode_ctx(now, state.ctx_id, fields))
        end
    end
    return state.ctx_id
end

-- A weapon skill's own context, written at the moment it is SENT: the TP about to be spent, the
-- buffs up right now (other people's rolls and songs included -- the attack that decides whether
-- PDL is worth anything), the target, and gear_sent (the WS set, see gear_sent above). The result
-- row, which arrives after GearSwap has already swapped back, is pointed at this context.
local WS_WINDOW = 15   -- seconds a sent WS waits for its result before it is considered lost

local function snapshot_ws(ws, target)
    local fields = build_fields()
    if not (fields and state.char) then return end
    fields.phase, fields.ws, fields.ws_target = 'ws', ws, target
    fields.gear_sent = gear_sent() or ''
    -- 0.5.0: the target's HP% when the WS went out (mob.hpp, as enemybar/AutoWS read it), so boss
    -- phases and near-dead targets can be told apart in WS damage.
    local ok, mob = pcall(windower.ffxi.get_mob_by_id, target)
    if ok and type(mob) == 'table' and type(mob.hpp) == 'number' then fields.ws_target_hpp = mob.hpp end
    state.ctx_id = state.ctx_id + 1
    state.session.ctx = state.session.ctx + 1
    state.session.ws = (state.session.ws or 0) + 1   -- nil-safe: 0.2.0 crashed here on every WS (login rebuilt session without ws)
    rows.append(state.char, today(), rows.encode_ctx(os.time(), state.ctx_id, fields))
    state.pending_ws[ws] = {ctx = state.ctx_id, t = os.clock()}
    -- The next ordinary action must take a fresh snapshot, not inherit this WS context.
    state.ctx_key = nil
end

-- 0.8.0: a hit taken gets its own context, like a WS does, so "was I in my DT set when that
-- landed?" has an answer. Before, context was re-read at most every context_secs (10 s), and a
-- WS set is on for about one second: a hit landing inside it was filed under the TP set.
-- Written for every enemy action that includes you as a target (damage, debuff or miss) when
-- incoming recording is on. It holds gear (what the client shows), gear_sent (what GearSwap has
-- just asked for), hp / max_hp and buffs at the moment the packet arrives. Whether hp already
-- includes this hit depends on which packet the server sent first; the next hit's context shows
-- the HP after it either way.
local function snapshot_hit(actor_id)
    local fields = build_fields()
    if not (fields and state.char) then return nil end
    fields.phase, fields.hit_by = 'hit', actor_id
    fields.gear_sent = gear_sent() or ''
    state.ctx_id = state.ctx_id + 1
    state.session.ctx = state.session.ctx + 1
    rows.append(state.char, today(), rows.encode_ctx(os.time(), state.ctx_id, fields))
    state.ctx_key = nil
    return state.ctx_id
end

-- 0.8.0: what you were ACTUALLY wearing when the weapon skill landed. gear_sent (above) is what
-- GearSwap asked for, and the player has seen GearSwap miss the WS set now and then (2026-09-28).
-- The client's own view (gear) changes only when the server confirms an equip (incoming 0x050,
-- which GearSwap's packet_parsing.lua matches against what it sent), and the server handles the
-- WS set's equips before the weapon skill itself, so when the result arrives the view shows what
-- the server used. Each slot of gear_sent that differs from this is a swap that did not happen.
-- (That the confirmations arrive before the result is the one assumption here; a result where
-- every slot differs would show it failing.)
local function snapshot_ws_result(ws, ws_ctx)
    local fields = build_fields()
    if not (fields and state.char) then return end
    fields.phase, fields.ws, fields.ws_ctx = 'ws_result', ws, ws_ctx
    state.ctx_id = state.ctx_id + 1
    state.session.ctx = state.session.ctx + 1
    rows.append(state.char, today(), rows.encode_ctx(os.time(), state.ctx_id, fields))
    state.ctx_key = nil
end

-- 0.9.0: the same for a spell of yours (category 4). GearSwap's midcast set is on while the spell
-- resolves and aftercast swaps back after the result, so gear here is the set the spell was cast in
-- (the same assumption as a WS result). Without this, a nuke was filed under a context up to 10 s
-- old -- usually the idle or TP set -- and "which set nukes harder" had no answer (SCH).
local function snapshot_spell_result(spell)
    local fields = build_fields()
    if not (fields and state.char) then return nil end
    fields.phase, fields.spell = 'spell_result', spell
    fields.gear_sent = gear_sent() or ''
    state.ctx_id = state.ctx_id + 1
    state.session.ctx = state.session.ctx + 1
    rows.append(state.char, today(), rows.encode_ctx(os.time(), state.ctx_id, fields))
    state.ctx_key = nil
    return state.ctx_id
end

-- Outgoing: equip packets (GearSwap's are injected, so injected ones count too) and our own WS.
-- GearSwap notes that injected chunks reach this event BEFORE the uninjected ones they precede,
-- so the WS set's equip packets are already noted when the WS packet itself is seen.
windower.register_event('outgoing chunk', guarded('outgoing chunk', function(id, data)
    -- The box shows the TP each WS was sent at, recording or not.
    if id == 0x01A and #data >= 0x0E and data:unpack('H', 0x0B) == 7 then
        local player = windower.ffxi.get_player()
        live.ws_sent(state.live, data:unpack('H', 0x0D), player and player.vitals and player.vitals.tp)
    end
    if not writing() then return end
    if id == 0x050 and #data >= 0x07 then
        note_equip(data:byte(0x05), data:byte(0x06), data:byte(0x07))
    elseif id == 0x051 and #data >= 0x08 then
        local count = math.min(data:byte(0x05) or 0, 16)
        for i = 0, count - 1 do
            local o = 0x09 + 4 * i
            if #data >= o + 2 then note_equip(data:byte(o), data:byte(o + 1), data:byte(o + 2)) end
        end
    elseif id == 0x01A and #data >= 0x0E and data:unpack('H', 0x0B) == 7 then   -- 7 = Weaponskill usage
        snapshot_ws(data:unpack('H', 0x0D), data:unpack('I', 0x05))
    end
end))

-------------------------------------------------------------------------------
-- Field discovery
--
-- The exact shape of a parsed action is not asserted anywhere in this addon. Every key seen on the
-- act / target / action tables is remembered so //cbt fields can print them, which is how the row
-- format gets extended from evidence instead of from a guess.
-------------------------------------------------------------------------------
local function note_fields(bucket, t)
    if type(t) ~= 'table' then return end
    for k, v in pairs(t) do
        local key = tostring(k)
        if type(v) ~= 'table' then
            state.fields_seen[bucket][key] = tostring(v)
        else
            state.fields_seen[bucket][key] = '<table>'
        end
    end
end

-------------------------------------------------------------------------------
-- The recorder
-------------------------------------------------------------------------------
local function target_name(id)
    local ok, mob = pcall(windower.ffxi.get_mob_by_id, id)
    if ok and type(mob) == 'table' and mob.name then return mob.name end
    return nil
end

-- 0.4.0: party members and trusts, by mob id. Shape from working code: rolltracker.lua:253 and
-- GearSwap refresh.lua read windower.ffxi.get_party() members as member.mob.id. Cached for 5 s:
-- action packets arrive many times a second and the party changes rarely.
local party_cache = {t = -100, ids = {}}
local function party_ids()
    if os.clock() - party_cache.t < 5 then return party_cache.ids end
    local ids = {}
    local ok, party = pcall(windower.ffxi.get_party)
    if ok and type(party) == 'table' then
        for _, member in pairs(party) do
            if type(member) == 'table' and type(member.mob) == 'table' and member.mob.id then
                ids[member.mob.id] = true
                -- Pets are not party members, but an automaton's or avatar's WS can open a
                -- skillchain. Guarded: pet_index is read defensively, not assumed on every build.
                local pi = member.mob.pet_index
                if pi and pi > 0 then
                    local okp, pet = pcall(windower.ffxi.get_mob_by_index, pi)
                    if okp and type(pet) == 'table' and pet.id then ids[pet.id] = true end
                end
            end
        end
    end
    party_cache.t, party_cache.ids = os.clock(), ids
    return ids
end

-- What party members do TO ENEMIES is recorded too (0.4.0): weapon skills (skillchain openers --
-- closing them was ~37% of one character's WS damage), spells, abilities, pet abilities and dances
-- (debuffs such as Dia, Angon, Frailty landing on the mob, which decide whether PDL is worth
-- anything). Their melee (1) and ranged (2) are left out: most of the volume, none of the answers.
-- Categories as parsed by windower.packets.parse_action: 3 WS, 4 spell, 6 JA, 13 pet, 14 dance/step.
local PARTY_CATEGORIES = {[3] = true, [4] = true, [6] = true, [13] = true, [14] = true}

-- Your pet's id, for the box (its damage is shown as one share). Cached like the party.
local pet_cache = {t = -100, id = nil}
local function pet_id()
    if os.clock() - pet_cache.t < 2 then return pet_cache.id end
    local ok, pet = pcall(windower.ffxi.get_mob_by_target, 'pet')
    pet_cache.t, pet_cache.id = os.clock(), (ok and type(pet) == 'table') and pet.id or nil
    return pet_cache.id
end

-- A mob's HP% now (mob.hpp, as enemybar/AutoWS read it), for the box's mob HP estimate.
local function mob_hpp(id)
    local ok, mob = pcall(windower.ffxi.get_mob_by_id, id)
    if ok and type(mob) == 'table' and type(mob.hpp) == 'number' then return mob.hpp end
    return nil
end

-- The live box: your own and your pet's actions in full; party members', trusts' and their pets'
-- only as damage on enemies (your share, the mob's HP). Held in memory; nothing here is written.
local function feed_live(act)
    if not state.player_id then return end
    local party = party_ids()
    local function enemy(id) return id ~= state.player_id and not party[id] and id ~= pet_id() end
    local pid = pet_id()
    local is_pet = pid ~= nil and act.actor_id == pid
    if act.actor_id ~= state.player_id and not is_pet then
        if party[act.actor_id] then
            live.party_action(state.live, act, os.clock(), enemy, target_name, mob_hpp)
        elseif act.actor_id ~= pid then
            -- 0.9.0: an enemy's action; live.taken ignores it unless it reached you.
            local function in_party(id) return party[id] == true end
            live.taken(state.live, act, os.clock(), state.player_id, in_party, target_name(act.actor_id))
        end
        return
    end
    local tp = nil
    if not is_pet then
        local player = windower.ffxi.get_player()
        tp = player and player.vitals and player.vitals.tp or nil
    end
    live.action(state.live, act, os.clock(), tp, is_pet, enemy, target_name, mob_hpp)
end

-- 1.2.0: Treasure Hunter and fight ids, kept per mob id so a defeat row can carry them. Message 603
-- ("Additional effect: Treasure Hunter effectiveness against ${target} increases to ${number}", the
-- number in the additional-effect param) and 608 (the same as the main message, the number in the
-- action param) -- ids from res/action_messages.lua. TH comes from the whole party's actions, not
-- just yours. A fight id is "<time of the first party hit>.<mob id>"; the pool drop row (pd) of that
-- mob carries the same text. Both tables are dropped when they grow past 300 mobs.
local TH_ADD_MESSAGE, TH_MESSAGE = 603, 608
local th_by_mob, fight_by_mob, tracked = {}, {}, 0

local function track_fights(act)
    if not act.targets then return end
    local party = party_ids()
    local from_us = (state.player_id and act.actor_id == state.player_id) or party[act.actor_id]
    if not from_us then return end
    for _, target in pairs(act.targets) do
        if target.id and not party[target.id] and target.id ~= state.player_id then
            if not fight_by_mob[target.id] then
                if tracked > 300 then th_by_mob, fight_by_mob, tracked = {}, {}, 0 end
                fight_by_mob[target.id] = ('%d.%d'):format(os.time(), target.id)
                tracked = tracked + 1
            end
            for _, action in pairs(target.actions or {}) do
                if action.has_add_effect and action.add_effect_message == TH_ADD_MESSAGE then
                    th_by_mob[target.id] = action.add_effect_param
                elseif action.message == TH_MESSAGE then
                    th_by_mob[target.id] = action.param
                end
            end
        end
    end
end

local function on_action(act)
    if type(act) ~= 'table' then return end
    local okf, errf = pcall(track_fights, act)
    if not okf then log_line('ERROR in track_fights: ' .. tostring(errf)) end
    local ok, err = pcall(feed_live, act)
    if not ok then log_line('ERROR in live: ' .. tostring(err)) end
    if not writing() then return end

    local mine = state.player_id and act.actor_id == state.player_id
    local at_me = false
    if not mine and settings.include_incoming and act.targets then
        for _, target in pairs(act.targets) do
            if target.id == state.player_id then at_me = true break end
        end
    end
    local party = party_ids()
    local from_party = not mine and not at_me and PARTY_CATEGORIES[act.category] and party[act.actor_id]
    if not (mine or at_me or from_party) then return end

    note_fields('act', act)

    -- 0.8.0: an enemy's action that reaches you is filed under a context read right now.
    -- Our own WS result (category 3, param = WS id) belongs to the context taken when it was sent.
    local ctx
    if mine and act.category == 3 then
        local p = state.pending_ws[act.param]
        if p and (os.clock() - p.t) <= WS_WINDOW then
            ctx = p.ctx
            snapshot_ws_result(act.param, p.ctx)
        end
        state.pending_ws[act.param] = nil
    end
    if mine and act.category == 4 then ctx = snapshot_spell_result(act.param) end
    -- 0.8.0: an enemy's action that reaches you is filed under a context read right now.
    if not ctx then
        ctx = at_me and not party[act.actor_id] and snapshot_hit(act.actor_id) or current_ctx()
    end
    local date = today()
    local n = 0
    local actor_name = mine and state.char or target_name(act.actor_id)

    -- 0.3.0: one action packet is one round; every row written from it shares this number.
    state.round_seq = (state.round_seq or 0) + 1
    local round = state.round_seq
    local ms = math.floor(os.clock() * 1000)
    local tp = nil
    if mine then
        local player = windower.ffxi.get_player()
        tp = player and player.vitals and player.vitals.tp or nil
    end

    -- A party member's action is kept only where it landed on an enemy: a Ballad or a Cure on a
    -- player is not a debuff and would bury the ones that are.
    local targets = act.targets or {}
    if from_party then
        local enemies = {}
        for _, target in pairs(targets) do
            if not party[target.id] then enemies[#enemies + 1] = target end
        end
        if #enemies == 0 then return end
        targets = enemies
    end

    for _, target in pairs(targets) do
        note_fields('target', target)
        local name = target_name(target.id)
        for _, action in pairs(target.actions or {}) do
            note_fields('action', action)
            -- The additional effect is the skillchain on a WS: kept in its own columns so its
            -- damage is never added to the weapon skill's.
            local add = action.has_add_effect
            rows.append(state.char, date, rows.encode_action(
                os.time(), ctx, act.category, act.param,
                target.id, name, action.message, action.param,
                act.actor_id, actor_name, action.reaction,
                add and action.add_effect_message or nil, add and action.add_effect_param or nil,
                round, ms, tp))
            n = n + 1
        end
    end

    state.session.actions = state.session.actions + n
end

-- 0.4.0: action messages (0x029) about enemies -- defeats (time to kill) and debuffs wearing off.
-- Ids from res/action_messages.lua: 6 "${actor} defeats ${target}.", 20 "${target} falls to the
-- ground.", 97 "${target} was defeated by ${actor}.", 64 / 204 / 350 / 531 "${target} is no longer
-- ${status}.", 206 "${target}'s ${status} effect wears off.". Layout from fields.lua 0x029: Actor
-- I@04, Target I@08, Param 1 I@0C (the status id on a wear-off), Param 2 I@10, Message H@18.
local ENEMY_MESSAGES = {[6] = true, [20] = true, [97] = true,
                        [64] = true, [204] = true, [206] = true, [350] = true, [531] = true}

local DEFEAT_MESSAGES = {[6] = true, [20] = true, [97] = true}

-- 1.3.0: reward lines tied to the enemy that died with them. The starstone text comes 2-5 s BEFORE the
-- boss's defeat line (2026-10-16 chat logs), so a reward waits up to REWARD_WAIT seconds for the next
-- defeat; one that arrives just after a defeat uses that defeat. Written as an r row (rows.lua).
local REWARD_WAIT = 10
local last_defeat = nil      -- {clock, id, name, fight}
local pending_reward = nil   -- {clock, ms, item}

local function write_reward(item, ms, clock, d)
    if not writing() then return end
    local gap = d and math.floor((clock - d.clock) * 1000) or nil
    rows.append(state.char, today(), rows.encode_reward(os.time(), ms, item,
        d and d.id or nil, d and d.name or nil, d and d.fight or nil, gap))
end

local function note_defeat(id, name, fight)
    last_defeat = {clock = os.clock(), id = id, name = name, fight = fight}
    if pending_reward and os.clock() - pending_reward.clock <= REWARD_WAIT then
        write_reward(pending_reward.item, pending_reward.ms, pending_reward.clock, last_defeat)
        pending_reward = nil
    end
end

local function on_reward_text(clean)
    local ms = math.floor(os.clock() * 1000)
    for name in tostring(settings.reward_items or ''):gmatch('[^,]+') do
        name = name:match('^%s*(.-)%s*$')
        if name ~= '' and clean:find(name, 1, true) and clean:find('^Obtained') then
            if pending_reward then
                write_reward(pending_reward.item, pending_reward.ms, pending_reward.clock, nil)
                pending_reward = nil
            end
            if last_defeat and os.clock() - last_defeat.clock <= REWARD_WAIT then
                write_reward(name, ms, os.clock(), last_defeat)
            else
                pending_reward = {clock = os.clock(), ms = ms, item = name}
            end
            return
        end
    end
end

-- A reward still waiting after REWARD_WAIT seconds is written without an enemy.
local function expire_reward()
    if pending_reward and os.clock() - pending_reward.clock > REWARD_WAIT then
        write_reward(pending_reward.item, pending_reward.ms, pending_reward.clock, nil)
        pending_reward = nil
    end
end

windower.register_event('incoming text', guarded('incoming text', function(original, _, mode)
    if type(original) ~= 'string' or original == '' then return end
    if not original:find('Obtained', 1, true) then return end   -- cheap test before cleaning every line
    local clean = original:gsub('[%z\1-\31\127]', '')
    on_reward_text(clean)
end))

local function on_message(data)
    if #data < 0x1A then return end
    local message = data:unpack('H', 0x19)
    if not ENEMY_MESSAGES[message] then return end
    local target = data:unpack('I', 0x09)
    if DEFEAT_MESSAGES[message] then live.defeated(state.live, target, os.clock()) end
    if not writing() then return end
    if party_ids()[target] or target == state.player_id then return end   -- enemies only
    local actor = data:unpack('I', 0x05)
    local th, fight
    if DEFEAT_MESSAGES[message] then
        th, fight = th_by_mob[target], fight_by_mob[target]
        th_by_mob[target], fight_by_mob[target] = nil, nil
        note_defeat(target, target_name(target), fight)
    end
    rows.append(state.char, today(), rows.encode_msg(os.time(), math.floor(os.clock() * 1000),
        actor, target_name(actor), target, target_name(target), message,
        data:unpack('I', 0x0D), data:unpack('I', 0x11), th, fight))
end

-- 1.1.0: the treasure pool. Incoming 0x0D2 = an item appears in the pool, 0x0D3 = a lot was cast or
-- the item left the pool. Layout from libs/packets/fields.lua (read 2026-10-16): 0x0D2 Dropper I@08,
-- Count I@0C, Item H@10, Dropper Index H@12, Index (pool slot) C@14, Old C@15; 0x0D3 Highest Lotter
-- I@04, Current Lotter I@08, Highest Lot H@0E, Current Lot H@12 (0xFFFF = pass), Index C@14, Drop
-- C@15 (0 none, 1 given to a player, 3 floored), names char[16]@16 and @26. data:unpack offsets are
-- 1-based here, hence +1. Only what the packets say is written; whether Drop 3 is an expiry is shown
-- by the age column, not asserted.
state.pool = state.pool or {}   -- slot -> {clock, item}

local function pool_name(data, at)
    local ok, s = pcall(function() return data:sub(at, at + 15) end)
    if not ok or type(s) ~= 'string' then return nil end
    s = s:gsub('%z.*$', '')
    return s ~= '' and s or nil
end

local function on_pool_drop(data)
    if #data < 0x16 then return end
    -- Count is the first dword after the header (byte 4); the dword at byte 12 is not a count. Checked on
    -- the 2026-10-17 Sortie captures: a crest drop reads count 1 here and 0 at the old offset.
    local dropper, count = data:unpack('I', 0x09), data:unpack('I', 0x05)
    local item, slot, old = data:unpack('H', 0x11), data:unpack('C', 0x15), data:unpack('C', 0x16)
    -- The client sends the whole pool as item-0 packets on zone-in (543 of 560 pd rows on 2026-10-17):
    -- an empty slot is no drop, so nothing is remembered or written for it.
    if item == 0 then return end
    state.pool[slot] = {clock = os.clock(), item = item}
    if not writing() then return end
    rows.append(state.char, today(), rows.encode_pool_drop(os.time(), math.floor(os.clock() * 1000),
        slot, item, count, dropper, target_name(dropper), old, fight_by_mob[dropper]))
end

local function on_pool_lot(data)
    if #data < 0x26 then return end
    local top_id, lotter_id = data:unpack('I', 0x05), data:unpack('I', 0x09)
    local top_lot, lot = data:unpack('H', 0x0F), data:unpack('H', 0x13)
    local slot, result = data:unpack('C', 0x15), data:unpack('C', 0x16)
    local top_name, lotter_name = pool_name(data, 0x17), pool_name(data, 0x27)
    local ms = math.floor(os.clock() * 1000)
    local entry = state.pool[slot]
    if result == 0 then
        if not writing() then return end
        rows.append(state.char, today(), rows.encode_pool_lot(os.time(), ms, slot, lotter_id,
            lotter_name, lot, top_id, top_name, top_lot))
        return
    end
    state.pool[slot] = nil
    if not writing() then return end
    rows.append(state.char, today(), rows.encode_pool_end(os.time(), ms, slot,
        entry and entry.item or nil, entry and math.floor(os.clock() - entry.clock) or nil,
        result, result == 1 and top_id or nil, result == 1 and top_name or nil,
        result == 1 and top_lot or nil))
end

windower.register_event('incoming chunk', guarded('incoming chunk', function(id, data)
    if id == 0x028 then
        local ok, act = pcall(windower.packets.parse_action, data)
        if ok and act then on_action(act) end
    elseif id == 0x029 then
        on_message(data)
    elseif id == 0x0D2 then
        on_pool_drop(data)
    elseif id == 0x0D3 then
        on_pool_lot(data)
    end
end))

-------------------------------------------------------------------------------
-- Box: a counter, plus one warning -- an expected buff missing while you fight.
-------------------------------------------------------------------------------
-- Expected buffs (0.4.1). Asked for 2026-09-18 when the data showed one character had no Signet in
-- 3,711 context rows while another had it. Names resolve through res/buffs.lua, and a name maps to
-- EVERY id that carries it (several do: "Attack Boost", "Haste" ...) -- present if any id is up.
-- Checked only while Engaged (res/statuses.lua: 1), so it does not nag in town.
local buff_ids_by_name = nil

local function ids_for(name)
    if not buff_ids_by_name then
        buff_ids_by_name = {}
        for id, buff in pairs(res.buffs) do
            local key = buff.en and buff.en:lower()
            if key then
                buff_ids_by_name[key] = buff_ids_by_name[key] or {}
                buff_ids_by_name[key][#buff_ids_by_name[key] + 1] = id
            end
        end
    end
    return buff_ids_by_name[name:lower()]
end

local function expected_list()
    local list = {}
    for name in tostring(settings.expect_buffs or ''):gmatch('[^,]+') do
        name = name:match('^%s*(.-)%s*$')
        if name ~= '' then list[#list + 1] = name end
    end
    return list
end

-- Region buffs (0.4.3). User, 2026-09-18: Signet, Sanction, Sigil and Ionis "all compete and
-- overwrite each other, they are zone dependent buffs, they have no effect outside their home
-- zones" -- and "I can wear a buff in any zone, but I only receive benefit from it in the home zone".
-- So seeing a buff IN a zone proves nothing about the zone (0.4.2 learned pairings that way and was
-- wrong), and gaining one proves little (Signet comes from a guard in town, not where you fight).
-- Which zone belongs to which is not in Windower's resources or in ffxi-atlas, and is not typed in
-- from memory. So:
--   * an undeclared zone warns only when NONE of the four is up (forgot it entirely);
--   * //cbt region <Signet|Sanction|Sigil|Ionis|none> declares the CURRENT zone's home buff, from the
--     player -- the one authority available -- shared by both characters in
--     data/shared/region_zones.txt; there it warns when the right one is missing, and names a wrong
--     one being worn ("have Signet, no effect here" -- the opportunity cost);
--   * 'none' marks a zone where none apply, so it stays quiet.
-- Every context row records zone and buffs, so the combat numbers can still show the difference.
local REGION_BUFFS = {[253] = 'Signet', [256] = 'Sanction', [268] = 'Sigil', [512] = 'Ionis'}
local REGION_FILE = DATA .. 'shared/region_zones.txt'
local region_by_zone = nil   -- zone id -> buff id, or 0 for "none apply here"

local function load_regions()
    region_by_zone = {}
    local f = io.open(REGION_FILE, 'r')
    if not f then return end
    for line in f:lines() do
        local z, b = line:match('^(%d+)\t(%d+)')
        if z then region_by_zone[tonumber(z)] = tonumber(b) end   -- later lines win
    end
    f:close()
end

local function declare_region(zone, buff)
    if not region_by_zone then load_regions() end
    region_by_zone[zone] = buff
    ensure_dir(ensure_dir(DATA) .. 'shared/')
    local f = io.open(REGION_FILE, 'a')
    if f then
        f:write(('%d\t%d\t%s\n'):format(zone, buff, buff == 0 and 'none' or REGION_BUFFS[buff]))
        f:close()
    end
end

local function region_missing(zone, up)
    if not region_by_zone then load_regions() end
    local have = nil
    for id, name in pairs(REGION_BUFFS) do if up[id] then have = name end end
    local want = zone and region_by_zone[zone]
    if want == 0 then return nil end                              -- declared: none apply here
    if want == nil then                                           -- undeclared: only "none at all"
        return (not have) and 'Signet/Sanction/Sigil/Ionis' or nil
    end
    if up[want] then return nil end
    return REGION_BUFFS[want] .. (have and (' (have ' .. have .. ', no effect here)') or '')
end

-- Names missing right now (and names res/buffs.lua does not know, flagged as such).
local function missing_buffs()
    local player = windower.ffxi.get_player()
    if not (player and player.status == 1) then return {} end
    local up = {}
    for _, id in ipairs(player.buffs or {}) do up[id] = true end
    local info = windower.ffxi.get_info()
    local missing = {}
    local region_done = false
    for _, name in ipairs(expected_list()) do
        local lname = name:lower()
        local is_region = lname == 'region' or lname == 'signet' or lname == 'sanction'
                          or lname == 'sigil' or lname == 'ionis'
        if is_region then
            -- Any of the four names means "this zone's one": they overwrite each other, and each
            -- does nothing outside its home zones, so asking for Signet in an Ionis zone is wrong.
            if not region_done then
                region_done = true
                local m = region_missing(info and info.zone, up)
                if m then missing[#missing + 1] = m end
            end
        else
            local ids = ids_for(name)
            if not ids then
                missing[#missing + 1] = name .. '?'
            else
                local present = false
                for _, id in ipairs(ids) do if up[id] then present = true break end end
                if not present then missing[#missing + 1] = name end
            end
        end
    end
    return missing
end

-- Twice a second, not every frame (see garden 0.1.1: unthrottled box text is the suspect for the
-- 2026-09-17 client hangs; every addon of ours that runs fine throttles this).
local last_box = 0

local function colour(r, g, b, text) return ('\\cs(%d,%d,%d)%s\\cr'):format(r, g, b, text) end

local function ws_name(id)
    local ws = res.weapon_skills[id]
    return ws and ws.en or ('WS ' .. tostring(id))
end

-- "Skillchain: Light.${lb}..." (res/action_messages.lua) -> "Light".
local function sc_name(message)
    local m = res.action_messages[message]
    return m and m.en and m.en:match('^Skillchain: ([^%.]+)') or 'skillchain'
end

local function spell_name(id)
    local sp = res.spells[id]
    return sp and sp.en or ('spell ' .. tostring(id))
end

-- What hit you, for the TAKEN line: a spell (category 4) or a monster TP move (11), from res.
local function ability_name(category, id)
    local ok, name = pcall(function()
        if category == 4 then return res.spells[id] and res.spells[id].en end
        if category == 11 then return res.monster_abilities[id] and res.monster_abilities[id].en end
        if category == 1 then return 'melee' end
    end)
    return ok and name or nil
end

-- Buffered rows are written at least every couple of seconds, box or no box (rows.lua, 0.4.4).
local last_tick = 0
windower.register_event('prerender', function()
    if os.clock() - last_tick >= 1 then
        last_tick = os.clock()
        local ok, err = pcall(rows.tick)
        if not ok then log_line('ERROR in rows.tick: ' .. tostring(err)) end
        local okr, errr = pcall(expire_reward)
        if not okr then log_line('ERROR in expire_reward: ' .. tostring(errr)) end
        -- Aftermath uptime, once a second while engaged (res/statuses.lua: 1), box or no box.
        local oka, erra = pcall(function()
            local player = windower.ffxi.get_player()
            if player then live.sample_buffs(state.live, player.buffs, player.status == 1) end
        end)
        if not oka then log_line('ERROR in live buffs: ' .. tostring(erra)) end
    end
    if not settings.show_box then
        if box:visible() then box:hide() end
        return
    end
    if os.clock() - last_box < 0.5 then return end
    last_box = os.clock()
    local okl, lines = pcall(function()
        local t = windower.ffxi.get_mob_by_target('t')
        local opts = {target_id = t and t.id, target_hpp = t and t.hpp,
            ws_name = ws_name, sc_name = sc_name, spell_name = spell_name, ability_name = ability_name,
            c = colour, short = settings.view == 'short'}
        if settings.view == 'diag' then return live.render_diag(state.live, os.clock(), opts) end
        if settings.view == 'taken' then return live.render_taken(state.live, os.clock(), opts) end
        return live.render(state.live, os.clock(), opts)
    end)
    if not okl then log_line('ERROR in live render: ' .. tostring(lines)) lines = {} end
    if #lines == 0 then lines[1] = 'no damage yet - //cbt reset starts the totals again' end
    table.insert(lines, 1, ('CombatLog  %s  %s'):format(state.char or '?', (state.recording and master_on())
        and ('REC %s rows'):format(live.big(state.session.actions)) or colour(255, 200, 80, 'not recording')))
    local ok, missing = pcall(missing_buffs)
    if ok and #missing > 0 then
        lines[#lines + 1] = colour(255, 80, 80, 'missing: ' .. table.concat(missing, ', '))
    end
    box:text(table.concat(lines, NL))
    if not box:visible() then box:show() end
end)

-------------------------------------------------------------------------------
-- Commands
-------------------------------------------------------------------------------
local function show(lines)
    for _, l in ipairs(lines) do windower.add_to_chat(207, l) end
end

local function cmd_summary(date)
    if not state.char then msg('not logged in') return end
    date = date or today()
    local list = rows.read_day(state.char, date)
    if #list == 0 then msg('no rows for ' .. date) return end

    -- Your own actions only. Rows written before 0.2.0 do not say who acted and are left out.
    local s = rows.summarize(list, state.player_id)
    local lines = {('CombatLog %s  %d rows, your actions only'):format(date, #list)}
    if s.unattributed > 0 then
        lines[#lines + 1] = ('  %d older rows skipped: written before 0.2.0, they do not say who acted'):format(s.unattributed)
    end
    if s.swings > 0 then
        local lo, hi = rows.hit_rate_ci(s.hits, s.swings)
        lines[#lines + 1] = ('  hits %d  misses %d  hit rate %.1f%% (95%% CI %.1f-%.1f, n=%d)'):format(
            s.hits, s.misses, s.hit_rate * 100, lo * 100, hi * 100, s.swings)
    end
    -- 0.3.0 rounds: the numbers multi-attack, Haste and Store TP move
    local rd = rows.rounds(list, state.player_id)
    if rd.rounds > 0 then
        local b = rd.by_swings
        lines[#lines + 1] = ('  rounds %d: %.2f swings/round (1:%d 2:%d 3:%d 4+:%d)'):format(
            rd.rounds, rd.swings_per_round or 0, b[1] or 0, b[2] or 0, b[3] or 0, b[4] or 0)
        lines[#lines + 1] = ('  median %s between rounds (n=%d), %s TP per round (n=%d)'):format(
            rd.gap_ms and ('%.2f s'):format(rd.gap_ms / 1000) or '-', rd.gaps,
            rd.tp_per_round and tostring(rd.tp_per_round) or '-', rd.tp_samples)
    end
    lines[#lines + 1] = '  by message id (this is how the crit id gets identified):'
    for i, m in ipairs(s.by_message) do
        if i > 12 then break end
        lines[#lines + 1] = ('    %5d %-9s n=%-6d avg %8.1f  min %d  max %d'):format(
            m.message, m.label, m.n, m.avg or 0, m.min or 0, m.max or 0)
    end
    show(lines)
end

local function cmd_fields()
    local lines = {}
    for bucket, seen in pairs(state.fields_seen) do
        local keys = {}
        for k in pairs(seen) do keys[#keys + 1] = k end
        table.sort(keys)
        if #keys > 0 then
            lines[#lines + 1] = ('-- %s: %d keys'):format(bucket, #keys)
            for _, k in ipairs(keys) do
                local line = ('   %-20s e.g. %s'):format(k, seen[k])
                lines[#lines + 1] = line
                log_line('field ' .. bucket .. ' ' .. line)
            end
        end
    end
    if #lines == 0 then lines = {'no action seen yet - hit something first'} end
    show(lines)
end

local function handle(cmd, ...)
    cmd = (cmd or 'help'):lower()
    local a = ({...})[1]

    if cmd == 'version' then
        msg('version ' .. _addon.version)
    elseif cmd == 'on' or cmd == 'off' then
        state.recording = (cmd == 'on')   -- not saved: every load starts recording again
        msg('recording ' .. (state.recording and 'ON' or 'OFF until the next load or //cbt on'))
    elseif cmd == 'status' then
        show({('CombatLog %s  char %s  %s'):format(_addon.version, tostring(state.char),
                (not master_on()) and 'NOT recording: the //rec master switch is off (//rec on)' or state.recording and 'RECORDING' or 'paused'),
              ('  session: %d action rows, %d context rows'):format(state.session.actions, state.session.ctx),
              ('  incoming actions: %s   context every %ss'):format(
                settings.include_incoming and 'recorded' or 'ignored', tostring(settings.context_secs)),
              ('  writing %s'):format(rows.path(state.char or '?', today())),
              ('  schema v%d  contributor %s  test %s'):format(rows.SCHEMA, contributor(),
                state.test and state.test.label or '-')})
    elseif cmd == 'view' then
        local VIEWS = {damage = 'how much damage, and where it comes from',
                       short = 'the DAMAGE and FIGHT headlines only',
                       diag = 'every raw figure, one per line (0.6.0 list)',
                       taken = 'what hits you first (tanking), then the DAMAGE headline'}
        if a and VIEWS[a:lower()] then
            settings.view = a:lower()
            config.save(settings)
        elseif a then
            msg('//cbt view damage | short | diag | taken')
            return
        end
        local v = VIEWS[settings.view] and settings.view or 'damage'
        msg(('view %s: %s'):format(v, VIEWS[v]))
    elseif cmd == 'reset' then
        state.live = live.new()
        msg('box totals reset (the recorded rows are untouched)')
    elseif cmd == 'summary' then
        cmd_summary(a)
    elseif cmd == 'fields' then
        cmd_fields()
    elseif cmd == 'incoming' then
        settings.include_incoming = not settings.include_incoming
        config.save(settings)
        msg('incoming actions ' .. (settings.include_incoming and 'recorded' or 'ignored'))
    elseif cmd == 'region' then
        -- Declare this zone's home region buff (shared by both characters). See "Region buffs".
        local info = windower.ffxi.get_info()
        local zone = info and info.zone
        if not zone then msg('not in a zone') return end
        if not region_by_zone then load_regions() end
        local zname = res.zones[zone] and res.zones[zone].en or ('zone ' .. zone)
        if a then
            local pick = a:lower()
            local buff = nil
            if pick == 'none' then buff = 0 end
            for id, name in pairs(REGION_BUFFS) do if name:lower() == pick then buff = id end end
            if buff == nil then msg('//cbt region Signet | Sanction | Sigil | Ionis | none') return end
            declare_region(zone, buff)
        end
        local cur = region_by_zone[zone]
        msg(('%s: %s'):format(zname, cur == nil and 'not declared (warns only if none of the four is up)'
            or cur == 0 and 'none apply here (no warning)' or (REGION_BUFFS[cur] .. ' expected')))
    elseif cmd == 'expect' then
        -- Saved per character (config.save writes the current character's section).
        local given = table.concat({...}, ' ')
        if given ~= '' then
            settings.expect_buffs = (given:lower() == 'none') and '' or given
            config.save(settings)
        end
        local list = expected_list()
        local unknown = {}
        for _, name in ipairs(list) do if name:lower() ~= 'region' and not ids_for(name) then unknown[#unknown + 1] = name end end
        msg('expected while engaged: ' .. (#list > 0 and table.concat(list, ', ') or 'nothing')
            .. '   (//cbt expect Signet, Ionis  |  //cbt expect none)')
        if #unknown > 0 then msg('not a buff name in res/buffs.lua: ' .. table.concat(unknown, ', ')) end
    elseif cmd == 'test' then
        -- 1.0.0: mark a test, so ffxi-atlas `validate.experiment --a test:<label>` can select it.
        local label = a
        if not label then
            msg(state.test and ('test %s running%s'):format(state.test.label,
                state.test.note and (' (' .. state.test.note .. ')') or '')
                or 'no test running   (//cbt test <label> [note]  |  //cbt test end)')
            return
        end
        if not writing() then msg('not recording - //cbt on first (and //rec on if the master switch is off)') return end
        local function mark(event, t)
            rows.append(state.char, today(), rows.encode_kv('x', os.time(), {test = t.label, event = event, note = t.note}))
        end
        if state.test then
            mark('end', state.test)
            msg('test ' .. state.test.label .. ' ended')
            state.test = nil
        end
        if label:lower() ~= 'end' then
            local rest = {select(2, ...)}
            state.test = {label = (label:gsub('[\t=]', '_')), note = #rest > 0 and table.concat(rest, ' ') or nil}
            state.ctx_key = nil   -- the next action takes a fresh context: the set being tested
            mark('start', state.test)
            msg('test ' .. state.test.label .. ' started - //cbt test end when you stop')
        end
    elseif cmd == 'box' then
        local v = a if v == 'on' or v == 'off' then settings.show_box = (v == 'on') else settings.show_box = not settings.show_box end
        config.save(settings)
        msg('box ' .. (settings.show_box and 'ON' or 'OFF'))
    else
        msg('//cbt status | on | off | test <label> [note] | test end | view <damage|short|diag|taken> | reset | summary [date] | fields | incoming | expect [buffs] | region <buff|none> | box [on|off]')
    end
end

windower.register_event('addon command', guarded('command', handle))

local function start_ctx()
    local player = windower.ffxi.get_player()
    if not player then return end
    if state.char ~= player.name then
        -- A different character: the session counters and the context id sequence belong to the
        -- old one. Rows are per character on disk, so the counters must be too, or the box reports
        -- one character's swings under another's name.
        state.session = {actions = 0, ctx = 0, start = os.time(), ws = 0}
        state.live = live.new()
        state.ctx_id = 0
        log_line('character is now ' .. player.name .. ' - session counters reset')
    end
    state.char, state.player_id = player.name, player.id
    state.ctx_key = nil   -- force a fresh context row after a login or job change
    log_line(('%s %s (id %s)'):format((state.recording and master_on()) and 'recording' or 'NOT recording',
        player.name, tostring(player.id)))
end

windower.register_event('login', function() coroutine.schedule(guarded('login', start_ctx), 5) end)
windower.register_event('job change', guarded('job change', function() state.ctx_key = nil end))
windower.register_event('zone change', guarded('zone change', function()
    state.ctx_key = nil
    rows.flush()
end))
windower.register_event('logout', guarded('logout', function()
    rows.close()   -- write what is held before the name goes
    state.char, state.player_id, state.ctx_key = nil, nil, nil
end))
windower.register_event('unload', function()
    pcall(rows.close)   -- a reload must not lose the rows still in memory
    if box then box:hide() end
end)

windower.register_event('load', guarded('load', function()
    msg('loaded version ' .. _addon.version .. '  (//cbt)  READ-ONLY recorder - '
        .. ((not master_on()) and 'NOT recording: the //rec master switch is off (//rec on)' or state.recording and 'RECORDING' or 'NOT recording (//cbt on)'))
    start_ctx()
    -- Declared region-buff zones, read now rather than mid-fight.
    local okr, err = pcall(load_regions)
    if not okr then log_line('ERROR in load_regions: ' .. tostring(err)) end
end))
