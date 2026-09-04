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
