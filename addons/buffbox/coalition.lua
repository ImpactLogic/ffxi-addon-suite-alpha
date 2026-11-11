--buffbox coalition: reads what an Adoulin Civil Registrar says about its coalition. Pure.
--
-- The game says which Ionis effects you have only when you ask a coalition's Civil Registrar. The
-- dialogue (ffxilogger, one character, 2026-09-27 10:56-10:59, all six coalitions) runs:
--   ...Is there anything you'd like to know about the Couriers' Coalition?
--   The Couriers' Coalition is currently rank number 8.
--   Based on the expansion of the Couriers' Coalition, Ionis provides...
--   - Moderate Accuracy and Magic Accuracy Enhancement            (four "- " lines, the last ending
--   - Moderate Haste Effect in addition to its normal benefits.     " in addition to its normal benefits.")
--   This coalition is edified as much as possible, and therefore we have no plans to expand.
-- The status line does not name the coalition, so it belongs to the last greeting seen. Wording for a
-- partly edified coalition has not been seen yet; any other line mentioning "edif" is kept verbatim.
-- The edification line is a SEPARATE menu choice: at 11:44-11:52 the same day all six registrars were
-- asked for status only, and none said it (buffbox 0.5.1 waited for it and saved nothing). So a record is
-- returned as soon as the effect list ends (its last line carries " in addition to its normal benefits."),
-- with status nil, and returned again, with status, if the edification line follows.
local M = {}

local function trim(s) return (s:gsub('^%s+', ''):gsub('%s+$', '')) end

function M.new() return {cur = nil, collecting = false, done = {}} end

