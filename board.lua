local _dir = debug.getinfo(1, "S").source:sub(2):match("(.*[/\\])") or "./"
local function lrequire(name)
    local key = _dir .. name
    if not package.loaded[key] then
        package.loaded[key] = assert(loadfile(_dir .. name .. ".lua"))()
    end
    return package.loaded[key]
end

local Timer  = require("timer")
local Solver = lrequire("solver")

-- ---------------------------------------------------------------------------
-- TrafficJamBoard — one level in play: where the vehicles are, the moves made,
-- the clock, hints and the step-through solution. Pure Lua, no UI.
--
-- Rows and columns are 1-based here (as everywhere in the UI); vehicle
-- positions are 0-based, as in solver.lua.
-- ---------------------------------------------------------------------------

local N = Solver.N
local unpack = unpack or table.unpack  -- luacheck: ignore (Lua 5.2+ in the specs)

-- Forward BFS budget for hints and the solution. The shipped levels' whole
-- clusters stay under 25 000 states, so this never cuts a real level short;
-- it only guards against a corrupt save.
local SOLVE_BUDGET = 60000

local TrafficJamBoard = {}
TrafficJamBoard.__index = TrafficJamBoard
TrafficJamBoard.N = N

function TrafficJamBoard:new(opts)
    opts = opts or {}
    local obj = setmetatable({
        timer      = Timer:new(),
        hints_used = 0,
        history    = {},
    }, self)
    if opts.level then
        obj:setLevel(opts.level, opts.optimal, opts.band, opts.index, opts.daily)
    end
    return obj
end

-- Starts `str` from scratch. Returns false if the string isn't a level.
function TrafficJamBoard:setLevel(str, optimal, band, index, daily)
    local veh, pos = Solver.parse(str)
    if not veh then return false end
    self.level      = str
    self.veh        = veh
    self.pos        = pos
    self.start_pos  = { unpack(pos) }
    self.optimal    = optimal
    self.band       = band
    self.index      = index
    self.daily      = daily or nil
    self.history    = {}
    self.won        = false
    self.selected   = nil
    self.hint_shown = nil
    self.solution   = nil
    self.sol_step   = nil
    self.hints_used = 0
    self._plan      = nil
    self.timer:reset()
    self.timer:start()
    return true
end

-- ---------------------------------------------------------------------------
-- Queries
-- ---------------------------------------------------------------------------

function TrafficJamBoard:vehicleCount()
    return #self.veh
end

-- Vehicle index covering cell (r, c), or nil.
function TrafficJamBoard:vehicleAt(r, c)
    if r < 1 or r > N or c < 1 or c > N then return nil end
    local grid = Solver.occupancy(self.veh, self.pos)
    return grid[(r - 1) * N + (c - 1)] or nil
end

