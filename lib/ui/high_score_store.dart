/// The best score, and how it survives the app being closed.
///
/// ============================================================================
/// WHY THIS IS NOT IN `lib/game/`, WHICH IS WHERE THE SCORE COMES FROM
/// ============================================================================
///
/// `lib/game/` has a directory rule — no Flutter, no Flame, no clock, no
/// randomness — and `test/game_model_test.dart` enforces it by reading the
/// sources. Storage breaks it twice over. Reading a file or a preferences store
/// is I/O, so it can fail, it takes time, and it returns something DIFFERENT
/// every run: whatever was there last time. A model with a `loadBestScore()` on
/// it would stop being a pure function of its inputs, and the replay system, the
/// verified score and the whole fairness proof all rest on it being one.
///
/// So the split is: the model PRODUCES a score, and something else STORES it.
/// This file is that something else. It is the only place in the app that knows
/// a disk exists.
///
/// ============================================================================
/// WHY A STORED SCORE IS RE-EXECUTED INSTEAD OF BELIEVED
/// ============================================================================
///
/// A number in a preferences file is a number anybody can edit, and the usual
/// answer — obfuscate it, sign it, hide it — is the fight `verified_score.dart`
/// already explains cannot be won on the player's own device.
///
/// This game does not have to have that fight. A run is a seed and a list of tap
/// frames, `run_code.dart` writes that down as a short string, and re-executing
/// it produces exactly one score on any machine. So what is stored is the RUN,
/// with the score alongside it as a claim, and loading it runs the claim through
/// `verifyRunCode`. A best score that comes back is a best score somebody could
/// watch.
///
/// That buys a second thing, which matters more in practice than cheating does:
/// **the stored best heals itself when the rules change.** The difficulty ramp
/// landed after this file was written; every run recorded before it scores
/// differently now, so those records no longer verify and are quietly dropped
/// instead of leaving an unreachable number on the start screen for ever.
library;

import 'package:shared_preferences/shared_preferences.dart';

import 'package:flappymiata/game/replay.dart';
import 'package:flappymiata/game/run_code.dart';
import 'package:flappymiata/game/verified_score.dart';

/// A best run: the score, and the run that scored it.
///
/// The [code] carries its own course seed (see `lib/game/course_seed.dart`), so
/// a record is self-describing — nothing else has to be stored to know which
/// course the run was played on.
class BestRun {
  /// The score claimed for the run.
  final int score;

  /// The run itself, as a run code.
  final String code;

  const BestRun({required this.score, required this.code});

  /// The decoded run, or null if the code is not readable. Cheap enough to call
  /// on demand; a record only exists after it has already decoded once.
  Replay? get replay => decodeRunCode(code).replay;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is BestRun && other.score == score && other.code == code;

  @override
  int get hashCode => Object.hash(score, code);

  @override
  String toString() => 'BestRun(score: $score, code: $code)';
}

/// Turning a [BestRun] into one string and back — with the run re-executed on
/// the way back in.
///
/// Split out from the stores below, and made pure, so that the interesting half
/// can be tested without a platform, a plugin or a disk. Every store is then a
/// four-line shim around a key and a string.
abstract final class BestRunRecord {
  /// The key the record is stored under.
  ///
  /// VERSIONED IN THE KEY, not in the value. If the record's layout ever has to
  /// change, a new key means the old value is simply never read again — no
  /// migration code, no half-parsed record, and an old build sharing a device
  /// with a new one cannot confuse the two.
  static const String storageKey = 'flappymiata.bestRun.v1';

  /// Separates the claimed score from the code.
  ///
  /// `:` is safe because a run code is Crockford Base32 — digits and uppercase
  /// letters only, see `runCodeAlphabet` — so it can never contain one, and
  /// splitting at the FIRST separator is unambiguous even if that ever changed.
  static const String separator = ':';

  /// The record as it is written to storage.
  static String encode(BestRun best) =>
      '${best.score}$separator${best.code}';

  /// Reads a record back, returning it ONLY if the run really scores what the
  /// record claims.
  ///
  /// Null for every way this can go wrong — absent, empty, malformed, a code
  /// that does not decode, a code that decodes but scores something else — on
  /// purpose. The caller's move is identical in all five cases: there is no
  /// trustworthy best score, so start from nothing. Distinguishing them would be
  /// a diagnostic nobody acts on.
  static BestRun? decode(String? raw) {
    if (raw == null) return null;

    final int cut = raw.indexOf(separator);
    if (cut <= 0) return null;

    final int? claimed = int.tryParse(raw.substring(0, cut));
    if (claimed == null || claimed < 0) return null;

    final String code = raw.substring(cut + separator.length);
    if (code.isEmpty) return null;

    // The whole point of the file. `verifyRunCode` decodes the run and plays it
    // through the real `GameModel`; `accepted` is true only when the score it
    // produces is the score that was claimed.
    final ScoreCheck check = verifyRunCode(code, claimed);
    if (!check.accepted) return null;

    return BestRun(score: claimed, code: code);
  }
}

/// Somewhere a best run can be kept between sessions.
///
/// An interface rather than a single concrete class because the game must be
/// testable with no platform under it. `flutter test` has no preferences plugin
/// and no disk that a widget test should be writing to; [InMemoryHighScoreStore]
/// is what runs there, and it is the same type the real game holds.
abstract class HighScoreStore {
  /// The stored best, or null when there is none that verifies.
  Future<BestRun?> load();

  /// Replaces the stored best.
  Future<void> save(BestRun best);
}

/// A store that forgets everything when the process ends.
///
/// Used by tests, and it is also the honest fallback when the platform store
/// cannot be reached — the game keeps a best score for the session and simply
/// does not carry it forward, which is exactly what it did before this file
/// existed.
class InMemoryHighScoreStore implements HighScoreStore {
  BestRun? _best;

  /// Seeds the store, so a test can arrange "the app has been played before".
  InMemoryHighScoreStore([this._best]);

  /// What is held right now, without going through the future.
  BestRun? get current => _best;

  @override
  Future<BestRun?> load() async => _best;

  @override
  Future<void> save(BestRun best) async {
    _best = best;
  }
}

/// The real one: `shared_preferences`, the platform's own small key-value store.
///
/// WHY THIS PACKAGE AND NOT A FILE: writing a file needs a directory that is
/// writable and survives an update, and on Android and iOS the only way to learn
/// where that is, is to ask the platform through a method channel. So the file
/// route is not dependency-free either — it is `path_provider` plus the encoding,
/// the atomic-write and the corrupt-file handling written by hand. This package
/// is one dependency instead of one dependency and a pile of code, it is
/// maintained by the Flutter team, and the thing being stored is one short
/// string, which is precisely what a preferences store is for.
///
/// EVERY CALL SWALLOWS ITS ERRORS. A missing plugin, a locked store or a full
/// disk must not take the game down: not being able to remember a score is a
/// disappointment, and a crash on launch is a bug. A failed load reads as "no
/// best yet" and a failed save is dropped, which is the same behaviour the game
/// had before it could persist anything at all.
class SharedPreferencesHighScoreStore implements HighScoreStore {
  @override
  Future<BestRun?> load() async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      return BestRunRecord.decode(prefs.getString(BestRunRecord.storageKey));
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> save(BestRun best) async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        BestRunRecord.storageKey,
        BestRunRecord.encode(best),
      );
    } catch (_) {
      // Deliberately ignored. See the class comment.
    }
  }
}
