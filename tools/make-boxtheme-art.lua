-- Draws the boxtheme textures (addons/boxtheme/art/*.png). Our own art: gradients and noise made here,
-- nothing copied from the game or other addons. Colours were measured from the user's screenshots of the
-- in-game Window Types 1-8 (2026-09-28). Deterministic: the same PNGs every run.
--   luajit tools/make-boxtheme-art.lua
local bit = require('bit')
local OUT = 'addons/boxtheme/art/'

-- PNG writer: RGBA8, zlib "stored" blocks (no compression library needed; the files stay small).
local crc_table = {}
for n = 0, 255 do
    local c = n
    for _ = 1, 8 do c = bit.band(c, 1) ~= 0 and bit.bxor(0xEDB88320, bit.rshift(c, 1)) or bit.rshift(c, 1) end
    crc_table[n] = c
end
local function crc32(s)
    local c = 0xFFFFFFFF
    for i = 1, #s do c = bit.bxor(crc_table[bit.band(bit.bxor(c, s:byte(i)), 0xFF)], bit.rshift(c, 8)) end
    return bit.bxor(c, 0xFFFFFFFF)
end
local function be32(n) return string.char(bit.band(bit.rshift(n, 24), 255), bit.band(bit.rshift(n, 16), 255), bit.band(bit.rshift(n, 8), 255), bit.band(n, 255)) end
local function chunk(kind, data) return be32(#data) .. kind .. data .. be32(crc32(kind .. data)) end
local function zlib_stored(raw)
    local out, a, b = {'\120\1'}, 1, 0
    local pos = 1
    while pos <= #raw do
        local block = raw:sub(pos, pos + 65534)
        pos = pos + #block
        local last = pos > #raw and 1 or 0
        local len = #block
        out[#out + 1] = string.char(last, bit.band(len, 255), bit.rshift(len, 8), bit.band(bit.bnot(len), 255), bit.band(bit.rshift(bit.bnot(len), 8), 255))
        out[#out + 1] = block
    end
    for i = 1, #raw do a = (a + raw:byte(i)) % 65521 b = (b + a) % 65521 end
    out[#out + 1] = be32(b * 65536 + a)
    return table.concat(out)
end
local function write_png(name, w, h, pixel)
    local rows = {}
    for y = 0, h - 1 do
        local r = {'\0'}
        for x = 0, w - 1 do
            local R, G, B, A = pixel(x, y)
            local function c(v) return math.max(0, math.min(255, math.floor(v + 0.5))) end
            r[#r + 1] = string.char(c(R), c(G), c(B), c(A))
        end
        rows[#rows + 1] = table.concat(r)
    end
    local ihdr = be32(w) .. be32(h) .. '\8\6\0\0\0'
    local png = '\137PNG\r\n\26\n' .. chunk('IHDR', ihdr) .. chunk('IDAT', zlib_stored(table.concat(rows))) .. chunk('IEND', '')
    local f = assert(io.open(OUT .. name, 'wb'))
    f:write(png) f:close()
    print(('%s %dx%d %d bytes'):format(name, w, h, #png))
end

-- Smooth value noise, tileable over `period` cells.
local function hash(x, y, seed)
    local n = bit.bxor(x * 374761393 + y * 668265263 + seed * 144269504, 0)
    n = bit.bxor(n, bit.rshift(n, 13)) * 1274126177
    return bit.band(bit.bxor(n, bit.rshift(n, 16)), 0xFFFF) / 65535
end
local function noise(x, y, period, seed)
    local x0, y0 = math.floor(x), math.floor(y)
    local fx, fy = x - x0, y - y0
    fx, fy = fx * fx * (3 - 2 * fx), fy * fy * (3 - 2 * fy)
    local function v(i, j) return hash((x0 + i) % period, (y0 + j) % period, seed) end
    local a = v(0, 0) + (v(1, 0) - v(0, 0)) * fx
    local b = v(0, 1) + (v(1, 1) - v(0, 1)) * fx
    return a + (b - a) * fy
end
local function fbm(x, y, size, octaves, seed)
    local sum, amp, total, cells = 0, 1, 0, 4
    for _ = 1, octaves do
        sum = sum + amp * noise(x / size * cells, y / size * cells, cells, seed)
        total, amp, cells = total + amp, amp * 0.5, cells * 2
    end
    return sum / total
end

local function lerp(a, b, t) return a + (b - a) * t end
local function grad(top, bottom, t)
    return lerp(top[1], bottom[1], t), lerp(top[2], bottom[2], t), lerp(top[3], bottom[3], t), lerp(top[4], bottom[4], t)
end

-- Plain white: tinted by the panel for frames, rules and time bars.
write_png('white.png', 4, 4, function() return 255, 255, 255, 255 end)

-- Vertical gradients (16 x 256, stretched to the box).
local GRADS = {
    type1 = {{38, 34, 64, 232}, {29, 25, 79, 232}},
    type2 = {{64, 68, 77, 232}, {41, 39, 47, 232}},
    type3 = {{34, 32, 55, 232}, {26, 22, 75, 232}},
    type4 = {{36, 48, 48, 232}, {18, 25, 25, 236}},
    type5 = {{62, 62, 69, 228}, {72, 72, 97, 228}},
    menu  = {{35, 42, 79, 236}, {18, 22, 48, 242}},
    menu_title = {{57, 66, 122, 250}, {38, 45, 89, 250}},
    glass = {{20, 16, 10, 158}, {10, 8, 6, 184}},
}
for name, g in pairs(GRADS) do
    write_png(name .. '.png', 16, 256, function(_, y) return grad(g[1], g[2], y / 255) end)
end

-- Scanlines for type 3: tiled over the gradient, one faint line every 3 px.
write_png('scanlines.png', 4, 3, function(_, y) if y == 0 then return 255, 255, 255, 10 end return 0, 0, 0, 0 end)

-- Textured types, 256 x 256, stretched to the box.
local S = 256
write_png('type6.png', S, S, function(x, y)   -- deep navy, soft clouds
    local n = fbm(x, y, S, 4, 6)
    local r, g, b, a = grad({0, 23, 51, 240}, {0, 13, 30, 240}, y / (S - 1))
    local k = (n - 0.35) * 70
    return r + k * 0.35, g + k * 0.6, b + k, a
end)
write_png('type7.png', S, S, function(x, y)   -- leather brown, blotchy
    local n = fbm(x, y, S, 5, 7)
    local fine = noise(x / 3, y / 3, S / 3, 17)
    local r, g, b, a = grad({96, 72, 52, 238}, {72, 60, 56, 238}, y / (S - 1))
    local k = (n - 0.5) * 80 + (fine - 0.5) * 14
    return r + k, g + k * 0.8, b + k * 0.6, a
end)
write_png('type8.png', S, S, function(x, y)   -- dark blue, caustic ripples
    local n = fbm(x, y, S, 3, 8)
    local ridge = 1 - math.abs(math.sin(n * 18))
    ridge = ridge ^ 6
    local r, g, b, a = grad({36, 45, 56, 238}, {30, 39, 63, 238}, y / (S - 1))
    return r + ridge * 45, g + ridge * 70, b + ridge * 95, a
end)

-- Title bar icons (idea #65): drawn smooth (4x4 supersampling), 16x16, shown at 14x14. One PNG per state so the
-- panel only shows/hides them and never swaps textures.
local function icon(name, main, dark, shape)
    write_png(name, 16, 16, function(x, y)
        local m, d = 0, 0
        for sy = 0, 3 do for sx = 0, 3 do
            local k = shape(x + (sx + 0.5) / 4, y + (sy + 0.5) / 4)
            if k == 1 then m = m + 1 elseif k == 2 then d = d + 1 end
        end end
        local n = m + d
        if n == 0 then return 0, 0, 0, 0 end
        return (main[1] * m + dark[1] * d) / n, (main[2] * m + dark[2] * d) / n, (main[3] * m + dark[3] * d) / n, 255 * n / 16
    end)
end
local function rrect(px, py, x0, y0, x1, y1, r)
    if px < x0 or px > x1 or py < y0 or py > y1 then return false end
    local cx = math.min(math.max(px, x0 + r), x1 - r)
    local cy = math.min(math.max(py, y0 + r), y1 - r)
    return (px - cx) ^ 2 + (py - cy) ^ 2 <= r * r
end
local function ring(px, py, cx, cy, ro, ri)
    local d2 = (px - cx) ^ 2 + (py - cy) ^ 2
    return d2 <= ro * ro and d2 >= ri * ri
end
local function padlock(open)
    return function(px, py)
        if rrect(px, py, 2.5, 7, 13.5, 14.5, 1.6) then
            if (px - 8) ^ 2 + (py - 10.2) ^ 2 <= 1.3 ^ 2 or (px >= 7.4 and px <= 8.6 and py >= 10.4 and py <= 12.6) then return 2 end
            return 1
        end
        local cy = open and 4.2 or 6.6
        if py <= cy and ring(px, py, 8, cy, 4.6, 2.6) then return 1 end
        if px >= 3.4 and px <= 5.4 and py >= cy and py <= 7.4 then return 1 end                  -- left leg
        if not open and px >= 10.6 and px <= 12.6 and py >= cy and py <= 7.4 then return 1 end   -- right leg
        return 0
    end
end
local function seg(px, py, ax, ay, bx, by, w)
    local dx, dy = bx - ax, by - ay
    local t = math.max(0, math.min(1, ((px - ax) * dx + (py - ay) * dy) / (dx * dx + dy * dy)))
    return (px - ax - t * dx) ^ 2 + (py - ay - t * dy) ^ 2 <= w * w
end
icon('lock_on.png', {236, 192, 98}, {40, 32, 14}, padlock(false))
icon('lock_off.png', {150, 158, 186}, {30, 32, 46}, padlock(true))
icon('close.png', {206, 210, 228}, {0, 0, 0}, function(px, py)
    if rrect(px, py, 1.5, 1.5, 14.5, 14.5, 2.4) and not rrect(px, py, 2.7, 2.7, 13.3, 13.3, 1.4) then return 1 end
    if seg(px, py, 5.2, 5.2, 10.8, 10.8, 0.85) or seg(px, py, 10.8, 5.2, 5.2, 10.8, 0.85) then return 1 end
    return 0
end)

-- Drag handle (2 x 3 dots): the whole title strip drags, this just shows where to grab.
icon('grip.png', {170, 178, 204}, {0, 0, 0}, function(px, py)
    for _, cx in ipairs({5.2, 10.8}) do
        for _, cy in ipairs({3.6, 8, 12.4}) do
            if (px - cx) ^ 2 + (py - cy) ^ 2 <= 1.45 ^ 2 then return 1 end
        end
    end
    return 0
end)
