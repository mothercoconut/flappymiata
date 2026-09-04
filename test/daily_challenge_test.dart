/// PART 4 — the daily challenge: one course per calendar date, the same course
/// for everybody who plays that day.
///
/// THREE THINGS HAVE TO BE TRUE, and they pull in different directions:
///
///   SAME DATE, SAME COURSE   Two players on 2026-09-04 must get identical
///                            obstacles. This is what makes comparing scores
///                            mean anything at all.
///   DIFFERENT DATE, DIFFERENT COURSE
///                            Otherwise it is not daily, it is just a course.
///                            Checked over a full year, seed by seed and gap by
///                            gap.
///   STILL FAIR               A date-seeded course is a course NOBODY CHOSE. On
///                            the shipped course an unfair stretch would be
///                            found once and fixed; here, a bad date arrives
///                            for everybody at midnight and is unplayable all
///                            day. So every daily course is put through the
///                            SAME prover as the shipped one — `tool/fairness.
///                            dart`, unmodified — rather than a second, more
///                            forgiving check written for the occasion.
///
/// The date range checked below is 366 consecutive days, 2024-01-01 through
/// 2024-12-31. A leap year on purpose: it is the only range that exercises
/// 29 February, and the day-number arithmetic is the one place a calendar bug
/// could hide.
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:flappymiata/game/course_seed.dart';
import 'package:flappymiata/game/game_model.dart';
import 'package:flappymiata/game/replay.dart';

import '../tool/fairness.dart';

/// How many consecutive dates every sweep below covers.
const int datesChecked = 366;

/// The first date of that range. 2024 is a leap year, so the range is
/// 2024-01-01 .. 2024-12-31 inclusive and contains 29 February.
final DateTime firstDate = DateTime.utc(2024, 1, 1);

/// The n-th date of the range.
///
/// Uses `DateTime` deliberately — this is a test, not `lib/game/`, and using
/// the platform's own calendar here is what makes the check of
/// [daysFromCivil] independent rather than circular.
DateTime dateAt(int n) => firstDate.add(Duration(days: n));

/// MurmurHash3's finaliser, written out again from the algorithm rather than
/// imported, so the golden values below are anchored to the documented mix and
/// not to whatever `course_seed.dart` currently happens to compute.
int refFmix32(int x) {
  int h = x & 0xFFFFFFFF;
  h = h ^ (h >> 16);
  h = (h * 0x85EBCA6B) & 0xFFFFFFFF;
  h = h ^ (h >> 13);
  h = (h * 0xC2B2AE35) & 0xFFFFFFFF;
  h = h ^ (h >> 16);
  return h;
}

/// The daily seed, computed a second way: the platform's day count, XORed with
/// the published domain constant, through the finaliser above.
int refDailySeed(DateTime date) {
  final int days = date.difference(DateTime.utc(1970, 1, 1)).inDays;
  return refFmix32((days ^ 0x44415921) & 0xFFFFFFFF);
}

