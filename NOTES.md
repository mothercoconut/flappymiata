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

1. The emulator process exited on its own partway through the Gradle build, so
   the install step got `adb.exe: no devices/emulators found` even though
   `adb devices` had listed it seconds earlier. Rebuilding was unnecessary — the
   APK was already on disk. Booting the emulator and installing inside one short
   window worked.

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
