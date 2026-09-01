# flappymiata

CSC 4330 project 2. Flappy Bird, but a Miata.

Flutter + Flame. Android target.

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
