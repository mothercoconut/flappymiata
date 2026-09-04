/// Assist mode, checked as two separate claims.
///
/// ============================================================================
/// CLAIM ONE: IT CHANGES NOTHING
/// ============================================================================
///
/// A display aid that could reach the model would break the replay system, the
/// verified score and the fairness proof at once — all three rest on a run being
/// a pure function of (seed, taps). "It does not touch the model" is therefore
/// the load-bearing property, and it is asserted the only way that means
/// anything: the same inputs are played twice, once with the solver consulted on
/// every single frame and once with it never constructed, and the two runs are
/// compared frame for frame.
///
/// A negative assertion is worth exactly as much as the fixture's ability to
/// violate it, so every one of those tests also asserts that the solver really
/// did produce advice, on many frames, during the run it was supposed to be not
/// affecting. Comparing two runs where the assist was never invoked would pass
/// forever and check nothing.
///
/// ============================================================================
/// CLAIM TWO: THE WINDOW IS REAL
/// ============================================================================
///
/// The rule the feature lives or dies by is "never draw a window the physics
/// does not support". That is checked by taking the taps the window offers and
/// PLAYING THEM through the real `GameModel` — not through the solver's own
/// model of the world, which would only prove the solver agrees with itself.
///
/// ============================================================================
/// WHAT IS NOT CHECKED HERE
/// ============================================================================
///
/// NO EMULATOR OR DEVICE WAS AVAILABLE. Nothing below has run on hardware.
/// Whether the highlight is legible over the pipes, whether the path reads as a
/// path, whether the deadline mark is noticed in time, and whether the whole
/// thing helps or distracts while actually playing are all UNVERIFIED. What is
/// checked is arithmetic and physics.
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:flappymiata/game/course_seed.dart';
import 'package:flappymiata/game/game_model.dart';
import 'package:flappymiata/game/replay.dart';
import 'package:flappymiata/ui/assist.dart';

import 'package:flappymiata/main.dart' show Autopilot;

import '../tool/headless_sim.dart';
import '../tool/solver_bot.dart';

/// One frame at the replay timestep — the same one the solver plans in.
const double frame = replayFrameSeconds;

/// A live run, [frames] frames in, driven by the solver bot so the car is
/// somewhere a real player could be rather than somewhere convenient.
///
/// Returns the recorder rather than the model, because the frame NUMBER is half
/// of what a plan is anchored to and reconstructing it afterwards would be a
/// second chance to get it wrong.
ReplayRecorder runInto(int frames, {int seed = 0}) {
  final ReplayRecorder recorder = ReplayRecorder(seed: seed);
  final Policy bot = solverPolicy();
  while (recorder.frame < frames && !recorder.finished) {
    if (bot(recorder.model, recorder.frame)) recorder.tap();
    recorder.step();
  }
  return recorder;
}

