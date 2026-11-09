-- Temprix Aeonic progress: Geas Fete NM kill counts read from the numbers in his menu packet (incoming 0x034).
-- HYPOTHESIS (2026-10-18, from one character's captures 10-16..10-18, not validated in play): the first three
-- menu parameters (zero-based 0x08, 0x0C, 0x10) are kill bitmasks for Escha - Zi'Tah, Escha - Ru'Aun and
-- Reisenjima. Evidence: popcounts equal the NM totals (25 / 31 / 28) for a character who finished the first
-- two zones and had 4 Reisenjima NMs left; one new Reisenjima kill (Zerde) turned on exactly one bit.
-- Which bit is which NM is NOT known except the single labelled guess in core.BIT_LABELS. Two other
-- parameters moved between visits (probably Dynamis steps) and are kept raw, not decoded.
local core = {}
core.HEADER = 'captured\tsession\tcharacter\tzi_tah\tru_aun\treisenjima\tparams_hex'
core.PARAM_BASE = 0x08  -- 0x034 layout: NPC id 0x04, 8 x uint32 menu parameters from 0x08
core.PARAM_COUNT = 8
core.MIN_SIZE = core.PARAM_BASE + core.PARAM_COUNT * 4

-- Candidate bitmask widths inferred from retained packet observations.
core.GROUPS = {
    {key='zitah', label="Escha - Zi'Tah", param=0, total=25},
    {key='ruaun', label="Escha - Ru'Aun", param=1, total=31},
    {key='reisenjima', label='Reisenjima', param=2, total=28},
}
core.BIT_LABELS = {reisenjima = {[22] = {nm = 'Zerde', status = 'hypothesis'}}}

local function u32(data, off)
    local a, b, c, d = data:byte(off + 1, off + 4)
    return a + b * 256 + c * 65536 + d * 16777216
end
local function bit_set(v, n) return math.floor(v / 2 ^ n) % 2 == 1 end

function core.decode(data)
    if type(data) ~= 'string' or #data < core.MIN_SIZE then return nil end
    local params = {}
    for i = 1, core.PARAM_COUNT do params[i] = u32(data, core.PARAM_BASE + (i - 1) * 4) end  -- 1-based
    local out = {params = params, groups = {}}
    for _, g in ipairs(core.GROUPS) do
        local raw, clear, set = params[g.param + 1], {}, 0
        for n = 0, g.total - 1 do
            if bit_set(raw, n) then set = set + 1 else clear[#clear + 1] = n end
        end
        local extra = 0
        for n = g.total, 31 do if bit_set(raw, n) then extra = extra + 1 end end
        out.groups[g.key] = {label = g.label, raw = raw, set = set, total = g.total,
            clear_bits = clear, extra_bits = extra, labels = core.BIT_LABELS[g.key]}
    end
    return out
end

function core.row_line(captured, session, character, data)
    local d = core.decode(data)
    if not d then return nil end
    local hexes = {}
    for i = 1, core.PARAM_COUNT do hexes[#hexes + 1] = ('%08x'):format(d.params[i]) end
    local g = d.groups
    return table.concat({captured, session, character, g.zitah.set, g.ruaun.set, g.reisenjima.set,
        table.concat(hexes, ',')}, '\t')
end
function core.parse_row(line)
    local f = {}
    for v in (line .. '\t'):gmatch('([^\t]*)\t') do f[#f + 1] = v end
    if #f < 7 or f[1] == 'captured' then return nil end
    local params = {}
    for h in f[7]:gmatch('%x+') do params[#params + 1] = tonumber(h, 16) end
    return {captured = f[1], session = f[2], character = f[3], params = params}
end

-- Bit numbers that turned on / off between two 1-based parameter lists; reports zero-based param and bit numbers.
function core.diff(old, new)
    local out = {}
    for i = 0, core.PARAM_COUNT - 1 do
        local a, b = old[i + 1] or 0, new[i + 1] or 0
        if a ~= b then
            local on, off = {}, {}
            for n = 0, 31 do
                local x, y = bit_set(a, n), bit_set(b, n)
                if y and not x then on[#on + 1] = n elseif x and not y then off[#off + 1] = n end
            end
            out[#out + 1] = {param = i, on = on, off = off}
        end
    end
    return out
end

function core.summary_lines(d)
    if not d then return {'Temprix progress: not seen yet (speak to Temprix and open his list)'} end
    local lines = {}
    for _, g in ipairs(core.GROUPS) do
        local x = d.groups[g.key]
        local line = ('%s: %d/%d Geas Fete NMs done'):format(x.label, x.set, x.total)
        if #x.clear_bits > 0 then line = line .. ' (open bits ' .. table.concat(x.clear_bits, ',') .. ')' end
        if x.extra_bits > 0 then line = line .. (' [%d unexpected high bits]'):format(x.extra_bits) end
        lines[#lines + 1] = line
        for _, n in ipairs(x.clear_bits) do
            local l = x.labels and x.labels[n]
            if l then lines[#lines + 1] = ('  bit %d = %s? (%s, still open)'):format(n, l.nm, l.status) end
        end
    end
    lines[#lines + 1] = 'Counts are a hypothesis (menu params 1-3); per-NM bit mapping unvalidated. Dynamis steps not decoded.'
    return lines
end

return core
