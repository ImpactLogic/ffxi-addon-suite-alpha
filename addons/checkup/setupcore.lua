--setupcore: the pure part of //setup (no Windower calls), so tools/test-setup.lua runs it offline.
-- Modules are ticked like check boxes. A "part" (an add-on, optionally with a box) is needed while ANY ticked
-- module lists it, so shared parts load once and are only switched off when no ticked module still needs them.
-- A module with `always: yes` (the passive collectors) counts as ticked for everyone and cannot be unticked.
-- Recording is never a module: it stays its own switch (//rec).
local core = {}

-- Text of packs/index.txt -> {modules = {id...}, presets = {name = {id...}}}
function core.parse_index(text)
    local out = {modules = {}, presets = {}}
    for line in (text or ''):gmatch('[^\r\n]+') do
        local m = line:match('^%s*module:%s*([%w_%-]+)')
        if m then out.modules[#out.modules + 1] = m end
        local name, ids = line:match('^%s*preset:%s*([%w_%-]+)%s*=%s*(.-)%s*$')
        if name then
            local list = {}
            for id in ids:gmatch('[%w_%-]+') do list[#list + 1] = id end
            out.presets[name] = list
        end
    end
    return out
end

-- Text of one module file -> {id, name, desc, atlas, status, hidden, parts = {{addon, cmd, box}...}}
function core.parse_pack(id, text)
    local p = {id = id, name = id, desc = '', atlas = nil, always = false, status = 'launch', hidden = false, parts = {}}
    for line in (text or ''):gmatch('[^\r\n]+') do
        local k, v = line:match('^%s*(%a+):%s*(.-)%s*$')
        if k == 'name' then p.name = v
        elseif k == 'desc' then p.desc = v
        elseif k == 'atlas' then p.atlas = v
        elseif k == 'status' then p.status = v
        elseif k == 'hidden' then p.hidden = (v == 'yes' or v == 'on' or v == 'true')
        elseif k == 'always' then p.always = (v == 'yes' or v == 'on' or v == 'true')
        elseif k == 'part' then
            local addon = v:match('^([%w_]+)')
            if addon then
                p.parts[#p.parts + 1] = {addon = addon, cmd = v:match('cmd=([%w_]+)') or addon,
                                         box = (' ' .. v .. ' '):find('%sbox%s') ~= nil}
            end
        end
    end
    return p
end

-- ticked: set {id = true}. Returns {addon = {cmd = ..., box = bool}} over every ticked module.
-- requires_of(addon) (optional) returns the list of add-ons that add-on cannot work without (its `_addon.requires`,
-- mirrored in registry/addons.tsv); they are pulled in transitively. `uses` never pulls anything in.
function core.needed(packs, ticked, requires_of)
    local need = {}
    for _, p in ipairs(packs) do
        if ticked[p.id] or p.always then
            for _, part in ipairs(p.parts) do
                local n = need[part.addon]
                if not n then need[part.addon] = {cmd = part.cmd, box = part.box}
                else n.box = n.box or part.box end
            end
        end
    end
    if requires_of then
        local queue = {}
        for addon in pairs(need) do queue[#queue + 1] = addon end
        local i = 1
        while queue[i] do
            for _, dep in ipairs(requires_of(queue[i]) or {}) do
                if not need[dep] then need[dep] = {cmd = dep, box = false, required_by = queue[i]} queue[#queue + 1] = dep end
            end
            i = i + 1
        end
    end
    return need
end

-- Text of an add-on's main file -> its declared hard requirements, or {}.
function core.parse_requires(text)
    local list = {}
    local v = (text or ''):match("_addon%.requires%s*=%s*['\"]([^'\"]*)['\"]")
    for dep in (v or ''):gmatch('[%w_]+') do list[#list + 1] = dep end
    return list
end

-- What changes going from one ticked set to another: addons to load, boxes to switch on or off.
-- Nothing is ever unloaded: unticking only hides a box nobody else needs.
function core.plan(packs, before, after, requires_of)
    local b, a = core.needed(packs, before, requires_of), core.needed(packs, after, requires_of)
    local plan = {load = {}, box_on = {}, box_off = {}}
    local names = {}
    for addon in pairs(a) do names[#names + 1] = addon end
    for addon in pairs(b) do if not a[addon] then names[#names + 1] = addon end end
    table.sort(names)
    for _, addon in ipairs(names) do
        local was, now = b[addon], a[addon]
        if now and not was then plan.load[#plan.load + 1] = addon end
        local was_box, now_box = was and was.box, now and now.box
        if now_box and not was_box then plan.box_on[#plan.box_on + 1] = now.cmd end
        if was_box and not now_box then plan.box_off[#plan.box_off + 1] = was.cmd end
    end
    return plan
end

-- Everything a ticked set needs, as a plan (used by //setup apply and the login re-apply, where nothing is "before").
function core.apply_all(packs, ticked, requires_of)
    local plan = {load = {}, box_on = {}, box_off = {}}
    local need = core.needed(packs, ticked, requires_of)
    local names = {}
    for addon in pairs(need) do names[#names + 1] = addon end
    table.sort(names)
    for _, addon in ipairs(names) do
        plan.load[#plan.load + 1] = addon
        if need[addon].box then plan.box_on[#plan.box_on + 1] = need[addon].cmd end
    end
    return plan
end

-- Old module ids still found in saved settings.
local ALIAS = {multiboxer = 'multibox'}

function core.ids_to_set(csv)
    local s = {}
    for id in tostring(csv or ''):gmatch('[%w_%-]+') do s[ALIAS[id] or id] = true end
    return s
end

function core.set_to_csv(set, order)
    local t = {}
    for _, id in ipairs(order) do if set[id] then t[#t + 1] = id end end
    return table.concat(t, ',')
end

-- The checkbox list for chat.
function core.render(packs, ticked)
    local lines = {}
    for _, p in ipairs(packs) do
        if not p.hidden or ticked[p.id] then
            local parts = {}
            for _, part in ipairs(p.parts) do parts[#parts + 1] = part.addon end
            local tag = p.always and ' - always on' or p.status == 'preview' and ' - preview' or ''
            lines[#lines + 1] = ('[%s] %s: %s (%s)%s'):format((ticked[p.id] or p.always) and 'x' or ' ', p.id, p.name, table.concat(parts, ', '), tag)
        end
    end
    return lines
end

return core
