/// The tuning numbers, pinned to ABSOLUTE values.
///
/// WHY THIS FILE EXISTS, AND WHY IT IS NOT A DUPLICATE OF
/// `game_model_test.dart`:
///
/// Nearly every assertion in the older files is stated in terms of the model's
/// own constants — `closeTo(GameModel.gravity * frame, 1e-12)`,
/// `expect(m.y, GameModel.minY)`, `closeTo(GameModel.obstacleSpacing, 1e-9)`.
/// Those are the right assertions for the RULES, because they keep testing the
/// relationship when the tuning is deliberately changed. But they are blind to
/// the tuning itself: change `gravity` from 2.2 to 2.42 and both sides of every
/// one of those comparisons move together, so the suite stays green while the
/// game plays differently.
///
/// `tool/mutate.dart` found exactly that. Perturbing eleven of the tuning
/// constants by ten percent left all 57 tests passing. Those survivors are the
/// reason for this file: every assertion below is an absolute number, derived
/// from the tuning comment that justifies the constant, so a silent re-tune
/// fails here and nowhere else.
///
/// WHAT THIS FILE IS NOT: it is not a snapshot of the current values for their
/// own sake. Each number is the game-facing CONSEQUENCE the constant was chosen
/// to produce — how much speed half a second of falling adds, how far apart the
/// pipes stand, how tall the gap is — so a failure here reads as "the game
/// changed" rather than "a literal moved".
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:flappymiata/game/game_model.dart';

/// One frame at 60fps, as everywhere else in this suite.
const double frame = 1.0 / 60.0;

/// A run started with every gap pinned to mid-field, so nothing below is
/// accidentally about collision.
GameModel midFieldRun() => GameModel.ready(gapCentreFor: (int _) => 0.5).flap();

