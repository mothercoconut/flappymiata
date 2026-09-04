/// The instrument, checked before anything is measured with it.
///
/// ============================================================================
/// WHY THIS FILE COMES FIRST
/// ============================================================================
///
/// `test/palette_contrast_test.dart` and `test/palette_colourblind_test.dart`
/// both do the same thing: they take a pair of colours, put them through
/// `lib/ui/colour_math.dart`, and pass or fail the app on the number that comes
/// back. Neither of them can tell a correct calculator from a broken one. A
/// contrast function with the luminance weights in the wrong order returns
/// plausible numbers for every pair it is given, prints a table full of PASS,
/// and is wrong about all of it.
///
/// So the calculator is pinned here, against values somebody else computed:
/// black on white is exactly 21:1 by the formula's own arithmetic, and the
/// greys, primaries and Lab pairs below are published reference data. Only once
/// the instrument reads correctly on known inputs is it allowed to judge
/// unknown ones.
///
/// The same argument applies to the dichromat simulator, which has no published
/// per-colour reference table to check against — so it is pinned by its
/// STRUCTURAL properties instead: a projection is idempotent, it fixes every
/// point already in the plane it projects onto, and it demonstrably moves the
/// points it is supposed to move. A simulator that returned its input unchanged
/// would satisfy the first two and fail the third, which is why the third is
/// there.
library;

import 'dart:math' as math;
import 'dart:ui' show Color;

import 'package:flutter_test/flutter_test.dart';

import 'package:flappymiata/ui/colour_math.dart';

/// How close two ΔE₀₀ values have to be to count as agreeing.
///
/// The published table is quoted to four decimal places, so 1e-4 is the
/// tightest tolerance the data itself supports.
const double _deltaETolerance = 1e-4;

