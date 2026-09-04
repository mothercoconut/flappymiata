/// The persistence boundary: what gets written down, and what is believed when
/// it is read back.
///
/// WHY THE INTERESTING HALF OF THIS FILE NEEDS NO PLATFORM: `BestRunRecord` is a
/// pure function each way — a record in, a string out, a string in, a verified
/// record out — and the store implementations are four-line shims around it.
/// Testing the shim would test `shared_preferences`; testing the record tests
/// the decision the app actually makes, which is whether to believe a number it
/// found on disk.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:flappymiata/game/replay.dart';
import 'package:flappymiata/game/run_code.dart';
import 'package:flappymiata/ui/high_score_store.dart';

import '../tool/fairness.dart';

/// A real run on [seed] that really gets past [obstacles] pipes.
///
/// WHY THE FAIRNESS PROVER PROVIDES THE FIXTURE RATHER THAN A BOT: this file's
/// assertions are all of the form "a record that scores N is believed and a
/// record that claims N + 1 is not", and a fixture that scored zero would make
/// every one of them pass for the wrong reason. The stock heuristic policies in
/// `tool/headless_sim.dart` are explicitly not good enough to be relied on — the
/// comment on `chaseGap` says so — whereas the prover returns a witness it has
/// PROVED clears the course. So the fixture's score is not a hope.
Replay playARun({int seed = 0, int obstacles = 3}) {
  final ProofResult proof = FairnessProver()
      .prove(Course.fromSeed(seed, 0, obstacles), witness: true);
  if (!proof.survivable) {
    throw StateError('no witness for seed $seed; the fixture cannot be built');
  }
  final List<bool> inputs = proof.witness!;
  return Replay(
    seed: seed,
    tapFrames: <int>[
      for (int i = 0; i < inputs.length; i++)
        if (inputs[i]) i,
    ],
    frames: inputs.length,
  );
}

