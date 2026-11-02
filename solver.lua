-- ---------------------------------------------------------------------------
-- solver.lua — rules and breadth-first solver for the sliding car puzzle.
--
-- Pure Lua (LuaJIT), no KOReader dependency: shared by the game, the specs and
-- the offline level generator in tools/.
--
-- A level is a 36-character string, row by row: "." is empty, "A" is the red
-- target car (always horizontal, on the exit row), "B".."P" the other vehicles.
-- Each vehicle has a fixed axis and line; only its position along that line
-- varies, so a state is one position per vehicle. A state packs into one number
-- (3 bits per vehicle, 16 vehicles at most = 48 bits, exact in a double), which
-- keeps the BFS tables small on a 256 MB reader.
--
-- A move slides one vehicle any distance along its axis; the optimal count is
-- the fewest such moves that bring the red car to the exit (its right end on
-- the last column of the exit row).
-- ---------------------------------------------------------------------------

local floor = math.floor

local Solver = {}

Solver.N        = 6
Solver.EXIT_ROW = 2   -- 0-based: the third row
Solver.TARGET   = "A"
Solver.MAX_VEHICLES = 16

local N = Solver.N

-- 8^(i-1), the weight of vehicle i in a packed state.
local WEIGHT = {}
for i = 1, Solver.MAX_VEHICLES do WEIGHT[i] = 8 ^ (i - 1) end
Solver.WEIGHT = WEIGHT

