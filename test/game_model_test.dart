import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:flappymiata/game/game_model.dart';

/// One frame at 60fps. The model never asks what the frame rate is — it only
/// ever sees a `dt` — so the tests supply their own and no real time passes.
/// That is the whole point of taking time as a parameter: a two-minute run can
/// be simulated in microseconds, exactly.
const double frame = 1.0 / 60.0;

/// Ticks [count] frames and returns the resulting model.
GameModel tickFrames(GameModel model, int count) {
  var m = model;
  for (var i = 0; i < count; i++) {
    m = m.tick(frame);
  }
  return m;
}

void main() {
  group('tick — integration', () {
    test('gravity accumulates: repeated ticks increase downward velocity', () {
      // flap() is the only door out of `ready`, so a run under gravity always
      // starts with one.
      var m = const GameModel.ready().flap();
      expect(m.state, RunState.playing);

      final v0 = m.velocity;
      m = m.tick(frame);
      final v1 = m.velocity;
      m = m.tick(frame);
      final v2 = m.velocity;

      expect(v1, greaterThan(v0));
      expect(v2, greaterThan(v1));

      // Not just "bigger" — bigger by exactly gravity * dt each step. A test
      // that only checks the direction would still pass if gravity were
      // applied twice per frame, or halved.
      expect(v1 - v0, closeTo(GameModel.gravity * frame, 1e-12));
      expect(v2 - v1, closeTo(GameModel.gravity * frame, 1e-12));
    });

    test('position integrates: y actually moves under repeated ticks', () {
      final start = const GameModel.ready().flap();

      // Immediately after a flap the velocity is upward, so y must decrease.
      final rising = start.tick(frame);
      expect(rising.y, lessThan(start.y));

      // Semi-implicit Euler moves by the NEW velocity, so the first step is
      // (flapImpulse + gravity * dt) * dt, not flapImpulse * dt. Asserting the
      // exact value is what pins the integration order down; a version that
      // integrated in the other order lands somewhere else on frame one.
      final expectedFirstStep =
          (GameModel.flapImpulse + GameModel.gravity * frame) * frame;
      expect(rising.y - start.y, closeTo(expectedFirstStep, 1e-12));

      // Gravity eventually wins: after ~40 frames the car is below where it
      // started. This is the arc, not just a single step.
      final later = tickFrames(start, 40);
      expect(later.y, greaterThan(start.y));
    });
  });

  group('frozen states', () {
    test('ready is frozen: ticking a ready model changes nothing', () {
      const ready = GameModel.ready();

      expect(ready.tick(frame), ready);

      // Also over a long span and a coarse dt — "nothing moves" must not mean
      // "moves too little to notice".
      expect(tickFrames(ready, 600), ready);
      expect(ready.tick(5.0), ready);
    });

    test('dead is frozen: ticking a dead model changes nothing', () {
      final dead = fallUntilDead();
      expect(dead.state, RunState.dead);

      // NOTE ON WHY THIS FIXTURE IS THE RIGHT ONE: a dead model that came from
      // hitting the floor has a large positive velocity and sits at y == maxY.
      // y alone could not detect a leaked tick — the car is already pinned at
      // the bottom, so a stray integration would leave y at 1.0 either way.
      // Velocity is the field that would move, and comparing whole models is
      // what catches it.
      expect(dead.velocity, greaterThan(0.0));

      expect(dead.tick(frame), dead);
      expect(tickFrames(dead, 600), dead);
    });
  });

  group('flap', () {
    test('flap from ready enters playing and sets upward velocity', () {
      const ready = GameModel.ready();
      final flapped = ready.flap();

      expect(flapped.state, RunState.playing);
      expect(flapped.velocity, GameModel.flapImpulse);
      expect(flapped.velocity, lessThan(0.0), reason: 'negative y is upward');

      // The first tap starts the run and lifts the car in one action; it does
      // not teleport it.
      expect(flapped.y, ready.y);
    });

    test('flap during playing replaces velocity rather than adding to it', () {
      // Fall for a while so the current velocity is large, positive, and
      // nothing like the impulse — if it were near flapImpulse already, the
      // assertion below could not tell assignment from addition.
      final falling = tickFrames(const GameModel.ready().flap(), 30);
      expect(falling.state, RunState.playing);
      expect(falling.velocity, greaterThan(0.0));

      final flapped = falling.flap();

      // Assignment: the old velocity is discarded entirely.
      expect(flapped.velocity, GameModel.flapImpulse);

      // And explicitly NOT addition. Spelled out because this is the line that
      // decides how the game feels, and `+=` would still pass a test that only
      // checked the velocity went negative.
      expect(
        flapped.velocity,
        isNot(closeTo(falling.velocity + GameModel.flapImpulse, 1e-12)),
      );

      // Two flaps in a row cannot climb faster than one.
      expect(flapped.flap().velocity, GameModel.flapImpulse);
    });

    test('flap while dead does nothing', () {
      final dead = fallUntilDead();
      expect(dead.state, RunState.dead);

      expect(dead.flap(), dead);
      expect(dead.flap().flap().flap(), dead);
    });
  });

  group('reset', () {
    test('reset returns to ready from playing', () {
      final playing = tickFrames(const GameModel.ready().flap(), 10);
      expect(playing.state, RunState.playing);

      expect(playing.reset(), const GameModel.ready());
    });

    test('reset returns to ready from dead', () {
      final dead = fallUntilDead();
      expect(dead.state, RunState.dead);

      final fresh = dead.reset();
      expect(fresh, const GameModel.ready());

      // A restart that kept the old velocity would be a restart in name only.
      expect(fresh.velocity, 0.0);
      expect(fresh.y, GameModel.startY);
    });
  });

  group('out-of-bounds death', () {
    test('leaving the top of the playfield kills the run', () {
      // Flapping every frame climbs, because each flap re-assigns the upward
      // velocity before gravity can cancel it. This is a player mashing the
      // button, which is exactly how the ceiling gets hit in practice.
      var m = const GameModel.ready().flap();
      var frames = 0;
      const budget = 300;
      while (m.state == RunState.playing && frames < budget) {
        m = m.flap().tick(frame);
        frames++;
      }

      // If the loop ran out of frames instead of dying, that is a failure and
      // not a pass — say so, rather than letting the assertions below read a
      // still-playing model.
      expect(
        frames,
        lessThan(budget),
        reason: 'never left the top within $budget frames',
      );
      expect(m.state, RunState.dead);
      expect(m.y, GameModel.minY);
    });

    test('leaving the bottom of the playfield kills the run', () {
      // One flap to start the run, then hands off the controls. Gravity does
      // the rest.
      var m = const GameModel.ready().flap();
      var frames = 0;
      const budget = 300;
      while (m.state == RunState.playing && frames < budget) {
        m = m.tick(frame);
        frames++;
      }

      expect(
        frames,
        lessThan(budget),
        reason: 'never left the bottom within $budget frames',
      );
      expect(m.state, RunState.dead);
      expect(m.y, GameModel.maxY);
    });

    test('death happens on crossing the bound, not on approaching it', () {
      // Guards against an over-eager bound: a model well inside the playfield
      // must stay alive. Without this, `state = dead` on every tick would pass
      // both tests above.
      final alive = tickFrames(const GameModel.ready().flap(), 5);
      expect(alive.state, RunState.playing);
      expect(alive.y, greaterThan(GameModel.minY));
      expect(alive.y, lessThan(GameModel.maxY));
    });
  });

  group('determinism', () {
    test('two identical tick sequences from the same start produce equal '
        'results', () {
      // A mixed script of flaps and ticks — a straight fall would be a weaker
      // test, because it exercises one branch of tick and no branch of flap.
      List<GameModel> run() {
        final trace = <GameModel>[];
        var m = const GameModel.ready();
        for (var i = 0; i < 120; i++) {
          if (i % 17 == 0) m = m.flap();
          m = m.tick(frame);
          trace.add(m);
        }
        return trace;
      }

      final a = run();
      final b = run();

      // Whole trace, not just the final model: a difference that appeared mid
      // run and washed out by the end would slip past an end-state comparison.
      expect(a, equals(b));
      expect(a.length, 120);

      // And the run must actually have gone somewhere. Comparing two traces of
      // identical frozen models would be trivially equal and prove nothing.
      expect(a.map((m) => m.y).toSet().length, greaterThan(1));
    });

    test('the same dt from the same model always gives the same next model', () {
      final m = tickFrames(const GameModel.ready().flap(), 7);
      expect(m.tick(frame), m.tick(frame));
      expect(m.flap().tick(frame), m.flap().tick(frame));
    });

    test('two identical runs with the same injected gap pattern are equal', () {
      // The obstacle half of determinism. The test above only moved the car;
      // this one also scrolls, spawns, collides and scores, so a difference
      // anywhere in the new code shows up here.
      double gaps(int index) => 0.48 + 0.02 * (index % 3);

      List<GameModel> run() => hoverTrace(startRun(gaps), 0.55, 400);

      final a = run();
      final b = run();

      expect(a, equals(b));

      // Non-vacuous: the run has to have contained obstacles and moved the
      // score, or two empty traces would compare equal and prove nothing.
      expect(a.last.nextObstacleIndex, greaterThan(1));
      expect(a.map((m) => m.score).toSet().length, greaterThan(1));
    });

    test('the default gap pattern is a pure function of the index', () {
      // The hash stands in for a random number generator, so the property that
      // matters is that it has no memory: obstacle 7 is in the same place
      // whether it is the first thing asked for or the thousandth.
      expect(GameModel.defaultGapCentre(7), GameModel.defaultGapCentre(7));

      final forwards = <double>[
        for (var i = 0; i < 50; i++) GameModel.defaultGapCentre(i),
      ];
      final backwards = <double>[
        for (var i = 49; i >= 0; i--) GameModel.defaultGapCentre(i),
      ];
      expect(forwards, equals(backwards.reversed.toList()));
    });

    test('lib/game contains no clock and no randomness', () {
      // A STRUCTURAL guard, not a behavioural one. The tests above can only
      // show that today's code is deterministic; they cannot stop tomorrow's
      // `DateTime.now()` from being added. This reads the sources instead, so
      // the ban is enforced rather than merely intended.
      final dir = Directory('lib/game');
      expect(
        dir.existsSync(),
        isTrue,
        reason: 'run from the package root, so lib/game is visible',
      );

      final sources = dir
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.dart'))
          .toList();

      // If the glob matched nothing, everything below is vacuously true. Fail
      // loudly instead.
      expect(sources, isNotEmpty, reason: 'found no Dart sources in lib/game');

      const banned = <String>[
        'DateTime.now(',
        'Stopwatch(',
        'dart:math',
        'Random(',
        'package:flame/',
        'package:flutter/',
      ];

      for (final file in sources) {
        final text = stripLineComments(file.readAsStringSync());
        for (final needle in banned) {
          expect(
            text.contains(needle),
            isFalse,
            reason: '${file.path} contains "$needle"',
          );
        }
      }
    });
  });

  group('gap positions', () {
    test('the model asks the injected pattern where each gap goes', () {
      // The gap pattern is the seam this whole feature hangs on: it is how
      // variation gets in without a random number generator. If the model
      // quietly generated its own gaps instead, every collision test below
      // would be aiming at the wrong place.
      final m = startRun((_) => 0.42).tick(frame);

      expect(m.obstacles, hasLength(1));
      expect(m.obstacles.first.gapCentre, 0.42);
      expect(m.obstacles.first.gapHeight, GameModel.gapHeight);
      expect(m.obstacles.first.width, GameModel.obstacleWidth);
    });

    test('gap centres are clamped away from the ceiling and the floor', () {
      // A pattern is caller-supplied data and may be nonsense. A gap centred
      // at y = -1.0 would put the whole flyable space outside the playfield,
      // where the out-of-bounds rule kills the car anyway — an obstacle nobody
      // can pass.
      final tooHigh = startRun((_) => -1.0).tick(frame).obstacles.first;
      expect(tooHigh.gapCentre, GameModel.minGapCentre);

      final tooLow = startRun((_) => 2.0).tick(frame).obstacles.first;
      expect(tooLow.gapCentre, GameModel.maxGapCentre);

      // A legal value must pass through untouched, or the clamp would be
      // flattening every gap onto the same two lines and the tests above would
      // still be green.
      expect(GameModel.clampGapCentre(0.5), 0.5);

      // And the clamped band has to leave real pipe at both ends, otherwise
      // "clamped" would still mean "flush with the edge".
      expect(tooHigh.gapTop, greaterThanOrEqualTo(GameModel.gapMargin));
      expect(tooLow.gapBottom, lessThanOrEqualTo(1.0 - GameModel.gapMargin));
    });

    test('the default pattern scatters inside the legal band', () {
      final centres = <double>[
        for (var i = 0; i < 500; i++) GameModel.defaultGapCentre(i),
      ];

      for (final c in centres) {
        expect(c, greaterThanOrEqualTo(GameModel.minGapCentre));
        expect(c, lessThanOrEqualTo(GameModel.maxGapCentre));
      }

      // In range is not enough — a pattern that returned 0.5 forever would
      // satisfy every assertion above and make the game a straight corridor.
      // Observed on this hash: 500 distinct values out of 500.
      expect(centres.toSet().length, greaterThan(400));
    });

    test('obstacle indices are requested in order and never reused', () {
      // The pattern is only as good as the sequence it is fed. An index that
      // repeated would replay an earlier gap; one that skipped would desync a
      // recorded run from a live one.
      final asked = <int>[];
      final start = GameModel.ready(
        gapCentreFor: (index) {
          asked.add(index);
          return 0.5;
        },
      ).flap();

      hoverTrace(start, 0.55, 400);

      expect(asked, isNotEmpty);
      expect(asked, List<int>.generate(asked.length, (i) => i));
    });
  });

  group('obstacles — scrolling and spawning', () {
    test('obstacles scroll toward the car over repeated ticks', () {
      var m = startRun((_) => 0.5).tick(frame);

      // The first obstacle is born at the right edge of the playfield, which
      // is the far end of the 1.55s approach the tuning comment promises.
      expect(m.obstacles, hasLength(1));
      expect(m.obstacles.first.index, 0);
      expect(m.obstacles.first.x, closeTo(playfieldRight, 1e-12));

      const int steps = 20;
      final double before = m.obstacles.first.x;
      m = tickFrames(m, steps);
      final double after = m.obstacles.first.x;

      expect(after, lessThan(before), reason: 'obstacles move left, toward car');

      // Not just "leftward" — leftward by exactly the scroll speed. A test that
      // only checked the direction would pass at half speed or double.
      expect(
        before - after,
        closeTo(GameModel.scrollSpeed * frame * steps, 1e-12),
      );

      // And still short of the car, so this test is about scrolling and not
      // accidentally about collision.
      expect(after, greaterThan(GameModel.carX));
      expect(m.state, RunState.playing);
    });

    test('a new obstacle appears on cadence', () {
      final trace = hoverTrace(startRun((_) => 0.5), 0.55, 400);

      // Every frame on which the model created an obstacle.
      final spawnFrames = <int>[];
      for (var i = 0; i < trace.length; i++) {
        final int previous = i == 0 ? 0 : trace[i - 1].nextObstacleIndex;
        if (trace[i].nextObstacleIndex > previous) spawnFrames.add(i);
      }

      expect(spawnFrames.length, greaterThanOrEqualTo(4));

      // Derived from the constants rather than typed in, so tuning the game
      // re-derives the expectation instead of breaking the test. One frame of
      // slack because a spawn can only happen on a frame boundary.
      final double cadence =
          GameModel.obstacleSpacing / (GameModel.scrollSpeed * frame);
      for (var i = 1; i < spawnFrames.length; i++) {
        expect(
          (spawnFrames[i] - spawnFrames[i - 1]).toDouble(),
          closeTo(cadence, 1.0),
          reason: 'gap between spawns $i and ${i - 1}',
        );
      }

      // The spacing on screen, which is what the player actually experiences,
      // and the indices, which are what the gap pattern is fed.
      for (final m in trace) {
        for (var i = 1; i < m.obstacles.length; i++) {
          expect(
            m.obstacles[i].x - m.obstacles[i - 1].x,
            closeTo(GameModel.obstacleSpacing, 1e-9),
          );
          expect(m.obstacles[i].index, m.obstacles[i - 1].index + 1);
        }
      }

      // Obstacles that have left the screen are dropped, so the list is a
      // window and not a log. Without this the model leaks one object per
      // 1.33s for as long as the run lasts.
      expect(trace.last.obstacles.length, lessThan(4));
      expect(trace.last.nextObstacleIndex, greaterThan(4));
      for (final o in trace.last.obstacles) {
        expect(o.right, greaterThanOrEqualTo(playfieldLeft));
      }
    });
  });

  group('collision', () {
    test('a near miss through the gap leaves the run alive', () {
      // THE MOST IMPORTANT TEST IN THIS FILE.
      //
      // Every other collision test below is passed by an implementation that
      // simply kills the car unconditionally. This is the only one that is not,
      // which makes it the test that decides whether the other two mean
      // anything at all.
      const double gapCentre = 0.5;

      // The line the car is flown along. It sits BELOW the gap centre on
      // purpose: a flap arc is asymmetric, climbing 0.118 above the point it
      // was fired from and dipping only a frame's worth below it, so a car
      // hovering on a line occupies a band that hangs above that line.
      // Offsetting the line downward centres the band on the gap. Measured
      // band for these constants: y stays within [0.437, 0.561].
      const double line = 0.55;

      final trace = hoverTrace(startRun((_) => gapCentre), line, 240);

      // Count the frames on which obstacle 0 was actually level with the car —
      // the danger window. Without this the test could pass by never reaching
      // a pipe at all, which is the failure mode it exists to rule out.
      var crossingFrames = 0;
      for (final m in trace) {
        final matches = m.obstacles.where((o) => o.index == 0).toList();
        if (matches.isEmpty) continue;
        final Obstacle o = matches.first;
        final Box car = GameModel.carBoxAt(m.y);

        if (car.right > o.left && car.left < o.right) {
          crossingFrames++;
          // A near miss, spelled out: the car was inside the gap with clear air
          // above and below, not merely lucky.
          expect(car.top, greaterThan(o.gapTop));
          expect(car.bottom, lessThan(o.gapBottom));
        }
      }

      // The window is (carWidth + obstacleWidth) / scrollSpeed seconds, about
      // 35 frames at 60fps.
      expect(
        crossingFrames,
        greaterThanOrEqualTo(30),
        reason: 'the car never actually drew level with a pipe',
      );

      // Alive on every single frame, not merely alive at the end.
      for (final m in trace) {
        expect(m.state, RunState.playing);
      }

      // And it got through: the pipe it threaded is behind it and paid out.
      expect(trace.last.score, greaterThanOrEqualTo(1));
    });

    test('a collision with the top pipe kills the run', () {
      // Gap high up, car flown low: the car meets the pipe hanging from the
      // ceiling, which spans y = 0.0 down to gapTop.
      final trace = hoverTrace(startRun((_) => 0.75), 0.35, 240);
      final dead = trace.last;

      expect(dead.state, RunState.dead);

      // WHICH death this was. Out-of-bounds pins y to exactly minY or maxY, so
      // a y strictly inside the playfield can only have come from a pipe.
      // Without this the test would also pass on a car that fell through the
      // floor without ever meeting an obstacle.
      expect(dead.y, greaterThan(GameModel.minY));
      expect(dead.y, lessThan(GameModel.maxY));

      // And which pipe: the car centre was above the gap, i.e. inside the
      // upper pipe rather than the lower one.
      expect(dead.obstacles.first.index, 0);
      expect(dead.y, lessThan(dead.obstacles.first.gapTop));

      // Nothing was scored, because the car never got past anything.
      expect(dead.score, 0);
    });

    test('a collision with the bottom pipe kills the run', () {
      // Mirror image: gap low, car flown high, so the car meets the pipe
      // standing on the floor, which spans gapBottom down to y = 1.0.
      final trace = hoverTrace(startRun((_) => 0.25), 0.75, 240);
      final dead = trace.last;

      expect(dead.state, RunState.dead);

      expect(dead.y, greaterThan(GameModel.minY));
      expect(dead.y, lessThan(GameModel.maxY));

      expect(dead.obstacles.first.index, 0);
      expect(dead.y, greaterThan(dead.obstacles.first.gapBottom));

      expect(dead.score, 0);
    });

    test('the two pipes of one obstacle are the space the gap is not', () {
      // A structural check on the boxes themselves, independent of any run.
      // Collision is four comparisons and it is worth being able to see them
      // laid out once.
      const Obstacle o = Obstacle(
        index: 0,
        x: 0.5,
        width: 0.2,
        gapCentre: 0.5,
        gapHeight: 0.3,
      );

      expect(o.topBox, const Box(left: 0.4, top: 0.0, right: 0.6, bottom: 0.35));
      expect(
        o.bottomBox,
        const Box(left: 0.4, top: 0.65, right: 0.6, bottom: 1.0),
      );

      // Inside the gap: clear of both pipes.
      const Box inGap = Box(left: 0.45, top: 0.48, right: 0.55, bottom: 0.52);
      expect(inGap.overlaps(o.topBox), isFalse);
      expect(inGap.overlaps(o.bottomBox), isFalse);

      // Same x, too high: into the upper pipe only.
      const Box high = Box(left: 0.45, top: 0.20, right: 0.55, bottom: 0.24);
      expect(high.overlaps(o.topBox), isTrue);
      expect(high.overlaps(o.bottomBox), isFalse);

      // Same x, too low: into the lower pipe only.
      const Box low = Box(left: 0.45, top: 0.80, right: 0.55, bottom: 0.84);
      expect(low.overlaps(o.topBox), isFalse);
      expect(low.overlaps(o.bottomBox), isTrue);

      // Right height to be hit, but nowhere near horizontally. This is the half
      // of the AABB test that a "do the y ranges overlap?" implementation would
      // get wrong, and every scenario above would still pass.
      const Box farLeft = Box(left: 0.0, top: 0.20, right: 0.1, bottom: 0.24);
      expect(farLeft.overlaps(o.topBox), isFalse);
      expect(farLeft.overlaps(o.bottomBox), isFalse);

      // Sharing exactly one edge is a scrape, not a hit. See Box.overlaps.
      const Box grazing = Box(left: 0.45, top: 0.35, right: 0.55, bottom: 0.39);
      expect(grazing.overlaps(o.topBox), isFalse);
    });
  });

  group('scoring', () {
    test('score increments by one when an obstacle is passed', () {
      final trace = hoverTrace(startRun((_) => 0.5), 0.55, 400);

      expect(trace.first.score, 0);

      // Find the frame the first point landed on.
      var firstPoint = -1;
      for (var i = 0; i < trace.length; i++) {
        if (trace[i].score == 1) {
          firstPoint = i;
          break;
        }
      }
      expect(firstPoint, greaterThan(0), reason: 'nothing ever scored');

      // Exactly one point, not two, and it belongs to obstacle 0.
      expect(trace[firstPoint - 1].score, 0);
      expect(trace[firstPoint].score, 1);

      final Obstacle scored = trace[firstPoint].obstacles.firstWhere(
        (o) => o.index == 0,
      );
      expect(scored.scored, isTrue);

      // The rule is "fully past the car", which is also what makes a point
      // proof of survival: with no horizontal overlap left, this obstacle can
      // never collide with the car again.
      final double carLeft = GameModel.carX - GameModel.carWidth / 2;
      expect(scored.right, lessThan(carLeft));

      final Obstacle beforeScoring = trace[firstPoint - 1].obstacles.firstWhere(
        (o) => o.index == 0,
      );
      expect(beforeScoring.scored, isFalse);
      expect(beforeScoring.right, greaterThanOrEqualTo(carLeft));

      // Never more than one point per frame, over the whole run.
      for (var i = 1; i < trace.length; i++) {
        expect(trace[i].score - trace[i - 1].score, anyOf(0, 1));
      }
    });

    test('the same obstacle never scores twice, however many ticks follow', () {
      // An obstacle sits behind the car for roughly 33 frames before it is
      // dropped. "Is it behind the car?" is therefore true 33 times, and a
      // model without the already-scored flag pays out 33 times.
      final trace = hoverTrace(startRun((_) => 0.5), 0.55, 900);

      final scoredIndices = <int>{};
      for (final m in trace) {
        for (final o in m.obstacles) {
          if (o.scored) scoredIndices.add(o.index);
        }

        // The invariant: the score is the number of DISTINCT obstacles that
        // have ever been marked, on every frame. Counting distinct indices is
        // what makes a repeat visible — a double count moves the score without
        // moving the set.
        expect(
          m.score,
          scoredIndices.length,
          reason: 'score ${m.score} but only ${scoredIndices.length} distinct '
              'obstacles have ever scored',
        );
      }

      // Non-vacuous: several obstacles really did pass, and each spent many
      // frames behind the car afterwards.
      expect(trace.last.score, greaterThanOrEqualTo(3));
    });

    test('reset clears the score', () {
      final m = hoverTrace(startRun((_) => 0.5), 0.55, 200).last;
      expect(m.score, greaterThan(0));
      expect(m.obstacles, isNotEmpty);
      expect(m.nextObstacleIndex, greaterThan(0));

      final fresh = m.reset();

      expect(fresh.score, 0);
      expect(fresh.obstacles, isEmpty);
      expect(fresh.nextObstacleIndex, 0);
      expect(fresh.state, RunState.ready);
      expect(fresh, const GameModel.ready());

      // The one thing a reset keeps is the gap pattern — it is the caller's
      // configuration, not part of the run. A restart that silently reverted to
      // the default hash would make every assertion after a reset a guess.
      expect(fresh.gapCentreFor(0), 0.5);
    });
  });
}

