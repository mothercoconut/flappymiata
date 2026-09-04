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

**Merged.** `sprite-ui` (@Sdav239) into trunk: pixel Miata sprite, layered
background, capped pipes, styled score panel.

CORRECTION, 2026-09-04: this said "parallax background". It was not parallax —
the backdrop was static. Nothing moved until the reduced-motion work added
real parallax so that the toggle had something to switch off. I wrote the
original line from the branch's own commit message without checking what it
drew.

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

## 2026-09-03 — Phase 2: headless simulator and a fairness proof

**Bar 1 closed.** Every course the game can generate is provably clearable.

**Files.** `tool/headless_sim.dart`, `tool/fairness.dart`, `tool/simulate.dart`,
`tool/prove_fairness.dart`, `test/headless_sim_test.dart`,
`test/fairness_prover_test.dart`. `lib/game/` unchanged — the prover needed
nothing exposed. No dependency added.

**Why not just play it a lot.** Sampling policies can show a course IS
survivable; it can never show one is not. "No policy I tried worked" reported as
"unfair" would be a guess. So the prover does a reachability search: advance
frame by frame carrying the SET of reachable non-colliding states, branching each
on flap/no-flap. Empty set before the course ends means no input sequence
survives it.

**The insight that makes it cheap.** `flap()` ASSIGNS velocity instead of adding
to it. So after any flap velocity is exactly `flapImpulse`, and between flaps it
is determined by frames elapsed. State is `(y, framesSinceFlap)`, not `(y, any
velocity)`. Better still, reachable y values land on an exact lattice of spacing
`gravity * dt^2 = 6.1111e-4`, so nothing is rounded at all — the state is two
integers. That lattice is 19.6x finer than the largest one-frame move
(`|flapImpulse * dt| = 0.012`), which is the resolution a grid would have needed
just to avoid stepping over a pipe lip.

**Which way it errs.** Survival tests demand 1e-9 of clearance, six orders finer
than a lattice cell and four coarser than float noise. The prover can call a fair
course unfair; it cannot certify an unfair one.

**The prover was made to fail before it was trusted.**

```
pinhole            gap 0.020 vs car 0.031    UNSURVIVABLE  gapNarrowerThanCar
zigzag             0.22 -> 0.78 in 0.36      UNSURVIVABLE  unreachable
above-the-ceiling  gap centred at y = -0.20  UNSURVIVABLE  gapOutsidePlayfield
overlap-clash      extremes 0.20 apart       UNSURVIVABLE  overlappingGapsDisjoint
wide-open          one centred full gap      SURVIVABLE, witness replayed
```

Each is impossible for a different reason and the prover names the mechanism,
not just the verdict. A second, independent hash-set search agrees on all five.
The `wide-open` witness is not a claim: 116 frames and 26 taps replayed through
the real `GameModel` and survived with score 1.

**The check that found a wrong assumption.** The single-obstacle survivability
threshold is NOT `carHeight`. An obstacle straddles the car for 43 frames and
gravity does not pause during them, so the gap must admit the car plus the
flattest 43-frame trajectory that exists:

```
flattest 43-frame excursion   0.086889
threshold must be             0.117889 = carHeight + excursion
prover flips at               0.118111   (within one 6.111e-4 lattice cell)
```

That expectation was wrong when first written and the check caught it; the
expectation was fixed, not the prover. It is now the strongest test in the suite
precisely because it pins the answer to a number computed outside the prover,
and lands nowhere near 0.031 — where a prover that only asked "does the car fit
through the hole" would flip.

**Results.**

```
10000 windows of 3 obstacles   PASS 10000  FAIL 0
worst course #4186             gaps 0.775, 0.227, 0.633
tightest margin                0.06021 playfield-heights (1.94 car-heights)
continuous 10000-obstacle run  SURVIVABLE, 800036 frames, peak 51124 states
bottleneck                     obstacle 4187 (0.227) -> 4188 (0.633)
12930 searches                 107.6 s
```

Both methods agree on the same bottleneck. Margin means: how much fatter the car
could be, on every side, with the course still clearable.

**Gate.** `test/fairness_prover_test.dart` runs 400 windows plus a continuous
150-obstacle run, about 2s of the suite. The full 10,000 stays
`dart run tool/prove_fairness.dart`.

**Known limits, stated rather than buried.** `minimumExcursion` searches patterns
of at most 2 flaps, so it is an upper bound — the safe direction. Margin is
measured to pipes only, not to the playfield edges, so a path that survives by
hugging the ceiling would not show up in that number. Exactness is in real
arithmetic; the 1e-9 epsilon is a well-founded argument that float drift cannot
flip a verdict, not a proof about IEEE doubles.

## 2026-09-03 — Phase 3a: mutation testing to 100%

**Bar 2 closed.** Every single-point mutant of `lib/game/` is killed by a test.

**Files.** `tool/mutate.dart`, `test/tuning_constants_test.dart`,
`test/model_boundaries_test.dart`. Tests 57 -> 82. `lib/game/` unchanged — the
score was not reached by editing the code under test.

**Result.**

```
mutants generated & run     410
invalid (did not compile)    23   neither a kill nor a survivor
equivalent (argued)           4   excluded from the denominator
killed                      383   of which by timeout: 0
survived                      0
mutation score  383 / 383 = 100.0%     (83.7% before the new tests)
```

