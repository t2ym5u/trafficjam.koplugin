local Blitbuffer     = require("ffi/blitbuffer")
local Geom           = require("ui/geometry")
local GestureRange   = require("ui/gesturerange")
local InputContainer = require("ui/widget/container/inputcontainer")
local UIManager      = require("ui/uimanager")

local C_BG    = Blitbuffer.COLOR_WHITE
local C_FG    = Blitbuffer.COLOR_BLACK
local C_GRID  = Blitbuffer.COLOR_GRAY_C
local C_FLOOR = Blitbuffer.COLOR_WHITE

local N = 6
local EXIT_ROW = 2   -- 0-based, as in solver.lua

-- ---------------------------------------------------------------------------
-- TrafficJamBoardWidget: the 6×6 car park, its walls and the exit on the right
-- of the third row. Vehicles are drawn with a gap between them, each with its
-- own fill so neighbours stay apart on a grey-scale screen; the red car is
-- solid black with a white arrow.
--
-- Taps go to cellTapCallback(r, c); a swipe that starts on a square goes to
-- swipeCallback(r, c, dir) with dir one of "left", "right", "up", "down".
-- ---------------------------------------------------------------------------

local TrafficJamBoardWidget = InputContainer:extend{
    board           = nil,
    max_width       = 0,
    max_height      = 0,
    cellTapCallback = nil,
    swipeCallback   = nil,
}

function TrafficJamBoardWidget:init()
    -- Width: walls + 6 cells + an exit band on each side (the left one keeps
    -- the car park centred). Height: walls + 6 cells.
    local cell = math.floor(math.min(self.max_width / (N + 1), self.max_height / (N + 0.2)))
    cell = math.max(cell, 12)
    self.cell = cell
    self.wall = math.max(3, math.floor(cell * 0.09))
    self.band = math.floor(cell * 0.5) - self.wall
    self.grid_x = self.band + self.wall
    self.grid_y = self.wall
    self.w = cell * N + 2 * (self.band + self.wall)
    self.h = cell * N + 2 * self.wall
    self.dimen = Geom:new{ w = self.w, h = self.h }

    self.paint_rect = nil
    local range = function() return self.paint_rect end
    self.ges_events = {
        CellTap   = { GestureRange:new{ ges = "tap",   range = range } },
        CellSwipe = { GestureRange:new{ ges = "swipe", range = range } },
    }
end

function TrafficJamBoardWidget:_cellAt(pos)
    if not self.paint_rect then return nil end
    local lx = pos.x - self.paint_rect.x - self.grid_x
    local ly = pos.y - self.paint_rect.y - self.grid_y
    if lx < 0 or ly < 0 then return nil end
    local c = math.floor(lx / self.cell) + 1
    local r = math.floor(ly / self.cell) + 1
    if r > N or c > N then return nil end
    return r, c
end

-- Screen centre of cell (r, c), for tests driving the widget.
function TrafficJamBoardWidget:getCellCenter(r, c)
    local rect = self.paint_rect or Geom:new{ x = 0, y = 0 }
    local half = math.floor(self.cell / 2)
    return rect.x + self.grid_x + (c - 1) * self.cell + half,
           rect.y + self.grid_y + (r - 1) * self.cell + half
end

function TrafficJamBoardWidget:onCellTap(_, ges)
    local r, c = self:_cellAt(ges.pos)
    if r and self.cellTapCallback then self.cellTapCallback(r, c) end
    return true
end

local SWIPE_DIR = {
    west = "left", east = "right", north = "up", south = "down",
    northwest = "left", southwest = "left", northeast = "right", southeast = "right",
}

function TrafficJamBoardWidget:onCellSwipe(_, ges)
    local r, c = self:_cellAt(ges.pos)
    local dir = SWIPE_DIR[ges.direction]
    if dir and self.swipeCallback then
        -- A diagonal swipe on a vertical vehicle means up or down.
        local vdir
        if ges.direction == "northwest" or ges.direction == "northeast" then vdir = "up"
        elseif ges.direction == "southwest" or ges.direction == "southeast" then vdir = "down" end
        self.swipeCallback(r, c, dir, vdir)
    end
    return true
