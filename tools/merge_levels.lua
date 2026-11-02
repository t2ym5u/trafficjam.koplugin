#!/usr/bin/env luajit
-- merge_levels.lua — merges gen_levels.lua outputs into the level bank text
-- (build_levels.sh wraps it into levels_data.lua).
--   luajit tools/merge_levels.lua part1.txt part2.txt ... > bank.txt
-- Drops duplicates, re-checks every optimal count with the forward solver,
-- sorts each band by optimal count and caps it at PER_BAND levels.
local dir = (arg[0]:match("(.*/)") or "./") .. "../"
local Solver = dofile(dir .. "solver.lua")
local PER_BAND = tonumber(os.getenv("PER_BAND") or 600)
local ORDER = { "beginner", "intermediate", "advanced", "expert" }
local bands, seen = {}, {}
for _, id in ipairs(ORDER) do bands[id] = {} end
for _, file in ipairs(arg) do
    local band
    for line in io.lines(file) do
        local b = line:match("^# (%a+)")
        if b then
            band = b
        else
            local str, d = line:match("^(%S+) (%d+)$")
            if str and not seen[str] then
                seen[str] = true
                local t = bands[band]
                t[#t + 1] = { str = str, d = tonumber(d) }
            end
        end
    end
end
for _, id in ipairs(ORDER) do
    local t = bands[id]
    -- Spread the cap over the whole band rather than keeping the easiest.
    table.sort(t, function(x, y) return x.str < y.str end)
    if #t > PER_BAND then
        local kept = {}
        for i = 1, PER_BAND do kept[i] = t[math.floor((i - 1) * #t / PER_BAND) + 1] end
        t = kept
    end
    table.sort(t, function(x, y)
        if x.d ~= y.d then return x.d < y.d end
        return x.str < y.str
    end)
    io.write("# ", id, " ", #t, "\n")
    for _, lv in ipairs(t) do
        local veh, pos = Solver.parse(lv.str)
        assert(veh, lv.str)
        assert(Solver.distance(veh, pos) == lv.d, "optimal count mismatch for " .. lv.str)
        io.write(lv.str, " ", lv.d, "\n")
    end
    io.stderr:write(id, ": ", #t, " (", t[1] and t[1].d or "-", "..", t[#t] and t[#t].d or "-", ")\n")
end
