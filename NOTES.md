# NOTES

Record of work actually done, one entry per completed task.

## 2026-09-01 — scaffold

Repo existed on GitHub but was empty. Scaffolded in place over the clone.

- `flutter create --org com.allen --project-name flappymiata --platforms android .`
- `flutter pub add flame` -> flame 1.38.2, pulled in ordered_set 8.0.1
- Created `lib/game/`, `lib/ui/`, `assets/images/`, `assets/audio/`, each with a
  README naming its owner. Empty directories are not tracked by git, so the
  READMEs are also what makes the layout survive a clone.
- Copied `CLAUDE.md` and the `.gitattributes` from project 1 (pins `gradlew` and
  `*.sh` to LF so a Linux CI runner will not choke on them in project 3).
- Root `README.md` carries the ownership table and the trunk-based workflow, so
  the split is visible the moment the repo is opened rather than living in chat.

Collaborator invite to @Sdav239 was already sent with write permission, pending
acceptance at time of scaffolding.

No game logic written. Scaffold only, by instruction.

### Verification and a device gotcha worth remembering

```
flutter analyze              -> No issues found! (ran in 14.5s)
flutter test                 -> 00:00 +1: All tests passed!
flutter build apk --debug    -> Built build\app\outputs\flutter-apk\app-debug.apk (144.9 MB)
adb install -r ...           -> Success
```

Two things went wrong on the emulator and neither was a code problem:

1. The emulator disappeared partway through the Gradle build, so the install
   step got `adb.exe: no devices/emulators found` even though `adb devices` had
   listed it seconds earlier. Rebuilding was unnecessary — the APK was already
   on disk. Booting the emulator and installing inside one short window worked.

   CORRECTION, 2026-09-03: this entry originally said the emulator "exited on
   its own", and treated it as an unexplained defect. It was not. The emulator
   window was being closed by hand between commands. There is no emulator bug
   here, and nobody should go looking for one. The practical lesson survives
   unchanged — build the APK first, then boot and install inside one short
   window — but the reason is that a person may close the window, not that the
   process is unstable.

2. On a cold boot the emulator restores its snapshot, and it reports
   `sys.boot_completed=1` *before* that restore has finished. An `adb install`
   plus `am start` issued in that window appeared to succeed and were then
   silently undone by the restore, which put project 1's app back in the
   foreground — and that app came back wedged, so its "isn't responding" dialog
   covered the screen. `am force-stop` on the old package cleared it.

   The lesson for the demo video: do not trust `sys.boot_completed` alone right
   after starting the emulator. Confirm with `adb shell pidof <package>` and
   `dumpsys activity activities | grep topResumedActivity` that the app you
   meant to launch is actually the one in front.

## 2026-09-01 — Task: game core physics and run state machine

**What changed.** The game rules, as plain Dart, plus a throwaway harness to
watch them run.

**Files.**

- `lib/game/game_model.dart` (new) — `RunState` enum (ready, playing, dead), an
  immutable `GameModel`, and `tick(dt)` / `flap()` / `reset()` that each return a
  new model instead of mutating. Vertical position is normalised 0.0-1.0, so the
  model never learns the screen size.
- `test/game_model_test.dart` (new) — 15 tests.
- `lib/dev/harness.dart` (new) — disposable test rig with its own entrypoint.
- `lib/dev/README.md` (new) — says plainly that this directory is throwaway.

**Design decisions.**

- Semi-implicit Euler: velocity updates before position inside `tick`. The naive
  order is not stable.
- `flap()` assigns velocity rather than adding to it. That is what caps how fast
  repeated taps can climb and is why the controls feel like Flappy Bird.
- Leaving the playfield transitions playing to dead, decided inside `tick`.
  Without it `dead` would be unreachable until obstacles exist, and an
  unreachable state cannot be tested.
- On death `y` is pinned to the bound that was crossed, so a renderer draws the
  wreck on-screen. The death is decided from the un-pinned value so pinning
  cannot hide a crossing.
- Constants: `gravity = 2.2`, `flapImpulse = -0.72`, `startY = 0.4`, in
  playfield-heights per second.

**Commands.**

```
flutter analyze                                     -> No issues found! (ran in 4.4s)
flutter test                                        -> 00:00 +16: All tests passed!
flutter build apk --debug -t lib/dev/harness.dart   -> Built app-debug.apk (160.5 MB) in 19.9s
adb install -r ...                                  -> Success
adb shell pidof com.allen.flappymiata               -> 3720
```

On device, before and after one tap:

```
state: ready    y: 0.4000  vel: 0.0000
state: playing  y: 0.3684  vel: 0.5267
```

y decreased, so the flap lifted the car; velocity is already positive again, so
gravity is pulling it back. The integration works on a real device, not only in
tests.