end

function TrafficJamBoardWidget:refresh()
    UIManager:setDirty(self, function()
        return "ui", self.paint_rect or self.dimen
    end)
end

-- ---------------------------------------------------------------------------
-- Fills. Each vehicle (but the red car) gets one, by its index: neighbouring
-- letters are usually neighbouring vehicles, so consecutive fills differ a lot.
-- `h` says the vehicle is horizontal: stripes run across or along it.
-- ---------------------------------------------------------------------------

local function stripes(bb, x, y, w, h, step, across_x)
    local sw = math.max(2, math.floor(step * 0.4))
    if across_x then
        for xx = x + math.floor(step / 2), x + w - sw, step do bb:paintRect(xx, y, sw, h, C_FG) end
    else
        for yy = y + math.floor(step / 2), y + h - sw, step do bb:paintRect(x, yy, w, sw, C_FG) end
    end
end

local function dots(bb, x, y, w, h, step, color)
    local d = math.max(2, math.floor(step * 0.4))
    for yy = y + math.floor((step - d) / 2), y + h - d, step do
        for xx = x + math.floor((step - d) / 2), x + w - d, step do
            bb:paintRect(xx, yy, d, d, color or C_FG)
        end
    end
end

local function hatch(bb, x, y, w, h, step)
    local sw = math.max(2, math.floor(step * 0.35))
    for yy = 0, h - 1 do
        local off = (yy % step)
        for xx = -off, w - 1, step do
            local x0 = math.max(0, xx)
            local x1 = math.min(w, xx + sw)
            if x1 > x0 then bb:paintRect(x + x0, y + yy, x1 - x0, 1, C_FG) end
        end
    end
end

local function grid(bb, x, y, w, h, step)
    local lw = math.max(1, math.floor(step / 6))
    for xx = x + math.floor(step / 2), x + w - lw, step do bb:paintRect(xx, y, lw, h, C_FG) end
    for yy = y + math.floor(step / 2), y + h - lw, step do bb:paintRect(x, yy, w, lw, C_FG) end
end

local function checker(bb, x, y, w, h, step)
    local s = math.max(3, math.floor(step * 0.7))
    local row = 0
    for yy = y, y + h - 1, s do
        local col = 0
        for xx = x, x + w - 1, s do
            if (row + col) % 2 == 0 then
                bb:paintRect(xx, yy, math.min(s, x + w - xx), math.min(s, y + h - yy), Blitbuffer.COLOR_GRAY_7)
            end
            col = col + 1
        end
        row = row + 1
    end
end

local FILLS = {
    function(bb, x, y, w, h)        bb:paintRect(x, y, w, h, Blitbuffer.COLOR_GRAY_B) end,
    function(bb, x, y, w, h, s, hz) stripes(bb, x, y, w, h, s, hz) end,
    function(bb, x, y, w, h, s)     dots(bb, x, y, w, h, s) end,
    function(bb, x, y, w, h)        bb:paintRect(x, y, w, h, Blitbuffer.COLOR_GRAY_6) end,
    function(bb, x, y, w, h, s)     hatch(bb, x, y, w, h, s) end,
    function(bb, x, y, w, h)        bb:paintRect(x, y, w, h, C_BG) end,
    function(bb, x, y, w, h, s, hz) stripes(bb, x, y, w, h, s, not hz) end,
    function(bb, x, y, w, h, s)     checker(bb, x, y, w, h, s) end,
    function(bb, x, y, w, h, s)
        bb:paintRect(x, y, w, h, Blitbuffer.COLOR_GRAY_9)
        dots(bb, x, y, w, h, s, C_BG)
    end,
    function(bb, x, y, w, h, s)     grid(bb, x, y, w, h, s) end,
    function(bb, x, y, w, h, s, hz)
        -- Dark body with one white stripe down its length.
        bb:paintRect(x, y, w, h, Blitbuffer.COLOR_GRAY_4)
        local t = math.max(2, math.floor(s * 0.45))
        if hz then bb:paintRect(x, y + math.floor((h - t) / 2), w, t, C_BG)
        else       bb:paintRect(x + math.floor((w - t) / 2), y, t, h, C_BG) end
    end,
    function(bb, x, y, w, h, s)
        -- White body with a second frame inside.
        local i = math.max(3, math.floor(s * 0.5))
        local lw = math.max(2, math.floor(s / 5))
        bb:paintRect(x + i, y + i, w - 2 * i, h - 2 * i, C_FG)
        bb:paintRect(x + i + lw, y + i + lw, w - 2 * (i + lw), h - 2 * (i + lw), C_BG)
    end,
}
TrafficJamBoardWidget.FILL_COUNT = #FILLS