**Why the invalid ones are excluded from both sides.** A mutant that never
compiled ran no test, so counting it as a kill is a free win nothing earned — a
suite asserting nothing at all would collect every one of them. Sixteen of the
23 are `&&` -> `||` inside `other is X && other.field == field`, where losing
the type promotion stops it typechecking.

**What the 63 survivors actually revealed.** Not sloppiness — a systematic gap.
Twenty-four were in the gap-pattern hash: every multiplier, mask and shift could
change and the suite stayed green, because the tests asserted only *properties*
(in range, distinct, pure) that a huge family of different hashes satisfies.
Killed with golden values and an independent re-implementation of the documented
finaliser. Another twenty-four were tuning constants surviving a 10%
perturbation, because every assertion was written in terms of the constant
itself — `closeTo(GameModel.gravity * frame, ...)` passes for any gravity.
Killed with absolute, game-facing assertions: half a second of falling adds
exactly 1.1; pipes stand exactly 0.60 apart.

That is the lesson worth keeping. A test written in terms of the constant it is
testing cannot detect a change to that constant.

**Five boundary survivors** differed from the original on exactly one input —
the one where two doubles are equal. Killed by solving the physics for that
exact double and walking neighbouring representable values until the model
landed on the line.

**Four equivalent mutants, argued individually.** Two `clampGapCentre` boundary
cases where the original returns `centre`, which IS the clamp bound by the
equality that selected the branch; one ternary whose equality case is
unreachable under its guard; and `minY = playfieldTop` -> `0.0`, where
`playfieldTop` is itself `const 0.0`, so after const evaluation the two programs
are literally identical. An unargued exclusion is a hidden survivor.

**Proof the tool is not lying.** `--selftest` runs three controls: a
behaviour-changing edit judged by tests that cover it comes back KILLED; the
SAME edit judged only by `widget_test.dart`, which never ticks the model, comes
back SURVIVED; and a syntax error comes back INVALID. The negative control is
the load-bearing one — it rules out a tool that reports KILLED unconditionally.
Additionally the 8-worker sandboxed run and the single-worker in-place run agree
verdict-for-verdict on all 406 mutants.

**A bug found in the harness itself.** A Dart `Future<int> main()` silently
discards its return value, so the exit code was always 0 — a CI gate that could
not fail. Found and fixed before CI was built on top of it. Also: an external
process reading the mutated file caused a Windows file-lock failure in the
restore path at mutant 73, briefly leaving `lib/game/` mutated. Restore now
retries; a failed restore is the worst thing this tool can do.

**Runtimes.** Full 410 mutants: 1265s single-worker, 345s with `--jobs=8`.
`--quick` (54 stratified mutants for CI): 165s, ~30s parallel. Self-test: 13s.

## 2026-09-03 — Phase 3b: CI that can actually fail

**Bar 3.** `.github/workflows/ci.yml`, five parallel jobs on `ubuntu-latest`,
triggered on push to `main`, PRs, and manual dispatch. Flutter pinned to 3.47.2
rather than `latest`, so CI cannot drift out from under the project.

```
Gate 1  static-analysis    flutter analyze
Gate 2  unit-tests         flutter test                    (82 tests)
Gate 3  android-build      flutter build apk --debug
Gate 4  fairness-proof     dart run tool/prove_fairness.dart
Gate 5  mutation-testing   dart run tool/mutate.dart --selftest
Gate 6  mutation-testing   dart run tool/mutate.dart --quick --jobs=2
```

Gates 5 and 6 share a job deliberately: `--quick`'s report only means anything
if `--selftest` has just shown the classifier can still say SURVIVED.

**Every gate was proven able to fail, locally, before being trusted.** A CI file
that is green because its steps cannot fail is worse than no CI. Each gate was
run green, broken, run red, restored, and run green again:

```
1  analyze   String returned from an int function        exit 1
2  test      gravity 2.2 -> 2.3                          exit 1
3  build     call to an undefined method                 exit 1
4  fairness  gapHeight 0.28 -> 0.15                      exit 1  (448 courses unsurvivable)
5  selftest  widget_test given an assertion on gravity   exit 1  (NEGATIVE control flipped to KILLED)
6  quick     untested helper appended to geometry.dart   exit 1  (2 survivors, at the predicted lines)
```

Two of those failed *attributably* rather than by cascade. Gate 4's break left
the prover's five impossibility controls and its physics flip-point check all
passing — only the shipped pattern went red. Gate 5's break flipped exactly one
of three controls, POSITIVE and INVALID unchanged; the self-test's
discriminating power is precisely what it exists to assert.

**Exit-code propagation, measured rather than assumed.** This project was
already bitten once by a gate that could not fail, so all four shapes were run
on Dart 3.13.2:

```
Future<int> main() async => 1;                 exits 0    <- the hazard
int main() => 1;                               exits 0    <- ALSO the hazard
Future<int> main() async { exitCode = 1; ... }  exits 1    <- mutate.dart
void main() { exit(1); }                       exits 1    <- prove_fairness.dart
```

The second row corrects a comment in `tool/mutate.dart` which claimed a
synchronous `int main()` was safe. It is not; Dart ignores main's return value
entirely. The code was already correct, only its stated reason was wrong — and a
comment that licenses a broken pattern is how the bug comes back.