void main() {
  group('the car physics are the numbers the comments promise', () {
    test('a flap assigns exactly -0.72, and half a second of falling adds '
        'exactly 1.1 to the downward speed', () {
      // gravity = 2.2 playfield-heights per second squared, so half a second
      // is 1.1. Written as the OBSERVED change in velocity over a known dt
      // rather than as `expect(GameModel.gravity, 2.2)`: this fails if the
      // constant moves AND if the integrator stops applying it once per step.
      final GameModel start = const GameModel.ready().flap();
      expect(start.state, RunState.playing);
      expect(start.velocity, closeTo(-0.72, 1e-15));

      final GameModel after = start.tick(0.5);
      expect(after.state, RunState.playing, reason: 'half a second is survivable');
      expect(after.velocity - start.velocity, closeTo(1.1, 1e-12));
    });

    test('one flap climbs 0.118 of the playfield and peaks after 0.33s', () {
      // The two numbers the `flapImpulse` comment quotes: the arc is
      // flapImpulse^2 / (2 * gravity) tall and takes -flapImpulse / gravity to
      // reach its peak. Flown, not computed from the constants, so the
      // integrator is on trial here as well as the tuning.
      GameModel m = const GameModel.ready().flap();
      final double startY = m.y;
      double peak = startY;
      double timeToPeak = 0.0;
      for (int i = 1; i <= 60; i++) {
        m = m.tick(frame);
        if (m.y < peak) {
          peak = m.y;
          timeToPeak = i * frame;
        }
      }
      // The arc measured at 60fps is 0.1119, a little under the continuous
      // 0.1178, because a sampler that only looks 60 times a second never sees
      // the true apex — it sees the highest frame. Asserting the SAMPLED value
      // rather than the ideal one is what lets the tolerance be tight enough to
      // notice a ten percent change in gravity.
      expect(startY - peak, closeTo(0.1119, 0.003));
      expect(timeToPeak, closeTo(0.327, 0.02));
    });

    test('a fresh run starts at 0.4 — above centre, with more room to fall '
        'than to rise', () {
      const GameModel ready = GameModel.ready();
      expect(ready.y, closeTo(0.4, 1e-15));
      expect(ready.velocity, 0.0);
      // The asymmetry the constant exists for, stated so that moving startY to
      // 0.5 or 0.6 is a decision somebody has to make on purpose.
      expect(GameModel.maxY - ready.y, greaterThan(ready.y - GameModel.minY));
    });
  });

  group('the playfield is the unit square', () {
    test('the edges are 0 and 1 exactly', () {
      expect(playfieldTop, 0.0);
      expect(playfieldBottom, 1.0);
      expect(playfieldLeft, 0.0);
      expect(playfieldRight, 1.0);
      expect(GameModel.minY, 0.0);
      expect(GameModel.maxY, 1.0);
    });

    test('every zero in the model is POSITIVE zero, not negative zero', () {
      // Dart has two zeros and `-0.0 == 0.0` is true, so not one equality
      // assertion in this suite can tell them apart — which is exactly why a
      // constant that quietly became `-0.0` survived the whole mutation run.
      //
      // They are still different doubles. `(-0.0).toString()` is '-0.0', so
      // every logged frame and every failure message would carry it; and
      // `1 / -0.0` is negative infinity, so the first piece of code that
      // divides by a playfield edge inherits a sign error out of nowhere.
      // `isNegative` is the only operator here that can see the difference.
      expect(playfieldTop.isNegative, isFalse);
      expect(playfieldLeft.isNegative, isFalse);
      expect(GameModel.minY.isNegative, isFalse);
      expect(const GameModel.ready().velocity.isNegative, isFalse);
    });
  });

  group('the obstacle course is the size the comments promise', () {
    test('a pipe is 0.16 wide and its gap is 0.28 tall', () {
      final Obstacle o = midFieldRun().tick(frame).obstacles.single;
      expect(o.right - o.left, closeTo(0.16, 1e-12));
      expect(o.gapBottom - o.gapTop, closeTo(0.28, 1e-12));
      // Nine car-heights, which is the ratio the gapHeight comment justifies
      // the value with. Flappy Bird's is about 4.2, and the difference is paid
      // for by a car two and a third times wider than it is tall.
      expect(
        (o.gapBottom - o.gapTop) / GameModel.carHeight,
        closeTo(9.0, 0.05),
      );
    });

    test('consecutive pipes stand exactly 0.60 apart, one every 1.33s', () {
      // Absolute, where `game_model_test.dart` states the same fact relative to
      // `GameModel.obstacleSpacing` and `GameModel.scrollSpeed`. Both spellings
      // are worth having: that one survives a deliberate re-tune, this one
      // notices an accidental one.
      GameModel m = midFieldRun();
      final List<GameModel> trace = <GameModel>[];
      for (int i = 0; i < 400; i++) {
        if (m.y > 0.55) m = m.flap();
        m = m.tick(frame);
        trace.add(m);
      }

      var checked = 0;
      for (final GameModel f in trace) {
        for (int i = 1; i < f.obstacles.length; i++) {
          expect(f.obstacles[i].x - f.obstacles[i - 1].x, closeTo(0.60, 1e-9));
          checked++;
        }
      }
      expect(checked, greaterThan(50), reason: 'never saw two pipes at once');

      // And the cadence in seconds, which is what the player actually feels.
      final List<int> spawnFrames = <int>[];
      for (int i = 0; i < trace.length; i++) {
        final int previous = i == 0 ? 1 : trace[i - 1].nextObstacleIndex;
        if (trace[i].nextObstacleIndex > previous) spawnFrames.add(i);
      }
      expect(spawnFrames.length, greaterThanOrEqualTo(4));
      for (int i = 1; i < spawnFrames.length; i++) {
        expect((spawnFrames[i] - spawnFrames[i - 1]) * frame,
            closeTo(1.3333, 0.02));
      }
    });

    test('the world scrolls 0.45 playfield-widths per second, so a pipe takes '
        '1.55s to reach the car', () {
      GameModel m = midFieldRun().tick(frame);
      final double before = m.obstacles.single.x;
      expect(before, closeTo(1.0, 1e-12));

      for (int i = 0; i < 60; i++) {
        if (m.y > 0.55) m = m.flap();
        m = m.tick(frame);
      }
      final double after = m.obstacles.first.x;
      expect(before - after, closeTo(0.45, 1e-9));

      // The approach the tuning comment sells: 1.55 seconds from the right
      // edge to the car.
      expect((before - 0.30) / 0.45, closeTo(1.5556, 0.001));
    });

    test('the car sits at 0.30 and its box is 0.164 by 0.031', () {
      final Box box = GameModel.carBoxAt(0.5);
      expect((box.left + box.right) / 2, closeTo(0.30, 1e-12));
      expect(box.right - box.left, closeTo(0.16419, 1e-5));
      expect(box.bottom - box.top, closeTo(0.031, 1e-12));

      // Left of centre on purpose: 70% of the screen is warning, 30% is
      // history. A car at the middle halves the reaction time for no gain.
      expect((box.left + box.right) / 2, lessThan(0.5));
    });

    test('a gap centre is held between 0.22 and 0.78', () {
      // gapHeight / 2 + gapMargin, and its mirror. Absolute, because every
      // existing assertion about the clamp is written against
      // `GameModel.minGapCentre` itself and so cannot see it move.
      expect(GameModel.minGapCentre, closeTo(0.22, 1e-12));
      expect(GameModel.maxGapCentre, closeTo(0.78, 1e-12));

      // And what the margin buys, in the units the comment argues in: one and
      // a half car-heights of clear pipe above the highest gap.
      final Obstacle highest = GameModel.ready(gapCentreFor: (int _) => -1.0)
          .flap()
          .tick(frame)
          .obstacles
          .single;
      expect(highest.gapTop, closeTo(0.08, 1e-12));
      expect(highest.gapTop / GameModel.carHeight, closeTo(2.58, 0.01));
    });
  });

  group('the gap pattern is the published hash, value for value', () {
    // WHY GOLDEN VALUES AND A SECOND IMPLEMENTATION, rather than the range and
    // scatter checks that were already here:
    //
    // `defaultGapCentre` stands in for a random number generator, and the only
    // contract a hash has is its exact output. Every existing assertion about
    // it is a property — "inside the band", "500 distinct values out of 500",
    // "the same answer twice" — and a property is satisfied by an enormous
    // family of different hashes. `tool/mutate.dart` proved that concretely:
    // changing a multiplier, a shift distance, the seed offset or the 2^32
    // divisor left every one of those properties true, so twenty-six separate
    // mutations of this function survived the whole suite. A run recorded on
    // one build would then replay into a different course on another, and
    // nothing would say so.

    /// The documented algorithm, written out a second time from the comment in
    /// `game_model.dart` rather than imported: MurmurHash3's 32-bit finaliser
    /// over `(index + 1) * 0x9E3779B1`, mapped onto the legal band. Every
    /// constant here is a literal, so this stays a genuinely independent
    /// statement of what the pattern is supposed to be.
    double referenceGapCentre(int index) {
      int h = (index + 1) & 0xFFFFFFFF;
      h = (h * 0x9E3779B1) & 0xFFFFFFFF;
      h = h ^ (h >> 16);
      h = (h * 0x85EBCA6B) & 0xFFFFFFFF;
      h = h ^ (h >> 13);
      h = (h * 0xC2B2AE35) & 0xFFFFFFFF;
      h = h ^ (h >> 16);
      const double minGap = 0.28 / 2 + 0.08;
      const double maxGap = 1.0 - 0.28 / 2 - 0.08;
      return minGap + (h / 4294967296.0) * (maxGap - minGap);
    }

    test('the first eight gaps are exactly these numbers', () {
      // Recorded from the shipped function and independently reproduced by
      // `referenceGapCentre` above. If this list has to change, the change is
      // a different game: every recorded run and every fairness witness was
      // proved against these positions.
      const List<double> golden = <double>[
        0.2593494626320899,
        0.6294272569194437,
        0.6895252630859614,
        0.7576993183977903,
        0.5558063750900328,
        0.5018399865180254,
        0.5379427675157786,
        0.762647825870663,
      ];
      for (int i = 0; i < golden.length; i++) {
        expect(
          GameModel.defaultGapCentre(i),
          closeTo(golden[i], 1e-12),
          reason: 'gap $i',
        );
      }
    });

    test('the shipped hash and an independent one agree over 500 indices', () {
      for (int i = 0; i < 500; i++) {
        expect(
          GameModel.defaultGapCentre(i),
          closeTo(referenceGapCentre(i), 1e-12),
          reason: 'index $i',
        );
      }
      // Non-vacuous: the two implementations have to be agreeing on something
      // that actually varies, not on a constant.
      final Set<double> distinct = <double>{
        for (int i = 0; i < 500; i++) referenceGapCentre(i),
      };
      expect(distinct.length, greaterThan(400));
    });

    test('the band the hash maps onto is the full legal band, corner to '
        'corner', () {
      // A mix that produced only the middle of the range would pass the golden
      // check for eight indices and still make a duller game. 4000 indices,
      // and the extremes have to get within a percent of both walls.
      double lowest = 1.0;
      double highest = 0.0;
      for (int i = 0; i < 4000; i++) {
        final double c = GameModel.defaultGapCentre(i);
        if (c < lowest) lowest = c;
        if (c > highest) highest = c;
      }
      expect(lowest, closeTo(0.22, 0.006));
      expect(highest, closeTo(0.78, 0.006));
    });
  });
}
