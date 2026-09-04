/// The replay command: records real runs, encodes them, breaks them on purpose,
/// and prints what happened.
///
///     dart run tool\replay_report.dart
///     dart run tool\replay_report.dart --seed=4242
///     dart run tool\replay_report.dart --date=2026-09-04
///
/// WHY THIS EXISTS AS A COMMAND AND NOT ONLY AS TESTS: the tests assert that
/// these properties hold. This prints the NUMBERS — how long a code actually is,
/// what a flipped character actually does, what the verifier actually says — so
/// they can be read, quoted and argued with rather than taken on the word of a
/// green suite.
///
/// It exits non-zero if anything it demonstrates fails to hold, so it is also a
/// gate and not only a report.
library;

import 'dart:io';

import 'package:flappymiata/game/course_seed.dart';
import 'package:flappymiata/game/game_model.dart';
import 'package:flappymiata/game/replay.dart';
import 'package:flappymiata/game/run_code.dart';
import 'package:flappymiata/game/verified_score.dart';

import 'headless_sim.dart';

int _failures = 0;

/// The eight courses the report is built on. Seed 0 is the shipped course.
const List<int> reportSeeds = <int>[0, 1, 2, 7, 99, 4242, 65535, 0xFFFFFFFF];

void main(List<String> args) {
  final Map<String, String> opts = _parseArgs(args);

  _banner('WHAT A RECORDING IS');
  stdout.writeln('  a run  =  one 32-bit course seed');
  stdout.writeln('         +  the frames the player tapped on');
  stdout.writeln('         +  how many frames it lasted');
  stdout.writeln('');
  stdout.writeln('  timestep       $replayFrameSeconds s  '
      '(${(1 / replayFrameSeconds).round()} fps, fixed)');
  stdout.writeln('  frame cap      $maxReplayFrames frames  '
      '(${(maxReplayFrames * replayFrameSeconds / 60).round()} minutes)');
  stdout.writeln('  seed range     0 .. $maxCourseSeed');
  stdout.writeln('  seed 0         is the shipped course, bit for bit');
  stdout.writeln('');
  stdout.writeln('  WHY THE SEED AND NOT JUST THE TAPS: the taps are half a');
  stdout.writeln('  run. The other half is where the gaps are, and that is');
  stdout.writeln('  injected — the same taps on two courses are two runs.');

  _part1Replay();
  _part2Codes(opts);
  _part3Verification();
  _part4Daily(opts);

  stdout.writeln('');
  if (_failures == 0) {
    stdout.writeln('ALL DEMONSTRATIONS HELD.');
  } else {
    stdout.writeln('$_failures DEMONSTRATION(S) FAILED.');
  }
  exit(_failures == 0 ? 0 : 1);
}

// =============================================================================
// PART 1 — frame-exact replay
// =============================================================================

