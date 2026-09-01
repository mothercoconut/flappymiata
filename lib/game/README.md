# lib/game — game logic

Owner: @mothercoconut

Physics, collision, scoring, difficulty ramp, game state.

**Rule for this directory: no imports of `package:flame/...` or
`package:flutter/...`.** Plain Dart only. Anything that needs a canvas, a
widget, or a game loop belongs in `lib/ui/` or `lib/main.dart` instead.

The reason is testability. Everything here can be exercised by
`flutter test` in milliseconds with no rendering, which means the rules stay
verifiable no matter what the UI does.
