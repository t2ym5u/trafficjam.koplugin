local _dir = debug.getinfo(1, "S").source:sub(2):match("(.*[/\\])") or "./"
local function lrequire(name)
    local key = _dir .. name
    if not package.loaded[key] then
        package.loaded[key] = assert(loadfile(_dir .. name .. ".lua"))()
    end
    return package.loaded[key]
end

local Device          = require("device")
local FrameContainer  = require("ui/widget/container/framecontainer")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan  = require("ui/widget/horizontalspan")
local Menu            = require("ui/widget/menu")
local Size            = require("ui/size")
local UIManager       = require("ui/uimanager")
local VerticalGroup   = require("ui/widget/verticalgroup")
local VerticalSpan    = require("ui/widget/verticalspan")
local _               = require("i18n")
local T               = require("ffi/util").template

local ScreenBase   = require("screen_base")
local DailySeed    = require("daily_seed")
local MenuHelper   = require("menu_helper")
local Board        = lrequire("board")
local BoardWidget  = lrequire("board_widget")
local Levels       = lrequire("levels")
local Progress     = lrequire("progress")

local DeviceScreen = Device.screen

local GAME_RULES_EN = [[
Traffic Jam — Rules

The car park is a 6×6 grid with one exit, in the right-hand wall of the third row. Get the black car with the white arrow out through it.

• Cars take two squares, trucks three.
• A vehicle only slides along its length: forwards or backwards, never sideways, and never through another vehicle.
• Sliding one vehicle any distance counts as one move.

Each level shows its optimal number of moves: the fewest it can be solved in. Solving it in that many, without a hint, is a perfect score: the level gets a star (★) instead of a check mark (✓) in the Level list.

Controls:
• Tap a vehicle to select it (thick outline). Dots mark the free squares it can reach; tap one to slide it there. Tap the vehicle again to deselect it.
• Or swipe on a vehicle to slide it as far as it goes in that direction.
• Undo takes back the last move; Restart puts every vehicle back where the level started.
• Hint: the first tap marks the vehicle to move next and outlines where it goes (dashed); the second tap plays that move. Every hint follows an optimal solution from where you are.
• Show solution (menu) gives up the level and lets you step through an optimal solution.

Difficulty: Beginner levels take up to 8 moves, Intermediate 9 to 17, Advanced 18 to 29, Expert 30 or more. "New game" opens the next level you haven't solved yet; "Level" lets you pick any level. The Daily Challenge is the same level for everyone today.
]]

local GAME_RULES_FR = [[
Embouteillage — Règles

Le parking est une grille de 6×6 avec une seule sortie, dans le mur de droite de la troisième ligne. Faites sortir la voiture noire à flèche blanche.

• Les voitures occupent deux cases, les camions trois.
• Un véhicule ne glisse que dans le sens de sa longueur : en avant ou en arrière, jamais de côté, et jamais à travers un autre véhicule.
• Faire glisser un véhicule, de n'importe quelle distance, compte pour un coup.

Chaque niveau indique son nombre de coups optimal : le minimum pour le résoudre. Le réussir en autant de coups, sans astuce, c'est le score parfait : le niveau reçoit une étoile (★) au lieu d'une coche (✓) dans la liste des niveaux.

Commandes :
• Touchez un véhicule pour le sélectionner (contour épais). Des points marquent les cases libres qu'il peut atteindre ; touchez-en une pour l'y faire glisser. Touchez à nouveau le véhicule pour le désélectionner.
• Ou balayez un véhicule pour le faire glisser aussi loin que possible dans cette direction.
• Annuler reprend le dernier coup ; Recommencer remet tous les véhicules à leur place de départ.
• Astuce : le premier appui marque le véhicule à déplacer et entoure (en pointillés) sa destination ; le second joue ce coup. Chaque indice suit une solution optimale depuis la position actuelle.
• Voir la solution (menu) abandonne le niveau et permet de parcourir une solution optimale pas à pas.

Difficulté : les niveaux Débutant se font en 8 coups au plus, Intermédiaire de 9 à 17, Avancé de 18 à 29, Expert en 30 ou plus. « Nouvelle partie » ouvre le prochain niveau pas encore résolu ; « Niveau » permet de choisir n'importe quel niveau. Le Défi du jour est le même niveau pour tout le monde aujourd'hui.
]]

local BAND_LABELS = {
    beginner     = _("Beginner"),
    intermediate = _("Intermediate"),
    advanced     = _("Advanced"),
    expert       = _("Expert"),
}

local TrafficJamScreen = ScreenBase:extend{}