void main() {
  group('channels and packing', () {
    test('bytes come apart and go back together', () {
      const int c = 0x8C8BD3C7;
      expect(alphaOf(c), 0x8C);
      expect(redOf(c), 0x8B);
      expect(greenOf(c), 0xD3);
      expect(blueOf(c), 0xC7);
      expect(packArgb(0x8C, 0x8B, 0xD3, 0xC7), c);
      expect(hexOf(c), '#8C8BD3C7');
    });

    test('opacity is the alpha byte and nothing else', () {
      expect(isOpaque(0xFF000000), isTrue);
      expect(isOpaque(0xFEFFFFFF), isFalse);
      expect(isOpaque(0x00FFFFFF), isFalse);
    });
  });

  group('compositing matches what Flutter actually draws', () {
    test('an opaque layer replaces what is under it', () {
      expect(composite(0xFF123456, 0xFFFFFFFF), 0xFF123456);
    });

    test('a fully transparent layer changes nothing', () {
      expect(composite(0x00FF0000, 0xFF123456), 0xFF123456);
    });

    test('half alpha lands halfway', () {
      // 0x80 is 128/255, a hair over half, so black over white rounds to 127.
      expect(composite(0x80000000, 0xFFFFFFFF), 0xFF7F7F7F);
    });

    // THE PIN THAT MATTERS. `composite` exists to predict a pixel the renderer
    // will produce, so the only thing that makes it right is agreeing with the
    // renderer. Flutter's own `Color.alphaBlend` is that renderer's arithmetic,
    // and this walks a spread of alphas and colours through both.
    test('it agrees with Flutter Color.alphaBlend across the range', () {
      const List<int> overs = <int>[
        0x00FFFFFF, 0x33FF0000, 0x8C8BD3C7, 0xB3061224,
        0xE68BD3C7, 0xF20A1D32, 0xFF10233F, 0xFFFFFFFF,
      ];
      const List<int> unders = <int>[
        0xFF000000, 0xFF10233F, 0xFF65B96C, 0xFFF4FBF4, 0xFFFFFFFF,
      ];
      for (final int over in overs) {
        for (final int under in unders) {
          final int mine = composite(over, under);
          final int theirs =
              Color.alphaBlend(Color(over), Color(under)).toARGB32();
          expect(mine, theirs,
              reason: 'composite(${hexOf(over)}, ${hexOf(under)}) gave '
                  '${hexOf(mine)}, Flutter gives ${hexOf(theirs)}');
        }
      }
    });

    test('a stack flattens from the bottom up', () {
      // Two layers laid on in order must equal two calls in the same order.
      const int base = 0xFF10233F;
      const int lower = 0xB3061224;
      const int upper = 0x8C8BD3C7;
      expect(flatten(base, const <int>[lower, upper]),
          composite(upper, composite(lower, base)));
    });

    test('the result of a flatten is always opaque', () {
      expect(isOpaque(flatten(0xFF10233F, const <int>[0x00FFFFFF])), isTrue);
      expect(isOpaque(flatten(0xFF10233F, const <int>[])), isTrue);
    });
  });

  group('WCAG relative luminance and contrast', () {
    test('the endpoints of the luminance scale are exact', () {
      expect(relativeLuminance(0xFF000000), 0.0);
      expect(relativeLuminance(0xFFFFFFFF), closeTo(1.0, 1e-12));
    });

    test('the three channel weights are the sRGB ones', () {
      // Not a round-trip: these are the coefficients themselves, read back one
      // primary at a time. A transposed matrix or a swapped pair of weights
      // shows up here and almost nowhere else.
      expect(relativeLuminance(0xFFFF0000), closeTo(0.2126, 1e-12));
      expect(relativeLuminance(0xFF00FF00), closeTo(0.7152, 1e-12));
      expect(relativeLuminance(0xFF0000FF), closeTo(0.0722, 1e-12));
    });

    test('a translucent colour is refused rather than guessed at', () {
      // The honest failure. A luminance is a property of light leaving the
      // screen, so a half-transparent colour has none until it is composited —
      // and a function that quietly ignored the alpha would report the contrast
      // of a colour nobody can see.
      expect(() => relativeLuminance(0xE812263D), throwsArgumentError);
      expect(() => contrastRatio(0xFFFFFFFF, 0x80000000), throwsArgumentError);
    });

    // ------------------------------------------------------------------------
    // PUBLISHED REFERENCE PAIRS.
    //
    // Black on white is 21:1 exactly, and that is not a measurement — it falls
    // straight out of the formula, (1.0 + 0.05) / (0.0 + 0.05). The rest are
    // the values quoted throughout the accessibility literature, including the
    // two greys that sit exactly on the AA and AAA boundaries for body text and
    // are used everywhere as the canonical examples.
    // ------------------------------------------------------------------------
    test('published pairs come out at their published ratios', () {
      const List<(String, int, int, double)> refs =
          <(String, int, int, double)>[
        ('black on white', 0xFF000000, 0xFFFFFFFF, 21.0),
        ('white on black', 0xFFFFFFFF, 0xFF000000, 21.0),
        ('white on white', 0xFFFFFFFF, 0xFFFFFFFF, 1.0),
        ('black on black', 0xFF000000, 0xFF000000, 1.0),
        ('#767676 on white — the AA body-text boundary', 0xFF767676,
            0xFFFFFFFF, 4.54),
        ('#595959 on white — the AAA body-text boundary', 0xFF595959,
            0xFFFFFFFF, 7.00),
        ('pure red on white', 0xFFFF0000, 0xFFFFFFFF, 3.99),
        ('pure blue on white', 0xFF0000FF, 0xFFFFFFFF, 8.59),
        ('pure green on black', 0xFF00FF00, 0xFF000000, 15.30),
        ('yellow on black', 0xFFFFFF00, 0xFF000000, 19.56),
      ];
      for (final (String name, int fg, int bg, double want) in refs) {
        expect(contrastRatio(fg, bg), closeTo(want, 0.01), reason: name);
      }
    });

    test('the ratio is symmetric and bounded', () {
      expect(contrastRatio(0xFF123456, 0xFFABCDEF),
          closeTo(contrastRatio(0xFFABCDEF, 0xFF123456), 1e-12));
      for (int i = 0; i < 256; i += 17) {
        final int grey = packArgb(0xFF, i, i, i);
        final double r = contrastRatio(grey, 0xFFFFFFFF);
        expect(r, greaterThanOrEqualTo(1.0));
        expect(r, lessThanOrEqualTo(21.0));
      }
    });

    test('the two boundary greys really do straddle the bars', () {
      // Non-vacuous in both directions: one grey passes and the next darker
      // shade of the same grey does not, so the bar is doing work.
      expect(contrastRatio(0xFF767676, 0xFFFFFFFF),
          greaterThanOrEqualTo(wcagAaTextContrast));
      expect(contrastRatio(0xFF777777, 0xFFFFFFFF),
          lessThan(wcagAaTextContrast));
      expect(wcagAaTextContrast, 4.5);
      expect(wcagAaNonTextContrast, 3.0);
    });
  });

  group('CIELAB', () {
    test('the achromatic axis has zero a* and b*', () {
      for (final int grey in <int>[
        0xFF000000, 0xFF404040, 0xFF808080, 0xFFC0C0C0, 0xFFFFFFFF,
      ]) {
        final Lab lab = toLab(grey);
        expect(lab.a, closeTo(0.0, 1e-6), reason: hexOf(grey));
        expect(lab.b, closeTo(0.0, 1e-6), reason: hexOf(grey));
      }
    });

    test('L* runs 0 to 100 over the greyscale', () {
      expect(toLab(0xFF000000).l, closeTo(0.0, 1e-9));
      expect(toLab(0xFFFFFFFF).l, closeTo(100.0, 1e-9));
      // Mid grey sits near 53.4, not 50 — the L* curve is perceptual, which is
      // the whole reason a colour difference is measured here and not in RGB.
      expect(toLab(0xFF808080).l, closeTo(53.585, 0.01));
    });

    test('the primaries land where the sRGB definition puts them', () {
      final Lab red = toLab(0xFFFF0000);
      expect(red.l, closeTo(53.2408, 0.001));
      expect(red.a, closeTo(80.0925, 0.001));
      expect(red.b, closeTo(67.2032, 0.001));

      final Lab green = toLab(0xFF00FF00);
      expect(green.l, closeTo(87.7347, 0.001));
      expect(green.a, closeTo(-86.1827, 0.001));
      expect(green.b, closeTo(83.1793, 0.001));

      final Lab blue = toLab(0xFF0000FF);
      expect(blue.l, closeTo(32.2970, 0.001));
      expect(blue.a, closeTo(79.1875, 0.001));
      expect(blue.b, closeTo(-107.8602, 0.001));
    });

    test('the sRGB transfer function round-trips', () {
      for (int i = 0; i <= 255; i++) {
        final double c = i / 255.0;
        expect(encodeSrgb(linearizeSrgb(c)), closeTo(c, 1e-12), reason: '$i');
      }
    });
  });

  group('CIEDE2000, against the published test data', () {
    // ------------------------------------------------------------------------
    // Sharma, Melkote & Trussell (2005), "The CIEDE2000 Color-Difference
    // Formula: Implementation Notes, Supplementary Test Data, and Mathematical
    // Observations". The table exists precisely because CIEDE2000 has several
    // places an implementation can be subtly wrong and still look plausible —
    // the hue-angle wrap, the mean-hue branch when the two hues straddle 0/360,
    // and the neutral case where a chroma product of zero makes the hue
    // undefined. Every one of those is a row below, on purpose.
    // ------------------------------------------------------------------------
    const List<(Lab, Lab, double)> data = <(Lab, Lab, double)>[
      (Lab(50.0000, 2.6772, -79.7751), Lab(50.0000, 0.0000, -82.7485), 2.0425),
      (Lab(50.0000, 3.1571, -77.2803), Lab(50.0000, 0.0000, -82.7485), 2.8615),
      (Lab(50.0000, 2.8361, -74.0200), Lab(50.0000, 0.0000, -82.7485), 3.4412),
      (Lab(50.0000, -1.3802, -84.2814), Lab(50.0000, 0.0000, -82.7485), 1.0000),
      (Lab(50.0000, -1.1848, -84.8006), Lab(50.0000, 0.0000, -82.7485), 1.0000),
      (Lab(50.0000, -0.9009, -85.5211), Lab(50.0000, 0.0000, -82.7485), 1.0000),
      (Lab(50.0000, 0.0000, 0.0000), Lab(50.0000, -1.0000, 2.0000), 2.3669),
      (Lab(50.0000, -1.0000, 2.0000), Lab(50.0000, 0.0000, 0.0000), 2.3669),
      (Lab(50.0000, 2.4900, -0.0010), Lab(50.0000, -2.4900, 0.0009), 7.1792),
      (Lab(50.0000, 2.4900, -0.0010), Lab(50.0000, -2.4900, 0.0011), 7.2195),
      (Lab(50.0000, -0.0010, 2.4900), Lab(50.0000, 0.0009, -2.4900), 4.8045),
      (Lab(50.0000, -0.0010, 2.4900), Lab(50.0000, 0.0011, -2.4900), 4.7461),
      (Lab(50.0000, 2.5000, 0.0000), Lab(50.0000, 0.0000, -2.5000), 4.3065),
      (Lab(50.0000, 2.5000, 0.0000), Lab(73.0000, 25.0000, -18.0000), 27.1492),
      (Lab(50.0000, 2.5000, 0.0000), Lab(61.0000, -5.0000, 29.0000), 22.8977),
      (Lab(50.0000, 2.5000, 0.0000), Lab(56.0000, -27.0000, -3.0000), 31.9030),
      (Lab(50.0000, 2.5000, 0.0000), Lab(58.0000, 24.0000, 15.0000), 19.4535),
      (Lab(50.0000, 2.5000, 0.0000), Lab(50.0000, 3.1736, 0.5854), 1.0000),
      (Lab(50.0000, 2.5000, 0.0000), Lab(50.0000, 3.2972, 0.0000), 1.0000),
      (Lab(50.0000, 2.5000, 0.0000), Lab(50.0000, 1.8634, 0.5757), 1.0000),
      (Lab(50.0000, 2.5000, 0.0000), Lab(50.0000, 3.2592, 0.3350), 1.0000),
      (Lab(60.2574, -34.0099, 36.2677), Lab(60.4626, -34.1751, 39.4387), 1.2644),
      (Lab(63.0109, -31.0961, -5.8663), Lab(62.8187, -29.7946, -4.0864), 1.2630),
      (Lab(61.2901, 3.7196, -5.3901), Lab(61.4292, 2.2480, -4.9620), 1.8731),
      (Lab(35.0831, -44.1164, 3.7933), Lab(35.0232, -40.0716, 1.5901), 1.8645),
      (Lab(22.7233, 20.0904, -46.6940), Lab(23.0331, 14.9730, -42.5619), 2.0373),
      (Lab(36.4612, 47.8580, 18.3852), Lab(36.2715, 50.5065, 21.2231), 1.4146),
      (Lab(90.8027, -2.0831, 1.4410), Lab(91.1528, -1.6435, 0.0447), 1.4441),
      (Lab(90.9257, -0.5406, -0.9208), Lab(88.6381, -0.8985, -0.7239), 1.5381),
      (Lab(6.7747, -0.2908, -2.4247), Lab(5.8714, -0.0985, -2.2286), 0.6377),
      (Lab(2.0776, 0.0795, -1.1350), Lab(0.9033, -0.0636, -0.5514), 0.9082),
    ];

    test('every published pair comes out at its published difference', () {
      for (final (Lab a, Lab b, double want) in data) {
        expect(deltaE2000(a, b), closeTo(want, _deltaETolerance),
            reason: '$a vs $b');
      }
    });

    test('the reference table is not empty and covers the awkward cases', () {
      // A loop over an empty list passes. It is worth one line to make sure
      // this one is not.
      expect(data.length, greaterThanOrEqualTo(30));
      // The row with a chroma of exactly zero on one side — where the hue is
      // undefined and a naive implementation divides by nothing — is present.
      expect(data.any((r) => r.$1.a == 0.0 && r.$1.b == 0.0), isTrue);
      // And the table spans the range rather than clustering: differences from
      // under 1 to over 30, so a formula that was right only for near-identical
      // colours could not pass it.
      expect(data.map((r) => r.$3).reduce(math.min), lessThan(1.0));
      expect(data.map((r) => r.$3).reduce(math.max), greaterThan(30.0));
    });

    test('a colour differs from itself by exactly nothing', () {
      for (final int c in <int>[
        0xFF000000, 0xFF8BD3C7, 0xFFFF2D78, 0xFFFFFFFF,
      ]) {
        expect(colourDifference(c, c), closeTo(0.0, 1e-12), reason: hexOf(c));
      }
    });

    test('it is symmetric', () {
      expect(colourDifference(0xFF2D7A4A, 0xFF5F9B8A),
          closeTo(colourDifference(0xFF5F9B8A, 0xFF2D7A4A), 1e-12));
    });
  });

  group('dichromacy simulation', () {
    // ------------------------------------------------------------------------
    // There is no published per-colour reference table for this the way there
    // is for CIEDE2000, so it is pinned by the properties a projection onto a
    // plane must have — plus one test that it actually does something, because
    // `simulateDichromacy(c) => c` would satisfy every structural property
    // below and be useless.
    // ------------------------------------------------------------------------

    const List<int> samples = <int>[
      0xFF000000, 0xFFFFFFFF, 0xFF808080, 0xFFFF0000, 0xFF00FF00,
      0xFF0000FF, 0xFF8BD3C7, 0xFFFF2D78, 0xFF2D7A4A, 0xFF65B96C,
      0xFFFFC13B, 0xFF3BE0FF, 0xFF173B62,
    ];

    test('simulating twice is simulating once', () {
      // A projection is idempotent. If this fails, the transform is not the
      // projection it claims to be.
      for (final Dichromacy type in Dichromacy.values) {
        for (final int c in samples) {
          final int once = simulateDichromacy(c, type);
          final int twice = simulateDichromacy(once, type);
          // One byte of slack per channel: the round trip through the encoding
          // curve and back rounds, and clipped colours round harder.
          expect((redOf(twice) - redOf(once)).abs(), lessThanOrEqualTo(1),
              reason: '$type ${hexOf(c)} R');
          expect((greenOf(twice) - greenOf(once)).abs(), lessThanOrEqualTo(1),
              reason: '$type ${hexOf(c)} G');
          expect((blueOf(twice) - blueOf(once)).abs(), lessThanOrEqualTo(1),
              reason: '$type ${hexOf(c)} B');
        }
      }
    });

    test('greys are left alone', () {
      // The achromatic axis is already in the plane being projected onto, so a
      // grey must come back as itself. This is the closest thing to a known
      // answer the simulator has.
      for (final Dichromacy type in Dichromacy.values) {
        for (int i = 0; i <= 255; i += 15) {
          final int grey = packArgb(0xFF, i, i, i);
          expect(colourDifference(simulateDichromacy(grey, type), grey),
              lessThan(1.0),
              reason: '$type $i');
        }
      }
    });

    test('alpha is carried through untouched', () {
      expect(alphaOf(simulateDichromacy(0x8C8BD3C7, Dichromacy.protanopia)),
          0x8C);
      expect(alphaOf(simulateDichromacy(0x00FF0000, Dichromacy.deuteranopia)),
          0x00);
    });

    test('it collapses red and green, which is the whole point', () {
      // THE POSITIVE CONTROL. Without this the two tests above are satisfied by
      // an identity function, and the colourblind check would be grading the
      // palette against ordinary colour vision under a different name.
      const int red = 0xFFCC0000;
      const int green = 0xFF00AA00;
      final double before = colourDifference(red, green);
      expect(before, greaterThan(60.0), reason: 'the fixture is not far apart');

      for (final Dichromacy type in Dichromacy.values) {
        final double after = colourDifference(
          simulateDichromacy(red, type),
          simulateDichromacy(green, type),
        );
        expect(after, lessThan(before / 2.0),
            reason: '$type left red and green $after apart, which is not a '
                'red-green deficiency');
        // And the simulator really did move at least one of them a long way.
        expect(
          math.max(
            colourDifference(simulateDichromacy(red, type), red),
            colourDifference(simulateDichromacy(green, type), green),
          ),
          greaterThan(10.0),
          reason: '$type barely changed either colour',
        );
      }
    });

    test('blue and yellow survive, because that axis is intact', () {
      // The other half of the model being right: a red-green deficiency is a
      // red-green deficiency, not a general loss of colour. If blue came back
      // as grey, the simulation would be over-reporting and would push the
      // palette toward changes nobody needs.
      for (final Dichromacy type in Dichromacy.values) {
        // Pure blue and pure yellow only. A cyan is deliberately NOT here:
        // it carries a large green component, so a protanope really does see
        // it differently, and asserting otherwise would be asserting the
        // simulator is wrong.
        for (final int c in <int>[0xFF0000FF, 0xFFFFFF00]) {
          expect(colourDifference(simulateDichromacy(c, type), c),
              lessThan(20.0),
              reason: '$type moved ${hexOf(c)} off the surviving axis');
        }
      }
    });

    test('the two simulations are not the same function', () {
      // Protanopia and deuteranopia differ most on reds, because only one of
      // them is missing the long-wavelength cone. A copy-paste that pointed
      // both enum arms at the same matrix would pass every test above.
      expect(
        colourDifference(
          simulateDichromacy(0xFFCC0000, Dichromacy.protanopia),
          simulateDichromacy(0xFFCC0000, Dichromacy.deuteranopia),
        ),
        greaterThan(5.0),
      );
    });
  });
}