**A worry that turned out fine.** `android/.gitignore` excludes `gradlew`,
`gradlew.bat` and `gradle-wrapper.jar`, and `settings.gradle.kts` requires
`flutter.sdk` from the gitignored `local.properties` — so a fresh CI checkout has
none of them. Tested by rebuilding a gitignore-accurate clean checkout and
building there: exit 0. The Flutter tool injects `gradlew` at mode 755, injects
the wrapper jar, and regenerates `local.properties` from `ANDROID_HOME` and
`FLUTTER_ROOT`.

**Not verified locally, and stated rather than assumed.** Linux exit-code
propagation through the shell wrappers; the marketplace actions themselves;
whether a 2-core runner tolerates `android/gradle.properties` asking Gradle for
`-Xmx8G` against ~7 GB of RAM. The workflow carries a comment on how to lower it
from `~/.gradle/gradle.properties` without editing the file the other developer
shares.

## 2026-09-04 — Phase 4: deterministic replay, run codes, verified scores, daily challenge, ghost

**Bar 4 closed.** A run is fully described by a seed plus an input timeline and
replays frame-exactly.

**New in `lib/game/`** — still pure Dart, no Flame, no Flutter, no clock, no
randomness: `course_seed.dart` (seeded gap patterns; seed 0 is bit-for-bit the
shipped hash, plus `dailySeed`), `replay.dart`, `run_code.dart`,
`verified_score.dart`. Tests 82 -> 167.

**Replay proof.** 33 recorded runs — 8 seeds x 5 policies — 15,497 frames
compared per pass, shortest 36 frames, longest 3000, 10 distinct scores, both
death modes, all three run states. Equality is asserted per frame on the whole
model, not on the endpoint, and `ReplayPlayer` is cross-checked frame-for-frame
against the independent `tool/headless_sim.dart`.

**Run codes.** Crockford base32 over LEB128 delta varints with a CRC-32.
A 30-second run on the shipped course is **151 characters**; a long run is 372.
Length tracks taps, not survival — one byte per tap plus an 8-byte frame.

All **4,681** single-character substitutions of one code were tried: 4,653
rejected on checksum, 28 on padding, and **0 decoded to a different run**. The
CRC is pinned to the standard's own check value (`123456789` -> `0xCBF43926`).

**Verified scores — a cheat-proof leaderboard with no server.** Determinism
means a claimed score is re-executable. Rejects a tampered timeline (all 85
single-tap deletions checked), an inflated claim on an honest run, and someone
else's valid code submitted under your claim. Corruption reports
`unreadableCode` rather than `scoreMismatch` — the distinction the checksum buys.

**Daily challenge.** The date is passed IN; `lib/game/` never reads a clock.
Same date gives an identical course, different dates differ, and every daily
course is proven fair by the *existing* prover: **731 dates** across 2024-2025,
all survivable, tightest margin 0.06851 on 2024-08-13.

**Mutation surface grew 410 -> 1225.** 19 survivors appeared in the new code:
7 killed by tests, 6 removed by restructuring so the comparison could
discriminate at all, 6 argued equivalent with both a written proof and an
empirical check. Back to 0.

### Three bugs found in the tooling itself, all the same shape

**1. `tool/mutate.dart` exited 255 on a clean run.** Sandbox teardown ran before
the report and threw on a transient Windows file lock, so a green codebase
produced a red gate with no diagnosis at all. Cleanup is housekeeping; the
verdicts are the product. Teardown now retries, warns, and can never suppress
the report or the exit code.

**2. Fixing that exposed a hang it had been masking.** `flutter test` leaves a
`flutter_tester` grandchild holding the pipe, so with the throw gone the VM
printed its whole report and then sat there forever. The crash had been acting
as the exit path. `main` now flushes and calls `exit`.

**3. `--selftest` was already failing before any of this.** Its NEGATIVE control
depends on a test file that CANNOT see a model change; `widget_test.dart` had
grown tests that tap and run 120 frames, so it could. The control returned
KILLED where SURVIVED was required — meaning the next CI run would have gone red
on gate 5. The judge moved to `car_geometry_test.dart`, which compiles the
mutated file but asserts only on box shape, and was proven non-vacuous.

That third one is the lesson. The self-test's blind judge is only blind by
accident of what that file happens to assert, and nothing stops a future test
from giving it sight. The drift will recur.

**`--quick` retuned.** `ceil(size/8)` per operator family scaled with the
codebase, so the CI subset went 52 -> 154 mutants and 670s. Replaced with a
fixed budget of 52 apportioned by highest-averages with a floor of 2 per family.
Measured 163-238s locally at `--jobs=4`. Traded away sampling density: a hole
had roughly a 1-in-8 chance of being sampled, now about 1-in-24, and it thins
further as `lib/game/` grows. The header prints `52 of 1225` so the next person
to grow the directory sees the ratio. The full run is unchanged and still grades
the suite.

**CI labels de-staled.** "Gate 2 - all 82 tests pass" became "the whole test
suite passes" — a property, which cannot go stale, rather than a number that
already had.

**Unverified.** The ghost car's appearance on hardware: colour, legibility over
the pipes, whether it reads as a ghost at all. Only the wiring is tested — it
exists, advances in lockstep, and its positions are ones the recorded run really
visited. Best-run persistence is in memory only; on-disk needs a storage package
and none was added.

## 2026-09-04 — CI died with SIGTERM; the fix was a missing ceiling