function TrafficJamScreen:init()
    self.progress = Progress.new(self.plugin)
    self.board = Board:new()
    if not self.board:load(self.plugin:loadState()) then
        self:_startLevel(self:_getBand(), self:_nextUnsolved(self:_getBand()))
    end
    ScreenBase.init(self)
end

function TrafficJamScreen:serializeState()
    return self.board:serialize()
end

function TrafficJamScreen:_save()
    self.plugin:saveState(self.board:serialize())
end

-- ---------------------------------------------------------------------------
-- Levels and progress
-- ---------------------------------------------------------------------------

function TrafficJamScreen:_getBand()
    local b = self.plugin:getSetting("difficulty", Levels.DEFAULT_BAND)
    return Levels.isBand(b) and b or Levels.DEFAULT_BAND
end

-- Solved / solved-in-the-optimum levels: see progress.lua.
function TrafficJamScreen:isLevelSolved(band, index)
    return self.progress:isSolved(band, index)
end

-- A win marks the level solved, and optimal too when it took the optimal
-- number of moves with no hint. Marks are never taken back.
function TrafficJamScreen:_markSolved()
    local b = self.board
    self.progress:record(b.band, b.index, b:isOptimalWin())
end

-- The first level of the band not solved yet (other than the one on the
-- board), or the one after the current level once they are all solved.
function TrafficJamScreen:_nextUnsolved(band)
    local total = Levels.count(band)
    local cur = self.board.band == band and self.board.index or nil
    for i = 1, total do
        if i ~= cur and not self:isLevelSolved(band, i) then return i end
    end
    if total == 0 then return nil end
    return cur and (cur % total) + 1 or 1
end

function TrafficJamScreen:_startLevel(band, index, daily)
    local lv = index and Levels.get(band, index)
    if not lv then return false end
    self.board:setLevel(lv.str, lv.optimal, band, index, daily)
    self.hint_cell = nil
    self:_save()
    return true
end

-- ---------------------------------------------------------------------------
-- Layout
-- ---------------------------------------------------------------------------

