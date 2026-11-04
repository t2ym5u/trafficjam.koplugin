# Changelog

All notable changes to this project will be documented in this file.

## [1.1.0] - 2026-11-04

### Added
- Levels solved in the optimal number of moves now get a star: the *Level* list shows ★
  for a level solved in its optimal number of moves without a hint, ✓ for any other solve,
  and the *Difficulty* menu shows "Solved: x/y · minimum: z". A later
  solve in the optimal number of moves turns a ✓ into a ★; a slower one never takes a
  ★ away. Levels solved before this version keep their ✓.
- A win that used a hint (even one only shown, not played) now says so
  instead of claiming the optimum: hints follow an optimal solution, so they
  don't earn the star.

## [1.0.5] - 2026-11-04

### Fixed
- A game no longer crashes when an outdated plugin is installed alongside:
  shared modules left behind by an older plugin are replaced by this
  plugin's own copy instead of being used as they are.

## [1.0.4] - 2026-11-04

### Changed
- Uses less memory: the game loads when you open it, not when KOReader
  starts, so it no longer takes memory or startup time while unplayed.
- Uses less memory: the level bank loads when the game opens and is freed
  when it closes.

## [1.0.3] - 2026-11-03

### Changed
- Picks up game-common 1.11.0: the shared on-screen keyboard (where used)
  gives every key the same letter size, and the no-repeat history helper.

## [1.0.2] - 2026-11-02

### Changed
- Picks up game-common 1.10.0: the shared Tools → Games menu also lists
  the games' new "· multiplayer" entries under Party & quiz.

## [1.0.1] - 2026-11-02

### Changed
- Listed under **Tools → Games**, grouped by category, instead of its own
  entry in the Tools menu (game-common 1.9.1).

## [1.0.0] - 2026-11-02

### Added
- First release: a sliding-block car puzzle on a 6×6 car park. Get the
  black car out through the exit by sliding cars and trucks along their
  lanes.
- 2400 original levels, 600 per difficulty, graded by their optimal number
  of moves: Beginner (3–8), Intermediate (9–17), Advanced (18–29) and
  Expert (30–50). Every level is checked to be solvable in exactly its
  stated optimum.
- Tap to select and tap a square to slide, or swipe a vehicle to slide it
  all the way.
- Moves counter against the optimum, Undo, Restart, timer and auto-save.
- Hint (two taps: mark the vehicle and its destination, then play it), always
  along an optimal solution from the current position.
- Show solution: step through an optimal solution, forwards and back.
- "New game" opens the next unsolved level; a level picker and solved
  counts per difficulty; a Daily Challenge.
