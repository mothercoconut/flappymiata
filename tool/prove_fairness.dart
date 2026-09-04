/// The fairness command.
///
///     dart run tool\prove_fairness.dart              # full report
///     dart run tool\prove_fairness.dart --quick      # small run, seconds
///     dart run tool\prove_fairness.dart --courses=1000 --window=3
///     dart run tool\prove_fairness.dart --dates=0    # skip the daily sweep
///
/// It does three things, in this order and deliberately in this order:
///
///   PART 3  proves the prover can say NO, by handing it courses that are
///           impossible for three different reasons and one that is trivial.
///           A prover that always answers "fair" would pass a survivability
///           sweep while being worth nothing, so this runs FIRST and the
///           command exits non-zero if any of it comes out wrong.
///   PART 4  runs the prover over the shipped game's own course.
///   PART 5  runs the SAME prover over every daily-challenge course in a
///           two-year range. Same searches, same epsilon, same course factory —
///           a second generator held to the first one's standard of evidence
///           rather than to a new one written for the occasion.
///   PART 6  aims all of it at the DIFFICULTY RAMP: the ramp's shape, a proof
///           at and beyond the setting it plateaus at, and the ramps that were
///           measured and rejected.
///
/// WHY PART 6 EXISTS AND IS NOT JUST MORE OF PART 4: before the ramp, every
/// window of the shipped pattern was played at the same speed with the same gap,
/// so "sweep 10,000 windows" covered the whole game. It no longer does. A sweep
/// that starts at obstacle 0, 1, 2, ... is a sweep of the EASY START, ten
/// thousand times over, and it would go green over a plateau that is unwinnable.
/// The obstacle the ramp stops at is the number to point a prover at, and Part 6
/// is where that happens.
///
/// Exit code 0 means every expectation held.
library;

import 'dart:io';

import 'package:flappymiata/game/course_seed.dart';
import 'package:flappymiata/game/game_model.dart';

import 'fairness.dart';
import 'headless_sim.dart';

int _failures = 0;

void main(List<String> args) {
  final Map<String, String> opts = _parseArgs(args);
  final bool quick = opts.containsKey('quick');
  final int courses = int.parse(opts['courses'] ?? (quick ? '200' : '10000'));
  final int window = int.parse(opts['window'] ?? '3');
  final int continuous =
      int.parse(opts['continuous'] ?? (quick ? '200' : '10000'));
  final int sample = int.parse(opts['sample'] ?? '200');
  // 731 days from 2024-01-01 is two whole calendar years, 2024 and 2025, so
  // every month length and one 29 February are covered. A leap year on purpose:
  // the day-number arithmetic is the one place a calendar bug could hide.
  final int dates = int.parse(opts['dates'] ?? (quick ? '60' : '731'));

  final FairnessProver prover = FairnessProver();
  final Stopwatch total = Stopwatch()..start();

  _banner('CONSTANTS THE PROOF RESTS ON');
  stdout.writeln('  dt                 ${prover.dt} s  '
      '(${(1 / prover.dt).round()} fps)');
  stdout.writeln('  gravity            ${GameModel.gravity}');
  stdout.writeln('  flapImpulse        ${GameModel.flapImpulse}  (ASSIGNED, '
      'never added — this is what makes the state (y, framesSinceFlap))');
  stdout.writeln('  lattice cell       ${prover.cell.toStringAsExponential(4)}'
      '  = gravity * dt^2, the exact spacing of reachable positions');
  stdout.writeln('  |flapImpulse*dt|   '
      '${(GameModel.flapImpulse * prover.dt).abs().toStringAsExponential(4)}'
      '  = largest one-frame move; '
      '${((GameModel.flapImpulse * prover.dt).abs() / prover.cell).toStringAsFixed(1)}'
      'x coarser than the cell');
  stdout.writeln('  survival epsilon   '
      '${prover.epsilon.toStringAsExponential(0)}  (errs toward calling a fair '
      'course unfair — see tool/fairness.dart)');
  stdout.writeln('  carHeight          ${GameModel.carHeight}');
  stdout.writeln('  gapHeight          ${GameModel.gapHeight}  '
      '(at the START of a run; the ramp narrows it — see PART 6)');
  stdout.writeln('  static gap slack   '
      '${(GameModel.gapHeight - GameModel.carHeight).toStringAsFixed(4)}'
      '  (a lone obstacle can never be unfair; only transitions can)');

  _part3(prover);
  _part4Windows(prover, courses, window, sample);
  if (continuous > 0) _part4Continuous(prover, continuous);
  if (dates > 0) _part5Daily(prover, 2024, 1, 1, dates, window);
  _part6Ramp(prover, courses, window, continuous, dates);

  total.stop();
  stdout.writeln('');
  stdout.writeln('total reachability searches  ${prover.proveCalls}');
  stdout.writeln('total wall time              '
      '${(total.elapsedMilliseconds / 1000).toStringAsFixed(1)} s');
  if (_failures == 0) {
    stdout.writeln('ALL EXPECTATIONS HELD.');
  } else {
    stdout.writeln('$_failures EXPECTATION(S) FAILED.');
  }
  exit(_failures == 0 ? 0 : 1);
}

// =============================================================================
// PART 3 — prove the prover can fail
// =============================================================================

