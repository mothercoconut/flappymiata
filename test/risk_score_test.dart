/// Risk-weighted scoring: the measurement, the curve, and the rules about when
/// it is paid.
///
/// ============================================================================
/// THE THREE THINGS THIS HAS TO ESTABLISH
/// ============================================================================
///
/// 1. **The measurement is the one that was promised.** "The smallest distance
///    between the car's box and either pipe while passing" is a sentence;
///    `Obstacle.clearanceTo` is an algebraic rearrangement of it with no
///    comparison in it. The two are checked against each other with a second,
///    obvious implementation written out longhand — because a rearrangement is
///    exactly the kind of thing that is right in the comment and wrong in the
///    code.
///
/// 2. **The curve is what the header says it is.** Every threshold in the table
///    in `lib/game/risk_score.dart` is asserted on both sides, so the file's own
///    documentation is a checked claim rather than a description.
///
/// 3. **It cannot be farmed.** Stated as invariants over whole runs rather than
///    as a list of tricks somebody thought of: the risk score never moves on a
///    frame where the obstacle count does not, never goes down, and a run that
///    passes nothing is worth nothing however close it flew.
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:flappymiata/game/course_seed.dart';
import 'package:flappymiata/game/game_model.dart';
import 'package:flappymiata/game/replay.dart';

import '../tool/fairness.dart';
import '../tool/headless_sim.dart';
import '../tool/solver_bot.dart';

/// One frame at 60fps.
const double frame = 1.0 / 60.0;

/// The room a base-height gap has to give a car of the shipped size.
final double baseRoom = (GameModel.gapHeight - GameModel.carHeight) / 2;

/// The clearance the SENTENCE describes, written out longhand: the smaller of
/// the two vertical distances from the car's box to the two pipe boxes.
///
/// Deliberately a second implementation, sharing nothing with the one under
/// test. `Obstacle.clearanceTo` folds the same quantity into "room minus how far
/// off centre", which is a better thing to read and a worse thing to trust
/// without a witness.
double clearanceLonghand(Obstacle o, Box car) {
  final double toUpperPipe = car.top - o.topBox.bottom;
  final double toLowerPipe = o.bottomBox.top - car.bottom;
  return toUpperPipe < toLowerPipe ? toUpperPipe : toLowerPipe;
}

/// A run recorded frame by frame, so invariants can be checked across it.
List<GameModel> traceOf({
  required GapPattern gaps,
  required Policy policy,
  int maxFrames = 3000,
}) {
  GameModel model = GameModel.ready(gapCentreFor: gaps);
  final List<GameModel> trace = <GameModel>[model];
  for (int f = 0; f < maxFrames; f++) {
    if (policy(model, f)) model = model.flap();
    model = model.tick(frame);
    trace.add(model);
    if (model.state == RunState.dead) break;
  }
  return trace;
}

/// The inputs [policy] produces on [gaps], so the same flying can be replayed
/// against a different course.
List<bool> inputsOf({
  required GapPattern gaps,
  required Policy policy,
  int maxFrames = 3000,
}) {
  GameModel model = GameModel.ready(gapCentreFor: gaps);
  final List<bool> inputs = <bool>[];
  for (int f = 0; f < maxFrames; f++) {
    final bool tap = policy(model, f);
    inputs.add(tap);
    if (tap) model = model.flap();
    model = model.tick(frame);
    if (model.state == RunState.dead) break;
  }
  return inputs;
}

