-- itemname: item id -> English name without loading Windower's whole items table.
--
-- res.items expands to about 18.7 MB in an addon's own Lua state the first time anything touches it, and every addon
-- keeps its own copy (2026-10-18: 7 addons x 18.7 MB = about 130 MB per client). This reads res/items.lua line by line,
-- keeps only the ids that were asked for (a few KB), and falls back to res.items if the file cannot be read.
local M = {}

local cache = {}      -- id -> name, or false when the id was not found
local path = nil

local function items_path()
    if path == nil then
        path = (windower and windower.windower_path or '') .. 'res/items.lua'
    end
    return path
end

local function scan(id)
    local f = io.open(items_path(), 'r')
    if not f then return nil end
    local want = '[' .. id .. ']'
    local found = false
    for line in f:lines() do
        local key = line:match('^%s*(%[%d+%])')
        if key == want then
            found = line:match('[{,]%s*en%s*=%s*"([^"]*)"') or false
            break
        end
    end
    f:close()
    return found
end

-- name(id) -> English name, or nil when unknown. fallback is only used when res/items.lua cannot be opened.
function M.name(id, fallback)
    id = tonumber(id)
    if not id or id ~= math.floor(id) then return nil end
    local c = cache[id]
    if c ~= nil then return c or nil end
    local found = scan(id)
    if found == nil then
        local ok, r = pcall(function() local t = fallback and fallback() return t and t[id] end)
        found = ok and type(r) == 'table' and (r.en or r.english) or false
    end
    cache[id] = found
    return found or nil
end

function M.reset() cache = {} path = nil end
function M.set_path(p) path = p cache = {} end

return M