void _part1Replay() {
  _banner('PART 1 — a recorded run replays frame for frame');
  stdout.writeln('  Not "same score". Same MODEL every frame: position,');
  stdout.writeln('  velocity, score, and every obstacle\'s x and scored flag.');
  stdout.writeln('  A score is one integer that only counts up, so two runs');
  stdout.writeln('  that diverged and re-converged would agree on it.');
  stdout.writeln('');
  stdout.writeln('  seed        frames   taps  score  outcome        frames '
      'compared');

  int totalFrames = 0;
  for (final int seed in reportSeeds) {
    final Replay r = _recordChase(seed);
    final List<GameModel> a = replayTrace(r);
    final List<GameModel> b = replayTrace(r);

    int mismatch = -1;
    for (int f = 0; f < a.length && mismatch < 0; f++) {
      if (a[f] != b[f]) mismatch = f;
    }
    if (mismatch >= 0) {
      _fail('seed $seed diverged at frame $mismatch');
    }
    if (a.length != r.frames + 1) {
      _fail('seed $seed produced ${a.length} frames for a ${r.frames}-frame '
          'run');
    }
    totalFrames += a.length;

    final GameModel end = a.last;
    stdout.writeln('  ${_pad(seed.toString(), 11)}'
        '${_pad(r.frames.toString(), 9)}'
        '${_pad(r.tapFrames.length.toString(), 7)}'
        '${_pad(end.score.toString(), 7)}'
        '${_pad(_outcome(end), 15)}${a.length}');
  }
  stdout.writeln('');
  stdout.writeln('  ${reportSeeds.length} runs, $totalFrames frames compared '
      'one by one, no divergence.');

  // The cross-check that matters most: the same taps through a completely
  // separate driver. If these ever disagreed, every fairness witness in the
  // repo would be describing a different game.
  int agreed = 0;
  for (final int seed in reportSeeds) {
    final Replay r = _recordChase(seed);
    final List<bool> bools = List<bool>.filled(r.frames, false);
    for (final int t in r.tapFrames) {
      bools[t] = true;
    }
    final SimResult sim = replay(
      bools,
      start: GameModel.ready(gapCentreFor: gapPatternForSeed(seed)),
    );
    if (sim.finalModel == replayFinalModel(r)) {
      agreed++;
    } else {
      _fail('seed $seed: the replay driver and tool/headless_sim.dart '
          'disagree');
    }
  }
  stdout.writeln('  $agreed/${reportSeeds.length} agree with '
      'tool/headless_sim.dart, which is where the');
  stdout.writeln('  tap-before-physics convention was first written down.');
}

// =============================================================================
// PART 2 — run codes
// =============================================================================

void _part2Codes(Map<String, String> opts) {
  _banner('PART 2 — how long a run code is');
  stdout.writeln('  Alphabet: $runCodeAlphabet');
  stdout.writeln('  (Crockford Base32 — no I, L, O or U, so nothing is');
  stdout.writeln('  confusable at a glance, nothing needs a shift key, and');
  stdout.writeln('  no code can spell anything unfortunate.)');
  stdout.writeln('');
  stdout.writeln('  seed        30 s: frames taps chars   full run: frames '
      'taps score chars');

  for (final int seed in reportSeeds) {
    final Replay full = _recordChase(seed);
    final int cut = full.frames < 1800 ? full.frames : 1800;
    final Replay short = Replay(
      seed: full.seed,
      tapFrames: full.tapFrames.where((int t) => t < cut).toList(),
      frames: cut,
    );
    final String shortCode = encodeRunCode(short);
    final String fullCode = encodeRunCode(full);
    if (decodeRunCode(shortCode).replay != short ||
        decodeRunCode(fullCode).replay != full) {
      _fail('seed $seed did not round-trip');
    }
    stdout.writeln('  ${_pad(seed.toString(), 11)}'
        '${_pad(short.frames.toString(), 8)}'
        '${_pad(short.tapFrames.length.toString(), 5)}'
        '${_pad(shortCode.length.toString(), 9)}'
        '${_pad(full.frames.toString(), 8)}'
        '${_pad(full.tapFrames.length.toString(), 5)}'
        '${_pad(replayFinalModel(full).score.toString(), 6)}'
        '${fullCode.length}');
  }
  stdout.writeln('');
  stdout.writeln('  The floor is one byte per tap plus four bytes of header');
  stdout.writeln('  and four of checksum, at eight bits per five characters —');
  stdout.writeln('  so the length tracks how much the player tapped and not');
  stdout.writeln('  how long they survived.');

  final int demoSeed = int.parse(opts['seed'] ?? '0');
  final Replay demo = _recordChase(demoSeed);
  final String code = encodeRunCode(demo);
  stdout.writeln('');
  stdout.writeln('  a real code (seed $demoSeed, ${code.length} characters):');
  for (int i = 0; i < code.length; i += 64) {
    stdout.writeln(
      '    ${code.substring(i, i + 64 > code.length ? code.length : i + 64)}',
    );
  }

  stdout.writeln('');
  stdout.writeln('  WHAT A FLIPPED CHARACTER DOES');
  stdout.writeln('  Every single-character substitution in that code, every');
  stdout.writeln('  position, every one of the other 31 characters:');
  final Map<String, int> kinds = <String, int>{};
  int decoded = 0;
  int tried = 0;
  for (int i = 0; i < code.length; i++) {
    for (int v = 0; v < runCodeAlphabet.length; v++) {
      final String ch = runCodeAlphabet[v];
      if (ch == code[i]) continue;
      final String bad = code.substring(0, i) + ch + code.substring(i + 1);
      final RunCodeDecoding d = decodeRunCode(bad);
      tried++;
      if (d.ok) {
        decoded++;
      } else {
        kinds[d.error!.name] = (kinds[d.error!.name] ?? 0) + 1;
      }
    }
  }
  stbullet('$tried corruptions tried');
  stbullet('$decoded decoded into a different run  '
      '${decoded == 0 ? "(none — which is the point)" : "** THIS IS BAD **"}');
  kinds.forEach((String name, int n) {
    stbullet('$n rejected as $name');
  });
  if (decoded != 0) {
    _fail('$decoded single-character corruptions decoded into a valid run');
  }

  // One concrete example, spelled out, because a table of counts is not the
  // same as seeing it happen.
  final String flipped =
      '${code.substring(0, 6)}${code[6] == 'Z' ? 'Y' : 'Z'}${code.substring(7)}';
  final RunCodeDecoding one = decodeRunCode(flipped);
  stdout.writeln('');
  stdout.writeln('  one of them, in full:');
  stbullet('character 7 changed from ${code[6]} to ${flipped[6]}');
  stbullet('verdict: ${one.error!.name}');
  stbullet(one.detail);
  stdout.writeln('  Without the checksum that code would have decoded — every');
  stdout.writeln('  byte string is a plausible run — and the verifier would');
  stdout.writeln('  have called an honest player a liar.');
}