The first CI run carrying Phase 4 failed on gates 5+6, killed with **exit 143**
two minutes into a job with a 45-minute timeout, after 7 of 50 mutants, with 26
seconds of unexplained silence before death. It passes locally at `--jobs=4` in
195s. The runner's own last line: `Terminate orphan process: pid (3804)
(dart:flutter_to)`.

**The fact that pointed at the answer.** 143 is SIGTERM. The Linux OOM killer
and `systemd-oomd` both use SIGKILL, which surfaces as **137**. So this was not
memory exhaustion — something *asked* the process to stop.

**The bug.** In `runTests`, the `.timeout()` was applied to `proc.exitCode`, and
the very next line awaited `Future.wait([outDone, errDone])` with no ceiling at
all. `flutter test` spawns a `flutter_tester` grandchild that INHERITS those
pipes, and a pipe stays readable until every holder of its write end is gone. So
once the direct child exited and the grandchild was orphaned, nothing covered
that wait. The tool had a timeout on the part that could not hang and none on
the part that did.

`main()` already carried a comment recording this exact symptom being observed
before — "printed its entire report at 201s and was still resident ten minutes
later" — and the fix at that time addressed only the program's final exit, never
the per-call wait. The same bug came back one level down.

**Fixed.** The drain is bounded. `_killTree` replaces `proc.kill()`: `taskkill
/T /F` on Windows, and on POSIX a `ps`-derived parent map walked DEEPEST-FIRST,
because killing a parent first *creates* the orphan and reparents it beyond
reach. A post-run sweep matches the sandbox marker on both argv and
`/proc/<pid>/cwd`, since only `flutter_tester` carries the sandbox in its
arguments.

**Instrumented rather than guessed at.** The job now prints memory, disk, the
filesystem backing the temp dir, and a process count before and after; samples
resources every 3s to a file; and prints a post-mortem `ps` sorted by RSS on
failure. The tool emits a heartbeat naming every in-flight mutant and its age.

That instrumentation paid for itself before reaching CI. A local run showed:

```
[hb] +02:30  done 8/50  inflight: REL232 (120s), REL283 (89s)
[   9/50] REL232  KILLED(t/o)  lib/game/run_code.dart:317:12  REL  '>=' -> '<'
```

`REL232` is a genuine infinite loop — a decode-loop comparison inverted. Without
the heartbeat that is indistinguishable from "the tool hung"; with it, the stuck
mutant names itself.

**Deliberately NOT changed: `--jobs=2`, `--timeout=180`, budget 52.** Lowering
`--jobs` costs zero detection power — the subset is fixed integer arithmetic, and
each worker judges its own mutant in its own sandbox, so job count moves wall
clock and nothing else. Which is exactly why it must not move in the same commit
as the instrumentation: a green run would then teach nothing about which change
fixed it. The release condition is written into the workflow.

**Detection power given up, stated plainly.** A genuine SURVIVOR whose output is
truncated by the now-bounded drain is misfiled as INVALID, which could hide a
hole in the suite. It fails safe — truncation cannot manufacture a kill, since
that needs `Some tests failed.` or a non-zero exit, and losing bytes adds
neither. Affected mutant ids are listed with a warning. The alternative was
hanging forever and reporting nothing.

**A measurement error of my own, for the record.** My first verification run
reported exit 255 and looked like a tool bug. It was `Select-Object -First 12`
terminating the PowerShell pipeline, which closes dart's stdout and kills it.
The tool was fine; the measuring instrument was not.

### The runner was thrashing, and MemAvailable hid it

The instrumented run (fa8254b) failed too, but this time it explained itself:

```
KILLED BY SIGTERM after 01:46
  pressure/memory: some avg10=64.23  full avg10=60.63
  MemAvailable 8950340 kB , SwapFree 1224180 kB
  machine: 4 cores, MemAvailable 14227732 kB, /tmp is ext4
