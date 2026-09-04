# PROJECT

Project number / name: Project 2 — flappymiata (Flappy Bird, but a Miata)
Stack and target platform: Flutter 3.47.2 / Dart 3.13.2, Flame 1.38.2, Android (Java 21, Android SDK at C:\Android\Sdk)
Solo or team; my assigned area: Team of 2 with @Sdav239. Project 2 was split game logic / UI; since submission I have taken sole responsibility for the whole repo for an open-ended quality pass
Trunk branch name: main
Task board, and where my cards live: Trello https://trello.com/b/fSePwxh7/flappymiata (private board; not readable by tooling)
Build command: flutter build apk --release --split-per-abi
Test command: flutter test
Analyze / lint command: flutter analyze
CI configured (yes/no) and workflow path: yes — .github/workflows/ci.yml, six gates: analyze, test, APK build, fairness proof, mutation self-test, mutation smoke test
Deliverables required for this project: git repo, demo video, task list — SUBMITTED 2026-09-04
Constraints (professor's requirements, must-differ-from-previous-app, etc.): must differ from project 1 (Paranoia Meter); teams of 2; no server component required until project 4
Repo: https://github.com/mothercoconut/flappymiata
Emulator AVD: csc4330 (Android 16, sdk 36, x86_64, google_apis) — run headless: emulator.exe -avd csc4330 -no-window -no-boot-anim
Application id: com.allen.flappymiata
Extra commands: dart run tool/prove_fairness.dart | dart run tool/mutate.dart | dart run tool/palette_report.dart | dart run tool/simulate.dart --policy=solver
Release APK size: 15,025,382 bytes arm64-v8a split (14.33 MB). The universal APK is 42 MB and cannot shrink — it carries three copies of the Flutter engine.
Notes: lib/game/ is pure Dart and imports nothing; tests enforce it. lib/dev/ was deleted once lib/ui/ superseded it.
Last updated: 2026-09-04
