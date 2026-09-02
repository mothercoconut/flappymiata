# PROJECT

Project number / name: Project 2 — flappymiata (Flappy Bird, but a Miata)
Stack and target platform: Flutter 3.47.2 / Dart 3.13.2, Flame 1.38.2, Android (Java 21, Android SDK at C:\Android\Sdk)
Solo or team; my assigned area: Team of 2 with @Sdav239. Mine is game logic (lib/game/, test/). His is UI and assets (lib/ui/, assets/)
Trunk branch name: main
Task board, and where my cards live: Trello https://trello.com/b/fSePwxh7/flappymiata (private board; not readable by tooling)
Build command: flutter build apk --debug
Test command: flutter test
Analyze / lint command: flutter analyze
CI configured (yes/no) and workflow path: no — automated build is first required in project 3
Deliverables required for this project: git repo, demo video, task list
Constraints (professor's requirements, must-differ-from-previous-app, etc.): must differ from project 1 (Paranoia Meter); teams of 2; no server component required until project 4
Repo: https://github.com/mothercoconut/flappymiata
Emulator AVD: csc4330 (Android 16, sdk 36, x86_64, google_apis)
Application id: com.allen.flappymiata
Due: Friday 2026-09-04 17:00
Dev harness: lib/dev/ is a DISPOSABLE test rig with its own entrypoint (flutter run -t lib/dev/harness.dart). Not the game UI. Delete once lib/ui/ renders the model.
Last updated: 2026-09-01
