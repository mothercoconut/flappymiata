# lib/game — game logic

Owner: @mothercoconut

**Rule for this directory: no imports of `package:flame/...` or
`package:flutter/...`.** Plain Dart only. Anything that needs a canvas, a
widget, or a game loop belongs in `lib/ui/` or `lib/main.dart` instead.

The reason is testability. Everything here can be exercised by
`flutter test` in milliseconds with no rendering, which means the rules stay
verifiable no matter what the UI does.

Two rules follow from that one and are worth stating separately, because they
are what the newer files in here depend on: **no clock and no randomness.**
`tick` takes `dt` as an argument rather than reading a clock, and the model
takes a gap function rather than rolling dice. That is what makes a run a pure
function of its inputs — and therefore what makes recording one, replaying it,
and re-executing somebody else's claim possible at all.

## What is in here

| File | What it owns |
| --- | --- |
| `game_model.dart` | The rules. Physics, the difficulty ramp, scoring, run state, and the immutable `GameModel` snapshot everything else is stated in terms of. Re-exports `geometry.dart`. |
| `geometry.dart` | The shapes the rules are stated in: the normalised playfield, `Box`, and the collision test. Split out so the box maths can be checked by hand. |
| `course_seed.dart` | Which course a run is played on, as a single integer, and how a calendar date becomes one. The course is a pure hash of (seed, obstacle index) rather than a generator, so any gap can be evaluated on its own. Seed 0 is exactly the shipped course. |
| `replay.dart` | A whole run written down as a seed plus the frames the player tapped on, and the driver that re-executes it. Fixes the timestep and the tap-then-tick ordering, which are the two things "the same taps" is ambiguous without. |
| `run_code.dart` | That recording as a short ASCII string somebody can paste into a chat message, plus a decoder that refuses to be lied to. Crockford Base32 with a CRC-32, so a mistyped code fails as corruption instead of decoding into a different legal run. |
| `verified_score.dart` | Checking a claimed score by re-running it. The verifier does not detect tampering or keep a secret; it plays the run itself and reads the scoreboard the model produces. |

No file in here imports anything from outside this directory — not a package,
not even a `dart:` library. Inside it the dependencies are acyclic and always
point down this order:

    geometry  <  game_model  <  course_seed  <  replay  <  run_code  <  verified_score

A file may import any file to its left and never one to its right. The exact
edges today are: `game_model` on `geometry` (and it re-exports it, so one
import brings the whole model); `course_seed` on `game_model`; `replay` on
`course_seed` and `game_model`; `run_code` on `replay`; `verified_score` on
`game_model`, `replay` and `run_code`.

## Why the directory rule is enforceable and not just stated

`tool/mutate.dart` mutates exactly these files and grades the test suite on
whether it notices. That gate is only meaningful because a mutant's effect here
is a deterministic function of the source — no renderer, no clock, no
randomness, so "the suite did not notice" is a fact rather than a flake. A
Flutter or Flame import in this directory would take that away.
