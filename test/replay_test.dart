/// PART 1 — the proof that a run is fully described by a seed plus an input
/// timeline, and that replaying it reproduces the run FRAME BY FRAME.
///
/// WHY FRAME-BY-FRAME AND NOT "SAME SCORE":
///
/// Two runs can agree on the final score and disagree everywhere else. Score is
/// an integer that only ever counts up, so it throws away almost everything a
/// trajectory does: a replay whose car sat one lattice cell lower for the whole
/// run, or which drifted apart and re-converged, scores the same and is not the
/// same run. The claim being made here is that a recording reproduces the RUN,
/// so the assertion has to be about every frame of it — the car's position, its
/// velocity, the score so far, every obstacle's x, and which of them have paid
/// out. `GameModel ==` compares exactly that set, element by element, and
/// `test/model_boundaries_test.dart` proves that comparison is not vacuous.
///
/// THE FIXTURE: 33 recorded runs. Varied deliberately rather than randomly —
/// five tapping policies crossed with eight course seeds (the do-nothing policy
/// only once, because it produces the identical run on every course) — so the
/// set covers death by ceiling, death by floor, death by pipe, long scoring
/// runs and a run that never starts at all. The spread is ASSERTED below rather
/// than assumed, so the fixture cannot quietly degenerate into thirty-three
/// copies of the same short run and go on passing.
library;

import 'dart:math';

import 'package:flutter_test/flutter_test.dart';

import 'package:flappymiata/game/course_seed.dart';
import 'package:flappymiata/game/game_model.dart';
import 'package:flappymiata/game/replay.dart';

import '../tool/headless_sim.dart';
import 'reference_bot.dart';

/// How many recorded runs the frame-exactness proof covers.
const int replayProofRuns = 33;

/// The five policies the fixture is built from. Named so a failure says which
/// kind of run broke.
final Map<String, bool Function(GameModel, int)> policies =
    <String, bool Function(GameModel, int)>{
      // Never taps: the run never leaves `ready` and nothing happens at all.
      'never': (GameModel m, int f) => false,
      // One tap, then gravity. Dies through the floor.
      'drop': (GameModel m, int f) => m.state == RunState.ready,
      // Taps every frame. Dies through the ceiling.
      'mash': (GameModel m, int f) => true,
      // Crude altitude hold around mid-field. Scores, then usually hits a pipe.
      'hold': (GameModel m, int f) => m.state == RunState.ready || m.y > 0.5,
      // Aims at the centre of the next gap. The longest, highest-scoring runs
      // in the fixture — up to 3000 frames and 37 points, which is what makes
      // this a proof about real play and not only about crashes.
      'chase': chaseNextGap,
    };

/// The eight courses the fixture is played on. Seed 0 is the shipped course;
/// the rest are arbitrary and fixed, so the fixture is the same every run.
const List<int> fixtureSeeds = <int>[0, 1, 2, 7, 99, 4242, 65535, 0xFFFFFFFF];

List<Replay> buildFixture() {
  final List<Replay> out = <Replay>[];
  for (final int seed in fixtureSeeds) {
    for (final MapEntry<String, bool Function(GameModel, int)> entry
        in policies.entries) {
      // 'never' would contribute eight identical do-nothing runs; one is
      // enough to prove the degenerate case and the other seven would only
      // pad the count.
      if (entry.key == 'never' && seed != 0) continue;
      out.add(recordRun(seed, entry.value));
    }
  }
  return out;
}

