local DIR = debug.getinfo(1, "S").source:sub(2):match("(.*[/\\])") or "./"

package.preload["gettext"] = function()
    return setmetatable({}, { __call = function(_, s) return s end })
end
package.path = DIR .. "common/?.lua;" .. DIR .. "?.lua;" .. package.path

-- Difficulty guarantees of the level bank: a level's difficulty is its
-- optimal move count (checked against the solver on a sample); each band
-- holds only levels of its documented range, sorted, the ranges are ordered,
-- and the bands get harder on average.
describe("Traffic Jam difficulty bands", function()
    local Levels, Solver
    setup(function()
        Levels = require("levels")
        Solver = require("solver")
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

    it("the documented ranges are ordered and do not overlap", function()
        local prev_hi = 0
        for _, band in ipairs(Levels.BANDS) do
            assert.are.equal(prev_hi + 1, RANGES[band][1], band)
            assert.is_true(RANGES[band][2] >= RANGES[band][1])
            prev_hi = RANGES[band][2]
        end
    end)

    it("the bands get harder on average", function()
        local prev = 0
        for _, band in ipairs(Levels.BANDS) do
            local n, sum = Levels.count(band), 0
            for i = 1, n do sum = sum + Levels.get(band, i).optimal end
            assert.is_true(sum / n > prev, band)
            prev = sum / n
        end
    end)
end)
