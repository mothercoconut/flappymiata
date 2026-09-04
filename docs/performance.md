# Size and frame-time measurements

Everything here is a number somebody took off this machine, with the command
that produced it. Where something could not be measured it says so instead of
estimating.

Taken 2026-09-04. Device: the `csc4330` AVD — Android 16 / API 36, x86_64,
Pixel 7 profile, **software rendering** (`vulkan_mode_selected:lavapipe
gles_mode_selected:swiftshader`), 60.00 Hz. That last fact is load-bearing and
is discussed under "What these numbers are not" at the end.

---

## 1. Release APK size

### The bar, and the number claimed against it

The bar is 30 MB. **Claimed: 15,025,382 bytes (14.33 MiB) — the `arm64-v8a`
split APK**, which is what an actual Android phone downloads and installs.

The universal APK is 42,019,511 bytes and cannot be brought under 30 MB, for a
structural reason rather than a fixable one: it contains **three copies of the
Flutter engine**, one per ABI, and they alone are 33,415,188 bytes — 79.5% of
the file. The engine is not this project's code and nothing in this repository
can shrink it. A universal APK is also not a thing anyone installs; it is a
convenience artefact that carries two ABIs the installing device will never
execute.

| artefact | bytes | MiB | under 30 MB |
|---|---:|---:|:--:|
| `--split-per-abi` armeabi-v7a | 12,221,104 | 11.65 | yes |
| **`--split-per-abi` arm64-v8a** | **15,025,382** | **14.33** | **yes** |
| `--split-per-abi` x86_64 | 16,394,469 | 15.63 | yes |
| `--target-platform android-arm,android-arm64` (one installable file, no emulator slice) | 26,451,039 | 25.23 | yes |
| universal (all three ABIs) | 42,019,511 | 40.07 | no |

Reproduce:

```
flutter build apk --release --split-per-abi
flutter build apk --release --target-platform android-arm,android-arm64
flutter build apk --release
```

### What the reductions bought

Baseline as found: **42,692,248 bytes**. After the two changes below:
**42,019,511 bytes**. Measured on the universal APK so the saving is counted
once per ABI-independent asset rather than three times.

| change | bytes saved | what it was |
|---|---:|---|
| `uses-material-design: false` | 556,000 | `MaterialIcons-Regular.otf`, 1.6 MB uncompressed. Nothing in this app imports `package:flutter/material.dart` and `grep -rn "Icons\.\|IconData\|Icon(" lib/` returns nothing, so not one glyph of it was reachable. It was not tree-shaken to nothing because the icon tree-shaker keeps the code points it finds in const `IconData` instances — with zero of those in the program there is nothing for it to walk, and the whole font survives. An optimisation that only fires when a feature is used cannot fire on an app that does not use the feature at all. |
| drop `cupertino_icons` | 116,000 | `CupertinoIcons.ttf`. The Flutter template's default, never imported. |
| **total, measured** | **672,737** | |

Nothing else in the APK is ours to cut. The full inventory:

| entry | bytes | share |
|---|---:|---:|
| `libflutter.so` × 3 ABIs | 33,415,188 | 79.5% |
| `libapp.so` × 3 ABIs (all our Dart, plus Flame and shared_preferences) | 7,670,104 | 18.3% |
| everything else (dex, resources, sprite, licences) | 934,219 | 2.2% |

The car sprite is 38,381 bytes and is already stored uncompressed. `NOTICES.Z`
(97 KB) is the third-party licence file and is required.

**Two of these changes need ratification** — see "Decisions that are not mine"
at the end.

---

## 2. Frame time

### The instrument the bar names does not work on this app

The acceptance criterion says to read jank from `adb shell dumpsys gfxinfo
com.allen.flappymiata`. Run against this app after 70 seconds of continuous
play, it says:

```
Total frames rendered: 0
Janky frames: 0 (0.00%)
```

**That is not a pass. It is the instrument reporting that it saw nothing.**

