/// The palette, seen by a protanope and by a deuteranope.
///
/// ============================================================================
/// WHY SIMULATE RATHER THAN GUESS
/// ============================================================================
///
/// Every person who worked on this game can see the difference between the
/// green pipes and the green hills. That is exactly why nobody could tell
/// whether the difference was there: the judgement "those are clearly different
/// greens" is made by the visual system that is not the one at risk. About one
/// man in twelve has some red-green colour deficiency, and no amount of care
/// from a trichromat substitutes for measuring.
///
/// So both dichromacies are simulated — `lib/ui/colour_math.dart`, Viénot,
/// Brettel & Mollon (1999) — and every pair the game NEEDS the player to tell
/// apart is measured after simulation as well as before.
///
/// ============================================================================
/// THE METRIC, AND WHY THIS ONE
/// ============================================================================
///
/// CIEDE2000, ΔE₀₀. The alternative is ΔE*ab, plain Euclidean distance in Lab,
/// which is four lines instead of forty — and which is known to be badly
/// non-uniform in the blue region and near the neutral axis. Simulating
/// dichromacy collapses colours ONTO a blue-yellow axis, so every pair here is
/// judged in precisely the region where the cheap metric is least trustworthy.
/// CIEDE2000 is the CIE's current recommendation and carries the corrections
/// that make a difference measured near blue comparable with one measured near
/// red. Its own implementation is pinned against the published Sharma, Melkote
/// & Trussell (2005) test data in `test/colour_math_test.dart` before it is
/// used here.
///
/// ============================================================================
/// THE LIMITS, WHICH ARE NOT SMALL
/// ============================================================================
///
///   * **Dichromacy is not the common case.** This models the total absence of
///     a cone class. The far more common conditions — protanomaly and
///     deuteranomaly, a SHIFTED cone rather than a missing one — are not
///     modelled at all. Dichromacy is the harder case, so passing here is
///     evidence and not proof.
///   * **Tritanopia is not covered.** Blue-yellow deficiency needs the full
///     two-half-plane Brettel construction rather than the single projection
///     used here. It is also much rarer. It is still not covered, and the
///     colours chosen to survive red-green loss lean on the blue-yellow axis,
///     which is precisely the axis a tritanope loses.
///   * **ΔE₀₀ models a laboratory judgement.** Two large uniform patches,
///     touching, under controlled light, with an unhurried observer. A phone
///     screen at unknown brightness in unknown light, showing small shapes
///     moving at half a screen width per second, is none of those.
///   * **A simulation is not an experience.** It predicts which colours become
///     confusable. It says nothing about what a colourblind player sees, how
///     they adapt, or whether the game is any good. NO COLOURBLIND PLAYER HAS
///     TESTED THIS GAME, and no emulator or device was available either.
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:flappymiata/ui/colour_math.dart';
import 'package:flappymiata/ui/palette.dart' as palette;

import 'sprite_colours.dart';

/// Decodes the sprite, off the test's fake clock.
///
/// WHY `runAsync` AND NOT A PLAIN `await`: `testWidgets` runs its body inside a
/// fake-async zone where timers and microtasks are driven by the test rather
/// than by the platform. Decoding a PNG is real, off-thread work with a real
/// future behind it, so awaiting it directly inside that zone waits forever —
/// the test does not hang because the decode is slow, it hangs because nothing
/// is ever going to complete it. `runAsync` steps outside the fake clock for
/// exactly as long as the decode takes.
Future<SpriteColours> spriteFor(WidgetTester tester) async {
  final SpriteColours? measured =
      await tester.runAsync<SpriteColours>(measureSprite);
  expect(measured, isNotNull, reason: 'the sprite could not be decoded');
  return measured!;
}

/// The three ways of looking that every pair is measured under.
const List<Dichromacy?> visions = <Dichromacy?>[
  null,
  Dichromacy.deuteranopia,
  Dichromacy.protanopia,
];

String _visionName(Dichromacy? v) => v?.name ?? 'normal colour vision';

