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
| `palette.dart` | Every colour in the game, as named `int`s, plus the pairs that have to be readable and the pairs that have to be tellable apart. Plain Dart, no Flutter. |
| `colour_math.dart` | The arithmetic behind every colour claim: WCAG relative luminance and contrast, alpha compositing, CIELAB, CIEDE2000, and the dichromat simulation. Plain Dart, no Flutter. |
| `motion.dart` | The reduced-motion setting, the decorative clock the parallax is drawn from, and the widget that reads the platform's own `MediaQuery.disableAnimations` switch. |

**Colours live in `palette.dart` and nowhere else, and that is enforced rather
than agreed.** `test/palette_test.dart` reads the source of `lib/main.dart` and
of every file in here and fails the suite on a colour literal outside the
palette. The reason is that a contrast test can only grade colours it can
enumerate: a `Color(0xFFBADBAD)` typed into a widget compiles, renders, and is
invisible to any test that walks a list. Every text/background pair is then
graded at 4.5:1 twice — once from the declared list, and once by building each
screen and walking the element tree for whatever text is really on it. See
`test/palette_contrast_test.dart`.

**`palette.dart` and `colour_math.dart` are pure Dart with no `dart:ui`.** Same
argument as `lib/game/`: `tool/palette_report.dart` runs them under a bare
`dart run` and prints the whole contrast and colourblindness table, which is
what somebody changing a colour needs and what a passing test never shows. The
`Color` conversion is one line per colour in `game_screens.dart` and
`main.dart`.

**Reduced motion is not an easy mode.** `motion.dart` stops the backdrop's
parallax and nothing else. Everything else that moves here is information — the
pipes are the course, the car is the player, the ghost is the record being
raced — and stopping any of it would be taking the game away from the player who
asked for less motion. `test/reduced_motion_test.dart` replays a proved run with
the setting on and off and requires the two to be identical frame for frame,
which is the same assertion `test/assist_test.dart` makes about assist mode and
for the same reason.

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

That applies to the colour work too, and is worth saying separately because
numbers read as certainty. The contrast ratios are exact arithmetic on the
values the app will paint with, and the colourblindness figures are a MODEL —
dichromacy, not the far commoner anomalous trichromacy, and not anybody's
experience. No colourblind player has seen this game, and neither the parallax
nor the switch that stops it has run on a device.