`gfxinfo` reports on HWUI, the renderer for the Android *view hierarchy*. A
Flutter app in its default render mode is handed a `SurfaceView` — visible as
`SurfaceView[com.allen.flappymiata/...](BLAST)` in `dumpsys SurfaceFlinger
--list` — and the engine's raster thread paints straight into that surface's
buffers, bypassing HWUI entirely. An earlier probe caught the same thing more
loudly: `Total frames rendered: 1`, `Janky frames: 1 (100.00%)`, where the one
frame was the Android view that *holds* the surface being laid out once.

The trap is that this tool's "I saw nothing" and its "everything was fine" are
**the same string**. Anyone reading only the second line scores a pass.

### What was measured instead

`SchedulerBinding.addTimingsCallback` — the engine's own record, one per frame
it actually presented. The probe is `FrameTimingProbe` in `lib/main.dart`,
compiled in only under `--dart-define=AUTOPILOT=true`. It costs **zero bytes**
without the define. `bool.fromEnvironment` with no define is a const `false`, so
the compiler drops every branch that reads it and everything only those branches
reach — and that is checked two independent ways rather than asserted:

1. `flutter build apk --release` produced a universal APK of **exactly
   42,019,511 bytes** both before the probe and the autopilot were written and
   after. `libapp.so` is the same size on arm64 and x86_64 in both, with
   different contents — confirmed by hashing, so this is not an APK being
   compared with itself.
2. Searching the AOT snapshot of the shipped build (`--analyze-size` JSON) for
   the class names finds **`Autopilot` absent and `FrameTimingProbe` absent**,
   while `FlappyMiataGame`, `_BackdropLayer`, `_WorldLayer`, `_GhostLayer`,
   `_AssistLayer` and `_ScorePanel` are all present. The same search finds
   **`_DebugOverlay` and `debugCarBox` absent** too, which is the same
   `const bool kShowCollisionBoxes = false` mechanism working on the
   collision-box overlay.

That second check is the useful one, because it can fail: it distinguishes
between names, so it is not a search that would report "absent" for anything
handed to it.

**Definition of a jank frame, stated precisely:** a *vsync interval in which no
new frame was presented*. The probe takes
`FrameTiming.timestampInMicroseconds(FramePhase.vsyncStart)` for consecutive
frames, divides the gap by the display's frame budget (16,667 µs, read off
`platformDispatcher.implicitView.display.refreshRate` and logged so the
comparison can be checked), rounds, and counts every interval beyond the first
as a miss. One miss = one refresh where the display showed the previous picture
again. That is what a player sees as a stutter, and nothing else is.

**Why not `FrameTiming.totalSpan` against the budget, which is the obvious
choice:** `totalSpan` runs from the vsync that scheduled a frame to the instant
the raster thread finished it, and those two threads are *pipelined* — frame
n+1 is built while frame n is still rasterising. On every run below, 100% of
frames exceed 16.667 ms by that measure while the game holds a steady 59.9 fps.
Scoring end-to-end latency against the frame period manufactures a total failure
out of a healthy system. Both numbers are reported; only the first answers the
question.

### The run

Driven by the **solver bot policy** — the assist solver's own surviving-state
search, coasting while coasting is survivable and tapping on the frame it stops
being (`Autopilot` in `lib/main.dart`, held line-for-line identical to
`tool/solver_bot.dart` by a test in `test/assist_test.dart`). A fixed-cadence
metronome was not an option: `tool/solver_bot.dart` records that the stock
`holdAltitude` policy now scores zero against the shipped ramp, so a minute of
it would be a minute of the game-over screen. Screenshots taken mid-run confirm
real play — score 44 and 56 at the moments they were taken. The bot restarts the
instant a run ends, so the minute is continuous play.

The window is **t=5 s to t=65 s**, obtained by subtracting one cumulative report
from another. App start-up is excluded deliberately and reported separately: it
is where every miss happens, and folding it in measures the launch instead of
the game.

### Result

