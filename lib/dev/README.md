# lib/dev — disposable test harness

**This is not the game's UI. It is scaffolding, and it is meant to be thrown
away.**

`lib/game/` is deliberately pure Dart — no Flame, no Flutter, no pixels. That
makes the rules fast to test but impossible to look at, and numbers like gravity
and the flap impulse can only really be judged by feel. `harness.dart` is the
crudest possible screen for judging them: rectangles drawn from the model's own
collision boxes, the live state/score/`y`/velocity printed as text, and taps
wired to `flap()` and `reset()`.

Run it:

    flutter run -t lib/dev/harness.dart

It has its own `main()` on purpose, so trying the physics never means editing
`lib/main.dart` — the one file both people in this repo have to touch.

## What is on screen

* **Red rectangle** — the car, drawn as its *collision box*, not as a sprite.
  If it is not touching a green rectangle, the model agrees it is not touching
  one.
* **Green rectangles** — the two pipes of each obstacle, drawn straight from
  `Obstacle.topBox` and `Obstacle.bottomBox`. Dimmed green once that obstacle
  has paid out its point, so scoring can be watched happening rather than
  inferred from the counter jumping.
* **Text block** — state, score, `y`, velocity, the frame's `dt`, and how many
  obstacles are currently on the playfield.

The text starts 48 logical pixels down rather than at the top edge. Drawn from
`y = 0` it sits underneath the status bar clock on a phone and the two overlap
into an unreadable smear.

## Known distortion: the boxes are stretched

**This is expected. Do not file it as a bug.**

The model is normalised on *both* axes: x runs 0.0–1.0 across the playfield and
y runs 0.0–1.0 down it. The harness turns those into pixels the only way it can
without knowing anything else — multiply x by the screen width and y by the
screen height. Those are two different numbers on any screen that is not square,
so a shape that is square in model coordinates is drawn as a tall rectangle on a
phone held upright.

Concretely: the car's box is 0.10 wide by 0.05 tall in model units, a 2:1
landscape rectangle. On a 1080x2400 handset it is drawn 108 px by 120 px —
almost square, and visibly the wrong shape.

Nothing is wrong with the model. Collision, scoring and every test operate in
normalised coordinates and never see a pixel, so the stretch is purely in this
file's `_toPixels`. It is accepted here because the harness exists to answer
"does the car pass through the gap?", which the distortion does not affect: both
the car and the pipes are stretched by the same two factors, so what overlaps on
screen is exactly what overlaps in the model.

The real UI in `lib/ui/` will have to decide this properly — letterbox to a
fixed aspect ratio, or scale both axes by the same factor and accept bars. That
is a design decision, and it is not this rig's to make.

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