void main() {
  group('riskBonus — the curve is the one the file documents', () {
    test('dead centre is worth nothing', () {
      // The whole point of the shape. A pass that gives away none of the room
      // has risked nothing, and the reward for risking nothing is zero.
      expect(riskBonus(clearance: baseRoom, room: baseRoom), 0);
    });

    test('touching a lip is worth the maximum', () {
      // Zero clearance is a real, survivable pass: `Box.overlaps` is strict, so
      // a car whose roof is exactly level with a pipe lip has threaded it.
      expect(riskBonus(clearance: 0.0, room: baseRoom), maxRiskBonus);
    });

    test('each of the five thresholds is where the header says it is', () {
      // floor(maxRiskBonus * given^3) reaches `b` first at given = (b/5)^(1/3).
      // Asserted from BOTH sides of each threshold, because a curve tested only
      // above its steps is satisfied by a curve with no steps in it.
      const List<double> firstGiven = <double>[
        0.5848035476425733, // 1
        0.7368062997280773, // 2
        0.8434326653017492, // 3
        0.9283177667225558, // 4
        1.0, // 5
      ];
      for (int b = 1; b <= maxRiskBonus; b++) {
        final double g = firstGiven[b - 1];
        // given = 1 - clearance/room, so clearance = room * (1 - given).
        expect(
          riskBonus(clearance: baseRoom * (1 - g - 1e-6), room: baseRoom),
          b,
          reason: 'just past the threshold for $b',
        );
        expect(
          riskBonus(clearance: baseRoom * (1 - g + 1e-6), room: baseRoom),
          b - 1,
          reason: 'just short of the threshold for $b',
        );
      }
    });

    test('the reward never falls as the pass gets closer', () {
      // Monotone, sampled densely enough that a curve that dipped anywhere would
      // be caught. Monotonicity is what makes "flying closer is worth more" a
      // property rather than a coincidence of the values picked above.
      int previous = -1;
      for (int i = 100; i >= 0; i--) {
        final double clearance = baseRoom * i / 100;
        final int bonus = riskBonus(clearance: clearance, room: baseRoom);
        expect(bonus, greaterThanOrEqualTo(previous),
            reason: 'clearance ${clearance.toStringAsFixed(5)} pays less than '
                'a wider pass did');
        previous = bonus;
      }
      expect(previous, maxRiskBonus, reason: 'the top of the curve is not the '
          'maximum, so the range is not what the doc says');
    });

    test('it is a fraction of the room, so the ramp cannot inflate it', () {
      // The gaps narrow as a run goes on — `Difficulty.tightestGapHeight` is a
      // tenth shorter than the base — so a reward keyed on a raw DISTANCE would
      // pay more and more for identical driving. The same fraction of the room
      // has to be worth the same at both ends of the ramp.
      final double plateauRoom =
          (Difficulty.tightestGapHeight - GameModel.carHeight) / 2;
      expect(plateauRoom, lessThan(baseRoom), reason: 'the ramp does narrow the '
          'gap, or this test is checking nothing');

      for (final double given in <double>[0.1, 0.35, 0.6, 0.75, 0.9, 0.99]) {
        expect(
          riskBonus(clearance: plateauRoom * (1 - given), room: plateauRoom),
          riskBonus(clearance: baseRoom * (1 - given), room: baseRoom),
          reason: 'the same quality of pass pays differently at given=$given',
        );
      }
    });

    test('the best pass the physics allows is still worth nothing', () {
      // THE CALIBRATION, DERIVED RATHER THAN ASSERTED BY TASTE. A car cannot
      // hold a corridor tighter than `minimumExcursion` over the frames an
      // obstacle spends level with it, so the very best possible pass still
      // gives away half that excursion. `minimumExcursion` shares no code with
      // the prover or with the curve — it enumerates flap patterns and
      // integrates them longhand — so this ties the threshold to the physics
      // through an independent route.
      final int window = obstacleOverlapFrames();
      final ExcursionBound best = minimumExcursion(window, maxFlaps: 2);
      final double bestClearance = baseRoom - best.excursion / 2;

      expect(bestClearance, greaterThan(0),
          reason: 'a lone obstacle would be unpassable, which contradicts the '
              'fairness proof');
      expect(riskBonus(clearance: bestClearance, room: baseRoom), 0,
          reason: 'the tightest corridor a car can hold is ${(1 -
              bestClearance / baseRoom).toStringAsFixed(3)} of the room, and '
              'the first point is not supposed to be reachable by flying well');
    });

    test('degenerate inputs are answered rather than thrown at', () {
      // A scoring rule that throws is a scoring rule that can end a run, so
      // every one of these is a defined answer and not an accident.
      expect(riskBonus(clearance: 0.0, room: 0.0), 0,
          reason: 'a gap exactly as tall as the car has no room to grade');
      expect(riskBonus(clearance: -0.01, room: 0.0), 0,
          reason: 'and still none when the boxes overlapped');
      expect(riskBonus(clearance: 0.05, room: -0.1), 0,
          reason: 'a gap shorter than the car must not pay a bonus');
      expect(riskBonus(clearance: double.infinity, room: baseRoom), 0,
          reason: 'never measured is not the same as measured at zero');
      expect(riskBonus(clearance: double.negativeInfinity, room: baseRoom), 0);
      expect(riskBonus(clearance: double.nan, room: baseRoom), 0);
      expect(riskBonus(clearance: baseRoom * 2, room: baseRoom), 0,
          reason: 'better than dead centre is not reachable, and pays nothing');
      expect(riskBonus(clearance: -baseRoom, room: baseRoom), maxRiskBonus,
          reason: 'an overlap is a crash, and must not pay MORE than the '
              'maximum — the range is 0..maxRiskBonus and nothing else');
    });
  });

  group('clearance is measured the way the sentence says', () {
    const Obstacle pipe = Obstacle(
      index: 0,
      x: 0.30,
      width: GameModel.obstacleWidth,
      gapCentre: 0.5,
      gapHeight: GameModel.gapHeight,
    );

    test('a centred car has exactly the room, and no more', () {
      expect(pipe.roomFor(GameModel.carHeight), baseRoom);
      // `closeTo` rather than equality by two ulps: the clearance is computed as
      // "room minus how far off centre", which goes through one more subtraction
      // than `roomFor` does. Nothing downstream can see 2e-17 — the reward is an
      // integer and the first threshold is 58% of the room away — but stating
      // equality here would be stating something false.
      expect(pipe.clearanceTo(GameModel.carBoxAt(0.5)), closeTo(baseRoom, 1e-15));
    });

    test('"level with" shares its edges with the collision rule', () {
      // The interval clearance is measured over. Both boundaries are checked
      // from both sides, because this is the one place they CAN be: inside
      // `GameModel.tick` the pipe's x comes out of the physics, so no test could
      // ever land an edge exactly on the car's.
      const double left = 0.22;
      const double right = 0.38;
      final double pipeLeft = pipe.left;
      final double pipeRight = pipe.right;

      expect(pipe.isLevelWith(left, right), isTrue,
          reason: 'a car straddling the pipe is level with it');

      // Sharing exactly one edge is NOT level, matching `Box.overlaps`.
      expect(pipe.isLevelWith(pipeRight, pipeRight + 0.1), isFalse,
          reason: 'the car starts where the pipe ends');
      expect(pipe.isLevelWith(pipeLeft - 0.1, pipeLeft), isFalse,
          reason: 'the car ends where the pipe starts');

      // And crossing that same edge by a hair IS.
      const double hair = 1e-9;
      expect(pipe.isLevelWith(pipeRight - hair, pipeRight + 0.1), isTrue);
      expect(pipe.isLevelWith(pipeLeft - 0.1, pipeLeft + hair), isTrue);

      // AND IT REALLY IS THE COLLISION RULE'S X HALF. Swept over the whole
      // playfield: wherever the car is not level with the pipe it cannot be
      // hitting it, and wherever it IS level, being outside the gap means it is.
      // That equivalence is the reason "while passing" and "while it could kill
      // you" are the same interval.
      for (int cx = 0; cx <= 100; cx++) {
        final double carLeft = cx / 100 - GameModel.carWidth / 2;
        final double carRight = carLeft + GameModel.carWidth;
        final bool level = pipe.isLevelWith(carLeft, carRight);

        // Somewhere well inside the upper pipe, vertically.
        final Box high = Box(
          left: carLeft,
          top: playfieldTop,
          right: carRight,
          bottom: pipe.gapTop - 0.01,
        );
        expect(high.overlaps(pipe.topBox), level,
            reason: 'car at x=${cx / 100}: level=$level but collision says '
                '${high.overlaps(pipe.topBox)}');

        // And somewhere squarely inside the gap, where nothing can be hit.
        final Box inGap = Box(
          left: carLeft,
          top: pipe.gapCentre - 0.001,
          right: carRight,
          bottom: pipe.gapCentre + 0.001,
        );
        expect(inGap.overlaps(pipe.topBox), isFalse);
        expect(inGap.overlaps(pipe.bottomBox), isFalse);
      }
    });

    test('a car resting on either lip has exactly zero', () {
      // The two boundary positions, both of which are survivable passes: the
      // collision test is strict, so sharing an edge is a scrape and not a hit.
      final double onCeiling = pipe.gapTop + GameModel.carHeight / 2;
      final double onFloor = pipe.gapBottom - GameModel.carHeight / 2;

      expect(pipe.clearanceTo(GameModel.carBoxAt(onCeiling)),
          closeTo(0.0, 1e-15));
      expect(pipe.clearanceTo(GameModel.carBoxAt(onFloor)), closeTo(0.0, 1e-15));

      // And the positions really are the ones collision calls survivable, or
      // the two numbers above would be about somewhere else.
      expect(GameModel.carBoxAt(onCeiling).overlaps(pipe.topBox), isFalse);
      expect(GameModel.carBoxAt(onFloor).overlaps(pipe.bottomBox), isFalse);
    });

    test('an overlapping car measures negative, and the boxes agree', () {
      final double inside = pipe.gapTop + GameModel.carHeight / 4;
      expect(pipe.clearanceTo(GameModel.carBoxAt(inside)), lessThan(0));
      expect(GameModel.carBoxAt(inside).overlaps(pipe.topBox), isTrue,
          reason: 'a negative clearance that was not a collision would mean the '
              'two rules disagree about what touching is');
    });

    test('it agrees with the longhand minimum everywhere', () {
      // The rearrangement, checked against the sentence it claims to be. Swept
      // across the whole playfield and across three gap heights, so a sign
      // error or a missing half would show up somewhere.
      for (final double gapHeight in <double>[
        GameModel.gapHeight,
        Difficulty.tightestGapHeight,
        0.20,
      ]) {
        for (int gc = 25; gc <= 75; gc += 5) {
          final Obstacle o = Obstacle(
            index: 0,
            x: 0.30,
            width: GameModel.obstacleWidth,
            gapCentre: gc / 100,
            gapHeight: gapHeight,
          );
          for (int cy = 0; cy <= 100; cy++) {
            final Box car = GameModel.carBoxAt(cy / 100);
            expect(o.clearanceTo(car), closeTo(clearanceLonghand(o, car), 1e-15),
                reason: 'gap $gc/100 h$gapHeight, car at ${cy / 100}');
          }
        }
      }
    });
  });

  group('an obstacle remembers its closest approach and nothing else', () {
    const Obstacle pipe = Obstacle(
      index: 4,
      x: 0.5,
      width: GameModel.obstacleWidth,
      gapCentre: 0.5,
      gapHeight: GameModel.gapHeight,
    );

    test('a fresh obstacle has been measured at nothing', () {
      expect(pipe.minClearance, double.infinity);
      expect(riskBonus(clearance: pipe.minClearance,
          room: pipe.roomFor(GameModel.carHeight)), 0);
    });

    test('the first measurement lands, and only smaller ones replace it', () {
      final Obstacle a = pipe.withClearance(0.05);
      expect(a.minClearance, 0.05);

      final Obstacle b = a.withClearance(0.02);
      expect(b.minClearance, 0.02, reason: 'a closer pass has to be remembered');

      final Obstacle c = b.withClearance(0.09);
      expect(c.minClearance, 0.02,
          reason: 'flying wide afterwards must not undo a scrape');
      expect(identical(c, b), isTrue,
          reason: 'nothing changed, so nothing should have been allocated');
    });

    test('a repeat of the current minimum is not a change', () {
      // THE BOUNDARY. `>=` and `>` differ on exactly this input and both produce
      // an EQUAL obstacle, so a value comparison could never separate them —
      // which would leave the line untestable. Identity can.
      final Obstacle a = pipe.withClearance(0.03);
      expect(identical(a.withClearance(0.03), a), isTrue);
      expect(identical(a.withClearance(0.030000001), a), isTrue);
      expect(identical(a.withClearance(0.029999999), a), isFalse);
    });

    test('moving and scoring carry the measurement with them', () {
      final Obstacle measured = pipe.withClearance(0.011);
      expect(measured.movedBy(-0.25).minClearance, 0.011);
      expect(measured.markScored().minClearance, 0.011);
      expect(measured.movedBy(-0.25).markScored().minClearance, 0.011);
    });

    test('two obstacles differing only in their measurement are not equal', () {
      // The field is part of the run, so it has to be part of equality — or
      // `test/replay_test.dart`'s frame-for-frame comparison would silently stop
      // covering it.
      expect(pipe.withClearance(0.02), isNot(pipe.withClearance(0.03)));
      expect(pipe.withClearance(0.02), pipe.withClearance(0.02));
      expect(pipe.withClearance(0.02).hashCode,
          pipe.withClearance(0.02).hashCode);
    });
  });

  group('the model measures over the right interval and pays once', () {
    test('an obstacle is only measured while it is level with the car', () {
      // The interval is the frames the two boxes overlap horizontally — the
      // exact frames the pipe could kill the car. A pipe still approaching has
      // been measured at nothing.
      GameModel m = GameModel.ready(gapCentreFor: (int _) => 0.5).flap();
      m = m.tick(frame);
      expect(m.obstacles, hasLength(1));
      final Obstacle spawned = m.obstacles.single;
      expect(spawned.x, playfieldRight, reason: 'it should be at the far edge');
      expect(spawned.minClearance, double.infinity,
          reason: 'a pipe a screen away is not being passed');

      // Fly it, and watch the measurement start exactly when the boxes meet.
      int firstMeasuredFrame = -1;
      int firstOverlapFrame = -1;
      final double carLeft = GameModel.carX - GameModel.carWidth / 2;
      final double carRight = GameModel.carX + GameModel.carWidth / 2;
      for (int f = 0; f < 200 && m.state == RunState.playing; f++) {
        if (m.y > 0.5) m = m.flap();
        m = m.tick(frame);
        for (final Obstacle o in m.obstacles) {
          if (o.index != 0) continue;
          final bool overlapping = carLeft < o.right && carRight > o.left;
          if (overlapping && firstOverlapFrame < 0) firstOverlapFrame = f;
          if (o.minClearance.isFinite && firstMeasuredFrame < 0) {
            firstMeasuredFrame = f;
          }
        }
      }
      expect(firstOverlapFrame, greaterThan(0),
          reason: 'the pipe never reached the car, so nothing was tested');
      expect(firstMeasuredFrame, firstOverlapFrame,
          reason: 'the measurement started on a different frame from the '
              'overlap it is supposed to be measured over');
    });

    test('the risk score only ever moves on a frame that also scores', () {
      // THE ANTI-FARM INVARIANT, stated once and checked over many runs instead
      // of enumerating tricks. If risk can only be paid on the frame an obstacle
      // is passed, then there is nothing to repeat, nothing to accumulate by
      // loitering, and nothing to collect from a pipe that was never got past.
      for (final int seed in <int>[0, 3, 17, 512, 4242]) {
        for (final Policy policy in <Policy>[
          solverPolicy(),
          chaseGap(),
          chaseGap(lead: 0.01),
          startThenDrop,
          alwaysFlap,
        ]) {
          final List<GameModel> trace = traceOf(
            gaps: gapPatternForSeed(seed),
            policy: policy,
            maxFrames: 1500,
          );
          for (int f = 1; f < trace.length; f++) {
            final int dScore = trace[f].score - trace[f - 1].score;
            final int dRisk = trace[f].riskScore - trace[f - 1].riskScore;
            expect(dScore, greaterThanOrEqualTo(0));
            expect(dRisk, greaterThanOrEqualTo(0),
                reason: 'seed $seed frame $f: the risk score went DOWN');
            if (dScore == 0) {
              expect(dRisk, 0,
                  reason: 'seed $seed frame $f: risk was paid on a frame that '
                      'passed no obstacle');
            } else {
              expect(dRisk, lessThanOrEqualTo(dScore * maxRiskBonus),
                  reason: 'seed $seed frame $f: paid more than the ceiling');
            }
          }
        }
      }
    });

    test('a run that passes nothing is worth nothing, however close it flew',
        () {
      // The specific trick the requirement names: scraping a pipe you never get
      // past. The fixture is a run that dies ON an obstacle, so a clearance was
      // certainly recorded against it.
      final List<GameModel> trace = traceOf(
        gaps: gapPatternForSeed(0),
        policy: chaseGap(lead: 0.05),
        maxFrames: 1200,
      );
      final GameModel end = trace.last;
      expect(end.state, RunState.dead);
      expect(end.score, 0, reason: 'this fixture was supposed to score nothing');
      expect(end.riskScore, 0);

      // Non-vacuous: the car really did come close to a pipe, so "worth
      // nothing" is about the payout rule and not about a car that was never
      // near anything.
      final double closest = end.obstacles
          .map((Obstacle o) => o.minClearance)
          .fold(double.infinity, (double a, double b) => b < a ? b : a);
      expect(closest.isFinite, isTrue,
          reason: 'nothing was ever measured, so nothing was scraped');
      expect(closest, lessThan(baseRoom / 2),
          reason: 'the car never actually flew close to anything');
    });

    test('a fresh model and a reset one owe nothing', () {
      const GameModel fresh = GameModel.ready();
      expect(fresh.riskScore, 0);
      expect(fresh.flap().riskScore, 0);

      final List<GameModel> trace = traceOf(
        gaps: gapPatternForSeed(0),
        policy: solverPolicy(),
        maxFrames: 900,
      );
      expect(trace.last.riskScore, greaterThan(0),
          reason: 'nothing was earned, so nothing is being cleared');
      expect(trace.last.reset().riskScore, 0);
      expect(trace.last.reset().score, 0);
    });
  });

  group('the reward reflects the risk', () {
    test('the same flying through a gap placed closer is worth more', () {
      // THE FEATURE, as one comparison. The inputs are identical in both runs,
      // so the car's trajectory is identical — only the GAP moves. The closer
      // pass is therefore the same driving with less room given, which is
      // exactly the thing the reward is supposed to notice and the old scoring
      // could not.
      double centred(int _) => 0.5;
      final List<bool> inputs = inputsOf(
        gaps: centred,
        policy: solverPolicy(),
        maxFrames: 600,
      );

      // Stops the instant the FIRST obstacle has been passed, so the whole run
      // is worth exactly one point and its risk score is exactly that one
      // obstacle's bonus. Anything longer would be summing bonuses across
      // obstacles flown at different distances, and the comparison would stop
      // being about a single pass.
      ({int risk, double clearance})? passOne(double shift) {
        GameModel m = GameModel.ready(gapCentreFor: (int _) => 0.5 + shift);
        double closest = double.infinity;
        for (int f = 0; f < inputs.length; f++) {
          if (inputs[f]) m = m.flap();
          m = m.tick(frame);
          for (final Obstacle o in m.obstacles) {
            if (o.index == 0 && o.minClearance < closest) {
              closest = o.minClearance;
            }
          }
          if (m.state == RunState.dead) return null;
          if (m.score >= 1) {
            return (risk: m.riskScore, clearance: closest);
          }
        }
        return null;
      }

      // The gap is swept past the car in both directions; which direction makes
      // a pass tighter depends on how the fixed inputs happen to fly, so it is
      // measured rather than assumed. Every surviving shift is a run that passed
      // the same single obstacle, so all of them are comparable.
      final List<({double shift, int risk, double clearance})> passes =
          <({double shift, int risk, double clearance})>[];
      for (int step = -60; step <= 60; step++) {
        final double shift = step * 0.002;
        final ({int risk, double clearance})? r = passOne(shift);
        if (r == null || !r.clearance.isFinite) continue;
        passes.add((shift: shift, risk: r.risk, clearance: r.clearance));
      }

      expect(passes.length, greaterThan(10),
          reason: 'too few surviving courses to compare anything');

      passes.sort((({double shift, int risk, double clearance}) a,
              ({double shift, int risk, double clearance}) b) =>
          a.clearance.compareTo(b.clearance));
      final ({double shift, int risk, double clearance}) tightest = passes.first;
      final ({double shift, int risk, double clearance}) widest = passes.last;

      // THE IDENTITY. Every single-obstacle run is worth exactly what the curve
      // says its measured clearance is worth — so the reward really is a
      // function of the clearance and not of anything else about the run.
      for (final ({double shift, int risk, double clearance}) p in passes) {
        expect(p.risk, riskBonus(clearance: p.clearance, room: baseRoom),
            reason: 'shift ${p.shift.toStringAsFixed(3)}: a pass with clearance '
                '${p.clearance.toStringAsFixed(5)} paid ${p.risk}');
      }

      // THE FEATURE. Identical inputs, identical obstacle count, different
      // clearance, different payout — which is exactly what the old scoring
      // could not express.
      expect(widest.clearance - tightest.clearance, greaterThan(baseRoom / 4),
          reason: 'the sweep never produced two genuinely different passes');
      expect(tightest.risk, greaterThan(widest.risk),
          reason: 'the same obstacle, flown closer, was worth the same — which '
              'is the whole defect this feature exists to fix');
      expect(widest.risk, 0,
          reason: 'the widest pass in the sweep should be paying nothing at '
              'all, or the curve is rewarding ordinary driving');
    });

    test('the score a record is checked against is untouched', () {
      // The compatibility promise. Adding the risk reward must not change what
      // `score` means, because every stored best run and every run code claims
      // that number and is re-executed against it.
      final List<bool> inputs = inputsOf(
        gaps: gapPatternForSeed(0),
        policy: solverPolicy(),
        maxFrames: 900,
      );
      final Replay recorded = Replay(
        seed: 0,
        tapFrames: <int>[
          for (int i = 0; i < inputs.length; i++)
            if (inputs[i]) i,
        ],
        frames: inputs.length,
      );
      final GameModel end = replayFinalModel(recorded);

      expect(end.score, greaterThan(0));
      expect(end.riskScore, greaterThan(0),
          reason: 'the fixture never earned any risk, so this proves nothing '
              'about the two numbers being separate');
      expect(end.score, isNot(end.riskScore),
          reason: 'the two numbers happen to coincide, so this run cannot show '
              'that they are independent');

      // The driver counts obstacles independently of the model, by watching them
      // cross behind the car. Its answer must still be the obstacle count.
      final SimResult sim = replay(inputs,
          start: GameModel.ready(gapCentreFor: gapPatternForSeed(0)));
      expect(sim.obstaclesPassed, end.score);
    });

    test('a replayed run reproduces its risk score exactly', () {
      // Determinism, in the currency the feature added. The trace comparison in
      // `test/replay_test.dart` already covers this through `GameModel ==`;
      // stating it here means a change that dropped `riskScore` out of equality
      // would be caught by something that names the field.
      for (final int seed in <int>[0, 11, 4242]) {
        final List<bool> inputs = inputsOf(
          gaps: gapPatternForSeed(seed),
          policy: solverPolicy(),
          maxFrames: 900,
        );
        final Replay recorded = Replay(
          seed: seed,
          tapFrames: <int>[
            for (int i = 0; i < inputs.length; i++)
              if (inputs[i]) i,
          ],
          frames: inputs.length,
        );
        final int once = replayFinalModel(recorded).riskScore;
        final int twice = replayFinalModel(recorded).riskScore;
        expect(once, twice);
        expect(once, greaterThan(0), reason: 'seed $seed earned nothing, so '
            'reproducing it proves nothing');

        // And every frame of it, not only the end — two runs can diverge and
        // re-converge.
        final List<GameModel> a = replayTrace(recorded);
        final List<GameModel> b = replayTrace(recorded);
        for (int f = 0; f < a.length; f++) {
          expect(a[f].riskScore, b[f].riskScore, reason: 'seed $seed frame $f');
        }
      }
    });
  });
}