void _part3(FairnessProver prover) {
  _banner('PART 3 — can this prover ever say NO?');
  stdout.writeln(
    'A prover that always answers "fair" passes a survivability sweep while\n'
    'being worthless. Each course below is impossible for a DIFFERENT reason,\n'
    'and the prover has to name the mechanism, not just the verdict. The last\n'
    'course is trivially easy and has to come back survivable — with a witness\n'
    'that is then replayed through the real GameModel.\n',
  );

  const ReferenceProver reference = ReferenceProver();

  // --- 1. a gap far narrower than the car is tall ---------------------------
  final Course pinhole = Course(
    name: 'pinhole',
    gaps: const <CourseGap>[CourseGap(0.5, 0.02)],
  );
  _expect(
    prover,
    reference,
    pinhole,
    'one gap 0.020 tall, centred; the car is '
        '${GameModel.carHeight} tall',
    expectSurvivable: false,
    expectCause: FailureCause.gapNarrowerThanCar,
  );

  // --- 2. two extremes with too little room between them --------------------
  //
  // Spacing 0.36 is chosen precisely. It is larger than carWidth +
  // obstacleWidth (0.3242), so the two obstacles are never over the car at the
  // same moment — that would be a geometric failure, and the point of this
  // course is a KINEMATIC one. It is small enough that only about five frames
  // of free air separate the two gaps, which is nowhere near enough to cross
  // the playfield.
  final Course zigzag = Course(
    name: 'zigzag',
    gaps: <CourseGap>[
      CourseGap(GameModel.minGapCentre, GameModel.gapHeight),
      CourseGap(GameModel.maxGapCentre, GameModel.gapHeight),
    ],
    spacing: 0.36,
  );
  _expect(
    prover,
    reference,
    zigzag,
    'gaps at ${GameModel.minGapCentre.toStringAsFixed(2)} then '
        '${GameModel.maxGapCentre.toStringAsFixed(2)}, only 0.36 apart; each '
        'gap is flyable on its own',
    expectSurvivable: false,
    expectCause: FailureCause.unreachable,
  );

  // --- 3. a gap that can only be threaded from outside the playfield --------
  final Course ceilingGap = Course(
    name: 'above-the-ceiling',
    gaps: const <CourseGap>[CourseGap(-0.20, GameModel.gapHeight)],
  );
  _expect(
    prover,
    reference,
    ceilingGap,
    'a full-size gap centred at y = -0.20, i.e. entirely above the playfield',
    expectSurvivable: false,
    expectCause: FailureCause.gapOutsidePlayfield,
  );

  // --- 4. two gaps over the car at once, with nothing in common -------------
  final Course clash = Course(
    name: 'overlap-clash',
    gaps: <CourseGap>[
      CourseGap(GameModel.minGapCentre, GameModel.gapHeight),
      CourseGap(GameModel.maxGapCentre, GameModel.gapHeight),
    ],
    spacing: 0.20,
  );
  _expect(
    prover,
    reference,
    clash,
    'the same two extremes 0.20 apart — closer than carWidth + obstacleWidth '
        '(${(GameModel.carWidth + GameModel.obstacleWidth).toStringAsFixed(4)}), '
        'so both straddle the car at once',
    expectSurvivable: false,
    expectCause: FailureCause.overlappingGapsDisjoint,
  );

  // --- 5. the positive control ---------------------------------------------
  final Course easy = Course(
    name: 'wide-open',
    gaps: const <CourseGap>[CourseGap(0.5, GameModel.gapHeight)],
    playableByGame: true,
  );
  _expect(
    prover,
    reference,
    easy,
    'one full-size gap dead centre — the easiest course that exists',
    expectSurvivable: true,
  );

  // --- 6. the flip point, checked against physics computed WITHOUT the prover
  //
  // A single centred obstacle is not survivable merely because the car fits
  // through the gap. The obstacle straddles the car for a run of consecutive
  // frames, and gravity does not stop during them: the car has to STAY inside
  // the gap for the whole window, and the flattest trajectory that exists still
  // moves. So the true threshold is
  //
  //     gapHeight  >=  carHeight + (smallest excursion over that many frames)
  //
  // and the right-hand side can be computed by enumerating flap patterns
  // directly — no reachable set, no lattice, no bitmaps, nothing the prover
  // touches. That makes it a genuine outside check on the prover's answer.
  stdout.writeln('');
  stdout.writeln('  --- where does the answer flip, and does the physics agree? ---');
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
  final int overlap = obstacleOverlapFrames();
  final ExcursionBound bound = minimumExcursion(overlap);
  final double predicted = GameModel.carHeight + bound.excursion;

  stdout.writeln('  prover: survivable above    ${hi.toStringAsFixed(6)}');
  stdout.writeln('  prover: unsurvivable below  ${lo.toStringAsFixed(6)}');
  stdout.writeln('  one obstacle straddles the car for $overlap frames');
  stdout.writeln('  flattest $overlap-frame trajectory spans '
      '${bound.excursion.toStringAsFixed(6)}  '
      '(entering with framesSinceFlap = ${bound.startCounter}, '
      'flapping on frame(s) ${bound.flapFrames})');
  stdout.writeln('  so the threshold must be   '
      '${predicted.toStringAsFixed(6)}  = carHeight + that excursion');
  final double flipError = (hi - predicted).abs();
  stdout.writeln('  |prover - physics|          '
      '${flipError.toStringAsExponential(3)}   '
      '(one lattice cell is ${prover.cell.toStringAsExponential(3)})');
  if (flipError > 2 * prover.cell) {
    _fail('the flip point disagrees with the independently computed threshold '
        'by more than two lattice cells');
  } else {
    stdout.writeln('  OK — the prover flips where the physics says it must, '
        'and NOT at carHeight (${GameModel.carHeight}), which is where a '
        'prover that only checked whether the car fits would flip.');
  }

  // --- 7. both sides of that boundary --------------------------------------
  //
  // The flip has to be sharp in both directions, or "unsurvivable" could just be
  // the prover's default answer for anything narrow.
  final Course tooTight = Course(
    name: 'hairline-too-tight',
    gaps: <CourseGap>[CourseGap(0.5, predicted - 3 * prover.cell)],
  );
  final Course justEnough = Course(
    name: 'hairline-just-enough',
    gaps: <CourseGap>[CourseGap(0.5, predicted + 3 * prover.cell)],
  );
  final bool tight = prover.prove(tooTight).survivable;
  final bool loose = prover.prove(justEnough).survivable;
  stdout.writeln('');
  stdout.writeln('  threshold - 3 cells  '
      '(${(predicted - 3 * prover.cell).toStringAsFixed(6)}): '
      '${tight ? "SURVIVABLE" : "UNSURVIVABLE"}  (expected UNSURVIVABLE)');
  stdout.writeln('  threshold + 3 cells  '
      '(${(predicted + 3 * prover.cell).toStringAsFixed(6)}): '
      '${loose ? "SURVIVABLE" : "UNSURVIVABLE"}  (expected SURVIVABLE)');
  if (tight) _fail('a gap below the physical threshold came back survivable');
  if (!loose) _fail('a gap above the physical threshold came back unsurvivable');
}

