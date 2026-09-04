/// Headless runner: plays the real [GameModel] under a chosen policy and prints
/// what happened. No window, no canvas, no frame pump.
///
///     dart run tool\simulate.dart
///     dart run tool\simulate.dart --policy=chase --frames=3000
///
/// Pure Dart on purpose: this is the proof that the rules in `lib/game/` can be
/// exercised without booting Flutter at all.
library;

import 'dart:io';

import 'package:flappymiata/game/game_model.dart';

import 'headless_sim.dart';
import 'solver_bot.dart';

void main(List<String> args) {
  final Map<String, String> opts = _parseArgs(args);
  final int frames = int.parse(opts['frames'] ?? '3600');
  final String wanted = opts['policy'] ?? 'all';

  final Map<String, Policy> policies = <String, Policy>{
    'never': neverFlap,
    'drop': startThenDrop,
    'always': alwaysFlap,
    'hold': holdAltitude(0.5),
    'chase': chaseGap(),
    // The only one of these that can still play the ramped game. See
    // `tool/solver_bot.dart`: it is not a heuristic, it reads the surviving
    // states out of the assist solver and never leaves them.
    'solver': solverPolicy(),
  };

  stdout.writeln('Headless simulator — GameModel at ${(1 / frameSeconds).round()}fps');
  stdout.writeln('frame budget: $frames frames '
      '(${(frames * frameSeconds).toStringAsFixed(1)}s of game time)');
  stdout.writeln('');
  stdout.writeln('policy    outcome         score   risk  passed  frames  flaps  finalY');
  stdout.writeln('--------------------------------------------------------------------------');

  for (final MapEntry<String, Policy> entry in policies.entries) {
    if (wanted != 'all' && wanted != entry.key) continue;
    final SimResult r = runHeadless(policy: entry.value, maxFrames: frames);
    stdout.writeln(
      '${entry.key.padRight(10)}'
      '${r.outcome.name.padRight(16)}'
      '${r.score.toString().padLeft(5)}'
      '${r.finalModel.riskScore.toString().padLeft(7)}'
      '${r.obstaclesPassed.toString().padLeft(8)}'
      '${r.frames.toString().padLeft(8)}'
      '${r.flaps.toString().padLeft(7)}'
      '${r.finalModel.y.toStringAsFixed(4).padLeft(9)}',
    );
  }

  stdout.writeln('');
  stdout.writeln(
    'NOTE: none of these policies says anything about fairness. A policy that '
    'survives proves a course is clearable; a policy that dies proves nothing '
    'at all. See tool/prove_fairness.dart.',
  );
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
