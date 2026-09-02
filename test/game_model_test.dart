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