##[error]The operation was canceled.
```

`full avg10=60.63` means the whole machine was stalled waiting on memory for 60%
of the preceding ten seconds. Swap fell from 3145724 kB free to 1224180 kB —
about 2 GB pushed out. GitHub's runner then cancelled the job. That cancellation
is who sent the SIGTERM.

Two concurrent `flutter test` trees, each compiling the suite, is more than a
4-core hosted runner carries. `--jobs=1` in CI. It costs wall clock and nothing
else: the subset is fixed integer arithmetic and each worker judges its own
mutant in its own sandbox, so job count cannot change a verdict.

**The release condition written into the workflow watched the wrong numbers, and
that is the part worth keeping.** It said to lower `--jobs` if `memavail_kb` fell
toward a few hundred megabytes or if `dartprocs` accumulated. Neither happened —
MemAvailable was still 8.9 GB at the moment of death and the process count only
drifted 163 to 171. MemAvailable counts reclaimable page cache, so it stays
comfortable right up until the machine is thrashing to keep it that way. The
number that actually showed the fault was `pressure/memory`, which the sampler
collected only because it was cheap to add.

A threshold chosen in advance is still a guess. This one was wrong in the safe
direction — the instrumentation was broad enough that the real signal was in the
log anyway — but it would have been just as easy to collect only the numbers the
hypothesis predicted, and then read a clean log as evidence of nothing wrong.

Also ruled out by the same log, at no extra cost: `/tmp is ext4`, so the sandbox
copies were never charged to RAM as a tmpfs; and `drain stalls so far: 0`, so the
bounded-drain fix was not itself firing.

### It was one mutant, allocating 25 GB

`--jobs=1` failed too, with *higher* memory pressure than `--jobs=2`
(`full avg10=69.97`). So parallelism was never the cause. The process table at
death showed nothing large — biggest was the tool itself at 82 MB, under 200 MB
in total — while `MemAvailable` had fallen from 14.2 GB to 5.7 GB. Something was
eating the machine and it was not in the table, because the runner cancelled the
job before the snapshot.

Both failures died with the same mutant in flight: **REL232**, at 42s and 38s.
Measured locally on a 31 GB machine:

```
t=  8s   dart+tester RSS = 20851 MB   system free =    5 MB
t= 56s   dart+tester RSS = 25664 MB   system free =  416 MB
peak                       25664 MB
```

`REL232` is `'>=' -> '<'` at `run_code.dart:317`, inverting a decode loop's
bound so it allocates without limit. **25 GB from one mutant.** This box has the
RAM to thrash through it and reach the 180s timeout; a 16 GB runner does not,
and dies in about 40 seconds. `--jobs=1` made it *worse* because with one worker
REL232 starts sooner.

**The gap: the tool had a time limit and no memory limit.** Turning a bounded
loop into an unbounded allocation is an ordinary thing for a mutation tester to
produce. It has to survive one.

**Fixed with a per-mutant memory ceiling**, `--max-rss`, default 4096 MB,
measured over the whole process tree because the runaway lives in the
`flutter_tester` grandchild. Chosen against data, not taste:

```
ordinary mutant, tier 1        1229, 1253 MB
ordinary mutant, tier 2        1769, 1810 MB
ceiling                        4096 MB          2.3x the worst honest case
REL232 unbounded               >25000 MB
```

Result: REL232 now dies in **5.3s** instead of 180s, caught at 11223 MB.
Every other verdict in the `--quick` subset is byte-identical to before —
diffing the verdict lines shows exactly one changed line, REL232 moving from
`KILLED(t/o)` to `KILLED(mem)`. A memory kill counts as a kill but is reported
separately and labelled weak evidence, in the same terms as a timeout: it says
"did not fit", not "asserted wrong".

Every run now prints its own margin — `the hungriest mutant that was NOT
memory-killed peaked at 1402 MB, leaving 2694 MB of headroom` — so the ceiling
is re-measured continuously rather than justified once in a comment and left to
rot.

`--selftest` gained a fourth control: healthy source under a forced 1 MB ceiling
must return `KILLED(mem)`, while the existing three run at the real ceiling and
none may be memory-killed. The guard is two-sided by construction.

**An adaptive sampler was written, measured, and deleted.** It sampled 8x faster
above half the ceiling; against REL232 it never once engaged, because the tree
goes from under 2 GB to over 13 GB inside a single interval. Unobserved code
with an unmeasured cost.

**Known limit.** Every overshoot figure above is a Windows number, inflated by a
2-second sampling gap (one CIM query costs 266 ms). Linux samples every 250 ms
via `ps`, so the same runaway should be caught nearer 5 GB. That is a design
expectation and the runner is the first place it is ever tested. If the POSIX
path is broken the failure is loud: the header says the ceiling cannot be
enforced and `--selftest` exits 1.

## 2026-09-04 — Phase 5a: screens, persistence, and a difficulty ramp that had to be proven

**Files.** New `lib/ui/game_screens.dart`, `lib/ui/high_score_store.dart`,
`tool/ramp_probe.dart`, three test files. Modified `lib/game/game_model.dart`
(adds `Difficulty`), `lib/main.dart`, both `tool/fairness.dart` and
`tool/prove_fairness.dart`. Tests 167 -> 230.

**Dependency added: `shared_preferences ^2.2.0`.** Storing a score needs a
writable directory that survives an app update, and finding it on Android means
a platform channel — so "just write a file" is `path_provider` plus encoding,
atomic writes and corrupt-file handling. Without it the best score would have
stayed in memory, as before. `lib/game/` does not import it, and a test enforces
that by reading the sources.

The best run is stored as a **run code plus a claimed score**, and `load()`
re-executes it through `verifyRunCode`. An edited number is rejected, and a
record made before the ramp changed what those taps score is dropped rather than
left as an unreachable target. That gives Phase 4's verified-score work its
first production caller.

**Pause needs no clock.** `update` simply stops asking the accumulator for
steps, so the immutable model is untouched and paused seconds are never banked.
A test pumps 300 paused frames and asserts the model equals
`before.tick(1/60)` — one frame of physics from exactly where it stopped.

### The ramp had to be proven, and the first one I wanted was unfair

Driven by obstacles passed. Warm-up 0-10, ramps over 40, plateaus at obstacle
50. `scrollSpeed` 0.450 -> 0.480, `gapHeight` 0.280 -> 0.252, spacing unchanged.

Fairness at and beyond the plateau:

```
5000 windows from obstacle 50      0 unsurvivable, worst 0.04132 (1.33 car-heights)
5000 windows from obstacle 5050    0 unsurvivable, worst 0.04110 (1.33)
continuous 0 -> 10000 through ramp SURVIVABLE, tightest 0.03550
continuous 0 -> 25000               SURVIVABLE, tightest 0.03169 (1.02) at obstacle 16760
120 daily courses from obstacle 50 0 unsurvivable, worst 0.05449 (1.76)
```

Worst-case margin was 1.94 car-heights before the ramp; it is 1.33 now. The game
is measurably harder.

**Three candidate plateaus were rejected because the prover found walls:**

```
speed 0.6     gap 0.21   spacing 0.6    WALL at obstacle 25
speed 0.5625  gap 0.22   spacing 0.6    WALL at obstacle 1728
speed 0.54    gap 0.23   spacing 0.54   WALL at obstacle 370
shipped: speed 0.48 gap 0.252 spacing 0.6   - no wall
```

Obstacle 1,728 is about six minutes into a run. The game becomes literally
impossible there — not hard, impossible — and no playtest reaches it. That ramp
would have shipped. `prove_fairness` PART 6 now re-runs all three rejected
candidates on every CI run and **fails if any of them starts passing**. That is
a regression test against a design mistake rather than a code one.

Spacing was left constant as a consequence: with speed already raised,
tightening spacing subtracts twice from the same budget — the free air that a
worst-case climb from a low gap to a high one is paid out of.

**Mutation.** 3 survivors appeared, all in `Difficulty.rampFraction`. One killed
by an `isNegative` assertion (`0.0` -> `-0.0` is invisible through the ramp but
visible on the fraction). Two argued equivalent: a clamp whose guard and formula
agree at the boundary cannot distinguish `<=` from `<`, checked over 200,001
values comparing raw IEEE-754 bit patterns, with a poisoned control that
differed at 100,011. Back to 0 survivors.

**Verified on a cold-booted emulator**, after the previous instance wedged its
System UI — every device check earlier in this session ran on an emulator that
had been up for hours through several memory-exhaustion events, so this one was
started clean rather than trusted. Screens in `docs/screen-start.png` and
`docs/screen-game-over.png`.

**A bug device verification found that no test caught: the game-over card shows
"NEW BEST" for a score of 0.** First run, you score nothing, and it congratulates
you. The comparison treats `0 >= 0` as an improvement. Not yet fixed — recorded
here so it is not lost.

**Also observed:** 25 seconds of scripted tapping at a fixed 0.55s cadence now
scores zero against the ramped game. That is the driver being a bad player, not
a defect, but it does mean automated "does it still work" checks get weaker as
the game gets harder. The fairness solver is a competent player and would make a
far better test driver than a metronome.

## 2026-09-04 — Phase 5b: risk scoring, assist mode, and a deeper bug than the one reported

**Files.** New `lib/game/risk_score.dart`, `lib/ui/assist.dart`,
`tool/solver_bot.dart`, `test/risk_score_test.dart`, `test/assist_test.dart`.
Tests 230 -> 282. No dependency added.

### The NEW BEST bug was not the bug I reported

I diagnosed it as `0 >= 0`. That was wrong, or rather it was the symptom. By the
time the game-over card is built **the record has already been written**, so
`score == bestScore` covers two situations that need opposite answers: the run
that just set the record, and a run tying one set last week. The fact that
distinguishes them no longer exists at that layer. Fixing the operator would
have shipped the tie case.

The comparison now happens where the previous best is still alive and
`isNewBest` is passed through. Reverting the screen fix turns 4 of 31 tests red;
reverting the model-side comparison turns 1 red — the asymmetry is real, only one
path reaches that line.

**The persistence path was already correct** — both sides used strict `>`. But
checking it surfaced a different hole: if the asynchronous store answered *after*
a run finished, a run that beat "no record" kept its claim when a better stored
record arrived. Now withdrawn. The first version of that guard was too
aggressive and withdrew every legitimate claim; the negative-control test caught
it.

### Risk-weighted scoring

`score` is unchanged — obstacles passed — so run codes and stored records are
unaffected. `riskScore` is a second field, part of `==`, so replay covers it for
free.

Clearance is measured over exactly the frames the car's box and the obstacle's
box overlap horizontally — the frames that pipe could kill you — at the post-tick
`y` the collision test uses.

Curve: `bonus = floor(5 * r^3)` where `r = 1 - clearance/room`.

```
bonus       1      2      3      4      5
r >=      0.585  0.737  0.843  0.928  1.000
```

**Picked, not derived:** the cap of 5 and the exponent 3. Those say how much the
game wants to pay for risk, and nothing computes them.
**Derived:** the ratio, from the model's own geometry — using it rather than raw
distance is what stops the ramp inflating rewards as gaps narrow.
**Measured, and the reason the exponent is 3:** an obstacle straddles the car for
43 frames, and `minimumExcursion(43)` is 0.0869, so the flattest pass physics
permits is r = 0.349 — below the 0.585 the first point costs. **Flying as well as
the physics allows earns nothing.** You have to actually take risk to be paid.

Anti-farm is an invariant, not a list of tricks: risk only moves on a frame that
also scores, never decreases, and is bounded by `5 * delta-score`. A pipe that
kills you never scores, so an unsurvived scrape pays zero.

### Assist mode

Same physics, same lattice, same pessimistic epsilon as the prover. Cheap by
three changes: bounded horizon (next obstacle + 45 frames), the search runs
BACKWARDS so one pass answers every candidate tap, and a pass is reused for ~60
frames because the surviving-state sets belong to the world, not the car.

```
302 passes: p50 0.47ms  p90 0.84ms  p99 1.13ms  max 1.67ms
one pass per ~58 frames  ->  0.014 ms/frame amortised
```

**Where it is wrong, stated rather than buried.** Within its horizon it is
exact, so it never highlights a tap the physics cannot support. It is
**optimistic past the horizon**: a highlighted tap clears the next obstacle and
45 frames beyond, and can still strand you two obstacles later. It says a
continuation exists, not that any continuation works.

It cannot touch the model. Asserted by playing identical inputs with the solver
consulted every frame and never constructed, comparing traces frame-for-frame,
with a non-vacuity assertion that the solver actually answered on 200+ frames.

### A competent test driver

```
policy    outcome     score   risk  passed  frames  flaps
solver    survived       45    170      45    3600    273
```

60 seconds, 45 obstacles, still alive. Over 300s it reaches 237, well past the
plateau. On the same course `chaseGap` dies at 12 and `holdAltitude` scores 0 —
and my scripted metronome scored 0 too. Automated checks now have a driver that
gets better as the game gets harder rather than worse.

### Two mutation boundaries restructured rather than argued away

A saturating clamp is continuous at its own boundary, so `>` and `>=` agree
there by construction — genuinely unkillable. Rather than write an equivalence
argument, `riskBonus` now counts thresholds so the saturation lives in a loop
bound where moving it by one changes the answer. Likewise the "level with the
car" test moved out of `tick` into `Obstacle.isLevelWith`: inline, pipe
positions come from the physics and no test could land an edge exactly on the
car's; as a function of two doubles the boundary is one line of a test.

Converting "no test can catch this" into "a test does catch this" beats a
well-written excuse. 117 new mutants, 117 killed, 0 equivalence arguments added.

**A hazard worth recording.** `tool/mutate.dart` restores `lib/game/` from a
startup snapshot when it exits. Editing those files while a run is in flight gets
them silently reverted. Nothing was lost this time because it was noticed, but a
background process that quietly undoes your edits is the kind of thing that gets
blamed on the editor. It should refuse to restore a file whose content changed
underneath it.

**Unverified on hardware.** Assist mode's appearance — legibility over the pipes,
whether the window is noticed in time, whether it helps or distracts.

## 2026-09-04 — Phase 6a: accessibility, computed rather than eyeballed

**Bar 6 closed.** New `lib/ui/palette.dart`, `colour_math.dart`, `motion.dart`,
`tool/palette_report.dart`, six test files. Tests 282 -> 367. No dependency added.

**The calculator was pinned before anything was judged by it.** WCAG relative
luminance and contrast, verified against published reference pairs — black on
white 21.0000 exactly, `#767676` on white 4.5422 against a published 4.54, pure
red on white 3.9985. Alpha compositing pinned against Flutter's own
`Color.alphaBlend` over 40 combinations, because it has to agree with the
renderer rather than with physics. CIEDE2000 pinned against all 31 rows of the
Sharma/Melkote/Trussell table to 1e-4. That found a real bug: greys came out
with non-zero a*/b* because the D65 white point was the rounded tabulated value
rather than the column sums of the sRGB matrix.

