-- storyguide_gather: GATHER steps (prototype), the pure part (no Windower calls) so tools/test-storyguide-gather.lua runs it offline.
--
-- A gather spec (storyguide_gathers.lua) sits on an existing step, keyed by mission id and step key, so no step is added or moved:
--   {item = 'Orc. Armor Plate', count = 1, hint = 'Orcs in Yughott Grotto', also = {{mob = '...', zone = '...', lo = 14, hi = 18, verified = false}}}
--   {item = 'White coral key', ki = true}                       a key item: done when it is in the key item list
--   {needs = {'p1s2', 'p1s3', 'p1s4'}}                          on the step that hands them in: a "have 2 of 3" counter (display only)
-- Done = the item (count) is in the bag, or the key item is held. Nothing here sends anything or changes the game.
local gather = {}

-- have = {item = function(name) -> count in the bag, ki = function(name) -> bool}
function gather.progress(spec, have)
    if spec.ki then
        local held = have.ki and have.ki(spec.item) and true or false
        return held and 1 or 0, 1, held
    end
    local need = spec.count or 1
    local got = have.item and have.item(spec.item) or 0
    return math.min(got, need), need, got >= need
end

-- Ranked sources: the wiki's own hint first, then the "also drops from" entries whose level band overlaps `level` (when known).
-- An entry marked verified = false says so: only what the cached wiki text states is unmarked.
function gather.sources(spec, level)
    local out = {}
    if spec.hint then out[#out + 1] = spec.hint end
    for _, a in ipairs(spec.also or {}) do
        local fits = not level or not (a.lo and a.hi) or (level >= a.lo and level <= a.hi)
        if fits then
            local band = (a.lo and a.hi) and (' lv' .. a.lo .. '-' .. a.hi) or ''
            out[#out + 1] = a.mob .. (a.zone and (' (' .. a.zone .. ')') or '') .. band .. (a.verified == false and ' (unverified)' or '')
        end
    end
    return out
end

-- Steps of `specs` (key -> spec) that are done right now.
function gather.done_keys(specs, have)
    local keys = {}
    for key, spec in pairs(specs or {}) do
        if spec.item then
            local _, _, done = gather.progress(spec, have)
            if done then keys[#keys + 1] = key end
        end
    end
    table.sort(keys)
    return keys
end

-- "have 2 of 3" for a step that lists the gather steps it needs.
function gather.group_progress(specs, keys, have)
    local got = 0
    for _, key in ipairs(keys) do
        local spec = specs[key]
        if spec and spec.item then
            local _, _, done = gather.progress(spec, have)
            if done then got = got + 1 end
        end
    end
    return got, #keys
end

-- The decorator core.render takes: (key, text) -> text shown. Gather steps get a counter in front, the handing-in step a group counter behind.
function gather.decorator(specs, have, level)
    if not specs then return nil end
    return function(key, text)
        local spec = specs[key]
        if not spec then return text end
        if spec.needs then
            local got, total = gather.group_progress(specs, spec.needs, have)
            return ('%s (have %d of %d)'):format(text, got, total)
        end
        if spec.item then
            local got, need, done = gather.progress(spec, have)
            local tag = spec.ki and (done and '[GATHER: held]' or '[GATHER: key item]') or ('[GATHER ' .. got .. '/' .. need .. ']')
            local extra = gather.sources(spec, level)
            -- the wiki hint is usually already in the step text; only list what the text does not say
            local more = {}
            for i = 2, #extra do more[#more + 1] = extra[i] end
            return tag .. ' ' .. text .. (#more > 0 and (' Also: ' .. table.concat(more, '; ') .. '.') or '')
        end
        return text
    end
end

return gather
