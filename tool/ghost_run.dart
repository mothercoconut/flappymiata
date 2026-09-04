/// Produces a recorded run worth racing, so the ghost can actually be LOOKED AT.
///
///     dart run tool\ghost_run.dart
///     dart run tool\ghost_run.dart --seed=0 --score=20
///     dart run tool\ghost_run.dart --code-only
///
/// ============================================================================
/// THE PROBLEM. IT IS NOT A TESTING PROBLEM — IT IS THAT NOBODY HAD EVER SEEN IT
/// ============================================================================
///
/// `lib/main.dart` draws the best run on this course beside the live one. To
/// see that on a device you must already HAVE a best run on today's course, and
/// the only way to get one is to finish a run. That leaves a gap nothing in the
/// repository could close:
///
///   * `tool/solver_bot.dart` plays properly but never dies, so it never
///     finishes a run and never leaves a recording behind;
///   * a weak driver dies in about two seconds, and the ghost it leaves spends
///     its whole life falling off the bottom of the screen before the first
///     pipe arrives — a ghost that is technically present and shows nothing;
///   * the widget tests can see the ghost's POSITION and could never see its
///     appearance at all.
///
/// So the ghost's rendering had never been in front of a human eye, and the
/// defect that was eventually reported — "it makes it really hard to see what's
/// you and what's the ghost" — was reported by a player, because a player was
/// the only instrument in the system capable of noticing it.
///
/// This closes that gap. It plays a full run with the solver bot, stops it at a
/// score worth watching, lets it die like a real one, and prints the run code.
/// `--dart-define=BEST_RUN=<code>` then opens the app with that run already
/// filed as the best, on the course it was played on.
///
/// ============================================================================
/// WHAT THIS PROVES, AND WHAT IT DOES NOT
/// ============================================================================
///
/// It proves the run it prints is real: the code round-trips, and re-executing
/// it produces the score printed beside it — the same check
/// `lib/ui/high_score_store.dart` makes of anything it loads. So a ghost drawn
/// from this is a ghost of a run somebody could have played.
///
/// It proves NOTHING about how the ghost looks. It cannot: it is a headless
/// script with no renderer in it. What it does is make the appearance
/// observable by a person in one command instead of unreachable — which is a
/// different and more honest claim than "checked".
///
/// Pure Dart with no Flutter, like every other script in this directory, so it
/// runs under a bare `dart run`.
library;

import 'dart:io';

import 'package:flappymiata/game/course_seed.dart';
import 'package:flappymiata/game/game_model.dart';
import 'package:flappymiata/game/replay.dart';
import 'package:flappymiata/game/run_code.dart';

import 'headless_sim.dart';
import 'solver_bot.dart';

/// How far the recorded run gets before the bot stops driving.
///
/// Twelve obstacles is about twenty-five seconds of play: long enough that the
/// difficulty ramp has visibly moved — the gaps are tighter and the world is
/// faster by the end of it — and long enough that somebody watching the ghost
/// has time to form an opinion about it. A three-obstacle run is over before a
/// viewer has finished looking at the screen.
const int defaultTargetScore = 12;

/// The hard ceiling on a recording made here, in frames.
///
/// The bot is not proved to survive forever — a backward pass looks a bounded
/// distance ahead, so it can be steered into a corner beyond its own horizon —
/// but neither is it proved to DIE, and a script that can loop until the heat
/// death of the universe is a script nobody should run unattended. Two minutes
/// of play is about five times the longest recording this is meant to make.
const int recordingFrameCap = 7200;

/// Plays [seed] with the solver bot until it has scored [targetScore], then
/// stops driving and lets the run end.
///
/// ============================================================================
/// WHY IT STOPS RATHER THAN RUNNING TO A FIXED LENGTH
/// ============================================================================
///
/// A ghost is a RECORDING, and a recording that was cut off mid-flight would
/// put a car on the track that simply stops existing at a frame number nobody
/// chose. Letting the bot stop tapping means the car falls, hits something and
/// dies — which is how every run a player ever records ends, and is what makes
/// the recording look like a run rather than like a clip.
///
/// SHARED WITH THE TEST rather than copied into it. `test/ghost_render_test.dart`
/// needs a run that really flies over pipes for several seconds, and building
/// its own would be a second definition of "a run worth racing" free to drift
/// from the one this tool prints. The fixture the test renders is the artefact
/// this command produces.
Replay recordSolverRun({
  int seed = 0,
  int targetScore = defaultTargetScore,
  int frameCap = recordingFrameCap,
}) {
  final ReplayRecorder recorder =
      ReplayRecorder(seed: seed, frameCap: frameCap);
  final Policy drive = solverPolicy();

  // Phase one: drive. The tap is decided immediately above the step it applies
  // to, which is the same `flap-then-tick` frame `lib/main.dart` hands the
  // autopilot and `tool/headless_sim.dart` hands every policy. Deciding
  // anywhere else would be deciding about a different frame, and the recording
  // would describe a game nothing else plays.
  while (!recorder.finished && recorder.model.score < targetScore) {
    if (drive(recorder.model, recorder.frame)) {
      recorder.tap();
    }
    recorder.step();
  }

  // Phase two: hands off. No taps, so gravity finishes the run.
  while (!recorder.finished) {
    recorder.step();
  }

  return recorder.replay;
}