// =============================================================================
// PART 3 — verified scores
// =============================================================================

void _part3Verification() {
  _banner('PART 3 — three ways to cheat, and what happens to each');

  final Replay honest = _recordChase(0);
  final int honestScore = replayFinalModel(honest).score;
  final String honestCode = encodeRunCode(honest);
  final Replay other = _recordChase(4242);
  final int otherScore = replayFinalModel(other).score;
  final String otherCode = encodeRunCode(other);

  stdout.writeln('  the honest run:  seed 0, ${honest.frames} frames, '
      '${honest.tapFrames.length} taps, score $honestScore');
  stdout.writeln('  somebody else\'s: seed 4242, ${other.frames} frames, '
      '${other.tapFrames.length} taps, score $otherScore');
  stdout.writeln('');

  _claim('the honest code, honest score', honestCode, honestScore, true);

  // (a) tampered timeline: delete one tap from the middle. Everything after the
  // edit was flown against a car that is now somewhere else.
  final int victim = honest.tapFrames.length ~/ 2;
  final Replay tampered = Replay(
    seed: honest.seed,
    tapFrames: List<int>.of(honest.tapFrames)..removeAt(victim),
    frames: honest.frames,
  );
  stdout.writeln('');
  stdout.writeln('  (a) TAMPERED TIMELINE — tap #$victim of '
      '${honest.tapFrames.length} deleted');
  stbullet('the edited code is perfectly well formed: '
      '${decodeRunCode(encodeRunCode(tampered)).ok ? "it decodes" : "IT DOES NOT DECODE"}');
  stbullet('its checksum is correct — a checksum cannot catch this');
  stbullet('it really scores ${replayFinalModel(tampered).score}');
  _claim('  the tampered code, claiming $honestScore', encodeRunCode(tampered),
      honestScore, false);
  _claim('  the tampered code, claiming what it really scores',
      encodeRunCode(tampered), replayFinalModel(tampered).score, true);
  stdout.writeln('      (accepted, and that is correct: it is a real run that');
  stdout.writeln('      really scores that. The verifier detects false claims,');
  stdout.writeln('      not edits — a player who improves is not a cheat.)');

  // (b) truthful timeline, inflated claim.
  stdout.writeln('');
  stdout.writeln('  (b) INFLATED CLAIM — the real code, a bigger number');
  _claim('  claiming ${honestScore + 1}', honestCode, honestScore + 1, false);
  _claim('  claiming 999999', honestCode, 999999, false);

  // (c) valid code, swapped content.
  stdout.writeln('');
  stdout.writeln('  (c) SWAPPED CONTENT — somebody else\'s real code');
  stbullet('nothing is corrupted: '
      '${decodeRunCode(otherCode).ok ? "it decodes cleanly" : "IT DOES NOT DECODE"}');
  stbullet('its checksum is intact — again, a checksum cannot catch this');
  _claim('  their code, claiming YOUR score of $honestScore', otherCode,
      honestScore, false);
  _claim('  their code, claiming their own score of $otherScore', otherCode,
      otherScore, true);

  stdout.writeln('');
  stdout.writeln('  (a) and (c) are the two a signature, an obfuscated payload');
  stdout.writeln('  or a stronger checksum would all miss, because in both the');
  stdout.writeln('  code is a genuine, well-formed run. Only RE-EXECUTION');
  stdout.writeln('  separates "this is a run" from "this is the run you say".');
  stdout.writeln('');
  stdout.writeln('  WHAT THIS DOES NOT STOP: a bot. A program that plays');
  stdout.writeln('  perfectly produces a real run with a real score and this');
  stdout.writeln('  will certify it, correctly. What is gained is that every');
  stdout.writeln('  score on the board is a run somebody can watch.');
}