/// Runs both provers over [course], prints the verdict and the mechanism, and
/// records a failure if anything is not as expected.
void _expect(
  FairnessProver prover,
  ReferenceProver reference,
  Course course,
  String description, {
  required bool expectSurvivable,
  FailureCause? expectCause,
}) {
  final ProofResult r = prover.prove(course, witness: expectSurvivable);
  stdout.writeln('');
  stdout.writeln('  ${course.name}');
  stdout.writeln('    $description');
  stdout.writeln('    verdict   '
      '${r.survivable ? "SURVIVABLE" : "UNSURVIVABLE"}'
      '   (expected ${expectSurvivable ? "SURVIVABLE" : "UNSURVIVABLE"})');
  if (!r.survivable) {
    stdout.writeln('    mechanism ${r.cause?.name}'
        '   (expected ${expectCause?.name})');
    stdout.writeln('    died at   frame ${r.deathFrame}, '
        'working on obstacle ${r.deathObstacleIndex}');
  } else {
    stdout.writeln('    cleared   ${r.obstaclesCleared} obstacle(s) in '
        '${r.frames} frames, peak ${r.peakStates} reachable states');
  }

  if (r.survivable != expectSurvivable) {
    _fail('${course.name}: wrong verdict');
  }
  if (expectCause != null && r.cause != expectCause) {
    _fail('${course.name}: wrong mechanism');
  }

  // The slow, obvious implementation has to agree. A disagreement means one of
  // the two is wrong and neither verdict can be trusted.
  final bool? ref = reference.survives(course);
  stdout.writeln('    cross-check (naive hash-set search): '
      '${ref == null ? "gave up (state cap)" : ref ? "SURVIVABLE" : "UNSURVIVABLE"}');
  if (ref != null && ref != r.survivable) {
    _fail('${course.name}: the two prover implementations disagree');
  }

  // A survivable verdict is only worth as much as the input sequence it hands
  // back. Replay it through the shipped GameModel.
  if (r.survivable && r.witness != null && course.playableByGame) {
    final SimResult sim = replay(
      r.witness!,
      start: GameModel.ready(gapCentreFor: course.asGapPattern),
    );
    stdout.writeln('    witness   ${r.witness!.length} frames, '
        '${r.witness!.where((bool b) => b).length} taps -> replayed through '
        'the real GameModel: ${sim.outcome.name}, score ${sim.score}');
    if (!sim.alive || sim.score < course.gaps.length) {
      _fail('${course.name}: the witness did not survive the real GameModel');
    }
  }
}

// =============================================================================
// PART 4 — the shipped game's own course
// =============================================================================

