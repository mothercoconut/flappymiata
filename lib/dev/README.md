# lib/dev — disposable test harness

**This is not the game's UI. It is scaffolding, and it is meant to be thrown
away.**

`lib/game/` is deliberately pure Dart — no Flame, no Flutter, no pixels. That
makes the rules fast to test but impossible to look at, and numbers like gravity
and the flap impulse can only really be judged by feel. `harness.dart` is the
crudest possible screen for judging them: a rectangle drawn from the model's
normalised `y`, the live state/`y`/velocity printed as text, and taps wired to
`flap()` and `reset()`.

Run it:

    flutter run -t lib/dev/harness.dart

It has its own `main()` on purpose, so trying the physics never means editing
`lib/main.dart` — the one file both people in this repo have to touch.

## Where the real UI goes

`lib/ui/` — screens, menus, HUD, input handling, anything that draws for real.
**That directory is owned by a teammate. Do not build the game's UI in here.**
Nothing in `lib/dev/` should be treated as a design, a pattern to follow, or
code to move across; it is a probe, not a prototype.

## Deleting this

Once `lib/ui/` renders the model on screen, **delete `lib/dev/` wholesale** —
both files, the whole directory. Nothing else imports it: `harness.dart` is
reachable only via `-t`, so removing it cannot break the app, the tests, or the
build. If it is still here after the real UI ships, that is an oversight, not a
dependency.