**What the falsifiability check found.** The implementing agent added a
structural test asserting `lib/game/` contains no clock and no randomness — the
behavioural tests can show today's code is deterministic but cannot stop a
`DateTime.now()` being added tomorrow. On its first run that guard failed on
correct code, because `game_model.dart` names `DateTime.now()` inside a comment
saying it is banned, and a raw substring scan matched the comment. Fixed by
stripping comments before scanning, then re-checked under a deliberate mutation
to confirm the guard still fires on real code. A detector that fails on valid
input is worse than no detector, and only running it against a known-bad tree
tells you which of the two you have.

**Known cosmetic issue, not fixed.** The harness readout is drawn from y=0 and
overlaps the status bar clock. It is a disposable rig; the real UI in `lib/ui/`
will not inherit this.

**Not committed.** Harness screenshots live in the session scratchpad rather than
`docs/`, because `docs/` was outside the writable paths set for this task.

## 2026-09-01 — Task: obstacles, AABB collision and scoring

**What changed.** The game became playable end to end: obstacles scroll, hitting
one kills the run, passing one scores.

**Files.**

- `lib/game/geometry.dart` (new) — `Box` with the axis-aligned overlap test and
  the `Obstacle` value type. Still plain Dart, no Flame, no Flutter.
- `lib/game/game_model.dart` — `GapPattern` typedef, obstacle constants, scroll,
  spawn, despawn, collision and scoring.
- `test/game_model_test.dart` — 15 more tests, 31 total. No existing test changed.
- `lib/dev/harness.dart` — draws obstacles and score; HUD rewritten (below).
- `lib/dev/README.md` — documents the HARNESS log line and the box stretching.
- `docs/harness-ready.png`, `docs/harness-scored.png` — evidence frames.

**Design decisions.**

- Gap positions arrive through an injected `double Function(int index)` rather
  than `Random`. Tests pass a fixed sequence and get exact, repeatable
  collisions; the harness passes a hash-based scatter that looks random and
  replays identically. Same trick as `dt`: the varying thing is a parameter.
- Each obstacle carries its own `scored` flag, so passing it can count exactly
  once no matter how many ticks follow.
- An obstacle is two boxes — the space the gap is not — so one overlap test
  covers both pipes.

Constants: `carX 0.30`, `carWidth 0.10`, `carHeight 0.05`, `obstacleWidth 0.16`,
`scrollSpeed 0.45`, `obstacleSpacing 0.60`, `gapHeight 0.28`, `gapMargin 0.08`.

**Commands.**

```
flutter analyze                                    -> No issues found! (ran in 5.3s)
flutter test                                       -> 00:00 +31: All tests passed!
flutter build apk --debug -t lib/dev/harness.dart  -> Built app-debug.apk in 18.2s
adb install -r ...                                 -> Success
```

On device:

```
HARNESS state=ready   score=0 pipes=0
HARNESS state=playing score=1 pipes=2
```

**Three things went wrong, and the third is the one worth remembering.**

1. *Tap cadence.* Driving the game needs a flap period near where one impulse
   cancels a period of gravity: `T = 2 * 0.72 / 2.2 = 0.655s`. Tapping from the
   PC costs about 300ms per `adb` round trip, so an intended 0.58s sleep was
   really ~0.9s and the car sank onto the floor every run. An earlier on-device
   loop was faster than hover and flew into the ceiling. Fixed by tapping
   on-device in a separate process and sweeping cadences; 0.55s scored.

2. *The HUD was painted underneath the obstacles.* The harness called
   `super.render(canvas)` and then drew the world on top, so a pipe crossing the
   readout hid the score entirely. Fixed by splitting into a world layer and a
   HUD layer with explicit priorities, and giving the HUD an opaque backing
   panel — ordering alone would still leave white text on bright green.

3. *The score detector was measuring the wrong thing.* To confirm scoring
   without reading digits off an image by eye, a script compared the framebuffer
   rectangle holding the "score:" text against its score-0 baseline. It fired —
   and it was wrong. The rectangle had changed because a pipe had scrolled over
   it. Obstacles traverse every x, so no on-screen region is safe from that, and
   the detector could not distinguish "the score changed" from "something drew
   on top of the score".

   Fixed by making the harness emit `HARNESS state=… score=… pipes=…` to the log
   on change, and verifying against that line instead. The lesson is not about
   Flame: a detector that can fire for a reason unrelated to what it claims to
   measure will eventually do so, and the run where it fires is the run you
   believe it. Reading a number beats inferring one from pixels.

## 2026-09-03 — Task: wire the game model into the real entrypoint

**Why.** `lib/main.dart` drew a text label and never imported `lib/game`. The
game existed only behind the dev harness entrypoint, so `flutter run` produced
nothing playable and there was no stable app to test new components against.

