-- ---------------------------------------------------------------------------
-- levels.lua — the level bank (levels_data.lua, built offline by tools/).
--
-- levels_data.lua returns one text: a band header per difficulty
-- ("# beginner 600") and one line per level, the 36-character board and its
-- optimal move count. Each band is sorted by optimal count, so level 1 is the
-- gentlest of its band. Parsed once, on first use (~0.3 MB in memory).
-- ---------------------------------------------------------------------------

local _dir = debug.getinfo(1, "S").source:sub(2):match("(.*[/\\])") or "./"

local Levels = {}

Levels.BANDS = { "beginner", "intermediate", "advanced", "expert" }
Levels.DEFAULT_BAND = "beginner"

local bank

local function load()
    if bank then return bank end
    bank = {}
    for _, id in ipairs(Levels.BANDS) do bank[id] = {} end
    local chunk = loadfile(_dir .. "levels_data.lua")
    local ok, text = pcall(chunk or error)
    if not ok or type(text) ~= "string" then return bank end
    local band
    for line in text:gmatch("[^\n]+") do
        local b = line:match("^# (%a+)")
        if b then
            band = bank[b]
        elseif band then
            local str, d = line:match("^([%.A-P]+) (%d+)")
            if str and #str == 36 then
                band[#band + 1] = { str = str, optimal = tonumber(d) }
            end
        end
    end
    return bank
end

function Levels.isBand(id)
    for _, b in ipairs(Levels.BANDS) do
        if b == id then return true end
    end
    return false
end

-- Number of levels in a band.
function Levels.count(band)
    local t = load()[band]
    return t and #t or 0
end

-- Level `index` of `band`: { str, optimal }, or nil.
function Levels.get(band, index)
    local t = load()[band]
    return t and t[index]
end

-- True once the bank is parsed (for tests).
function Levels.isLoaded()
    return bank ~= nil
end

-- Drops the parsed bank; the next call reads levels_data.lua again (~1-3 ms).
function Levels.release()
    bank = nil
end

return Levels