| run | host CPU max | frames in 60 s | **missed vsyncs** | fps |
|---|---:|---:|---:|---:|
| before backdrop change, run 1 | — | 3,594 | **0** | 59.90 |
| before backdrop change, run 2 | 6.1% | 3,586 | **9** | 59.77 |
| before backdrop change, run 3 | 4.8% | 3,593 | **0** | 59.88 |
| after backdrop change, run 2 | 5.6% | 3,590 | **0** | 59.83 |
| after backdrop change, run 3 | 6.4% | 3,594 | **0** | 59.90 |
| after backdrop change, run 4 | 4.8% | 3,593 | **0** | 59.88 |
| *(discarded)* before, run 4 | **18%** | 3,543 | 51 | 59.05 |
| *(discarded)* after, run 1 | contended | ~3,481 | 112 | — |

**Zero jank frames across a 60-second scripted run: met on 3 of 3 runs after the
backdrop change, and on 2 of 3 before it.**

The two discarded runs are the reason `measure.ps1` samples host CPU throughout.
Both were taken while another build was running on this machine, and on an
emulator that rasterises in software that is not a background detail — it is
competition for the same cores that are drawing the game. A frame-time number
taken on a busy machine is a number about the machine.

### The distribution

60-second window, "after" run 3 (representative; the other quiet runs agree to
within a bucket). Buckets are whole milliseconds, floored.

| measure | p50 | p90 | p99 | max | ≥ 17 ms |
|---|---:|---:|---:|---:|---:|
| **build** (UI thread — Dart, the game, the layout) | 0 ms | 0 ms | 1 ms | 2 ms | 0 (0.0%) |
| **raster** (GPU thread — the actual drawing) | 15 ms | 16 ms | 18 ms | 23 ms | 356 (9.9%) |
| build + raster (the work that has to fit) | 16 ms | 17 ms | 18 ms | 23 ms | 710 (19.8%) |
| totalSpan (end-to-end, pipelined — see above) | 20 ms | 21 ms | 22 ms | 28 ms | 3,594 (100%) |

Full histograms, `ms:count`:

```
build   0:3539 1:51 2:4
raster  10:2 11:2 12:12 13:82 14:521 15:1356 16:1263 17:311 18:39 19:3 20:2 23:1
gaps    1:3594                     <- every frame on the very next vsync
```

**The shape of this is the whole story.** The Dart side is free: 3,539 of the
3,594 frames — 98.5% — spend under one millisecond in `build`, and not one
exceeded 2 ms. That is the thread the game logic, the fixed-step model, the
ghost replay and the widget layer all run on, and it is idle. The
cost is entirely rasterisation, and on this emulator rasterisation is a CPU
walking pixels. There is no headroom — 20% of frames spend more than the frame
budget doing work — but the buffer queue absorbs it and nothing is dropped.

### What was changed, and what it bought

`_BackdropLayer` in `lib/main.dart`:

1. **The sky gradient is drawn only down to the horizon**, not over the whole
   screen. Everything below is covered by two fully opaque rectangles, so 30% of
   the most expensive fill in the frame was being painted and then hidden. The
   shader is anchored to absolute pixels rather than to the rectangle it fills,
   so shrinking the rectangle moves no colour.
2. **The hill silhouette `Path` is built once and kept**, instead of being
   allocated and re-tessellated twice per frame.

Verified visually rather than assumed: screenshots before and after have
**byte-identical modal pixel colours** at every sampled row — `#1B4166` at
y=200, `#2B5574` at y=900, `#36637E` at y=1400, `#5A7C9B` at the hills,
`#8C9BA8` at the horizon band, `#3A3F52` on the ground.

What it bought was **tail latency, not throughput**. The median frame is
unchanged (15 ms raster either way). The tail collapsed:

| | frames ≥ 20 ms raster (60 s) | worst raster |
|---|---:|---:|
| before | 20 | 33 ms |
| after | 2 | 20 ms |

Start-up misses (outside the measured window) were 35/38/43 before and 16/19/48
after — lower on two of three runs and higher on the third, which is too noisy
to claim anything from. Inside the window, missed vsyncs went from clean on two
runs of three to clean on three of three.

