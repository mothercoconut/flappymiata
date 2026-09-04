/// The difficulty ramp: its shape, its ends, and the fact that it really is
/// wired into the game rather than merely declared beside it.
///
/// WHY THIS FILE IS SEPARATE FROM `tuning_constants_test.dart`: that file pins
/// the numbers the game STARTS at. This one is about the function that moves
/// them, which is a different kind of claim and fails for different reasons. A
/// ramp can be perfectly wired and pointed the wrong way; it can have the right
/// endpoints and the wrong shape in between; and it can be a beautiful function
/// that `tick` never calls.
///
/// WHAT `tool/mutate.dart` WOULD DO TO A WEAKER VERSION OF THIS FILE, which is
/// what most of the assertions below are shaped by:
///
///   * a ramp asserted only at its two ends is satisfied by a step function, by
///     a curve, and by a ramp that runs backwards in the middle;
///   * a clamp asserted only well past its boundary cannot tell `<` from `<=`;
///   * an assertion written as `gapHeightAt(50) == Difficulty.tightestGapHeight`
///     moves with the constant, so it survives a re-tune — the absolute numbers
///     are written out here for the same reason `tuning_constants_test.dart`
///     writes its own out.
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:flappymiata/game/game_model.dart';
import 'package:flappymiata/game/replay.dart';
import 'package:flappymiata/game/run_code.dart';

import '../tool/fairness.dart';

/// One frame at 60fps, as everywhere else in this suite.
const double frame = 1.0 / 60.0;

/// A run with every gap pinned to mid-field, so nothing here is accidentally
/// about collision.
GameModel midFieldRun() => GameModel.ready(gapCentreFor: (int _) => 0.5).flap();

/// Flies [start] for [frames] frames, holding roughly at [line]. Enough to keep
/// a car alive long enough to be scored past a plateau.
GameModel fly(GameModel start, double line, int frames) {
  GameModel m = start;
  for (int i = 0; i < frames; i++) {
    if (m.y > line) m = m.flap();
    m = m.tick(frame);
  }
  return m;
}

