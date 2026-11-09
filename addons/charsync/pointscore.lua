--points core: turns Windower's player tables into rows and a summary. Pure, so tools/test-points.lua can
--run it outside the game.
--
-- Evidence (points 0.1.0 capture, one character, 2026-09-27 13:06): get_player() already holds everything at
-- load, 274 merits.* and 286 job_points.* values, keyed merits.<snake_name> (merits.double_attack_rate=5,
-- merits.upheaval=1) and job_points.<job3>.<snake_name> (job_points.war.berserk_effect=20, plus .jp,
-- .jp_spent and .cp per job). No 0x08C / 0x08D arrived; 0x063 order 2 carries Limit Points, Merit Points
-- and Max Merit Points. Names and per-point effects come from Windower res/job_points.lua and
-- res/merit_points.lua (en, endesc), matched by snake_case of the English name.
local M = {}

M.CP_CAP = 29999   -- seen on WAR, BLU, COR and SCH at 500 JP: capacity points stop banking there
M.JP_CAP = 500

function M.snake(name)
    return ((name or ''):lower():gsub('[^a-z0-9]+', '_'):gsub('^_+', ''):gsub('_+$', ''))
end

-- 0.2.0 in game left 33 merit names empty (one character, 2026-09-27 13:19): Windower drops the apostrophe
-- (warriors_charge) and the skill merits are keyed by the bare skill (great_axe, blue, enfeebling) where
-- the res name may carry "Skill" / "Magic". So each res name is indexed under those spellings too; the
-- exact spelling wins over a variant. Keys still unmatched come back in
-- rows(...).unnamed, which points.lua writes to the log.
local function variants(en)
    local out = {M.snake(en), M.snake((en:gsub("'", '')))}
    for _, base in ipairs({out[1], out[2]}) do
        for _, suffix in ipairs({'_magic_skill', '_skill', '_magic'}) do
            if base:sub(-#suffix) == suffix and #base > #suffix then out[#out + 1] = base:sub(1, -#suffix - 1) end
        end
    end
    return out
end

local function index(res_table)
    local by, exact = {}, {}
    for _, r in pairs(res_table or {}) do
        if type(r) == 'table' and type(r.en) == 'string' then
            for i, key in ipairs(variants(r.en)) do
                if i == 1 then by[key], exact[key] = r, true
                elseif not exact[key] and not by[key] then by[key] = r end
            end
        end
    end
    return by
end

local TOTALS = {jp = true, jp_spent = true, cp = true}

-- rows: {kind = 'merit' | 'jp' | 'jp_total', job, key, value, name, desc}. Zero values are dropped
-- except the per-job totals, so the file lists what you actually have.
function M.rows(player, res_jp, res_merits)
    local out = {}
    local jp_names, merit_names = index(res_jp), index(res_merits)
    for key, value in pairs(type(player.merits) == 'table' and player.merits or {}) do
        if type(value) == 'number' and value > 0 then
            local r = merit_names[key]
            out[#out + 1] = {kind = 'merit', job = '', key = key, value = value,
                name = r and r.en or key, desc = r and r.endesc or ''}
        end
    end
    for job, t in pairs(type(player.job_points) == 'table' and player.job_points or {}) do
        if type(t) == 'table' then
            for key, value in pairs(t) do
                if type(value) == 'number' and (TOTALS[key] or value > 0) then
                    local r = jp_names[key]
                    out[#out + 1] = {kind = TOTALS[key] and 'jp_total' or 'jp', job = job, key = key, value = value,
                        name = r and r.en or key, desc = r and r.endesc or ''}
                end
            end
        end
    end
    out.unnamed = {}
    for _, r in ipairs(out) do
        if r.kind ~= 'jp_total' and r.name == r.key then out.unnamed[#out.unnamed + 1] = r.key end
    end
    table.sort(out.unnamed)
    table.sort(out, function(a, b)
        if a.kind ~= b.kind then return a.kind < b.kind end
        if a.job ~= b.job then return a.job < b.job end
        return a.key < b.key
    end)
    return out
end

local function one_line(s) return ((s or ''):gsub('[\t\r\n]+', ' ')) end

function M.to_tsv(rows, date)
    local lines = {'date\tkind\tjob\tkey\tvalue\tname\teffect'}
    for _, r in ipairs(rows) do
        lines[#lines + 1] = table.concat({date, r.kind, r.job, r.key, tostring(r.value), one_line(r.name),
            one_line(r.desc)}, '\t')
    end
    return table.concat(lines, '\n') .. '\n'
end

-- Chat summary: merit bank, then per job what is waiting to be spent and whether points are being lost.
-- totals = {merit_points, max_merit_points, limit_points} from 0x063 order 2, or nil if not seen yet.
function M.summary(player, totals)
    local out = {}
    if totals and totals.merit_points then
        local capped = totals.max_merit_points and totals.merit_points >= totals.max_merit_points
        out[#out + 1] = ('merits banked %d/%s%s'):format(totals.merit_points, tostring(totals.max_merit_points or '?'),
            capped and ' - CAPPED, new merits are lost: spend some' or '')
    else
        out[#out + 1] = 'merit bank not seen yet (open the Merits menu once)'
    end
    local jobs = {}
    for job, t in pairs(type(player.job_points) == 'table' and player.job_points or {}) do
        if type(t) == 'table' and ((t.jp or 0) > 0 or (t.jp_spent or 0) > 0) then jobs[#jobs + 1] = job end
    end
    table.sort(jobs)
    for _, job in ipairs(jobs) do
        local t = player.job_points[job]
        local lost = (t.jp or 0) >= M.JP_CAP and (t.cp or 0) >= M.CP_CAP
        out[#out + 1] = ('%s: %d JP spent, %d to spend%s'):format(job:upper(), t.jp_spent or 0, t.jp or 0,
            lost and ' - CAPPED, new capacity points are lost' or '')
    end
    return out
end

return M
