-- storyguide_core: the pure part of storyguide (no Windower calls), so tools/test-storyguide.lua can run it outside the game.
--
-- A "track" is one storyline in order (generated from wiki pages by tools/build-storyguide.py): missions, and quests that ride along (detours), each with
-- parts and steps. Position comes from (1) a player-confirmed anchor tied to the packet value at that time, or (2) an ordinal rule for storylines where the
-- packet value is the zero-based mission position. A changed packet value after an anchor means "moved: confirm again", never a guess.
local core = {}

local TAB, NL = string.char(9), string.char(10)

function core.mission_positions(track)
    -- indices (into track.missions) of real missions, in order; quests are detours and never count as a mission position
    local list = {}
    for i, entry in ipairs(track.missions or {}) do
        if (entry.kind or 'mission') == 'mission' then list[#list + 1] = i end
    end
    return list
end

function core.find(track, text)
    local wanted = tostring(text or ''):lower()
    for i, entry in ipairs(track.missions or {}) do
        if entry.id:lower() == wanted or entry.name:lower() == wanted then return i end
    end
    for i, entry in ipairs(track.missions or {}) do
        if entry.name:lower():find(wanted, 1, true) or entry.id:lower():find(wanted, 1, true) then return i end
    end
end

-- Match a track's missions to a generated id table (tools/build-storyguide-ids.py): each mission gets m.gid (the game's id) and m.key (the bit index),
-- by name. Articles and punctuation are ignored because the wiki and the game word a few titles differently ("Affairs of State").
function core.norm(name)
    local n = tostring(name or ''):gsub('\226\128\153', "'"):lower():gsub('^_+', ''):gsub('[^%w]+', ' ')
    n = (' ' .. n .. ' '):gsub(' the ', ' '):gsub(' an? ', ' ')
    return (n:gsub('^%s+', ''):gsub('%s+$', ''))
end

-- Apply the corrections of storyguide_fixes.lua to a loaded track (move a step before another, and/or replace its text). Idempotent. Returns how many changes it made.
function core.apply_fixes(track, fixes)
    local moved = 0
    for _, mission in ipairs(track.missions or {}) do
        for _, fix in ipairs(fixes[mission.id] or {}) do
            for _, part in ipairs(mission.parts or {}) do
                if part.heading and part.heading:lower():find(fix.part:lower(), 1, true) == 1 then
                    local from, to
                    for i, st in ipairs(part.steps or {}) do
                        if not from and st.text:find(fix.step, 1, true) == 1 then from = i end
                        if not to and fix.before and st.text:find(fix.before, 1, true) == 1 then to = i end
                    end
                    if from and fix.text and part.steps[from].text ~= fix.text then
                        part.steps[from].text = fix.text
                        moved = moved + 1
                    end
                    if from and fix.before and to and from > to then
                        table.insert(part.steps, to, table.remove(part.steps, from))
                        moved = moved + 1
                    end
                end
            end
        end
    end
    return moved
end

-- Lay the curated overlay (curated/<track>.lua, built by tools/build-curated.py from the cleanup drafts) over a loaded track: a mission listed there takes the
-- curated parts (steps keyed c1, c2, ...) and any start/reward/after/requirements it gives. Idempotent. Returns how many missions it replaced.
function core.apply_curated(track, curated)
    local replaced = 0
    for _, mission in ipairs(track.missions or {}) do
        local c = curated[mission.id]
        if c and c.parts and not mission.curated then
            mission.parts = c.parts
            mission.curated = true
            for _, field in ipairs({'start', 'reward', 'after', 'requirements', 'migrate'}) do
                if c[field] ~= nil then mission[field] = c[field] end
            end
            replaced = replaced + 1
        end
    end
    return replaced
end

-- A curated mission may carry migrate = {oldkey = 'newkey'}: a tick stored under an old wiki step key moves to its curated key (only if the new key is not set).
function core.migrate_keys(set, mission)
    if not (mission.migrate and set[mission.id]) then return 0 end
    local moved = 0
    for old, new in pairs(mission.migrate) do
        if set[mission.id][old] and not set[mission.id][new] then
            set[mission.id][new] = set[mission.id][old]
            set[mission.id][old] = nil
            moved = moved + 1
        end
    end
    return moved
end

function core.attach_ids(track, ids, skipped)
    local by_name, last = {}, nil
    for _, e in ipairs(ids.entries or {}) do
        by_name[core.norm(e.name)] = e
        if e.id and (not last or e.id > last) then last = e.id end
    end
    local matched = 0
    for _, m in ipairs(track.missions or {}) do
        local e = by_name[core.norm(m.name)]
        if e then m.gid, m.key = e.id, e.key; matched = matched + 1 end
    end
    track.map = {mode = ids.mode, page = ids.page, offset = ids.offset, last_id = last, skipped = skipped or {}}
    return matched