void _part4Windows(
  FairnessProver prover,
  int courseCount,
  int window,
  int sampleSize,
) {
  _banner('PART 4a — $courseCount courses of $window obstacles from the real '
      'default gap pattern');
  stdout.writeln('WHAT A "COURSE" IS HERE, AND WHY:');
  stdout.writeln('  GameModel.defaultGapCentre is a pure function of the '
      'obstacle index, so the');
  stdout.writeln('  shipped game has exactly ONE course and it is infinite. '
      '"10,000 courses" is');
  stdout.writeln('  therefore realised as 10,000 overlapping windows of it: '
      'course s is the');
  stdout.writeln('  stretch beginning at obstacle s, played from the real '
      'start state');
  stdout.writeln('  (y = ${GameModel.startY}, first tap on frame 0). '
      's = 0..${courseCount - 1} covers every');
  stdout.writeln('  consecutive run of $window gaps in indices '
      '0..${courseCount + window - 2}.');
  stdout.writeln('  That is where unfairness could live. A lone obstacle '
      'leaves a constant');
  stdout.writeln('  ${(GameModel.gapHeight - GameModel.carHeight).toStringAsFixed(3)} '
      'of vertical slack and cannot be unfair by itself, so only the');
  stdout.writeln('  transitions between gaps can be — and a window of $window '
      'contains them.');
  stdout.writeln('');
  stdout.writeln('  EACH WINDOW IS PROVED AT ITS OWN DEPTH ON THE RAMP: window '
      's uses the speed,');
  stdout.writeln('  spacing and gap height the game gives obstacle s, not the '
      'ones it gives');
  stdout.writeln('  obstacle 0. But s = 0..${courseCount - 1} is still mostly '
      'the easy start of the');
  stdout.writeln('  game repeated, so this sweep is NOT a proof about the '
      'plateau. PART 6 is.');
  stdout.writeln('');

  final Stopwatch clock = Stopwatch()..start();
  final int callsBefore = prover.proveCalls;

  final List<int> failing = <int>[];
  double worstMargin = double.infinity;
  int worstIndex = -1;
  int incumbentBeaten = 0;

  for (int s = 0; s < courseCount; s++) {
    final Course course = Course.fromDefaultPattern(s, window);

    // Beat-the-incumbent: a course that clears the whole run with the current
    // worst-known margin still to spare cannot BE the worst, so one pass settles
    // it. Only a course that fails at the incumbent margin is worth bisecting.
    // That keeps the sweep at roughly one reachability search per course while
    // still finding the exact worst case.
    final bool clearsIncumbent =
        worstIndex >= 0 && prover.prove(course, inflate: worstMargin).survivable;
    if (clearsIncumbent) continue;

    if (!prover.prove(course, inflate: 0.0).survivable) {
      failing.add(s);
      continue;
    }
    final double m = tightestMargin(
      course,
      prover: prover,
      upper: worstIndex < 0 ? 0.2 : worstMargin,
    );
    if (m < worstMargin) {
      worstMargin = m;
      worstIndex = s;
      incumbentBeaten++;
    }
  }

  clock.stop();
  final int passes = prover.proveCalls - callsBefore;

  stdout.writeln('  courses checked        $courseCount');
  stdout.writeln('  obstacles per course   $window');
  stdout.writeln('  PASS (survivable)      ${courseCount - failing.length}');
  stdout.writeln('  FAIL (unsurvivable)    ${failing.length}');
  if (failing.isNotEmpty) {
    stdout.writeln('  failing course indices ${failing.take(20).toList()}'
        '${failing.length > 20 ? " ..." : ""}');
    _fail('${failing.length} course(s) of the shipped pattern are '
        'unsurvivable — reporting, not retuning: the constants are the '
        'owner\'s call');
  }
  if (worstIndex >= 0) {
    final String centres = Course.fromDefaultPattern(worstIndex, window)
        .gaps
        .map((CourseGap g) => g.centre.toStringAsFixed(3))
        .join(', ');
    stdout.writeln('  worst course           #$worstIndex  (gaps at $centres)');
    stdout.writeln('  its tightest margin    '
        '${worstMargin.toStringAsFixed(5)} playfield-heights '
        '(${(worstMargin / GameModel.carHeight).toStringAsFixed(2)} '
        'car-heights of room for the best possible path)');
  }
  stdout.writeln('  incumbent beaten       $incumbentBeaten time(s)');
  stdout.writeln('  reachability passes    $passes');
  stdout.writeln('  wall time              '
      '${(clock.elapsedMilliseconds / 1000).toStringAsFixed(1)} s');

  // A margin sample, so the worst case can be read against a distribution
  // rather than in isolation.
  final int n = sampleSize < courseCount ? sampleSize : courseCount;
  if (n > 0) {
    final List<double> margins = <double>[];
    for (int s = 0; s < n; s++) {
      margins.add(tightestMargin(Course.fromDefaultPattern(s, window),
          prover: prover));
    }
    margins.sort();
    stdout.writeln('');
    stdout.writeln('  margin distribution over the first $n courses:');
    stdout.writeln('    min    ${margins.first.toStringAsFixed(5)}');
    stdout.writeln('    p10    ${margins[(n * 0.10).floor()].toStringAsFixed(5)}');
    stdout.writeln('    median ${margins[n ~/ 2].toStringAsFixed(5)}');
    stdout.writeln('    max    ${margins.last.toStringAsFixed(5)}');
  }
}

