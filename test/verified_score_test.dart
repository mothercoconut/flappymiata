/// PART 3 — verified scores. A leaderboard with no server.
///
/// The verifier makes exactly one move: it replays the run and looks at the
/// score the model produces. Everything below is a demonstration that this one
/// move is enough, stated as the three attacks somebody would actually try.
///
///   (a) TAMPERED TIMELINE   edit the taps so the run "goes further", re-encode
///                           with a correct checksum, claim the old score.
///   (b) INFLATED CLAIM      an honest, unedited code with a bigger number
///                           attached.
///   (c) SWAPPED CONTENT     somebody else's real code — checksum intact,
///                           nothing corrupted — under your own claim.
///
/// (a) and (c) are the two that a checksum, an obfuscated payload or a
/// signature would all fail to catch, because in both cases the code is a
/// perfectly well-formed run. Only re-execution separates "this is a run" from
/// "this is the run you say it is".
///
/// The fourth case tested here is the one that must NOT be rejected: an edited
/// timeline that genuinely scores higher verifies, because it is a real run
/// that really scores that. A verifier that refused it would be detecting
/// editing rather than detecting dishonesty, and would reject every player who
/// improved.
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:flappymiata/game/game_model.dart';
import 'package:flappymiata/game/replay.dart';
import 'package:flappymiata/game/run_code.dart';
import 'package:flappymiata/game/verified_score.dart';

import 'reference_bot.dart';

