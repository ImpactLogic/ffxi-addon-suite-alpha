-- uiscale: the one place that knows the screen's scale. Pure Lua (no Windower calls except through M.read), so it is tested offline
-- (tools/test-uiscale.lua). Idea #81.
--
-- Vocabulary. The window is x_res by y_res real pixels. Windower divides it by the profile's `uiscale` to get the UI size
-- (ui_x_res by ui_y_res); every text and image object is positioned and sized in UI pixels and then drawn scaled up by that ratio. So
-- one setting, the profile's uiscale, already scales every Windower box of every addon together. This module only reads it,
-- converts between the two pixel kinds, and works out which uiscale would give a wanted text size.
local M = {}

-- ws = windower.get_windower_settings() or a table with the same four fields. Returns nil when there is nothing usable.
function M.info(ws)
    if type(ws) ~= 'table' then return nil end
    local ww, wh, uw, uh = tonumber(ws.x_res), tonumber(ws.y_res), tonumber(ws.ui_x_res), tonumber(ws.ui_y_res)
    if not (ww and wh and uw and uh) or ww <= 0 or wh <= 0 or uw <= 0 or uh <= 0 then return nil end
    return {win_w = ww, win_h = wh, ui_w = uw, ui_h = uh, scale = ww / uw, scale_y = wh / uh}
end

function M.read()
    if not (windower and windower.get_windower_settings) then return nil end
    return M.info(windower.get_windower_settings())
end

-- UI pixels <-> window pixels (what native plugins such as FFXIDB use).
function M.to_window(n, info) return n * ((info and info.scale) or 1) end
function M.to_ui(n, info) return n / ((info and info.scale) or 1) end

-- Which uiscale gives a text line `want_win_px` tall (in window pixels) when the line measures `ui_line_px` in UI pixels.
-- Rounded to 0.05 and kept inside the 0.5 .. 3.0 that tools/set-uiscale.ps1 accepts.
function M.needed_scale(want_win_px, ui_line_px)
    want_win_px, ui_line_px = tonumber(want_win_px), tonumber(ui_line_px)
    if not want_win_px or not ui_line_px or want_win_px <= 0 or ui_line_px <= 0 then return nil end
    local s = math.floor(want_win_px / ui_line_px / 0.05 + 0.5) * 0.05
    if s < 0.5 then s = 0.5 elseif s > 3.0 then s = 3.0 end
    return math.floor(s * 100 + 0.5) / 100
end

-- Keep a box of w x h fully inside a UI of uw x uh.
function M.clamp(x, y, w, h, uw, uh)
    local nx = math.max(0, math.min(x, math.max(0, uw - (w or 0))))
    local ny = math.max(0, math.min(y, math.max(0, uh - (h or 0))))
    return nx, ny
end

-- Same screen as last time? Compares the four numbers, with a little slack for float noise.
function M.same(a, b)
    if not a or not b then return a == b end
    local function eq(x, y) return math.abs(x - y) < 0.5 end
    return eq(a.win_w, b.win_w) and eq(a.win_h, b.win_h) and eq(a.ui_w, b.ui_w) and eq(a.ui_h, b.ui_h)
end

-- Polls `getter` (default M.read) at most every `every` seconds and tells you when the screen changed.
--   local t = uiscale.tracker(nil, 2)
--   local changed, info, old = t:poll(os.clock())
function M.tracker(getter, every)
    local t = {getter = getter or M.read, every = every or 2, last = nil, at = nil}
    function t:poll(now)
        if self.at and now - self.at < self.every then return false, self.last end
        self.at = now
        local cur = self.getter()
        if not cur then return false, self.last end
        local old = self.last
        self.last = cur
        if old and not M.same(old, cur) then return true, cur, old end
        return false, cur
    end
    return t
end

-- One line for chat or a log.
function M.describe(info)
    if not info then return 'screen size unknown' end
    return ('window %dx%d, UI %dx%d, uiscale %.2f'):format(info.win_w, info.win_h, info.ui_w, info.ui_h, info.scale)
end

return M