void main() {
  final FairnessProver prover = FairnessProver();

  group('the calendar arithmetic', () {
    test('daysFromCivil agrees with the platform calendar over $datesChecked '
        'days', () {
      for (int n = 0; n < datesChecked; n++) {
        final DateTime d = dateAt(n);
        expect(
          daysFromCivil(d.year, d.month, d.day),
          d.difference(DateTime.utc(1970, 1, 1)).inDays,
          reason: '$d',
        );
      }
    });

    test('and on the dates that break naive implementations', () {
      // Every one of these is a case a hand-rolled day count gets wrong: the
      // epoch itself, the century that IS a leap year, the century that is not,
      // 29 February, the day either side of it, and dates before 1970.
      const List<List<int>> dates = <List<int>>[
        <int>[1970, 1, 1],
        <int>[1969, 12, 31],
        <int>[1900, 3, 1],
        <int>[2000, 2, 29],
        <int>[2000, 3, 1],
        <int>[2024, 2, 28],
        <int>[2024, 2, 29],
        <int>[2024, 3, 1],
        <int>[2100, 3, 1],
        <int>[2400, 2, 29],
      ];
      for (final List<int> d in dates) {
        final DateTime platform = DateTime.utc(d[0], d[1], d[2]);
        expect(
          daysFromCivil(d[0], d[1], d[2]),
          platform.difference(DateTime.utc(1970, 1, 1)).inDays,
          reason: '${d[0]}-${d[1]}-${d[2]}',
        );
      }
      expect(daysFromCivil(1970, 1, 1), 0, reason: 'the epoch is day zero');
      expect(daysFromCivil(1969, 12, 31), -1, reason: 'before it is negative');
    });

    test('and on dates in the era before year zero', () {
      // NO DAILY CHALLENGE WILL EVER FALL HERE, and that is exactly why this
      // test exists. `daysFromCivil` carries a branch for negative years —
      // `shiftedYear >= 0 ? shiftedYear : shiftedYear - 399`, which keeps the
      // 400-year era arithmetic correct on the far side of year zero. Nothing
      // in the game reaches it, so without this the whole branch is code the
      // suite cannot see: `>= 0` could become `> 0`, or the 399 could become
      // anything at all, and every other test here would stay green.
      const List<List<int>> ancient = <List<int>>[
        <int>[1, 1, 1],
        <int>[0, 12, 31],
        <int>[0, 3, 1],
        <int>[0, 2, 29], // year 0 is a leap year in the proleptic calendar
        <int>[0, 1, 1],
        <int>[-1, 12, 31],
        <int>[-400, 3, 1],
        <int>[-401, 2, 28],
      ];
      for (final List<int> d in ancient) {
        expect(
          daysFromCivil(d[0], d[1], d[2]),
          DateTime.utc(d[0], d[1], d[2])
              .difference(DateTime.utc(1970, 1, 1))
              .inDays,
          reason: '${d[0]}-${d[1]}-${d[2]}',
        );
      }
      // And consecutive days across the year-zero boundary really are
      // consecutive, which is the property the era arithmetic exists to keep.
      expect(
        daysFromCivil(0, 1, 1) - daysFromCivil(-1, 12, 31),
        1,
        reason: 'the day after -1-12-31 is 0-01-01',
      );
    });

    test('a date that is not a date is refused, on both edges', () {
      expect(() => dailySeed(2026, 0, 1), throwsArgumentError);
      expect(() => dailySeed(2026, 13, 1), throwsArgumentError);
      expect(() => dailySeed(2026, 1, 0), throwsArgumentError);
      expect(() => dailySeed(2026, 1, 32), throwsArgumentError);
      // The neighbouring legal values, so the guard is a range and not a ban.
      expect(dailySeed(2026, 1, 1), isA<int>());
      expect(dailySeed(2026, 12, 31), isA<int>());
    });
  });

  group('the daily seed is the published mix', () {
    test('these six dates map to exactly these seeds', () {
      // Golden values. If this table has to change, the daily challenge is a
      // different daily challenge — every score anybody posted for a date was
      // earned on the old obstacles.
      const Map<String, int> golden = <String, int>{
        '1970-01-01': 3957556043,
        '2000-01-01': 2203359729,
        '2024-02-29': 3862634126,
        '2026-09-04': 2273422211,
        '2026-09-05': 990005581,
        '2027-01-01': 3851050287,
      };
      golden.forEach((String iso, int seed) {
        final List<String> parts = iso.split('-');
        expect(
          dailySeed(
            int.parse(parts[0]),
            int.parse(parts[1]),
            int.parse(parts[2]),
          ),
          seed,
          reason: iso,
        );
      });
    });

    test('and an independent implementation agrees over $datesChecked days',
        () {
      for (int n = 0; n < datesChecked; n++) {
        final DateTime d = dateAt(n);
        expect(dailySeed(d.year, d.month, d.day), refDailySeed(d), reason: '$d');
      }
    });

    test('the epoch does not fall through to the shipped course', () {
      // Without the domain constant, 1970-01-01 would hash zero to zero and one
      // calendar day would silently BE the classic course.
      expect(dailySeed(1970, 1, 1), isNot(0));
    });
  });

  group('same date, same course', () {
    test('two players on the same date get identical obstacles', () {
      // "Two players" is modelled as two independently built models, because
      // that is the whole claim: nothing about the course comes from the device
      // or from when in the day it was started.
      for (int n = 0; n < datesChecked; n += 7) {
        final DateTime d = dateAt(n);
        final int alice = dailySeed(d.year, d.month, d.day);
        final int bob = dailySeed(d.year, d.month, d.day);
        expect(alice, bob);

        final GameModel aliceRun =
            GameModel.ready(gapCentreFor: gapPatternForSeed(alice)).flap();
        final GameModel bobRun =
            GameModel.ready(gapCentreFor: gapPatternForSeed(bob)).flap();
        GameModel a = aliceRun;
        GameModel b = bobRun;
        for (int f = 0; f < 400; f++) {
          a = a.tick(replayFrameSeconds);
          b = b.tick(replayFrameSeconds);
        }
        expect(a.obstacles, isNotEmpty);
        expect(a, b, reason: '$d: two players saw different worlds');
      }
    });

    test('and a run recorded on a date replays on that date and no other', () {
      final DateTime d = DateTime.utc(2026, 9, 4);
      final int today = dailySeed(d.year, d.month, d.day);
      final int tomorrow = dailySeed(2026, 9, 5);

      final Replay r = Replay(
        seed: today,
        tapFrames: <int>[0, 20, 44, 70, 96, 120],
        frames: 400,
      );
      final Replay wrongDay = Replay(
        seed: tomorrow,
        tapFrames: r.tapFrames,
        frames: r.frames,
      );
      expect(replayFinalModel(r), isNot(replayFinalModel(wrongDay)));
    });
  });

  group('different dates, different courses', () {
    test('all $datesChecked dates in the range have distinct seeds', () {
      final Set<int> seeds = <int>{};
      for (int n = 0; n < datesChecked; n++) {
        final DateTime d = dateAt(n);
        seeds.add(dailySeed(d.year, d.month, d.day));
      }
      expect(seeds, hasLength(datesChecked));
    });

    test('consecutive dates give courses that differ from the first gap', () {
      // Distinct seeds would be satisfied by a mix that changed one low bit and
      // left the course visually identical. This checks the thing a player
      // would actually notice: where the pipes are.
      int identicalFirstGaps = 0;
      for (int n = 0; n + 1 < datesChecked; n++) {
        final DateTime a = dateAt(n);
        final DateTime b = dateAt(n + 1);
        final int seedA = dailySeed(a.year, a.month, a.day);
        final int seedB = dailySeed(b.year, b.month, b.day);
        if (seededGapCentre(seedA, 0) == seededGapCentre(seedB, 0)) {
          identicalFirstGaps++;
        }
      }
      expect(identicalFirstGaps, 0);
    });

    test('the first twelve gaps differ on every pair of dates in a month', () {
      // Stronger and much more expensive, so it runs over 31 dates rather than
      // 366: no two of them agree on their opening stretch.
      final List<List<double>> openings = <List<double>>[
        for (int n = 0; n < 31; n++)
          <double>[
            for (int i = 0; i < 12; i++)
              seededGapCentre(
                dailySeed(dateAt(n).year, dateAt(n).month, dateAt(n).day),
                i,
              ),
          ],
      ];
      for (int i = 0; i < openings.length; i++) {
        for (int j = i + 1; j < openings.length; j++) {
          expect(
            openings[i],
            isNot(openings[j]),
            reason: 'day $i and day $j open identically',
          );
        }
      }
    });

    test('the daily courses use the whole legal band, like the shipped one',
        () {
      // A generator that only ever produced mid-field gaps would satisfy every
      // test above and make a duller game every single day.
      double lowest = 1.0;
      double highest = 0.0;
      for (int n = 0; n < datesChecked; n++) {
        final DateTime d = dateAt(n);
        final int seed = dailySeed(d.year, d.month, d.day);
        for (int i = 0; i < 20; i++) {
          final double c = seededGapCentre(seed, i);
          if (c < lowest) lowest = c;
          if (c > highest) highest = c;
        }
      }
      expect(lowest, closeTo(GameModel.minGapCentre, 0.002));
      expect(highest, closeTo(GameModel.maxGapCentre, 0.002));
    });
  });

  group('every daily course is provably fair', () {
    // The SAME prover, the SAME courses class, the SAME standard of evidence as
    // the shipped pattern's gate in `test/fairness_prover_test.dart`. Nothing
    // in this group is a second fairness implementation — `Course.fromSeed` is
    // the shipped `Course.fromPattern` handed a different pattern, and that is
    // the entire difference.

    test('$datesChecked consecutive dates, six obstacles each, all survivable',
        () {
      final List<String> failing = <String>[];
      for (int n = 0; n < datesChecked; n++) {
        final DateTime d = dateAt(n);
        final int seed = dailySeed(d.year, d.month, d.day);
        final ProofResult r = prover.prove(Course.fromSeed(seed, 0, 6));
        if (!r.survivable) {
          failing.add('${d.toIso8601String().substring(0, 10)} '
              '(seed $seed, ${r.cause?.name} at obstacle '
              '${r.deathObstacleIndex})');
        }
      }
      expect(
        failing,
        isEmpty,
        reason: 'unsurvivable daily courses: $failing — report this rather '
            'than retuning the constants',
      );
    });

    test('and a continuous sixty-obstacle run on three of them', () {
      // Stronger than the windows: the reachable set is never reset, so this
      // says a perfect player who starts the daily challenge is still alive at
      // obstacle 60 rather than that each stretch is clearable from scratch.
      for (int n = 0; n < 3; n++) {
        final DateTime d = dateAt(n);
        final int seed = dailySeed(d.year, d.month, d.day);
        final ProofResult r = prover.prove(Course.fromSeed(seed, 0, 60));
        expect(
          r.survivable,
          isTrue,
          reason: '$d died at frame ${r.deathFrame} on obstacle '
              '${r.deathObstacleIndex} (${r.cause?.name})',
        );
        expect(r.obstaclesCleared, 60);
      }
    });

    test('with a real margin, not a hairline one', () {
      // Survivable is the bar; this is the follow-up. A daily course that is
      // clearable by 1e-4 is technically fair and would read as broken.
      double worst = double.infinity;
      for (int n = 0; n < 20; n++) {
        final DateTime d = dateAt(n);
        final int seed = dailySeed(d.year, d.month, d.day);
        final double m =
            tightestMargin(Course.fromSeed(seed, 0, 3), prover: prover);
        if (m < worst) worst = m;
      }
      expect(
        worst,
        greaterThan(GameModel.carHeight),
        reason: 'the tightest margin over the first 20 daily courses is $worst, '
            'less than one car-height',
      );
    });

    test('the prover is not simply saying yes to everything', () {
      // The control this whole group needs. `Course.fromSeed` builds courses
      // through the same factory as everything else, so if that factory were
      // quietly producing empty or trivially wide courses, every proof above
      // would pass for no reason. A course with the daily gaps CRUSHED to a
      // tenth of their height has to come back unsurvivable.
      final int seed = dailySeed(2026, 9, 4);
      final Course real = Course.fromSeed(seed, 0, 6);
      expect(real.gaps, hasLength(6));
      expect(real.playableByGame, isTrue);
      for (final CourseGap g in real.gaps) {
        expect(g.height, GameModel.gapHeight);
      }

      final Course pinched = Course(
        name: 'daily, pinched',
        gaps: <CourseGap>[
          for (final CourseGap g in real.gaps)
            CourseGap(g.centre, GameModel.carHeight / 2),
        ],
        playableByGame: false,
      );
      final ProofResult r = prover.prove(pinched);
      expect(r.survivable, isFalse);
      expect(r.cause, FailureCause.gapNarrowerThanCar);
    });
  });

  group('seed 0 keeps its meaning', () {
    test('the classic course is still reachable and is not a daily course', () {
      expect(Course.fromSeed(0, 0, 8).gaps.map((CourseGap g) => g.centre),
          Course.fromDefaultPattern(0, 8).gaps.map((CourseGap g) => g.centre));
      // And no date in the range accidentally lands on it.
      for (int n = 0; n < datesChecked; n++) {
        final DateTime d = dateAt(n);
        expect(dailySeed(d.year, d.month, d.day), isNot(0), reason: '$d');
      }
    });
  });
}