function TrafficJamScreen:buildLayout()
    local is_landscape = self:isLandscape()

    local title_bar = self:buildTitleBar(_("Traffic Jam"), function()
        local items = {
            { text = _("New game"), callback = function() self:onNewGame() end },
            self:makeDailyButtonConfig(),
            { text = T(_("Difficulty: %1"), BAND_LABELS[self:_getBand()]),
              callback = function() self:openDifficultyMenu() end },
            { text = self:_levelButtonText(), callback = function() self:openLevelMenu() end },
        }
        if not self.board:isShowingSolution() and not self.board:isWon() then
            items[#items + 1] = { text = _("Show solution"), callback = function() self:onShowSolution() end }
        end
        items[#items + 1] = self:makeRulesButtonConfig(GAME_RULES_EN, GAME_RULES_FR)
        return items
    end)

    self.status_text:setMaxWidth(self:getControlsWidth())
    local undo    = { id = "undo_btn",    text = _("Undo"),    callback = function() self:onUndo() end }
    local restart = { id = "restart_btn", text = _("Restart"), callback = function() self:onRestart() end }
    local hint    = { text = _("Hint"), callback = function() self:onHint() end }
    -- The landscape side panel is too narrow for three labels on one row.
    local action_bar = self:buildActionBar(is_landscape
        and { { undo, restart }, { hint } }
        or  { undo, restart, hint })
    self.undo_btn    = action_bar:getButtonById("undo_btn")
    self.restart_btn = action_bar:getButtonById("restart_btn")
    local controls = VerticalGroup:new{
        align = "center",
        self.status_text,
        VerticalSpan:new{ width = Size.span.vertical_large },
        action_bar,
    }

    -- The widget draws its own walls, so the frame only pads.
    local frame_pad = Size.padding.large
    local budget_w, budget_h = self:getBoardBudget(title_bar, controls)
    self.board_widget = BoardWidget:new{
        board           = self.board,
        max_width       = math.max(budget_w - 2 * frame_pad, 84),
        max_height      = math.max(budget_h - 2 * frame_pad, 72),
        cellTapCallback = function(r, c) self:onCellTap(r, c) end,
        swipeCallback   = function(r, c, dir, vdir) self:onSwipe(r, c, dir, vdir) end,
    }
    local board_frame = FrameContainer:new{
        padding    = frame_pad,
        margin     = 0,
        bordersize = 0,
        self.board_widget,
    }
    self:_updateButtons()

    if is_landscape then
        self:buildLandscapeLayout(title_bar, HorizontalGroup:new{
            align = "center",
            board_frame,
            HorizontalSpan:new{ width = self:getGutter() },
            controls,
        })
    else
        self:buildPortraitLayout(title_bar, board_frame,
            VerticalGroup:new{ align = "center", controls, VerticalSpan:new{ width = self:getGutter() } })
    end
    self:updateStatus()
end

-- ---------------------------------------------------------------------------
-- Interaction
-- ---------------------------------------------------------------------------

-- After anything that moved a vehicle: one repaint (updateStatus dirties the
-- whole screen once), the save, and the level marked solved on a win.
function TrafficJamScreen:_afterMove()
    self.hint_cell = nil
    local b = self.board
    if b:isWon() then self:_markSolved() end
    self:_save()
    self:_updateButtons()
    self:updateStatus()
end

function TrafficJamScreen:onCellTap(r, c)
    local b = self.board
    if b:isWon() or b:isShowingSolution() then return end
    local i = b:vehicleAt(r, c)
    if i then
        b:select(b.selected ~= i and i or nil)
        b.hint_shown = nil
        self.hint_cell = nil
        self.board_widget:refresh()
        return
    end
    local sel = b.selected
    local to = sel and b:targetFor(sel, r, c)
    if to and b:move(sel, to) then
        self:_afterMove()
    elseif sel then
        b:select(nil)
        self.board_widget:refresh()
    end
end

function TrafficJamScreen:onSwipe(r, c, dir, vdir)
    local b = self.board
    if b:isWon() or b:isShowingSolution() then return end
    local i = (r and b:vehicleAt(r, c)) or b.selected
    if not i then return end
    local v = b.veh[i]
    local d
    if v.h then
        d = (dir == "left" and -1) or (dir == "right" and 1) or nil
    else
        local vd = vdir or dir
        d = (vd == "up" and -1) or (vd == "down" and 1) or nil
    end
    if not d then return end
    b:select(i)
    if b:slide(i, d) then
        self:_afterMove()
    else
        self.board_widget:refresh()
    end
end

function TrafficJamScreen:onUndo()
    if self.board:undoMove() then self:_afterMove() end
end

function TrafficJamScreen:onRestart()
    if self.board:restart() then self:_afterMove() end
end

-- Each hint step names the vehicle by marking it on the board.
function TrafficJamScreen:describeHintStep(_step, level)
    if level == 1 then
        return _("Slide the marked vehicle to the dashed box.")
    end
    return _("Hint played.")
end

-- A hint can drive the red car out, so the round may end here.
-- A hint shown, even one only marked, rules out the optimal mark.
function TrafficJamScreen:onHint()
    local b = self.board
    local used = b:getHintsUsed()
    ScreenBase.onHint(self)
    if (self.hint_cell or b:getHintsUsed() > used) and not b.hint_seen then
        b:noteHintSeen()
        self:_save()
    end
    if b:isWon() then
        self:_markSolved()
        self:_save()
    end
    self:_updateButtons()
    self:refreshActionBar()
end

function TrafficJamScreen:onShowSolution()
    if not self.board:showSolution() then
        self:updateStatus(_("No hint is available here."))
        return
    end
    self.hint_cell = nil
    self:_save()
    self:_updateButtons()
    self:updateStatus()
end

function TrafficJamScreen:onSolutionStep(dir)
    if self.board:solutionStep(dir) then
        self:_save()
        self:updateStatus()
    end
end

function TrafficJamScreen:onNewGame()
    local band = self:_getBand()
    self:_startLevel(band, self:_nextUnsolved(band))
    self:buildLayout()
    UIManager:setDirty(self, function() return "ui", self.dimen end)
end

-- Today's level: picked from the bank by the daily seed, so everyone playing
-- the same difficulty gets the same one today.
function TrafficJamScreen:onDailyGame()
    local band = self:_getBand()
    local total = Levels.count(band)
    if total == 0 then return end
    local plugin = self.plugin
    local key = (plugin.getPluginId and plugin:getPluginId() or plugin.name) .. "_" .. band
    local index
    DailySeed.run(key, function() index = math.random(total) end)
    self:_startLevel(band, index, os.date("%Y-%m-%d"))
    self:buildLayout()
    UIManager:setDirty(self, function() return "ui", self.dimen end)
end

function TrafficJamScreen:openDifficultyMenu()
    local items = {}
    for _i, id in ipairs(Levels.BANDS) do
        items[#items + 1] = {
            id   = id,
            text = BAND_LABELS[id] .. " · " .. T(_("Solved: %1/%2 · minimum: %3"),
                self.progress:solvedCount(id), Levels.count(id), self.progress:optimalCount(id)),
        }
    end
    MenuHelper.openPickerMenu{
        title      = _("Difficulty"),
        items      = items,
        -- Wide enough for "Intermédiaire · Résolus : 600/600 · au minimum : 600".
        width_ratio = 0.9,
        current_id = self:_getBand(),
        parent     = self,
        on_select  = function(id)
            self.plugin:saveSetting("difficulty", id)
            self:onNewGame()
        end,
    }
end

-- Every level of the current difficulty, opened on the page of the level in
-- play; solved ones carry a check mark, a star if solved in the optimum.
function TrafficJamScreen:openLevelMenu()
    local band = self:_getBand()
    local total = Levels.count(band)
    if total == 0 then return end
    local cur = (self.board.band == band and not self.board.daily) and self.board.index or nil
    local menu
    local item_table = {}
    for i = 1, total do
        local lv = Levels.get(band, i)
        item_table[i] = {
            text     = T("%1 · %2", i, T(_("Optimal: %1"), lv.optimal)),
            mandatory = self.progress:mark(band, i),
            checked  = i == cur,
            callback = function()
                UIManager:close(menu)
                self:_startLevel(band, i)
                self:buildLayout()
                UIManager:setDirty(self, function() return "ui", self.dimen end)
            end,
        }
    end
    menu = Menu:new{
        title                  = T("%1 · %2", _("Level"), BAND_LABELS[band]),
        item_table             = item_table,
        width                  = math.floor(DeviceScreen:getWidth() * 0.8),
        height                 = math.floor(DeviceScreen:getHeight() * 0.9),
        disable_footer_padding = true,
        show_parent            = self,
    }
    if cur then menu:switchItemTable(nil, item_table, cur) end
    UIManager:show(menu)
    return menu
end

-- ---------------------------------------------------------------------------
-- Round over: a win, or the solution on show (one-way).
-- ---------------------------------------------------------------------------

function TrafficJamScreen:isRoundOver()
    return self.board:isWon() or self.board:isShowingSolution()
end

function TrafficJamScreen:getRoundOverButtons()
    local new_game = { text = _("New game"), callback = function() self:onNewGame() end }
    if self.board:isShowingSolution() then
        local back = { text = _("Step back"),    callback = function() self:onSolutionStep(-1) end }
        local fwd  = { text = _("Step forward"), callback = function() self:onSolutionStep(1) end }
        if self:isLandscape() then
            return { { back, fwd }, { new_game } }
        end
        return { { back, fwd, new_game } }
    end
    return { new_game }
end

-- ---------------------------------------------------------------------------
-- Status
-- ---------------------------------------------------------------------------

function TrafficJamScreen:_levelButtonText()
    local b = self.board
    if b.daily or not b.index then
        return T(_("Level: %1"), "–")
    end
    return T(_("Level: %1"), T("%1/%2", b.index, Levels.count(b.band)))
end

function TrafficJamScreen:updateStatus(msg)
    local b = self.board
    local status
    if msg then
        status = msg
    elseif b:isShowingSolution() then
        status = T(_("Solution: move %1/%2"), b.sol_step, #b.solution)
    elseif b:isWon() then
        if b:isOptimalWin() then
            status = T(_("Solved in %1 moves, the optimum! Time: %2"), b:getMoves(), b.timer:format())
        elseif b.hint_seen or b:getHintsUsed() > 0 then
            -- Hints follow an optimal solution: no credit for the count.
            status = T(_("Solved with hints in %1 moves (optimal: %2). Time: %3"), b:getMoves(),
                b.optimal or "?", b.timer:format())
        else
            status = T(_("Solved in %1 moves (optimal: %2). Time: %3"), b:getMoves(), b.optimal or "?",
                b.timer:format())
        end
    else
        local where
        if b.daily then
            where = _("Daily Challenge")
        elseif b.index then
            where = T(_("No. %1"), b.index)
        end
        status = self:joinStatus(
            BAND_LABELS[b.band],
            where,
            T(_("Moves: %1"), b:getMoves()),
            b.optimal and T(_("Optimal: %1"), b.optimal))
    end
    ScreenBase.updateStatus(self, status)
    -- Every move, hint, undo and reveal ends here, so the bar follows the board.
    self:refreshActionBar()
end

function TrafficJamScreen:_updateButtons()
    if self.undo_btn then self.undo_btn:enableDisable(self.board:canUndo()) end
    if self.restart_btn then self.restart_btn:enableDisable(self.board:canUndo()) end
end

-- The level bank is only needed while a game is open: drop it when the
-- screen closes (the next game reads it again).
function TrafficJamScreen:onCloseWidget()
    Levels.release()
end

return TrafficJamScreen
