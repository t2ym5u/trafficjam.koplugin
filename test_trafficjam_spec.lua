local DIR = debug.getinfo(1, "S").source:sub(2):match("(.*[/\\])") or "./"

package.preload["gettext"] = function()
    return setmetatable({}, { __call = function(_, s) return s end })
end
package.path = DIR .. "common/?.lua;" .. DIR .. "?.lua;" .. package.path

local unpack = unpack or table.unpack

-- Boards are drawn row by row, "." empty, "A" the red car.
local function rows(...)
    return table.concat({ ... })
end

describe("Solver", function()
    local Solver
    setup(function() Solver = require("solver") end)

    it("parses and formats a level string", function()
        local s = rows("BB...C", ".....C", "AA...C", "D.....", "D.EEE.", "......")
        local veh, pos = Solver.parse(s)
        assert.are.equal(5, #veh)
        assert.are.same({ id = "A", h = true, len = 2, line = 2 }, veh[1])
        assert.are.equal(0, pos[1])
        local c = veh[3]
        assert.are.equal("C", c.id)
        assert.is_false(c.h)
        assert.are.equal(3, c.len)
        assert.are.equal(5, c.line)
        assert.are.equal(s, Solver.format(veh, pos))
    end)

    it("rejects malformed levels", function()
        assert.is_nil(Solver.parse("too short"))
        assert.is_nil(Solver.parse(rows("......", "......", "......", "......", "......", "......")))
        -- Red car not on the exit row.
        assert.is_nil(Solver.parse(rows("AA....", "......", "......", "......", "......", "......")))
        -- A vehicle in two pieces.
        assert.is_nil(Solver.parse(rows("B.B...", "......", "AA....", "......", "......", "......")))
        -- A single square is not a vehicle.
        assert.is_nil(Solver.parse(rows("B.....", "......", "AA....", "......", "......", "......")))
    end)

    it("finds the optimal count on hand-made cases", function()
        local function dist(s)
            local veh, pos = assert(Solver.parse(s))
            return Solver.distance(veh, pos)
        end
        -- Free road: one move, any distance.
        assert.are.equal(1, dist(rows("......", "......", "AA....", "......", "......", "......")))
        -- Already at the exit.
        assert.are.equal(0, dist(rows("......", "......", "....AA", "......", "......", "......")))
        -- One car in the way, free to leave: 2.
        assert.are.equal(2, dist(rows("......", "...B..", "AA.B..", "......", "......", "......")))
        -- A truck that can only clear the row downwards, held up by a car.
        assert.are.equal(3, dist(rows(".....B", ".....B", "AA...B", "......", "......", "....CC")))
        -- Blocked for good: the column under and over the truck is full.
        assert.is_nil((dist(rows(".....B", ".....B", "AA...B", ".....C", ".....C", ".....C"))))
    end)

    it("agrees with an independent iterative-deepening search", function()
        local Board = require("board")
        -- Plain DFS over the move rules, without the packed states.
        local function ids(b, limit)
            if b.pos[1] == 4 then return true end
            if limit == 0 then return false end
            for i = 1, #b.veh do
                local lo, hi = b:range(i)
                local p = b.pos[i]
                for q = lo, hi do
                    if q ~= p then
                        b.pos[i] = q
                        local ok = ids(b, limit - 1)
                        b.pos[i] = p
                        if ok then return true end
                    end
                end
            end
            return false
        end
        local cases = {
            rows("..B...", "..B.C.", "AA..C.", "...DD.", "......", "......"),
            rows("B..C..", "B..C..", "AA.C..", "..DD..", ".....E", ".....E"),
            rows("BB.C..", "...C.D", "AA...D", "E.FF.D", "E.....", "GG...."),
            rows("...B..", "...B..", "AAC...", "..C.DD", "EE....", "......"),
        }
        for _, s in ipairs(cases) do
            local b = Board:new{ level = s }
            local d = Solver.distance(b.veh, b.pos)
            assert.is_truthy(d)
            local found
            for k = 0, d do
                if ids(b, k) then found = k break end
            end
            assert.are.equal(d, found, s)
        end
    end)
end)

describe("TrafficJamBoard", function()
    local Board, Solver
    setup(function()
        Board  = require("board")
        Solver = require("solver")
    end)

    local LEVEL = rows("......", "...B..", "AA.B..", "...CCC", "......", "......")

    it("slides vehicles only along their axis and never through others", function()
        local b = Board:new{ level = LEVEL, optimal = 2 }
        local red = 1
        local car_b = b:vehicleAt(2, 4)
        assert.are.equal("B", b.veh[car_b].id)
        -- The red car reaches column 3 at most: B blocks it.
        local lo, hi = b:range(red)
        assert.are.equal(0, lo)
        assert.are.equal(1, hi)
        assert.is_false(b:move(red, 4))
        -- B goes up one, not down (the truck sits under it).
        lo, hi = b:range(car_b)
        assert.are.equal(0, lo)
        assert.are.equal(1, hi)
        assert.is_false(b:move(car_b, 2))
        -- Tapping a square: only on the vehicle's line, outside it, in reach.
        assert.are.equal(0, b:targetFor(car_b, 1, 4))
        assert.is_nil(b:targetFor(car_b, 4, 4))   -- under it: the truck
        assert.is_nil(b:targetFor(car_b, 1, 3))   -- not on its column
        assert.are.equal(1, b:targetFor(red, 3, 3))
        assert.is_nil(b:targetFor(red, 3, 6))     -- past B
        assert.are.equal(0, b:getMoves())
    end)

    it("detects the win when the red car reaches the exit", function()
        local b = Board:new{ level = LEVEL, optimal = 2 }
        local car_b = b:vehicleAt(2, 4)
        assert.is_true(b:slide(car_b, -1))
        assert.is_false(b:isWon())
        assert.is_true(b:slide(1, 1))
        assert.is_true(b:isWon())
        assert.are.equal(2, b:getMoves())
        -- Nothing moves once the level is solved.
        assert.is_false(b:move(car_b, 1))
        assert.is_false(b:canUndo())
    end)

    it("undoes and restarts", function()
        local b = Board:new{ level = LEVEL, optimal = 2 }
        local start = { unpack(b.pos) }
        local truck = b:vehicleAt(4, 4)
        assert.is_true(b:move(truck, 0))
        assert.is_true(b:move(truck, 2))
        assert.are.equal(2, b:getMoves())
        assert.is_true(b:undoMove())
        assert.are.equal(0, b.pos[truck])
        assert.are.equal(1, b:getMoves())
        assert.is_true(b:restart())
        assert.are.same(start, b.pos)
        assert.are.equal(0, b:getMoves())
        assert.is_false(b:undoMove())
    end)

    it("gives hints that each bring the exit one move closer", function()
        local b = Board:new{ level = rows("BB.C..", "...C.D", "AA...D", "E.FF.D", "E.....", "GG....") }
        -- Scramble a little first, so hints start off the stored path.
        math.randomseed(5)
        for _ = 1, 6 do
            local i = math.random(#b.veh)
            local lo, hi = b:range(i)
            b:move(i, math.random(lo, hi))
            if b:isWon() then break end
        end
        while not b:isWon() do
            local before = b:remaining()
            local step = b:findHint()
            assert.is_truthy(step)
            assert.are.equal(b.veh[step.v].id, b.veh[b:vehicleAt(step.r, step.c)].id)
            assert.is_true(b:applyHint(step))
            local after = b:isWon() and 0 or b:remaining()
            assert.are.equal(before - 1, after)
        end
        local step, why = b:findHint()
        assert.is_nil(step)
        assert.are.equal("complete", why)
    end)

    it("steps through the solution one way", function()
        local b = Board:new{ level = LEVEL, optimal = 2 }
        assert.is_true(b:showSolution())
        assert.is_true(b:isShowingSolution())
        assert.are.equal(2, #b.solution)
        assert.is_false(b:move(1, 1))
        assert.is_false(b:solutionStep(-1))
        assert.is_true(b:solutionStep(1))
        assert.is_true(b:solutionStep(1))
        assert.is_true(Solver.isSolved(b.pos))
        assert.is_false(b:solutionStep(1))
        assert.is_true(b:solutionStep(-1))
        assert.is_false(Solver.isSolved(b.pos))
    end)

    it("round-trips a save, mid-game, solved and with the solution on show", function()
        local b = Board:new{ level = LEVEL, optimal = 2, band = "beginner", index = 7 }
        local truck = b:vehicleAt(4, 4)
        b:move(truck, 1)
        b:noteHintUsed()
        local data = b:serialize()
        local c = Board:new()
        assert.is_true(c:load(data))
        assert.are.same(b.pos, c.pos)
        assert.are.equal(1, c:getMoves())
        assert.are.equal("beginner", c.band)
        assert.are.equal(7, c.index)
        assert.are.equal(1, c:getHintsUsed())
        assert.is_true(c:undoMove())
        assert.are.same({ unpack(c.start_pos) }, c.pos)

        local car_b = b:vehicleAt(2, 4)
        b:slide(car_b, -1)
        b:slide(1, 1)
        local d = Board:new()
        assert.is_true(d:load(b:serialize()))
        assert.is_true(d:isWon())

        local e = Board:new{ level = LEVEL, optimal = 2 }
        e:showSolution()
        e:solutionStep(1)
        local f = Board:new()
        assert.is_true(f:load(e:serialize()))
        assert.is_true(f:isShowingSolution())
        assert.are.equal(1, f.sol_step)
        assert.are.same(e.pos, f.pos)
        assert.is_true(f:solutionStep(1))
        assert.is_true(Solver.isSolved(f.pos))
    end)

    it("refuses corrupt saves", function()
        local b = Board:new()
        assert.is_false(b:load(nil))
        assert.is_false(b:load({ level = "nonsense" }))
        local good = Board:new{ level = LEVEL }:serialize()
        good.pos = { 0, 0 }   -- one vehicle short
        assert.is_false(b:load(good))
        good = Board:new{ level = LEVEL }:serialize()
        good.pos[1] = 3   -- on top of B
        assert.is_false(b:load(good))
    end)
end)

describe("level bank", function()
    local Levels, Solver, Board
    setup(function()
        Levels = require("levels")
        Solver = require("solver")
        Board  = require("board")
    end)

    local RANGES = {
        beginner     = { 1, 8 },
        intermediate = { 9, 17 },
        advanced     = { 18, 29 },
        expert       = { 30, 99 },
    }

    it("holds at least 500 levels per difficulty, each within its band", function()
        for _, band in ipairs(Levels.BANDS) do
            local n = Levels.count(band)
            assert.is_true(n >= 500, band .. ": " .. n)
            local seen = {}
            for i = 1, n do
                local lv = Levels.get(band, i)
                assert.is_truthy(Solver.parse(lv.str), lv.str)
                assert.is_true(lv.optimal >= RANGES[band][1] and lv.optimal <= RANGES[band][2], lv.str)
                assert.is_nil(seen[lv.str])
                seen[lv.str] = true
                if i > 1 then assert.is_true(lv.optimal >= Levels.get(band, i - 1).optimal) end
            end
        end
    end)

    it("stores the exact optimal count (sampled)", function()
        for _, band in ipairs(Levels.BANDS) do
            local n = Levels.count(band)
            for i = 1, n, 15 do
                local lv = Levels.get(band, i)
                local veh, pos = Solver.parse(lv.str)
                assert.are.equal(lv.optimal, Solver.distance(veh, pos), band .. " #" .. i)
            end
            -- The hardest of each band too.
            local lv = Levels.get(band, n)
            local veh, pos = Solver.parse(lv.str)
            assert.are.equal(lv.optimal, Solver.distance(veh, pos))
        end
    end)

    it("is solved by following hints in exactly the optimal count (sampled)", function()
        for _, band in ipairs(Levels.BANDS) do
            for i = 1, Levels.count(band), 97 do
                local lv = Levels.get(band, i)
                local b = Board:new{ level = lv.str, optimal = lv.optimal }
                local steps = 0
                while not b:isWon() and steps <= lv.optimal do
                    assert.is_true(b:applyHint(b:findHint()))
                    steps = steps + 1
                end
                assert.is_true(b:isWon())
                assert.are.equal(lv.optimal, steps)
            end
        end
    end)

    it("solves the hardest level quickly enough for an e-reader", function()
        local lv = Levels.get("expert", Levels.count("expert"))
        local veh, pos = Solver.parse(lv.str)
        local t = os.clock()
        Solver.solve(veh, pos)
        -- A desktop is ~10-20x faster than a Kobo's CPU.
        assert.is_true(os.clock() - t < 0.5)
    end)
end)