void main() {
  group('the world the solver plans against is the world the game builds', () {
    test('obstacle for obstacle, frame for frame, for six seconds', () {
      // `AssistWorld` is a SECOND COPY of the spawn cadence in `GameModel.tick`.
      // A copy that drifted would place pipes the player is not looking at, and
      // every window computed from it would be about a different course. This is
      // the same check `test/fairness_prover_test.dart` makes of the prover's
      // own world, for the same reason.
      GameModel live = GameModel.ready(
        gapCentreFor: gapPatternForSeed(0),
      ).flap();
      final AssistWorld mirror = AssistWorld(live, frame);

      int comparisons = 0;
      for (int f = 0; f < 360; f++) {
        live = live.tick(frame);
        mirror.step();

        // The live car dies early with no taps; the WORLD carries on either way,
        // which is the property the solver depends on. So the comparison stops
        // being meaningful once `tick` freezes, and the loop below runs against a
        // live model that is kept alive by flapping.
        if (live.state != RunState.playing) break;

        expect(mirror.obstacles.length, live.obstacles.length,
            reason: 'frame $f: different number of pipes on the playfield');
        for (int i = 0; i < live.obstacles.length; i++) {
          final Obstacle a = live.obstacles[i];
          final Obstacle b = mirror.obstacles[i];
          expect(b.index, a.index, reason: 'frame $f, pipe $i');
          expect(b.x, a.x, reason: 'frame $f, pipe ${a.index}: x drifted');
          expect(b.gapCentre, a.gapCentre, reason: 'frame $f, pipe ${a.index}');
          expect(b.gapHeight, a.gapHeight, reason: 'frame $f, pipe ${a.index}');
          expect(b.scored, a.scored, reason: 'frame $f, pipe ${a.index}');
          comparisons++;
        }
        expect(mirror.score, live.score, reason: 'frame $f: score drifted');
      }

      // A car that taps once and then coasts falls out of the playfield in about
      // 77 frames, so this bare comparison is short by construction. The long
      // flown one below is what reaches a spawn cadence; this one exists to pin
      // the very first frames, where the playfield is empty and the spawn rule
      // takes its other branch.
      expect(comparisons, greaterThan(50),
          reason: 'the run ended before anything was really compared');
    });

    test('a long flown run keeps the two worlds in step', () {
      // The test above stops at the first death. This one flies, so the
      // comparison reaches the ramp and several spawn events rather than only
      // the first.
      final ReplayRecorder recorder = ReplayRecorder(seed: 0);
      final Policy bot = solverPolicy();
      final AssistWorld mirror = AssistWorld(recorder.model, frame);
      // The mirror is seeded from a `ready` model, so it has to be started the
      // same way the run is: the first tap is what makes the world move.
      recorder.tap();

      int checked = 0;
      while (recorder.frame < 1200 && !recorder.finished) {
        recorder.step();
        mirror.step();
        expect(mirror.obstacles.length, recorder.model.obstacles.length,
            reason: 'frame ${recorder.frame}');
        for (int i = 0; i < recorder.model.obstacles.length; i++) {
          expect(mirror.obstacles[i].x, recorder.model.obstacles[i].x,
              reason: 'frame ${recorder.frame}, pipe $i');
          expect(mirror.obstacles[i].index, recorder.model.obstacles[i].index);
          checked++;
        }
        expect(mirror.score, recorder.model.score);
        if (bot(recorder.model, recorder.frame)) recorder.tap();
      }
      expect(recorder.model.score, greaterThan(5),
          reason: 'the run never got far enough to test a spawn cadence');
      expect(checked, greaterThan(1000));
    });
  });

  group('the counter is recovered from the model rather than tracked', () {
    test('framesSinceFlap comes back out of the velocity', () {
      final AssistSolver solver = AssistSolver();
      GameModel m = const GameModel.ready().flap();

      // Straight after a flap the counter is zero: the velocity IS flapImpulse,
      // gravity has not been applied yet.
      expect(solver.counterFor(m.velocity), 0);

      for (int n = 1; n <= 40; n++) {
        m = m.tick(frame);
        expect(solver.counterFor(m.velocity), n,
            reason: 'after $n coasted frames');
      }

      // And a flap resets it, whatever it was.
      m = m.flap();
      expect(solver.counterFor(m.velocity), 0);
      m = m.tick(frame);
      expect(solver.counterFor(m.velocity), 1);
    });

    test('a velocity this game cannot produce is refused', () {
      // Not decoration: the counter is what indexes the row a state is looked up
      // in, so a wrong answer here reads a bitmap row belonging to a different
      // trajectory. Refusing is the only safe response.
      final AssistSolver solver = AssistSolver();
      expect(solver.counterFor(GameModel.flapImpulse - 1.0), -1,
          reason: 'a velocity above the flap impulse is not reachable');
      expect(solver.counterFor(double.nan), -1);
      expect(solver.counterFor(1000.0), -1, reason: 'past the row cap');
    });
  });

  group('assist changes nothing about the run', () {
    /// Plays [inputs] and returns every frame's model.
    ///
    /// When [consult] is true a solver is built and asked for advice on EVERY
    /// frame — far more often than the game does it — so that if consulting
    /// could disturb anything, this is the version it would disturb.
    List<GameModel> play(List<bool> inputs, {required bool consult}) {
      final AssistSolver? solver = consult ? AssistSolver() : null;
      final ReplayRecorder recorder = ReplayRecorder(seed: 0);
      final List<GameModel> trace = <GameModel>[recorder.model];
      int advised = 0;
      for (int f = 0; f < inputs.length && !recorder.finished; f++) {
        if (solver != null) {
          final AssistPlan? plan = solver.plan(recorder.model, recorder.frame);
          if (plan?.adviseAt(recorder.model, recorder.frame) != null) advised++;
        }
        if (inputs[f]) recorder.tap();
        recorder.step();
        trace.add(recorder.model);
      }
      if (consult) {
        // NON-VACUITY. Without this the whole group would pass over a solver
        // that returned null on every frame — which is exactly what a broken
        // solver does, and exactly the state in which "it changed nothing" is
        // trivially true.
        expect(advised, greaterThan(200),
            reason: 'the solver was consulted but never actually answered');
      }
      return trace;
    }

    /// A run long enough to cross several obstacles, driven by the bot.
    List<bool> botInputs({int frames = 900}) {
      final ReplayRecorder recorder = ReplayRecorder(seed: 0);
      final Policy bot = solverPolicy();
      final List<bool> inputs = <bool>[];
      while (recorder.frame < frames && !recorder.finished) {
        final bool tap = bot(recorder.model, recorder.frame);
        inputs.add(tap);
        if (tap) recorder.tap();
        recorder.step();
      }
      return inputs;
    }

    test('the same inputs give the same run with the solver on and off', () {
      final List<bool> inputs = botInputs();

      final List<GameModel> withAssist = play(inputs, consult: true);
      final List<GameModel> without = play(inputs, consult: false);

      expect(withAssist.length, without.length,
          reason: 'the two runs did not even last the same number of frames');
      for (int f = 0; f < withAssist.length; f++) {
        expect(withAssist[f], without[f], reason: 'frame $f differs');
      }

      // `GameModel ==` covers state, y, velocity, score, riskScore and every
      // obstacle — but saying so out loud costs nothing and makes the claim
      // legible without going and reading the operator.
      final GameModel a = withAssist.last;
      final GameModel b = without.last;
      expect(a.score, b.score);
      expect(a.riskScore, b.riskScore);
      expect(a.y, b.y);
      expect(a.velocity, b.velocity);

      // And the fixture was a real run rather than a car sitting on the start
      // line, or none of the above compared anything interesting.
      expect(a.score, greaterThan(5), reason: 'the fixture never scored');
      expect(a.riskScore, greaterThan(0),
          reason: 'the fixture never earned a risk point, so the one number '
              'most likely to be disturbed was never exercised');
    });

    test('a recorded run still verifies after assist has been consulted', () {
      // The end-to-end version of the same claim, stated in the currency that
      // actually matters: a run code re-executed elsewhere has to produce the
      // score the run produced here.
      final List<bool> inputs = botInputs(frames: 600);
      final List<GameModel> trace = play(inputs, consult: true);

      final Replay recorded = Replay(
        seed: 0,
        tapFrames: <int>[
          for (int i = 0; i < inputs.length; i++)
            if (inputs[i]) i,
        ],
        frames: trace.length - 1,
      );
      final GameModel replayed = replayFinalModel(recorded);

      expect(replayed, trace.last,
          reason: 'the run does not replay as itself');
      expect(replayed.score, trace.last.score);
      expect(replayed.riskScore, trace.last.riskScore);
    });
  });

  group('every tap the window offers is one the physics supports', () {
    /// A plan taken part way into a real run.
    ({ReplayRecorder run, AssistPlan plan, AssistAdvice advice}) situation({
      int at = 240,
      int seed = 0,
    }) {
      final ReplayRecorder run = runInto(at, seed: seed);
      final AssistSolver solver = AssistSolver();
      final AssistPlan? plan = solver.plan(run.model, run.frame);
      expect(plan, isNotNull, reason: 'no plan at frame ${run.frame}');
      final AssistAdvice? advice = plan!.adviseAt(run.model, run.frame);
      expect(advice, isNotNull);
      return (run: run, plan: plan, advice: advice!);
    }

    test('the window separates: it is neither always empty nor always full', () {
      // WITHOUT THIS THE WHOLE GROUP IS SATISFIED BY A CONSTANT. An advice that
      // offered nothing would pass every survival test below vacuously, and one
      // that offered everything would pass them only because the plan-following
      // policy is good. Both answers have to be observed on a real run for the
      // window to be a window at all.
      //
      // Sampled along a run rather than at one moment, because at any single
      // moment either answer is legitimate: a car that has just tapped and is
      // climbing toward a low gap genuinely has no safe tap for a while.
      int fullyOffered = 0;
      int partlyOffered = 0;
      int refusedSome = 0;

      final ReplayRecorder run = ReplayRecorder(seed: 0);
      final Policy bot = solverPolicy();
      final AssistSolver solver = AssistSolver();
      while (run.frame < 900 && !run.finished) {
        if (run.model.state == RunState.playing && run.frame % 10 == 0) {
          final AssistPlan? plan = solver.plan(run.model, run.frame);
          final AssistAdvice? a = plan?.adviseAt(run.model, run.frame);
          if (a != null) {
            expect(a.path.length, a.flapViable.length,
                reason: 'a path point with no verdict beside it');
            final int yes = a.flapViable.where((bool v) => v).length;
            if (yes == a.flapViable.length) fullyOffered++;
            if (yes > 0 && yes < a.flapViable.length) partlyOffered++;
            if (yes < a.flapViable.length) refusedSome++;

            // The two ends of the window bracket every offered frame, and
            // nothing outside them is offered. This is what a caller drawing a
            // single span would rely on.
            if (yes == 0) {
              expect(a.windowStart, -1);
              expect(a.windowEnd, -1);
            } else {
              expect(a.windowStart, greaterThanOrEqualTo(0));
              expect(a.windowEnd, greaterThanOrEqualTo(a.windowStart));
              expect(a.flapViable[a.windowStart], isTrue);
              expect(a.flapViable[a.windowEnd], isTrue);
              for (int d = 0; d < a.windowStart; d++) {
                expect(a.flapViable[d], isFalse,
                    reason: 'an offered frame before windowStart');
              }
              for (int d = a.windowEnd + 1; d < a.flapViable.length; d++) {
                expect(a.flapViable[d], isFalse,
                    reason: 'an offered frame after windowEnd');
              }
              expect(a.flapNow, a.windowStart == 0);
            }
          }
        }
        if (bot(run.model, run.frame)) run.tap();
        run.step();
      }

      expect(fullyOffered, greaterThan(5),
          reason: 'the window is never fully open, which suggests it is stuck');
      expect(partlyOffered, greaterThan(3),
          reason: 'the window is never partial, so it separates nothing');
      expect(refusedSome, greaterThan(3));
    });

    test('taking any offered tap and then following the plan survives', () {
      // THE CLAIM, checked against the real `GameModel` rather than against the
      // solver's own arithmetic. For every frame the window offers, the run is
      // replayed from the live state with a tap on that frame and the plan
      // consulted for everything after it.
      final ({ReplayRecorder run, AssistPlan plan, AssistAdvice advice}) s =
          situation();
      final int base = s.run.frame;
      final int lastFrame = s.plan.lastAdvisableFrame;

      int checkedWindows = 0;
      for (int d = 0; d < s.advice.flapViable.length; d++) {
        if (!s.advice.flapViable[d]) continue;
        checkedWindows++;

        final SimResult r = runHeadless(
          start: s.run.model,
          maxFrames: lastFrame - base,
          policy: (GameModel m, int f) {
            if (f < d) return false;
            if (f == d) return true;
            // After the offered tap, walk the plan: coast while coasting stays
            // inside the surviving set, tap on the frame it would leave it.
            final AssistAdvice? a = s.plan.adviseAt(m, base + f);
            if (a == null) return false;
            return a.latestSafeCoast < 1;
          },
        );

        expect(r.outcome, SimOutcome.survived,
            reason: 'the window offered a tap at +$d frames and the car died '
                '${r.outcome.name} after ${r.frames} frames');
      }

      expect(checkedWindows, greaterThan(3),
          reason: 'too few offered taps to call this a check');
    });

    test('the offer holds at several points of a run and on several courses',
        () {
      // One situation could be a lucky one. This walks the same check across
      // three courses and three depths, which is where a disagreement between
      // the solver's world and the game's would show up.
      int offers = 0;
      for (final int seed in <int>[0, 7, 4242]) {
        for (final int at in <int>[120, 300, 600]) {
          final ReplayRecorder run = runInto(at, seed: seed);
          if (run.finished) continue;
          final AssistSolver solver = AssistSolver();
          final AssistPlan? plan = solver.plan(run.model, run.frame);
          if (plan == null) continue;
          final AssistAdvice? advice = plan.adviseAt(run.model, run.frame);
          if (advice == null) continue;

          for (int d = 0; d < advice.flapViable.length; d++) {
            if (!advice.flapViable[d]) continue;
            offers++;
            final SimResult r = runHeadless(
              start: run.model,
              maxFrames: plan.lastAdvisableFrame - run.frame,
              policy: (GameModel m, int f) {
                if (f < d) return false;
                if (f == d) return true;
                final AssistAdvice? a = plan.adviseAt(m, run.frame + f);
                return a != null && a.latestSafeCoast < 1;
              },
            );
            expect(r.outcome, SimOutcome.survived,
                reason: 'seed $seed at frame $at: tap offered at +$d killed the '
                    'car by ${r.outcome.name}');
          }
        }
      }
      expect(offers, greaterThan(30),
          reason: 'the sweep checked almost nothing');
    });

    test('the deadline is not premature: coasting really does last that long',
        () {
      // The other side. `latestSafeCoast` says "doing nothing is survivable for
      // this many more frames", so a run that does nothing must not die BEFORE
      // then. It may die after — the mark is about every continuation, and doing
      // nothing is only one of them.
      for (final int at in <int>[180, 300, 480]) {
        final ReplayRecorder run = runInto(at);
        if (run.finished) continue;
        final AssistSolver solver = AssistSolver();
        final AssistPlan? plan = solver.plan(run.model, run.frame);
        if (plan == null) continue;
        final AssistAdvice? advice = plan.adviseAt(run.model, run.frame);
        if (advice == null) continue;

        // `latestSafeCoast` is a DELAY: `d` means "after d more ticks the car is
        // still somewhere with a future". So the run that has to survive is
        // exactly that many ticks, not one more.
        final SimResult r = runHeadless(
          start: run.model,
          policy: neverFlap,
          maxFrames: advice.latestSafeCoast,
        );
        expect(r.outcome, SimOutcome.survived,
            reason: 'at frame $at the mark promised '
                '${advice.latestSafeCoast} more coasted frames and the car died '
                'after ${r.frames}');

        // And the mark is not simply the end of the search: a car that never
        // taps does eventually die, so the promise is finite and is being
        // measured rather than assumed.
        final SimResult forever = runHeadless(
          start: run.model,
          policy: neverFlap,
          maxFrames: 600,
        );
        expect(forever.outcome, isNot(SimOutcome.survived),
            reason: 'a car that never taps has to fall out of the playfield');
        expect(forever.frames, greaterThan(advice.latestSafeCoast));
      }
    });
  });

  group('the solver bot is a competent driver', () {
    test('it survives a full sixty seconds and scores', () {
      // The point of the bot: a scripted tap cadence scores nothing against the
      // ramp, so "does the game still work" needs a driver that can actually
      // play. 3600 frames is sixty seconds at the fixed timestep.
      final AssistSolver solver = AssistSolver();
      final SimResult r = runHeadless(
        policy: solverPolicy(solver: solver),
        maxFrames: 3600,
      );

      expect(r.outcome, SimOutcome.survived,
          reason: 'the bot died after ${r.frames} frames on ${r.score} points');
      expect(r.frames, 3600);
      expect(r.score, greaterThan(30),
          reason: 'sixty seconds should clear well over thirty obstacles');
      expect(r.obstaclesPassed, r.score,
          reason: 'the driver and the model disagree about the count');

      // It is well past the warm-up, so the number above is a statement about a
      // game that has already started getting harder rather than about its easy
      // opening. It does NOT reach the plateau: obstacles arrive every 1.33s at
      // the start, so obstacle 50 is around 67 seconds and sixty is not enough.
      // The longer run in the next test is where the plateau is reached.
      expect(r.score, greaterThan(Difficulty.warmUpObstacles));
      expect(r.score, greaterThan(40));

      // And it did it with a search per second or so rather than a search per
      // frame, which is the whole reason it can run inside a game loop.
      expect(solver.passes, lessThan(r.frames ~/ 20),
          reason: 'the bot re-planned far more often than it should have to');
    });

    test('it flies through the plateau, where the ramp stops', () {
      // The depth that matters. The ramp reaches its hardest setting at obstacle
      // 50 and holds it; a bot that only ever plays the warm-up would say
      // nothing about the game most of a good run is spent in.
      final SimResult r = runHeadless(
        policy: solverPolicy(),
        maxFrames: 9000,
      );
      expect(r.outcome, SimOutcome.survived,
          reason: 'died after ${r.frames} frames on ${r.score} points');
      expect(r.score, greaterThan(Difficulty.plateauObstacle),
          reason: 'never reached the hardest setting the game has');
    });

    test('it plays several courses, not just the shipped one', () {
      for (final int seed in <int>[0, 1, 7, 99, 4242]) {
        final SimResult r = runHeadless(
          start: GameModel.ready(gapCentreFor: gapPatternForSeed(seed)),
          policy: solverPolicy(),
          maxFrames: 1800,
        );
        expect(r.outcome, SimOutcome.survived,
            reason: 'seed $seed: died after ${r.frames} frames on '
                '${r.score} points');
        expect(r.score, greaterThan(10), reason: 'seed $seed scored too little');
      }
    });

    test('it beats the heuristic bots it replaces', () {
      // The measurement that justifies the file existing. Both are run on the
      // same course for the same budget.
      final SimResult solver = runHeadless(
        policy: solverPolicy(),
        maxFrames: 3600,
      );
      final SimResult chase = runHeadless(policy: chaseGap(), maxFrames: 3600);
      final SimResult hold = runHeadless(
        policy: holdAltitude(0.5),
        maxFrames: 3600,
      );

      expect(chase.outcome, isNot(SimOutcome.survived),
          reason: 'the heuristic bot was supposed to be the weak instrument');
      expect(solver.score, greaterThan(chase.score * 2));
      expect(solver.score, greaterThan(hold.score));
    });
  });

  // ===========================================================================
  // THE AUTOPILOT IS THE SAME BOT
  // ===========================================================================
  //
  // `lib/main.dart` carries its own copy of this policy, because `tool/` is not
  // on the app's import path and a shipped APK cannot reach a `dart run`
  // script. Two copies of a decision are two chances to drift, and drift here
  // would be invisible in the worst possible way: the frame-time measurement
  // would go on reporting numbers, just about a game nobody plays.
  //
  // So the comment in `lib/main.dart` that says "these two agree" is not left
  // as a comment. This drives both over the same run and compares them frame by
  // frame.
  group('Autopilot matches tool/solver_bot.dart', () {
    test('the two policies make the same decision on every frame of a run', () {
      final Autopilot autopilot = Autopilot();
      final Policy reference = solverPolicy();

      // Driven by the REFERENCE, so both are asked about the same trajectory.
      // Letting each drive its own run would compare two different games and
      // would pass even if they disagreed — the first disagreement would put
      // the cars in different places and every frame after it would be
      // incomparable rather than equal.
      final ReplayRecorder recorder = ReplayRecorder(seed: 0);
      int frames = 0;
      int taps = 0;
      while (!recorder.finished && frames < 3600) {
        final bool wanted = reference(recorder.model, recorder.frame);
        expect(
          autopilot.wantsTap(recorder.model, recorder.frame),
          wanted,
          reason: 'the two policies disagreed on frame ${recorder.frame}',
        );
        if (wanted) {
          recorder.tap();
          taps++;
        }
        recorder.step();
        frames++;
      }

      // A negative assertion is worth what the fixture's ability to violate it
      // is worth. A run that never tapped, or that died in the first second,
      // would agree about nothing interesting and pass forever.
      expect(frames, greaterThan(1800),
          reason: 'the run was too short to compare anything');
      expect(taps, greaterThan(20),
          reason: 'the run barely tapped, so agreement means little');
      expect(recorder.model.score, greaterThan(10),
          reason: 'the run has to get somewhere for the comparison to bite');
    });

    test('it survives a restart, which is what a measurement run does', () {
      // The autopilot is stateful — it caches a backward pass — and the game
      // restarts it the instant a run ends so that a sixty-second measurement
      // is sixty seconds of play. A cache that came back stale would make the
      // second run of a measurement a different bot from the first.
      final Autopilot autopilot = Autopilot();

      int scoreOf(int runIndex) {
        final ReplayRecorder recorder = ReplayRecorder(seed: 0);
        while (!recorder.finished && recorder.frame < 1800) {
          if (autopilot.wantsTap(recorder.model, recorder.frame)) {
            recorder.tap();
          }
          recorder.step();
        }
        return recorder.model.score;
      }

      final int first = scoreOf(0);
      autopilot.reset();
      final int second = scoreOf(1);
      expect(second, first,
          reason: 'the same bot on the same course scored differently after a '
              'restart, so its cache is carrying state across runs');
      expect(first, greaterThan(10));
    });
  });

}