// =============================================================================
// PART 4 — daily challenge
// =============================================================================

void _part4Daily(Map<String, String> opts) {
  _banner('PART 4 — the daily challenge');

  final String iso = opts['date'] ??
      DateTime.now().toIso8601String().substring(0, 10);
  final List<String> parts = iso.split('-');
  final int year = int.parse(parts[0]);
  final int month = int.parse(parts[1]);
  final int day = int.parse(parts[2]);

  stdout.writeln('  date                   $iso');
  stdout.writeln('  days since 1970-01-01  ${daysFromCivil(year, month, day)}');
  stdout.writeln('  seed                   ${dailySeed(year, month, day)}');
  stdout.writeln('  first four gaps        ${<String>[
    for (int i = 0; i < 4; i++)
      seededGapCentre(dailySeed(year, month, day), i).toStringAsFixed(4),
  ].join('  ')}');
  stdout.writeln('');
  stdout.writeln('  THE DATE IS PASSED IN, NEVER READ INSIDE lib/game/.');
  stdout.writeln('  dailySeed takes three integers and has no idea which of');
  stdout.writeln('  them is today. A clock inside the rules would be a hidden');
  stdout.writeln('  input — a function whose answer changed at midnight — and');
  stdout.writeln('  the structural guard in test/game_model_test.dart would');
  stdout.writeln('  fail on the spot. lib/main.dart reads the calendar; it is');
  stdout.writeln('  a renderer and already knows about wall-clock time.');
  stdout.writeln('');

  // Two neighbours, to show the courses really move.
  final DateTime today = DateTime.utc(year, month, day);
  final DateTime tomorrow = today.add(const Duration(days: 1));
  final int seedToday = dailySeed(year, month, day);
  final int seedTomorrow =
      dailySeed(tomorrow.year, tomorrow.month, tomorrow.day);
  stdout.writeln('  ${today.toIso8601String().substring(0, 10)}  seed '
      '${_pad(seedToday.toString(), 12)}gap 0 at '
      '${seededGapCentre(seedToday, 0).toStringAsFixed(4)}');
  stdout.writeln('  ${tomorrow.toIso8601String().substring(0, 10)}  seed '
      '${_pad(seedTomorrow.toString(), 12)}gap 0 at '
      '${seededGapCentre(seedTomorrow, 0).toStringAsFixed(4)}');
  if (seedToday == seedTomorrow) {
    _fail('two consecutive dates share a seed');
  }

  // Distinctness over a long range, which is the property that makes it daily.
  const int span = 3653; // ten years
  final Set<int> seeds = <int>{};
  final DateTime first = DateTime.utc(2024, 1, 1);
  for (int n = 0; n < span; n++) {
    final DateTime d = first.add(Duration(days: n));
    seeds.add(dailySeed(d.year, d.month, d.day));
  }
  stdout.writeln('');
  stdout.writeln('  over ${first.toIso8601String().substring(0, 10)} .. '
      '${first.add(const Duration(days: span - 1)).toIso8601String().substring(0, 10)} '
      '($span dates):');
  stbullet('${seeds.length} distinct seeds');
  if (seeds.length != span) {
    _fail('${span - seeds.length} date(s) collide');
  }
  stdout.writeln('');
  stdout.writeln('  Fairness of these courses is NOT checked here. It is');
  stdout.writeln('  checked by the same prover as the shipped course, in');
  stdout.writeln('  PART 5 of tool/prove_fairness.dart and in');
  stdout.writeln('  test/daily_challenge_test.dart. One prover, two');
  stdout.writeln('  generators, one standard of evidence.');
}

