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