void main() {
  final List<Replay> fixture = buildFixture();

  group('the fixture is varied enough to be evidence', () {
    test('there are $replayProofRuns runs and they are genuinely different', () {
      expect(fixture, hasLength(replayProofRuns));

      // Lengths span nearly two orders of magnitude, so "replays exactly" is
      // being claimed about runs that end in under a second and about runs of
      // thousands of frames.
      final List<int> lengths = fixture.map((Replay r) => r.frames).toList();
      expect(lengths.reduce(min), lessThan(60));
      expect(lengths.reduce(max), greaterThan(600));

      // Every one of the model's three end states is represented.
      final Set<RunState> states = <RunState>{
        for (final Replay r in fixture) replayFinalModel(r).state,
      };
      expect(states, containsAll(<RunState>[RunState.ready, RunState.dead]));

      // Both deaths are represented: a car killed by the bounds rests exactly
      // on an edge, one killed by a pipe does not.
      final List<GameModel> deaths = <GameModel>[
        for (final Replay r in fixture)
          if (replayFinalModel(r).state == RunState.dead) replayFinalModel(r),
      ];
      final bool anyBounds = deaths.any(
        (GameModel m) => m.y == GameModel.minY || m.y == GameModel.maxY,
      );
      final bool anyPipe = deaths.any(
        (GameModel m) => m.y != GameModel.minY && m.y != GameModel.maxY,
      );
      expect(anyBounds, isTrue, reason: 'no run died by leaving the playfield');
      expect(anyPipe, isTrue, reason: 'no run died on a pipe');

      // And scores actually vary, so the score comparisons below are not all
      // comparing 0 to 0.
      final Set<int> scores = <int>{
        for (final Replay r in fixture) replayFinalModel(r).score,
      };
      expect(scores.length, greaterThan(2));
      expect(scores.reduce(max), greaterThan(3));
    });
  });

  group('a recorded run replays frame for frame', () {
    test('replaying the same recording twice gives the same $replayProofRuns '
        'traces', () {
      // THE WEAKER OF THE TWO CLAIMS, and named as such. Both traces here come
      // from the same `Replay`, so this shows the PLAYER is deterministic —
      // that nothing in the model or the driver carries state between runs. It
      // does NOT show that the recording captured the live run; that is the
      // next test, and it is the one Part 1 actually asks for.
      int framesCompared = 0;
      for (final Replay r in fixture) {
        final List<GameModel> first = replayTrace(r);
        final List<GameModel> second = replayTrace(r);

        expect(
          second,
          hasLength(first.length),
          reason: '$r: two replays produced different numbers of frames',
        );
        expect(
          first,
          hasLength(r.frames + 1),
          reason: '$r: a trace holds the start plus one entry per frame',
        );

        for (int f = 0; f < first.length; f++) {
          expect(
            second[f],
            first[f],
            reason: '$r diverged at frame $f:\n'
                '  first  ${first[f]}\n'
                '  second ${second[f]}',
          );
        }
        framesCompared += first.length;
      }
      // Non-vacuous: a bug that made `replayTrace` return an empty list would
      // otherwise satisfy every assertion above.
      expect(framesCompared, greaterThan(10000));
    });

    test('a live run and its replay agree on every frame and on the last', () {
      // THE CLAIM PART 1 ACTUALLY MAKES. Above, both traces come from the same
      // Replay object. Here the run is played LIVE through `ReplayRecorder` —
      // stepped one frame at a time with taps arriving as they would from a
      // touch handler — and separately replayed from nothing but the seed and
      // the list of tap frames. No policy, no recorder, no shared state
      // crosses between them. If anything the recorder knew were missing from
      // the recording, this is where it would show.
      int framesCompared = 0;
      for (final Replay r in fixture) {
        final ReplayRecorder recorder = ReplayRecorder(seed: r.seed);
        final List<GameModel> live = <GameModel>[recorder.model];
        int cursor = 0;
        while (recorder.frame < r.frames) {
          if (cursor < r.tapFrames.length &&
              r.tapFrames[cursor] == recorder.frame) {
            recorder.tap();
            cursor++;
          }
          if (!recorder.step()) break;
          live.add(recorder.model);
        }

        final List<GameModel> replayed = replayTrace(r);
        expect(live, hasLength(replayed.length), reason: '$r: length');
        for (int f = 0; f < live.length; f++) {
          expect(replayed[f], live[f], reason: '$r: frame $f');
        }
        // The final model as well as the trace, stated separately because it is
        // the half a leaderboard cares about and it should not be inferable
        // only from the loop above.
        expect(replayFinalModel(r), live.last, reason: '$r: final model');
        expect(replayFinalModel(r).score, live.last.score, reason: '$r: score');
        framesCompared += live.length;
      }
      // Non-vacuous: a bug that made the live loop exit immediately would
      // otherwise satisfy every assertion above.
      expect(framesCompared, greaterThan(10000));
    });

    test('a replay is byte-identical whatever order the frames are asked for',
        () {
      // Determinism under re-entry: building a trace, then building it again
      // after having already built a dozen others, must not depend on anything
      // left over from the earlier ones. This is the property that would break
      // first if a cached gap pattern or a lazily-initialised table ever crept
      // into the model.
      final Replay a = fixture[3];
      final Replay b = fixture[17];
      final GameModel aFirst = replayFinalModel(a);
      for (final Replay other in fixture) {
        replayFinalModel(other);
      }
      expect(replayFinalModel(a), aFirst);
      expect(replayFinalModel(b), replayFinalModel(b));
    });
  });

  group('the seed is load-bearing, not decoration', () {
    test('the same taps on a different seed are a different run', () {
      // If this passed with the seeds swapped, the seed would not be part of
      // the run and Part 1 would be storing half a recording.
      // A run that actually STARTED and scored. A do-nothing run would pass
      // this test for the wrong reason: while the state is `ready` no obstacle
      // is ever spawned, so every seed produces the same empty playfield.
      final Replay onZero = fixture.firstWhere(
        (Replay r) => r.seed == 0 && replayFinalModel(r).score > 3,
      );
      final Replay onOther = Replay(
        seed: 4242,
        tapFrames: onZero.tapFrames,
        frames: onZero.frames,
      );
      final List<GameModel> a = replayTrace(onZero);
      final List<GameModel> b = replayTrace(onOther);
      expect(a, hasLength(b.length));
      int firstDifference = -1;
      for (int f = 0; f < a.length && firstDifference < 0; f++) {
        if (a[f] != b[f]) firstDifference = f;
      }
      expect(
        firstDifference,
        greaterThanOrEqualTo(0),
        reason: 'two seeds produced the same trajectory; the seed is ignored',
      );
    });

    test('seed 0 is exactly the shipped course', () {
      // Everything already proved about `GameModel.defaultGapCentre` — the
      // golden values, every fairness window — is proved about seed 0 too, and
      // only because these two functions agree to the last bit.
      for (int i = 0; i < 500; i++) {
        expect(
          seededGapCentre(0, i),
          GameModel.defaultGapCentre(i),
          reason: 'index $i',
        );
      }
    });
  });

  group('the replay driver agrees with tool/headless_sim.dart', () {
    test('tap-before-physics, frame for frame, on the same inputs', () {
      // The two drivers are stated in two places for two reasons — the headless
      // one predates this file and every fairness witness is written in its
      // terms. If they ever disagreed about whether a tap lands before or after
      // that frame's physics, the witnesses would stop describing this game and
      // nothing would say so. This is the pin.
      for (final Replay r in fixture) {
        if (r.frames == 0) continue;
        final List<bool> asBools = List<bool>.filled(r.frames, false);
        for (final int tap in r.tapFrames) {
          asBools[tap] = true;
        }
        final SimResult sim = replay(
          asBools,
          start: GameModel.ready(gapCentreFor: gapPatternForSeed(r.seed)),
        );
        expect(sim.finalModel, replayFinalModel(r), reason: '$r');
        expect(sim.score, replayFinalModel(r).score, reason: '$r');
      }
    });
  });

  group('a Replay refuses to be an impossible run', () {
    test('taps must be strictly increasing', () {
      expect(
        () => Replay(seed: 0, tapFrames: <int>[5, 5], frames: 10),
        throwsArgumentError,
      );
      expect(
        () => Replay(seed: 0, tapFrames: <int>[5, 4], frames: 10),
        throwsArgumentError,
      );
      // The neighbouring legal case, so the rule is "strictly increasing" and
      // not "no taps at all".
      expect(Replay(seed: 0, tapFrames: <int>[4, 5], frames: 10).frames, 10);
    });

    test('taps must be inside the run, on both edges', () {
      expect(
        () => Replay(seed: 0, tapFrames: <int>[-1], frames: 10),
        throwsArgumentError,
      );
      expect(
        () => Replay(seed: 0, tapFrames: <int>[10], frames: 10),
        throwsArgumentError,
      );
      // Frame 0 and frame 9 are both inside a ten-frame run.
      expect(Replay(seed: 0, tapFrames: <int>[0, 9], frames: 10).tapFrames,
          <int>[0, 9]);
    });

    test('the seed and the frame count have to fit', () {
      expect(
        () => Replay(seed: -1, tapFrames: <int>[], frames: 1),
        throwsArgumentError,
      );
      expect(
        () => Replay(seed: maxCourseSeed + 1, tapFrames: <int>[], frames: 1),
        throwsArgumentError,
      );
      expect(
        () => Replay(seed: 0, tapFrames: <int>[], frames: -1),
        throwsArgumentError,
      );
      expect(
        () => Replay(seed: 0, tapFrames: <int>[], frames: maxReplayFrames + 1),
        throwsArgumentError,
      );
      // Both extremes are legal.
      expect(Replay(seed: maxCourseSeed, tapFrames: <int>[], frames: 0).seed,
          maxCourseSeed);
      expect(
        Replay(seed: 0, tapFrames: <int>[], frames: maxReplayFrames).frames,
        maxReplayFrames,
      );
    });

    test('the tap list cannot be edited after the fact', () {
      final List<int> mutable = <int>[1, 2, 3];
      final Replay r = Replay(seed: 0, tapFrames: mutable, frames: 10);
      // Editing the caller's list must not reach inside the replay, or a
      // "recorded" run could be rewritten after it was verified.
      mutable.add(4);
      expect(r.tapFrames, <int>[1, 2, 3]);
      expect(() => r.tapFrames.add(9), throwsUnsupportedError);
    });

    test('value equality compares the values', () {
      final Replay base = Replay(seed: 3, tapFrames: <int>[1, 4], frames: 20);
      expect(base, Replay(seed: 3, tapFrames: <int>[1, 4], frames: 20));
      expect(
        base.hashCode,
        Replay(seed: 3, tapFrames: <int>[1, 4], frames: 20).hashCode,
      );
      expect(base, isNot(Replay(seed: 4, tapFrames: <int>[1, 4], frames: 20)));
      expect(base, isNot(Replay(seed: 3, tapFrames: <int>[1, 5], frames: 20)));
      expect(base, isNot(Replay(seed: 3, tapFrames: <int>[1], frames: 20)));
      expect(base, isNot(Replay(seed: 3, tapFrames: <int>[1, 4], frames: 21)));

      // A run differing only in its FIRST tap. `tool/mutate.dart` found that
      // the element loop could be made to start at index 1 with the whole
      // suite green: every unequal pair above differs somewhere after the
      // first entry, so nothing was checking element zero.
      expect(base, isNot(Replay(seed: 3, tapFrames: <int>[2, 4], frames: 20)));

      // A replay equals itself. The identity fast path returns `true` before
      // looking at anything, so nothing else here exercises it — and a fast
      // path that returned `false` would make `r == r` false, which is the
      // most surprising bug a value type can have.
      expect(base == base, isTrue);

      // And a replay does not equal something that is not a replay. Written as
      // an explicit `==` in this direction rather than as
      // `expect(base, isNot('...'))`, because the matcher compares
      // `expected == actual` — it would ask the STRING whether it equals the
      // replay, which is a different method and always says no. That version
      // passed against a `Replay ==` that returned true for every type.
      final Object notAReplay = 'not a replay';
      expect(base == notAReplay, isFalse);
    });
  });

  group('the replay player', () {
    test('stops at the end of the recording and reports it', () {
      final ReplayPlayer p = ReplayPlayer(
        Replay(seed: 0, tapFrames: <int>[0], frames: 3),
      );
      expect(p.done, isFalse);
      expect(p.frame, 0);
      expect(p.step(), isTrue);
      expect(p.step(), isTrue);
      expect(p.step(), isTrue);
      expect(p.frame, 3);
      expect(p.done, isTrue);
      // Asking for more is a no-op, not an error and not an extra frame.
      final GameModel settled = p.model;
      expect(p.step(), isFalse);
      expect(p.frame, 3);
      expect(p.model, settled);
    });

    test('a zero-frame recording is a legal recording', () {
      final Replay empty = Replay(seed: 0, tapFrames: <int>[], frames: 0);
      expect(replayTrace(empty), hasLength(1));
      expect(replayFinalModel(empty), GameModel.ready());
    });
  });

  group('the recorder', () {
    test('a recorder with no seed records the shipped course', () {
      // The default has to be pinned on its own. Every other test that uses
      // `ReplayRecorder()` would be just as happy on any other course — a car
      // falling out of the playfield falls the same way wherever the pipes are
      // — so nothing else here would notice the default moving.
      expect(ReplayRecorder().seed, 0);
      expect(ReplayRecorder().replay.seed, 0);

      // And seed 0 really is the shipped course, checked where it shows: the
      // first obstacle's gap.
      final ReplayRecorder r = ReplayRecorder();
      r.tap();
      r.step();
      expect(r.model.obstacles, hasLength(1));
      expect(
        r.model.obstacles.single.gapCentre,
        GameModel.defaultGapCentre(0),
      );
    });

    test('it stops on the cap frame, not one after it', () {
      // A run that never taps never dies, so the frame cap is the only thing
      // that can end it — which makes this the one place the cap's boundary is
      // observable at all. The shipped cap is 216,000 frames and nobody would
      // run a test to it, so the cap is a parameter and this runs three frames.
      //
      // `tool/mutate.dart` found this: `_frame >= frameCap` mutated to `>` left
      // every test in the suite green, and a recorder that overran its cap by
      // one frame produces a `Replay` the constructor then rejects — a crash at
      // the end of an hour-long run, which is the worst possible time.
      expect(ReplayRecorder().frameCap, maxReplayFrames);

      // BOUNDED, so a recorder that never reports itself finished fails an
      // assertion instead of hanging the suite. A test that can only fail by
      // running forever is weaker evidence than one that fails by name, and it
      // costs forty-five seconds of the mutation run to say so.
      final ReplayRecorder capped = ReplayRecorder(frameCap: 3);
      int steps = 0;
      while (steps < 100 && capped.step()) {
        steps++;
      }
      expect(steps, 3);
      expect(capped.frame, 3);
      expect(capped.finished, isTrue);
      expect(capped.replay.frames, 3);
      expect(capped.model.state, RunState.ready, reason: 'it never tapped');

      // And one frame short of the cap it is NOT finished — the ceiling is
      // where it says it is, not one frame early.
      final ReplayRecorder nearly = ReplayRecorder(frameCap: 3);
      nearly.step();
      nearly.step();
      expect(nearly.finished, isFalse);
      expect(nearly.frame, 2);
    });

    test('a tap lands on the next frame, never the one already run', () {
      final ReplayRecorder r = ReplayRecorder();
      r.step(); // frame 0 runs with no tap
      r.tap();
      r.step(); // frame 1 is the tap
      expect(r.replay.tapFrames, <int>[1]);
    });

    test('two taps inside one frame are one tap', () {
      // A flap ASSIGNS velocity, so a second flap in the same frame changes
      // nothing the model can observe. Recording both would let two different
      // recordings describe one identical run.
      final ReplayRecorder r = ReplayRecorder();
      r.tap();
      r.tap();
      r.tap();
      r.step();
      expect(r.replay.tapFrames, <int>[0]);
    });

    test('recording stops when the car dies', () {
      final ReplayRecorder r = ReplayRecorder();
      r.tap();
      int steps = 0;
      // Bounded for the same reason as the cap test above: a recorder that
      // never notices the death should fail an assertion, not run out the
      // clock.
      while (steps < 500 && r.step()) {
        steps++;
      }
      expect(r.finished, isTrue);
      expect(r.model.state, RunState.dead);
      expect(steps, r.replay.frames);
      expect(steps, greaterThan(30), reason: 'the car has to fall some way');
      // The upper bound is the load-bearing half. Without it, a recorder that
      // never noticed the death and ran on until the frame cap would satisfy
      // every other assertion here — it would still finish, still be dead, and
      // still have recorded more than thirty frames.
      expect(steps, lessThan(200), reason: 'the recorder stopped at the death');
      // And a step after the end changes nothing.
      final int settled = r.frame;
      expect(r.step(), isFalse);
      expect(r.frame, settled);
    });
  });

  group('the fixed-step accumulator', () {
    test('one frame of real time buys exactly one step', () {
      final FixedStepAccumulator a = FixedStepAccumulator();
      expect(a.stepsFor(replayFrameSeconds), 1);
      expect(a.carry, closeTo(0.0, 1e-12));
    });

    test('a second of jittery frames buys sixty steps, whatever the pacing',
        () {
      // The property the whole recording rests on: the number of SIMULATION
      // frames depends on how much time passed, not on how it was delivered.
      int steady = 0;
      final FixedStepAccumulator a = FixedStepAccumulator();
      for (int i = 0; i < 60; i++) {
        steady += a.stepsFor(1.0 / 60.0);
      }

      int jittery = 0;
      final FixedStepAccumulator b = FixedStepAccumulator();
      // 1/120 and 1/40 alternating averages 1/60 and never exceeds the cap.
      for (int i = 0; i < 60; i++) {
        jittery += b.stepsFor(i.isEven ? 1.0 / 120.0 : 1.0 / 40.0);
      }
      expect(steady, 60);
      expect(jittery, 60);
    });

    test('half a frame buys nothing and is banked', () {
      final FixedStepAccumulator a = FixedStepAccumulator();
      expect(a.stepsFor(replayFrameSeconds / 2), 0);
      expect(a.carry, closeTo(replayFrameSeconds / 2, 1e-12));
      expect(a.stepsFor(replayFrameSeconds / 2), 1);
    });

    test('a long stall is capped, and the surplus is dropped rather than banked',
        () {
      // The spiral-of-death guard. Ten seconds of debt must not turn into 600
      // physics steps inside one frame — and must not be owed on the next one
      // either, or the stall simply repeats.
      final FixedStepAccumulator a = FixedStepAccumulator(maxStepsPerCall: 5);
      expect(a.stepsFor(10.0), 5);
      expect(a.carry, 0.0, reason: 'the surplus is dropped, not banked');
      expect(a.stepsFor(replayFrameSeconds), 1);

      // The DEFAULT cap, pinned separately. Every other test here either passes
      // the cap explicitly or never reaches it, so the default is the one value
      // nothing else is looking at — and it is the value the shipped game runs
      // on.
      expect(FixedStepAccumulator().stepsFor(10.0), 5);
    });

    test('hitting the cap exactly does not throw away a legitimate remainder',
        () {
      // Exactly five frames' worth: the cap is reached but there is no surplus,
      // so nothing should be discarded and the leftover half-frame must survive.
      final FixedStepAccumulator a = FixedStepAccumulator(maxStepsPerCall: 5);
      expect(a.stepsFor(replayFrameSeconds * 5.5), 5);
      expect(a.carry, closeTo(replayFrameSeconds * 0.5, 1e-12));
    });

    test('a debt of exactly one frame left by the cap is still over budget',
        () {
      // THE EXACT EDGE of the over-budget test, which nothing else reaches.
      // Doubling a double is exact and so is subtracting the original from it,
      // so after one capped step the carry is bit-for-bit one frame — the only
      // input on which `carry >= frame` and `carry > frame` disagree. One frame
      // of unspent time after the cap has fired IS over budget and is dropped,
      // exactly as the class comment says.
      final FixedStepAccumulator a = FixedStepAccumulator(maxStepsPerCall: 1);
      expect(a.stepsFor(replayFrameSeconds * 2), 1);
      expect(
        a.carry,
        0.0,
        reason: 'a whole frame left over means the cap stopped the loop',
      );
    });

    test('a zero, negative or non-finite frame buys nothing and is not banked',
        () {
      final FixedStepAccumulator a = FixedStepAccumulator();
      expect(a.stepsFor(0.0), 0);
      expect(a.stepsFor(-1.0), 0);
      expect(a.stepsFor(double.nan), 0);
      expect(a.carry, 0.0);
      // Still usable afterwards: a NaN must not have poisoned the accumulator.
      expect(a.stepsFor(replayFrameSeconds), 1);
    });
  });
}