void _part4Continuous(FairnessProver prover, int obstacles) {
  _banner('PART 4b — one continuous run of $obstacles obstacles');
  stdout.writeln(
    'Stronger than 4a and not a substitute for it. Here the reachable set is\n'
    'carried across the WHOLE pattern without ever being reset, so a pass means\n'
    'a perfect player who starts a real game can still be alive at obstacle\n'
    '$obstacles — not merely that each stretch is clearable from a fresh start.\n'
    '\n'
    'THIS IS ALSO THE ONLY PART THAT DESCRIBES THE RAMP END TO END. The run\n'
    'starts at obstacle 0 with the shipped tuning, climbs the ramp, and spends\n'
    'the remaining ${obstacles - Difficulty.plateauObstacle} obstacles at the '
    'plateau — one search, one game, no\n'
    'resets and no hand-off between difficulty settings.\n',
  );

  final Course course = Course.fromDefaultPattern(0, obstacles);
  final Stopwatch clock = Stopwatch()..start();
  final ProofResult r = prover.prove(course);
  clock.stop();

  stdout.writeln('  obstacles              $obstacles');
  stdout.writeln('  verdict                '
      '${r.survivable ? "SURVIVABLE" : "UNSURVIVABLE"}');
  stdout.writeln('  frames simulated       ${r.frames}');
  stdout.writeln('  obstacles cleared      ${r.obstaclesCleared}');
  stdout.writeln('  peak reachable states  ${r.peakStates}');
  stdout.writeln('  wall time              '
      '${(clock.elapsedMilliseconds / 1000).toStringAsFixed(1)} s');
  if (!r.survivable) {
    stdout.writeln('  died at                frame ${r.deathFrame}, '
        'obstacle ${r.deathObstacleIndex}, cause ${r.cause?.name}');
    _fail('the continuous run of the shipped pattern is unsurvivable');
    return;
  }

  // Where is the bottleneck? Squeeze the whole run until it breaks; the
  // obstacle it breaks at is the hardest moment in the pattern.
  final Stopwatch squeeze = Stopwatch()..start();
  double lo = 0.0;
  double hi = 0.2;
  int bottleneck = -1;
  for (int i = 0; i < 12; i++) {
    final double mid = (lo + hi) / 2;
    final ProofResult probe = prover.prove(course, inflate: mid);
    if (probe.survivable) {
      lo = mid;
    } else {
      hi = mid;
      bottleneck = probe.deathObstacleIndex ?? -1;
    }
  }
  squeeze.stop();
  stdout.writeln('  tightest margin        ${lo.toStringAsFixed(5)} '
      '(the whole run still clears with the car this much fatter on each side)');
  stdout.writeln('  bottleneck at          obstacle $bottleneck');
  if (bottleneck > 0 && bottleneck < obstacles) {
    // The gap either side of the bottleneck is what makes it hard: a transition,
    // never a single obstacle.
    final String around = <int>[bottleneck - 1, bottleneck]
        .map((int i) => 'obstacle $i gap at '
            '${course.gaps[i].centre.toStringAsFixed(3)}')
        .join(', then ');
    stdout.writeln('  the hard transition    $around');
  }
  stdout.writeln('  squeeze wall time      '
      '${(squeeze.elapsedMilliseconds / 1000).toStringAsFixed(1)} s');
}

// =============================================================================
// PART 5 — the daily challenge, held to the same bar
// =============================================================================

/// Proves every date in a range, using the SAME prover, the SAME course
/// factory and the SAME epsilon as the shipped pattern above.
///
/// WHY THE DAILY COURSES NEED THIS MORE THAN THE SHIPPED ONE DOES: the shipped
/// pattern is one course. It was proved once, and if a bad stretch had turned
/// up, somebody would have found it and the constants would have moved. A
/// date-seeded course is a course NOBODY CHOSE and nobody has played. An
/// unfair one does not get discovered in review — it arrives at midnight, for
/// everybody at once, and is unplayable for a day.
///
/// The sweep is over WINDOWS for the same reason Part 4's is: a lone obstacle
/// can never be unfair, so the interesting question is always a transition, and
/// a window of [window] consecutive gaps is the smallest thing that contains
/// one.
void _part5Daily(
  FairnessProver prover,
  int startYear,
  int startMonth,
  int startDay,
  int days,
  int window,
) {
  _banner('PART 5 — every daily challenge in a $days-day range');

  final DateTime first = DateTime.utc(startYear, startMonth, startDay);
  final DateTime last = first.add(Duration(days: days - 1));
  stdout.writeln('  range                  '
      '${first.toIso8601String().substring(0, 10)} .. '
      '${last.toIso8601String().substring(0, 10)}  ($days dates)');
  stdout.writeln('  obstacles per course   $window');
  stdout.writeln('  seed derivation        dailySeed(y, m, d) — a pure function '
      'of the date;');
  stdout.writeln('                         the calendar is read in '
      'lib/main.dart, never in lib/game/');
  stdout.writeln('');

  final Stopwatch sw = Stopwatch()..start();
  final List<String> failing = <String>[];
  final Set<int> seeds = <int>{};
  double worstMargin = double.infinity;
  String worstDate = '';

  for (int n = 0; n < days; n++) {
    final DateTime d = first.add(Duration(days: n));
    final int seed = dailySeed(d.year, d.month, d.day);
    seeds.add(seed);
    final ProofResult r = prover.prove(Course.fromSeed(seed, 0, window));
    if (!r.survivable) {
      failing.add('${d.toIso8601String().substring(0, 10)} (seed $seed, '
          '${r.cause?.name} at obstacle ${r.deathObstacleIndex})');
    }
    // Margins are a bisection and cost about fifteen searches each, so they are
    // measured on a sample rather than on every date.
    if (n % 25 == 0) {
      final double m =
          tightestMargin(Course.fromSeed(seed, 0, window), prover: prover);
      if (m < worstMargin) {
        worstMargin = m;
        worstDate = d.toIso8601String().substring(0, 10);
      }
    }
  }
  sw.stop();

  stdout.writeln('  dates checked          $days');
  stdout.writeln('  distinct seeds         ${seeds.length}');
  stdout.writeln('  PASS (survivable)      ${days - failing.length}');
  stdout.writeln('  FAIL (unsurvivable)    ${failing.length}');
  stdout.writeln('  tightest margin        '
      '${worstMargin.toStringAsFixed(5)} on $worstDate  '
      '(car height is ${GameModel.carHeight})');
  stdout.writeln('  wall time              '
      '${(sw.elapsedMilliseconds / 1000).toStringAsFixed(1)} s');

  if (seeds.length != days) {
    _fail('${days - seeds.length} date(s) share a seed with another date; the '
        'daily challenge is not daily');
  }
  if (failing.isNotEmpty) {
    _fail('unsurvivable daily courses: ${failing.take(10).join("; ")}');
  }
  if (worstMargin <= GameModel.carHeight) {
    _fail('the tightest daily margin is $worstMargin, under one car height');
  }
}