-- Feed one chat line. Returns the finished record {coalition, rank, effects, status} when a status line
-- closes a coalition, else nil. Records are keyed by coalition name ("Couriers'").
function M.feed(st, line)
    line = trim((line or ''):gsub('^Civil Registrar%s*:%s*', ''))
    local name = line:match("like to know about the (.-) Coalition%?$")
        or line:match('^The (.-) Coalition is currently rank')
        or line:match('^Based on the expansion of the (.-) Coalition')
    if name then
        if not st.cur or st.cur.coalition ~= name then
            -- A list that never showed its closing line is still worth keeping.
            local prev = st.cur
            st.cur, st.collecting = {coalition = name, effects = {}}, false
            if prev and #prev.effects > 0 and not prev.returned then prev.returned = true return prev end
        end
    end
    local cur = st.cur
    if not cur then return nil end
    local rank = line:match('Coalition is currently rank number (%d+)')
    if rank then cur.rank = tonumber(rank) return nil end
    if line:match('Ionis provides') then st.collecting = true cur.effects = {} return nil end
    if st.collecting then
        local eff = line:match('^%-%s*(.+)$')
        if eff then
            local last = eff:find('in addition to its normal benefits', 1, true) ~= nil
            eff = trim(eff:gsub('%s*in addition to its normal benefits%.?%s*$', ''):gsub('%.$', ''))
            cur.effects[#cur.effects + 1] = eff
            if last then st.collecting = false cur.returned = true return cur end
            return nil
        end
        st.collecting = false
    end
    if line:lower():match('edif') then
        cur.status = line:match('edified as much as possible') and 'full' or line
        st.done[cur.coalition] = cur
        st.cur = nil
        return cur
    end
    return nil
end

-- Box text for one coalition: "Couriers: Accuracy/Magic Accuracy, Haste (Moderate)".
function M.short(rec)
    local tiers, parts = {}, {}
    for _, e in ipairs(rec.effects or {}) do
        local tier, rest = e:match('^(%a+) (.+)$')
        if tier == 'Moderate' or tier == 'Minor' then tiers[tier] = true else rest = e end
        rest = rest:gsub(' and ', '/'):gsub(' Enhancement$', ''):gsub(' Increase$', ''):gsub(' Effect$', '')
            :gsub(' Bonus$', ''):gsub('^Enhancement to ', '')
        parts[#parts + 1] = rest
    end
    local tier = (tiers.Moderate and tiers.Minor) and ' (mixed)' or tiers.Moderate and ' (Moderate)'
        or tiers.Minor and ' (Minor)' or ''
    local name = rec.coalition:gsub("'$", '')
    if #parts == 0 then return name .. ': ' .. (rec.status == 'full' and 'fully edified' or 'effects not read') end
    return name .. ': ' .. table.concat(parts, ', ') .. tier
end

-- The number an optional effect table (ionis_wiki.lua, none ships) gives for a game effect line, when its text starts with the game's words
-- ("Moderate Defense Enhancement" -> "(+20 DEF)"). nil when there is none.
function M.wiki_number(wiki, coalition, effect)
    for _, e in ipairs(wiki and wiki[coalition .. ' Coalition'] or {}) do
        if e.effect:sub(1, #effect) == effect then
            local n = trim(e.effect:sub(#effect + 1))
            if n ~= '' then return n end
        end
    end
    return nil
end

-- Box layout (user 2026-09-27: "I want it in the box ... a different format"): short labels with the
-- table's number, combat first, three to a row, then one row for everything else and a footer with the tier and
-- the date checked. The game's words are matched after dropping the tier; anything not listed still shows
-- in its own words, so a new effect is never hidden. A number the table marks unverified is left off.
local LABELS = {   -- {game words contain, label, combat?}, in box order
    {'Attack Enhancement', 'Atk', true}, {'Accuracy and Magic Accuracy', 'Acc/MAcc', true},
    {'Magic Attack Bonus', 'MAB', true},
    {'Defense Enhancement', 'DEF', true}, {'Evasion and Magic Evasion', 'Eva/MEva', true},
    {'Magic Defense Bonus', 'MDB', true},
    {'Max HP and MP', 'HP/MP', true}, {'Haste', 'Haste', true}, {'Fast Cast', 'FC', true},
    {'Save TP', 'Save TP', true}, {'Conserve MP', 'Conserve MP', true}, {'Critical Hit Rate', 'Crit rate', true},
    {'HP and MP Recovery', 'HP/MP recovery', true}, {'Resistance', 'Status resist', true},
    {'Experience Point', 'EXP', false}, {'Skill Gain', 'skill-ups', false}, {'Reward Obtainment', 'drops', false},
    {'Gathering', 'gathering', false}, {'Crystal', 'crafting', false}, {'Material Loss', 'crafting', false},
    {'Synthesis', 'crafting', false},
}

-- "(+2% 25/1024 Equipment Haste)" -> "+2%", "(+100 each)" -> "+100", "(3%)" -> "3%"; nil when unverified.
local function short_number(n)
    if not n or n:find('unverified', 1, true) then return nil end
    return n:match('([+-]?%d+%%?)')
end

function M.box_lines(recs, wiki)
    local found, tiers, extra = {}, {}, {}
    for _, rec in ipairs(recs or {}) do
        for _, e in ipairs(rec.effects or {}) do
            local tier = e:match('^(%a+) ')
            if tier == 'Moderate' or tier == 'Minor' then tiers[tier] = true end
            local rest = e:gsub('^Moderate ', ''):gsub('^Minor ', '')
            local hit
            for i, l in ipairs(LABELS) do
                if rest:find(l[1], 1, true) then hit = i break end
            end
            local num = short_number(M.wiki_number(wiki, rec.coalition, e))
            if hit then
                local label = LABELS[hit][2]
                if not found[label] then found[label] = {i = hit, text = label, combat = LABELS[hit][3]} end
                if num then found[label].text = label .. ' ' .. num end
            else
                extra[#extra + 1] = rest
            end
        end
    end
    local list = {}
    for _, f in pairs(found) do list[#list + 1] = f end
    table.sort(list, function(a, b) return a.i < b.i end)
    local out, row, other = {}, {}, {}
    for _, f in ipairs(list) do
        if f.combat then
            row[#row + 1] = f.text
            if #row == 3 then out[#out + 1] = table.concat(row, '   ') row = {} end
        else
            other[#other + 1] = f.text
        end
    end
    if #row > 0 then out[#out + 1] = table.concat(row, '   ') end
    for _, x in ipairs(extra) do other[#other + 1] = x end
    if #other > 0 then out[#out + 1] = table.concat(other, '   ') end
    local tier = (tiers.Moderate and tiers.Minor) and 'mixed tiers' or tiers.Moderate and 'all Moderate'
        or tiers.Minor and 'all Minor' or nil
    local date = recs and recs[1] and recs[1].date
    out[#out + 1] = table.concat({tier or '', date and ('checked ' .. date:sub(6)) or ''},
        (tier and date) and ', ' or '')
    return out
end

-- data/<Char>/coalitions.tsv: coalition, rank, date, status, effects joined by "; ".
function M.to_tsv(rec, date)
    return table.concat({rec.coalition, tostring(rec.rank or ''), date, rec.status or '',
        table.concat(rec.effects or {}, '; ')}, '\t')
end

function M.from_tsv(line)
    local c, r, d, s, e = line:match('^([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)\t?(.*)$')
    if not c or c == '' then return nil end
    local effects = {}
    for x in (e or ''):gmatch('[^;]+') do effects[#effects + 1] = trim(x) end
    return {coalition = c, rank = tonumber(r), date = d, status = s, effects = effects}
end

return M
