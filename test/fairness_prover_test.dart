/// Tests for the fairness prover in `tool/fairness.dart`.
///
/// There are two jobs here and they are not the same job.
///
///   1. THE GATE (`fairness gate` group at the bottom). A reduced version of the
///      10,000-course sweep that `tool/prove_fairness.dart` runs: enough of the
///      shipped gap pattern to be meaningful, few enough to run in a normal
///      `flutter test`. It fails if any course is unsurvivable.
///
///   2. PROVING THE PROVER CAN FAIL. A gate that can only ever say "fine" is
///      not a gate. Most of this file is courses that are impossible for
///      specific, different reasons, plus a check that the prover's threshold
///      for a single obstacle lands exactly where physics computed OUTSIDE the
///      prover says it must.
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:flappymiata/game/game_model.dart';

import '../tool/fairness.dart';
import '../tool/headless_sim.dart';

void main() {
  final FairnessProver prover = FairnessProver();
  const ReferenceProver reference = ReferenceProver();

  group('the prover models the shipped game and not something near it', () {
    test('the prover world matches GameModel obstacle for obstacle', () {
      // The prover re-implements the obstacle half of `GameModel.tick` so it can
      // run the world without a car in it. That duplication is the single most
      // dangerous thing in the prover: if the game's spawn cadence changed and
      // this did not, the prover would be proving things about a game nobody
      // ships, and every test below would still pass. So pin them together.
      final Course course = Course.fromDefaultPattern(0, 5);
      final ProofResult proof = prover.prove(course, witness: true);
      expect(proof.survivable, isTrue);

      final List<bool> inputs = proof.witness!;
      GameModel model = GameModel.ready(gapCentreFor: course.asGapPattern);
      final CourseWorld world = CourseWorld(course);

      for (int f = 0; f < inputs.length; f++) {
        if (inputs[f]) model = model.flap();
        model = model.tick(frameSeconds);
        world.step();

        expect(model.state, RunState.playing, reason: 'died on frame $f');
        expect(world.obstacles.length, model.obstacles.length,
            reason: 'obstacle count diverged on frame $f');
        for (int i = 0; i < model.obstacles.length; i++) {
          final Obstacle real = model.obstacles[i];
          final WorldObstacle mine = world.obstacles[i];
          expect(mine.index, real.index, reason: 'index diverged on frame $f');
          expect(mine.x, closeTo(real.x, 1e-12),
              reason: 'x diverged on frame $f');
          // Past the end of the course the prover's world deliberately spawns
          // an obstacle with a gap taller than the playfield, so those cannot
          // constrain anything. Only the in-course gaps are comparable.
          if (real.index < course.gaps.length) {
            expect(mine.gap.centre, closeTo(real.gapCentre, 1e-12));
            expect(mine.gap.height, closeTo(real.gapHeight, 1e-12));
          }
        }
      }
    });

    test('a SURVIVABLE verdict comes with inputs the real game accepts', () {
      // The strongest thing the prover can hand over: not "my search says yes"
      // but "here are the taps, run them yourself". Twenty stretches of the real
      // pattern, each proved and then replayed through the shipped GameModel.
      for (int s = 0; s < 20; s++) {
        final Course course = Course.fromDefaultPattern(s, 3);
        final ProofResult proof = prover.prove(course, witness: true);
        expect(proof.survivable, isTrue, reason: 'course $s');

        final SimResult sim = replay(
          proof.witness!,
          start: GameModel.ready(gapCentreFor: course.asGapPattern),
        );
        expect(sim.alive, isTrue,
            reason: 'course $s: the witness died in the real game '
                '(${sim.outcome.name} at frame ${sim.frames})');
        expect(sim.score, greaterThanOrEqualTo(3), reason: 'course $s');
      }
    });
  });

  group('the prover can say NO', () {
    // Each of these is impossible for a DIFFERENT reason, and the prover has to
    // name the mechanism rather than merely refuse. A prover that returned
    // `false` for everything would pass the verdicts and fail the mechanisms.

    test('a gap narrower than the car is tall is unsurvivable', () {
      final Course pinhole = Course(
        name: 'pinhole',
        gaps: const <CourseGap>[CourseGap(0.5, 0.02)],
      );
      expect(0.02, lessThan(GameModel.carHeight));

      final ProofResult r = prover.prove(pinhole);
      expect(r.survivable, isFalse);
      expect(r.cause, FailureCause.gapNarrowerThanCar);
      expect(reference.survives(pinhole), isFalse);
    });

    test('two extremes too close together are unsurvivable, and the reason is '
        'kinematic rather than geometric', () {
      // Spacing is 0.36, which is larger than carWidth + obstacleWidth
      // (0.3242), so the two obstacles are NEVER over the car at the same
      // moment. Nothing about this course is geometrically impossible: both gaps
      // are full size and both are individually flyable. What defeats it is that
      // roughly five frames of free air is not enough to cross the playfield.
      expect(0.36, greaterThan(GameModel.carWidth + GameModel.obstacleWidth));

      final Course zigzag = Course(
        name: 'zigzag',
        gaps: <CourseGap>[
          CourseGap(GameModel.minGapCentre, GameModel.gapHeight),
          CourseGap(GameModel.maxGapCentre, GameModel.gapHeight),
        ],
        spacing: 0.36,
      );

      final ProofResult r = prover.prove(zigzag);
      expect(r.survivable, isFalse);
      expect(r.cause, FailureCause.unreachable);
      expect(r.deathObstacleIndex, 1,
          reason: 'the first gap is fine; it is the transition that kills');
      expect(reference.survives(zigzag), isFalse);

      // And the control: the same two gaps at the game's real spacing are fine.
      // Without this, "unsurvivable" could just be the prover disliking extreme
      // gap centres.
      final Course spaced = Course(
        name: 'zigzag-at-real-spacing',
        gaps: zigzag.gaps,
      );
      expect(prover.prove(spaced).survivable, isTrue);
    });

    test('a gap reachable only from outside the playfield is unsurvivable', () {
      // The gap is full size — the car fits through it easily. It is just in a
      // place the car cannot legally be.
      final Course ceiling = Course(
        name: 'above-the-ceiling',
        gaps: const <CourseGap>[CourseGap(-0.20, GameModel.gapHeight)],
      );

      final ProofResult r = prover.prove(ceiling);
      expect(r.survivable, isFalse);
      expect(r.cause, FailureCause.gapOutsidePlayfield);
      expect(reference.survives(ceiling), isFalse);
    });

    test('two gaps straddling the car at once with nothing in common is '
        'unsurvivable', () {
      final Course clash = Course(
        name: 'overlap-clash',
        gaps: <CourseGap>[
          CourseGap(GameModel.minGapCentre, GameModel.gapHeight),
          CourseGap(GameModel.maxGapCentre, GameModel.gapHeight),
        ],
        spacing: 0.20,
      );
      expect(0.20, lessThan(GameModel.carWidth + GameModel.obstacleWidth));

      final ProofResult r = prover.prove(clash);
      expect(r.survivable, isFalse);
      expect(r.cause, FailureCause.overlappingGapsDisjoint);
      expect(reference.survives(clash), isFalse);
    });

    test('the easiest course that exists is survivable', () {
      // The positive control for all of the above.
      final Course easy = Course(
        name: 'wide-open',
        gaps: const <CourseGap>[CourseGap(0.5, GameModel.gapHeight)],
        playableByGame: true,
      );
      final ProofResult r = prover.prove(easy, witness: true);
      expect(r.survivable, isTrue);
      expect(r.cause, isNull);
      expect(reference.survives(easy), isTrue);

      final SimResult sim = replay(
        r.witness!,
        start: GameModel.ready(gapCentreFor: easy.asGapPattern),
      );
      expect(sim.alive, isTrue);
      expect(sim.score, 1);
    });
  });

  group('the threshold is where the physics puts it', () {
    test('a single obstacle flips at carHeight + the flattest trajectory', () {
      // The check that would catch a prover which is merely self-consistent.
      //
      // A gap does not have to admit the car, it has to admit the car for the
      // whole run of frames that obstacle spends level with it — and the
      // flattest trajectory that exists still moves. `minimumExcursion` works
      // that number out by enumerating flap patterns and integrating them
      // directly: no reachable set, no lattice, no bitmaps, nothing the prover
      // touches. The two answers then have to agree.
      final int overlap = obstacleOverlapFrames();
      expect(overlap, greaterThan(30));

      final ExcursionBound bound = minimumExcursion(overlap);
      final double predicted = GameModel.carHeight + bound.excursion;

      double lo = 0.0;
      double hi = GameModel.gapHeight;
      for (int i = 0; i < 40; i++) {
        final double mid = (lo + hi) / 2;
        final Course probe = Course(
          name: 'probe',
          gaps: <CourseGap>[CourseGap(0.5, mid)],
        );
        if (prover.prove(probe).survivable) {
          hi = mid;
        } else {
          lo = mid;
        }
      }

      expect(hi, closeTo(predicted, 2 * prover.cell),
          reason: 'the prover flips at $hi, the physics says $predicted');

      // And emphatically NOT at carHeight, which is where a prover that only
      // asked "does the car fit through the hole?" would flip. The gap between
      // the two numbers is the whole difficulty of the game.
      expect((hi - GameModel.carHeight).abs(), greaterThan(0.08));
    });

    test('the flip is sharp in both directions', () {
      final int overlap = obstacleOverlapFrames();
      final double predicted =
          GameModel.carHeight + minimumExcursion(overlap).excursion;

      Course probe(double height) =>
          Course(name: 'probe', gaps: <CourseGap>[CourseGap(0.5, height)]);

      expect(prover.prove(probe(predicted - 3 * prover.cell)).survivable,
          isFalse);
      expect(
          prover.prove(probe(predicted + 3 * prover.cell)).survivable, isTrue);
    });
  });

  group('two independent implementations agree', () {
    test('the bitmap search and the naive hash-set search give the same '
        'answers', () {
      // The fast prover is bit-shifting on a closed-form lattice, which no
      // reader can check by eye. The reference is a hash set of explicit
      // (y, framesSinceFlap) pairs with y accumulated frame by frame exactly as
      // `GameModel.tick` accumulates it. A bug in the shifts shows up here as a
      // disagreement rather than as a confident wrong number.
      final List<Course> battery = <Course>[
        Course.fromDefaultPattern(0, 2),
        Course.fromDefaultPattern(7, 2),
        Course.fromDefaultPattern(41, 2),
        Course(
          name: 'tight',
          gaps: <CourseGap>[CourseGap(0.5, 0.12)],
        ),
        Course(
          name: 'tighter',
          gaps: <CourseGap>[CourseGap(0.5, 0.117)],
        ),
        Course(
          name: 'high-then-low',
          gaps: <CourseGap>[
            CourseGap(GameModel.minGapCentre, GameModel.gapHeight),
            CourseGap(GameModel.maxGapCentre, GameModel.gapHeight),
          ],
          spacing: 0.42,
        ),
      ];

      for (final Course c in battery) {
        final bool fast = prover.prove(c).survivable;
        final bool? slow = reference.survives(c);
        expect(slow, isNotNull, reason: '${c.name}: reference hit its cap');
        expect(fast, slow, reason: '${c.name}: the two searches disagree');
      }
    });
  });

  group('margins', () {
    test('a tighter gap has a smaller margin than a looser one', () {
      Course probe(double height) =>
          Course(name: 'probe', gaps: <CourseGap>[CourseGap(0.5, height)]);

      final double wide = tightestMargin(probe(0.28), prover: prover);
      final double narrow = tightestMargin(probe(0.20), prover: prover);
      expect(narrow, lessThan(wide));

      // Half the extra height, on the nose: a centred gap's margin is exactly
      // (gapHeight - carHeight) / 2 minus whatever the trajectory has to spend
      // on moving, and that second term does not depend on the height.
      expect(wide - narrow, closeTo(0.04, 3 * prover.cell));
    });

    test('an unsurvivable course reports a negative margin', () {
      final Course pinhole = Course(
        name: 'pinhole',
        gaps: const <CourseGap>[CourseGap(0.5, 0.02)],
      );
      expect(tightestMargin(pinhole, prover: prover), lessThan(0));
    });
  });

  group('fairness gate', () {
    // ------------------------------------------------------------------------
    // THE GATE. A reduced form of Part 4 in `tool/prove_fairness.dart`.
    //
    // 400 windows of 3 consecutive obstacles from the shipped gap pattern,
    // covering indices 0..401, plus one continuous 150-obstacle run that carries
    // the reachable set across the whole stretch without resetting it. Runs in
    // roughly two seconds. The full 10,000-course sweep stays a tool command:
    //   dart run tool\prove_fairness.dart
    // ------------------------------------------------------------------------
    const int courses = 400;
    const int window = 3;

    test('every 3-obstacle window of the shipped pattern is survivable', () {
      final List<int> failing = <int>[];
      for (int s = 0; s < courses; s++) {
        if (!prover.prove(Course.fromDefaultPattern(s, window)).survivable) {
          failing.add(s);
        }
      }
      expect(failing, isEmpty,
          reason: 'unsurvivable windows of the default gap pattern: $failing '
              '— report this rather than retuning the constants');
    });

    test('a continuous 150-obstacle run of the shipped pattern is survivable',
        () {
      // Stronger than the windows: the reachable set is never reset, so this
      // says a perfect player who starts a real game is still alive at obstacle
      // 150 — not merely that each stretch is clearable from a fresh start.
      final ProofResult r = prover.prove(Course.fromDefaultPattern(0, 150));
      expect(r.survivable, isTrue,
          reason: 'died at frame ${r.deathFrame} on obstacle '
              '${r.deathObstacleIndex} (${r.cause?.name})');
      expect(r.obstaclesCleared, 150);
    });

    test('the shipped pattern keeps a real margin, not a hairline one', () {
      // Survivable is the bar. This is the follow-up question: how much room
      // does the best possible path have? A course that is survivable by 1e-4
      // is technically fair and unplayable.
      double worst = double.infinity;
      for (int s = 0; s < 60; s++) {
        final double m =
            tightestMargin(Course.fromDefaultPattern(s, window), prover: prover);
        if (m < worst) worst = m;
      }
      expect(worst, greaterThan(GameModel.carHeight),
          reason: 'the tightest margin over the first 60 windows is $worst, '
              'less than one car-height');
    });
  });
}
