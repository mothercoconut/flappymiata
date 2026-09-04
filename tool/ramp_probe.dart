/// Measures one candidate plateau setting for the difficulty ramp.
///
///     dart run tool\ramp_probe.dart
///     dart run tool\ramp_probe.dart --speed=0.54 --gap=0.23 --spacing=0.60
///     dart run tool\ramp_probe.dart --courses=4000 --window=3
///
/// WHY THIS EXISTS SEPARATELY FROM `tool/prove_fairness.dart`: that tool proves
/// the ramp the game actually ships. This one answers the question that comes
/// BEFORE it — what should the plateau be? A plateau is three numbers, and the
/// only honest way to pick them is to hold the whole game at each candidate and
/// measure how much room the best possible path has left. Feel cannot answer it,
/// because the plateau is reached at obstacle 50 and nobody playtests there.
///
/// It uses the same prover, the same epsilon and the same margin bisection as
/// the gate. The only thing it changes is that the world is held at a FIXED
/// difficulty — [FixedDifficulty] — rather than ramped, so that a candidate is
/// measured in isolation instead of averaged with the easy warm-up in front of
/// it.
///
/// The margin it prints is in playfield-heights and is the amount the car could
/// be fattened, on every side, and still clear the worst window in the sweep.
/// One car-height is 0.031, and that is the bar `tool/prove_fairness.dart`
/// already holds the daily challenge to.
library;

import 'dart:io';

import 'package:flappymiata/game/game_model.dart';

import 'fairness.dart';

void main(List<String> args) {
  final Map<String, String> opts = _parseArgs(args);
  final double speed =
      double.parse(opts['speed'] ?? '${Difficulty.topScrollSpeed}');
  final double gap = double.parse(opts['gap'] ?? '${Difficulty.tightestGapHeight}');
  final double spacing =
      double.parse(opts['spacing'] ?? '${Difficulty.tightestSpacing}');
  final int courses = int.parse(opts['courses'] ?? '4000');
  final int window = int.parse(opts['window'] ?? '3');
  final int continuous = int.parse(opts['continuous'] ?? '2000');

  final FairnessProver prover = FairnessProver();
  final CourseDifficulty held =
      FixedDifficulty(scrollSpeed: speed, spacing: spacing);

  /// The stretch of the shipped pattern from obstacle [first], held at the
  /// candidate difficulty. Centres come from the real generator, so the gaps are
  /// in the real places; only the three ramped numbers are overridden.
  Course held3(int first, int count) => Course(
    name: 'held[$first]',
    gaps: List<CourseGap>.generate(
      count,
      (int k) => CourseGap(
        GameModel.clampGapCentre(GameModel.defaultGapCentre(first + k)),
        gap,
      ),
    ),
    difficulty: held,
    firstIndex: first,
  );

  final int overlap = obstacleOverlapFrames(scrollSpeed: speed);
  final double threshold =
      GameModel.carHeight + minimumExcursion(overlap).excursion;

  stdout.writeln('candidate plateau');
  stdout.writeln('  scrollSpeed            $speed  '
      '(${(speed / GameModel.scrollSpeed).toStringAsFixed(3)}x the base)');
  stdout.writeln('  gapHeight              $gap  '
      '(${(gap / GameModel.carHeight).toStringAsFixed(2)} car-heights)');
  stdout.writeln('  obstacleSpacing        $spacing');
  stdout.writeln('  approach time          '
      '${((playfieldRight - GameModel.carX) / speed).toStringAsFixed(3)} s  '
      '(base 1.556 s)');
  stdout.writeln('  obstacle cadence       '
      '${(spacing / speed).toStringAsFixed(3)} s  (base 1.333 s)');
  stdout.writeln('  free air between pipes '
      '${((spacing - GameModel.carWidth - GameModel.obstacleWidth) / speed).toStringAsFixed(3)} s'
      '  (base 0.613 s)');
  stdout.writeln('  overlap window         $overlap frames  (base 43)');
  stdout.writeln('  lone-obstacle floor    ${threshold.toStringAsFixed(5)}  '
      '(a single gap below this is unsurvivable on its own)');
  if (gap <= threshold) {
    stdout.writeln('  ** the candidate gap is at or below the floor: every '
        'obstacle is individually impossible');
  }

  // ---- the sweep, with the same beat-the-incumbent shortcut Part 4a uses ----
  final Stopwatch clock = Stopwatch()..start();
  final List<int> failing = <int>[];
  double worst = double.infinity;
  int worstAt = -1;
  for (int s = 0; s < courses; s++) {
    final Course c = held3(s, window);
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
  stdout.writeln('  windows swept          $courses of $window obstacles');
  stdout.writeln('  unsurvivable           ${failing.length}'
      '${failing.isEmpty ? "" : "  ${failing.take(10).toList()}"}');
  if (worstAt >= 0) {
    stdout.writeln('  worst margin           ${worst.toStringAsFixed(5)}  '
        '(${(worst / GameModel.carHeight).toStringAsFixed(2)} car-heights) '
        'at window #$worstAt');
  }
  stdout.writeln('  wall time              '
      '${(clock.elapsedMilliseconds / 1000).toStringAsFixed(1)} s');

  if (continuous > 0) {
    final Course run = held3(0, continuous);
    final ProofResult r = prover.prove(run);
    stdout.writeln('');
    stdout.writeln('  continuous $continuous     '
        '${r.survivable ? "SURVIVABLE" : "UNSURVIVABLE "
            "(obstacle ${r.deathObstacleIndex}, ${r.cause?.name})"}');
  }
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