**No text pair ever failed 4.5:1.** I am not going to claim a rescue that did
not happen. What was actually wrong is subtler: two text-bearing surfaces were
translucent — `hudSurface` at `0xE8`, `cardSurface` at `0xF2` — so their contrast
was partly a property of whichever pipe was scrolling behind. The comment beside
`hudSurface` insisted the alpha "is FF and has to stay FF" while the code said
otherwise; the code was wrong. Both are opaque now and a test asserts it, because
a paragraph cannot fail and an assertion can.

**Colours changed for colourblind distinguishability**, with before/after
CIEDE2000 against the pair each one was failing:

```
ground        0xFF264B3D -> 0xFF3A3F52   5.09/5.25/5.16  ->  24.16/18.06/21.24
horizonBand   0xFF78A88D -> 0xFF8C9BA8  12.09/12.37/12.55 -> 30.79/29.73/31.45
assistCoast   0x99FFFFFF -> 0xE6FFD24A   8.61/3.65/2.14  ->  32.18/28.51/23.14
hill          0xFF5F9B8A -> 0xFF5A7C9B   did not fail; changed for scene coherence
```

Where a green and a green had to be pulled apart, the obstacle kept its colour
and the scenery moved. `assistCoast` went amber so the three assist signals sit
along the blue-yellow axis, which both simulated deficiencies preserve.