-- The red car's white arrow, pointing at the exit.
local function arrow(bb, x, y, w, h)
    local cy   = y + math.floor(h / 2)
    local head = math.floor(h * 0.62)
    local hl   = math.floor(head * 0.75)
    local sh   = math.max(2, math.floor(h * 0.2))
    local x_end = x + w - math.floor(w * 0.14)
    local x_beg = x + math.floor(w * 0.16)
    bb:paintRect(x_beg, cy - math.floor(sh / 2), x_end - hl - x_beg + 1, sh, C_BG)
    for k = 0, hl - 1 do
        local half = math.floor(head / 2 * (1 - k / hl))
        bb:paintRect(x_end - hl + k, cy - half, 1, 2 * half + 1, C_BG)
    end
end

local function dashedOutline(bb, x, y, w, h, t, dash)
    for xx = x, x + w - 1, 2 * dash do
        local l = math.min(dash, x + w - xx)
        bb:paintRect(xx, y, l, t, C_FG)
        bb:paintRect(xx, y + h - t, l, t, C_FG)
    end
    for yy = y, y + h - 1, 2 * dash do
        local l = math.min(dash, y + h - yy)
        bb:paintRect(x, yy, t, l, C_FG)
        bb:paintRect(x + w - t, yy, t, l, C_FG)
    end
end

-- Rectangle of vehicle i at position p, inset by the gap.
function TrafficJamBoardWidget:_vehicleRect(gx, gy, v, p)
    local cell, gap = self.cell, math.max(2, math.floor(self.cell * 0.07))
    local x, y, w, h
    if v.h then
        x, y, w, h = gx + p * cell, gy + v.line * cell, v.len * cell, cell
    else
        x, y, w, h = gx + v.line * cell, gy + p * cell, cell, v.len * cell
    end
    return x + gap, y + gap, w - 2 * gap, h - 2 * gap
end

