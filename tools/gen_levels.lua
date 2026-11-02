#!/usr/bin/env luajit
-- ---------------------------------------------------------------------------
-- gen_levels.lua — offline generator for the level bank (not shipped).
--
--   luajit tools/gen_levels.lua [per_bucket] [seed] > part.txt
--   (tools/build_levels.sh runs several seeds in parallel and merges them)
--
-- 1. Drop the red car on the exit row and a random set of cars and trucks
--    around it (no other horizontal vehicle on the exit row: it could never
--    get out of the way).
-- 2. Enumerate every state reachable from there (its "cluster") and run one
--    BFS backwards from all the solved states of the cluster: every state then
--    knows its optimal move count.
-- 3. Keep at most one state per difficulty band from each cluster: the
--    farthest state for the highest band the cluster reaches, a random state
--    at a random distance inside each lower band.
-- 4. Re-letter each kept state canonically (reading order), drop duplicates,
--    double-check the optimal count with the forward solver, sort each band by
--    optimal count, then write one line per level: "<36 chars> <optimal>".
--
-- Deterministic for a given seed. Nothing here is copied from any published
-- card set: every position comes out of the random placement above.
-- ---------------------------------------------------------------------------

local dir = (arg[0]:match("(.*/)") or "./") .. "../"
package.path = dir .. "?.lua;" .. package.path
local Solver = dofile(dir .. "solver.lua")

local PER_BUCKET = tonumber(arg[1]) or 600
local SEED       = tonumber(arg[2]) or 20261102
local MAX_CLUSTER = 25000   -- keeps the in-game hint/solution BFS cheap
local STEPS = 400           -- hill-climbing steps per restart
local QUOTA = { 12, 12, 12, 25 }  -- levels per band per restart, for variety

local BUCKETS = {
    { id = "beginner",     lo = 3,  hi = 8 },
    { id = "intermediate", lo = 9,  hi = 17 },
    { id = "advanced",     lo = 18, hi = 29 },
    { id = "expert",       lo = 30, hi = 99 },
}

math.randomseed(SEED)
local N = Solver.N
local LETTERS = "BCDEFGHIJKLMNOP"