**Metric and its limits.** CIEDE2000 over Viénot/Brettel/Mollon dichromat
simulation, applied in linear light. Threshold 15 ΔE00 — **a judgement, not a
standard**, unlike 4.5:1. ΔE00 = 1 is the lab JND for adjacent uniform patches
under controlled light; these are small shapes moving half a screen width per
second on an uncalibrated phone, so 15 is a chosen multiplier and says so.

The simulator has no published reference table, so it is pinned structurally —
idempotent, greys unchanged, alpha preserved — **plus a positive control** that
requires it to collapse red against green, or an identity function would pass
everything else.

**Stated limits, not buried.** This models dichromacy, a missing cone. The far
commoner protanomaly and deuteranomaly are a *shifted* cone and are not modelled
at all. Tritanopia is not covered — and the colours chosen to survive red-green
loss lean on exactly the axis a tritanope loses. No colourblind player has seen
this game.

**The sprite was handled, not excluded.** A PNG cannot be a palette entry, so the
test decodes it: 19,414 opaque pixels, darkest `#FF060B0C`, brightest
`#FFFEFEFE`. Two findings — the file's alpha tops out at **254**, so a strict
`== 255` test found nothing, and `rawRgba` is premultiplied and had to be divided
back out. The sprite's extreme pixels are pushed through both text surfaces to
show compositing cannot reach the glyphs, with the old `0xE8` asserted to fail
that same statement so the check is not vacuous.