function TrafficJamBoardWidget:_paintVehicle(bb, gx, gy, i, selected)
    local board = self.board
    local v = board.veh[i]
    local x, y, w, h = self:_vehicleRect(gx, gy, v, board.pos[i])
    local cell = self.cell
    local bw = math.max(2, math.floor(cell / 28))
    local radius = math.floor(cell * 0.12)
    if selected then
        -- Thick black rim, then a white ring, so the selection reads on the
        -- black car and on white vehicles alike.
        local t = math.max(4, math.floor(cell / 9))
        bb:paintRoundedRect(x, y, w, h, C_FG, radius)
        local ring = math.max(2, math.floor(t / 2))
        bb:paintRect(x + t, y + t, w - 2 * t, h - 2 * t, C_BG)
        x, y, w, h = x + t + ring, y + t + ring, w - 2 * (t + ring), h - 2 * (t + ring)
        bb:paintRect(x, y, w, h, C_FG)
        bw = math.max(1, math.floor(bw / 2))
    else
        bb:paintRoundedRect(x, y, w, h, C_FG, radius)
    end
    if i == 1 then
        arrow(bb, x, y, w, h)
        return
    end
    local ix, iy, iw, ih = x + bw, y + bw, w - 2 * bw, h - 2 * bw
    bb:paintRect(ix, iy, iw, ih, C_BG)
    local fill = FILLS[(i - 2) % #FILLS + 1]
    fill(bb, ix, iy, iw, ih, math.max(5, math.floor(cell / 6)), v.h)
end

function TrafficJamBoardWidget:paintTo(bb, x, y)
    self.paint_rect = Geom:new{ x = x, y = y, w = self.w, h = self.h }
    local board = self.board
    local cell, wall = self.cell, self.wall
    local gx, gy = x + self.grid_x, y + self.grid_y
    local gw = cell * N

    bb:paintRect(x, y, self.w, self.h, C_BG)
    bb:paintRect(gx, gy, gw, gw, C_FLOOR)

    -- Parking bays: thin lines.
    for k = 1, N - 1 do
        bb:paintRect(gx + k * cell, gy, 1, gw, C_GRID)
        bb:paintRect(gx, gy + k * cell, gw, 1, C_GRID)
    end

    -- Walls, with the exit opening on the right of the exit row.
    local wx, wy = gx - wall, gy - wall
    local ww = gw + 2 * wall
    bb:paintRect(wx, wy, ww, wall, C_FG)
    bb:paintRect(wx, gy + gw, ww, wall, C_FG)
    bb:paintRect(wx, wy, wall, ww, C_FG)
    local ex_top = gy + EXIT_ROW * cell
    bb:paintRect(gx + gw, wy, wall, ex_top - wy, C_FG)
    bb:paintRect(gx + gw, ex_top + cell, wall, wy + ww - ex_top - cell, C_FG)
    -- Exit chevron in the band right of the opening.
    local band = self.band
    if band >= 6 then
        local cy = ex_top + math.floor(cell / 2)
        local len = math.floor(band * 0.7)
        local x0 = gx + gw + wall + math.floor((band - len) / 2)
        local half = math.min(math.floor(cell * 0.3), len)
        for k = 0, len - 1 do
            local hh = math.floor(half * (1 - k / len))
            bb:paintRect(x0 + k, cy - hh, 1, 2 * hh + 1, C_FG)
        end
    end

    -- Where the selected vehicle can go: a dot on every free square in reach.
    local sel = board.selected
    if sel and board.veh[sel] and not board.won then
        local v = board.veh[sel]
        local lo, hi = board:range(sel)
        local p = board.pos[sel]
        local d = math.max(4, math.floor(cell / 8))
        for q = lo, hi + v.len - 1 do
            if q < p or q >= p + v.len then
                local r, c
                if v.h then r, c = v.line, q else r, c = q, v.line end
                bb:paintRect(gx + c * cell + math.floor((cell - d) / 2),
                             gy + r * cell + math.floor((cell - d) / 2), d, d, C_FG)
            end
        end
    end

    -- Where the hinted (or next solution) move goes: a dashed outline.
    local ghost = board.hint_shown
    local nxt = board.nextSolutionMove and board:nextSolutionMove()
    if nxt then ghost = { v = nxt.v, to = nxt.to } end
    if ghost and board.veh[ghost.v] then
        local rx, ry, rw, rh = self:_vehicleRect(gx, gy, board.veh[ghost.v], ghost.to)
        dashedOutline(bb, rx, ry, rw, rh, math.max(2, math.floor(cell / 16)), math.max(4, math.floor(cell / 7)))
    end

    for i = 1, #board.veh do
        local selected = (i == sel) or (nxt and i == nxt.v)
        self:_paintVehicle(bb, gx, gy, i, selected)
    end
end

return TrafficJamBoardWidget