void main() {
  group('the ramp is where the comments say it is', () {
    test('the warm-up is 10 obstacles and the plateau is obstacle 50', () {
      // Absolute, not relative. `plateauObstacle` is derived from the other two,
      // so asserting it against its own definition would pass for any pair of
      // values at all.
      expect(Difficulty.warmUpObstacles, 10);
      expect(Difficulty.rampObstacles, 40);
      expect(Difficulty.plateauObstacle, 50);
    });

    test('the plateau is the numbers the comments promise', () {
      expect(Difficulty.topScrollSpeed, closeTo(0.48, 1e-15));
      expect(Difficulty.tightestGapHeight, closeTo(0.252, 1e-15));
      expect(Difficulty.tightestSpacing, closeTo(0.60, 1e-15));

      // And what those numbers MEAN, in the units the tuning comments argue in:
      // the world ends up 6.7% faster and the gap ends up a tenth narrower.
      expect(Difficulty.topScrollSpeed / GameModel.scrollSpeed,
          closeTo(1.0667, 0.001));
      expect(Difficulty.tightestGapHeight / GameModel.gapHeight,
          closeTo(0.90, 0.001));
      expect(Difficulty.tightestGapHeight / GameModel.carHeight,
          closeTo(8.13, 0.01));
    });

    test('the spacing lever really is left alone', () {
      // The plateau spacing is written out as its own literal so that it is not
      // a compile-time alias of `GameModel.obstacleSpacing` — see the comment on
      // the constant. This is the assertion that keeps the two in step, and it
      // is what a re-tune of either number has to come past.
      expect(Difficulty.tightestSpacing, GameModel.obstacleSpacing);
      expect(Difficulty.spacingAt(0), GameModel.obstacleSpacing);
      expect(Difficulty.spacingAt(Difficulty.plateauObstacle),
          GameModel.obstacleSpacing);
      expect(Difficulty.spacingAt(999999), GameModel.obstacleSpacing);
    });
  });

  group('rampFraction — the shape, and both of its ends', () {
    test('it is flat at 0 for the whole warm-up, boundary included', () {
      // The boundary is the assertion that matters: `progress` one short of the
      // warm-up length and `progress` exactly equal to it must both be 0.0, and
      // the very next obstacle must not be.
      for (int p = 0; p <= Difficulty.warmUpObstacles; p++) {
        expect(Difficulty.rampFraction(p), 0.0, reason: 'progress $p');
      }
      expect(Difficulty.rampFraction(Difficulty.warmUpObstacles + 1),
          greaterThan(0.0));

      // A progress below zero cannot happen in a run, but the clamp has to hold
      // anyway: a negative fraction would hand back a gap TALLER than the base
      // one and say nothing about it.
      expect(Difficulty.rampFraction(-1), 0.0);
      expect(Difficulty.rampFraction(-1000000), 0.0);
    });

    test('it reaches exactly 1.0 at the plateau and never moves again', () {
      expect(Difficulty.rampFraction(Difficulty.plateauObstacle - 1),
          lessThan(1.0));
      expect(Difficulty.rampFraction(Difficulty.plateauObstacle), 1.0);
      expect(Difficulty.rampFraction(Difficulty.plateauObstacle + 1), 1.0);
      expect(Difficulty.rampFraction(1 << 40), 1.0);
    });

    test('it is linear in between, value for value', () {
      // Not "increasing" and not "between 0 and 1" — the exact fraction at every
      // step. A property-style assertion here would be satisfied by a curve, and
      // a curve is a different game.
      for (int k = 0; k <= Difficulty.rampObstacles; k++) {
        expect(
          Difficulty.rampFraction(Difficulty.warmUpObstacles + k),
          closeTo(k / Difficulty.rampObstacles, 1e-15),
          reason: '$k obstacles into the ramp',
        );
      }
      // Two spot values written as plain numbers, so the assertion above cannot
      // pass by re-deriving itself from a mutated `rampObstacles`.
      expect(Difficulty.rampFraction(20), closeTo(0.25, 1e-15));
      expect(Difficulty.rampFraction(30), closeTo(0.50, 1e-15));
    });

    test('the fraction is POSITIVE zero during the warm-up, not negative zero',
        () {
      // Dart has two zeros and `-0.0 == 0.0` is true, so not one equality
      // assertion above can tell them apart — which is exactly why
      // `tool/mutate.dart` found a mutant that returns `-0.0` from the warm-up
      // branch and survived the whole suite. Same hole
      // `tuning_constants_test.dart` already closes for the model's own zeros,
      // and closed the same way, because `isNegative` is the only operator here
      // that can see the difference.
      //
      // It is not a difference the ramp itself can express — `blend` multiplies
      // the sign away, so every scroll speed and gap height comes out identical
      // either way, checked over 200,001 values of progress. It is a difference
      // the moment anything DIVIDES by the fraction or prints it: `1 / -0.0` is
      // negative infinity, and a logged frame would read `-0.0`.
      expect(Difficulty.rampFraction(0).isNegative, isFalse);
      expect(Difficulty.rampFraction(Difficulty.warmUpObstacles).isNegative,
          isFalse);
      expect(Difficulty.rampFraction(-5).isNegative, isFalse);
    });

    test('it never goes backwards', () {
      double previous = -1.0;
      for (int p = -5; p < Difficulty.plateauObstacle + 20; p++) {
        final double f = Difficulty.rampFraction(p);
        expect(f, greaterThanOrEqualTo(previous), reason: 'progress $p');
        previous = f;
      }
    });
  });

  group('blend — exact at the ends, honest in the middle', () {
    test('t = 0 and t = 1 return the endpoints bit for bit', () {
      // The whole reason `blend` is written `from * (1 - t) + to * t` rather
      // than the shorter `from + (to - from) * t`. With the short form the
      // plateau lands a few ulps from the constant and nothing can state the
      // hardest setting as a number. `equals` here, not `closeTo`.
      expect(Difficulty.blend(0.45, 0.48, 0.0), 0.45);
      expect(Difficulty.blend(0.45, 0.48, 1.0), 0.48);
      expect(Difficulty.blend(0.28, 0.252, 0.0), 0.28);
      expect(Difficulty.blend(0.28, 0.252, 1.0), 0.252);
    });

    test('it interpolates rather than picking a side', () {
      expect(Difficulty.blend(0.0, 1.0, 0.5), closeTo(0.5, 1e-15));
      expect(Difficulty.blend(0.0, 10.0, 0.25), closeTo(2.5, 1e-15));
      expect(Difficulty.blend(2.0, 4.0, 0.75), closeTo(3.5, 1e-15));
      // Descending, which is the direction the gap height travels.
      expect(Difficulty.blend(4.0, 2.0, 0.75), closeTo(2.5, 1e-15));
    });
  });

  group('the three settings move in the directions the design says', () {
    test('scroll speed starts at the shipped value, rises, and stops', () {
      expect(Difficulty.scrollSpeedAt(0), GameModel.scrollSpeed);
      expect(Difficulty.scrollSpeedAt(Difficulty.warmUpObstacles),
          GameModel.scrollSpeed);
      expect(Difficulty.scrollSpeedAt(Difficulty.plateauObstacle),
          Difficulty.topScrollSpeed);
      expect(Difficulty.scrollSpeedAt(100000), Difficulty.topScrollSpeed);

      // Half way along the ramp, as an absolute number: 0.45 and 0.48 meet at
      // 0.465.
      expect(Difficulty.scrollSpeedAt(30), closeTo(0.465, 1e-12));

      for (int p = 0; p < Difficulty.plateauObstacle + 5; p++) {
        expect(Difficulty.scrollSpeedAt(p + 1),
            greaterThanOrEqualTo(Difficulty.scrollSpeedAt(p)),
            reason: 'the world may never slow down (progress $p)');
      }
    });

    test('gap height starts at the shipped value, narrows, and stops', () {
      expect(Difficulty.gapHeightAt(0), GameModel.gapHeight);
      expect(Difficulty.gapHeightAt(Difficulty.warmUpObstacles),
          GameModel.gapHeight);
      expect(Difficulty.gapHeightAt(Difficulty.plateauObstacle),
          Difficulty.tightestGapHeight);
      expect(Difficulty.gapHeightAt(100000), Difficulty.tightestGapHeight);

      // Half way: 0.28 and 0.252 meet at 0.266.
      expect(Difficulty.gapHeightAt(30), closeTo(0.266, 1e-12));

      for (int p = 0; p < Difficulty.plateauObstacle + 5; p++) {
        expect(Difficulty.gapHeightAt(p + 1),
            lessThanOrEqualTo(Difficulty.gapHeightAt(p)),
            reason: 'the gap may never widen (index $p)');
      }
    });

    test('a ramped gap still fits inside the playfield with room over', () {
      // The centre band is deliberately NOT re-derived from the ramped height,
      // so the narrowest gap sits strictly inside the space the base gap
      // occupied — further from the ceiling and the floor, not closer.
      final double h = Difficulty.tightestGapHeight;
      expect(GameModel.minGapCentre - h / 2, greaterThan(playfieldTop));
      expect(GameModel.maxGapCentre + h / 2, lessThan(playfieldBottom));
      expect(h, greaterThan(GameModel.carHeight));

      // And the band itself did not move when the ramp arrived.
      expect(GameModel.minGapCentre, closeTo(0.22, 1e-12));
      expect(GameModel.maxGapCentre, closeTo(0.78, 1e-12));
    });

    test('settingsAt bundles the three functions and nothing else', () {
      for (final int p in <int>[0, 7, 10, 11, 25, 49, 50, 51, 5000]) {
        expect(
          Difficulty.settingsAt(p),
          DifficultySettings(
            scrollSpeed: Difficulty.scrollSpeedAt(p),
            gapHeight: Difficulty.gapHeightAt(p),
            obstacleSpacing: Difficulty.spacingAt(p),
          ),
          reason: 'progress $p',
        );
      }
    });

    test('two settings differing in exactly one field are not equal', () {
      // `==` on a value type is mutated to `return true`, and nothing else in
      // this file ever compares two settings that differ.
      const DifficultySettings a = DifficultySettings(
          scrollSpeed: 0.45, gapHeight: 0.28, obstacleSpacing: 0.60);
      expect(
        a,
        const DifficultySettings(
            scrollSpeed: 0.45, gapHeight: 0.28, obstacleSpacing: 0.60),
      );
      expect(
        a,
        isNot(const DifficultySettings(
            scrollSpeed: 0.46, gapHeight: 0.28, obstacleSpacing: 0.60)),
      );
      expect(
        a,
        isNot(const DifficultySettings(
            scrollSpeed: 0.45, gapHeight: 0.27, obstacleSpacing: 0.60)),
      );
      expect(
        a,
        isNot(const DifficultySettings(
            scrollSpeed: 0.45, gapHeight: 0.28, obstacleSpacing: 0.61)),
      );
      expect(a, isNot('not a settings object'));
      expect(a.toString(), contains('0.45'));
    });
  });

  group('the ramp is actually wired into the game', () {
    // A ramp nothing calls is a ramp that does nothing. Each of these observes
    // the effect on a real run rather than on the function.

    test('obstacle 0 is built at the shipped gap height', () {
      final Obstacle first = midFieldRun().tick(frame).obstacles.single;
      expect(first.index, 0);
      expect(first.gapBottom - first.gapTop, closeTo(GameModel.gapHeight, 1e-12));
    });

    test('an obstacle past the plateau is built at the narrowest height', () {
      // Flown, not computed: the car has to actually get there, which is what
      // makes this a statement about `_spawnAt` rather than about `Difficulty`.
      final GameModel m = fly(midFieldRun(), 0.55, 5200);
      expect(m.state, RunState.playing, reason: 'the altitude hold died');
      expect(m.score, greaterThan(Difficulty.plateauObstacle),
          reason: 'never reached the plateau');

      final Obstacle deep = m.obstacles.last;
      expect(deep.index, greaterThanOrEqualTo(Difficulty.plateauObstacle));
      expect(
        deep.gapBottom - deep.gapTop,
        closeTo(Difficulty.tightestGapHeight, 1e-12),
      );
    });

    test('an obstacle keeps the height it was born with', () {
      // The rule the ramp must not break: a pipe cannot narrow while the car is
      // inside it. Obstacle 0 is followed for its whole life on screen.
      GameModel m = midFieldRun();
      double? height;
      for (int i = 0; i < 200; i++) {
        m = m.tick(frame);
        for (final Obstacle o in m.obstacles) {
          if (o.index != 0) continue;
          final double h = o.gapBottom - o.gapTop;
          height ??= h;
          expect(h, height, reason: 'obstacle 0 changed shape on frame $i');
        }
      }
      expect(height, isNotNull);
    });

    test('the world really does speed up once the ramp starts', () {
      // Measured as distance travelled by a pipe over a fixed number of frames,
      // which is the thing a player sees, rather than by reading the constant
      // back.
      double travelOver(GameModel m, int frames) {
        final double before = m.obstacles.first.x;
        final int index = m.obstacles.first.index;
        GameModel n = m;
        for (int i = 0; i < frames; i++) {
          if (n.y > 0.55) n = n.flap();
          n = n.tick(frame);
        }
        final Obstacle same =
            n.obstacles.firstWhere((Obstacle o) => o.index == index);
        return before - same.x;
      }

      final GameModel early = fly(midFieldRun(), 0.55, 30);
      expect(early.score, 0);
      expect(travelOver(early, 30), closeTo(GameModel.scrollSpeed * 0.5, 1e-9));

      final GameModel late = fly(midFieldRun(), 0.55, 5200);
      expect(late.score, greaterThan(Difficulty.plateauObstacle));
      expect(travelOver(late, 30),
          closeTo(Difficulty.topScrollSpeed * 0.5, 1e-9));
    });

    test('the run is still a pure function of its inputs across the ramp', () {
      // The property the whole ramp design exists to preserve. Two independent
      // runs, identical taps, driven past the plateau: every frame has to match,
      // or a recording made today would replay into a different course.
      GameModel a = GameModel.ready(gapCentreFor: (int _) => 0.5);
      GameModel b = GameModel.ready(gapCentreFor: (int _) => 0.5);
      for (int i = 0; i < 5200; i++) {
        final bool tap = i == 0 || a.y > 0.55;
        if (tap) {
          a = a.flap();
          b = b.flap();
        }
        a = a.tick(frame);
        b = b.tick(frame);
        expect(b, a, reason: 'the two runs diverged on frame $i');
      }
      expect(a.score, greaterThan(Difficulty.plateauObstacle));
    });

    test('a recorded run replays frame-exactly THROUGH the ramp, run code and '
        'all', () {
      // The end-to-end version of the claim above, and the one the whole
      // recording feature rests on: a run that crosses out of the warm-up is
      // written down as a short string, read back, and re-executed frame for
      // frame — including the difficulty it was played at.
      //
      // The taps come from the fairness prover rather than from a bot, because
      // a recording that died on obstacle 2 would never reach the ramp and this
      // test would pass while checking nothing about it.
      const int obstacles = 14;
      final ProofResult proof = FairnessProver()
          .prove(Course.fromSeed(0, 0, obstacles), witness: true);
      expect(proof.survivable, isTrue);

      final List<bool> inputs = proof.witness!;
      final Replay original = Replay(
        seed: 0,
        tapFrames: <int>[
          for (int i = 0; i < inputs.length; i++)
            if (inputs[i]) i,
        ],
        frames: inputs.length,
      );

      // Non-vacuous in the way that matters: the run really did leave the
      // warm-up, so the frames being compared below include obstacles the ramp
      // has narrowed.
      final List<GameModel> trace = replayTrace(original);
      expect(trace.last.score, greaterThan(Difficulty.warmUpObstacles),
          reason: 'the recording never got past the warm-up, so nothing about '
              'the ramp was replayed');
      final double narrowest = trace.last.obstacles
          .map((Obstacle o) => o.gapBottom - o.gapTop)
          .reduce((double a, double b) => a < b ? a : b);
      expect(narrowest, lessThan(GameModel.gapHeight),
          reason: 'no ramped obstacle was ever on screen');

      // Through the wire and back.
      final Replay? decoded = decodeRunCode(encodeRunCode(original)).replay;
      expect(decoded, original);

      final List<GameModel> again = replayTrace(decoded!);
      expect(again, hasLength(trace.length));
      for (int i = 0; i < trace.length; i++) {
        // Whole-model equality, frame by frame — not just the final score.
        // Two trajectories can diverge and re-converge, so comparing only the
        // end would pass for a replay that took a different route.
        expect(again[i], trace[i], reason: 'frame $i differs after a round trip');
      }
    });
  });
}