-- Cells of vehicle i: list of {r, c}, 1-based.
function TrafficJamBoard:cellsOf(i, p)
    local v = self.veh[i]
    p = p or self.pos[i]
    local t = {}
    for k = 0, v.len - 1 do
        if v.h then t[#t + 1] = { v.line + 1, p + k + 1 }
        else        t[#t + 1] = { p + k + 1, v.line + 1 } end
    end
    return t
end

-- Lowest and highest positions vehicle i can slide to.
function TrafficJamBoard:range(i)
    return Solver.range(self.veh, self.pos, i)
end

-- The position vehicle i would take to cover (r, c), if (r, c) lies on its
-- line, outside it and within reach; nil otherwise. The vehicle slides the
-- least distance that puts one of its squares on the cell.
function TrafficJamBoard:targetFor(i, r, c)
    local v = self.veh[i]
    if not v then return nil end
    local along
    if v.h then
        if r - 1 ~= v.line then return nil end
        along = c - 1
    else
        if c - 1 ~= v.line then return nil end
        along = r - 1
    end
    local p = self.pos[i]
    local to
    if along < p then
        to = along
    elseif along >= p + v.len then
        to = along - v.len + 1
    else
        return nil
    end
    local lo, hi = self:range(i)
    if to < lo or to > hi then return nil end
    return to
end

function TrafficJamBoard:isWon()
    return self.won
end

function TrafficJamBoard:getMoves()
    return #self.history
end

function TrafficJamBoard:canUndo()
    return #self.history > 0 and not self.won and not self.solution
end

function TrafficJamBoard:isShowingSolution()
    return self.solution ~= nil
end

-- ---------------------------------------------------------------------------
-- Moves
-- ---------------------------------------------------------------------------

-- The plan (an optimal path from the current state) survives a move that
-- follows it, so a run of hints costs one search.
function TrafficJamBoard:_advancePlan(i, to)
    local plan = self._plan
    if plan and plan.path[1] and plan.path[1].v == i and plan.path[1].to == to then
        local rest = {}
        for k = 2, #plan.path do rest[#rest + 1] = plan.path[k] end
        self._plan = { key = Solver.encode(self.pos), path = rest }
    else
        self._plan = nil
    end
end

-- Slides vehicle i to position `to`. Returns true if it moved.
function TrafficJamBoard:move(i, to)
    if self.won or self.solution then return false end
    local p = self.pos[i]
    if not p or to == p then return false end
    local lo, hi = self:range(i)
    if to < lo or to > hi then return false end
    self.history[#self.history + 1] = { i, p, to }
    self.pos[i] = to
    self:_advancePlan(i, to)
    self.hint_shown = nil
    if Solver.isSolved(self.pos) then
        self.won = true
        self.selected = nil
        self.timer:stop()
    end
    return true
end

-- Slides vehicle i as far as it goes in direction dir (-1: left/up,
-- +1: right/down). Returns true if it moved.
function TrafficJamBoard:slide(i, dir)
    if not self.veh[i] then return false end
    local lo, hi = self:range(i)
    return self:move(i, dir < 0 and lo or hi)
end

function TrafficJamBoard:undoMove()
    if not self:canUndo() then return false end
    local h = table.remove(self.history)
    self.pos[h[1]] = h[2]
    self._plan = nil
    self.hint_shown = nil
    return true
end

-- Back to the starting position. The clock keeps running.
function TrafficJamBoard:restart()
    if self.won or self.solution or #self.history == 0 then return false end
    self.pos = { unpack(self.start_pos) }
    self.history = {}
    self.selected = nil
    self.hint_shown = nil
    self._plan = nil
    return true
end

function TrafficJamBoard:select(i)
    self.selected = i
end

-- ---------------------------------------------------------------------------
-- Solving: hints and the solution
-- ---------------------------------------------------------------------------

-- An optimal path from the current state, or nil plus a reason.
function TrafficJamBoard:plan()
    local key = Solver.encode(self.pos)
    if self._plan and self._plan.key == key then return self._plan.path end
    local path, why = Solver.solve(self.veh, self.pos, SOLVE_BUDGET)
    if not path then return nil, why end
    self._plan = { key = key, path = path }
    return path
end

-- Optimal number of moves left from here.
function TrafficJamBoard:remaining()
    local path = self:plan()
    return path and #path
end

-- Game-common hint convention (ScreenBase:onHint): a step names a cell (the
-- vehicle's first square) and a tag (where it goes), so the first tap marks
-- the vehicle and the second makes the move.
function TrafficJamBoard:findHint()
    if self.won then return nil, "complete" end
    local path = self:plan()
    if not path or not path[1] then return nil, "none" end
    local m = path[1]
    local cell = self:cellsOf(m.v)[1]
    local step = { kind = "fill", r = cell[1], c = cell[2], tag = m.to, v = m.v, to = m.to }
    self._last_hint = step
    return step
end

-- Called by ScreenBase:onHint with the hinted cell: marks the vehicle and
-- remembers where it is going, for the board widget.
function TrafficJamBoard:setSelection(r, c)
    local i = self:vehicleAt(r, c)
    self.selected = i
    local h = self._last_hint
    if h and h.v == i then self.hint_shown = { v = i, to = h.to } end
end

function TrafficJamBoard:applyHint(step)
    if not step or not step.v then return false end
    return self:move(step.v, step.to)
end

function TrafficJamBoard:getHintsUsed()
    return self.hints_used or 0
end

function TrafficJamBoard:noteHintUsed()
    self.hints_used = (self.hints_used or 0) + 1
end

-- One-way: the solution from the current position replaces play. The player
-- then steps through it; the board shows the position after sol_step moves.
function TrafficJamBoard:showSolution()
    if self.solution then return true end
    if self.won then return false end
    local path = self:plan()
    if not path then return false end
    self.solution = path
    self.sol_base = { unpack(self.pos) }
    self.sol_step = 0
    self.selected = nil
    self.hint_shown = nil
    self.timer:stop()
    return true
end

-- The solution move about to be played (for the widget), or nil.
function TrafficJamBoard:nextSolutionMove()
    if not self.solution then return nil end
    return self.solution[self.sol_step + 1]
end

-- Steps the solution forward (+1) or back (-1). Returns true if it moved.
function TrafficJamBoard:solutionStep(dir)
    if not self.solution then return false end
    local s = self.sol_step + dir
    if s < 0 or s > #self.solution then return false end
    self.pos = { unpack(self.sol_base) }
    for k = 1, s do
        local m = self.solution[k]
        self.pos[m.v] = m.to
    end
    self.sol_step = s
    return true
end

-- ---------------------------------------------------------------------------
-- Persistence
-- ---------------------------------------------------------------------------

local function flatMoves(list, a, b)
    local t = {}
    for _, m in ipairs(list) do
        t[#t + 1] = m[a]
        t[#t + 1] = m[b]
    end
    return t
end

function TrafficJamBoard:serialize()
    if not self.level then return nil end
    local hist = {}
    for _, h in ipairs(self.history) do
        hist[#hist + 1] = h[1]; hist[#hist + 1] = h[2]; hist[#hist + 1] = h[3]
    end
    local data = {
        level      = self.level,
        optimal    = self.optimal,
        band       = self.band,
        index      = self.index,
        daily      = self.daily,
        pos        = { unpack(self.pos) },
        history    = hist,
        won        = self.won,
        hints_used = self.hints_used,
        timer      = self.timer:serialize(),
    }
    if self.solution then
        data.solution = flatMoves(self.solution, "v", "to")
        data.sol_base = { unpack(self.sol_base) }
        data.sol_step = self.sol_step
    end
    return data
end

-- Restores a saved game. Returns false (board untouched) on anything that
-- doesn't fit the level it names.
function TrafficJamBoard:load(data)
    if type(data) ~= "table" or type(data.level) ~= "string" then return false end
    local veh, start = Solver.parse(data.level)
    if not veh then return false end
    local n = #veh
    local function validPos(t)
        if type(t) ~= "table" or #t ~= n then return false end
        for i = 1, n do
            local p = tonumber(t[i])
            if not p or p < 0 or p + veh[i].len > N then return false end
        end
        -- No two vehicles on one square.
        local seen = {}
        for i = 1, n do
            for k = 0, veh[i].len - 1 do
                local cell = Solver.cellOf(veh[i], t[i], k)
                if seen[cell] then return false end
                seen[cell] = true
            end
        end
        return true
    end
    if not validPos(data.pos) then return false end
    local hist = type(data.history) == "table" and data.history or {}
    if #hist % 3 ~= 0 then return false end
    local sol
    if data.solution ~= nil then
        if type(data.solution) ~= "table" or #data.solution % 2 ~= 0 or not validPos(data.sol_base) then
            return false
        end
        sol = {}
        for k = 1, #data.solution, 2 do
            local v, to = tonumber(data.solution[k]), tonumber(data.solution[k + 1])
            if not v or not veh[v] or not to then return false end
            sol[#sol + 1] = { v = v, to = to }
        end
        local s = tonumber(data.sol_step)
        if not s or s < 0 or s > #sol then return false end
    end

    self:setLevel(data.level, tonumber(data.optimal), data.band, tonumber(data.index), data.daily)
    self.pos = { unpack(data.pos) }
    self.history = {}
    for k = 1, #hist, 3 do
        self.history[#self.history + 1] = { tonumber(hist[k]), tonumber(hist[k + 1]), tonumber(hist[k + 2]) }
    end
    self.won = data.won and Solver.isSolved(self.pos) or false
    self.hints_used = tonumber(data.hints_used) or 0
    self.timer:load(data.timer)
    if sol then
        self.solution = sol
        self.sol_base = { unpack(data.sol_base) }
        self.sol_step = tonumber(data.sol_step)
    end
    if self.won or self.solution then self.timer:stop() else self.timer:start() end
    return true
end

return TrafficJamBoard