end

-- cstate = {value = packet value or nil, completed = function(key) -> bool or nil, anchor = {node = id, value = n} or nil, rule = 'ordinal' or nil}
-- returns index, source ('data' | 'anchor' | 'rule' | 'moved' | nil), note
-- 'data' needs an id table (track.map): 'value' storylines match the game's current-mission number to a mission id; 'bits' storylines take the first
-- mission whose completed bit is clear (missions observed to be skippable are passed over).
function core.position(track, cstate)
    cstate = cstate or {}
    local map = track.map
    if map and map.mode == 'value' and cstate.value ~= nil and cstate.value >= 0 and cstate.value < 10000 then
        if map.last_id and cstate.value > map.last_id then return nil, 'data', 'the game says this storyline is finished' end
        local at
        for i, m in ipairs(track.missions or {}) do
            if m.gid and m.gid <= cstate.value then at = i end
        end
        if at then return at, 'data', 'read from the game' end
    elseif map and map.mode == 'bits' and cstate.completed then
        local known = false
        for i, m in ipairs(track.missions or {}) do
            if m.key ~= nil then
                local done = cstate.completed(m.key)
                if done ~= nil then known = true end
                if done == false and not map.skipped[m.key] then return i, 'data', 'first mission not completed in the game' end
            end
        end
        if known then return nil, 'data', 'every required mission is completed in the game' end
    end
    local anchor = cstate.anchor
    if anchor and anchor.node then
        if cstate.value ~= nil and anchor.value ~= nil and cstate.value ~= anchor.value then
            return nil, 'moved', 'the game value changed since you last confirmed the mission; tell me the current one with //sg at <mission>'
        end
        local index = core.find(track, anchor.node)
        if index then return index, 'anchor', 'confirmed by you' end
    end
    if cstate.rule == 'ordinal' and cstate.value ~= nil then
        local missions = core.mission_positions(track)
        local index = missions[cstate.value + 1]
        if index then return index, 'rule', 'inferred: the game value is the mission position minus one' end
    end
    return nil, nil, 'position unknown: confirm the current mission with //sg at <mission>'
end

