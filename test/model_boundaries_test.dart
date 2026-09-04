/// The exact edges of every comparison in the model, and the exact conditions
/// under which two snapshots are the same snapshot.
///
/// WHY THIS FILE EXISTS: `tool/mutate.dart` mutates each comparison in
/// `lib/game/` into its neighbours — `<` into `<=`, `>` into `>=` — and each
/// `bool` result into a constant. Twenty-two of those mutants survived the
/// original 57 tests. Every one of them is the same kind of hole: the suite
/// exercised a comparison well inside its range and never on the line, or it
/// compared two models that were obviously different and never two that were
/// nearly the same.
///
/// A comparison is only tested at its boundary. `car.top < pipe.gapTop` with
/// the car half a playfield away proves nothing about `<` versus `<=` — the two
/// answers differ on exactly one input, the one where the two numbers are
/// equal, and that is the input a test has to supply.
///
/// HOW THE `dt` LITERALS BELOW WERE FOUND, because they look arbitrary and are
/// not: the model is deterministic and its arithmetic is IEEE-754 doubles, so
/// "the car is exactly on the ceiling" is a specific double and the `dt` that
/// produces it is a specific double. Each one was found by solving the physics
/// for the boundary and then walking the neighbouring representable doubles
/// until the model landed on it exactly. Every test states the boundary
/// condition as its own assertion first, so if a `dt` ever stops hitting the
/// line the test fails loudly instead of quietly testing an ordinary frame.
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:flappymiata/game/game_model.dart';

const double frame = 1.0 / 60.0;

GameModel midFieldRun() => GameModel.ready(gapCentreFor: (int _) => 0.5).flap();

