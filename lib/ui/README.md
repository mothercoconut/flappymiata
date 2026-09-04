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
| `assist.dart` | Assist mode's solver. Works out where the flap window for the next obstacle is, by running the fairness prover's reachability search BACKWARDS over a bounded horizon. Plain Dart, no Flutter — it returns numbers and draws nothing. |

**`assist.dart` is in here because it is a display aid, and that is a rule and
not a filing decision.** It reads a `GameModel` and returns some numbers; it is
never called by `tick`, it is never on the path from a tap to a position, and it
cannot be. A run played with assist on and the same run played with it off are
the same run — `test/assist_test.dart` asserts exactly that, frame for frame —
which is what keeps the replay system, the verified score and the fairness proof
true. If assist could reach the model, "the same taps" would stop describing the
same run.

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