function core.wrap(text, width)
    local lines, current = {}, ''
    for word in tostring(text or ''):gmatch('%S+') do
        if current == '' then current = word
        elseif #current + 1 + #word <= width then current = current .. ' ' .. word
        else lines[#lines + 1] = current; current = word end
    end
    if current ~= '' then lines[#lines + 1] = current end
    return lines
end

-- Lines that tell the player how the mission is laid out but cannot be done ("there are 2 distinct paths ... either order"): shown as notes, not steps.
function core.is_note(text)
    local t = tostring(text or ''):lower()
    return (t:find('distinct paths', 1, true) or t:find('either order', 1, true) or t:find('any order', 1, true)) and true or false
end

-- Inferred triggers: guess from a step's wording what the game does when it is done. "Zone into X" -> zoning into X; "speak with / talk to / examine NPC" ->
-- a cutscene/menu event from that NPC. A guess only; the player's //sg undo overrides it. Returns {kind = 'zone', zone = n} or {kind = 'event', npc = n} or nil.
local CONNECT = {of = true, the = true, de = true, du = true, la = true, le = true, von = true}
core.zones = nil   -- optional list of zone names (set by the add-on from the game's own resources); lets travel wording ("Head to X") be guessed too

-- The longest known zone name in a piece of text (whole words only), or nil.
function core.find_zone(text)
    local best
    for _, name in ipairs(core.zones or {}) do
        if #name >= 5 and (not best or #name > #best) then
            local a, b = text:find(name, 1, true)
            if a and not text:sub(a - 1, a - 1):match('%a') and not text:sub(b + 1, b + 1):match('%a') then best = name end
        end
    end
    return best
end

function core.infer(text)
    local t = tostring(text or ''):gsub('%[%[', ''):gsub('%]%]', '')
    local zone = t:match('[Zz]one into ([%u][^%.,;:%(]*)')
    if zone then
        zone = zone:gsub(' for .*$', ''):gsub(' and .*$', ''):gsub(' to .*$', ''):gsub(' then .*$', ''):gsub('%s+$', '')
        if zone ~= '' then return {kind = 'zone', zone = zone} end
    end
    local rest
    for _, verb in ipairs({'[Ss]peak with ', '[Ss]peak to ', '[Tt]alk to ', '[Tt]alk with ', '[Ee]xamine '}) do
        rest = rest or t:match(verb .. '(.*)$')
    end
    if not rest then
        -- Travel wording with a known zone name: "Head to ... Zeruhn Mines", "Travel to", "Enter", "Journey to" -> zoning into that zone.
        local verb = t:match('^%s*(%a+)') or ''
        local travel = {Head = true, Go = true, Travel = true, Journey = true, Enter = true, Return = true, Proceed = true, Make = true}
        if travel[verb] then
            local zone = core.find_zone(t)
            if zone then return {kind = 'zone', zone = zone} end
        end
        return nil
    end
    local words = {}
    for word in rest:gmatch('%S+') do
        local bare = word:gsub('[,%.;:%)%(]+$', '')
        if bare:match('^%u') or (#words > 0 and CONNECT[bare]) then
            words[#words + 1] = bare
            if bare ~= word then break end   -- punctuation ends the name
        else break end
    end
    while #words > 0 and CONNECT[words[#words]] do words[#words] = nil end
    if #words == 0 then return nil end
    local name = table.concat(words, ' ')
    if name == 'Him' or name == 'Her' or name == 'The' then return nil end
    return {kind = 'event', npc = name}
end

-- "Go to: Makarim, Zeruhn Mines (H-11)" from a step's wording: the NPC it names, the zone it is in (needs core.zones) and the map square. nil when nothing useful.
function core.goto_hint(text)
    local t = tostring(text or ''):gsub('%[%[', ''):gsub('%]%]', '')
    local guess = core.infer(t)
    local npc = guess and guess.kind == 'event' and guess.npc or nil
    local zone = core.find_zone(t) or (guess and guess.kind == 'zone' and guess.zone) or nil
    local grid = t:match('%((%u%-%d+)%)')
    if not (npc or zone) then return nil end
    local parts = {}
    if npc then parts[#parts + 1] = npc end
    if zone then parts[#parts + 1] = zone end
    return table.concat(parts, ', ') .. (grid and (' (' .. grid .. ')') or '')
end

-- Steps whose wording warns about something (missable, "make sure", "do not", "you must"): shown with a (!) so a new player reads them twice.
function core.missable(text)
    local t = tostring(text or ''):lower()
    for _, w in ipairs({'missable', 'be sure', 'make sure', 'do not', "don't", 'cannot', "can't", 'warning', 'you must', 'you will not', 'you will need to'}) do
        if t:find(w, 1, true) then return true end
    end
    return false
end

function core.same(a, b) return core.norm(a) == core.norm(b) end

-- Guess which step an event finishes: only the first `spec.window` (default 3) open, non-optional steps of a path, counted from the first open one (the NOW step).
-- Far-off steps (a later Act naming the same NPC) never match, and a stale tick far ahead cannot hide the steps in front of you. The NPC you just finished with
-- (the last ticked step before the first open one) does not move the guess forward when you speak to them again.
-- `ticked` holds every key not open for guessing (done, auto, guessed, undone); `vetoed` (optional) the undone ones, which are skipped and never count as progress.
-- Returns the step key, or nil. A mission with an odd layout can set `window` in storyguide_branches.lua.
function core.match_inferred(entry, ev, ticked, spec, vetoed)
    vetoed = vetoed or {}
    local function fits(item)
        local c = core.infer(item.text)
        return c and c.kind == ev.kind and ((c.kind == 'zone' and core.same(c.zone, ev.zone)) or (c.kind == 'event' and ev.npc and core.same(c.npc, ev.npc)))
    end
    local window, groups, order = spec and spec.window or 3, {}, {}
    for _, item in ipairs(core.flatten(entry, spec)) do
        if item.kind == 'step' then
            local b = item.branch or 0
            local g = groups[b]
            if not g then g = {seen = 0, last = nil, open = false}; groups[b] = g; order[#order + 1] = b end
            if ticked[item.key] then
                if not vetoed[item.key] and not g.open then g.last = item end
            elseif not item.optional and g.seen < window then
                g.open = true
                g.seen = g.seen + 1
                if fits(item) then
                    if g.last and fits(g.last) then return nil end   -- speaking to the same NPC again: stay on the step already ticked
                    return item.key
                end
            end
        end
    end
end

-- Flat list of the steps of one mission with stable keys, plus section headings.
-- spec (optional, storyguide_branches.lua): parallel paths of a mission. A part whose heading starts with a path's `from` opens that path; the part whose
-- heading starts with `after` closes it. Items between carry item.branch = the path's number.
-- decorate (optional, storyguide_gather.lua): function(key, text) -> the text to show for a step (a GATHER counter); keys and everything else are untouched.
function core.flatten(entry, spec, decorate)
    local flat = {}
    local branch
    for p, part in ipairs(entry.parts or {}) do
        if spec and part.heading then
            local h = part.heading:lower()
            if spec.after and h:find(spec.after:lower(), 1, true) == 1 then branch = nil end
            for n, path in ipairs(spec.paths) do
                if h:find(path.from:lower(), 1, true) == 1 then branch = n end
            end
        end
        if part.heading then flat[#flat + 1] = {kind = 'heading', text = part.heading, branch = branch} end
        for s, step in ipairs(part.steps or {}) do
            if step.tip or core.is_note(step.text) then   -- a curated tip is information attached to the step above it, never a step of its own
                flat[#flat + 1] = {kind = 'note', text = step.text, depth = step.depth or 0, branch = branch}
            else
            local key = step.key or ('p%ds%d'):format(p, s)
            flat[#flat + 1] = {kind = 'step', key = key, text = decorate and decorate(key, step.text) or step.text, depth = step.depth or 0,
                optional = step.optional, ki = step.ki or {}, branch = branch}
            end
        end
    end
    return flat
end

-- opts: {done = set of keys, have_ki = function(lowercase name) -> bool, width = 60, max_lines = 22, page = 0 (0-based; see the returned page count), check = '[x]', open = '[ ]'}
function core.confirmed_state(state)
    return state == 'done' or state == 'auto' or state == 'ev' or state == 'implied'
end

-- The details breakout (its own box): where the mission starts, level, the goal in full and the requirement sentences worth showing.
function core.details_lines(track, entry, opts)
    opts = opts or {}
    local width = opts.width or 62
    local lines = {opts.title or 'Mission details', ('%s: %s'):format(track.storyline, entry.name)}
    local start = entry.start and entry.start:lower()
    if entry.start and not (start:find('^varies') or start:find('see below', 1, true)) then for _, l in ipairs(core.wrap((entry.start_from == 'steps' and 'Start (from steps): ' or 'Start: ') .. entry.start, width)) do lines[#lines + 1] = l end end
    if entry.level then lines[#lines + 1] = 'Level: ' .. entry.level end
    if entry.goal then for _, l in ipairs(core.wrap('Goal: ' .. entry.goal, width)) do lines[#lines + 1] = l end end
    if entry.after then for _, l in ipairs(core.wrap('After: ' .. entry.after, width)) do lines[#lines + 1] = l end end
    local shown = 0
    for _, req in ipairs(entry.requirements or {}) do
        local lowered = req:lower()
        if shown < 4 and not lowered:find('unrelated', 1, true) and not lowered:find('does not need', 1, true) and not lowered:find('part 1 of a quest chain', 1, true) then
            shown = shown + 1
            for _, l in ipairs(core.wrap('! ' .. req, width)) do lines[#lines + 1] = l end
        end
    end
    if entry.reward then for _, l in ipairs(core.wrap('Reward: ' .. entry.reward, width)) do lines[#lines + 1] = l end end
    if opts.reward then for _, l in ipairs(core.wrap('Worth: ' .. opts.reward, width)) do lines[#lines + 1] = l end end
    if #lines == 2 then lines[3] = 'No details recorded for this mission.' end
    return lines
end

function core.render(track, index, source, note, opts)
    opts = opts or {}
    local width, max_lines = opts.width or 60, opts.max_lines or 22
    local lines, rows = {}, {}   -- rows[line number] = step key on that line, for click hit-testing
    if not index then
        lines[1] = opts.title or 'Story Guide'
        lines[2] = track.storyline
        for _, l in ipairs(core.wrap(note or 'position unknown', width)) do lines[#lines + 1] = l end
        if opts.hint ~= false then for _, l in ipairs(core.wrap('Open the Missions menu once so Story Guide can read your progress, or //sg at <mission> to say where you are.', width)) do lines[#lines + 1] = l end end
        return lines, 0, {}, 1, 1, nil, rows
    end
    local entry = track.missions[index]
    local label = (entry.kind == 'quest') and 'Quest' or 'Mission'
    lines[#lines + 1] = opts.title or 'Story Guide'   -- first line = the box title, as in every themed box here
    lines[#lines + 1] = ('%s: %s'):format(track.storyline, entry.name)
    if track.map and entry.key ~= nil and track.map.skipped[entry.key] then label = label .. ' (optional)' end
    lines[#lines + 1] = ('%s %d of %d  [%s]'):format(label, index, #track.missions, source == 'data' and 'from game' or source == 'anchor' and 'confirmed' or source == 'rule' and 'inferred' or source == 'preview' and 'browsing; //sg here' or '?')
    local details = opts.details ~= false   -- Start/Level/Goal/requirements: collapsed in the game by default (//sg details), the NOW line below is always shown
    local vague_start = entry.start and (entry.start:lower():find('^varies') or entry.start:lower():find('see below', 1, true))
    if not details then
        lines[#lines + 1] = (opts.dim and opts.dim or '') .. (opts.details_open and 'Details: open (click to close)' or 'Details: click to open (goal, level, requirements)') .. (opts.dim and opts.reset or '')
        rows[#lines] = '@details'
    else
    if entry.start and not vague_start then for _, l in ipairs(core.wrap((entry.start_from == 'steps' and 'Start (from steps): ' or 'Start: ') .. entry.start, width)) do lines[#lines + 1] = l end end
    if entry.level then lines[#lines + 1] = 'Level: ' .. entry.level end
    if entry.goal then
        local wrapped = core.wrap('Goal: ' .. entry.goal, width)
        for w = 1, math.min(3, #wrapped) do lines[#lines + 1] = wrapped[w] .. ((w == 3 and #wrapped > 3) and ' ...' or '') end
    end
    -- Requirement sentences from the wiki are noisy: drop the "unrelated / not needed" ones, show at most two, two lines each.
    local shown_reqs = 0
    for _, req in ipairs(entry.requirements or {}) do
        local lowered = req:lower()
        if shown_reqs < 2 and not lowered:find('unrelated', 1, true) and not lowered:find('does not need', 1, true) and not lowered:find('part 1 of a quest chain', 1, true) then
            shown_reqs = shown_reqs + 1
            local wrapped = core.wrap('! ' .. req, width)
            for w = 1, math.min(2, #wrapped) do lines[#lines + 1] = wrapped[w] .. ((w == 2 and #wrapped > 2) and ' ...' or '') end
        end
    end
    end
    lines[#lines + 1] = ''
    local flat = core.flatten(entry, opts.branches, opts.decorate)
    if #flat == 0 then   -- a skeleton mission: it is on the list and your position works, but no step text exists for it yet
        for _, l in ipairs(core.wrap('No step text for this ' .. label:lower() .. ' yet. Your place in the storyline is still tracked.', width)) do lines[#lines + 1] = l end
    end
    local done, have_ki = opts.done or {}, opts.have_ki
    local first_open
    local states = {}
    for i, item in ipairs(flat) do
        if item.kind == 'step' then
            local auto = false
            if have_ki then for _, name in ipairs(item.ki) do if have_ki(name:lower()) then auto = true end end end
            states[i] = done[item.key] and 'done' or (auto and 'auto') or (opts.evidence and opts.evidence[item.key] and 'ev') or (opts.inferred and opts.inferred[item.key] and 'inf') or 'open'
        end
    end
    -- Implied steps: a confirmed later step (done by hand or by evidence) proves the earlier ones happened (you cannot be in Carpenters' Landing without having
    -- travelled there). Earlier steps of the same path (or outside any path) become 'implied': done, shown as such, never over a step you undid yourself.
    local vetoed = opts.vetoed or {}
    for j, later in ipairs(flat) do
        if later.kind == 'step' and (states[j] == 'done' or states[j] == 'ev') then
            for i = 1, j - 1 do
                local item = flat[i]
                if item.kind == 'step' and (states[i] == 'open' or states[i] == 'inf') and not vetoed[item.key]
                    and (item.branch == nil or later.branch == nil or item.branch == later.branch) then states[i] = 'implied' end
            end
        end
    end
    -- Dev mode (//sg infer on): a wording guess is weaker evidence, so the steps it implies are 'implied_guess': shown done but flagged (implied?), skipped by the NOW line,
    -- never counted toward path progress. Guesses never imply over a veto, and never over a step already confirmed.
    for j, later in ipairs(flat) do
        if later.kind == 'step' and states[j] == 'inf' then
            for i = 1, j - 1 do
                local item = flat[i]
                if item.kind == 'step' and (states[i] == 'open' or states[i] == 'inf') and not vetoed[item.key]
                    and (item.branch == nil or later.branch == nil or item.branch == later.branch) then states[i] = 'implied_guess' end
            end
        end
    end
    -- Parallel paths: one summary line each (done/total required steps); only the focused path is expanded (the first path with work left, or the one you chose).
    local focus
    if opts.branches then
        local total, finished = {}, {}
        for i, item in ipairs(flat) do
            if item.kind == 'step' and item.branch and not item.optional then
                total[item.branch] = (total[item.branch] or 0) + 1
                if core.confirmed_state(states[i]) then finished[item.branch] = (finished[item.branch] or 0) + 1 end
            end
        end
        local paths = opts.branches.paths
        focus = opts.focus
        if not focus then
            for n = 1, #paths do if (finished[n] or 0) < (total[n] or 0) then focus = n; break end end
        end
        lines[#lines + 1] = ''
        lines[#lines + 1] = 'Paths (' .. (opts.branches.any_order and 'any order' or 'in turn') .. ', all required; //sg path <n>):'
        for n, path in ipairs(paths) do
            local f, t = finished[n] or 0, total[n] or 0
            local row = ('%s %d. %s  %d/%d%s'):format(n == focus and '>' or ' ', n, path.name, f, t, f >= t and t > 0 and '  done' or '')
            lines[#lines + 1] = (n == focus and opts.now) and (opts.now .. row .. opts.reset) or (f >= t and opts.dim) and (opts.dim .. row .. opts.reset) or row
        end
        local kept, kept_states = {}, {}
        for i, item in ipairs(flat) do
            if not item.branch or item.branch == focus then kept[#kept + 1] = item; kept_states[#kept] = states[i] end
        end
        flat, states = kept, kept_states
    end
    -- NOW skips a guessed step too (the guess says it probably happened), but a guess alone never ends the mission: if only guesses are left, NOW falls back to the first.
    local first_guess
    for i, item in ipairs(flat) do
        if item.kind == 'step' and not core.confirmed_state(states[i]) and states[i] ~= 'implied_guess' and not item.optional then
            if states[i] == 'inf' then first_guess = first_guess or i elseif not first_open then first_open = i end
        end
    end
    local view_from = first_guess and (not first_open or first_guess < first_open) and first_guess or first_open   -- the page starts at a guess so the tick stays visible
    first_open = first_open or first_guess
    -- NOW: the first open step of the focused path, pinned under the mission line so it is on screen whatever the page or scroll shows.
    do
        local now_lines
        if first_open then
            local full = core.wrap('> NOW: ' .. (core.missable(flat[first_open].text) and '(!) ' or '') .. flat[first_open].text, width)
            now_lines = {full[1], full[2]}
            if #full > 2 then now_lines[2] = now_lines[2] .. ' ...' end
        else
            local following = track.missions[index + 1]
            now_lines = core.wrap('> Mission done!' .. (entry.wait_after and (' First ' .. entry.wait_after .. '.') or '') .. (following and (' Then: ' .. following.name .. (following.start and (' (' .. following.start .. ')') or '')) or ''), width)
        end
        local hint = first_open and core.goto_hint(flat[first_open].text)
        if hint then now_lines[#now_lines + 1] = 'Go to: ' .. hint end
        for n, l in ipairs(now_lines) do
            table.insert(lines, 3 + n, opts.now and (opts.now .. l .. opts.reset) or l)
            if first_open then rows[3 + n] = flat[first_open].key end   -- clicking the NOW line ticks that step
        end
        if opts.compact then   -- compact mode: title, the NOW line(s) and a way back, nothing else
            local out, crow, by_key = {lines[1]}, {}, {}
            for n = 1, #now_lines do out[#out + 1] = lines[3 + n]; crow[#out] = rows[3 + n] end
            out[#out + 1] = (opts.dim or '') .. '+ click here to expand' .. (opts.dim and opts.reset or '')
            crow[#out] = '@expand'
            for i, item in ipairs(flat) do if item.kind == 'step' then by_key[item.key] = states[i] end end
            return out, 0, {}, 1, 1, nil, crow, by_key
        end
    end
    local budget = max_lines - #lines - 3   -- room for the page marker lines and the Then line
    local width_of = function(item) return item.kind == 'heading' and 1 or item.kind == 'note' and #core.wrap(item.text, width - 2) or #core.wrap((item.optional and '(opt) ' or '') .. item.text, width - 6 - item.depth * 2) end
    -- Pages: page 0 starts at the first open step; each further page starts where the previous one ran out of room.
    local from = 1
    if view_from or first_open then
        from = view_from or first_open
        while from > 1 and flat[from - 1].kind == 'heading' do from = from - 1 end
    end
    local function page_end(start)   -- index of the first item that does not fit when the page starts at `start` (#flat + 1 = it all fits)
        local used, i = 0, start
        while i <= #flat do
            local cost = width_of(flat[i])
            if used + cost > budget and used > 0 then break end
            used = used + cost; i = i + 1
        end
        return i
    end
    local starts = {from}
    while page_end(starts[#starts]) <= #flat do starts[#starts + 1] = page_end(starts[#starts]) end
    local pages = #starts
    local page = math.min(math.max(opts.page or 0, 0), pages - 1)
    from = starts[page + 1]
    if opts.scroll then   -- mouse wheel: start from any item (scroll is an absolute item index; clamped so the last page stays full)
        from = math.min(math.max(opts.scroll, 1), starts[#starts])
        page = 0
        for i, st in ipairs(starts) do if st <= from then page = i - 1 end end
    end
    local stop = page_end(from) - 1
    local number = 0
    local keys = {}
    for i, item in ipairs(flat) do if item.kind == 'step' and i < from then number = number + 1; keys[number] = item.key end end
    local steps_total, steps_above, steps_below = 0, 0, 0
    for i, item in ipairs(flat) do
        if item.kind == 'step' then
            steps_total = steps_total + 1
            if i < from then steps_above = steps_above + 1 elseif i > stop then steps_below = steps_below + 1 end
        end
    end
    -- Scroll indicator (plain text, no scrollbar widget): "^ n earlier" above, "v n more" below, and a small position bar so it is clear the list scrolls.
    local function scroll_bar()
        local cells, first_cell, last_cell = 10, nil, nil
        local shown_from, shown_to = steps_above, steps_total - steps_below
        first_cell = math.floor(shown_from / math.max(steps_total, 1) * cells)
        last_cell = math.max(first_cell + 1, math.ceil(shown_to / math.max(steps_total, 1) * cells))
        local bar = {}
        for c = 1, cells do bar[c] = (c > first_cell and c <= last_cell) and '#' or '-' end
        return '[' .. table.concat(bar) .. ']'
    end
    if from > 1 and (page > 0 or opts.scroll) then
        local up = ('^ %d earlier step%s: scroll up'):format(steps_above, steps_above == 1 and '' or 's')
        lines[#lines + 1] = opts.dim and (opts.dim .. up .. opts.reset) or up
    end
    for i = from, stop do
        local item = flat[i]
        if item.kind == 'heading' then
            local h = '== ' .. item.text
            lines[#lines + 1] = opts.head and (opts.head .. h .. opts.reset) or h
        elseif item.kind == 'note' then
            for _, l in ipairs(core.wrap(item.text, width - 2)) do
                lines[#lines + 1] = opts.dim and (opts.dim .. '  ' .. l .. opts.reset) or ('  ' .. l)
            end
        else
            number = number + 1
            keys[number] = item.key
            -- Three marks: done [x], the step to do now [>], later [ ]. How a done step was detected is a short tag after the text, not a mark.
            local st = states[i]
            local mark = (core.confirmed_state(st) or st == 'implied_guess') and (opts.check or '[x]') or (i == first_open and '[>]') or (opts.open or '[ ]')
            local how = st == 'implied' and ' (implied)' or st == 'implied_guess' and ' (implied?)' or st == 'auto' and ' (key item)' or st == 'ev' and ' (auto)' or st == 'inf' and ' (guess)' or ''
            local text = (item.optional and '(opt) ' or '') .. (core.missable(item.text) and '(!) ' or '') .. item.text .. how
            local wrapped = core.wrap(text, width - 6 - item.depth * 2)
            local colour = (opts.flash and item.key == opts.flash and opts.flashc) or (i == first_open and opts.now) or (states[i] ~= 'open' and opts.dim) or nil
            for w, l in ipairs(wrapped) do
                local row = (w == 1 and ('%s %d. '):format(mark, number) or '      ') .. string.rep('  ', item.depth) .. l
                if w == 1 and opts.flash and item.key == opts.flash then row = row .. '  <- just ticked' end
                lines[#lines + 1] = colour and (colour .. row .. opts.reset) or row
                rows[#lines] = item.key
            end
        end
    end
    if stop < #flat then
        local down = ('v %d more step%s: scroll down %s'):format(steps_below, steps_below == 1 and '' or 's', scroll_bar())
        lines[#lines + 1] = opts.dim and (opts.dim .. down .. opts.reset) or down
    end
    for i = 1, #flat do
        if flat[i].kind == 'step' then
            local known = false
            for _, k in pairs(keys) do if k == flat[i].key then known = true; break end end
            if not known then number = number + 1; keys[number] = flat[i].key end
        end
    end
    local following = track.missions[index + 1]
    if following and entry.wait_after then lines[#lines + 1] = 'First ' .. entry.wait_after .. '.' end
    if following then lines[#lines + 1] = 'Then: ' .. following.name .. (following.start and (' (' .. following.start .. ')') or '') end
    local by_key, any_step = {}, false
    for i, item in ipairs(flat) do if item.kind == 'step' then by_key[item.key] = states[i]; any_step = true end end
    return lines, number, keys, pages, from, focus, rows, by_key, first_open == nil and any_step, stop
end

-- List view (level 1 of the tracker): every mission and riding-along quest of a track in order, one row each, with its state against the position.
-- State is by position only: missions before the current one are done, the current one is 'now', the rest 'later'. Quests have no completion data yet,
-- so they are always 'unknown' ('?'). No position (index nil): 'finished' (source 'data' and the note says so) marks every mission done, otherwise all unknown.
-- Returns lines, rows (rows[line number] = track index of that line, for click hit-testing; the title is line 1), done, total (missions), first, last (rows shown).
-- opts: {width, max_lines, scroll = first row to show, selected = index to highlight, now, dim, head, reset}
function core.list_states(track, index, source, note)
    local finished = index == nil and source == 'data' and tostring(note or ''):find('finished', 1, true) ~= nil
    local states, done, total = {}, 0, 0
    for i, m in ipairs(track.missions or {}) do
        local is_quest = (m.kind or 'mission') == 'quest'
        if not is_quest then total = total + 1 end
        local st
        if is_quest then st = 'unknown'
        elseif finished then st = 'done'
        elseif not index then st = 'unknown'
        elseif i < index then st = 'done'
        elseif i == index then st = 'now'
        else st = 'later' end
        if st == 'done' and not is_quest then done = done + 1 end
        states[i] = st
    end
    return states, done, total
end

function core.render_list(track, index, source, note, opts)
    opts = opts or {}
    local width, max_lines = opts.width or 60, opts.max_lines or 22
    local next_n = opts.next_n or 3   -- not-started missions shown after the current one; the rest are a count (the full list belongs on the web app)
    local missions = track.missions or {}
    local states, done, total = core.list_states(track, index, source, note)
    local lines, rows = {}, {}
    lines[1] = opts.title or 'Story Guide'
    lines[2] = ('%s  %d/%d missions done%s'):format(track.storyline, done, total, (index == nil and done == 0) and '  (position unknown)' or '')
    -- Visible rows: done, current, the next few not started, and the quests (unknown state) that sit between those. No position at all: everything.
    local lo, hi, later_shown, hidden = nil, nil, 0, 0
    for i = 1, #missions do
        local st = states[i]
        local keep = (st == 'done' or st == 'now') or (st == 'later' and later_shown < next_n)
        if st == 'later' and keep then later_shown = later_shown + 1 end
        if st == 'later' and not keep then hidden = hidden + 1 end
        if keep then lo = lo or i; hi = i end
    end
    local visible = {}
    for i = 1, #missions do
        if not lo then visible[#visible + 1] = i
        elseif i >= lo and i <= hi then visible[#visible + 1] = i end
    end
    local budget = max_lines - 5   -- title, header, footer and the two "more" markers
    local at = 1
    for n, i in ipairs(visible) do if i == index then at = n end end
    local first = opts.scroll
    if not first then first = math.max(1, at - math.floor(budget / 2)) end   -- keep the current mission in view, history above and the next few below
    first = math.min(math.max(first, 1), math.max(#visible - budget + 1, 1))
    local last = math.min(first + budget - 1, #visible)
    if first > 1 then lines[#lines + 1] = opts.dim and (opts.dim .. ('  ... %d earlier (scroll up)'):format(first - 1) .. opts.reset) or ('  ... ' .. (first - 1) .. ' earlier (scroll up)') end
    local marks = {done = '[x]', now = '>>>', later = '[ ]', unknown = '[?]'}
    for n = first, last do
        local i = visible[n]
        local m = missions[i]
        local tag = (m.kind == 'quest') and ' (Q)' or ''
        if track.map and m.key ~= nil and track.map.skipped and track.map.skipped[m.key] then tag = tag .. ' (opt)' end
        local right = m.level and ('  Lv ' .. m.level) or ''
        local name = m.name .. tag
        local room = width - 11 - #right
        if #name > room then name = name:sub(1, math.max(room - 1, 1)) .. '~' end
        local row = ('%s %3d. %s%s'):format(marks[states[i]], i, name, right)
        local colour = (states[i] == 'now' and opts.now) or (states[i] == 'done' and opts.dim) or nil
        if i == opts.selected then row = row .. '  <' end
        lines[#lines + 1] = colour and (colour .. row .. opts.reset) or row
        rows[#lines] = i
    end
    if last < #visible then lines[#lines + 1] = opts.dim and (opts.dim .. ('  ... %d more (scroll down)'):format(#visible - last) .. opts.reset) or ('  ... ' .. (#visible - last) .. ' more (scroll down)') end
    lines[#lines + 1] = (hidden > 0 and (hidden .. ' not started: see the web app. ') or '') .. 'click a row to open it'
    return lines, rows, done, total, first, last, hidden
end

-- anchors.tsv: storyline <TAB> mission id <TAB> packet value at the time (the player's statement, kept per character)
function core.anchors_to_tsv(anchors)
    local rows = {}
    for storyline, a in pairs(anchors) do rows[#rows + 1] = table.concat({storyline, a.node, a.value ~= nil and a.value or ''}, TAB) end
    table.sort(rows)
    return table.concat(rows, NL) .. NL
end

function core.anchors_from_tsv(text)
    local anchors = {}
    for line in tostring(text or ''):gmatch('[^\r\n]+') do
        local storyline, node, value = line:match('^([^\t]*)\t([^\t]*)\t?([^\t]*)$')
        if storyline and node and node ~= '' then anchors[storyline] = {node = node, value = tonumber(value)} end
    end
    return anchors
end

-- done.tsv: mission id <TAB> step key
function core.done_to_tsv(done)
    local rows = {}
    for mission, keys in pairs(done) do for key in pairs(keys) do rows[#rows + 1] = mission .. TAB .. key end end
    table.sort(rows)
    return table.concat(rows, NL) .. NL
end

function core.done_from_tsv(text)
    local done = {}
    for line in tostring(text or ''):gmatch('[^\r\n]+') do
        local mission, key = line:match('^([^\t]*)\t([^\t]*)$')
        if mission then done[mission] = done[mission] or {}; done[mission][key] = true end
    end
    return done
end

return core
