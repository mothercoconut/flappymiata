# lib/ui — presentation

Owner: @Sdav239

Screens, menus, HUD, buttons, input handling, and anything that draws.

Free to import Flame and Flutter. Read state from `lib/game/`; do not put game
rules in here. If you find yourself writing a number that decides how the game
behaves — gravity, gap size, score per pipe — that number belongs in
`lib/game/`.

## What is in here

| File | What it owns |
| --- | --- |
| `game_screens.dart` | The start, paused and game-over screens, the pause control, the palette they share with `lib/main.dart`, and `overlaysFor` — the pure function that decides which screen is up. |
| `high_score_store.dart` | Persistence. The best run as a string, the check that re-executes it before believing it, and the two stores that hold it. |

**These files do not import `lib/main.dart`.** The screens talk to a
`GameScreenHost` — a handful of getters and four verbs — which `FlappyMiataGame`
implements. The dependency points one way, `lib/main.dart` -> `lib/ui/` ->
`lib/game/`, and that is what lets every screen be driven by a plain fake in
`test/game_screens_test.dart` with no game loop under it.

**Persistence lives here rather than in `lib/game/` because it is I/O.** Reading
a store can fail, takes time, and returns something different every run — all
three of which would stop the model being a pure function of its inputs, and the
replay system, the verified score and the fairness proof all rest on it being
one. The model produces a score; this directory stores it.

**No screen in here has been seen on hardware.** No emulator or device was
available when they were written. What is checked is the widget tree, the labels
and what the buttons call; how any of it looks and whether the pause control is
comfortable to hit are unverified.
