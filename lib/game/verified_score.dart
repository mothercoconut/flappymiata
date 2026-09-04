/// Verified scores: checking a claim by re-running it.
///
/// ============================================================================
/// WHY A CLAIMED SCORE IS CHECKABLE HERE AND IS NOT IN MOST GAMES
/// ============================================================================
///
/// The usual leaderboard is a number sent to a server. The server has no way to
/// know whether the number came from playing or from a text field, so the only
/// defence is to make the number hard to forge — obfuscation, a shared secret,
/// a signature — and every one of those lives inside the client, where the
/// player is. That fight is lost by construction.
///
/// This game is deterministic. A run is a seed and a list of tap frames, and
/// running them produces exactly one score, on any machine, every time. So the
/// claim can simply be RE-EXECUTED. The verifier does not have to trust the
/// player, detect tampering, or keep a secret: it plays the run itself and
/// looks at the scoreboard the model produces.
///
/// That closes all three of the obvious attacks, and it is worth being explicit
/// about why each one closes, because they close for different reasons:
///
///   1. **Inflate the claimed score.** The code is honest, the number is not.
///      Re-execution produces the real score, which is smaller.
///      Caught by comparing the two numbers.
///   2. **Tamper with the timeline** to make a better run. Editing tap frames
///      is easy — but the edited taps are a DIFFERENT run, and almost every
///      edit kills the car earlier rather than later. Caught the same way: the
///      re-executed score is not the claimed one. (An edit that genuinely does
///      score higher is not cheating. It is a better run, and it verifies,
///      because it really happened.)
///   3. **Send somebody else's valid code with your own claimed score.** The
///      checksum is intact — it is a real code — so nothing about the code's
///      integrity is wrong. Caught only by re-execution: that code scores what
///      that code scores, and it is not what was claimed.
///
/// Attack 3 is the one that shows why a checksum is not an anti-cheat measure
/// and was never meant to be. The checksum answers "did this code arrive as it
/// was sent". Re-execution answers "does this run do what you say". Two
/// different questions, and only the second one is about honesty. See
/// `run_code.dart` for the first.
///
/// WHAT THIS STILL DOES NOT STOP: a bot. A program that plays perfectly
/// produces a genuine run with a genuine high score, and this verifier will
/// correctly certify it, because it did happen. Distinguishing a human from a
/// machine is a different problem and no amount of determinism solves it. What
/// is gained is that every score on the board is a run somebody can watch —
/// which is a much stronger guarantee than a signed integer.
///
/// Same directory rule as the rest of `lib/game/`: no Flame, no Flutter, no
/// clock, no randomness.
library;

import 'game_model.dart';
import 'replay.dart';
import 'run_code.dart';

/// The three outcomes of checking a claim.
enum ScoreVerdict {
  /// The code decoded and the run really scores what was claimed.
  verified,

  /// The code could not be read at all. Nothing was claimed about a run because
  /// there was no run — see the accompanying [ScoreCheck.codeError].
  unreadableCode,

  /// The code is a real run and it does not score what was claimed.
  scoreMismatch,
}

/// The result of checking one claim.
class ScoreCheck {
  /// What was decided.
  final ScoreVerdict verdict;

  /// The score that was claimed.
  final int claimedScore;

  /// The score the run actually produces. Null when the code was unreadable, so
  /// that "no answer" and "the answer is 0" stay distinguishable.
  final int? actualScore;

  /// The decoded run, when there was one.
  final Replay? replay;

  /// Why the code could not be read, when that is what happened.
  final RunCodeError? codeError;

  /// A sentence naming what went wrong, for reports and error messages.
  final String detail;

  const ScoreCheck({
    required this.verdict,
    required this.claimedScore,
    this.actualScore,
    this.replay,
    this.codeError,
    this.detail = '',
  });

  /// True only for [ScoreVerdict.verified]. The one question a leaderboard asks.
  bool get accepted => verdict == ScoreVerdict.verified;

  @override
  String toString() => switch (verdict) {
    ScoreVerdict.verified => 'VERIFIED score $claimedScore',
    ScoreVerdict.unreadableCode => 'REJECTED (unreadable code) $detail',
    ScoreVerdict.scoreMismatch =>
      'REJECTED (claimed $claimedScore, actually $actualScore)',
  };
}

/// Checks that [code] really is a run scoring [claimedScore].
///
/// This is the whole leaderboard, and it needs no server: anybody holding the
/// code can run this and get the same answer, because the model that decides it
/// is the same model on every machine.
ScoreCheck verifyRunCode(String code, int claimedScore) {
  final RunCodeDecoding decoded = decodeRunCode(code);
  final Replay? replay = decoded.replay;
  if (replay == null) {
    return ScoreCheck(
      verdict: ScoreVerdict.unreadableCode,
      claimedScore: claimedScore,
      codeError: decoded.error,
      detail: decoded.detail,
    );
  }
  return verifyReplay(replay, claimedScore);
}

/// Checks an already-decoded run against a claim.
///
/// Split out from [verifyRunCode] so the re-execution can be tested without a
/// code in the way, and so a caller that already has a replay — the game
/// itself, checking its own best run before offering it — does not have to
/// encode it just to check it.
ScoreCheck verifyReplay(Replay replay, int claimedScore) {
  final GameModel finalModel = replayFinalModel(replay);
  final int actual = finalModel.score;
  if (actual != claimedScore) {
    return ScoreCheck(
      verdict: ScoreVerdict.scoreMismatch,
      claimedScore: claimedScore,
      actualScore: actual,
      replay: replay,
      detail: 'the run ends ${finalModel.state.name} on obstacle $actual',
    );
  }
  return ScoreCheck(
    verdict: ScoreVerdict.verified,
    claimedScore: claimedScore,
    actualScore: actual,
    replay: replay,
  );
}