// =============================================================================
// PART 6 — the difficulty ramp
// =============================================================================

/// Proves the ramp, which means proving it AT ITS HARDEST and past there.
///
/// THE FAILURE THIS PART EXISTS TO PREVENT, stated plainly: a ramp is a promise
/// that the game gets harder, and a fairness proof is a promise that it stays
/// winnable. Those two promises pull against each other, and the place they
/// break is deep in a run — obstacle 300, obstacle 400 — where no playtest goes.
/// A ramp tuned by feel can therefore be unwinnable and feel excellent, because
/// the part anybody plays is the part that got better.
///
/// So the ramp is not tuned here, it is bounded here. The plateau is the one
/// hardest setting the game can ever reach; everything below points the existing
/// prover at it.
void _part6Ramp(
  FairnessProver prover,
  int courseCount,
  int window,
  int continuous,
  int dates,
) {
  _banner('PART 6 — the difficulty ramp, proved at and beyond its plateau');

  // ---- 6a: what the ramp is -------------------------------------------------
  stdout.writeln('THE RAMP');
  stdout.writeln('  driven by              obstacles passed — a pure function of '
      'progress, with');
  stdout.writeln('                         no clock and no randomness, so a '
      'recorded run replays');
  stdout.writeln('                         frame-exactly INCLUDING its '
      'difficulty');
  stdout.writeln('  warm-up                obstacles 0..${Difficulty.warmUpObstacles} '
      '(the shipped tuning, unchanged)');
  stdout.writeln('  ramps over             ${Difficulty.rampObstacles} obstacles');
  stdout.writeln('  PLATEAUS AT            obstacle ${Difficulty.plateauObstacle}'
      '  <- the hardest setting the game has');
  stdout.writeln('');
  stdout.writeln('  progress   scrollSpeed   gapHeight   spacing   '
      'gap in car-heights');
  for (final int p in <int>[
    0,
    Difficulty.warmUpObstacles,
    Difficulty.warmUpObstacles + Difficulty.rampObstacles ~/ 4,
    Difficulty.warmUpObstacles + Difficulty.rampObstacles ~/ 2,
    Difficulty.plateauObstacle - 1,
    Difficulty.plateauObstacle,
    Difficulty.plateauObstacle + 1,
    100000,
  ]) {
    final DifficultySettings s = Difficulty.settingsAt(p);
    stdout.writeln('  ${p.toString().padLeft(8)}   '
        '${s.scrollSpeed.toStringAsFixed(6).padLeft(11)}   '
        '${s.gapHeight.toStringAsFixed(6).padLeft(9)}   '
        '${s.obstacleSpacing.toStringAsFixed(4).padLeft(7)}   '
        '${(s.gapHeight / GameModel.carHeight).toStringAsFixed(2).padLeft(6)}');
  }

  // The plateau has to BE a plateau. Everything below is a proof about one
  // setting, and that is only worth anything if the game cannot get past it.
  final DifficultySettings top =
      Difficulty.settingsAt(Difficulty.plateauObstacle);
  if (Difficulty.settingsAt(Difficulty.plateauObstacle + 1) != top ||
      Difficulty.settingsAt(1 << 40) != top) {
    _fail('the ramp does not plateau — a proof at obstacle '
        '${Difficulty.plateauObstacle} says nothing about obstacle 10,000');
  }
  if (top.scrollSpeed != Difficulty.topScrollSpeed ||
      top.gapHeight != Difficulty.tightestGapHeight ||
      top.obstacleSpacing != Difficulty.tightestSpacing) {
    _fail('the settings at the plateau are not the plateau constants; the '
        'report above is describing a game that is not being proved');
  }

  // ---- 6b: what the plateau costs, in physics ------------------------------
  final int baseOverlap =
      obstacleOverlapFrames(scrollSpeed: GameModel.scrollSpeed);
  final int topOverlap =
      obstacleOverlapFrames(scrollSpeed: Difficulty.topScrollSpeed);
  final double baseFloor =
      GameModel.carHeight + minimumExcursion(baseOverlap).excursion;
  final double topFloor =
      GameModel.carHeight + minimumExcursion(topOverlap).excursion;

  stdout.writeln('');
  stdout.writeln('WHAT THE PLATEAU CHANGES, in numbers computed without the '
      'prover');
  stdout.writeln('                            start     plateau');
  stdout.writeln('  approach time (s)         '
      '${((playfieldRight - GameModel.carX) / GameModel.scrollSpeed).toStringAsFixed(3)}     '
      '${((playfieldRight - GameModel.carX) / Difficulty.topScrollSpeed).toStringAsFixed(3)}');
  stdout.writeln('  obstacle cadence (s)      '
      '${(GameModel.obstacleSpacing / GameModel.scrollSpeed).toStringAsFixed(3)}     '
      '${(Difficulty.tightestSpacing / Difficulty.topScrollSpeed).toStringAsFixed(3)}');
  stdout.writeln('  free air between pipes    '
      '${((GameModel.obstacleSpacing - GameModel.carWidth - GameModel.obstacleWidth) / GameModel.scrollSpeed).toStringAsFixed(3)}     '
      '${((Difficulty.tightestSpacing - GameModel.carWidth - GameModel.obstacleWidth) / Difficulty.topScrollSpeed).toStringAsFixed(3)}'
      '   <- what a worst-case climb is paid out of');
  stdout.writeln('  overlap window (frames)   '
      '${baseOverlap.toString().padLeft(5)}     ${topOverlap.toString().padLeft(5)}'
      '   <- shorter, so a lone gap gets EASIER');
  stdout.writeln('  lone-obstacle floor       '
      '${baseFloor.toStringAsFixed(3)}     ${topFloor.toStringAsFixed(3)}'
      '   <- a single gap below this is impossible');
  stdout.writeln('  gap height                '
      '${GameModel.gapHeight.toStringAsFixed(3)}     '
      '${Difficulty.tightestGapHeight.toStringAsFixed(3)}');
  if (Difficulty.tightestGapHeight <= topFloor) {
    _fail('the plateau gap (${Difficulty.tightestGapHeight}) is at or below the '
        'lone-obstacle floor ($topFloor): every obstacle past the plateau is '
        'impossible on its own');
  } else {
    stdout.writeln('  OK — the plateau gap clears its own floor by '
        '${(Difficulty.tightestGapHeight - topFloor).toStringAsFixed(4)}, so no '
        'single obstacle is impossible.');
    stdout.writeln('       That is necessary and NOT sufficient: what follows '
        'is about transitions.');
  }

  // ---- 6c: the sweep at and beyond the plateau -----------------------------
  //
  // Two blocks, and the second is not "harder" than the first — the ramp has
  // stopped, so both are the identical setting. It is a second sample of the gap
  // pattern at that setting, which is what stops the first block passing by
  // luck about which gaps happen to sit around obstacle 50.
  final int perBlock = courseCount ~/ 2 < 1 ? 1 : courseCount ~/ 2;
  for (final int from in <int>[
    Difficulty.plateauObstacle,
    Difficulty.plateauObstacle + 5000,
  ]) {
    final Stopwatch clock = Stopwatch()..start();
    final List<int> failing = <int>[];
    double worst = double.infinity;
    int worstAt = -1;
    for (int s = from; s < from + perBlock; s++) {
      final Course c = Course.fromDefaultPattern(s, window);
      // Same beat-the-incumbent shortcut Part 4a uses: a course that clears at
      // the current worst margin cannot be the new worst, so one search settles
      // it and only a real candidate is bisected.
      if (worstAt >= 0 && prover.prove(c, inflate: worst).survivable) continue;
      if (!prover.prove(c).survivable) {
        failing.add(s);
        continue;
      }
      final double m = tightestMargin(c,
          prover: prover, upper: worstAt < 0 ? 0.2 : worst);
      if (m < worst) {
        worst = m;
        worstAt = s;
      }
    }
    clock.stop();

    stdout.writeln('');
    stdout.writeln('  $perBlock windows of $window obstacles from obstacle '
        '$from  (ramp fraction '
        '${Difficulty.rampFraction(from).toStringAsFixed(1)})');
    stdout.writeln('    PASS (survivable)    ${perBlock - failing.length}');
    stdout.writeln('    FAIL (unsurvivable)  ${failing.length}'
        '${failing.isEmpty ? "" : "  ${failing.take(10).toList()}"}');
    if (worstAt >= 0) {
      stdout.writeln('    worst margin         ${worst.toStringAsFixed(5)}  '
          '(${(worst / GameModel.carHeight).toStringAsFixed(2)} car-heights) '
          'at obstacle $worstAt');
    }
    stdout.writeln('    wall time            '
        '${(clock.elapsedMilliseconds / 1000).toStringAsFixed(1)} s');

    if (failing.isNotEmpty) {
      _fail('${failing.length} window(s) at the plateau (from obstacle $from) '
          'are unsurvivable — the ramp has been pushed past what the game can '
          'honour');
    }
    // The same bar the daily challenge is already held to. Survivable by a
    // hairline is technically fair and unplayable, and a ramp is exactly the
    // feature that would produce one.
    if (worstAt >= 0 && worst <= GameModel.carHeight) {
      _fail('the tightest margin at the plateau is $worst, under one car '
          'height (${GameModel.carHeight})');
    }
  }

  // ---- 6d: a continuous run that goes THROUGH the ramp ----------------------
  //
  // Part 4b already does this for `continuous` obstacles and is the strongest
  // statement in the whole report. Repeated here only as a short, explicit
  // "the plateau is reachable by playing", because 4b's headline is about the
  // gap pattern rather than about the ramp.
  final int reach = Difficulty.plateauObstacle + 100;
  final ProofResult through = prover.prove(Course.fromDefaultPattern(0, reach));
  stdout.writeln('');
  stdout.writeln('  one run from the start line to obstacle $reach '
      '(warm-up, ramp, then 100 of plateau)');
  stdout.writeln('    verdict              '
      '${through.survivable ? "SURVIVABLE" : "UNSURVIVABLE"}');
  stdout.writeln('    obstacles cleared    ${through.obstaclesCleared}');
  if (!through.survivable) {
    stdout.writeln('    died at              frame ${through.deathFrame}, '
        'obstacle ${through.deathObstacleIndex}, ${through.cause?.name}');
    _fail('a run that climbs the ramp cannot reach the plateau');
  }

  // ---- 6e: the ramps that were rejected ------------------------------------
  //
  // The falsification half, and the reason Part 3 runs before Part 4: a proof
  // that the shipped ramp is fair is worth nothing unless the same machinery
  // would have refused an unfair one. These three are real candidates that were
  // measured during design, and every one of them looks perfectly reasonable
  // written down.
  stdout.writeln('');
  stdout.writeln('  RAMPS THAT WERE MEASURED AND REJECTED');
  stdout.writeln('  Each is a plateau somebody could plausibly have shipped — '
      '"a third faster and');
  stdout.writeln('  a quarter tighter" is not an outrageous thing to write. '
      'Each is held fixed at');
  stdout.writeln('  that setting and windows of the shipped gap pattern are '
      'swept from obstacle 0');
  stdout.writeln('  until one is refused. The index printed is the first '
      'obstacle at which that');
  stdout.writeln('  ramp hands a player a course NOTHING can get past — and '
      'note how deep some');
  stdout.writeln('  of them are. That depth is the whole reason this is '
      'measured and not felt.');

  const List<List<double>> rejected = <List<double>>[
    <double>[0.60, 0.21, 0.60],
    <double>[0.5625, 0.22, 0.60],
    <double>[0.54, 0.23, 0.54],
  ];
  const int rejectScan = 2500;
  for (final List<double> candidate in rejected) {
    final double speed = candidate[0];
    final double gap = candidate[1];
    final double spacing = candidate[2];
    final CourseDifficulty held =
        FixedDifficulty(scrollSpeed: speed, spacing: spacing);

    int firstBad = -1;
    FailureCause? cause;
    for (int s = 0; s < rejectScan && firstBad < 0; s++) {
      final Course c = Course(
        name: 'rejected[$s]',
        gaps: List<CourseGap>.generate(
          window,
          (int k) => CourseGap(
            GameModel.clampGapCentre(GameModel.defaultGapCentre(s + k)),
            gap,
          ),
        ),
        difficulty: held,
        firstIndex: s,
      );
      final ProofResult r = prover.prove(c);
      if (!r.survivable) {
        firstBad = s;
        cause = r.cause;
      }
    }

    stdout.writeln('    speed $speed  gap $gap  spacing $spacing   '
        '${firstBad < 0 ? "no wall found in $rejectScan windows" : "WALL at "
            "obstacle $firstBad (${cause?.name})"}');
    if (firstBad < 0) {
      _fail('a plateau rejected during design produced no unsurvivable window '
          'in $rejectScan tries; either the prover or the design note is wrong, '
          'and neither can be trusted until that is settled');
    }
  }
  stdout.writeln('    shipped: speed ${Difficulty.topScrollSpeed}  '
      'gap ${Difficulty.tightestGapHeight}  '
      'spacing ${Difficulty.tightestSpacing}   '
      '- no wall, proved above');

  // ---- 6f: the daily challenge, at the plateau ------------------------------
  //
  // Part 5 sweeps every date at obstacle 0, which is now the easy start. A daily
  // course nobody chose has to be fair at the HARD end too, and it is a
  // different set of gaps for every date, so it gets its own pass.
  if (dates > 0) {
    final int deepDates = dates < 120 ? dates : 120;
    final DateTime first = DateTime.utc(2024, 1, 1);
    final List<String> failing = <String>[];
    double worst = double.infinity;
    String worstDate = '';
    for (int n = 0; n < deepDates; n++) {
      final DateTime d = first.add(Duration(days: n));
      final int seed = dailySeed(d.year, d.month, d.day);
      final Course c =
          Course.fromSeed(seed, Difficulty.plateauObstacle, window);
      if (!prover.prove(c).survivable) {
        failing.add(d.toIso8601String().substring(0, 10));
      } else if (n % 10 == 0) {
        final double m = tightestMargin(c, prover: prover);
        if (m < worst) {
          worst = m;
          worstDate = d.toIso8601String().substring(0, 10);
        }
      }
    }
    stdout.writeln('');
    stdout.writeln('  $deepDates daily courses, each read from obstacle '
        '${Difficulty.plateauObstacle} (i.e. at the plateau)');
    stdout.writeln('    PASS (survivable)    ${deepDates - failing.length}');
    stdout.writeln('    FAIL (unsurvivable)  ${failing.length}'
        '${failing.isEmpty ? "" : "  ${failing.take(10).toList()}"}');
    stdout.writeln('    tightest margin      ${worst.toStringAsFixed(5)} on '
        '$worstDate  (${(worst / GameModel.carHeight).toStringAsFixed(2)} '
        'car-heights)');
    if (failing.isNotEmpty) {
      _fail('unsurvivable daily courses at the plateau: '
          '${failing.take(10).join(", ")}');
    }
    if (worst <= GameModel.carHeight) {
      _fail('the tightest daily margin at the plateau is $worst, under one car '
          'height');
    }
  }
}

// =============================================================================

void _banner(String title) {
  stdout.writeln('');
  stdout.writeln('=' * 78);
  stdout.writeln(title);
  stdout.writeln('=' * 78);
}

void _fail(String message) {
  _failures++;
  stdout.writeln('  ** FAILED: $message');
}

Map<String, String> _parseArgs(List<String> args) {
  final Map<String, String> out = <String, String>{};
  for (final String a in args) {
    if (!a.startsWith('--')) continue;
    final int eq = a.indexOf('=');
    if (eq < 0) {
      out[a.substring(2)] = 'true';
    } else {
      out[a.substring(2, eq)] = a.substring(eq + 1);
    }
  }
  return out;
}