void main(List<String> args) {
  final bool codeOnly = args.contains('--code-only');
  final int seed = _intArg(args, '--seed') ?? _todaysSeed();
  final int targetScore = _intArg(args, '--score') ?? defaultTargetScore;

  final Replay run = recordSolverRun(seed: seed, targetScore: targetScore);
  final GameModel finished = replayFinalModel(run);
  final String code = encodeRunCode(run);

  // THE INSTRUMENT, CHECKED BEFORE ITS OUTPUT IS BELIEVED. A code that does not
  // decode back to the run that made it would be a code that seeds a different
  // ghost, or none — and it would be printed in exactly the same words as a
  // good one. Both halves are checked: that it reads back as the same value,
  // and that re-executing it scores what is being claimed.
  final Replay? roundTrip = decodeRunCode(code).replay;
  if (roundTrip != run) {
    stderr.writeln('ABORT: the run code does not decode back to the run that '
        'produced it. $code');
    exitCode = 1;
    return;
  }
  if (replayFinalModel(roundTrip!).score != finished.score) {
    stderr.writeln('ABORT: the decoded run scores '
        '${replayFinalModel(roundTrip).score}, not ${finished.score}.');
    exitCode = 1;
    return;
  }

  if (codeOnly) {
    stdout.writeln(code);
    return;
  }

  stdout.writeln('A RECORDED RUN, FOR WATCHING THE GHOST');
  stdout.writeln('-' * 72);
  stdout.writeln('  course seed      $seed'
      '${seed == _todaysSeed() ? "  (today's)" : ''}');
  stdout.writeln('  score            ${finished.score}'
      '  (asked for $targetScore)');
  stdout.writeln('  risk             ${finished.riskScore}');
  stdout.writeln('  frames           ${run.frames}'
      '  (${run.seconds.toStringAsFixed(1)}s)');
  stdout.writeln('  taps             ${run.tapFrames.length}');
  stdout.writeln('  ended            ${finished.state.name}');
  stdout.writeln('  code             ${code.length} characters');
  stdout.writeln('');
  stdout.writeln(code);
  stdout.writeln('');
  stdout.writeln('Open the app with this run already filed as the best, so the');
  stdout.writeln('ghost is on the track from the first frame of the first run:');
  stdout.writeln('');
  stdout.writeln('  flutter run --dart-define=BEST_RUN=$code');
  stdout.writeln('');
  stdout.writeln('The seed travels inside the code, so the course is set for');
  stdout.writeln('you — see kSeededBestRun in lib/main.dart. The record goes');
  stdout.writeln('into memory only and never reaches the device store.');

  if (finished.state != RunState.dead) {
    // Not an abort. A recording that ran out of frames is still a usable ghost;
    // it is just not a run that ENDED, and the difference is worth saying out
    // loud rather than leaving somebody to wonder why the ghost keeps flying
    // after the frame it stops moving on.
    stdout.writeln('');
    stdout.writeln('NOTE: the bot hit the $recordingFrameCap-frame ceiling '
        'rather than dying, so this');
    stdout.writeln('recording stops mid-flight. Lower --score to get a run '
        'that ends.');
  }
}

/// Today's course, by the same local-calendar rule `lib/main.dart` uses.
///
/// Read here rather than in `lib/game/`, for the reason that directory's own
/// rule gives: a model that could look at a clock would stop being a function
/// of its arguments. `dailySeed` takes three plain integers and has no idea
/// which of them is today.
int _todaysSeed() {
  final DateTime now = DateTime.now();
  return dailySeed(now.year, now.month, now.day);
}

/// `--name=123`, or null when the flag is absent.
///
/// A flag that is PRESENT but unreadable is a hard stop rather than a silent
/// fall back to the default: somebody who typed `--seed=today` meant a
/// particular course, and quietly playing a different one would produce a
/// perfectly valid run code for the wrong game.
int? _intArg(List<String> args, String name) {
  final String prefix = '$name=';
  for (final String arg in args) {
    if (!arg.startsWith(prefix)) continue;
    final int? value = int.tryParse(arg.substring(prefix.length));
    if (value == null) {
      stderr.writeln('$name needs a whole number, not '
          '"${arg.substring(prefix.length)}"');
      exit(2);
    }
    return value;
  }
  return null;
}
