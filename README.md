# flappymiata

[![CI](https://github.com/mothercoconut/flappymiata/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/mothercoconut/flappymiata/actions/workflows/ci.yml)

CSC 4330 project 2. Flappy Bird, but a Miata.

Flutter + Flame. Android target.

The badge reports `main` specifically (`?branch=main`). Without that it would
show whichever branch ran most recently, which is not what "is trunk healthy?"
means.

## Who owns what

Two of us work in this repo. The split below exists so we do not edit the same
files at the same time. If you need something outside your area, say so in
Discord and let the owner change it — do not reach across.

| Path            | Owner            | Contents                                              |
| --------------- | ---------------- | ----------------------------------------------------- |
| `lib/game/`     | @mothercoconut   | Game logic: physics, collision, scoring, difficulty, game state |
| `test/`         | @mothercoconut   | Tests over that logic                                  |
| `lib/ui/`       | @Sdav239         | Screens, menus, HUD, buttons, input widgets            |
| `assets/`       | @Sdav239         | Sprites, audio                                         |
| `pubspec.yaml`  | shared           | Ask before adding a dependency                         |
| `lib/main.dart` | shared           | Wiring only. Keep it thin                              |
| `android/`      | shared           | Rarely changes. Ask first                              |

`lib/game/` deliberately does not import Flame or Flutter. The rules are plain
Dart so they can be unit-tested with no game loop and no widget tree running.
That is also what keeps the two halves independent: rendering can change
without touching the logic tests, and the logic can change without opening a
single UI file.

## Workflow

Trunk-based. Branch off `main`, keep it short, merge back the same day.
Rebase onto `main` before pushing. Do not commit directly to `main`.

## Commands

```
flutter analyze              # static analysis
flutter test                 # unit + widget tests
flutter build apk --debug    # build
flutter run -d emulator-5554 # run on the emulator
```

## The CI gates, and how to run each one yourself

`.github/workflows/ci.yml` runs six checks on every push to `main` and on every
pull request. Nothing here is CI-only — each gate is a command you can run on
your own machine and get the same answer, which is the point. If the badge is
red, run the matching line below and you will see what CI saw.

| # | What it proves | Command |
| - | -------------- | ------- |
| 1 | The code analyses clean | `flutter analyze` |
| 2 | All 82 tests pass | `flutter test` |
| 3 | The Android app still builds | `flutter build apk --debug` |
| 4 | The shipped course is winnable by a perfect player (~110 s) | `dart run tool/prove_fairness.dart` |
| 5 | The mutation tool can still tell KILLED, SURVIVED and INVALID apart | `dart run tool/mutate.dart --selftest` |
| 6 | The test suite still notices deliberate breakage | `dart run tool/mutate.dart --quick --jobs=4` |

Two differences between these lines and what CI runs, both deliberate:

* CI passes `--jobs=2` to gate 6, sized for a 2-core hosted runner. Use
  `--jobs=4` (or more) locally.
* CI passes `--timeout=180` to gates 5 and 6. The mutation tool counts a test
  run that does not finish in time as a kill, which is weaker evidence than a
  failing assertion, and a cold hosted runner is slow enough to hit the 45 s
  default. Locally the default is fine.

Both mutation gates rewrite source on disk while they run. `--selftest` always
edits the real `lib/game/game_model.dart` and restores it (it also traps Ctrl-C
so an interrupt cannot leave the tree broken). `--quick` edits the real tree at
`--jobs=1`, but at `--jobs=2` and above every worker gets a throwaway sandbox
copy and the repository is never modified at all. Either way the run ends by
printing a SHA-256 of each target file before and after, so "it put everything
back" is something you read rather than something you hope.

Every one of these six gates was run against a deliberately broken tree before
the workflow was committed, to confirm it actually exits non-zero rather than
merely printing a complaint that GitHub would ignore. A gate nobody has watched
fail is not a gate.
