/// Which course a run is played on, expressed as a single integer — and how a
/// calendar date turns into one.
///
/// WHY A SEED IS PART OF A REPLAY AT ALL, when the inputs alone look like they
/// ought to be enough:
///
/// A run is `flap()` and `tick(dt)` applied to a starting model. The taps are
/// only half of that starting model. The other half is [GapPattern] — the
/// function that decides where every gap sits — and it is injected, so two
/// players tapping on exactly the same frames on two different courses die in
/// two different places with two different scores. Storing the taps without
/// storing which course they were tapped against records half a run and calls
/// it whole. The seed is that other half, compressed to one number.
///
/// WHY THE COURSE IS A PURE FUNCTION OF THE SEED, rather than the seed being
/// fed to a random number generator:
///
/// A generator carries state, so gap 400 depends on how many numbers were drawn
/// before it — which means reproducing gap 400 means replaying the whole draw
/// sequence in the right order. A hash of (seed, index) depends on nothing else
/// at all. It can be evaluated out of order, backwards, on two machines, in a
/// test, and give the same answer. That is the same argument
/// `GameModel.defaultGapCentre` already makes for the shipped course; this file
/// only adds a second input to it.
///
/// SEED 0 IS THE SHIPPED COURSE, exactly. Not "close to" and not "similar in
/// spirit": [seededGapCentre] with a seed of 0 evaluates to the identical
/// double as [GameModel.defaultGapCentre] for every index, which is checked
/// value-for-value in `test/daily_challenge_test.dart`. That matters because
/// every fairness proof, every golden value and every recorded run that already
/// exists was made against the shipped course, and none of it has to be redone.
///
/// Same directory rule as the rest of `lib/game/`: no Flame, no Flutter, no
/// clock, no randomness. The DATE, in particular, is passed IN as three plain
/// integers — see [dailySeed] for why that direction is the only workable one.
library;

import 'game_model.dart';

/// Everything in this file is 32-bit arithmetic done in Dart's 64-bit ints, so
/// every step that can overflow past 32 bits is masked straight back down.
/// Letting an intermediate grow wider silently changes the answer, and a hash
/// that gives a different answer is a different course.
const int _mask32 = 0xFFFFFFFF;

/// Domain separator for daily seeds, so a date's seed is not simply a day
/// number wearing a hash.
///
/// WHY IT IS HERE: without it, `dailySeed` for 1970-01-01 would be
/// `_fmix32(0)`, which is 0 — and seed 0 is the shipped course. One calendar
/// day would silently be "the classic course" while every other day got a fresh
/// one. The constant is ASCII `DAY!`; nothing about the value matters except
/// that it is not zero and is written down once.
const int _dailyDomain = 0x44415921;

/// MurmurHash3's 32-bit finaliser, `fmix32`.
///
/// This is character-for-character the mixing half of
/// [GameModel.defaultGapCentre]. It is repeated rather than imported because
/// that function does the multiply-by-a-large-odd-constant step *before* the
/// mix and returns a position rather than a hash, so there is no seam in it to
/// call. The duplication is pinned by a golden test, not by hope.
///
/// The one property this file leans on: `_fmix32(0) == 0`. Every step is either
/// a multiply (0 stays 0) or an xor with a shift of itself (0 stays 0), so the
/// finaliser fixes zero. That is what lets seed 0 fall through to the shipped
/// course exactly rather than approximately.
int _fmix32(int x) {
  int h = x & _mask32;
  h = h ^ (h >> 16);
  h = (h * 0x85EBCA6B) & _mask32;
  h = h ^ (h >> 13);
  h = (h * 0xC2B2AE35) & _mask32;
  h = h ^ (h >> 16);
  return h;
}

/// The largest seed value, inclusive. Seeds are 32-bit because the hash is.
///
/// Stated as a constant rather than left implicit so that the replay record and
/// the run code encoder can both range-check against the same number instead of
/// each inventing its own idea of how wide a seed is.
const int maxCourseSeed = _mask32;

/// Where the gap in obstacle [index] sits on the course selected by [seed].
///
/// The shape of the mix, and why it is this shape:
///
///   1. The SEED is scrambled first, on its own. Consecutive seeds — which is
///      what consecutive dates produce — differ in one or two low bits, and
///      feeding those straight in would make consecutive days' courses visibly
///      related. `_fmix32` is a bijection on 32 bits, so distinct seeds stay
///      distinct after scrambling.
///   2. The scrambled seed is XORed into `index + 1`, not added. Addition would
///      make "seed s, index i" collide with "seed s', index i'" along whole
///      diagonals — one course would be another course shifted along. XOR has
///      no such structure.
///   3. `index + 1` rather than `index`, because several mixes send 0 to 0 and
///      that would peg obstacle 0 of the seed-0 course to the top of its band.
///      This is inherited from [GameModel.defaultGapCentre] and is part of what
///      makes seed 0 reproduce it.
///
/// The result lands in `[minGapCentre, maxGapCentre)` already, because `unit`
/// is in `[0, 1)`. It is still passed through `GameModel.clampGapCentre` by the
/// model itself when an obstacle is spawned; nothing here relies on that.
double seededGapCentre(int seed, int index) {
  final int scrambledSeed = _fmix32(seed);
  int h = ((index + 1) ^ scrambledSeed) & _mask32;
  h = (h * 0x9E3779B1) & _mask32;
  h = _fmix32(h);

  // 2^32, so `unit` lands in [0.0, 1.0).
  final double unit = h / 4294967296.0;
  return GameModel.minGapCentre +
      unit * (GameModel.maxGapCentre - GameModel.minGapCentre);
}