local function randomConfig()
    local grid = {}
    for i = 0, N * N - 1 do grid[i] = false end
    local veh, pos = {}, {}
    local function place(v, p)
        for k = 0, v.len - 1 do
            if grid[Solver.cellOf(v, p, k)] then return false end
        end
        for k = 0, v.len - 1 do grid[Solver.cellOf(v, p, k)] = true end
        veh[#veh + 1] = v
        pos[#pos + 1] = p
        return true
    end
    place({ id = "A", h = true, len = 2, line = Solver.EXIT_ROW }, math.random(0, 3))
    local want = math.random(8, 14)
    local tries = 0
    while #veh < want and tries < 200 do
        tries = tries + 1
        local len = math.random() < 0.3 and 3 or 2
        local h = math.random() < 0.5
        local line = math.random(0, N - 1)
        if not (h and line == Solver.EXIT_ROW) then
            local id = LETTERS:sub(#veh, #veh)
            place({ id = id, h = h, len = len, line = line }, math.random(0, N - len))
        end
    end
    return veh, pos
end

-- Letters in reading order of the vehicles' first cells, red car always "A".
local function canonical(str)
    local map, nxt = { ["."] = ".", A = "A" }, 1
    local out = {}
    for i = 1, #str do
        local ch = str:sub(i, i)
        if not map[ch] then
            map[ch] = LETTERS:sub(nxt, nxt)
            nxt = nxt + 1
        end
        out[i] = map[ch]
    end
    return table.concat(out)
end

local banks, seen = {}, {}
for b = 1, #BUCKETS do banks[b] = {} end
local function full(b) return #banks[b] >= PER_BUCKET end
local function allFull()
    for b = 1, #BUCKETS do if not full(b) then return false end end
    return true
end

local trials, clusters = 0, 0
local t0 = os.clock()
local cur = {}

-- Files the cluster's states into the bands (see the header).
local function harvest(veh, states, dist, maxd, quota)
    local by_d = {}
    for _, k in ipairs(states) do
        local d = dist[k]
        if d then
            by_d[d] = by_d[d] or {}
            local t = by_d[d]
            t[#t + 1] = k
        end
    end
    for b, bk in ipairs(BUCKETS) do
        if not full(b) and maxd >= bk.lo and (quota[b] or 0) < QUOTA[b] then
            local d
            if maxd <= bk.hi then
                d = maxd
            else
                d = math.random(math.max(bk.lo, math.floor((bk.lo + bk.hi) / 2) - 2), bk.hi)
            end
            local list = by_d[d]
            local key = list[math.random(#list)]
            Solver.decode(key, #veh, cur)
            local str = canonical(Solver.format(veh, cur))
            if not seen[str] then
                seen[str] = true
                quota[b] = (quota[b] or 0) + 1
                local bank = banks[b]
                bank[#bank + 1] = { str = str, d = d, size = #states }
            end
        end
    end
end

local function evaluate(veh, pos)
    trials = trials + 1
    local states, dist, maxd = Solver.cluster(veh, pos, MAX_CLUSTER)
    if not states or not dist then return nil end
    clusters = clusters + 1
    return { veh = veh, pos = pos, states = states, dist = dist, maxd = maxd }
end

-- A neighbour configuration: from a random state of the cluster, remove a
-- vehicle, add one, or both. Hard positions are rare among random layouts,
-- so the search climbs towards clusters with a longer optimal solution.
local function mutate(c)
    local key = c.states[math.random(#c.states)]
    local p0 = Solver.decode(key, #c.veh, {})
    local veh, pos = {}, {}
    for i, v in ipairs(c.veh) do
        veh[i] = { id = v.id, h = v.h, len = v.len, line = v.line }
        pos[i] = p0[i]
    end
    local op = math.random(3)
    if (op == 1 or op == 3) and #veh > 5 then
        local i = math.random(2, #veh)
        table.remove(veh, i)
        table.remove(pos, i)
    end
    if op ~= 1 and #veh < 15 then
        local grid = Solver.occupancy(veh, pos)
        for _ = 1, 50 do
            local len = math.random() < 0.3 and 3 or 2
            local h = math.random() < 0.5
            local line = math.random(0, N - 1)
            local p = math.random(0, N - len)
            if not (h and line == Solver.EXIT_ROW) then
                local v = { h = h, len = len, line = line }
                local ok = true
                for k = 0, len - 1 do
                    if grid[Solver.cellOf(v, p, k)] then ok = false break end
                end
                if ok then
                    veh[#veh + 1] = v
                    pos[#pos + 1] = p
                    break
                end
            end
        end
    end
    for i = 2, #veh do veh[i].id = LETTERS:sub(i - 1, i - 1) end
    return veh, pos
end

while not allFull() do
    local c
    repeat
        c = evaluate(randomConfig())
    until c and c.maxd >= 1
    local quota = {}
    harvest(c.veh, c.states, c.dist, c.maxd, quota)
    for _ = 1, STEPS do
        if allFull() then break end
        local cand = evaluate(mutate(c))
        if cand and cand.maxd >= 1 then
            harvest(cand.veh, cand.states, cand.dist, cand.maxd, quota)
            if cand.maxd >= c.maxd then c = cand end
        end
    end
    io.stderr:write(string.format("trials %d clusters %d  %d/%d/%d/%d  best %d  %.1fs\n", trials, clusters,
        #banks[1], #banks[2], #banks[3], #banks[4], c.maxd, os.clock() - t0))
end

-- Forward check of every kept level, then output.
for b, bk in ipairs(BUCKETS) do
    local bank = banks[b]
    table.sort(bank, function(x, y)
        if x.d ~= y.d then return x.d < y.d end
        return x.str < y.str
    end)
    io.write("# ", bk.id, " ", #bank, "\n")
    for _, lv in ipairs(bank) do
        local veh, pos = Solver.parse(lv.str)
        local d = Solver.distance(veh, pos)
        assert(d == lv.d, "optimal count mismatch for " .. lv.str)
        io.write(lv.str, " ", lv.d, "\n")
    end
end
io.stderr:write(string.format("done: %d trials, %d clusters, %.1fs\n", trials, clusters, os.clock() - t0))