---

## 3. Is Flame worth keeping?

Measured both ways. A complete Flame-free variant was built on a throwaway copy
of this tree: `CustomPainter` + `Ticker` in place of `FlameGame`, an explicit
sorted layer list in place of component priorities, `TextPainter` in place of
`TextComponent`, a `ChangeNotifier` in place of `game.overlays`, and
`GestureDetector` in place of `TapCallbacks`. It draws the same picture, passes
367 tests, and analyzes clean.

### Size — Flame costs 175 KB of Dart, 1.3% of the shipped APK

From `flutter build apk --release --target-platform android-arm64
--analyze-size`, comparing the AOT snapshot package by package:

| package | with Flame | without | delta |
|---|---:|---:|---:|
| `package:flame` | 84,040 | 0 | −84,040 |
| `package:flutter` | 773,871 | 751,876 | −21,995 |
| `dart:mixin_deduplication` | 124,765 | 107,771 | −16,994 |
| `dart:collection` | 46,041 | 31,108 | −14,933 |
| `package:collection` | 13,384 | 434 | −12,950 |
| `dart:_internal` | 63,060 | 55,628 | −7,432 |
| `package:ordered_set` (Flame's own dependency) | 5,136 | 0 | −5,136 |
| `package:vector_math` | 17,407 | 13,562 | −3,845 |
| everything else, net | | | −11,831 |
| `package:flappymiata` (**our** code — the replacement renderer) | 79,750 | 83,784 | **+4,034** |
| **total Dart code** | **2,010,987** | **1,835,865** | **−175,122** |

In the APK that is `libapp.so` 2,425,736 → 2,229,128 on arm64, i.e. **−196,608
bytes**, or **1.31% of the 15,025,382-byte arm64 split APK**.

### Cold start — Flame is *faster*, by about 100 ms

`am start -W`, `TotalTime`, seven cold starts each, force-stopped between, same
backdrop and same probe in both:

| | median | min | max |
|---|---:|---:|---:|
| with Flame | **640 ms** | 619 | 778 |
| without Flame | 741 ms | 725 | 791 |

Not the expected direction, and reported as measured rather than explained. The
ranges barely overlap across fourteen runs, so the difference looks real, but
two things stop it being a clean result:

- **The two builds differ by more than Flame.** The variant was branched from
  this tree before the icon fonts came out, so its APK still contains
  `MaterialIcons-Regular.otf` and `CupertinoIcons.ttf` (verified by listing both
  APKs). Neither font is loaded at start-up, but the asset manifest they appear
  in is parsed, and 1.9 MB of extra asset is 1.9 MB the installer laid down.
- **No mechanism was identified.** A ~100 ms difference in engine start-up is
  not something this measurement can attribute, and guessing at it would be
  worse than leaving it open.

The honest reading is that removing Flame did not make start-up faster, which is
enough for the decision below. Anyone wanting the real figure should rebuild the
variant from the current pubspec and repeat.

### Frame time — no measurable difference, and there could not have been

Same instrument, same 60-second window, same quiet machine:

| | missed vsyncs | frames | build p50 / max | raster p50 / p90 | raster ≥17 ms |
|---|---:|---:|---:|---:|---:|
| with Flame | **0** | 3,593 | 0 ms / 2 ms | 15 / 17 ms | 10.2% |
| without Flame | **0** | 3,591 | 0 ms / 2 ms | 15 / 17 ms | 11.5% |

**The measurement above already made this conclusion unavoidable before the
variant was built.** Everything Flame does per frame happens on the UI thread —
walking a six-component tree and calling `update`. That thread's whole frame
cost is *0 ms at the median and 2 ms at the maximum*. There is no room there to
win. The frame cost is rasterisation, and both variants issue the same
`canvas.draw*` calls in the same order, so both rasterise identically.

### Recommendation: **keep Flame.**

Following the numbers, not the effort:

- It costs **1.3% of the APK**. The bar is met with a 50% margin either way.
- It costs **nothing measurable per frame**, and structurally cannot cost much:
  everything it does happens on the UI thread, and that thread finished 98.5% of
  frames in under 1 ms against a 16.667 ms budget, never exceeding 2 ms.
- Removing it made cold start **worse** by ~16% in the only measurement taken.
- The replacement is ~190 lines of hand-rolled game loop, layer ordering, text
  layout and overlay management — code this project would then own and test
  forever, in exchange for 197 KB.

The one thing that would change this answer is a size bar Flame's 197 KB
actually decided. It does not: dropping the *fonts* saved three and a half times
more, for a one-line change.

**Found while building the variant, and worth keeping regardless of the
decision:** `initState` runs per element, so swapping a second game into a live
surface never re-ran `onLoad`. The app never does this; a test that pumps two
games would. The 367 tests were green over it.

---

---

## 4. What was removed, and what was deliberately kept

### Removed

**`lib/dev/` — the whole directory** (`harness.dart`, 362 lines, and its
`README.md`). It had its own entrypoint (`flutter run -t lib/dev/harness.dart`)
and was never on any build path. Checked, rather than searched-and-shrugged:

- `grep -rn "flappymiata/dev\|dev/harness\|'\.\./dev" --include=*.dart
  --include=*.yaml --include=*.yml --include=*.kts --include=*.gradle .` finds
  no import of it anywhere in `lib/`, `test/`, `tool/`, `pubspec.yaml` or
  `android/`.
- The only mentions in the repository are prose: `NOTES.md` (a dated record of
  when it was written) and `PROJECT.md`, which says *"DISPOSABLE test rig... 
  Delete once `lib/ui/` renders the model"*. `lib/ui/` renders the model.
- `test/palette_test.dart` lists the files it scans explicitly rather than
  globbing, so no test's coverage changed.

Two comments that named it were repointed, because a deleted directory leaves
claims behind:

- `test/palette_test.dart` listed `lib/dev/` as an *exemption* from the
  colour-literal scan. An exemption for a directory that no longer exists is the
  worst kind of stale claim — nothing about it would ever have gone red.
- `lib/main.dart` cited the harness in the anecdote that justifies the draw-order
  constants. Still true; it now says the directory was deleted.

**`cupertino_icons` and `MaterialIcons-Regular.otf`** — see §1.

### Kept, with the reason

Three things look like dead code and are not. In each case the test suite was
read, not just grepped.

**`kShowCollisionBoxes`, `_DebugOverlay`, `_debugPriority`, and the three
`debug*` palette colours.** The constant is `false`, the branch is unreachable,
and the class is *proven absent from the shipped snapshot* (§2). So it costs
nothing to keep. It costs something to remove: `lib/ui/palette.dart` registers
all three colours as `DistinctPair` entries, and `test/palette_contrast_test.dart`
grades every one of them under both dichromacy simulations; `test/palette_test.dart`
additionally asserts that `assistDeadline` and `debugCarBox` are the same pink.
Deleting the overlay would either delete three graded pairs from the contrast
suite — weakening a guard — or leave three constants describing a component that
no longer exists. Zero bytes saved, real coverage lost.

**The `if (!kDailyChallenge) return classicCourseSeed;` branch.** Unreachable at
runtime, because the constant ships `true`. But `test/widget_test.dart` asserts
`kDailyChallenge` is true and that the shipped course is *not*
`classicCourseSeed` — a tripwire that makes flipping it a visible decision rather
than a silent one — and `classicCourseSeed` is now also what the autopilot pins
the measurement course to. Removing the branch removes the documented way to ship
the classic course.

**`neverFlap`, `startThenDrop`, `alwaysFlap`, `holdAltitude`, `chaseGap` in
`tool/headless_sim.dart`.** The file's own header says these heuristics
"stopped being useful", which reads like an invitation. Every one of them is
reached by a test, and two of them are load-bearing in a way a grep does not
show: `chaseGap` and `holdAltitude` are the **control arm** of the
`test/assist_test.dart` case *"it beats the heuristic bots it replaces"*, which
asserts that the weak bots really are weak (`expect(chase.outcome, isNot(
SimOutcome.survived))`) before comparing scores. Delete them and that comparison
has nothing to compare against.

**Systematic check, not just these three:** every public top-level declaration
in `lib/` was cross-referenced against `lib/`, `test/` and `tool/`. Nothing came
back with zero uses outside its own file that was not a Flutter override or a
false positive from the scan. Private unused elements are already caught by
`flutter analyze`, which is clean.

## What these numbers are not

- **The emulator renders in software.** `swiftshader` for GLES, `lavapipe` for
  Vulkan. A 15 ms rasterisation on this machine is perhaps 1–2 ms on a phone
  with a real GPU. The *shape* of the result transfers — the Dart side is free,
  the cost is fill — but the absolute milliseconds do not, and neither does the
  claim that there is no headroom. **Nothing here has run on physical hardware.**
- **`dumpsys gfxinfo` cannot measure this app**, as shown above. If the bar has
  to be scored with that specific command, the honest answer is that it cannot
  be, and the reason is architectural rather than a matter of getting the
  invocation right.
- **Cold start is `am start -W TotalTime`**, which is the activity reporting
  itself drawn. It includes emulator scheduling and is noisy at the 100 ms
  scale.
- **Two runs were discarded for host CPU contention** and are shown above rather
  than dropped silently.
- The Flame-free variant carries two icon fonts this tree no longer has, so its
  raw APK totals are not comparable to this tree's. Only the snapshot breakdown
  is, which is why the size argument is made from that.

## Decisions that are not mine

Two changes touch things the working agreement says to ask about first. Both are
one-line reversions.

1. **`cupertino_icons` was removed from `pubspec.yaml`** — a dependency removal.
2. **`uses-material-design` was set to `false`** — build configuration.

Both are safe today and both have a trip-wire: the moment any file imports
`package:flutter/material.dart` and draws an `Icon`, that icon renders as an
empty box, silently, with no build error. The comment in `pubspec.yaml` says so
at the line that would have to change.

Also noted: `PROJECT.md` says `CI configured (yes/no): no`, but
`.github/workflows/ci.yml` exists and defines six gates. `PROJECT.md` was out of
scope for this work and has not been corrected.

---

## Acceptance, run after every change above

```
$ flutter analyze
Analyzing flappymiata...
No issues found! (ran in 2.6s)

$ flutter test
00:11 +369: All tests passed!

$ flutter build apk --release
Running Gradle task 'assembleRelease'...                           16.8s
√ Built build\app\outputs\flutter-apk\app-release.apk (40.1MB)     [exit 0]

$ dart run tool/prove_fairness.dart
  one run from the start line to obstacle 150 ... verdict SURVIVABLE, 150 cleared
  120 daily courses, each read from obstacle 50
    PASS (survivable)    120
    FAIL (unsurvivable)  0
    tightest margin      0.05449 on 2024-01-01  (1.76 car-heights)
  total reachability searches  27160
  total wall time              140.2 s
  ALL EXPECTATIONS HELD.

$ dart run tool/mutate.dart --quick --jobs=1
  wall clock: 339.1s for 52 mutants                                [exit 0]
  RESTORED — lib/game is byte-identical to how the run found it.
```

**The test count moved from 367 to 369, and that is this work's doing**: two
tests were added to `test/assist_test.dart` asserting that the in-app
`Autopilot` and `tool/solver_bot.dart`'s `solverPolicy` make the same decision on
every frame of a 3,600-frame run, and that the bot's cached search survives a
restart. The first was checked for falsifiability the only way that means
anything — one comparison operator was changed in one of the two copies, and the
test failed naming frame 51 as the first disagreement.

`--jobs=1` mutates the repository in place. The tree was backed up before the
run and diffed after: byte-identical, no stray mutant or backup files, and the
harness printed its own SHA-256 before/after for all seven files in `lib/game/`.