**What changed.** `lib/main.dart` only.

- Ticks the model from Flame's `update(dt)`.
- Tap flaps while ready or playing, and resets when dead.
- Draws the car and obstacles from the model's own boxes, converting normalised
  0..1 coordinates to pixels at render time.
- Score on a HUD layer above the world, on an opaque backing.

Deliberately plain — flat colours, rectangles, no sprites, no menus. `lib/ui/`
is untouched so the real UI has somewhere to go.

**Commands.**

```
flutter analyze                       -> No issues found! (ran in 4.3s)
flutter test                          -> 00:00 +31: All tests passed!
flutter build apk --debug             -> Built app-debug.apk in 15.6s
adb install -r ...                    -> Success
adb shell pidof com.allen.flappymiata -> 8083
```

On device the default entrypoint reached `score: 1` under a scripted tap loop at
a 0.55s cadence. Frames in `docs/app-ready.png` and `docs/app-playing.png`.

**The one thing carried over from the harness on purpose.** The score renders on
a HUD layer with an explicit priority and an opaque backing. Obstacles scroll the
full width of the screen, so there is no safe corner — anything drawn under them
is covered periodically. The harness hit this because it painted the world after
`super.render`, which no component priority can fix. Repeating the fix here was
cheaper than rediscovering the bug.

**What was left out, deliberately.** The harness's debug readout (y, velocity,
dt, pipe count), its `HARNESS` log line, the kill-line markers and the
scored-pipe dimming. Those are instrumentation for watching the model, not part
of the app.

**Backend status: framework complete, not closed.** Physics, state machine,
obstacles, collision and scoring all work and are covered by 31 tests. Not
present: high-score persistence, a difficulty ramp, pause, and sound hooks. None
of those are required for this project.

## 2026-09-03 — Phase 1: merge sprite UI, fix the sprite/hitbox mismatch

Start of an open-ended quality pass. Project 2 is already submitted; none of
this is on a deadline.

**Merged.** `sprite-ui` (@Sdav239) into trunk: pixel Miata sprite, parallax
background, capped pipes, styled score panel.

**The bug.** The car drew about three times wider than the box that kills you.
Measured on a 1080x2400 screen:

```
hitbox        108 x 120 px      carWidth 0.10, carHeight 0.05
drawn rect    339 x 226 px      1.885 x hitbox height, image aspect 1.5
visible car   316 x 132 px      the PNG was 45.4% transparent padding
                                -> width 2.93x the hitbox, height 1.10x
```

Height was always about right; a ~10% margin is the convention. Width was the
whole defect: the nose and tail passed through pipes without dying.

**Root cause, which was not the magic number.** `_toPixels` scales normalised x
by screen width and y by screen height independently. So a box of 0.10 x 0.05 is
108 x 120 px here — aspect 0.9, nearly square — while the car is aspect 2.383.
No single scale factor reconciles those. The hitbox's *shape* silently depended
on the device's aspect ratio, and nothing said so.

**Fix.** The dependency is now named and derived rather than implied:

```dart
static const double referenceAspect = 2400 / 1080;   // the frame boxes mean
static const double carSpriteAspect = 286 / 120;     // the sprite's own pixels
static const double carHeight = 0.031;
static const double carWidth  = carHeight * referenceAspect * carSpriteAspect;
```

carWidth comes out at 0.164185 — a hitbox of 177.3 x 74.4 px at the reference
aspect, the same shape as the sprite, and within 1.8% of the old hitbox's *area*
so difficulty did not jump. The renderer draws the sprite into that box inflated
by 1.10, making the hitbox ~91% of the visible car.

**Assets.** `miatasprite.png` was cropped to its opaque bounds and downscaled
5x with a premultiplied box filter, then re-encoded with per-row adaptive PNG
filtering: 1536x1024 and 1034 KB became 286x120 and 37 KB, 96.4% smaller, with
the aspect ratio preserved exactly. `mario2.png` was deleted — 875 KB, zero
references anywhere in the repo.

**Debug overlay.** New, off by default behind `kShowCollisionBoxes`. Draws the
car's hitbox, both obstacle boxes and each gap centre. It exists because this
bug took pixel measurement off a screenshot to find, and would have taken ten
seconds to see.

**Verified on device, not asserted.** With the overlay on, the rendered hitbox
measured 182 x 80 px against a computed 177.3 x 74.4. The difference is the
outline stroke, which is centred on the box edge and so adds about 5 px to each
dimension; subtracting it lands exactly on the computed size.

**Where a number stood in for taste.** `carHeight = 0.031` was chosen to hold
the hitbox *area* roughly constant, not because 0.031 feels right. The danger
window grew from 0.578s to 0.720s as a result. Phase 2's simulator measures
whether that is actually harder; until then it is an assumption.