void main() {
  group('Box.overlaps — sharing an edge is a scrape, not a hit', () {
    // The class comment promises strict `<` and `>` on all four sides: a car
    // whose roof is at precisely the pipe lip's y has threaded it. The original
    // suite checked that on ONE side. These check all four, plus the
    // hair's-breadth overlap on each, which is what stops the assertions being
    // satisfied by a box that never touches anything.
    const Box pipe = Box(left: 0.4, top: 0.2, right: 0.6, bottom: 0.8);

    test('touching on the left, right, top or bottom edge is not an overlap',
        () {
      const Box fromLeft = Box(left: 0.2, top: 0.4, right: 0.4, bottom: 0.5);
      const Box fromRight = Box(left: 0.6, top: 0.4, right: 0.8, bottom: 0.5);
      const Box fromAbove = Box(left: 0.45, top: 0.1, right: 0.55, bottom: 0.2);
      const Box fromBelow = Box(left: 0.45, top: 0.8, right: 0.55, bottom: 0.9);

      expect(fromLeft.overlaps(pipe), isFalse, reason: 'right edge == pipe.left');
      expect(fromRight.overlaps(pipe), isFalse, reason: 'left edge == pipe.right');
      expect(fromAbove.overlaps(pipe), isFalse, reason: 'bottom == pipe.top');
      expect(fromBelow.overlaps(pipe), isFalse, reason: 'top == pipe.bottom');

      // Symmetric: overlap is a relation between two boxes, not a property of
      // the receiver.
      expect(pipe.overlaps(fromLeft), isFalse);
      expect(pipe.overlaps(fromRight), isFalse);
      expect(pipe.overlaps(fromAbove), isFalse);
      expect(pipe.overlaps(fromBelow), isFalse);
    });

    test('crossing the same edge by a hair IS an overlap', () {
      // Without these four, "touching is not a hit" would also be satisfied by
      // an `overlaps` that always returned false — and collision would be gone
      // from the game with the suite still green.
      const double hair = 1e-9;
      expect(
        const Box(left: 0.2, top: 0.4, right: 0.4 + hair, bottom: 0.5)
            .overlaps(pipe),
        isTrue,
      );
      expect(
        const Box(left: 0.6 - hair, top: 0.4, right: 0.8, bottom: 0.5)
            .overlaps(pipe),
        isTrue,
      );
      expect(
        const Box(left: 0.45, top: 0.1, right: 0.55, bottom: 0.2 + hair)
            .overlaps(pipe),
        isTrue,
      );
      expect(
        const Box(left: 0.45, top: 0.8 - hair, right: 0.55, bottom: 0.9)
            .overlaps(pipe),
        isTrue,
      );
    });
  });

  group('value equality actually compares the values', () {
    // Every `==` in `lib/game/` was mutated into `return true`, and three of
    // those mutants survived: nothing in the suite ever asserted that two
    // DIFFERENT things are different. An `==` that always says yes makes every
    // "the run is deterministic" and "a flap while dead changes nothing"
    // assertion vacuous, so these three tests are load-bearing for the whole
    // file they are checking.

    test('two boxes differing in exactly one edge are not equal', () {
      const Box box = Box(left: 0.1, top: 0.2, right: 0.3, bottom: 0.4);
      expect(box, const Box(left: 0.1, top: 0.2, right: 0.3, bottom: 0.4));
      expect(box, isNot(const Box(left: 0.15, top: 0.2, right: 0.3, bottom: 0.4)));
      expect(box, isNot(const Box(left: 0.1, top: 0.25, right: 0.3, bottom: 0.4)));
      expect(box, isNot(const Box(left: 0.1, top: 0.2, right: 0.35, bottom: 0.4)));
      expect(box, isNot(const Box(left: 0.1, top: 0.2, right: 0.3, bottom: 0.45)));
      expect(box, isNot('not a box'));
    });

    test('two obstacles differing in exactly one field are not equal', () {
      const Obstacle o = Obstacle(
        index: 3,
        x: 0.5,
        width: 0.16,
        gapCentre: 0.5,
        gapHeight: 0.28,
      );
      expect(
        o,
        const Obstacle(
            index: 3, x: 0.5, width: 0.16, gapCentre: 0.5, gapHeight: 0.28),
      );
      expect(
        o,
        isNot(const Obstacle(
            index: 4, x: 0.5, width: 0.16, gapCentre: 0.5, gapHeight: 0.28)),
      );
      expect(
        o,
        isNot(const Obstacle(
            index: 3, x: 0.6, width: 0.16, gapCentre: 0.5, gapHeight: 0.28)),
      );
      expect(
        o,
        isNot(const Obstacle(
            index: 3, x: 0.5, width: 0.20, gapCentre: 0.5, gapHeight: 0.28)),
      );
      expect(
        o,
        isNot(const Obstacle(
            index: 3, x: 0.5, width: 0.16, gapCentre: 0.6, gapHeight: 0.28)),
      );
      expect(
        o,
        isNot(const Obstacle(
            index: 3, x: 0.5, width: 0.16, gapCentre: 0.5, gapHeight: 0.30)),
      );
      expect(o, isNot(o.markScored()), reason: 'the scored flag is part of it');
      expect(o, isNot('not an obstacle'));
    });

    test('two models differing in exactly one field are not equal', () {
      final GameModel playing = midFieldRun().tick(frame);
      expect(playing, isNot(const GameModel.ready()), reason: 'state');
      expect(playing, isNot(playing.tick(frame)), reason: 'y and velocity');
      expect(playing, isNot('not a model'));

      // Same instant, different score: fly on until a point lands and compare
      // the two frames either side of it.
      GameModel m = playing;
      GameModel? before;
      GameModel? after;
      for (int i = 0; i < 400 && after == null; i++) {
        if (m.y > 0.55) m = m.flap();
        final GameModel next = m.tick(frame);
        if (next.score > m.score) {
          before = m;
          after = next;
        }
        m = next;
      }
      expect(after, isNotNull, reason: 'nothing ever scored');
      expect(before, isNot(after));
    });
  });

  group('two runs are the same run only if their obstacles match', () {
    // `_sameObstacles` is the element-by-element list comparison behind
    // `GameModel ==`, and five separate mutations of it survived: the identical
    // fast path inverted, the length guard inverted, the element mismatch
    // inverted, and the element loop made to start at 1 or never run at all.
    // All five have the same cause — the suite only ever compared obstacle
    // lists that were equal, so nothing checked that unequal lists are noticed.

    test('models identical except for one obstacle\'s gap are not equal', () {
      // Two runs driven by identical inputs, differing only in where obstacle
      // 0's gap sits. After one frame each has exactly one obstacle, in the
      // same place, with the same index — the ONLY difference in the entire
      // snapshot is `gapCentre`, and it is in element 0 of the list.
      final GameModel a =
          GameModel.ready(gapCentreFor: (int _) => 0.50).flap().tick(frame);
      final GameModel b = GameModel.ready(
        gapCentreFor: (int i) => i == 0 ? 0.40 : 0.50,
      ).flap().tick(frame);

      expect(a.obstacles, hasLength(1));
      expect(b.obstacles, hasLength(1));
      expect(a.state, b.state);
      expect(a.y, b.y);
      expect(a.velocity, b.velocity);
      expect(a.score, b.score);
      expect(a.nextObstacleIndex, b.nextObstacleIndex);
      expect(a.obstacles.single.x, b.obstacles.single.x);
      expect(a.obstacles.single.gapCentre, isNot(b.obstacles.single.gapCentre));

      expect(a, isNot(b));
      expect(b, isNot(a));
    });

    test('models identical except for the NUMBER of obstacles are not equal',
        () {
      // The length guard needs a pair that agrees on every scalar field and
      // disagrees only on how many pipes are on screen, which is far harder to
      // build than it sounds — the obstacle count normally moves in lockstep
      // with the score and the spawn counter.
      //
      // The lever is a `dt` that advances the WORLD without moving the CAR.
      // `nextVelocity = flapImpulse + gravity * dt` comes out exactly 0.0 when
      // dt is -flapImpulse / gravity, and then `nextY = y + 0.0 * dt` is y
      // unchanged. Two of those steps, each followed by a flap to restore the
      // velocity, scroll the world 0.29 of a width while leaving the car's
      // position, speed, score and spawn counter exactly where they were — and
      // that is enough to push one already-scored pipe off the left edge.
      final double still = -GameModel.flapImpulse / GameModel.gravity;
      expect(
        GameModel.flapImpulse + GameModel.gravity * still,
        0.0,
        reason: 'this dt has to cancel the flap exactly, or the car moves',
      );

      GameModel m = midFieldRun();
      for (int i = 0; i < 116; i++) {
        if (m.y > 0.55) m = m.flap();
        m = m.tick(frame);
      }
      expect(m.state, RunState.playing);

      final GameModel a = m.flap();
      final GameModel b = a.tick(still).flap().tick(still).flap();

      // The car really did stand still, and the world really did move.
      expect(b.state, a.state);
      expect(b.y, a.y);
      expect(b.velocity, a.velocity);
      expect(b.score, a.score);
      expect(b.nextObstacleIndex, a.nextObstacleIndex);
      expect(a.obstacles, hasLength(2));
      expect(b.obstacles, hasLength(1));

      expect(a, isNot(b));
      expect(b, isNot(a));
    });
  });

  group('tick — every comparison tested on its own line', () {
    test('an obstacle whose right edge is exactly on the left wall stays on '
        'screen', () {
      // `if (moved.right >= playfieldLeft) next.add(moved);` — the cull keeps
      // an obstacle while any part of it is still on the playfield, and an edge
      // exactly on the wall counts as still on it. With `>` the pipe would
      // vanish one frame early; here that also changes where the NEXT pipe is
      // born, because an empty list spawns at the right edge instead of one
      // spacing behind the survivor.
      GameModel m = midFieldRun();
      for (int i = 0; i < 128; i++) {
        if (m.y > 0.55) m = m.flap();
        m = m.tick(frame);
      }
      expect(m.state, RunState.playing);

      final GameModel n = m.tick(0.2833333333333396);
      final Obstacle first = n.obstacles.first;
      expect(first.index, 0);
      expect(
        first.right,
        playfieldLeft,
        reason: 'the dt above must put the pipe exactly on the wall',
      );
      expect(n.obstacles, hasLength(2));
    });

    test('a pipe exactly one spacing in from the right edge triggers the next '
        'spawn', () {
      // `else if (next.last.x <= playfieldRight - obstacleSpacing)`. Exactly on
      // the line is a spawn; `<` would hold the pipe back a frame and let the
      // spacing drift.
      final GameModel spawned = midFieldRun().tick(frame);
      expect(spawned.obstacles.single.x, closeTo(playfieldRight, 1e-12));
      expect(spawned.nextObstacleIndex, 1);

      final GameModel n = spawned.tick(1.3333333333333333);
      expect(
        n.obstacles.first.x,
        playfieldRight - GameModel.obstacleSpacing,
        reason: 'the dt above must land the pipe exactly on the spawn line',
      );
      expect(n.nextObstacleIndex, 2);
      expect(n.obstacles, hasLength(2));
    });

    test('a pipe whose right edge is exactly level with the car\'s left edge '
        'has not scored yet', () {
      // `if (!obstacle.scored && obstacle.right < carLeft)`. The rule is
      // "fully past the car", and level is not past: with `<=` a pipe would pay
      // out while it is still, by a hair, overlapping the car — which would
      // break the promise that a point also means the player survived it.
      final GameModel spawned = midFieldRun().tick(frame);
      final GameModel n = spawned.tick(1.9157613168724281);

      final Obstacle o = n.obstacles.firstWhere((Obstacle q) => q.index == 0);
      expect(
        o.right,
        GameModel.carX - GameModel.carWidth / 2,
        reason: 'the dt above must land the pipe exactly on the scoring line',
      );
      expect(o.scored, isFalse);
      expect(n.score, 0);
    });

    test('a car exactly on the ceiling is still alive', () {
      // `if (nextY < minY || nextY > maxY)`. Strict, like the collision test:
      // the boundary belongs to the playfield. With `<=` the car would die on
      // the frame it grazes the ceiling — and, because the resting position is
      // chosen by re-asking `nextY < minY`, it would be laid to rest against
      // the FLOOR, a full playfield away from where it died.
      GameModel m = const GameModel.ready().flap();
      var climbed = 0;
      while (m.y > 0.05 && climbed < 200) {
        m = m.flap().tick(frame);
        climbed++;
      }
      expect(m.state, RunState.playing);
      expect(climbed, 31, reason: 'the dt below was solved for this exact state');

      final GameModel n = m.flap().tick(0.08989034228098178);
      expect(n.y, GameModel.minY, reason: 'exactly on the ceiling, not near it');
      expect(n.state, RunState.playing);
    });

    test('a car exactly on the floor is still alive', () {
      // The mirror image: `nextY > maxY` has to be strict too, or the same
      // graze kills at the bottom.
      final GameModel n =
          const GameModel.ready().flap().tick(0.7109060706651785);
      expect(n.y, GameModel.maxY, reason: 'exactly on the floor, not near it');
      expect(n.state, RunState.playing);
    });
  });
}