void main() {
  final Replay run = playARun();
  final int trueScore = replayFinalModel(run).score;
  final String code = encodeRunCode(run);

  group('the fixture is worth testing against', () {
    test('the run really scores something', () {
      // If this fixture scored zero, "the stored score is believed" and "the
      // stored score is rejected" would be the same assertion.
      expect(trueScore, greaterThan(0),
          reason: 'the fixture run never got past a pipe');
      expect(code, isNotEmpty);
    });
  });

  group('BestRunRecord — a claim is checked, not believed', () {
    test('an honest record survives a round trip', () {
      final BestRun best = BestRun(score: trueScore, code: code);
      final BestRun? back = BestRunRecord.decode(BestRunRecord.encode(best));

      expect(back, isNotNull);
      expect(back, best);
      expect(back!.score, trueScore);
      expect(back.replay, run,
          reason: 'the decoded record must be the same run, not merely a run');
    });

    test('an inflated score is rejected', () {
      // THE ATTACK THIS EXISTS FOR: a preferences file is a text file. Editing
      // the number is the easiest cheat there is, and no amount of hiding the
      // number stops it. Re-executing the run does.
      final String tampered =
          BestRunRecord.encode(BestRun(score: trueScore + 1, code: code));
      expect(BestRunRecord.decode(tampered), isNull);

      // And in the other direction: a claim that is too LOW is a mismatch too.
      // Not because understating a score is an attack, but because a record that
      // disagrees with its own run is a record nothing should be built on.
      final String understated =
          BestRunRecord.encode(BestRun(score: trueScore - 1, code: code));
      expect(BestRunRecord.decode(understated), isNull);
    });

    test('a record from an older set of rules is dropped rather than kept', () {
      // This is not hypothetical: the difficulty ramp changed what a given
      // sequence of taps scores, so every run recorded before it now
      // re-executes to a different number. Simulated here by claiming the score
      // those same taps used to produce.
      //
      // The behaviour that matters is that the app self-heals — an unreachable
      // number does not sit on the start screen for ever — and it falls out of
      // verification rather than needing a version check of its own.
      final String stale =
          BestRunRecord.encode(BestRun(score: trueScore + 12, code: code));
      expect(BestRunRecord.decode(stale), isNull);
    });

    test('every way a record can be broken comes back null', () {
      expect(BestRunRecord.decode(null), isNull, reason: 'nothing stored');
      expect(BestRunRecord.decode(''), isNull, reason: 'empty');
      expect(BestRunRecord.decode('7'), isNull, reason: 'no separator');
      expect(BestRunRecord.decode(':$code'), isNull, reason: 'no score');
      expect(BestRunRecord.decode('$trueScore:'), isNull, reason: 'no code');
      expect(BestRunRecord.decode('seven:$code'), isNull, reason: 'score is not a number');
      expect(BestRunRecord.decode('-1:$code'), isNull, reason: 'negative score');
      expect(BestRunRecord.decode('$trueScore:NOTAREALCODE'), isNull,
          reason: 'the code does not decode');
      expect(BestRunRecord.decode('$trueScore${BestRunRecord.separator}'
          '${code.substring(0, code.length - 1)}'), isNull,
          reason: 'the code is truncated, so the checksum fails');
    });

    test('the key is versioned, so an old record is never half-read', () {
      expect(BestRunRecord.storageKey, endsWith('.v1'));
    });

    test('two records differing in one field are not equal', () {
      // `==` on a value type gets mutated to `return true`; without this,
      // "the decoded record must be the same run" above would be vacuous.
      final BestRun a = BestRun(score: trueScore, code: code);
      expect(a, BestRun(score: trueScore, code: code));
      expect(a, isNot(BestRun(score: trueScore + 1, code: code)));
      expect(a, isNot(BestRun(score: trueScore, code: '${code}X')));
      expect(a, isNot('not a best run'));
      expect(a.toString(), contains('$trueScore'));
    });

    test('a record carries its own course, so nothing else has to store it', () {
      // The seed lives inside the run code. That is what lets the game decide
      // whether the stored run is a ghost worth racing on today's course
      // without a second key on disk to get out of step with this one.
      final Replay other = playARun(seed: 4242);
      final BestRun best = BestRun(
        score: replayFinalModel(other).score,
        code: encodeRunCode(other),
      );
      final BestRun? back = BestRunRecord.decode(BestRunRecord.encode(best));
      expect(back, isNotNull);
      expect(back!.replay!.seed, 4242);
      expect(back.replay!.seed, isNot(run.seed));
    });
  });

  group('InMemoryHighScoreStore', () {
    test('an empty store has nothing', () async {
      expect(await InMemoryHighScoreStore().load(), isNull);
    });

    test('what is saved is what is loaded', () async {
      final InMemoryHighScoreStore store = InMemoryHighScoreStore();
      final BestRun best = BestRun(score: trueScore, code: code);
      await store.save(best);
      expect(await store.load(), best);
      expect(store.current, best);
    });

    test('a seeded store stands in for "the app has been played before"',
        () async {
      final BestRun best = BestRun(score: trueScore, code: code);
      final InMemoryHighScoreStore store = InMemoryHighScoreStore(best);
      expect(await store.load(), best);
    });
  });

  group('lib/game stays clear of storage', () {
    test('nothing under lib/game imports the persistence package', () {
      // `test/game_model_test.dart` already bans Flutter and Flame in that
      // directory by reading the sources. This is the same guard aimed at the
      // dependency this feature added: the model must not learn that a disk
      // exists, or it stops being a pure function of its inputs and every
      // replay, verified score and fairness proof rests on it being one.
      //
      // Asserted here rather than added to that file's list because this is a
      // fact about THIS feature, and the person who deletes the feature should
      // find the test next to it.
      const List<String> banned = <String>[
        'shared_preferences',
        'dart:io',
        'dart:async',
        'package:flappymiata/ui/',
      ];

      final Directory dir = Directory('lib/game');
      expect(dir.existsSync(), isTrue,
          reason: 'run from the package root, so lib/game is visible');
      final List<File> sources = dir
          .listSync(recursive: true)
          .whereType<File>()
          .where((FileSystemEntity f) => f.path.endsWith('.dart'))
          .toList();
      // If the glob matched nothing every assertion below is vacuously true.
      expect(sources, isNotEmpty, reason: 'found no Dart sources in lib/game');

      for (final File file in sources) {
        // Comments are prose and may legitimately name the thing being banned —
        // this feature's own files say "no I/O in here" in so many words. The
        // ban is on code.
        final String text = _stripLineComments(file.readAsStringSync());
        for (final String needle in banned) {
          expect(text.contains(needle), isFalse,
              reason: '${file.path} contains "$needle"');
        }
      }
    });
  });
}

/// Strips `//` line comments so the ban above applies to code and not to prose.
///
/// Naive on purpose, and the same shape as the one in `game_model_test.dart`:
/// it would also cut a `//` inside a string literal, and there is none in
/// `lib/game/`. A real parser here would be more machinery than the rule is
/// worth.
String _stripLineComments(String source) => source
    .split('\n')
    .map((String line) {
      final int i = line.indexOf('//');
      return i == -1 ? line : line.substring(0, i);
    })
    .join('\n');