// =============================================================================
// Helpers
// =============================================================================

/// Records a run of the reference bot: tap whenever the car is below the centre
/// of the gap it is heading for.
///
/// A HEURISTIC, and nothing here concludes anything from how well it plays —
/// see `tool/fairness.dart` for why a policy can never answer a question about
/// what is possible. Its only job is to produce runs that look like play.
Replay _recordChase(int seed) {
  final ReplayRecorder recorder = ReplayRecorder(seed: seed);
  while (!recorder.finished && recorder.frame < 3000) {
    final GameModel m = recorder.model;
    bool tap;
    if (m.state == RunState.ready) {
      tap = true;
    } else {
      final double carRight = GameModel.carX + GameModel.carWidth / 2;
      double target = 0.5;
      for (final Obstacle o in m.obstacles) {
        if (o.right > carRight - GameModel.carWidth) {
          target = o.gapCentre;
          break;
        }
      }
      tap = m.y > target;
    }
    if (tap) recorder.tap();
    if (!recorder.step()) break;
  }
  return recorder.replay;
}

void _claim(String label, String code, int claimed, bool expectAccepted) {
  final ScoreCheck check = verifyRunCode(code, claimed);
  final String mark = check.accepted ? 'ACCEPTED' : 'REJECTED';
  stdout.writeln('  ${_pad(label, 52)}$mark  ${_detail(check)}');
  if (check.accepted != expectAccepted) {
    _fail('$label: expected ${expectAccepted ? "ACCEPTED" : "REJECTED"}');
  }
}

String _detail(ScoreCheck check) {
  switch (check.verdict) {
    case ScoreVerdict.verified:
      return '';
    case ScoreVerdict.unreadableCode:
      return check.codeError!.name;
    case ScoreVerdict.scoreMismatch:
      return 'really scores ${check.actualScore}';
  }
}

String _outcome(GameModel m) {
  switch (m.state) {
    case RunState.ready:
      return 'never started';
    case RunState.playing:
      return 'still alive';
    case RunState.dead:
      return m.y == GameModel.minY || m.y == GameModel.maxY
          ? 'left playfield'
          : 'hit a pipe';
  }
}

String _pad(String s, int width) =>
    s.length >= width ? '$s ' : s.padRight(width);

void stbullet(String line) => stdout.writeln('    - $line');

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