/// The [GapPattern] for one seed, ready to hand to `GameModel.ready`.
GapPattern gapPatternForSeed(int seed) =>
    (int index) => seededGapCentre(seed, index);

/// Days from 1970-01-01 to the proleptic Gregorian date [year]-[month]-[day].
///
/// Howard Hinnant's `days_from_civil`, which is the standard branch-free way to
/// do this. It is INTEGER ARITHMETIC ONLY — no date library, no clock, no
/// locale, no timezone — which is the whole reason it can live in this
/// directory. Negative results are fine and mean "before 1970".
///
/// WHY NOT JUST `year * 10000 + month * 100 + day` AS THE SEED: it would work,
/// in the sense that each date would get its own number. But it leaves gaps —
/// there is no 2026-01-32 — and it makes "the day after" a jump of 1 on most
/// days and 69 at a month boundary. A day count makes consecutive days
/// consecutive integers, which is the property [dailySeed] then deliberately
/// destroys with a hash. Starting from something regular and scrambling it is
/// easier to reason about than starting from something irregular.
int daysFromCivil(int year, int month, int day) {
  // March-based year: the leap day moves to the END, so the 4/100/400 rules
  // apply to whole years and never split one.
  final int shiftedYear = month <= 2 ? year - 1 : year;

  // FLOOR division, written without a branch. Hinnant's published version says
  // `(y >= 0 ? y : y - 399) / 400`, compensating for a C++ division that
  // truncates toward zero; Dart's `~/` truncates the same way, so the same
  // compensation is needed. The branch is a worse way to say it, and not only
  // stylistically: at shiftedYear == 0 the two arms give 0 ~/ 400 and
  // -399 ~/ 400, which are both 0, so the comparison in it cannot discriminate
  // and `tool/mutate.dart` could move the threshold freely with the whole
  // suite green. Dart's `%` is non-negative for a positive divisor, so
  // subtracting the remainder first turns truncation into flooring for every
  // input, with nothing left over to get wrong.
  final int era = (shiftedYear - shiftedYear % 400) ~/ 400;
  final int yearOfEra = shiftedYear - era * 400; // [0, 399]
  final int dayOfYear =
      (153 * (month + (month > 2 ? -3 : 9)) + 2) ~/ 5 + day - 1; // [0, 365]
  final int dayOfEra =
      yearOfEra * 365 + yearOfEra ~/ 4 - yearOfEra ~/ 100 + dayOfYear;
  // 146097 days per 400-year era; 719468 shifts the origin from 0000-03-01 to
  // 1970-01-01.
  return era * 146097 + dayOfEra - 719468;
}

/// The course seed everybody playing on [year]-[month]-[day] gets.
///
/// WHY THE DATE IS A PARAMETER AND NOT SOMETHING THIS FILE LOOKS UP:
///
/// Reading the clock here would put a hidden input into `lib/game/`. `tick`
/// takes `dt` rather than reading a clock, and the model takes a gap pattern
/// rather than rolling dice, for exactly one reason: a function whose answer
/// depends on something the caller cannot see cannot be tested by comparing it
/// to an expected value. A daily seed that read today's date would be a
/// function whose output changed at midnight — the test asserting "2026-03-14
/// gives seed X" would still work, but nothing could test the wiring, the
/// whole directory would stop being clock-free, and the structural guard in
/// `test/game_model_test.dart` would fail on the spot.
///
/// So the date enters the way time and randomness already do: from outside.
/// `lib/main.dart` is where the actual calendar is consulted; it is a renderer,
/// it already knows about wall-clock time because Flame hands it a frame
/// duration, and one more real-world fact there costs nothing.
///
/// Throws [ArgumentError] on a date that is not a date. A malformed date
/// silently producing *some* course is the failure that matters here: two
/// players would be told they are on the same daily challenge while playing
/// different obstacles, and nothing would say so.
int dailySeed(int year, int month, int day) {
  if (month < 1 || month > 12) {
    throw ArgumentError.value(month, 'month', 'must be 1..12');
  }
  if (day < 1 || day > 31) {
    throw ArgumentError.value(day, 'day', 'must be 1..31');
  }
  return _fmix32((daysFromCivil(year, month, day) ^ _dailyDomain) & _mask32);
}