void main() {
  // Two genuine runs on two different courses, recorded by the reference bot.
  final Replay honest = recordRun(0, chaseNextGap);
  final Replay somebodyElse = recordRun(4242, chaseNextGap);
  final int honestScore = replayFinalModel(honest).score;
  final int otherScore = replayFinalModel(somebodyElse).score;
  final String honestCode = encodeRunCode(honest);
  final String otherCode = encodeRunCode(somebodyElse);

  group('the fixture is two real, different, scoring runs', () {
    test('both score, and they do not score the same', () {
      expect(honestScore, greaterThan(5));
      expect(otherScore, greaterThan(5));
      expect(honestScore, isNot(otherScore));
      expect(honest.seed, isNot(somebodyElse.seed));
    });
  });

  group('an honest claim is accepted', () {
    test('the real code with the real score verifies', () {
      final ScoreCheck check = verifyRunCode(honestCode, honestScore);
      expect(check.accepted, isTrue, reason: check.toString());
      expect(check.verdict, ScoreVerdict.verified);
      expect(check.actualScore, honestScore);
      expect(check.replay, honest);
      expect(check.codeError, isNull);
    });

    test('anybody can check it, because nothing about it is secret', () {
      // Same code, same answer, on a verifier that has never seen the recorder.
      // This is the whole point of determinism as an anti-cheat measure: the
      // check needs no key, no server and no trust in the sender.
      final RunCodeDecoding decoded = decodeRunCode(honestCode);
      expect(decoded.ok, isTrue);
      expect(replayFinalModel(decoded.replay!).score, honestScore);
    });
  });

  group('(a) a tampered timeline is rejected', () {
    test('deleting one tap from the middle destroys everything after it', () {
      // WHY THE MIDDLE AND NOT THE END: every tap after the edit was flown
      // against a car that is now somewhere else, so the run diverges from the
      // edit onward and the car dies early. Editing the END of a run changes
      // nothing that has already been scored — which is a real property of the
      // game, not a hole in the verifier, and is why the "no edit scores more"
      // test below exists rather than a hand-picked one.
      final int victim = honest.tapFrames.length ~/ 2;
      final List<int> edited = List<int>.of(honest.tapFrames)
        ..removeAt(victim);
      final Replay tampered = Replay(
        seed: honest.seed,
        tapFrames: edited,
        frames: honest.frames,
      );
      expect(
        replayFinalModel(tampered).score,
        lessThan(honestScore),
        reason: 'the edit has to actually change the run, or this proves '
            'nothing',
      );

      // The tampered code is a PERFECTLY VALID code. Nothing about its
      // integrity is wrong: it decodes, its checksum is correct, and it
      // round-trips. That is exactly why the checksum cannot be what catches
      // this.
      final String tamperedCode = encodeRunCode(tampered);
      final RunCodeDecoding decoded = decodeRunCode(tamperedCode);
      expect(decoded.ok, isTrue, reason: 'the forgery is a well-formed code');
      expect(decoded.replay, tampered);

      final ScoreCheck check = verifyRunCode(tamperedCode, honestScore);
      expect(check.accepted, isFalse);
      expect(check.verdict, ScoreVerdict.scoreMismatch);
      expect(check.actualScore, isNot(honestScore));
      expect(check.detail, isNotEmpty);
    });

    test('no single-tap edit of the run buys a better score, and every one of '
        'them is rejected when it claims one', () {
      // Exhaustive over the edits a cheat can actually reach by hand: delete
      // any one of the run's taps, and let the edited run fly ten seconds
      // longer than the original in case the deletion keeps the car alive.
      // Every one is checked, not a sample.
      int checked = 0;
      int stillTwelve = 0;
      for (int i = 0; i < honest.tapFrames.length; i++) {
        final List<int> edited = List<int>.of(honest.tapFrames)..removeAt(i);
        final Replay candidate = Replay(
          seed: honest.seed,
          tapFrames: edited,
          frames: honest.frames + 600,
        );
        final int score = replayFinalModel(candidate).score;
        expect(
          score,
          lessThanOrEqualTo(honestScore),
          reason: 'deleting tap $i scored $score, better than the recorded '
              '$honestScore — the claim below is no longer the right one',
        );
        expect(
          verifyRunCode(encodeRunCode(candidate), honestScore + 1).accepted,
          isFalse,
          reason: 'deleting tap $i and claiming ${honestScore + 1} was '
              'accepted',
        );
        if (score == honestScore) stillTwelve++;
        checked++;
      }
      expect(checked, greaterThan(50));
      // Some deletions land after the last point was scored and change nothing
      // the score can see. Those runs really do score what they score, and
      // verify — which is the next test.
      expect(stillTwelve, greaterThan(0));
    });

    test('an edited timeline verifies under the score it ACTUALLY produces',
        () {
      // The verifier is not an edit detector and must not become one. It has no
      // idea where a timeline came from; it only knows what the timeline does.
      final int victim = honest.tapFrames.length ~/ 2;
      final Replay tampered = Replay(
        seed: honest.seed,
        tapFrames: List<int>.of(honest.tapFrames)..removeAt(victim),
        frames: honest.frames,
      );
      final int truth = replayFinalModel(tampered).score;
      expect(truth, isNot(honestScore));
      expect(verifyRunCode(encodeRunCode(tampered), truth).accepted, isTrue);
    });

    test('adding taps to "fly further" is rejected too', () {
      // The other direction: pad the run out with extra taps and claim a score
      // the padded run does not reach.
      final List<int> padded = <int>[
        ...honest.tapFrames,
        for (int f = honest.frames; f < honest.frames + 60; f += 3) f,
      ];
      final Replay longer = Replay(
        seed: honest.seed,
        tapFrames: padded,
        frames: honest.frames + 60,
      );
      final ScoreCheck check =
          verifyRunCode(encodeRunCode(longer), honestScore + 5);
      expect(check.accepted, isFalse);
      expect(check.verdict, ScoreVerdict.scoreMismatch);
    });

    test('changing the SEED is a tampered timeline too', () {
      // The subtlest edit: keep every tap and move the run to an easier course.
      // The seed is part of the run, so this is a different run and scores
      // differently.
      final Replay moved = Replay(
        seed: honest.seed + 1,
        tapFrames: honest.tapFrames,
        frames: honest.frames,
      );
      final ScoreCheck check =
          verifyRunCode(encodeRunCode(moved), honestScore);
      expect(check.accepted, isFalse);
      expect(check.verdict, ScoreVerdict.scoreMismatch);
    });

    test('a genuinely better run on the same course is ACCEPTED', () {
      // The control, and the one that stops all of the above from being
      // satisfied by a verifier that simply says no. A second player on the
      // same course, tapping a little earlier, scores half as much again — and
      // that claim is true, so it verifies.
      //
      // Without this, "rejects everything" would pass every other test in this
      // file.
      final Replay better = recordRun(0, chaseNextGapWithLead(0.01));
      final int betterScore = replayFinalModel(better).score;
      expect(
        betterScore,
        greaterThan(honestScore),
        reason: 'the control run has to actually be better',
      );
      final ScoreCheck check =
          verifyRunCode(encodeRunCode(better), betterScore);
      expect(check.accepted, isTrue, reason: check.toString());
      // And the better run's code under the WORSE run's score is still a lie.
      expect(
        verifyRunCode(encodeRunCode(better), honestScore).accepted,
        isFalse,
      );
    });
  });

  group('(b) a truthful timeline with an inflated claim is rejected', () {
    test('the honest code, one point too many', () {
      final ScoreCheck check = verifyRunCode(honestCode, honestScore + 1);
      expect(check.accepted, isFalse);
      expect(check.verdict, ScoreVerdict.scoreMismatch);
      expect(check.actualScore, honestScore);
      expect(check.claimedScore, honestScore + 1);
      expect(check.toString(), contains('$honestScore'));
    });

    test('the honest code, a wildly inflated claim', () {
      final ScoreCheck check = verifyRunCode(honestCode, 999999);
      expect(check.accepted, isFalse);
      expect(check.actualScore, honestScore);
    });

    test('under-claiming is rejected as well', () {
      // Not an attack, but the rule is "the claim matches", not "the claim is
      // no larger". A verifier that accepted any number below the truth would
      // accept a code paired with the wrong run whenever that run scored more.
      final ScoreCheck check = verifyRunCode(honestCode, honestScore - 1);
      expect(check.accepted, isFalse);
    });

    test('a negative or nonsense claim is rejected', () {
      expect(verifyRunCode(honestCode, -1).accepted, isFalse);
      expect(verifyRunCode(honestCode, 0).accepted, isFalse);
    });
  });

  group('(c) a valid code with swapped content is rejected', () {
    test("somebody else's real run under your claim", () {
      // Nothing is corrupted here. `otherCode` is a genuine code for a genuine
      // run; its checksum is intact and it decodes cleanly. The only thing
      // wrong with it is that it is not the run being claimed.
      final RunCodeDecoding decoded = decodeRunCode(otherCode);
      expect(decoded.ok, isTrue, reason: 'the swapped code is entirely valid');
      expect(decoded.replay, somebodyElse);

      final ScoreCheck check = verifyRunCode(otherCode, honestScore);
      expect(check.accepted, isFalse);
      expect(check.verdict, ScoreVerdict.scoreMismatch);
      expect(check.actualScore, otherScore);
      expect(
        check.codeError,
        isNull,
        reason: 'the code is fine; it is the claim that is wrong, and the '
            'verdict has to say which',
      );
    });

    test('and it verifies perfectly well under its OWN score', () {
      // The same bytes, the same checksum, a different claim — accepted. Which
      // is what proves the rejection above was about the claim and not about
      // the code.
      final ScoreCheck check = verifyRunCode(otherCode, otherScore);
      expect(check.accepted, isTrue, reason: check.toString());
    });
  });

  group('a code that is not a code is refused separately from a false claim',
      () {
    test('corruption is unreadableCode, not scoreMismatch', () {
      // The distinction the checksum buys. "Your code arrived damaged" and
      // "your claim is false" are different accusations, and a system that
      // cannot tell them apart calls honest people liars every time a character
      // gets mangled in transit.
      final String flipped = honestCode.substring(0, 4) +
          (honestCode[4] == 'Z' ? 'Y' : 'Z') +
          honestCode.substring(5);
      expect(flipped, isNot(honestCode));

      final ScoreCheck check = verifyRunCode(flipped, honestScore);
      expect(check.accepted, isFalse);
      expect(check.verdict, ScoreVerdict.unreadableCode);
      expect(check.codeError, RunCodeError.checksumMismatch);
      expect(
        check.actualScore,
        isNull,
        reason: 'there is no run, so there is no score to report',
      );
    });

    test('an empty or garbage string is refused without replaying anything',
        () {
      expect(verifyRunCode('', 10).verdict, ScoreVerdict.unreadableCode);
      expect(verifyRunCode('hello there', 10).verdict,
          ScoreVerdict.unreadableCode);
      expect(verifyRunCode('!!!', 10).codeError, RunCodeError.illegalCharacter);
    });

    test('a code claiming an impossibly long run is refused, not run', () {
      // A verifier re-executes untrusted input, so the cost of a rejection has
      // to be bounded. A frame count past the cap is refused by the decoder
      // before a single tick happens.
      expect(
        () => Replay(
          seed: 0,
          tapFrames: <int>[],
          frames: maxReplayFrames + 1,
        ),
        throwsArgumentError,
      );
    });
  });

  group('verifyReplay is the same check without a code in the way', () {
    test('it accepts and rejects the same things', () {
      expect(verifyReplay(honest, honestScore).accepted, isTrue);
      expect(verifyReplay(honest, honestScore + 1).accepted, isFalse);
      expect(verifyReplay(honest, honestScore + 1).actualScore, honestScore);
      expect(verifyReplay(somebodyElse, honestScore).accepted, isFalse);
    });

    test('a run that never started scores zero and verifies as zero', () {
      final Replay nothing = Replay(seed: 0, tapFrames: <int>[], frames: 600);
      expect(replayFinalModel(nothing).state, RunState.ready);
      expect(verifyReplay(nothing, 0).accepted, isTrue);
      expect(verifyReplay(nothing, 1).accepted, isFalse);
    });
  });
}
