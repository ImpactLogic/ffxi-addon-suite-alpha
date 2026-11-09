--bagcore: pure rendering for the bags box (no Windower needed, so tools/test-bags.lua can run it).
local M = {}

-- Windower bag ids. Mog House bags (safe, storage, locker, safe2) only report while you are there.
M.BAGS = {
    {id = 0,  key = 'inventory', label = 'Inventory'},
    {id = 5,  key = 'satchel',   label = 'Satchel'},
    {id = 6,  key = 'sack',      label = 'Sack'},
    {id = 7,  key = 'case',      label = 'Case'},
    {id = 8,  key = 'wardrobe',  label = 'Wardrobe 1', ward = true},
    {id = 10, key = 'wardrobe2', label = 'Wardrobe 2', ward = true},
    {id = 11, key = 'wardrobe3', label = 'Wardrobe 3', ward = true},
    {id = 12, key = 'wardrobe4', label = 'Wardrobe 4', ward = true},
    {id = 13, key = 'wardrobe5', label = 'Wardrobe 5', ward = true},
    {id = 14, key = 'wardrobe6', label = 'Wardrobe 6', ward = true},
    {id = 15, key = 'wardrobe7', label = 'Wardrobe 7', ward = true},
    {id = 16, key = 'wardrobe8', label = 'Wardrobe 8', ward = true},
    {id = 1,  key = 'safe',      label = 'Safe',      mog = true},
    {id = 9,  key = 'safe2',     label = 'Safe 2',    mog = true},
    {id = 2,  key = 'storage',   label = 'Storage',   mog = true},
    {id = 4,  key = 'locker',    label = 'Locker',    mog = true},
}
M.LAYOUTS = {bubbles = true, numbers = true, both = true}
M.PIPS = 10
local GREEN, AMBER, RED, DIM = {90, 210, 110}, {255, 210, 90}, {255, 80, 80}, {110, 110, 110}

local function colour(c, text) return ('\\cs(%d,%d,%d)%s\\cr'):format(c[1], c[2], c[3], text) end

function M.colour_of(frac, opts)
    if frac >= (opts.crit or 0.95) then return RED end
    if frac >= (opts.warn or 0.8) then return AMBER end
    return GREEN
end

-- 10 pips; any used slot shows at least one filled, and only a truly full bag shows all ten.
function M.pips(used, max)
    if max <= 0 then return 0 end
    local n = math.ceil(used / max * M.PIPS)
    if used > 0 and n < 1 then n = 1 end
    if used < max and n >= M.PIPS then n = M.PIPS - 1 end
    return math.max(0, math.min(M.PIPS, n))
end

function M.number(used, max, mode)
    if mode == 'free' then return ('%d free'):format(max - used) end
    return ('%d/%d'):format(used, max)
end

-- infos: {[bag id] = {count =, max =, enabled =}}. opts: layout, numbers ('frac'|'free'), show = {key = true},
-- wardrobes ('sum'|'each'), warn, crit. Returns the lines (first = title), and the inventory free count.
function M.rows(infos, opts)
    local rows, wsum = {}, nil
    for _, b in ipairs(M.BAGS) do
        local i = infos[b.id]
        local shown = opts.show and opts.show[b.key]
        if b.ward and (opts.wardrobes or 'sum') == 'sum' then shown = opts.show and opts.show.wardrobe end
        if shown and i and i.max and i.max > 0 and i.enabled ~= false then
            if b.ward and (opts.wardrobes or 'sum') == 'sum' then
                wsum = wsum or {label = 'Wardrobes', used = 0, max = 0}
                wsum.used, wsum.max = wsum.used + (i.count or 0), wsum.max + i.max
            else
                rows[#rows + 1] = {label = b.label, used = i.count or 0, max = i.max}
            end
        end
    end
    if wsum then
        -- keep wardrobes after the belt-worn bags, before Mog House bags
        local at = #rows + 1
        for k, r in ipairs(rows) do if r.label == 'Safe' or r.label == 'Safe 2' or r.label == 'Storage' or r.label == 'Locker' then at = k break end end
        table.insert(rows, at, wsum)
    end
    return rows
end

function M.render(infos, opts)
    local layout = M.LAYOUTS[opts.layout] and opts.layout or 'both'
    local rows = M.rows(infos, opts)
    local lines = {}
    for _, r in ipairs(rows) do
        local frac = r.used / r.max
        local c = M.colour_of(frac, opts)
        local parts = {('%-10s'):format(r.label)}
        if layout ~= 'numbers' then
            local n = M.pips(r.used, r.max)
            parts[#parts + 1] = '[' .. colour(c, ('#'):rep(n)) .. colour(DIM, ('-'):rep(M.PIPS - n)) .. ']'
        end
        if layout ~= 'bubbles' then parts[#parts + 1] = colour(c, ('%7s'):format(M.number(r.used, r.max, opts.numbers))) end
        lines[#lines + 1] = table.concat(parts, ' ')
    end
    return lines, rows
end

-- True when the inventory just dropped to warn_free or fewer slots (fires once per crossing).
function M.crossed(prev_free, free, warn_free)
    return warn_free and warn_free > 0 and free <= warn_free and (prev_free == nil or prev_free > warn_free)
end

return M