/// Starts a run with a chosen gap pattern: ready, then the one flap that is the
/// only door out of `ready`.
GameModel startRun(GapPattern gaps) =>
    GameModel.ready(gapCentreFor: gaps).flap();

/// Flies the car along the horizontal line [targetY] for [frames] frames and
/// returns every frame of the run.
///
/// The rule is one line: flap whenever the car has sunk below the line. That is
/// a crude autopilot, and crude is the point — it is a scripted player, using
/// only `flap()` and `tick()` exactly as a real one would, so nothing here can
/// put the model into a state a player could not reach. There is no other way
/// to hold an altitude in this game: the model has no setter for y, and gravity
/// never switches off.
///
/// The resulting flight is not perfectly level. A flap assigns an upward
/// velocity, so the car climbs about 0.118 of the playfield above the line
/// before falling back to it; the band is roughly [line - 0.12, line + 0.01].
/// Tests that care about clearance say so explicitly rather than assuming it.
List<GameModel> hoverTrace(GameModel start, double targetY, int frames) {
  final trace = <GameModel>[];
  var m = start;
  for (var i = 0; i < frames; i++) {
    if (m.y > targetY) m = m.flap();
    m = m.tick(frame);
    trace.add(m);
  }
  return trace;
}

/// Strips `//` line comments, so the ban above applies to code and not to
/// prose.
///
/// This exists because the first version of that guard failed on correct code:
/// `game_model.dart` names `DateTime.now()` in a comment precisely in order to
/// say it is banned, and a raw substring search flagged it. A detector that
/// fires on valid input is worse than no detector, because it trains whoever
/// reads the output to ignore it.
///
/// Naive on purpose: it would also cut a `//` inside a string literal. There is
/// none in `lib/game/`, and a real parser here would be more machinery than the
/// rule is worth.
String stripLineComments(String source) => source
    .split('\n')
    .map((line) {
      final i = line.indexOf('//');
      return i == -1 ? line : line.substring(0, i);
    })
    .join('\n');

/// Builds a `dead` model the way the game does: one flap to start, then let
/// gravity carry the car through the floor.
///
/// Written as a helper rather than a literal `GameModel` because the private
/// constructor is not reachable from here — which is deliberate. Every fixture
/// in this file is a state the game can actually get into.
GameModel fallUntilDead() {
  var m = const GameModel.ready().flap();
  var frames = 0;
  while (m.state == RunState.playing && frames < 1000) {
    m = m.tick(frame);
    frames++;
  }
  return m;
}