**Reduced motion.** Defaults to `MediaQuery.disableAnimations`, re-read on
`didChangeDependencies`, with an in-app override cycling system → reduced → full.
The label names the *resolved* state, because "AUTO" alone answers the wrong
question. It stops the backdrop parallax and nothing else: pipes are the course,
the car is the player, the ghost is the record, the assist path is the future.
Three tests hold the model identical with motion on and off.

**The demonstration I did not ask for, and the best one.** Replacing the decor
phase with a constant in the render path left every clock and offset test green.
Only a pixel-level test caught it — so one was written: render the tree to real
RGBA at two decor phases while the run is `ready`, and require the bytes to
differ with motion full and be identical with it reduced. Without it, reduced
motion would have had thorough tests of a clock that nothing drew.

## 2026-09-04 — Phase 6b: size, frame time, the Flame decision, and removals

**Bar 5 closed, but the bar as written was wrong and that is the finding.**

I specified zero jank frames measured from `adb shell dumpsys gfxinfo`.
**That instrument cannot see this app.** Flutter renders into a `SurfaceView`,
bypassing the HWUI pipeline gfxinfo reports on. After 70 seconds of continuous
play it returns `Total frames rendered: 0` and `Janky frames: 0 (0.00%)`.

Its everything-is-perfect output and its I-can-see-nothing output are the same
string. A run that took the bar literally would have reported a flawless pass
from an instrument measuring nothing — the exact failure this project keeps
hunting, written into the acceptance criteria by me.

Measured instead with `SchedulerBinding.addTimingsCallback`. A jank frame is a
vsync interval in which no new frame was presented, from consecutive
`vsyncStart` gaps over the 16,667 us budget read off `display.refreshRate`. Not
`totalSpan` against budget: that is end-to-end latency across a pipelined
build/raster path and reports 100% failure while the game holds 59.9 fps.

**Zero missed vsyncs, 3 of 3 quiet runs, 3,594 frames over 60s**, driven by the
solver bot rather than a metronome, restarting on death so the minute is
continuous play.

```
              p50    p90    p99    max    >=17ms
build          0ms    0ms    1ms    2ms    0
raster        15ms   16ms   18ms   23ms    9.9%
```

Two runs were discarded for host CPU contention and are shown in
`docs/performance.md` rather than dropped, because they initially pointed the
wrong way.

Backdrop optimisation bought tail latency, not throughput: the sky gradient is
clipped to the horizon (30% was painted then covered) and the hill path cached
instead of rebuilt twice a frame. Frames at or above 20ms raster went 20 to 2;
worst 33ms to 20ms.

**APK size.**

```
split arm64-v8a    15,025,382 bytes  (14.33 MB)   <- claimed against the bar
split armeabi-v7a  12,221,104
split x86_64       16,394,469
universal          42,019,511                     <- cannot reach 30 MB
```

The universal APK carries three copies of the Flutter engine, 33.4 MB, 79.5% of
the file, and is not what anyone installs. Reductions: turning off
`uses-material-design` saved 556 KB — the icon tree-shaker keeps code points
found in const `IconData`, and with none present it had nothing to walk, so the
whole font survived — and dropping `cupertino_icons` saved 116 KB. Nothing else
in the APK is ours.

**Flame stays, and the numbers say so.**

```
                        with Flame    without
libapp.so arm64          2,425,736   2,229,128   (-196,608 = 1.31% of the split APK)
cold start median            640ms       741ms   (7 runs each)
missed vsyncs / 60s              0           0
```

It costs 1.3% of an APK clearing the bar with 50% margin, cannot cost frame time
(everything it does runs on a UI thread finishing 98.5% of frames under 1 ms
against a 16.667 ms budget), and removing it made cold start worse. The
replacement is about 190 lines of game loop, layer ordering, text layout and
overlay management owned forever, for 197 KB — while one line of pubspec saved
three and a half times more.

**Removals.** `lib/dev/` deleted; no import of it existed anywhere. A stale
exemption clause in `test/palette_test.dart` naming `lib/dev/` was repointed —
the dangerous kind, since nothing about an unscanned missing directory ever goes
red.

Kept, with reasons found by reading the suite rather than grepping: the debug
overlay, proven absent from the shipped AOT snapshot so it costs zero bytes
while its three colours are graded pairs under both dichromacy simulations; the
non-daily-challenge branch, asserted by `widget_test`; and the `chaseGap` and
`holdAltitude` policies, which are the control arm of the assist tests claim to
beat the bots it replaces, asserting the weak bots really die before comparing.

**Two changes await ratification** — a dependency removal and a build-config
change, both on the standing stop-and-ask list, and the goal authorised only
adding dependencies. `cupertino_icons` removed, `uses-material-design` off. Both
are one-line reversions, and both carry a silent trip-wire: the moment any file
imports `flutter/material.dart` and draws an `Icon` it renders as an empty box
with no build error. The pubspec comment says so at the line that would change.

**Not measurable here.** Everything on physical hardware. The emulator
rasterises in software, so 15 ms of raster is perhaps 1-2 ms on a real GPU. The
shape of the distribution transfers; the absolute milliseconds do not.