void main() {
  group('every pair the game relies on stays tellable apart', () {
    test('under normal vision, deuteranopia and protanopia', () {
      final List<String> failures = <String>[];
      for (final palette.DistinctPair pair in palette.distinctPairs) {
        for (final Dichromacy? vision in visions) {
          final double got = pair.worstDifference(vision);
          if (got < palette.distinguishableDeltaE) {
            failures.add(
              '${pair.label}: ${got.toStringAsFixed(2)} ΔE00 under '
              '${_visionName(vision)}, needs '
              '${palette.distinguishableDeltaE} — worst against '
              '${hexOf(pair.worstBackdrop(vision))}.\n'
              '    what this costs: ${pair.cost}',
            );
          }
        }
      }
      expect(failures, isEmpty, reason: '\n${failures.join('\n')}');
    });

    test('the list is not empty and names what each merge would cost', () {
      // A loop over an empty list passes, and a list of pairs nobody can
      // justify is a list somebody will delete the first time it is
      // inconvenient. Every entry has to say what goes wrong if the two
      // colours merge.
      expect(palette.distinctPairs.length, greaterThanOrEqualTo(10));
      for (final palette.DistinctPair pair in palette.distinctPairs) {
        expect(pair.label.trim(), isNotEmpty);
        expect(pair.cost.trim(), isNotEmpty, reason: pair.label);
        expect(pair.over, isNotEmpty, reason: pair.label);
        for (final int backdrop in pair.over) {
          expect(isOpaque(backdrop), isTrue,
              reason: '${pair.label} is graded against ${hexOf(backdrop)}, '
                  'which is itself see-through');
        }
      }
    });

    test('the pairs cover the three groups that matter', () {
      // Named coverage rather than a count: the pipes against the scenery, the
      // three assist signals against each other, and the ghost against what it
      // flies over. A count alone would be satisfied by ten variations on one
      // easy pair.
      final String all =
          palette.distinctPairs.map((palette.DistinctPair p) => p.label).join(';');
      expect(all, contains('pipe body vs the hills'));
      expect(all, contains('pipe outline vs the ground'));
      expect(all, contains('assist window vs assist deadline'));
      expect(all, contains('ghost car'));
      expect(all, contains('collision overlay'));
    });
  });

  group('the check would notice a pair that merged', () {
    test('two colours a deuteranope cannot separate are reported', () {
      // THE DETECTOR, DETECTED. Everything above is a loop that reports
      // failures; if `worstDifference` were broken — a simulation that returned
      // its input, a metric stuck at a large constant — the loop would find
      // nothing and the suite would be green about a palette nobody had
      // examined.
      //
      // This is a pair chosen to be a classic red-green confusion: a mid red
      // and a mid green of similar lightness. A trichromat sees them as
      // obviously different; a deuteranope does not.
      const palette.DistinctPair confusable = palette.DistinctPair(
        'deliberately confusable',
        'this pair exists to prove the check can fail',
        0xFFA08000,
        0xFF6E9000,
        <int>[0xFF10233F],
      );
      expect(confusable.worstDifference(null),
          greaterThan(palette.distinguishableDeltaE),
          reason: 'the fixture is not far apart to begin with, so the '
              'collapse below would prove nothing');
      expect(confusable.worstDifference(Dichromacy.deuteranopia),
          lessThan(palette.distinguishableDeltaE));
      expect(confusable.worstDifference(Dichromacy.protanopia),
          lessThan(palette.distinguishableDeltaE));
    });

    test('the ORIGINAL palette really did fail, which is why it changed', () {
      // The three pairs that forced a colour change, kept here as their old
      // values. This is the evidence for the claim in `lib/ui/palette.dart`
      // that these were failures rather than preferences — and it fails if
      // somebody ever "restores" one of the old colours.
      const palette.DistinctPair oldGround = palette.DistinctPair(
        'the old green ground against a pipe outline',
        'the bottom pipe is drawn over the ground',
        palette.pipeOutline,
        0xFF264B3D,
        <int>[0xFF264B3D],
      );
      const palette.DistinctPair oldHorizon = palette.DistinctPair(
        'the old green horizon band against a pipe highlight',
        'the pipes cross the band',
        palette.pipeHighlight,
        0xFF78A88D,
        <int>[0xFF78A88D],
      );
      const palette.DistinctPair oldCoast = palette.DistinctPair(
        'the old white coast path against the assist window',
        'opposite advice on two lines drawn on top of each other',
        0x99FFFFFF,
        palette.assistWindow,
        palette.playfieldBackdrops,
      );

      for (final palette.DistinctPair old in <palette.DistinctPair>[
        oldGround,
        oldHorizon,
        oldCoast,
      ]) {
        for (final Dichromacy? vision in visions) {
          expect(old.worstDifference(vision),
              lessThan(palette.distinguishableDeltaE),
              reason: '${old.label} under ${_visionName(vision)} is no longer '
                  'a failure, so the change it justified needs revisiting');
        }
      }

      // The worst of the three was a plain readability problem before it was a
      // colourblindness one: 5.09 ΔE00 for everybody.
      expect(oldGround.worstDifference(null), lessThan(6.0));
    });

    test('and the replacements really are better, by a margin', () {
      // Non-vacuous in the other direction. Without this, the test above is
      // satisfied by a metric that says everything is close.
      expect(
        palette.distinctPairs
            .map((palette.DistinctPair p) => visions
                .map((Dichromacy? v) => p.worstDifference(v))
                .reduce((double a, double b) => a < b ? a : b))
            .reduce((double a, double b) => a < b ? a : b),
        greaterThan(palette.distinguishableDeltaE),
      );
    });
  });

  group('the car sprite, measured rather than remembered', () {
    // ------------------------------------------------------------------------
    // The car is a PNG and cannot be a palette entry. Excluding it silently
    // would leave the one pair a player looks at most — their own car against
    // the ghost of their best run — ungraded. So the file is opened and the
    // colours in it are measured. See `test/sprite_colours.dart`.
    // ------------------------------------------------------------------------

    testWidgets('it is a real image with real pixels in it', (
      WidgetTester tester,
    ) async {
      final SpriteColours car = await spriteFor(tester);
      // PRINTED, not just asserted. These numbers are a fact about a file
      // outside this repository's source, and the only way a reader can check
      // the claims made from them is to see what was actually measured.
      // ignore: avoid_print
      print('measured $car');
      expect(car.opaquePixels, greaterThan(1000),
          reason: 'almost nothing in the sprite is opaque, so every number '
              'derived from it below is derived from a handful of pixels');
      // The file's alpha really does top out below 255 — see
      // `spriteOpaqueThreshold`. Asserted rather than described, so that if
      // somebody re-exports the sprite properly the comment stops being a lie.
      expect(car.maxAlpha, lessThan(0xFF));
      expect(car.maxAlpha, greaterThanOrEqualTo(spriteOpaqueThreshold));
      expect(isOpaque(car.mean), isTrue);
      expect(contrastRatio(car.brightest, car.darkest), greaterThan(2.0),
          reason: 'the sprite is one flat colour, which would make the '
              'darkest/brightest bounds meaningless');
    });

    testWidgets('the ghost stays distinguishable from the live car', (
      WidgetTester tester,
    ) async {
      // THE PAIR THAT MATTERS MOST TO A PLAYER: two cars on screen at once, one
      // of which is theirs. The ghost is drawn as a flat silhouette rather than
      // a faded copy of the sprite precisely so it cannot be mistaken for the
      // car — this is that claim, measured.
      final SpriteColours car = await spriteFor(tester);
      final List<String> failures = <String>[];
      double worst = double.infinity;

      for (final int backdrop in <int>[
        palette.skyTop,
        palette.skyBottom,
        palette.pipeBody,
        palette.hill,
      ]) {
        final int ghost = composite(palette.ghostSilhouette, backdrop);
        for (final Dichromacy? vision in visions) {
          int see(int c) => vision == null ? c : simulateDichromacy(c, vision);
          final double d = colourDifference(see(ghost), see(car.mean));
          if (d < worst) worst = d;
          if (d < palette.distinguishableDeltaE) {
            failures.add('over ${hexOf(backdrop)} under ${_visionName(vision)}: '
                '${d.toStringAsFixed(2)} ΔE00 between the ghost '
                '${hexOf(ghost)} and the car ${hexOf(car.mean)}');
          }
        }
      }
      // ignore: avoid_print
      print('ghost vs live car, worst of 4 backdrops x 3 visions: '
          '${worst.toStringAsFixed(2)} dE00');
      expect(failures, isEmpty, reason: '\n${failures.join('\n')}');
    });

    testWidgets('nothing in the sprite can reach the text', (
      WidgetTester tester,
    ) async {
      // The honest handling of "text over art": rather than trying to prove a
      // contrast ratio against 34,000 unknown pixels, the app is built so the
      // question cannot arise — every surface carrying text is opaque. This
      // takes the sprite's two extreme pixels, the worst cases, and shows the
      // HUD and the card come out at the same colour over both.
      final SpriteColours car = await spriteFor(tester);
      for (final int behind in <int>[car.darkest, car.brightest, car.mean]) {
        expect(composite(palette.hudSurface, behind), palette.hudSurface,
            reason: 'the HUD backing lets ${hexOf(behind)} through');
        expect(composite(palette.cardSurface, behind), palette.cardSurface,
            reason: 'the card backing lets ${hexOf(behind)} through');
      }
      // And the same statement fails for the values these used to have, so the
      // assertion above is not vacuously true of any colour.
      expect(composite(0xE812263D, car.brightest), isNot(0xE812263D));
    });
  });
}