-- Parses a level string. Returns the vehicle list (red car first, then by
-- letter) and the position list, or nil and a reason.
-- Each vehicle: { id = "B", h = true|false, len = 2|3, line = 0..5 }.
-- Its position is the column of its left end (horizontal) or the row of its
-- top end (vertical), 0-based.
function Solver.parse(str)
    if type(str) ~= "string" or #str ~= N * N then return nil, "length" end
    local cells = {}
    for i = 1, N * N do
        local ch = str:sub(i, i)
        if ch ~= "." then
            local r, c = floor((i - 1) / N), (i - 1) % N
            cells[ch] = cells[ch] or {}
            local t = cells[ch]
            t[#t + 1] = { r, c }
        end
    end
    if not cells[Solver.TARGET] then return nil, "no target" end
    local ids = {}
    for id in pairs(cells) do
        if id ~= Solver.TARGET then ids[#ids + 1] = id end
    end
    table.sort(ids)
    table.insert(ids, 1, Solver.TARGET)
    if #ids > Solver.MAX_VEHICLES then return nil, "too many vehicles" end

    local veh, pos = {}, {}
    for i, id in ipairs(ids) do
        local t = cells[id]
        local len = #t
        if len < 2 or len > 3 then return nil, "bad length " .. id end
        local r0, c0 = t[1][1], t[1][2]
        local h = t[2][1] == r0
        for k = 2, len do
            local r, c = t[k][1], t[k][2]
            if h and not (r == r0 and c == c0 + k - 1) then return nil, "bad shape " .. id end
            if not h and not (c == c0 and r == r0 + k - 1) then return nil, "bad shape " .. id end
        end
        veh[i] = { id = id, h = h, len = len, line = h and r0 or c0 }
        pos[i] = h and c0 or r0
    end
    local red = veh[1]
    if not red.h or red.line ~= Solver.EXIT_ROW or red.len ~= 2 then
        return nil, "target must be a horizontal car on the exit row"
    end
    return veh, pos
end

-- Back to a level string.
function Solver.format(veh, pos)
    local t = {}
    for i = 1, N * N do t[i] = "." end
    for i, v in ipairs(veh) do
        for k = 0, v.len - 1 do
            local r, c
            if v.h then r, c = v.line, pos[i] + k else r, c = pos[i] + k, v.line end
            t[r * N + c + 1] = v.id
        end
    end
    return table.concat(t)
end

-- Cell index (0-based, row-major) of the k-th square of vehicle v at p.
local function cellOf(v, p, k)
    if v.h then return v.line * N + p + k end
    return (p + k) * N + v.line
end
Solver.cellOf = cellOf

function Solver.encode(pos)
    local key = 0
    for i = #pos, 1, -1 do key = key * 8 + pos[i] end
    return key
end

function Solver.decode(key, n, out)
    out = out or {}
    for i = 1, n do
        local p = key % 8
        out[i] = p
        key = (key - p) / 8
    end
    return out
end

-- Occupancy grid: grid[cell] = vehicle index, or false.
function Solver.occupancy(veh, pos, grid)
    grid = grid or {}
    for i = 0, N * N - 1 do grid[i] = false end
    for i, v in ipairs(veh) do
        for k = 0, v.len - 1 do grid[cellOf(v, pos[i], k)] = i end
    end
    return grid
end

-- Furthest positions vehicle i can reach (lo, hi), given the others.
function Solver.range(veh, pos, i, grid)
    grid = grid or Solver.occupancy(veh, pos)
    local v, p = veh[i], pos[i]
    local lo = p
    while lo > 0 and not grid[cellOf(v, lo - 1, 0)] do lo = lo - 1 end
    local hi = p
    while hi + v.len < N and not grid[cellOf(v, hi + 1, v.len - 1)] do hi = hi + 1 end
    return lo, hi
end

function Solver.isSolved(pos)
    return pos[1] == N - 2
end

-- Calls fn(i, newpos, newkey) for every move out of the state.
local function eachMove(veh, n, pos, key, grid, fn)
    for i = 1, n do
        local v, p = veh[i], pos[i]
        local w = WEIGHT[i]
        local q = p - 1
        while q >= 0 and not grid[cellOf(v, q, 0)] do
            fn(i, q, key + (q - p) * w)
            q = q - 1
        end
        q = p + 1
        while q + v.len <= N and not grid[cellOf(v, q, v.len - 1)] do
            fn(i, q, key + (q - p) * w)
            q = q + 1
        end
    end
end
Solver.eachMove = eachMove

-- Optimal solution from (veh, pos): a list of moves { v = i, to = p }, empty
-- when already solved. Returns nil, "unsolvable" when the exit can't be
-- reached, nil, "budget" past max_states explored (default 400000).
function Solver.solve(veh, pos, max_states)
    max_states = max_states or 400000
    local n = #veh
    if Solver.isSolved(pos) then return {} end
    local start = Solver.encode(pos)
    local parent, via = { [start] = false }, {}
    local queue, head, tail = { start }, 1, 1
    local cur, grid = {}, {}
    local goal = N - 2
    local found
    local count = 1
    local key
    local function visit(i, q, nk)
        if found or parent[nk] ~= nil then return end
        parent[nk] = key
        via[nk] = (i - 1) * 8 + q
        count = count + 1
        if i == 1 and q == goal then found = nk return end
        tail = tail + 1
        queue[tail] = nk
    end
    while head <= tail do
        key = queue[head]
        queue[head] = nil
        head = head + 1
        Solver.decode(key, n, cur)
        Solver.occupancy(veh, cur, grid)
        eachMove(veh, n, cur, key, grid, visit)
        if found then break end
        if count > max_states then return nil, "budget" end
    end
    if not found then return nil, "unsolvable" end
    local path = {}
    local k = found
    while parent[k] do
        local m = via[k]
        table.insert(path, 1, { v = floor(m / 8) + 1, to = m % 8 })
        k = parent[k]
    end
    return path
end

-- Optimal move count, or nil plus the reason.
function Solver.distance(veh, pos, max_states)
    local path, why = Solver.solve(veh, pos, max_states)
    if not path then return nil, why end
    return #path
end

-- Every state reachable from pos, with its distance to the nearest solved
-- state (nil when the cluster has no solution). Used offline by the level
-- generator. Returns states (list of keys), dist (key -> moves), max distance.
function Solver.cluster(veh, pos, max_states)
    max_states = max_states or 200000
    local n = #veh
    local start = Solver.encode(pos)
    local seen = { [start] = true }
    local states, cnt = { start }, 1
    local solved = {}
    local cur, grid = {}, {}
    local head = 1
    local function visit(_, _, nk)
        if not seen[nk] then
            seen[nk] = true
            cnt = cnt + 1
            states[cnt] = nk
        end
    end
    while head <= cnt do
        local key = states[head]
        head = head + 1
        Solver.decode(key, n, cur)
        if cur[1] == N - 2 then solved[#solved + 1] = key end
        Solver.occupancy(veh, cur, grid)
        eachMove(veh, n, cur, key, grid, visit)
        if cnt > max_states then return nil, "budget" end
    end
    if #solved == 0 then return states, nil, -1 end
    -- Moves are reversible, so distances to the goal come from one BFS that
    -- starts from every solved state at once.
    local dist, queue = {}, {}
    for i, k in ipairs(solved) do dist[k] = 0; queue[i] = k end
    local qh, qt = 1, #queue
    local maxd = 0
    local d
    local function relax(_, _, nk)
        if dist[nk] == nil then
            dist[nk] = d + 1
            if d + 1 > maxd then maxd = d + 1 end
            qt = qt + 1
            queue[qt] = nk
        end
    end
    while qh <= qt do
        local key = queue[qh]
        qh = qh + 1
        d = dist[key]
        Solver.decode(key, n, cur)
        Solver.occupancy(veh, cur, grid)
        eachMove(veh, n, cur, key, grid, relax)
    end
    return states, dist, maxd
end

return Solver
